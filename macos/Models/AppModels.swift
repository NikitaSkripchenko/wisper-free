import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .record:
            "mic.circle"
        case .history:
            "doc.text"
        case .settings:
            "gearshape"
        }
    }
}

enum HistoryStatus: String, Codable, Equatable {
    case completed
    case failed
    case processing
}

struct AppSettings: Codable {
    var shortcut: KeyboardShortcut
    var chunkingEnabled: Bool
    var chunkSeconds: Int
    var audioSourceID: String?
    var captureMode: RecordingCaptureMode?
    var showInMenuBarOnly: Bool?
    var onboardingCompleted: Bool

    static let `default` = AppSettings(
        shortcut: .default,
        chunkingEnabled: true,
        chunkSeconds: 480,
        audioSourceID: nil,
        captureMode: .defaultMode,
        showInMenuBarOnly: false,
        onboardingCompleted: false
    )

    init(
        shortcut: KeyboardShortcut,
        chunkingEnabled: Bool,
        chunkSeconds: Int,
        audioSourceID: String?,
        captureMode: RecordingCaptureMode?,
        showInMenuBarOnly: Bool?,
        onboardingCompleted: Bool
    ) {
        self.shortcut = shortcut
        self.chunkingEnabled = chunkingEnabled
        self.chunkSeconds = chunkSeconds
        self.audioSourceID = audioSourceID
        self.captureMode = captureMode
        self.showInMenuBarOnly = showInMenuBarOnly
        self.onboardingCompleted = onboardingCompleted
    }

    enum CodingKeys: String, CodingKey {
        case shortcut
        case chunkingEnabled
        case chunkSeconds
        case audioSourceID
        case captureMode
        case showInMenuBarOnly
        case onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        shortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut) ?? defaults.shortcut
        chunkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .chunkingEnabled) ?? defaults.chunkingEnabled
        chunkSeconds = try container.decodeIfPresent(Int.self, forKey: .chunkSeconds) ?? defaults.chunkSeconds
        audioSourceID = try container.decodeIfPresent(String.self, forKey: .audioSourceID)
        captureMode = try container.decodeIfPresent(RecordingCaptureMode.self, forKey: .captureMode) ?? defaults.captureMode
        showInMenuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBarOnly) ?? defaults.showInMenuBarOnly
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
            ?? defaults.onboardingCompleted
    }
}

struct Transcript: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var source: String
    var originalName: String
    var audioPath: String?
    var durationSeconds: TimeInterval?
    var status: HistoryStatus
    var transcriptionText: String
    var errorMessage: String?
    var mode: String
    var updatedAt: Date

    var title: String {
        originalName.isEmpty ? "Recording" : originalName
    }

    var text: String {
        transcriptionText
    }

    var audioURL: URL? {
        guard let audioPath, audioPath.isEmpty == false else { return nil }
        return URL(filePath: audioPath)
    }

    var canUseAudio: Bool {
        guard let audioPath else { return false }
        return FileManager.default.fileExists(atPath: audioPath)
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: String = "native-mac",
        originalName: String,
        audioPath: String?,
        durationSeconds: TimeInterval?,
        status: HistoryStatus,
        transcriptionText: String,
        errorMessage: String? = nil,
        mode: String = "plain",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.originalName = originalName
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.status = status
        self.transcriptionText = transcriptionText
        self.errorMessage = errorMessage
        self.mode = mode
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case source
        case originalName
        case audioPath
        case durationSeconds
        case status
        case transcriptionText
        case text
        case errorMessage
        case mode
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "native-mac"
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
            ?? audioPath.map { URL(filePath: $0).lastPathComponent }
            ?? "Recording"
        durationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        status = try container.decodeIfPresent(HistoryStatus.self, forKey: .status) ?? .completed
        transcriptionText = try container.decodeIfPresent(String.self, forKey: .transcriptionText)
            ?? container.decodeIfPresent(String.self, forKey: .text)
            ?? ""
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "plain"
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encode(originalName, forKey: .originalName)
        try container.encodeIfPresent(audioPath, forKey: .audioPath)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(status, forKey: .status)
        try container.encode(transcriptionText, forKey: .transcriptionText)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(mode, forKey: .mode)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct PendingUploadedAudio: Equatable {
    let originalName: String
    let audioURL: URL
    let durationSeconds: TimeInterval?
}

enum AppActivity: Equatable {
    case idle
    case startingRecording
    case recording
    case stoppingRecording
    case transcribing
    case importingAudio
    case restartingRecording
    case discardingRecording

    var blocksUpdateInstallation: Bool {
        self != .idle
    }
}
