import Foundation

protocol MeetingTranscribing: Sendable {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult
}

extension OpenAITranscriptionService: MeetingTranscribing {}

actor MeetingLease {
    private var owner: UUID?

    func acquire(for meetingID: UUID) -> Bool {
        guard owner == nil || owner == meetingID else { return false }
        owner = meetingID
        return true
    }

    func validate(owner meetingID: UUID) -> Bool {
        owner == meetingID
    }

    func release(for meetingID: UUID) {
        guard owner == meetingID else { return }
        owner = nil
    }

    var activeMeetingID: UUID? { owner }
}

enum MeetingCoordinatorError: LocalizedError, Equatable {
    case bootstrapIncomplete
    case anotherMeetingActive(UUID)
    case noActiveCapture
    case invalidTransition
    case missingAPIKey
    case invalidMeetingTitle
    case meetingMetadataBusy

    var errorDescription: String? {
        switch self {
        case .bootstrapIncomplete:
            "Wisper is still preparing meeting history."
        case .anotherMeetingActive:
            "Another meeting is already recording or processing."
        case .noActiveCapture:
            "There is no active recording."
        case .invalidTransition:
            "That action is not available for the meeting's current stage."
        case .missingAPIKey:
            "Save an OpenAI API key before processing meetings."
        case .invalidMeetingTitle:
            "Enter a meeting title."
        case .meetingMetadataBusy:
            "Another action is already updating this meeting."
        }
    }
}

enum MeetingBootstrapState: Equatable {
    case preparing
    case ready
    case failed(String)
}

actor MeetingProcessingPipeline {
    typealias RecordUpdate = @MainActor @Sendable (MeetingRecord) -> Void

    private let store: any MeetingHistoryStoring
    private let transcriber: any MeetingTranscribing
    private let notesGenerator: any MeetingNotesGenerating
    private let logger: LocalLogger

    init(
        store: any MeetingHistoryStoring,
        transcriber: any MeetingTranscribing,
        notesGenerator: any MeetingNotesGenerating,
        logger: LocalLogger
    ) {
        self.store = store
        self.transcriber = transcriber
        self.notesGenerator = notesGenerator
        self.logger = logger
    }

    func process(
        meetingID: UUID,
        apiKey: String,
        chunkSeconds: Int?,
        beginWithTranscription: Bool,
        onUpdate: @escaping RecordUpdate
    ) async {
        if beginWithTranscription {
            let transcriptionSucceeded = await runTranscription(
                meetingID: meetingID,
                apiKey: apiKey,
                chunkSeconds: chunkSeconds,
                onUpdate: onUpdate
            )
            guard transcriptionSucceeded else { return }
        }
        await runNotes(meetingID: meetingID, apiKey: apiKey, onUpdate: onUpdate)
    }

    private func runTranscription(
        meetingID: UUID,
        apiKey: String,
        chunkSeconds: Int?,
        onUpdate: @escaping RecordUpdate
    ) async -> Bool {
        let attemptID = UUID()
        do {
            var record = try await store.loadRecord(id: meetingID)
            record.transcription = nextAttempt(from: record.transcription, attemptID: attemptID)
            record.updatedAt = Date()
            try await store.saveRecord(record)
            await onUpdate(record)
            logTransition(stage: "transcription", status: "processing", record: record)

            let audioURL = try await store.artifactURL(
                record.captureArtifacts.transcriptionInput,
                meetingID: meetingID
            )
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw MeetingFailure(category: .missingArtifact, message: "The saved transcription audio is missing.")
            }
            let result = try await transcriber.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                chunkSeconds: chunkSeconds,
                progress: nil
            )
            try Task.checkCancellation()
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw MeetingFailure(category: .emptyTranscript, message: "No speech was recognized. Retry transcription.")
            }

            var latest = try await store.loadRecord(id: meetingID)
            guard latest.transcription.attemptID == attemptID,
                  latest.transcription.status == .processing else { return false }
            let reference = try await store.saveTranscript(result.text, meetingID: meetingID, attemptID: attemptID)
            latest.transcription.status = .completed
            latest.transcription.finishedAt = Date()
            latest.transcription.failure = nil
            latest.transcription.requestCount = result.requestCount
            latest.transcriptionMode = result.mode
            latest.transcriptArtifact = reference
            latest.updatedAt = Date()
            try await store.saveRecord(latest)
            await onUpdate(latest)
            logTransition(stage: "transcription", status: "completed", record: latest)
            return true
        } catch {
            await persistFailure(error, meetingID: meetingID, stage: .transcription, attemptID: attemptID, onUpdate: onUpdate)
            return false
        }
    }

    private func runNotes(
        meetingID: UUID,
        apiKey: String,
        onUpdate: @escaping RecordUpdate
    ) async {
        let attemptID = UUID()
        do {
            var record = try await store.loadRecord(id: meetingID)
            guard let transcriptReference = record.transcriptArtifact else {
                throw MeetingFailure(category: .missingArtifact, message: "The raw transcript is missing.")
            }
            record.notes = nextAttempt(from: record.notes, attemptID: attemptID)
            record.updatedAt = Date()
            try await store.saveRecord(record)
            await onUpdate(record)
            logTransition(stage: "notes", status: "processing", record: record)

            let transcript = try await store.loadTranscript(transcriptReference, meetingID: meetingID)
            let generation = try await notesGenerator.generateNotes(transcript: transcript, apiKey: apiKey)
            try Task.checkCancellation()

            var latest = try await store.loadRecord(id: meetingID)
            guard latest.notes.attemptID == attemptID,
                  latest.notes.status == .processing else { return }
            let reference = try await store.saveNotes(generation.notes, meetingID: meetingID, attemptID: attemptID)
            latest.notes.status = .completed
            latest.notes.finishedAt = Date()
            latest.notes.failure = nil
            latest.notes.requestCount = generation.requestCount
            latest.lastValidNotesArtifact = reference
            latest.notesProvenance = MeetingNotesProvenance(
                modelID: OpenAIMeetingNotesService.model,
                promptVersion: OpenAIMeetingNotesService.promptVersion,
                generatedAt: Date()
            )
            latest.updatedAt = Date()
            try await store.saveRecord(latest)
            await onUpdate(latest)
            logTransition(stage: "notes", status: "completed", record: latest)
        } catch {
            await persistFailure(error, meetingID: meetingID, stage: .notes, attemptID: attemptID, onUpdate: onUpdate)
        }
    }

    private enum FailureStage: Equatable { case transcription, notes }

    private func persistFailure(
        _ error: Error,
        meetingID: UUID,
        stage: FailureStage,
        attemptID: UUID,
        onUpdate: @escaping RecordUpdate
    ) async {
        do {
            var record = try await store.loadRecord(id: meetingID)
            let failure = failure(from: error)
            switch stage {
            case .transcription:
                guard record.transcription.attemptID == attemptID else { return }
                record.transcription.status = .failed
                record.transcription.finishedAt = Date()
                record.transcription.failure = failure
            case .notes:
                guard record.notes.attemptID == attemptID else { return }
                record.notes.status = .failed
                record.notes.finishedAt = Date()
                record.notes.failure = failure
            }
            record.updatedAt = Date()
            try await store.saveRecord(record)
            await onUpdate(record)
            let attempt = stage == .transcription ? record.transcription : record.notes
            logger.warning("Meeting stage failed", metadata: [
                "meetingID": meetingID.uuidString,
                "stage": stage == .transcription ? "transcription" : "notes",
                "attempt": String(attempt.attemptCount),
                "failureCategory": failure.category.rawValue
            ])
        } catch {
            if var record = try? await store.loadRecord(id: meetingID) {
                switch stage {
                case .transcription:
                    record.transcription.status = .failed
                    record.transcription.finishedAt = Date()
                    record.transcription.failure = .saveFailed
                case .notes:
                    record.notes.status = .failed
                    record.notes.finishedAt = Date()
                    record.notes.failure = .saveFailed
                }
                await onUpdate(record)
            }
            logger.error("Meeting failure transition could not be persisted", metadata: [
                "meetingID": meetingID.uuidString,
                "stage": stage == .transcription ? "transcription" : "notes"
            ], error: error)
        }
    }

    private func nextAttempt(from previous: MeetingStageAttempt, attemptID: UUID) -> MeetingStageAttempt {
        MeetingStageAttempt(
            status: .processing,
            attemptID: attemptID,
            attemptCount: previous.attemptCount + 1,
            requestCount: 1,
            startedAt: Date(),
            finishedAt: nil,
            failure: nil
        )
    }

    private func logTransition(stage: String, status: String, record: MeetingRecord) {
        let attempt = stage == "transcription" ? record.transcription : record.notes
        var metadata = [
            "meetingID": record.id.uuidString,
            "stage": stage,
            "status": status,
            "attempt": String(attempt.attemptCount)
        ]
        if stage == "notes" {
            metadata["modelID"] = OpenAIMeetingNotesService.model
        }
        if let startedAt = attempt.startedAt {
            let end = attempt.finishedAt ?? Date()
            metadata["durationSeconds"] = String(max(0, end.timeIntervalSince(startedAt)))
        }
        logger.info("Meeting stage transition", metadata: metadata)
    }

    private func failure(from error: Error) -> MeetingFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? MeetingFailure { return failure }
        if let notesError = error as? MeetingNotesError {
            switch notesError {
            case .timeout: return MeetingFailure(category: .timeout, message: "Meeting-note generation timed out. Retry notes.")
            case .transcriptTooLong: return MeetingFailure(category: .transcriptTooLong, message: "This transcript is too long for meeting-note generation in this version of Wisper.")
            case .responseTruncated: return MeetingFailure(category: .responseTruncated, message: "OpenAI truncated the meeting notes twice. Retry notes.")
            case .emptyTranscript: return MeetingFailure(category: .emptyTranscript, message: "The raw transcript is empty.")
            default: return MeetingFailure(category: .invalidResponse, message: "OpenAI returned invalid meeting notes. Retry notes.")
            }
        }
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .unsupportedAudioFileType, .audioNormalizationUnsupported:
                return MeetingFailure(category: .audioUnsupported, message: "This audio format could not be prepared for transcription.")
            case .audioTooLarge:
                return MeetingFailure(category: .audioTooLarge, message: "This audio could not be split below the upload limit.")
            case .emptyResult:
                return MeetingFailure(category: .emptyTranscript, message: "No speech was recognized. Retry transcription.")
            }
        }
        let nsError = error as NSError
        if nsError.code == 401 {
            return MeetingFailure(category: .authentication, message: "OpenAI rejected the API key. Update it in Settings.")
        }
        if nsError.code == 429 {
            return MeetingFailure(category: .rateLimit, message: "OpenAI is rate limiting requests. Retry this stage later.")
        }
        if nsError.code == 404 {
            return MeetingFailure(category: .modelUnavailable, message: "The meeting-notes model is unavailable. Update Wisper.")
        }
        if nsError.domain == NSURLErrorDomain {
            return MeetingFailure(category: .network, message: "A network error interrupted processing. Retry this stage.")
        }
        if error is MeetingStorageError || nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return .saveFailed
        }
        return MeetingFailure(category: .unknown, message: "Processing failed. Retry this stage.")
    }
}

@MainActor
final class MeetingOperationCoordinator: ObservableObject {
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var bootstrapState: MeetingBootstrapState = .preparing
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var isCapturing = false
    @Published private(set) var isProcessing = false
    @Published private(set) var recoveryMessage: String?

    private let recorder: any MeetingRecording
    private let store: any MeetingHistoryStoring
    private let pipeline: MeetingProcessingPipeline
    private let lease: MeetingLease
    private let logger: LocalLogger
    private var activeTask: Task<Void, Never>?
    private var activeCaptureMode: RecordingCaptureMode?
    private var activeStagingURL: URL?
    private var metadataMutationIDs: Set<UUID> = []

    init(
        recorder: any MeetingRecording,
        store: any MeetingHistoryStoring,
        transcriber: any MeetingTranscribing,
        notesGenerator: any MeetingNotesGenerating,
        lease: MeetingLease = MeetingLease(),
        logger: LocalLogger = .shared
    ) {
        self.recorder = recorder
        self.store = store
        self.logger = logger
        pipeline = MeetingProcessingPipeline(
            store: store,
            transcriber: transcriber,
            notesGenerator: notesGenerator,
            logger: logger
        )
        self.lease = lease
    }

    var canSafelyTerminate: Bool {
        bootstrapState == .ready && activeMeetingID == nil && isProcessing == false && isCapturing == false
    }

    func bootstrap() async {
        bootstrapState = .preparing
        let startedAt = Date()
#if DEBUG
        if let delay = ProcessInfo.processInfo.environment["WISPER_UI_TEST_BOOTSTRAP_DELAY_MS"].flatMap(Int.init),
           delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
#endif
        do {
            let result = try await store.bootstrap()
            records = result.records
            let recoveryMessages = [
                result.quarantinedRecordCount > 0
                    ? "Some damaged meeting records were quarantined."
                    : nil,
                result.staleTrashCount > 0
                    ? "Some previously removed meeting files could not be cleaned up for more than seven days."
                    : nil
            ].compactMap { $0 }
            recoveryMessage = recoveryMessages.isEmpty ? nil : recoveryMessages.joined(separator: " ")
            bootstrapState = .ready
            logger.info("Meeting history bootstrap completed", metadata: [
                "durationSeconds": String(Date().timeIntervalSince(startedAt)),
                "recordCount": String(result.records.count),
                "migratedRecordCount": String(result.migratedRecordCount),
                "quarantinedRecordCount": String(result.quarantinedRecordCount),
                "staleTrashCount": String(result.staleTrashCount)
            ])
        } catch {
            bootstrapState = .failed("Meeting history could not be prepared. Try again.")
            logger.warning("Meeting history bootstrap failed", metadata: [
                "durationSeconds": String(Date().timeIntervalSince(startedAt))
            ], error: error)
        }
    }

    func startCapture(mode: RecordingCaptureMode, audioSourceID: String?) async throws {
        guard bootstrapState == .ready else { throw MeetingCoordinatorError.bootstrapIncomplete }
        let meetingID = UUID()
        guard await lease.acquire(for: meetingID) else {
            throw MeetingCoordinatorError.anotherMeetingActive(await lease.activeMeetingID ?? meetingID)
        }
        activeMeetingID = meetingID
        activeCaptureMode = mode
        do {
            let stagingURL = try await store.createStagingDirectory(meetingID: meetingID)
            activeStagingURL = stagingURL
            try await recorder.start(
                captureMode: mode,
                audioSourceID: audioSourceID,
                outputDirectory: stagingURL
            )
            isCapturing = true
        } catch {
            try? await store.discardStagedMeeting(id: meetingID)
            activeMeetingID = nil
            activeCaptureMode = nil
            activeStagingURL = nil
            await lease.release(for: meetingID)
            throw error
        }
    }

    func stopCaptureAndProcess(apiKey: String, chunkSeconds: Int?) async throws {
        guard apiKey.isEmpty == false else { throw MeetingCoordinatorError.missingAPIKey }
        guard let meetingID = activeMeetingID,
              let captureMode = activeCaptureMode,
              let stagingURL = activeStagingURL,
              isCapturing else {
            throw MeetingCoordinatorError.noActiveCapture
        }
        let finalizationStartedAt = Date()
        guard let transcriptionURL = try await recorder.stop(discarding: false) else {
            throw MeetingCoordinatorError.noActiveCapture
        }
        logger.info("Meeting capture finalized", metadata: [
            "meetingID": meetingID.uuidString,
            "durationSeconds": String(Date().timeIntervalSince(finalizationStartedAt))
        ])
        isCapturing = false

        do {
            let persistenceStartedAt = Date()
            let record = try await persistCapture(
                meetingID: meetingID,
                captureMode: captureMode,
                staged: stagingURL,
                transcriptionURL: transcriptionURL,
                title: nil,
                durationSeconds: recorder.lastDurationSeconds
            )
            logger.info("Meeting capture persisted", metadata: [
                "meetingID": meetingID.uuidString,
                "durationSeconds": String(Date().timeIntervalSince(persistenceStartedAt))
            ])
            upsert(record)
            startPipeline(meetingID: meetingID, apiKey: apiKey, chunkSeconds: chunkSeconds, beginWithTranscription: true)
        } catch {
            try? await store.discardStagedMeeting(id: meetingID)
            activeMeetingID = nil
            activeCaptureMode = nil
            activeStagingURL = nil
            await lease.release(for: meetingID)
            throw error
        }
    }

    func discardCapture() async throws {
        guard let meetingID = activeMeetingID, isCapturing else {
            throw MeetingCoordinatorError.noActiveCapture
        }
        try await recorder.discard()
        try await store.discardStagedMeeting(id: meetingID)
        isCapturing = false
        activeMeetingID = nil
        activeCaptureMode = nil
        activeStagingURL = nil
        await lease.release(for: meetingID)
    }

    func pauseCapture() throws {
        guard isCapturing, recorder.canPause else { throw MeetingCoordinatorError.invalidTransition }
        recorder.pause()
    }

    func resumeCapture() throws {
        guard isCapturing else { throw MeetingCoordinatorError.invalidTransition }
        recorder.resume()
    }

    func restartCapture(mode: RecordingCaptureMode, audioSourceID: String?) async throws {
        guard let meetingID = activeMeetingID,
              isCapturing,
              await lease.validate(owner: meetingID) else {
            throw MeetingCoordinatorError.noActiveCapture
        }
        try await recorder.discard()
        isCapturing = false
        do {
            try await store.discardStagedMeeting(id: meetingID)
            let stagingURL = try await store.createStagingDirectory(meetingID: meetingID)
            activeStagingURL = stagingURL
            try await recorder.restart(
                captureMode: mode,
                audioSourceID: audioSourceID,
                outputDirectory: stagingURL
            )
            activeCaptureMode = mode
            isCapturing = true
        } catch {
            try? await store.discardStagedMeeting(id: meetingID)
            activeMeetingID = nil
            activeCaptureMode = nil
            activeStagingURL = nil
            await lease.release(for: meetingID)
            throw error
        }
    }

    func retryTranscription(meetingID: UUID, apiKey: String, chunkSeconds: Int?) async throws {
        guard bootstrapState == .ready else { throw MeetingCoordinatorError.bootstrapIncomplete }
        guard metadataMutationIDs.contains(meetingID) == false else {
            throw MeetingCoordinatorError.meetingMetadataBusy
        }
        let record = try await store.loadRecord(id: meetingID)
        guard record.transcription.status == .failed
                || record.transcription.status == .completed
                || record.transcription.status == .processing else {
            throw MeetingCoordinatorError.invalidTransition
        }
        try await acquireAndStart(meetingID: meetingID, apiKey: apiKey, chunkSeconds: chunkSeconds, beginWithTranscription: true)
    }

    func importAndProcess(sourceURL: URL, apiKey: String, chunkSeconds: Int?) async throws {
        guard bootstrapState == .ready else { throw MeetingCoordinatorError.bootstrapIncomplete }
        guard apiKey.isEmpty == false else { throw MeetingCoordinatorError.missingAPIKey }
        let meetingID = UUID()
        guard await lease.acquire(for: meetingID) else {
            throw MeetingCoordinatorError.anotherMeetingActive(await lease.activeMeetingID ?? meetingID)
        }
        activeMeetingID = meetingID
        do {
            let stagingURL = try await store.createStagingDirectory(meetingID: meetingID)
            activeStagingURL = stagingURL
            let imported = try await recorder.importAudioFile(from: sourceURL, outputDirectory: stagingURL)
            let record = try await persistCapture(
                meetingID: meetingID,
                captureMode: .microphone,
                staged: stagingURL,
                transcriptionURL: imported.url,
                title: sourceURL.deletingPathExtension().lastPathComponent,
                durationSeconds: imported.durationSeconds
            )
            upsert(record)
            startPipeline(meetingID: meetingID, apiKey: apiKey, chunkSeconds: chunkSeconds, beginWithTranscription: true)
        } catch {
            try? await store.discardStagedMeeting(id: meetingID)
            activeMeetingID = nil
            activeStagingURL = nil
            await lease.release(for: meetingID)
            throw error
        }
    }

    func retryNotes(meetingID: UUID, apiKey: String) async throws {
        guard bootstrapState == .ready else { throw MeetingCoordinatorError.bootstrapIncomplete }
        guard metadataMutationIDs.contains(meetingID) == false else {
            throw MeetingCoordinatorError.meetingMetadataBusy
        }
        let record = try await store.loadRecord(id: meetingID)
        guard record.transcription.status == .completed,
              record.notes.status == .failed
                || record.notes.status == .completed
                || record.notes.status == .processing else {
            throw MeetingCoordinatorError.invalidTransition
        }
        try await acquireAndStart(meetingID: meetingID, apiKey: apiKey, chunkSeconds: nil, beginWithTranscription: false)
    }

    func cancelProcessing() {
        activeTask?.cancel()
    }

    func removeMeeting(id: UUID) async throws {
        guard metadataMutationIDs.contains(id) == false else {
            throw MeetingCoordinatorError.meetingMetadataBusy
        }
        guard activeMeetingID != id else { throw MeetingCoordinatorError.invalidTransition }
        guard activeMeetingID == nil, isProcessing == false, isCapturing == false else {
            throw MeetingCoordinatorError.anotherMeetingActive(activeMeetingID ?? id)
        }
        isProcessing = true
        defer { isProcessing = false }
        try await store.removeMeeting(id: id)
        records.removeAll { $0.id == id }
    }

    func renameMeeting(id: UUID, title: String) async throws -> MeetingRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { throw MeetingCoordinatorError.invalidMeetingTitle }
        guard activeMeetingID != id else { throw MeetingCoordinatorError.invalidTransition }
        guard metadataMutationIDs.insert(id).inserted else {
            throw MeetingCoordinatorError.meetingMetadataBusy
        }
        defer { metadataMutationIDs.remove(id) }

        let committed = try await store.updateTitle(trimmedTitle, meetingID: id)
        upsert(committed)
        return committed
    }

    func loadTranscript(for record: MeetingRecord) async throws -> String? {
        guard let reference = record.transcriptArtifact else { return nil }
        return try await store.loadTranscript(reference, meetingID: record.id)
    }

    func loadNotes(for record: MeetingRecord) async throws -> MeetingNotes? {
        guard let reference = record.lastValidNotesArtifact else { return nil }
        return try await store.loadNotes(reference, meetingID: record.id)
    }

    func audioURL(for record: MeetingRecord) async throws -> URL {
        try await store.artifactURL(record.captureArtifacts.transcriptionInput, meetingID: record.id)
    }

    private func acquireAndStart(
        meetingID: UUID,
        apiKey: String,
        chunkSeconds: Int?,
        beginWithTranscription: Bool
    ) async throws {
        guard apiKey.isEmpty == false else { throw MeetingCoordinatorError.missingAPIKey }
        guard await lease.acquire(for: meetingID) else {
            throw MeetingCoordinatorError.anotherMeetingActive(await lease.activeMeetingID ?? meetingID)
        }
        activeMeetingID = meetingID
        startPipeline(
            meetingID: meetingID,
            apiKey: apiKey,
            chunkSeconds: chunkSeconds,
            beginWithTranscription: beginWithTranscription
        )
    }

    private func startPipeline(
        meetingID: UUID,
        apiKey: String,
        chunkSeconds: Int?,
        beginWithTranscription: Bool
    ) {
        guard activeTask == nil else { return }
        isProcessing = true
        activeTask = Task { [weak self] in
            guard let self else { return }
            await pipeline.process(
                meetingID: meetingID,
                apiKey: apiKey,
                chunkSeconds: chunkSeconds,
                beginWithTranscription: beginWithTranscription
            ) { [weak self] record in
                self?.upsert(record)
            }
            await finishPipeline(meetingID: meetingID)
        }
    }

    private func finishPipeline(meetingID: UUID) async {
        activeTask = nil
        isProcessing = false
        activeMeetingID = nil
        activeCaptureMode = nil
        activeStagingURL = nil
        await lease.release(for: meetingID)
    }

    private func persistCapture(
        meetingID: UUID,
        captureMode: RecordingCaptureMode,
        staged: URL,
        transcriptionURL: URL,
        title: String?,
        durationSeconds: TimeInterval?
    ) async throws -> MeetingRecord {
        let artifacts = recorder.lastCaptureArtifacts

        func referenceForStagedFile(_ source: URL) throws -> MeetingArtifactReference {
            let parent = source.deletingLastPathComponent().standardizedFileURL
            guard parent == staged.standardizedFileURL,
                  FileManager.default.fileExists(atPath: source.path) else {
                throw MeetingStorageError.invalidStagedRecord
            }
            return try MeetingArtifactReference(source.lastPathComponent)
        }

        let microphone: MeetingArtifactReference?
        let systemAudio: MeetingArtifactReference?
        let transcriptionInput: MeetingArtifactReference
        if let artifacts {
            microphone = try artifacts.microphoneURL.map(referenceForStagedFile)
            systemAudio = try referenceForStagedFile(artifacts.systemAudioURL)
            if artifacts.transcriptionInputURL == artifacts.systemAudioURL {
                transcriptionInput = systemAudio!
            } else {
                transcriptionInput = try referenceForStagedFile(artifacts.transcriptionInputURL)
            }
        } else {
            let reference = try referenceForStagedFile(transcriptionURL)
            microphone = reference
            systemAudio = nil
            transcriptionInput = reference
        }

        let now = Date()
        let record = MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: meetingID,
            title: title ?? "Meeting \(now.formatted(date: .abbreviated, time: .shortened))",
            createdAt: now,
            updatedAt: now,
            durationSeconds: durationSeconds,
            captureMode: captureMode,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: microphone,
                systemAudio: systemAudio,
                transcriptionInput: transcriptionInput
            ),
            transcription: .notStarted,
            transcriptArtifact: nil,
            notes: .notStarted,
            lastValidNotesArtifact: nil,
            notesProvenance: nil
        )
        try await store.promoteStagedMeeting(record)
        return record
    }

    private func upsert(_ record: MeetingRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.createdAt > $1.createdAt }
    }
}
