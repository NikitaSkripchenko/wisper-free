import Foundation

enum MeetingStageStatus: String, Codable, Equatable, Sendable {
    case notStarted
    case processing
    case completed
    case failed
}

enum MeetingFailureCategory: String, Codable, Equatable, Sendable {
    case cancelled
    case interrupted
    case permission
    case storage
    case network
    case authentication
    case rateLimit
    case timeout
    case modelUnavailable
    case audioUnsupported
    case audioTooLarge
    case transcriptTooLong
    case responseTruncated
    case emptyTranscript
    case invalidResponse
    case missingArtifact
    case unknown
}

struct MeetingFailure: Codable, Equatable, Sendable, Error {
    let category: MeetingFailureCategory
    let message: String

    var isRetryable: Bool {
        switch category {
        case .permission, .authentication, .modelUnavailable, .missingArtifact, .transcriptTooLong:
            false
        default:
            true
        }
    }

    static let interrupted = MeetingFailure(
        category: .interrupted,
        message: "Processing was interrupted. Retry this stage."
    )
    static let cancelled = MeetingFailure(
        category: .cancelled,
        message: "Processing was cancelled."
    )
    static let saveFailed = MeetingFailure(
        category: .storage,
        message: "Save failed; retry this stage."
    )
}

struct MeetingArtifactReference: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard normalized.isEmpty == false,
              normalized.hasPrefix("/") == false,
              normalized.contains("\0") == false,
              components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return nil
        }
        self.rawValue = normalized
    }

    init(_ rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw MeetingStorageError.invalidArtifactReference
        }
        self = value
    }
}

struct MeetingCaptureArtifacts: Codable, Equatable, Sendable {
    var microphone: MeetingArtifactReference?
    var systemAudio: MeetingArtifactReference?
    var transcriptionInput: MeetingArtifactReference
}

struct MeetingStageAttempt: Codable, Equatable, Sendable {
    var status: MeetingStageStatus
    var attemptID: UUID?
    var attemptCount: Int
    var requestCount: Int
    var startedAt: Date?
    var finishedAt: Date?
    var failure: MeetingFailure?

    static let notStarted = MeetingStageAttempt(
        status: .notStarted,
        attemptID: nil,
        attemptCount: 0,
        requestCount: 0,
        startedAt: nil,
        finishedAt: nil,
        failure: nil
    )
}

struct MeetingNotesProvenance: Codable, Equatable, Sendable {
    let modelID: String
    let promptVersion: String
    let generatedAt: Date
}

struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var durationSeconds: TimeInterval?
    var captureMode: RecordingCaptureMode
    var captureArtifacts: MeetingCaptureArtifacts
    var transcription: MeetingStageAttempt
    var transcriptionMode: TranscriptionMode? = nil
    var transcriptArtifact: MeetingArtifactReference?
    var notes: MeetingStageAttempt
    var lastValidNotesArtifact: MeetingArtifactReference?
    var notesProvenance: MeetingNotesProvenance?

    var displayState: MeetingDisplayState {
        if lastValidNotesArtifact != nil {
            return .complete
        }
        switch transcription.status {
        case .notStarted:
            return .captured
        case .processing:
            return .transcribing
        case .failed:
            return .transcriptFailed
        case .completed:
            switch notes.status {
            case .notStarted:
                return .transcriptReady
            case .processing:
                return .generatingNotes
            case .failed:
                return .notesFailed
            case .completed:
                return lastValidNotesArtifact == nil ? .transcriptReady : .complete
            }
        }
    }
}

struct MeetingHistoryMetadataPresenter {
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone

    init(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.locale = locale
        self.calendar = calendar
        self.timeZone = timeZone
    }

    func dateText(for record: MeetingRecord) -> String {
        let style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        .month(.abbreviated)
        .day()
        .hour()
        .minute()
        return record.createdAt.formatted(style)
    }

    func matches(_ record: MeetingRecord, query: String) -> Bool {
        let normalizedQuery = normalize(query)
        guard normalizedQuery.isEmpty == false else { return true }
        return normalize(record.title).contains(normalizedQuery)
            || normalize(dateText(for: record)).contains(normalizedQuery)
    }

    func filter(_ records: [MeetingRecord], query: String) -> [MeetingRecord] {
        records.filter { matches($0, query: query) }
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}

enum MeetingAction: String, Equatable {
    case rename
    case retryTranscription
    case retryNotes
    case remove
    case copyTranscript
    case copyNotes
    case playAudio
    case revealAudio
}

struct MeetingActionFeedback: Identifiable, Equatable {
    let meetingID: UUID
    let action: MeetingAction
    let message: String
    let isRetryable: Bool

    var id: String { "\(meetingID.uuidString)-\(action.rawValue)" }
}

enum MeetingDisplayState: String, Codable, Equatable, Sendable {
    case captured
    case transcribing
    case transcriptFailed
    case transcriptReady
    case generatingNotes
    case notesFailed
    case complete

    var statusText: String {
        switch self {
        case .captured: "Capture saved"
        case .transcribing: "Transcribing"
        case .transcriptFailed: "Transcription needs retry"
        case .transcriptReady: "Transcript ready"
        case .generatingNotes: "Generating notes"
        case .notesFailed: "Notes need retry"
        case .complete: "Meeting notes ready"
        }
    }
}

extension MeetingNotes {
    var plainText: String {
        func section(_ title: String, _ items: [GroundedMeetingNote]) -> String {
            let body = items.isEmpty ? "None" : items.map { "- \($0.text)" }.joined(separator: "\n")
            return "\(title)\n\(body)"
        }
        let actions = actionItems.isEmpty
            ? "None"
            : actionItems.map { item in
                let details = [item.owner, item.dueDate].compactMap { $0 }.joined(separator: " · ")
                return details.isEmpty ? "- \(item.text)" : "- \(item.text) (\(details))"
            }.joined(separator: "\n")
        return [
            section("Summary", summaryPoints),
            section("Decisions", decisions),
            "Action Items\n\(actions)",
            section("Open Questions", openQuestions)
        ].joined(separator: "\n\n")
    }
}

struct MeetingBootstrapResult: Sendable {
    let records: [MeetingRecord]
    let quarantinedRecordCount: Int
    let migratedRecordCount: Int
    let staleTrashCount: Int
}

enum MeetingStorageError: LocalizedError, Equatable {
    case invalidArtifactReference
    case artifactEscapesMeetingDirectory
    case missingRecord
    case stagedMeetingAlreadyExists
    case invalidStagedRecord
    case legacyMigrationFailed
    case removeFailed
    case invalidTitle

    var errorDescription: String? {
        switch self {
        case .invalidArtifactReference, .artifactEscapesMeetingDirectory:
            "A meeting contains an unsafe file reference."
        case .missingRecord:
            "The meeting record could not be found."
        case .stagedMeetingAlreadyExists:
            "A staged meeting with this identifier already exists."
        case .invalidStagedRecord:
            "The staged meeting could not be validated."
        case .legacyMigrationFailed:
            "Legacy history could not be migrated safely. The original history was left unchanged."
        case .removeFailed:
            "The meeting could not be moved to Trash. Try again."
        case .invalidTitle:
            "Enter a meeting title."
        }
    }
}
