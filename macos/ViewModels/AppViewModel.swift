import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedSection: SidebarSection? = .record
    @Published var history: [Transcript] = []
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
    @Published var showInMenuBarOnly = false
    @Published var onboardingCompleted = false
    @Published private(set) var microphonePermissionStatus: PermissionReadiness = .notDetermined
    @Published private(set) var screenAudioPermissionStatus: PermissionReadiness = .notDetermined
    @Published var pendingUploadedAudio: PendingUploadedAudio?
    @Published private(set) var activity: AppActivity = .idle
    @Published private(set) var isUpdateInstallPending = false

    let recorder: RecordingController
    let shortcutManager: ShortcutManager
    let audioPlayer: AudioPlaybackController

    private let keychain: KeychainStore
    private let transcriptionService: OpenAITranscriptionService
    private let localLogger: LocalLogger
    private let overlayController: OverlayWindowController
    private let settingsStore: any AppSettingsStoring
    private let historyStore: any TranscriptHistoryStoring
    private var overlayTimer: Timer?

    convenience init(
        settingsStore: any AppSettingsStoring = JSONAppSettingsStore(),
        historyStore: any TranscriptHistoryStoring = JSONTranscriptHistoryStore()
    ) {
        self.init(services: AppServices(settingsStore: settingsStore, historyStore: historyStore))
    }

    init(services: AppServices = .live()) {
        recorder = services.recorder
        shortcutManager = services.shortcutManager
        audioPlayer = services.audioPlayer
        keychain = services.keychain
        transcriptionService = services.transcriptionService
        localLogger = services.localLogger
        overlayController = services.overlayController
        settingsStore = services.settingsStore
        historyStore = services.historyStore

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
        showInMenuBarOnly = settings.showInMenuBarOnly ?? false
        onboardingCompleted = settings.onboardingCompleted
        selectedSection = .record
        recorder.refreshAudioSources()
        refreshPermissionStatuses()
        loadHistory()
        refreshAPIKeyStatus()
        configureOverlayActions()
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
            await Task.yield()
            applyPresentationMode(showMainWindowWhenRegular: true)
        }
    }

    var hasAPIKey: Bool {
        (try? keychain.read())?.isEmpty == false
    }

    var localLogFileURL: URL {
        localLogger.logFileURL
    }

    var canCompleteOnboarding: Bool {
        hasAPIKey && microphonePermissionStatus == .granted && screenAudioPermissionStatus.isReady
    }

    var selectedAudioSourceName: String {
        recorder.audioSourceName(for: selectedAudioSourceID)
    }

    var captureModeDescription: String {
        captureMode.displayName
    }

    var activeAudioSourceName: String {
        if pendingUploadedAudio != nil { return "Uploaded file" }
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

        if granted {
            statusMessage = "Microphone access granted"
        } else {
            errorMessage = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
        }
    }

    func requestScreenAudioPermission() {
        let granted = ScreenAudioPermission.requestAccess()
        refreshPermissionStatuses()
        localLogger.info("Screen and system audio permission requested", metadata: ["granted": String(granted)])

        if granted {
            statusMessage = "Screen and system audio recording access granted"
        } else if ScreenAudioPermission.isSupported {
            errorMessage = "Approve Wisper in System Settings > Privacy & Security > Screen & System Audio Recording."
        } else {
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
            errorMessage = "Finish the API key, microphone, and screen/system audio steps before continuing."
            return
        }

        onboardingCompleted = true
        do {
            try saveSettings()
            selectedSection = .record
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

        guard pendingUploadedAudio == nil else {
            errorMessage = "Transcribe or cancel the uploaded audio before recording."
            return
        }

        guard hasAPIKey else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before recording. Wisper transcribes automatically when you stop."
            return
        }

        activity = .startingRecording
        localLogger.info("Recording start requested", metadata: [
            "captureMode": captureMode.rawValue,
            "audioSource": selectedAudioSourceName
        ])
        do {
            try await recorder.start(captureMode: captureMode, audioSourceID: selectedAudioSourceID)
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
            if let url = try await recorder.stop() {
                statusMessage = "Saved recording to \(url.lastPathComponent)"
                localLogger.info("Recording stopped", metadata: [
                    "file": url.lastPathComponent,
                    "durationSeconds": String(format: "%.2f", recorder.lastDurationSeconds)
                ])
                stopOverlayTimer()
                await transcribeRecording(url, durationSeconds: recorder.lastDurationSeconds)
            } else {
                activity = .idle
            }
        } catch {
            activity = .idle
            stopOverlayTimer()
            overlayController.hide()
            localLogger.error("Recording stop failed", error: error)
            errorMessage = error.localizedDescription
            statusMessage = "Recording failed"
        }
    }

    func transcribeLatestRecording() async {
        guard canBeginNewWork() else { return }
        if pendingUploadedAudio != nil {
            await transcribePendingUploadedAudio()
            return
        }

        guard let audioURL = recorder.lastRecordingURL else {
            errorMessage = "Record audio before transcribing."
            return
        }

        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before transcribing."
            return
        }

        statusMessage = "Transcribing \(audioURL.lastPathComponent)"
        await transcribeRecording(audioURL, durationSeconds: recorder.lastDurationSeconds)
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

        activity = .importingAudio
        defer { activity = .idle }
        do {
            latestTranscriptText = "Importing \(sourceURL.lastPathComponent)..."
            statusMessage = "Importing \(sourceURL.lastPathComponent)"
            localLogger.info("Audio import started", metadata: ["file": sourceURL.lastPathComponent])
            clearPendingUploadedAudio(deleteFile: true)
            let imported = try await recorder.importAudioFile(from: sourceURL)
            pendingUploadedAudio = PendingUploadedAudio(
                originalName: sourceURL.lastPathComponent,
                audioURL: imported.url,
                durationSeconds: imported.durationSeconds
            )
            latestTranscriptText = "Audio uploaded. Confirm when you are ready to transcribe."
            statusMessage = "Ready to transcribe \(sourceURL.lastPathComponent)"
            localLogger.info("Audio import completed", metadata: ["file": sourceURL.lastPathComponent])
        } catch {
            localLogger.error("Audio import failed", metadata: ["file": sourceURL.lastPathComponent], error: error)
            errorMessage = error.localizedDescription
            latestTranscriptText = error.localizedDescription
            statusMessage = "Upload failed"
        }
    }

    func transcribePendingUploadedAudio() async {
        guard canBeginNewWork() else { return }
        guard let pendingUploadedAudio else {
            errorMessage = "Drop an audio file before transcribing."
            return
        }

        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before transcribing."
            return
        }

        self.pendingUploadedAudio = nil
        await transcribeRecording(
            pendingUploadedAudio.audioURL,
            durationSeconds: pendingUploadedAudio.durationSeconds,
            source: "Uploaded file",
            originalName: pendingUploadedAudio.originalName,
            allowChunking: pendingUploadedAudio.durationSeconds != nil
        )
    }

    func cancelPendingUploadedAudio() {
        clearPendingUploadedAudio(deleteFile: true)
        latestTranscriptText = "Upload cancelled."
        statusMessage = "Ready to record"
        localLogger.info("Pending uploaded audio cancelled")
    }

    func pauseRecording() {
        recorder.pause()
        statusMessage = "Recording paused"
        localLogger.info("Recording paused")
        updateOverlay()
    }

    func resumeRecording() {
        recorder.resume()
        statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
        localLogger.info("Recording resumed")
        updateOverlay()
    }

    func discardRecording() async {
        activity = .discardingRecording
        do {
            try await recorder.discard()
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
            try await recorder.restart(captureMode: captureMode, audioSourceID: selectedAudioSourceID)
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

    func refreshAudioSources() {
        recorder.refreshAudioSources()
        statusMessage = "Audio sources refreshed"
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

    func saveShowInMenuBarOnly(_ value: Bool) {
        guard showInMenuBarOnly != value else { return }

        showInMenuBarOnly = value
        do {
            try saveSettings()
            statusMessage = value ? "Wisper will stay in the menu bar" : "Wisper will show as a normal app"
            applyPresentationMode(showMainWindowWhenRegular: true)
            localLogger.info("Presentation mode changed", metadata: ["showInMenuBarOnly": String(value)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPresentationMode(showMainWindowWhenRegular: Bool) {
        if showInMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
            hideStandardWindows()
        } else {
            NSApp.setActivationPolicy(.regular)
            if showMainWindowWhenRegular {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func hideStandardWindows() {
        for window in NSApp.windows where window is NSPanel == false {
            window.orderOut(nil)
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

    func copyTranscript(_ transcript: Transcript) {
        guard transcript.transcriptionText.isEmpty == false else {
            errorMessage = "No transcript text to copy."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.transcriptionText, forType: .string)
        statusMessage = "Transcript copied"
    }

    func revealAudio(_ transcript: Transcript) {
        guard let url = transcript.audioURL, transcript.canUseAudio else {
            errorMessage = "Audio file is missing."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func playAudio(_ transcript: Transcript) {
        guard let url = transcript.audioURL, transcript.canUseAudio else {
            errorMessage = "Audio file is missing."
            return
        }

        do {
            try audioPlayer.toggle(url: url)
            statusMessage = audioPlayer.playingURL == nil ? "Audio stopped" : "Playing audio"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportTranscript(_ transcript: Transcript) {
        guard transcript.transcriptionText.isEmpty == false else {
            errorMessage = "No transcript text to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(transcript.title).txt"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try transcript.transcriptionText.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Transcript exported"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retranscribe(_ transcript: Transcript) async {
        guard canBeginNewWork() else { return }
        guard let url = transcript.audioURL, transcript.canUseAudio else {
            errorMessage = "Audio file is missing."
            return
        }

        await transcribeRecording(url, durationSeconds: transcript.durationSeconds, replacing: transcript)
    }

    func removeFromHistory(_ transcript: Transcript) {
        history.removeAll { $0.id == transcript.id }
        do {
            try saveHistory()
            statusMessage = "Removed from history"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearPendingUploadedAudio(deleteFile: Bool) {
        guard let pendingUploadedAudio else { return }
        self.pendingUploadedAudio = nil

        if deleteFile {
            recorder.removeImportedAudio(pendingUploadedAudio.audioURL)
        }
    }

    private func transcribeRecording(
        _ audioURL: URL,
        durationSeconds: TimeInterval?,
        replacing existing: Transcript? = nil,
        source: String? = nil,
        originalName: String? = nil,
        allowChunking: Bool = true
    ) async {
        let continuesRecordingWorkflow = activity == .stoppingRecording
        if continuesRecordingWorkflow == false {
            guard activity == .idle, canBeginNewWork() else { return }
        }

        activity = .transcribing
        defer {
            isProcessing = false
            activity = .idle
        }

        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before transcribing."
            return
        }

        isProcessing = true
        statusMessage = "Transcribing \(audioURL.lastPathComponent)"
        latestTranscriptText = "Transcribing..."
        updateOverlay(detail: "Transcribing audio")
        localLogger.info("Transcription started", metadata: [
            "file": audioURL.lastPathComponent,
            "allowChunking": String(allowChunking),
            "chunkingEnabled": String(chunkingEnabled)
        ])

        let startedAt = existing?.createdAt ?? Date()
        let id = existing?.id ?? UUID()
        let pendingItem = Transcript(
            id: id,
            createdAt: startedAt,
            source: source ?? existing?.source ?? recorder.lastRecordingSourceName,
            originalName: originalName ?? existing?.originalName ?? audioURL.lastPathComponent,
            audioPath: audioURL.path,
            durationSeconds: durationSeconds,
            status: .processing,
            transcriptionText: existing?.transcriptionText ?? "",
            errorMessage: nil,
            mode: existing?.mode ?? "plain"
        )
        upsertHistoryItem(pendingItem)

        do {
            let chunkLength = chunkingEnabled && allowChunking ? chunkSeconds : nil
            let result = try await transcriptionService.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                chunkSeconds: chunkLength
            ) { progress in
                self.handleTranscriptionProgress(progress)
            }
            let transcript = Transcript(
                id: id,
                createdAt: startedAt,
                source: pendingItem.source,
                originalName: pendingItem.originalName,
                audioPath: audioURL.path,
                durationSeconds: durationSeconds,
                status: .completed,
                transcriptionText: result.text,
                errorMessage: nil,
                mode: result.mode.rawValue
            )
            upsertHistoryItem(transcript)
            try saveHistory()
            selectedSection = .history
            latestTranscriptText = result.text.isEmpty ? "No text returned." : result.text
            statusMessage = result.mode == .chunked ? "Chunked transcription complete" : "Transcription complete"
            localLogger.info("Transcription completed", metadata: [
                "file": audioURL.lastPathComponent,
                "mode": result.mode.rawValue
            ])
            updateOverlay(detail: "Transcript saved")
            hideOverlay(after: 1.4)
        } catch {
            let failed = Transcript(
                id: id,
                createdAt: startedAt,
                source: pendingItem.source,
                originalName: pendingItem.originalName,
                audioPath: audioURL.path,
                durationSeconds: durationSeconds,
                status: .failed,
                transcriptionText: pendingItem.transcriptionText,
                errorMessage: error.localizedDescription,
                mode: pendingItem.mode
            )
            upsertHistoryItem(failed)
            try? saveHistory()
            errorMessage = error.localizedDescription
            latestTranscriptText = error.localizedDescription
            statusMessage = "Transcription failed"
            localLogger.error("Transcription failed", metadata: ["file": audioURL.lastPathComponent], error: error)
            updateOverlay(detail: "Transcription failed")
            hideOverlay(after: 2.4)
        }

    }

    func setUpdateInstallPending(_ isPending: Bool) {
        isUpdateInstallPending = isPending
        if isPending {
            statusMessage = "Update will install when current work finishes"
        }
    }

    private func canBeginNewWork() -> Bool {
        guard isUpdateInstallPending == false else {
            errorMessage = "An update is waiting to install. Finish the current work before starting something new."
            return false
        }
        return true
    }

    private func handleTranscriptionProgress(_ progress: TranscriptionProgress) {
        switch progress {
        case .chunkingStart:
            statusMessage = "Splitting audio into \(chunkSeconds)-second chunks"
            updateOverlay(detail: "Splitting audio")
        case .chunkingComplete(let total):
            statusMessage = "Created \(total) chunks"
            updateOverlay(detail: "Created \(total) chunks")
        case .transcriptionStart(let label):
            statusMessage = "Transcribing \(label)"
            updateOverlay(detail: "Transcribing \(label)")
        case .transcriptionComplete(let label):
            statusMessage = "Completed \(label)"
        case .chunkComplete(let current, let total):
            latestTranscriptText = "Transcribed chunk \(current) of \(total)."
            updateOverlay(detail: "Chunk \(current) of \(total) complete")
        }
    }

    private func upsertHistoryItem(_ item: Transcript) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index] = item
        } else {
            history.insert(item, at: 0)
        }
        history.sort { $0.createdAt > $1.createdAt }
    }

    private func handleGlobalShortcut() async {
        if isProcessing { return }

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
        overlayController.show(state: overlayState())
    }

    private func updateOverlay(detail: String? = nil) {
        overlayController.update(state: overlayState(detail: detail))
    }

    private func overlayState(detail: String? = nil) -> RecordingOverlayState {
        RecordingOverlayState(
            state: isProcessing ? "Processing/transcribing" : recorder.phase.rawValue,
            detail: detail ?? statusMessage,
            elapsedText: recorder.elapsedDisplay,
            canPause: recorder.phase == .recording && recorder.canPause && isProcessing == false,
            canResume: recorder.phase == .paused && isProcessing == false,
            canStop: recorder.phase == .recording || recorder.phase == .paused,
            canDiscard: recorder.phase == .recording || recorder.phase == .paused,
            canRestart: recorder.phase == .recording || recorder.phase == .paused
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
            showInMenuBarOnly: showInMenuBarOnly,
            onboardingCompleted: onboardingCompleted
        ))
    }

    private func loadHistory() {
        do {
            history = try historyStore.load()
        } catch {
            errorMessage = "Could not load local history: \(error.localizedDescription)"
        }
    }

    private func saveHistory() throws {
        try historyStore.save(history)
    }
}
