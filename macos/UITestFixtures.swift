#if DEBUG
import Foundation

enum UITestFixtureSeeder {
    static func configuredMeetingStore(environment: [String: String]) -> MeetingHistoryStore? {
        guard let rootPath = environment["WISPER_UI_TEST_ROOT"],
              let fixture = environment["WISPER_UI_TEST_FIXTURE"] else {
            return nil
        }
        let container = URL(filePath: rootPath, directoryHint: .isDirectory)
        let root = container.appending(path: "Meetings", directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: container)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if fixture != "empty" {
                try seedMeeting(fixture: fixture, root: root)
            }
        } catch {
            assertionFailure("Could not seed UI test fixture: \(error)")
        }
        return MeetingHistoryStore(
            rootURL: root,
            legacyHistoryURL: container.appending(path: "legacy-history.json")
        )
    }

    private static func seedMeeting(fixture: String, root: URL) throws {
        let meetingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let directory = root.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture audio".utf8).write(to: directory.appending(path: "audio.m4a"))
        let transcript = "Nick will send the draft Friday. The team decided to ship."
        try Data(transcript.utf8).write(to: directory.appending(path: "transcript.txt"))

        let notesReference: MeetingArtifactReference?
        let notesAttempt: MeetingStageAttempt
        if fixture == "notes-failed" {
            notesReference = nil
            notesAttempt = MeetingStageAttempt(
                status: .failed,
                attemptID: UUID(),
                attemptCount: 1,
                requestCount: 2,
                startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 1_001),
                failure: MeetingFailure(category: .invalidResponse, message: "OpenAI returned invalid meeting notes. Retry notes.")
            )
        } else {
            let notes = MeetingNotes(
                summaryPoints: [.init(text: "The team plans to ship.", evidence: "The team decided to ship.")],
                decisions: fixture == "empty-categories"
                    ? []
                    : [.init(text: "Ship the current plan.", evidence: "The team decided to ship.")],
                actionItems: fixture == "empty-categories"
                    ? []
                    : [.init(text: "Send the draft.", owner: "Nick", dueDate: "Friday", evidence: "Nick will send the draft Friday.")],
                openQuestions: []
            )
            let reference = try MeetingArtifactReference("notes.json")
            try JSONEncoder.wisper.encode(notes).write(to: directory.appending(path: reference.rawValue))
            notesReference = reference
            notesAttempt = MeetingStageAttempt(
                status: .completed,
                attemptID: UUID(),
                attemptCount: 1,
                requestCount: 1,
                startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 1_001),
                failure: nil
            )
        }

        let record = MeetingRecord(
            schemaVersion: MeetingRecord.currentSchemaVersion,
            id: meetingID,
            title: "UI Test Planning Call",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001),
            durationSeconds: 60,
            captureMode: .microphone,
            captureArtifacts: MeetingCaptureArtifacts(
                microphone: try MeetingArtifactReference("audio.m4a"),
                systemAudio: nil,
                transcriptionInput: try MeetingArtifactReference("audio.m4a")
            ),
            transcription: MeetingStageAttempt(
                status: .completed,
                attemptID: UUID(),
                attemptCount: 1,
                requestCount: 1,
                startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 1_001),
                failure: nil
            ),
            transcriptArtifact: try MeetingArtifactReference("transcript.txt"),
            notes: notesAttempt,
            lastValidNotesArtifact: notesReference,
            notesProvenance: notesReference.map { _ in
                MeetingNotesProvenance(
                    modelID: OpenAIMeetingNotesService.model,
                    promptVersion: OpenAIMeetingNotesService.promptVersion,
                    generatedAt: Date(timeIntervalSince1970: 1_001)
                )
            }
        )
        try JSONEncoder.wisper.encode(record).write(to: directory.appending(path: "record.json"))
    }
}
#endif
