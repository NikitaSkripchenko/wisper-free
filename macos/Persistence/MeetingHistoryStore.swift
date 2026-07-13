import Darwin
import CryptoKit
import Foundation

enum MeetingStorageBoundary: Equatable, Sendable {
    case stagedWrite
    case fileSync
    case atomicReplace
    case directorySync
    case promotionRename
    case tombstoneRename
    case trashDelete
    case quarantineRename
}

typealias MeetingStorageFaultInjector = @Sendable (MeetingStorageBoundary) -> (any Error)?

private struct MigrationState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case promoted
        case validated
        case retired
    }

    let phase: Phase
    let legacyIDs: [UUID]
    let legacyDigest: String
    let artifactDigests: [String: String]
    let legacyOwnedAudioPaths: [String]
}

protocol MeetingHistoryStoring: Sendable {
    func bootstrap() async throws -> MeetingBootstrapResult
    func createStagingDirectory(meetingID: UUID) async throws -> URL
    func discardStagedMeeting(id: UUID) async throws
    func promoteStagedMeeting(_ record: MeetingRecord) async throws
    func loadRecord(id: UUID) async throws -> MeetingRecord
    func saveRecord(_ record: MeetingRecord) async throws
    func updateTitle(_ title: String, meetingID: UUID) async throws -> MeetingRecord
    func saveTranscript(_ transcript: String, meetingID: UUID, attemptID: UUID) async throws -> MeetingArtifactReference
    func loadTranscript(_ reference: MeetingArtifactReference, meetingID: UUID) async throws -> String
    func saveNotes(_ notes: MeetingNotes, meetingID: UUID, attemptID: UUID) async throws -> MeetingArtifactReference
    func loadNotes(_ reference: MeetingArtifactReference, meetingID: UUID) async throws -> MeetingNotes
    func removeMeeting(id: UUID) async throws
    func artifactURL(_ reference: MeetingArtifactReference, meetingID: UUID) async throws -> URL
}

actor MeetingHistoryStore: MeetingHistoryStoring {
    private let rootURL: URL
    private let legacyHistoryURL: URL
    private let fileManager: FileManager
    private let faultInjector: MeetingStorageFaultInjector

    init(
        rootURL: URL = AppStorageLocation.supportDirectory.appending(path: "Meetings", directoryHint: .isDirectory),
        legacyHistoryURL: URL = AppStorageLocation.historyURL,
        fileManager: FileManager = .default,
        faultInjector: @escaping MeetingStorageFaultInjector = { _ in nil }
    ) {
        self.rootURL = rootURL
        self.legacyHistoryURL = legacyHistoryURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func bootstrap() async throws -> MeetingBootstrapResult {
        let migration = try migrateLegacyHistoryIfNeeded()
        try createInfrastructure()
        cleanupDirectoryBestEffort(stagingRootURL)
        let staleTrashCount = cleanupTrashBestEffort()

        var records: [MeetingRecord] = []
        var quarantinedCount = migration.quarantinedLegacy ? 1 : 0
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in contents where directory.lastPathComponent != ".tmp" && directory.lastPathComponent != ".trash" {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do {
                var record = try readRecord(at: directory.appending(path: "record.json"))
                guard record.schemaVersion == MeetingRecord.currentSchemaVersion,
                      record.id.uuidString == directory.lastPathComponent else {
                    throw MeetingStorageError.invalidStagedRecord
                }
                var needsRecoverySave = false
                if record.transcription.status == .processing {
                    record.transcription.status = .failed
                    record.transcription.failure = .interrupted
                    record.transcription.finishedAt = Date()
                    needsRecoverySave = true
                }
                if record.notes.status == .processing {
                    record.notes.status = .failed
                    record.notes.failure = .interrupted
                    record.notes.finishedAt = Date()
                    needsRecoverySave = true
                }
                if needsRecoverySave {
                    record.updatedAt = Date()
                    try writeRecord(record, to: directory.appending(path: "record.json"))
                }
                cleanupUnreferencedArtifactsBestEffort(record: record, directory: directory)
                records.append(record)
            } catch {
                try quarantine(directory)
                quarantinedCount += 1
            }
        }

        records.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
        return MeetingBootstrapResult(
            records: records,
            quarantinedRecordCount: quarantinedCount,
            migratedRecordCount: migration.migratedCount,
            staleTrashCount: staleTrashCount
        )
    }

    func createStagingDirectory(meetingID: UUID) throws -> URL {
        try createInfrastructure()
        let directory = stagingDirectory(for: meetingID)
        guard fileManager.fileExists(atPath: directory.path) == false else {
            throw MeetingStorageError.stagedMeetingAlreadyExists
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func discardStagedMeeting(id: UUID) throws {
        let source = stagingDirectory(for: id)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let tombstone = trashRootURL.appending(path: "staged-\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try failIfRequested(.tombstoneRename)
            try fileManager.moveItem(at: source, to: tombstone)
            try syncDirectory(stagingRootURL)
        } catch {
            throw MeetingStorageError.removeFailed
        }
        removeTrashBestEffort(tombstone)
    }

    func promoteStagedMeeting(_ record: MeetingRecord) throws {
        let staged = stagingDirectory(for: record.id)
        let destination = meetingDirectory(for: record.id)
        guard record.schemaVersion == MeetingRecord.currentSchemaVersion,
              fileManager.fileExists(atPath: staged.path),
              fileManager.fileExists(atPath: destination.path) == false else {
            throw MeetingStorageError.invalidStagedRecord
        }
        try validateArtifactReferences(record, directory: staged)
        for reference in [
            record.captureArtifacts.microphone,
            record.captureArtifacts.systemAudio,
            record.captureArtifacts.transcriptionInput
        ].compactMap({ $0 }) {
            let url = try safeArtifactURL(reference, directory: staged)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MeetingStorageError.invalidStagedRecord
            }
            try syncFile(url)
        }
        let recordURL = staged.appending(path: "record.json")
        try writeRecord(record, to: recordURL)
        let validated = try readRecord(at: recordURL)
        guard validated.id == record.id,
              validated.schemaVersion == record.schemaVersion,
              validated.captureArtifacts == record.captureArtifacts else {
            throw MeetingStorageError.invalidStagedRecord
        }
        try syncDirectory(staged)
        try failIfRequested(.promotionRename)
        try fileManager.moveItem(at: staged, to: destination)
        try syncDirectory(rootURL)
    }

    func loadRecord(id: UUID) throws -> MeetingRecord {
        try readRecord(at: meetingDirectory(for: id).appending(path: "record.json"))
    }

    func saveRecord(_ record: MeetingRecord) throws {
        let directory = meetingDirectory(for: record.id)
        guard record.schemaVersion == MeetingRecord.currentSchemaVersion,
              fileManager.fileExists(atPath: directory.path) else {
            throw MeetingStorageError.missingRecord
        }
        try validateArtifactReferences(record, directory: directory)
        try writeRecord(record, to: directory.appending(path: "record.json"))
    }

    func updateTitle(_ title: String, meetingID: UUID) throws -> MeetingRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { throw MeetingStorageError.invalidTitle }

        var record = try loadRecord(id: meetingID)
        let previousUpdatedAt = record.updatedAt
        record.title = trimmedTitle
        record.updatedAt = Date()
        do {
            try saveRecord(record)
            return try loadRecord(id: meetingID)
        } catch {
            // A directory-sync failure can be reported after the atomic replacement
            // already committed. In that case, return the authoritative record instead
            // of presenting a false failure while the new title is durable on disk.
            if let committed = try? loadRecord(id: meetingID),
               committed.title == trimmedTitle,
               committed.updatedAt >= previousUpdatedAt {
                return committed
            }
            throw error
        }
    }

    func saveTranscript(_ transcript: String, meetingID: UUID, attemptID: UUID) throws -> MeetingArtifactReference {
        let reference = try MeetingArtifactReference("transcript-\(attemptID.uuidString).txt")
        let url = try artifactURL(reference, meetingID: meetingID)
        try writeData(Data(transcript.utf8), to: url)
        return reference
    }

    func loadTranscript(_ reference: MeetingArtifactReference, meetingID: UUID) throws -> String {
        let data = try Data(contentsOf: artifactURL(reference, meetingID: meetingID))
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func saveNotes(_ notes: MeetingNotes, meetingID: UUID, attemptID: UUID) throws -> MeetingArtifactReference {
        let reference = try MeetingArtifactReference("notes-\(attemptID.uuidString).json")
        try writeData(JSONEncoder.wisper.encode(notes), to: artifactURL(reference, meetingID: meetingID))
        return reference
    }

    func loadNotes(_ reference: MeetingArtifactReference, meetingID: UUID) throws -> MeetingNotes {
        try JSONDecoder.wisper.decode(MeetingNotes.self, from: Data(contentsOf: artifactURL(reference, meetingID: meetingID)))
    }

    func removeMeeting(id: UUID) throws {
        let source = meetingDirectory(for: id)
        guard fileManager.fileExists(atPath: source.path) else {
            throw MeetingStorageError.missingRecord
        }
        let tombstone = trashRootURL.appending(path: "\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try failIfRequested(.tombstoneRename)
            try fileManager.moveItem(at: source, to: tombstone)
            try syncDirectory(rootURL)
        } catch {
            throw MeetingStorageError.removeFailed
        }
        removeTrashBestEffort(tombstone)
    }

    func artifactURL(_ reference: MeetingArtifactReference, meetingID: UUID) throws -> URL {
        try safeArtifactURL(reference, directory: meetingDirectory(for: meetingID))
    }

    private var stagingRootURL: URL {
        rootURL.appending(path: ".tmp", directoryHint: .isDirectory)
    }

    private var trashRootURL: URL {
        rootURL.appending(path: ".trash", directoryHint: .isDirectory)
    }

    private var corruptRootURL: URL {
        rootURL.appending(path: ".corrupt", directoryHint: .isDirectory)
    }

    private var migrationStateURL: URL {
        rootURL.deletingLastPathComponent().appending(path: "migration-v2.json")
    }

    private var migrationTemporaryRootURL: URL {
        rootURL.deletingLastPathComponent().appending(
            path: "\(rootURL.lastPathComponent).v2.tmp",
            directoryHint: .isDirectory
        )
    }

    private var legacyBackupURL: URL {
        legacyHistoryURL.deletingLastPathComponent().appending(path: "history.legacy-backup.json")
    }

    private func meetingDirectory(for id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func stagingDirectory(for id: UUID) -> URL {
        stagingRootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func createInfrastructure() throws {
        try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: trashRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corruptRootURL, withIntermediateDirectories: true)
    }

    private func cleanupDirectoryBestEffort(_ directory: URL) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }

    private func cleanupUnreferencedArtifactsBestEffort(record: MeetingRecord, directory: URL) {
        let retainedNames = Set([
            record.captureArtifacts.microphone,
            record.captureArtifacts.systemAudio,
            Optional(record.captureArtifacts.transcriptionInput),
            record.transcriptArtifact,
            record.lastValidNotesArtifact
        ].compactMap { $0?.rawValue }).union(["record.json"])
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where retainedNames.contains(file.lastPathComponent) == false {
            try? fileManager.removeItem(at: file)
        }
    }

    private func cleanupTrashBestEffort(now: Date = Date()) -> Int {
        guard fileManager.fileExists(atPath: trashRootURL.path),
              let items = try? fileManager.contentsOfDirectory(
                at: trashRootURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
              ) else { return 0 }
        var staleCount = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let ageAnchor = values?.contentModificationDate ?? values?.creationDate ?? now
            if removeTrashBestEffort(item) == false,
               now.timeIntervalSince(ageAnchor) >= 7 * 24 * 60 * 60 {
                staleCount += 1
            }
        }
        return staleCount
    }

    @discardableResult
    private func removeTrashBestEffort(_ url: URL) -> Bool {
        do {
            try failIfRequested(.trashDelete)
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func migrateLegacyHistoryIfNeeded() throws -> (migratedCount: Int, quarantinedLegacy: Bool) {
        var state = try loadMigrationState()
        if state?.phase == .retired, let state {
            try validateMigrationRoot(rootURL, expectedIDs: state.legacyIDs)
            return (0, false)
        }

        if let preparedState = state, preparedState.phase == .prepared,
           fileManager.fileExists(atPath: migrationTemporaryRootURL.path) == false,
           try rootContainsProductionRecords() {
            try validateMigratedRoot(state: preparedState)
            state = migrationState(preparedState, phase: .promoted)
            try saveMigrationState(state!)
        }
        if let resumableState = state,
           resumableState.phase == .promoted || resumableState.phase == .validated {
            try validateMigratedRoot(state: resumableState)
            if resumableState.phase == .promoted {
                state = migrationState(resumableState, phase: .validated)
                try saveMigrationState(state!)
            }
            try retireLegacyMigration(state: state!)
            return (0, false)
        }

        guard fileManager.fileExists(atPath: legacyHistoryURL.path) else {
            if state == nil { return (0, false) }
            throw MeetingStorageError.legacyMigrationFailed
        }
        let legacyData: Data
        let legacy: [Transcript]
        do {
            legacyData = try Data(contentsOf: legacyHistoryURL)
            legacy = try JSONDecoder.wisper.decode([Transcript].self, from: legacyData)
        } catch {
            throw MeetingStorageError.legacyMigrationFailed
        }
        let ids = legacy.map(\.id)
        guard Set(ids).count == ids.count,
              try rootContainsProductionRecords() == false else {
            throw MeetingStorageError.legacyMigrationFailed
        }

        if fileManager.fileExists(atPath: legacyBackupURL.path) == false {
            try fileManager.copyItem(at: legacyHistoryURL, to: legacyBackupURL)
            try syncFile(legacyBackupURL)
            try syncDirectory(legacyBackupURL.deletingLastPathComponent())
        }
        try? fileManager.removeItem(at: migrationTemporaryRootURL)
        try fileManager.createDirectory(
            at: migrationTemporaryRootURL.appending(path: ".tmp", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: migrationTemporaryRootURL.appending(path: ".trash", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: migrationTemporaryRootURL.appending(path: ".corrupt", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        for transcript in legacy {
            try writeMigratedMeeting(transcript, root: migrationTemporaryRootURL)
        }
        try validateMigrationRoot(migrationTemporaryRootURL, expectedIDs: ids)
        let preparedState = MigrationState(
            phase: .prepared,
            legacyIDs: ids,
            legacyDigest: digest(legacyData),
            artifactDigests: try migrationArtifactDigests(root: migrationTemporaryRootURL, expectedIDs: ids),
            legacyOwnedAudioPaths: legacyOwnedAudioPaths(in: legacy)
        )
        try syncDirectory(migrationTemporaryRootURL)
        try saveMigrationState(preparedState)

        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try failIfRequested(.promotionRename)
        try fileManager.moveItem(at: migrationTemporaryRootURL, to: rootURL)
        try syncDirectory(rootURL.deletingLastPathComponent())
        let promotedState = migrationState(preparedState, phase: .promoted)
        try saveMigrationState(promotedState)
        try validateMigratedRoot(state: promotedState)
        let validatedState = migrationState(promotedState, phase: .validated)
        try saveMigrationState(validatedState)
        try retireLegacyMigration(state: validatedState)
        return (legacy.count, false)
    }

    private func writeMigratedMeeting(_ transcript: Transcript, root: URL) throws {
        let directory = root.appending(path: transcript.id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        var microphoneReference: MeetingArtifactReference?
        if let audioURL = transcript.audioURL, fileManager.fileExists(atPath: audioURL.path) {
            let fileName = "imported-source.\(audioURL.pathExtension.lowercased())"
            let reference = try MeetingArtifactReference(fileName)
            let destination = directory.appending(path: fileName)
            try fileManager.copyItem(at: audioURL, to: destination)
            try syncFile(destination)
            microphoneReference = reference
        }
        let attemptID = UUID()
        let transcriptReference = try MeetingArtifactReference("transcript-\(attemptID.uuidString).txt")
        try writeData(Data(transcript.transcriptionText.utf8), to: directory.appending(path: transcriptReference.rawValue))
        let captureReference = try microphoneReference ?? MeetingArtifactReference("missing-source.audio")
        let record = MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: transcript.id,
            title: transcript.title,
            createdAt: transcript.createdAt,
            updatedAt: transcript.updatedAt,
            durationSeconds: transcript.durationSeconds,
            captureMode: .microphone,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: microphoneReference,
                systemAudio: nil,
                transcriptionInput: captureReference
            ),
            transcription: MeetingStageAttempt(
                status: transcript.status == .completed ? .completed : .failed,
                attemptID: attemptID,
                attemptCount: 1,
                requestCount: 1,
                startedAt: transcript.createdAt,
                finishedAt: transcript.updatedAt,
                failure: transcript.status == .completed
                    ? nil
                    : MeetingFailure(category: .interrupted, message: "Legacy transcription was interrupted. Retry this stage.")
            ),
            transcriptionMode: TranscriptionMode(rawValue: transcript.mode) ?? .plain,
            transcriptArtifact: transcriptReference,
            notes: .notStarted,
            lastValidNotesArtifact: nil,
            notesProvenance: nil
        )
        try writeRecord(record, to: directory.appending(path: "record.json"))
    }

    private func rootContainsProductionRecords() throws -> Bool {
        guard fileManager.fileExists(atPath: rootURL.path) else { return false }
        return try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".") == false }
    }

    private func validateMigratedRoot(state: MigrationState) throws {
        try validateMigrationRoot(rootURL, expectedIDs: state.legacyIDs)
        guard try migrationArtifactDigests(root: rootURL, expectedIDs: state.legacyIDs) == state.artifactDigests else {
            throw MeetingStorageError.legacyMigrationFailed
        }
    }

    private func validateMigrationRoot(_ root: URL, expectedIDs: [UUID]) throws {
        for id in expectedIDs {
            let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
            let record = try readRecord(at: directory.appending(path: "record.json"))
            guard record.id == id, record.schemaVersion == MeetingRecord.currentSchemaVersion else {
                throw MeetingStorageError.legacyMigrationFailed
            }
            _ = try loadTranscriptFromRoot(record.transcriptArtifact, meetingID: id, root: root)
            if let microphone = record.captureArtifacts.microphone {
                let url = try safeArtifactURL(microphone, directory: directory)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw MeetingStorageError.legacyMigrationFailed
                }
            }
        }
    }

    private func loadTranscriptFromRoot(
        _ reference: MeetingArtifactReference?,
        meetingID: UUID,
        root: URL
    ) throws -> String {
        guard let reference else { throw MeetingStorageError.legacyMigrationFailed }
        let directory = root.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        let data = try Data(contentsOf: safeArtifactURL(reference, directory: directory))
        guard let transcript = String(data: data, encoding: .utf8) else {
            throw MeetingStorageError.legacyMigrationFailed
        }
        return transcript
    }

    private func loadMigrationState() throws -> MigrationState? {
        guard fileManager.fileExists(atPath: migrationStateURL.path) else { return nil }
        return try JSONDecoder.wisper.decode(MigrationState.self, from: Data(contentsOf: migrationStateURL))
    }

    private func saveMigrationState(_ state: MigrationState) throws {
        try writeData(JSONEncoder.wisper.encode(state), to: migrationStateURL)
    }

    private func retireLegacyMigration(state: MigrationState) throws {
        for source in [legacyHistoryURL, legacyBackupURL] where fileManager.fileExists(atPath: source.path) {
            guard digest(try Data(contentsOf: source)) == state.legacyDigest else {
                throw MeetingStorageError.legacyMigrationFailed
            }
        }
        let ownedRoot = legacyOwnedRecordingsRoot.standardizedFileURL
        for relativePath in state.legacyOwnedAudioPaths {
            let candidate = ownedRoot.appending(path: relativePath).standardizedFileURL
            guard candidate.path.hasPrefix(ownedRoot.path + "/") else {
                throw MeetingStorageError.legacyMigrationFailed
            }
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }
        if fileManager.fileExists(atPath: ownedRoot.path) {
            try syncDirectory(ownedRoot)
        }
        if fileManager.fileExists(atPath: legacyHistoryURL.path) {
            try fileManager.removeItem(at: legacyHistoryURL)
        }
        if fileManager.fileExists(atPath: legacyBackupURL.path) {
            try fileManager.removeItem(at: legacyBackupURL)
        }
        try syncDirectory(legacyHistoryURL.deletingLastPathComponent())
        try saveMigrationState(migrationState(state, phase: .retired))
    }

    private var legacyOwnedRecordingsRoot: URL {
        legacyHistoryURL.deletingLastPathComponent().appending(path: "Recordings", directoryHint: .isDirectory)
    }

    private func legacyOwnedAudioPaths(in transcripts: [Transcript]) -> [String] {
        let root = legacyOwnedRecordingsRoot.standardizedFileURL
        return transcripts.compactMap { transcript in
            guard let audioURL = transcript.audioURL?.standardizedFileURL,
                  audioURL.path.hasPrefix(root.path + "/") else { return nil }
            return String(audioURL.path.dropFirst(root.path.count + 1))
        }
    }

    private func migrationState(_ state: MigrationState, phase: MigrationState.Phase) -> MigrationState {
        MigrationState(
            phase: phase,
            legacyIDs: state.legacyIDs,
            legacyDigest: state.legacyDigest,
            artifactDigests: state.artifactDigests,
            legacyOwnedAudioPaths: state.legacyOwnedAudioPaths
        )
    }

    private func migrationArtifactDigests(root: URL, expectedIDs: [UUID]) throws -> [String: String] {
        var result: [String: String] = [:]
        for id in expectedIDs {
            let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
            let recordURL = directory.appending(path: "record.json")
            let record = try readRecord(at: recordURL)
            var references = Set([
                record.captureArtifacts.microphone,
                record.captureArtifacts.systemAudio,
                record.transcriptArtifact
            ].compactMap { $0 })
            references.insert(record.captureArtifacts.transcriptionInput)
            result["\(id.uuidString)/record.json"] = digest(try Data(contentsOf: recordURL))
            for reference in references {
                let url = try safeArtifactURL(reference, directory: directory)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                result["\(id.uuidString)/\(reference.rawValue)"] = digest(try Data(contentsOf: url))
            }
        }
        return result
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateArtifactReferences(_ record: MeetingRecord, directory: URL) throws {
        let references = [
            record.captureArtifacts.microphone,
            record.captureArtifacts.systemAudio,
            record.captureArtifacts.transcriptionInput,
            record.transcriptArtifact,
            record.lastValidNotesArtifact
        ].compactMap { $0 }
        for reference in references {
            _ = try safeArtifactURL(reference, directory: directory)
        }
    }

    private func safeArtifactURL(_ reference: MeetingArtifactReference, directory: URL) throws -> URL {
        let root = directory.standardizedFileURL
        let candidate = root.appending(path: reference.rawValue).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate.path != root.path else {
            throw MeetingStorageError.artifactEscapesMeetingDirectory
        }
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw MeetingStorageError.artifactEscapesMeetingDirectory
        }
        var current = candidate.deletingLastPathComponent()
        while current.path.hasPrefix(root.path), current.path != root.path {
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw MeetingStorageError.artifactEscapesMeetingDirectory
            }
            current.deleteLastPathComponent()
        }
        return candidate
    }

    private func quarantine(_ directory: URL) throws {
        let destination = corruptRootURL.appending(
            path: "\(directory.lastPathComponent).corrupt-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try failIfRequested(.quarantineRename)
        try fileManager.moveItem(at: directory, to: destination)
    }

    private func readRecord(at url: URL) throws -> MeetingRecord {
        try JSONDecoder.wisper.decode(MeetingRecord.self, from: Data(contentsOf: url))
    }

    private func writeRecord(_ record: MeetingRecord, to url: URL) throws {
        try writeData(JSONEncoder.wisper.encode(record), to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try failIfRequested(.stagedWrite)
        try data.write(to: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }
        try failIfRequested(.fileSync)
        try handle.synchronize()
        try handle.close()
        try failIfRequested(.atomicReplace)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try syncDirectory(directory)
    }

    private func syncDirectory(_ directory: URL) throws {
        try failIfRequested(.directorySync)
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private func syncFile(_ url: URL) throws {
        try failIfRequested(.fileSync)
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private func failIfRequested(_ boundary: MeetingStorageBoundary) throws {
        if let error = faultInjector(boundary) {
            throw error
        }
    }
}
