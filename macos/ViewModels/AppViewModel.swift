import AppKit
import Combine
import Foundation

/// Pure formatting for the Settings storage line ("14 meetings · 3.4 GB of audio").
/// Kept free of AppViewModel so it's directly testable.
enum MeetingStorageStats {
    static func summaryText(meetingCount: Int, audioBytes: Int64?) -> String {
        let meetingsText = meetingCount == 1 ? "1 meeting" : "\(meetingCount) meetings"
        guard let audioBytes else { return meetingsText }
        let formatted = ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
        return "\(meetingsText) · \(formatted) of audio"
    }

    private static let audioFileExtensions: Set<String> = ["m4a", "wav", "caf", "mp3", "aac", "aiff"]

    /// Walks the Meetings directory off the main actor and sums audio file sizes only
    /// (record.json / transcript-*.txt / notes-*.json are skipped by extension).
    nonisolated static func measureAudioBytes(in meetingsRoot: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: meetingsRoot,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator where audioFileExtensions.contains(url.pathExtension.lowercased()) {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    /// No longer drives navigation (the workspace replaced the sidebar's section
    /// switch); left in place because other code and tests still read it.
    @Published var selectedSection: SidebarSection? = .record
    @Published var selectedMeetingID: UUID?
    @Published var isSettingsPresented = false
    @Published var renameRequestedMeetingID: UUID?
    @Published var statusMessage = "Ready to record"
    @Published var errorMessage: String?
    @Published var apiKeyStatus = "Not configured"
    @Published var isProcessing = false
    @Published var latestTranscriptText = "No transcript yet."
    @Published var shortcut: KeyboardShortcut = .default
    @Published var shortcutCaptureMessage = "Default: Command Shift Space"
    @Published var chunkingEnabled = true
    @Published var chunkSeconds = 480
    @Published var selectedAudioSourceID: String?
    @Published var captureMode: RecordingCaptureMode = .defaultMode
    @Published var onboardingCompleted = false
    @Published var showOverlayWhileRecording = true
    @Published private(set) var meetingStorageAudioBytes: Int64?
    @Published private(set) var microphonePermissionStatus: PermissionReadiness = .notDetermined
    @Published private(set) var screenAudioPermissionStatus: PermissionReadiness = .notDetermined
    @Published private(set) var activity: AppActivity = .idle
    @Published private(set) var isUpdateInstallPending = false
    @Published private(set) var meetingActionFeedback: MeetingActionFeedback?

    let recorder: RecordingController
    let meetingCoordinator: MeetingOperationCoordinator
    let shortcutManager: ShortcutManager
    let audioPlayer: AudioPlaybackController

    private let keychain: KeychainStore
    private let localLogger: LocalLogger
    private let overlayController: OverlayWindowController
    private let settingsStore: any AppSettingsStoring
    private var overlayTimer: Timer?
    private var lastAnnouncedMeetingStatus: String?
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices = .live()) {
        recorder = services.recorder
        meetingCoordinator = services.meetingCoordinator
        shortcutManager = services.shortcutManager
        audioPlayer = services.audioPlayer
        keychain = services.keychain
        localLogger = services.localLogger
        overlayController = services.overlayController
        settingsStore = services.settingsStore

        let settings: AppSettings
        do {
            settings = try settingsStore.load()
        } catch {
            settings = .default
            errorMessage = "Could not load saved settings. Wisper restored defaults."
            localLogger.warning("Settings load failed; defaults restored", error: error)
        }

        shortcut = settings.shortcut
        chunkingEnabled = settings.chunkingEnabled
        chunkSeconds = settings.chunkSeconds
        selectedAudioSourceID = settings.audioSourceID
        captureMode = settings.captureMode ?? .defaultMode
        onboardingCompleted = settings.onboardingCompleted
        showOverlayWhileRecording = settings.showOverlayWhileRecording
#if DEBUG
        if ProcessInfo.processInfo.environment["WISPER_UI_TEST_ROOT"] != nil {
            onboardingCompleted = ProcessInfo.processInfo.environment["WISPER_UI_TEST_ONBOARDING"] != "1"
        }
#endif
        activity = .bootstrapping
        isProcessing = true
        recorder.refreshAudioSources()
        refreshPermissionStatuses()
        refreshAPIKeyStatus()
        configureOverlayActions()
        // Permissions are granted in System Settings, so re-read them whenever
        // the user comes back to Wisper instead of only when a view appears.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermissionStatuses() }
            .store(in: &cancellables)
        meetingCoordinator.$records
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshMeetingStorageStats() }
            .store(in: &cancellables)
        localLogger.info("App state initialized", metadata: [
            "captureMode": captureMode.rawValue,
            "chunkingEnabled": String(chunkingEnabled)
        ])
        shortcutManager.start(shortcut: shortcut) { [weak self] in
            Task { @MainActor in
                await self?.handleGlobalShortcut()
            }
        }
        shortcutCaptureMessage = shortcutManager.statusMessage
        Task { @MainActor in
            await meetingCoordinator.bootstrap()
            activity = .idle
            isProcessing = false
            if case .failed(let message) = meetingCoordinator.bootstrapState {
                errorMessage = message
            }
        }
    }

    var hasAPIKey: Bool {
        (try? keychain.read())?.isEmpty == false
    }

    var localLogFileURL: URL {
        localLogger.logFileURL
    }

    /// System audio is optional: without it Wisper records the microphone only.
    var canCompleteOnboarding: Bool {
        hasAPIKey && microphonePermissionStatus == .granted
    }

    func openMeeting(id: UUID) {
        selectedMeetingID = id
    }

    func requestMeetingRename(id: UUID) {
        openMeeting(id: id)
        renameRequestedMeetingID = id
    }

    func clearMeetingActionFeedback(for meetingID: UUID? = nil) {
        guard meetingID == nil || meetingActionFeedback?.meetingID == meetingID else { return }
        meetingActionFeedback = nil
    }

    var selectedAudioSourceName: String {
        recorder.audioSourceName(for: selectedAudioSourceID)
    }

    var captureModeDescription: String {
        captureMode.displayName
    }

    var activeAudioSourceName: String {
        return recorder.isRecording ? recorder.lastRecordingSourceName : configuredAudioSourceName
    }

    var configuredAudioSourceName: String {
        captureMode.usesMicrophone ? selectedAudioSourceName : "System output"
    }

    func refreshPermissionStatuses() {
        microphonePermissionStatus = RecordingController.microphonePermissionStatus()
        screenAudioPermissionStatus = ScreenAudioPermission.status()
    }

    func requestMicrophonePermission() async {
        let granted = await RecordingController.requestMicrophoneAccess()
        refreshPermissionStatuses()
        localLogger.info("Microphone permission requested", metadata: ["granted": String(granted)])

        // A refusal shows up inline as "Open System Settings"; no alert on top.
        if granted {
            statusMessage = "Microphone access granted"
        }
    }

    func requestScreenAudioPermission() {
        let granted = ScreenAudioPermission.requestAccess()
        refreshPermissionStatuses()
        localLogger.info("Screen and system audio permission requested", metadata: ["granted": String(granted)])

        if granted {
            statusMessage = "Screen and system audio recording access granted"
        } else if ScreenAudioPermission.isSupported == false {
            errorMessage = "System audio capture requires macOS 15 or later."
        }
    }

    func openMicrophoneSettings() {
        openSystemSettingsPane("Privacy_Microphone")
    }

    func openScreenAudioSettings() {
        openSystemSettingsPane("Privacy_ScreenCapture")
    }

    func revealLocalLogFile() {
        let url = localLogFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) == false {
                try Data().write(to: url, options: .atomic)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = "Could not open local log: \(error.localizedDescription)"
        }
    }

    func completeOnboarding() {
        guard canCompleteOnboarding else {
            errorMessage = "Add your OpenAI key and allow the microphone before continuing."
            return
        }

        // Skipping system audio must not leave a capture mode that fails on
        // the first recording.
        if captureMode.usesSystemAudio, screenAudioPermissionStatus != .granted {
            captureMode = .microphone
        }
        onboardingCompleted = true
        do {
            try saveSettings()
            statusMessage = "Wisper is ready"
            localLogger.info("Onboarding completed")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            errorMessage = "Enter an OpenAI API key before saving."
            return
        }

        do {
            try keychain.save(trimmed)
            refreshAPIKeyStatus()
            statusMessage = "API key saved in Keychain"
            localLogger.info("API key saved")
        } catch {
            localLogger.error("API key save failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            refreshAPIKeyStatus()
            statusMessage = "API key removed"
            localLogger.info("API key removed")
        } catch {
            localLogger.error("API key deletion failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() async {
        guard isProcessing == false else { return }
        guard canBeginNewWork() else { return }

        guard hasAPIKey else {
            isSettingsPresented = true
            errorMessage = "Save an OpenAI API key before recording. Wisper transcribes automatically when you stop."
            return
        }

        activity = .startingRecording
        localLogger.info("Recording start requested", metadata: [
            "captureMode": captureMode.rawValue,
            "audioSource": selectedAudioSourceName
        ])
        do {
            try await meetingCoordinator.startCapture(mode: captureMode, audioSourceID: selectedAudioSourceID)
            activity = .recording
            latestTranscriptText = "Recording..."
            statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
            localLogger.info("Recording started", metadata: ["source": recorder.lastRecordingSourceName])
            showOverlay()
            startOverlayTimer()
        } catch {
            activity = .idle
            localLogger.error("Recording start failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        activity = .stoppingRecording
        localLogger.info("Recording stop requested")
        do {
            guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
                throw MeetingCoordinatorError.missingAPIKey
            }
            isProcessing = true
            stopOverlayTimer()
            try await meetingCoordinator.stopCaptureAndProcess(
                apiKey: apiKey,
                chunkSeconds: chunkingEnabled ? chunkSeconds : nil
            )
            await monitorMeetingProcessing()
        } catch {
            activity = .idle
            isProcessing = false
            stopOverlayTimer()
            overlayController.hide()
            localLogger.error("Recording stop failed", error: error)
            errorMessage = error.localizedDescription
            statusMessage = "Recording failed"
        }
    }

    func importDroppedAudioFiles(_ urls: [URL]) async {
        guard canBeginNewWork() else { return }
        guard recorder.isRecording == false else {
            errorMessage = "Stop the current recording before uploading an audio file."
            return
        }

        guard isProcessing == false else {
            errorMessage = "Wait for the current transcription to finish before uploading an audio file."
            return
        }

        guard let sourceURL = urls.first(where: { RecordingController.isSupportedAudioFile($0) }) else {
            statusMessage = "Unsupported audio file"
            errorMessage = "Drop a supported audio file: \(RecordingController.supportedAudioFileTypesDescription)."
            return
        }

        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            isSettingsPresented = true
            errorMessage = "Save an OpenAI API key before importing audio."
            return
        }
        activity = .importingAudio
        isProcessing = true
        do {
            latestTranscriptText = "Importing \(sourceURL.lastPathComponent)..."
            try await meetingCoordinator.importAndProcess(
                sourceURL: sourceURL,
                apiKey: apiKey,
                chunkSeconds: chunkingEnabled ? chunkSeconds : nil
            )
            await monitorMeetingProcessing()
        } catch {
            activity = .idle
            isProcessing = false
            localLogger.error("Audio import failed", metadata: ["file": sourceURL.lastPathComponent], error: error)
            errorMessage = error.localizedDescription
            latestTranscriptText = error.localizedDescription
            statusMessage = "Upload failed"
        }
    }

    func pauseRecording() {
        do {
            try meetingCoordinator.pauseCapture()
            statusMessage = "Recording paused"
            localLogger.info("Recording paused")
            updateOverlay()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeRecording() {
        do {
            try meetingCoordinator.resumeCapture()
            statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
            localLogger.info("Recording resumed")
            updateOverlay()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardRecording() async {
        activity = .discardingRecording
        do {
            try await meetingCoordinator.discardCapture()
            activity = .idle
            latestTranscriptText = "Recording discarded."
            statusMessage = "Ready to record"
            localLogger.info("Recording discarded")
            stopOverlayTimer()
            overlayController.hide()
        } catch {
            activity = recorder.isRecording ? .recording : .idle
            localLogger.error("Recording discard failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func restartRecording() async {
        guard canBeginNewWork() else { return }
        activity = .restartingRecording
        do {
            try await meetingCoordinator.restartCapture(mode: captureMode, audioSourceID: selectedAudioSourceID)
            activity = .recording
            latestTranscriptText = "Recording..."
            statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
            localLogger.info("Recording restarted")
            showOverlay()
            startOverlayTimer()
        } catch {
            activity = recorder.isRecording ? .recording : .idle
            localLogger.error("Recording restart failed", error: error)
            handleRecordingStartError(error)
        }
    }

    private func handleRecordingStartError(_ error: Error) {
        if let systemAudioError = error as? SystemAudioCaptureError,
           systemAudioError == .screenRecordingPermissionRequired {
            let message = systemAudioError.localizedDescription
            latestTranscriptText = message
            statusMessage = "Screen recording permission needed"
            return
        }

        errorMessage = error.localizedDescription
    }

    func saveShortcut(_ nextShortcut: KeyboardShortcut) {
        shortcut = nextShortcut
        do {
            try saveSettings()
            shortcutManager.register(nextShortcut)
            shortcutCaptureMessage = shortcutManager.statusMessage
            localLogger.info("Shortcut saved", metadata: ["shortcut": nextShortcut.displayText])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAudioSource(_ sourceID: String?) {
        selectedAudioSourceID = sourceID?.isEmpty == false ? sourceID : nil
        do {
            try saveSettings()
            statusMessage = "Audio source set to \(selectedAudioSourceName)"
            localLogger.info("Audio source saved", metadata: ["source": selectedAudioSourceName])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCaptureMode(_ mode: RecordingCaptureMode) {
        captureMode = mode
        do {
            try saveSettings()
            statusMessage = "Capture mode set to \(mode.displayName)"
            localLogger.info("Capture mode saved", metadata: ["captureMode": mode.rawValue])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveShowOverlayWhileRecording(_ enabled: Bool) {
        showOverlayWhileRecording = enabled
        do {
            try saveSettings()
            if enabled {
                if recorder.phase == .recording || recorder.phase == .paused {
                    showOverlay()
                    startOverlayTimer()
                }
            } else {
                overlayController.hide()
            }
            localLogger.info("Show overlay setting saved", metadata: ["enabled": String(enabled)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Measures Meetings-directory audio bytes off the main actor and caches the result;
    /// call again only when the Settings screen appears or the meeting records change.
    func refreshMeetingStorageStats() {
        let meetingsRoot = AppStorageLocation.supportDirectory.appending(path: "Meetings", directoryHint: .isDirectory)
        Task.detached(priority: .utility) { [weak self] in
            let bytes = MeetingStorageStats.measureAudioBytes(in: meetingsRoot)
            await MainActor.run {
                self?.meetingStorageAudioBytes = bytes
            }
        }
    }

    private func openSystemSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            errorMessage = "Could not open System Settings."
            return
        }

        NSWorkspace.shared.open(url)
    }

    func saveChunkingSettings(enabled: Bool? = nil, seconds: Int? = nil) {
        if let enabled {
            chunkingEnabled = enabled
        }

        if let seconds {
            chunkSeconds = min(max(seconds, 60), 3_600)
        }

        do {
            try saveSettings()
            statusMessage = chunkingEnabled
                ? "Chunking enabled at \(chunkSeconds) seconds"
                : "Chunking disabled"
            localLogger.info("Chunking settings saved", metadata: [
                "enabled": String(chunkingEnabled),
                "chunkSeconds": String(chunkSeconds)
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setUpdateInstallPending(_ isPending: Bool) {
        isUpdateInstallPending = isPending
        if isPending {
            statusMessage = "Update will install when current work finishes"
        }
    }

    func retryTranscription(for record: MeetingRecord) async {
        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            isSettingsPresented = true
            errorMessage = "Save an OpenAI API key before retrying."
            return
        }
        do {
            clearMeetingActionFeedback(for: record.id)
            activity = .transcribing
            isProcessing = true
            try await meetingCoordinator.retryTranscription(
                meetingID: record.id,
                apiKey: apiKey,
                chunkSeconds: chunkingEnabled ? chunkSeconds : nil
            )
            await monitorMeetingProcessing()
        } catch {
            activity = .idle
            isProcessing = false
            presentMeetingError(error, for: record.id, action: .retryTranscription)
        }
    }

    func retryNotes(for record: MeetingRecord) async {
        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            isSettingsPresented = true
            errorMessage = "Save an OpenAI API key before retrying notes."
            return
        }
        do {
            clearMeetingActionFeedback(for: record.id)
            activity = .transcribing
            isProcessing = true
            try await meetingCoordinator.retryNotes(meetingID: record.id, apiKey: apiKey)
            await monitorMeetingProcessing()
        } catch {
            activity = .idle
            isProcessing = false
            presentMeetingError(error, for: record.id, action: .retryNotes)
        }
    }

    func removeMeeting(_ record: MeetingRecord) async {
        activity = .discardingRecording
        defer { activity = .idle }
        do {
            clearMeetingActionFeedback(for: record.id)
            try await meetingCoordinator.removeMeeting(id: record.id)
            if selectedMeetingID == record.id {
                selectedMeetingID = meetingCoordinator.records.first?.id
            }
            statusMessage = "Meeting removed"
        } catch {
            presentMeetingError(error, for: record.id, action: .remove)
        }
    }

    func renameMeeting(_ record: MeetingRecord, title: String) async -> Bool {
        do {
            clearMeetingActionFeedback(for: record.id)
            _ = try await meetingCoordinator.renameMeeting(id: record.id, title: title)
            statusMessage = "Meeting renamed"
            return true
        } catch {
            presentMeetingError(error, for: record.id, action: .rename)
            return false
        }
    }

    func copyMeetingTranscript(_ record: MeetingRecord) async {
        do {
            guard let transcript = try await meetingCoordinator.loadTranscript(for: record) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            statusMessage = "Transcript copied"
        } catch {
            presentMeetingError(error, for: record.id, action: .copyTranscript)
        }
    }

    func copyMeetingNotes(_ record: MeetingRecord) async {
        do {
            guard let notes = try await meetingCoordinator.loadNotes(for: record) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(notes.plainText, forType: .string)
            statusMessage = "Notes copied"
        } catch {
            presentMeetingError(error, for: record.id, action: .copyNotes)
        }
    }

    func playMeetingAudio(_ record: MeetingRecord) async {
        do {
            let url = try await meetingCoordinator.audioURL(for: record)
            do {
                try audioPlayer.toggle(url: url)
            } catch {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                meetingActionFeedback = MeetingActionFeedback(
                    meetingID: record.id,
                    action: .playAudio,
                    message: "This audio format cannot be played here. Wisper revealed the owned file in Finder.",
                    isRetryable: false
                )
            }
        } catch {
            presentMeetingError(error, for: record.id, action: .playAudio)
        }
    }

    func prepareMeetingAudio(_ record: MeetingRecord) async -> URL? {
        do {
            let url = try await meetingCoordinator.audioURL(for: record)
            try audioPlayer.load(url: url)
            return url
        } catch {
            presentMeetingError(error, for: record.id, action: .playAudio)
            return nil
        }
    }

    func retryMeetingBootstrap() async {
        await meetingCoordinator.bootstrap()
        if case .failed(let message) = meetingCoordinator.bootstrapState {
            errorMessage = message
        }
    }

    func revealMeetingStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([AppStorageLocation.supportDirectory])
    }

    func stopProcessing(for record: MeetingRecord) {
        guard meetingCoordinator.activeMeetingID == record.id else { return }
        meetingCoordinator.cancelProcessing()
    }

    func revealMeetingAudio(_ record: MeetingRecord) async {
        do {
            let url = try await meetingCoordinator.audioURL(for: record)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentMeetingError(error, for: record.id, action: .revealAudio)
        }
    }

    private func monitorMeetingProcessing() async {
        let processingMeetingID = meetingCoordinator.activeMeetingID
        activity = .transcribing
        while meetingCoordinator.canSafelyTerminate == false {
            if let id = meetingCoordinator.activeMeetingID,
               let record = meetingCoordinator.records.first(where: { $0.id == id }) {
                statusMessage = record.displayState.statusText
                latestTranscriptText = record.displayState.statusText
                updateOverlay()
                announceMeetingStatusIfNeeded(record.displayState.statusText)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        isProcessing = false
        activity = .idle
        overlayController.hide()
        if let completed = meetingCoordinator.records.first(where: { $0.id == processingMeetingID })
            ?? meetingCoordinator.records.first {
            statusMessage = completed.displayState.statusText
            if let transcript = try? await meetingCoordinator.loadTranscript(for: completed) {
                latestTranscriptText = transcript
            }
            openMeeting(id: completed.id)
        }
    }

    private func presentMeetingError(_ error: Error, for meetingID: UUID, action: MeetingAction) {
        let retryable: Bool
        if let failure = error as? MeetingFailure {
            retryable = failure.isRetryable
        } else {
            retryable = true
        }
        meetingActionFeedback = MeetingActionFeedback(
            meetingID: meetingID,
            action: action,
            message: error.localizedDescription,
            isRetryable: retryable
        )
    }

    private func announceMeetingStatusIfNeeded(_ status: String) {
        guard lastAnnouncedMeetingStatus != status else { return }
        lastAnnouncedMeetingStatus = status
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: status, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func canBeginNewWork() -> Bool {
        guard isUpdateInstallPending == false else {
            errorMessage = "An update is waiting to install. Finish the current work before starting something new."
            return false
        }
        return true
    }

    private func handleGlobalShortcut() async {
        if isProcessing || onboardingCompleted == false { return }

        NSApp.activate(ignoringOtherApps: false)
        if recorder.phase == .recording || recorder.phase == .paused {
            await stopRecording()
            return
        }

        await startRecording()
    }

    private func configureOverlayActions() {
        overlayController.onDiscard = { [weak self] in
            Task { @MainActor in await self?.discardRecording() }
        }
        overlayController.onRestart = { [weak self] in
            Task { @MainActor in await self?.restartRecording() }
        }
        overlayController.onPause = { [weak self] in self?.pauseRecording() }
        overlayController.onResume = { [weak self] in self?.resumeRecording() }
        overlayController.onStop = { [weak self] in
            Task { @MainActor in await self?.stopRecording() }
        }
    }

    private func showOverlay() {
        guard showOverlayWhileRecording else { return }
        overlayController.show(state: overlayState())
    }

    private func updateOverlay() {
        guard showOverlayWhileRecording else { return }
        overlayController.update(state: overlayState())
    }

    /// Processing outranks the recorder's own phase: once capture stops the
    /// surface must stop looking like it is still listening.
    private var overlayPhase: RecordingSurfacePhase {
        if isProcessing { return .processing }
        return recorder.phase == .paused ? .paused : .recording
    }

    private func overlayState() -> RecordingOverlayState {
        RecordingOverlayState(
            phase: overlayPhase,
            elapsedText: recorder.elapsedDisplay,
            canPause: recorder.phase == .recording && recorder.canPause && isProcessing == false,
            canResume: recorder.phase == .paused && isProcessing == false,
            canStop: recorder.phase == .recording || recorder.phase == .paused,
            canDiscard: recorder.phase == .recording || recorder.phase == .paused,
            canRestart: recorder.phase == .recording || recorder.phase == .paused,
            microphoneLevels: recorder.microphoneLevels,
            showsMicrophoneWaveform: recorder.phase == .recording && captureMode.usesMicrophone && isProcessing == false
        )
    }

    private func startOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateOverlay()
            }
        }
    }

    private func stopOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = nil
    }

    private func hideOverlay(after seconds: TimeInterval) {
        stopOverlayTimer()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            overlayController.hide()
        }
    }

    private func refreshAPIKeyStatus() {
        apiKeyStatus = hasAPIKey ? "Saved in Keychain" : "Not configured"
    }

    private func saveSettings() throws {
        try settingsStore.save(AppSettings(
            shortcut: shortcut,
            chunkingEnabled: chunkingEnabled,
            chunkSeconds: chunkSeconds,
            audioSourceID: selectedAudioSourceID,
            captureMode: captureMode,
            onboardingCompleted: onboardingCompleted,
            showOverlayWhileRecording: showOverlayWhileRecording
        ))
    }

}
