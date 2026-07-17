import Foundation
import XCTest
@testable import Wisper

@MainActor
final class MeetingProcessingCoordinatorTests: XCTestCase {
    func testCaptureAutomaticallyProgressesThroughTranscriptAndNotes() async throws {
        let fixture = try CoordinatorFixture()
        let recorder = FakeMeetingRecorder(outputURL: fixture.audioURL)
        let coordinator = MeetingOperationCoordinator(
            recorder: recorder,
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "The team decided to ship Friday."),
            notesGenerator: StubMeetingNotesGenerator()
        )
        XCTAssertFalse(coordinator.canSafelyTerminate)
        await coordinator.bootstrap()
        XCTAssertTrue(coordinator.canSafelyTerminate)

        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        XCTAssertFalse(coordinator.canSafelyTerminate)
        let activeID = try XCTUnwrap(coordinator.activeMeetingID)
        let stagedAudio = fixture.container
            .appending(path: "Meetings/.tmp/\(activeID.uuidString)/microphone.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedAudio.path))
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        XCTAssertFalse(coordinator.canSafelyTerminate)
        try await waitUntil { coordinator.canSafelyTerminate }

        let record = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(record.displayState, .complete)
        XCTAssertEqual(record.transcription.attemptCount, 1)
        XCTAssertEqual(record.notes.attemptCount, 1)
        let transcript = try await coordinator.loadTranscript(for: record)
        let notes = try await coordinator.loadNotes(for: record)
        XCTAssertNotNil(transcript)
        XCTAssertNotNil(notes)
    }

    func testSecondCaptureIsRejectedWhileLeaseIsHeld() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "Transcript"),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)

        do {
            try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
            XCTFail("Expected the process-wide lease to reject a second capture")
        } catch let error as MeetingCoordinatorError {
            guard case .anotherMeetingActive = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await coordinator.discardCapture()
        XCTAssertTrue(coordinator.canSafelyTerminate)
    }

    func testCancellationPersistsFailedStageAndKeepsCapture() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: BlockingMeetingTranscriber(),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.records.first?.transcription.status == .processing }

        coordinator.cancelProcessing()
        try await waitUntil { coordinator.canSafelyTerminate }

        let record = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(record.transcription.status, .failed)
        XCTAssertEqual(record.transcription.failure?.category, .cancelled)
        let audioURL = try await coordinator.audioURL(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRetryNotesDoesNotRetranscribe() async throws {
        let fixture = try CoordinatorFixture()
        let transcriber = CountingMeetingTranscriber(text: "The team decided to ship Friday.")
        let notesGenerator = FailOnceMeetingNotesGenerator()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: transcriber,
            notesGenerator: notesGenerator
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }

        let failed = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(failed.notes.status, .failed)
        let callsBeforeRetry = await transcriber.callCount
        XCTAssertEqual(callsBeforeRetry, 1)

        try await coordinator.retryNotes(meetingID: failed.id, apiKey: "key")
        try await waitUntil { coordinator.canSafelyTerminate }

        let completed = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(completed.notes.status, .completed)
        XCTAssertEqual(completed.transcription.attemptCount, 1)
        XCTAssertEqual(completed.notes.attemptCount, 2)
        let callsAfterRetry = await transcriber.callCount
        XCTAssertEqual(callsAfterRetry, 1)
    }

    func testCancellationRejectsLateTranscriptionSuccess() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: CancellationIgnoringTranscriber(),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.records.first?.transcription.status == .processing }

        coordinator.cancelProcessing()
        try await waitUntil { coordinator.canSafelyTerminate }

        let record = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(record.transcription.status, .failed)
        XCTAssertEqual(record.transcription.failure?.category, .cancelled)
        XCTAssertNil(record.transcriptArtifact)
        XCTAssertEqual(record.notes.status, .notStarted)
    }

    func testImportAutomaticallyRunsTheSamePipeline() async throws {
        let fixture = try CoordinatorFixture()
        let source = fixture.container.appending(path: "import-source.m4a")
        try Data("imported audio".utf8).write(to: source)
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "Imported transcript"),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()

        try await coordinator.importAndProcess(sourceURL: source, apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }

        let record = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(record.title, "import-source")
        XCTAssertEqual(record.displayState, .complete)
        let transcript = try await coordinator.loadTranscript(for: record)
        XCTAssertEqual(transcript, "Imported transcript")
    }

    func testRestartKeepsLeaseAndPauseRespectsRecorderCapability() async throws {
        let fixture = try CoordinatorFixture()
        let recorder = FakeMeetingRecorder(outputURL: fixture.audioURL, canPause: false)
        let coordinator = MeetingOperationCoordinator(
            recorder: recorder,
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "Transcript"),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .systemAudio, audioSourceID: nil)

        XCTAssertThrowsError(try coordinator.pauseCapture())
        try await coordinator.restartCapture(mode: .systemAudio, audioSourceID: nil)
        XCTAssertEqual(recorder.restartCount, 1)
        do {
            try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
            XCTFail("Expected restart to keep the existing lease")
        } catch let error as MeetingCoordinatorError {
            guard case .anotherMeetingActive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try await coordinator.discardCapture()
    }

    func testFailedRetranscriptionRetainsLastValidTranscriptAndNotes() async throws {
        let fixture = try CoordinatorFixture()
        let transcriber = SuccessThenFailureTranscriber()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: transcriber,
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }
        let completed = try XCTUnwrap(coordinator.records.first)
        let transcriptReference = try XCTUnwrap(completed.transcriptArtifact)
        let notesReference = try XCTUnwrap(completed.lastValidNotesArtifact)

        try await coordinator.retryTranscription(meetingID: completed.id, apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }

        let failed = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(failed.displayState, .complete)
        XCTAssertEqual(failed.transcriptArtifact, transcriptReference)
        XCTAssertEqual(failed.lastValidNotesArtifact, notesReference)
        let retainedTranscript = try await fixture.store.loadTranscript(transcriptReference, meetingID: failed.id)
        let retainedNotes = try await fixture.store.loadNotes(notesReference, meetingID: failed.id)
        XCTAssertEqual(retainedTranscript, "First transcript")
        XCTAssertNotNil(retainedNotes)
    }

    func testRegeneratingTranscriptRunsBothStagesAndReplacesArtifacts() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: SuccessThenSuccessTranscriber(),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }
        let original = try XCTUnwrap(coordinator.records.first)

        try await coordinator.retryTranscription(meetingID: original.id, apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }

        let regenerated = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(regenerated.transcription.attemptCount, 2)
        XCTAssertEqual(regenerated.notes.attemptCount, 2)
        XCTAssertNotEqual(regenerated.transcriptArtifact, original.transcriptArtifact)
        XCTAssertNotEqual(regenerated.lastValidNotesArtifact, original.lastValidNotesArtifact)
        let transcript = try await coordinator.loadTranscript(for: regenerated)
        let notes = try await coordinator.loadNotes(for: regenerated)
        XCTAssertEqual(transcript, "Second transcript")
        XCTAssertEqual(notes?.summaryPoints.first?.evidence, "Second transcript")
    }

    func testStaleProcessingRecordCanRetryWithoutRelaunch() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "Recovered transcript"),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        var stale = try capturedRecord()
        stale.transcription = MeetingStageAttempt(
            status: .processing,
            attemptID: UUID(),
            attemptCount: 1,
            requestCount: 1,
            startedAt: Date(),
            finishedAt: nil,
            failure: nil
        )
        try await persist(stale, in: fixture)

        try await coordinator.retryTranscription(meetingID: stale.id, apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }

        let recovered = try XCTUnwrap(coordinator.records.first(where: { $0.id == stale.id }))
        XCTAssertEqual(recovered.displayState, .complete)
        XCTAssertEqual(recovered.transcription.attemptCount, 2)
    }

    func testRetryForAnotherMeetingIsRejectedWithoutRemoteWork() async throws {
        let fixture = try CoordinatorFixture()
        var failed = try capturedRecord()
        failed.transcription.status = .failed
        failed.transcription.failure = .interrupted
        try await persist(failed, in: fixture)
        let transcriber = CountingMeetingTranscriber(text: "Should not run")
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: transcriber,
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)

        do {
            try await coordinator.retryTranscription(meetingID: failed.id, apiKey: "key", chunkSeconds: nil)
            XCTFail("Expected the active capture lease to reject retry")
        } catch let error as MeetingCoordinatorError {
            guard case .anotherMeetingActive = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let callCount = await transcriber.callCount
        let unchanged = try await fixture.store.loadRecord(id: failed.id)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(unchanged.id, failed.id)
        XCTAssertEqual(unchanged.transcription, failed.transcription)
        XCTAssertEqual(unchanged.transcriptArtifact, failed.transcriptArtifact)
        XCTAssertEqual(unchanged.notes, failed.notes)
        try await coordinator.discardCapture()
    }

    func testFailedRegenerationKeepsPreviouslyValidNotesVisible() async throws {
        let fixture = try CoordinatorFixture()
        let notesGenerator = SuccessThenFailureNotesGenerator()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: StubMeetingTranscriber(text: "The team decided to ship Friday."),
            notesGenerator: notesGenerator
        )
        await coordinator.bootstrap()
        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.canSafelyTerminate }
        let completed = try XCTUnwrap(coordinator.records.first)
        let validNotes = try XCTUnwrap(completed.lastValidNotesArtifact)

        try await coordinator.retryNotes(meetingID: completed.id, apiKey: "key")
        try await waitUntil { coordinator.canSafelyTerminate }

        let failed = try XCTUnwrap(coordinator.records.first)
        XCTAssertEqual(failed.displayState, .complete)
        XCTAssertEqual(failed.notes.status, .failed)
        XCTAssertEqual(failed.lastValidNotesArtifact, validNotes)
        let retainedNotes = try await coordinator.loadNotes(for: failed)
        XCTAssertNotNil(retainedNotes)
    }

    func testRenameCommitsTrimmedTitleAndRejectsActiveMeeting() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = MeetingOperationCoordinator(
            recorder: FakeMeetingRecorder(outputURL: fixture.audioURL),
            store: fixture.store,
            transcriber: BlockingMeetingTranscriber(),
            notesGenerator: StubMeetingNotesGenerator()
        )
        await coordinator.bootstrap()
        let saved = try capturedRecord()
        try await persist(saved, in: fixture)

        let renamed = try await coordinator.renameMeeting(id: saved.id, title: "  Design sync  ")
        XCTAssertEqual(renamed.title, "Design sync")
        XCTAssertEqual(coordinator.records.first(where: { $0.id == saved.id })?.title, "Design sync")

        try await coordinator.startCapture(mode: .microphone, audioSourceID: nil)
        try await coordinator.stopCaptureAndProcess(apiKey: "key", chunkSeconds: nil)
        try await waitUntil { coordinator.records.first?.transcription.status == .processing }
        let activeID = try XCTUnwrap(coordinator.activeMeetingID)
        do {
            _ = try await coordinator.renameMeeting(id: activeID, title: "Blocked")
            XCTFail("Expected active meeting rename to be rejected")
        } catch {
            XCTAssertEqual(error as? MeetingCoordinatorError, .invalidTransition)
        }
        coordinator.cancelProcessing()
        try await waitUntil { coordinator.canSafelyTerminate }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while condition() == false {
            guard clock.now < deadline else {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func capturedRecord(id: UUID = UUID()) throws -> MeetingRecord {
        MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: id,
            title: "Saved meeting",
            createdAt: Date(),
            updatedAt: Date(),
            durationSeconds: 10,
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

    private func persist(_ record: MeetingRecord, in fixture: CoordinatorFixture) async throws {
        let staged = try await fixture.store.createStagingDirectory(meetingID: record.id)
        try Data("audio".utf8).write(to: staged.appending(path: "audio.m4a"))
        try await fixture.store.promoteStagedMeeting(record)
    }
}

@MainActor
private final class FakeMeetingRecorder: MeetingRecording {
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    let lastCaptureArtifacts: SystemAudioCaptureArtifacts? = nil
    let lastDurationSeconds: TimeInterval = 42
    let canPause: Bool
    private(set) var restartCount = 0
    private var outputURL: URL

    init(outputURL: URL, canPause: Bool = true) {
        self.outputURL = outputURL
        self.canPause = canPause
    }

    func start(
        captureMode: RecordingCaptureMode,
        audioSourceID: String?,
        outputDirectory: URL
    ) async throws {
        outputURL = outputDirectory.appending(path: "microphone.m4a")
        isRecording = true
        try Data("audio".utf8).write(to: outputURL)
        lastRecordingURL = outputURL
    }

    func stop(discarding: Bool) async throws -> URL? {
        isRecording = false
        if discarding {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    func pause() {}

    func resume() {}

    func discard() async throws {
        _ = try await stop(discarding: true)
    }

    func restart(
        captureMode: RecordingCaptureMode,
        audioSourceID: String?,
        outputDirectory: URL
    ) async throws {
        restartCount += 1
        try await discard()
        try await start(
            captureMode: captureMode,
            audioSourceID: audioSourceID,
            outputDirectory: outputDirectory
        )
    }

    func importAudioFile(
        from sourceURL: URL,
        outputDirectory: URL
    ) async throws -> (url: URL, durationSeconds: TimeInterval?) {
        outputURL = outputDirectory.appending(path: "imported-source.m4a")
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        lastRecordingURL = outputURL
        return (outputURL, lastDurationSeconds)
    }

    func removeImportedAudio(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
    }
}

private struct StubMeetingTranscriber: MeetingTranscribing {
    let text: String

    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        TranscriptionResult(mode: .plain, text: text)
    }
}

private struct BlockingMeetingTranscriber: MeetingTranscribing {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        try await Task.sleep(for: .seconds(30))
        return TranscriptionResult(mode: .plain, text: "late")
    }
}

private actor CountingMeetingTranscriber: MeetingTranscribing {
    let text: String
    private(set) var callCount = 0

    init(text: String) {
        self.text = text
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        callCount += 1
        return TranscriptionResult(mode: .plain, text: text)
    }
}

private struct CancellationIgnoringTranscriber: MeetingTranscribing {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        try? await Task.sleep(for: .milliseconds(100))
        return TranscriptionResult(mode: .plain, text: "late success")
    }
}

private actor SuccessThenFailureTranscriber: MeetingTranscribing {
    private var callCount = 0

    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        callCount += 1
        if callCount == 1 {
            return TranscriptionResult(mode: .plain, text: "First transcript")
        }
        throw StubTranscriptionError.failed
    }
}

private actor SuccessThenSuccessTranscriber: MeetingTranscribing {
    private var callCount = 0

    func transcribe(
        audioURL: URL,
        apiKey: String,
        chunkSeconds: Int?,
        progress: (@MainActor (TranscriptionProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        callCount += 1
        return TranscriptionResult(mode: .plain, text: callCount == 1 ? "First transcript" : "Second transcript")
    }
}

private enum StubTranscriptionError: Error {
    case failed
}

private struct StubMeetingNotesGenerator: MeetingNotesGenerating {
    func generateNotes(transcript: String, apiKey: String) async throws -> MeetingNotesGenerationResult {
        MeetingNotesGenerationResult(
            notes: MeetingNotes(
                summaryPoints: [.init(text: "The team will ship.", evidence: transcript)],
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            requestCount: 1
        )
    }
}

private actor FailOnceMeetingNotesGenerator: MeetingNotesGenerating {
    private var callCount = 0

    func generateNotes(transcript: String, apiKey: String) async throws -> MeetingNotesGenerationResult {
        callCount += 1
        if callCount == 1 {
            throw MeetingNotesError.invalidContent
        }
        return try await StubMeetingNotesGenerator().generateNotes(transcript: transcript, apiKey: apiKey)
    }
}

private actor SuccessThenFailureNotesGenerator: MeetingNotesGenerating {
    private var callCount = 0

    func generateNotes(transcript: String, apiKey: String) async throws -> MeetingNotesGenerationResult {
        callCount += 1
        if callCount == 1 {
            return try await StubMeetingNotesGenerator().generateNotes(transcript: transcript, apiKey: apiKey)
        }
        throw MeetingNotesError.invalidContent
    }
}

private struct CoordinatorFixture {
    let container: URL
    let audioURL: URL
    let store: MeetingHistoryStore

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appending(path: "WisperCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        audioURL = container.appending(path: "capture.m4a")
        store = MeetingHistoryStore(
            rootURL: container.appending(path: "Meetings", directoryHint: .isDirectory),
            legacyHistoryURL: container.appending(path: "history.json")
        )
    }
}
