import Foundation

@MainActor
struct AppServices {
    let recorder: RecordingController
    let shortcutManager: ShortcutManager
    let audioPlayer: AudioPlaybackController
    let keychain: KeychainStore
    let meetingCoordinator: MeetingOperationCoordinator
    let localLogger: LocalLogger
    let overlayController: OverlayWindowController
    let settingsStore: any AppSettingsStoring

    init(
        recorder: RecordingController = RecordingController(),
        shortcutManager: ShortcutManager = ShortcutManager(),
        audioPlayer: AudioPlaybackController = AudioPlaybackController(),
        keychain: KeychainStore = KeychainStore(service: "com.wisper.mac", account: "openai-api-key"),
        transcriptionService: OpenAITranscriptionService = OpenAITranscriptionService(),
        meetingNotesService: OpenAIMeetingNotesService = OpenAIMeetingNotesService(),
        meetingStore: any MeetingHistoryStoring = MeetingHistoryStore(),
        localLogger: LocalLogger = .shared,
        overlayController: OverlayWindowController = OverlayWindowController(),
        settingsStore: any AppSettingsStoring = JSONAppSettingsStore()
    ) {
        self.recorder = recorder
        self.shortcutManager = shortcutManager
        self.audioPlayer = audioPlayer
        self.keychain = keychain
        meetingCoordinator = MeetingOperationCoordinator(
            recorder: recorder,
            store: meetingStore,
            transcriber: transcriptionService,
            notesGenerator: meetingNotesService,
            logger: localLogger
        )
        self.localLogger = localLogger
        self.overlayController = overlayController
        self.settingsStore = settingsStore
    }

    static func live() -> AppServices {
#if DEBUG
        if let store = UITestFixtureSeeder.configuredMeetingStore(environment: ProcessInfo.processInfo.environment) {
            return AppServices(meetingStore: store)
        }
#endif
        return AppServices()
    }
}
