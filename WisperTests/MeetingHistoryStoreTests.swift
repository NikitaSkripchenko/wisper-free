import Foundation
import XCTest
@testable import Wisper

final class MeetingHistoryStoreTests: XCTestCase {
    func testPromotesRecordAndLoadsPayloadsLazily() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let record = try makeRecord()
        let staged = try await store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))

        try await store.promoteStagedMeeting(record)
        let transcriptReference = try await store.saveTranscript(
            "A grounded transcript.",
            meetingID: record.id,
            attemptID: UUID()
        )
        let notes = MeetingNotes(
            summaryPoints: [.init(text: "Summary", evidence: "grounded transcript")],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
        let notesReference = try await store.saveNotes(notes, meetingID: record.id, attemptID: UUID())

        let loadedTranscript = try await store.loadTranscript(transcriptReference, meetingID: record.id)
        let loadedNotes = try await store.loadNotes(notesReference, meetingID: record.id)
        let loadedRecord = try await store.loadRecord(id: record.id)
        XCTAssertEqual(loadedTranscript, "A grounded transcript.")
        XCTAssertEqual(loadedNotes, notes)
        XCTAssertEqual(loadedRecord, record)
    }

    func testBootstrapRecoversInterruptedStagesAndCleansTemporaryDirectories() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        var record = try makeRecord()
        record.transcription = MeetingStageAttempt(
            status: .processing,
            attemptID: UUID(),
            attemptCount: 1,
            requestCount: 1,
            startedAt: Date(),
            finishedAt: nil,
            failure: nil
        )
        let staged = try await store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await store.promoteStagedMeeting(record)

        let abandonedID = UUID()
        let abandoned = try await store.createStagingDirectory(meetingID: abandonedID)
        try Data("partial".utf8).write(to: abandoned.appending(path: "partial.m4a"))
        let orphan = fixture.root
            .appending(path: record.id.uuidString)
            .appending(path: "transcript-orphan.txt")
        try Data("uncommitted".utf8).write(to: orphan)

        let result = try await store.bootstrap()

        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.transcription.status, .failed)
        XCTAssertEqual(result.records.first?.transcription.failure, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testBootstrapQuarantinesCorruptRecordWithoutBlockingHealthyRecords() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let record = try makeRecord()
        let staged = try await store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await store.promoteStagedMeeting(record)

        let corruptDirectory = fixture.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptDirectory.appending(path: "record.json"))

        let result = try await store.bootstrap()

        XCTAssertEqual(result.records, [record])
        XCTAssertEqual(result.quarantinedRecordCount, 1)
    }

    func testLegacyMigrationPreservesIdentityAndTranscript() async throws {
        let fixture = try StoreFixture()
        let legacy = Transcript(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            originalName: "Legacy recording",
            audioPath: nil,
            durationSeconds: 12,
            status: .completed,
            transcriptionText: "Legacy text",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.wisper.encode([legacy]).write(to: fixture.legacyHistory)

        let result = try await fixture.store.bootstrap()
        let migrated = try XCTUnwrap(result.records.first)
        let transcriptReference = try XCTUnwrap(migrated.transcriptArtifact)

        XCTAssertEqual(result.migratedRecordCount, 1)
        XCTAssertEqual(migrated.id, legacy.id)
        XCTAssertEqual(migrated.createdAt, legacy.createdAt)
        let loadedTranscript = try await fixture.store.loadTranscript(transcriptReference, meetingID: migrated.id)
        XCTAssertEqual(loadedTranscript, "Legacy text")

        let secondBootstrap = try await fixture.store.bootstrap()
        XCTAssertEqual(secondBootstrap.migratedRecordCount, 0)
        XCTAssertEqual(secondBootstrap.records.map(\.id), [legacy.id])
        let audioURL = try await fixture.store.artifactURL(
            migrated.captureArtifacts.transcriptionInput,
            meetingID: migrated.id
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testCorruptLegacyHistoryAbortsMigrationAndLeavesOriginalUntouched() async throws {
        let fixture = try StoreFixture()
        try Data("not-json".utf8).write(to: fixture.legacyHistory)

        do {
            _ = try await fixture.store.bootstrap()
            XCTFail("Expected migration to fail")
        } catch {
            XCTAssertEqual(error as? MeetingStorageError, .legacyMigrationFailed)
            XCTAssertEqual(try Data(contentsOf: fixture.legacyHistory), Data("not-json".utf8))
        }
    }

    func testWholeRootMigrationResumesAfterPromotionRenameFailure() async throws {
        let fixture = try StoreFixture()
        let legacy = Transcript(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            originalName: "Legacy",
            audioPath: nil,
            durationSeconds: nil,
            status: .completed,
            transcriptionText: "Retained legacy text",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.wisper.encode([legacy]).write(to: fixture.legacyHistory)
        let faultingStore = MeetingHistoryStore(
            rootURL: fixture.root,
            legacyHistoryURL: fixture.legacyHistory,
            faultInjector: { $0 == .promotionRename ? StoreFault.injected : nil }
        )

        do {
            _ = try await faultingStore.bootstrap()
            XCTFail("Expected root promotion to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyHistory.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.root.appending(path: legacy.id.uuidString).path
            ))
        }

        let recovered = try await fixture.store.bootstrap()
        XCTAssertEqual(recovered.records.map(\.id), [legacy.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyHistory.path))
    }

    func testLegacyMigrationOwnsCopyAndRetiresOnlyAppOwnedSourceAudio() async throws {
        let fixture = try StoreFixture()
        let recordings = fixture.container.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let ownedAudio = recordings.appending(path: "legacy.m4a")
        let externalAudio = fixture.container.deletingLastPathComponent().appending(path: "external-\(UUID()).m4a")
        try Data("owned".utf8).write(to: ownedAudio)
        try Data("external".utf8).write(to: externalAudio)
        defer { try? FileManager.default.removeItem(at: externalAudio) }
        let owned = Transcript(
            originalName: "Owned",
            audioPath: ownedAudio.path,
            durationSeconds: 1,
            status: .completed,
            transcriptionText: "Owned transcript"
        )
        let external = Transcript(
            originalName: "External",
            audioPath: externalAudio.path,
            durationSeconds: 1,
            status: .processing,
            transcriptionText: "External transcript"
        )
        try JSONEncoder.wisper.encode([owned, external]).write(to: fixture.legacyHistory)

        let result = try await fixture.store.bootstrap()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalAudio.path))
        XCTAssertEqual(result.records.first(where: { $0.id == external.id })?.transcription.status, .failed)
        XCTAssertEqual(
            result.records.first(where: { $0.id == external.id })?.transcription.failure?.category,
            .interrupted
        )
        for record in result.records {
            if let microphone = record.captureArtifacts.microphone {
                let copied = try await fixture.store.artifactURL(microphone, meetingID: record.id)
                XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
            }
        }
    }

    func testRemoveMakesMeetingImmediatelyInvisible() async throws {
        let fixture = try StoreFixture()
        let record = try makeRecord()
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await fixture.store.promoteStagedMeeting(record)

        try await fixture.store.removeMeeting(id: record.id)

        let result = try await fixture.store.bootstrap()
        XCTAssertTrue(result.records.isEmpty)
        do {
            _ = try await fixture.store.loadRecord(id: record.id)
            XCTFail("Expected the removed meeting to be unavailable")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testPromotionFaultsNeverExposeARecordWithoutItsCapture() async throws {
        let boundaries: [MeetingStorageBoundary] = [
            .stagedWrite, .fileSync, .atomicReplace, .directorySync, .promotionRename
        ]
        for boundary in boundaries {
            let fixture = try StoreFixture()
            let store = MeetingHistoryStore(
                rootURL: fixture.root,
                legacyHistoryURL: fixture.legacyHistory,
                faultInjector: { $0 == boundary ? StoreFault.injected : nil }
            )
            let record = try makeRecord()
            let staged = try await store.createStagingDirectory(meetingID: record.id)
            try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))

            do {
                try await store.promoteStagedMeeting(record)
                XCTFail("Expected \(boundary) to fail")
            } catch {
                let visible = fixture.root.appending(path: record.id.uuidString, directoryHint: .isDirectory)
                XCTAssertFalse(FileManager.default.fileExists(atPath: visible.path))
            }
        }
    }

    func testAtomicReplacementFaultRetainsAValidCommittedRecord() async throws {
        for boundary in [MeetingStorageBoundary.stagedWrite, .fileSync, .atomicReplace, .directorySync] {
            let fixture = try StoreFixture()
            var original = try makeRecord()
            let staged = try await fixture.store.createStagingDirectory(meetingID: original.id)
            try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
            try await fixture.store.promoteStagedMeeting(original)
            let faultingStore = MeetingHistoryStore(
                rootURL: fixture.root,
                legacyHistoryURL: fixture.legacyHistory,
                faultInjector: { $0 == boundary ? StoreFault.injected : nil }
            )
            original.title = "Updated title"

            do {
                try await faultingStore.saveRecord(original)
                XCTFail("Expected \(boundary) to fail")
            } catch {
                let loaded = try await fixture.store.loadRecord(id: original.id)
                XCTAssertEqual(loaded.id, original.id)
                XCTAssertTrue(["Planning call", "Updated title"].contains(loaded.title))
            }
        }
    }

    func testTitleUpdateTrimsAndPreservesEveryOtherField() async throws {
        let fixture = try StoreFixture()
        var record = try makeRecord()
        record.transcription.status = .completed
        record.transcription.attemptCount = 2
        record.transcriptArtifact = try MeetingArtifactReference("transcript.txt")
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try Data("transcript".utf8).write(to: staged.appending(path: "transcript.txt"))
        try await fixture.store.promoteStagedMeeting(record)

        let committed = try await fixture.store.updateTitle("  Weekly café ☕️  ", meetingID: record.id)

        XCTAssertEqual(committed.title, "Weekly café ☕️")
        XCTAssertGreaterThan(committed.updatedAt, record.updatedAt)
        var expected = record
        expected.title = committed.title
        expected.updatedAt = committed.updatedAt
        XCTAssertEqual(committed, expected)
        let reloaded = try await fixture.store.loadRecord(id: record.id)
        XCTAssertEqual(reloaded, committed)
    }

    func testTitleUpdateRejectsEmptyAndAtomicFailureKeepsOldTitle() async throws {
        let fixture = try StoreFixture()
        let record = try makeRecord()
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await fixture.store.promoteStagedMeeting(record)

        do {
            _ = try await fixture.store.updateTitle(" \n ", meetingID: record.id)
            XCTFail("Expected an empty title to fail")
        } catch {
            XCTAssertEqual(error as? MeetingStorageError, .invalidTitle)
        }

        let faultingStore = MeetingHistoryStore(
            rootURL: fixture.root,
            legacyHistoryURL: fixture.legacyHistory,
            faultInjector: { $0 == .atomicReplace ? StoreFault.injected : nil }
        )
        do {
            _ = try await faultingStore.updateTitle("New title", meetingID: record.id)
            XCTFail("Expected atomic replacement to fail")
        } catch {
            XCTAssertEqual(error as? StoreFault, .injected)
        }
        let retained = try await fixture.store.loadRecord(id: record.id)
        XCTAssertEqual(retained.title, record.title)
    }

    func testTombstoneRenameFaultLeavesMeetingVisible() async throws {
        let fixture = try StoreFixture()
        let record = try makeRecord()
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await fixture.store.promoteStagedMeeting(record)
        let faultingStore = MeetingHistoryStore(
            rootURL: fixture.root,
            legacyHistoryURL: fixture.legacyHistory,
            faultInjector: { $0 == .tombstoneRename ? StoreFault.injected : nil }
        )

        do {
            try await faultingStore.removeMeeting(id: record.id)
            XCTFail("Expected tombstone movement to fail")
        } catch {
            let loaded = try await fixture.store.loadRecord(id: record.id)
            XCTAssertEqual(loaded, record)
        }
    }

    func testTrashDeletionFailureOlderThanSevenDaysIsReported() async throws {
        let fixture = try StoreFixture()
        let record = try makeRecord()
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await fixture.store.promoteStagedMeeting(record)
        let faultingStore = MeetingHistoryStore(
            rootURL: fixture.root,
            legacyHistoryURL: fixture.legacyHistory,
            faultInjector: { $0 == .trashDelete ? StoreFault.injected : nil }
        )

        try await faultingStore.removeMeeting(id: record.id)
        let trash = fixture.root.appending(path: ".trash", directoryHint: .isDirectory)
        let tombstone = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: tombstone.path
        )

        let result = try await faultingStore.bootstrap()

        XCTAssertEqual(result.staleTrashCount, 1)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testArtifactReferenceRejectsTraversalAndAbsolutePaths() {
        XCTAssertNil(MeetingArtifactReference(rawValue: "../secret"))
        XCTAssertNil(MeetingArtifactReference(rawValue: "/tmp/secret"))
        XCTAssertNotNil(MeetingArtifactReference(rawValue: "transcript-attempt.txt"))
    }

    private func makeRecord(id: UUID = UUID()) throws -> MeetingRecord {
        MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: id,
            title: "Planning call",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            durationSeconds: 60,
            captureMode: .microphone,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: try MeetingArtifactReference("audio.m4a"),
                systemAudio: nil,
                transcriptionInput: try MeetingArtifactReference("audio.m4a")
            ),
            transcription: .notStarted,
            transcriptArtifact: nil,
            notes: .notStarted,
            lastValidNotesArtifact: nil,
            notesProvenance: nil
        )
    }
}

final class MeetingHistoryMetadataPresenterTests: XCTestCase {
    func testMatchesTitleAndDisplayedDateCaseAndDiacriticInsensitively() throws {
        let presenter = makePresenter()
        var record = try makeRecordForSearch()
        record.title = "Café Planning"

        XCTAssertTrue(presenter.matches(record, query: "CAFE"))
        let displayedDate = presenter.dateText(for: record)
        XCTAssertTrue(presenter.matches(record, query: displayedDate))
        XCTAssertFalse(presenter.matches(record, query: "quarterly review"))
    }

    func testEmptyQueryReturnsAllRecordsWithoutArtifactAccess() throws {
        let presenter = makePresenter()
        let records = [try makeRecordForSearch(), try makeRecordForSearch()]

        XCTAssertEqual(presenter.filter(records, query: " \n ").map(\.id), records.map(\.id))
        XCTAssertTrue(presenter.filter(records, query: "missing").isEmpty)
    }

    func testDisplayedDateIsDeterministicForInjectedEnvironment() throws {
        let presenter = makePresenter()
        let record = try makeRecordForSearch()

        XCTAssertEqual(presenter.dateText(for: record), "Jan 1 at 12:00\u{202F}AM")
    }

    func testFilteringTenThousandMetadataRecords() throws {
        let presenter = makePresenter()
        let template = try makeRecordForSearch()
        let records = (0..<10_000).map { index in
            var record = template
            record.title = "Meeting \(index)"
            return record
        }

        measure(metrics: [XCTClockMetric()]) {
            XCTAssertEqual(presenter.filter(records, query: "Meeting 9999").count, 1)
        }
    }

    private func makePresenter() -> MeetingHistoryMetadataPresenter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MeetingHistoryMetadataPresenter(
            locale: Locale(identifier: "en_US_POSIX"),
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func makeRecordForSearch() throws -> MeetingRecord {
        MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: UUID(),
            title: "Planning",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            captureMode: .microphone,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: nil,
                systemAudio: nil,
                transcriptionInput: try MeetingArtifactReference("audio.m4a")
            ),
            transcription: .notStarted,
            transcriptArtifact: nil,
            notes: .notStarted,
            lastValidNotesArtifact: nil,
            notesProvenance: nil
        )
    }
}

private enum StoreFault: Error, Equatable {
    case injected
}

private struct StoreFixture {
    let container: URL
    let root: URL
    let legacyHistory: URL
    let store: MeetingHistoryStore

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appending(path: "WisperMeetingStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = container.appending(path: "Meetings", directoryHint: .isDirectory)
        legacyHistory = container.appending(path: "history.json")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        store = MeetingHistoryStore(rootURL: root, legacyHistoryURL: legacyHistory)
    }
}
