import Foundation

@MainActor
struct AppServices {
    let recorder: RecordingController
    let shortcutManager: ShortcutManager
    let audioPlayer: AudioPlaybackController
    let keychain: KeychainStore
    let transcriptionService: OpenAITranscriptionService
    let localLogger: LocalLogger
    let overlayController: OverlayWindowController
    let settingsStore: any AppSettingsStoring
    let historyStore: any TranscriptHistoryStoring

    init(
        recorder: RecordingController = RecordingController(),
        shortcutManager: ShortcutManager = ShortcutManager(),
        audioPlayer: AudioPlaybackController = AudioPlaybackController(),
        keychain: KeychainStore = KeychainStore(service: "com.wisper.mac", account: "openai-api-key"),
        transcriptionService: OpenAITranscriptionService = OpenAITranscriptionService(),
        localLogger: LocalLogger = .shared,
        overlayController: OverlayWindowController = OverlayWindowController(),
        settingsStore: any AppSettingsStoring = JSONAppSettingsStore(),
        historyStore: any TranscriptHistoryStoring = JSONTranscriptHistoryStore()
    ) {
        self.recorder = recorder
        self.shortcutManager = shortcutManager
        self.audioPlayer = audioPlayer
        self.keychain = keychain
        self.transcriptionService = transcriptionService
        self.localLogger = localLogger
        self.overlayController = overlayController
        self.settingsStore = settingsStore
        self.historyStore = historyStore
    }

    static func live() -> AppServices {
        AppServices()
    }
}
