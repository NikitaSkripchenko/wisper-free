import AppKit
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

private struct AppSettings: Codable {
    var shortcut: KeyboardShortcut
    var chunkingEnabled: Bool
    var chunkSeconds: Int
    var audioSourceID: String?
    var captureMode: RecordingCaptureMode?
    var showInMenuBarOnly: Bool?

    static let `default` = AppSettings(
        shortcut: .default,
        chunkingEnabled: true,
        chunkSeconds: 480,
        audioSourceID: nil,
        captureMode: .microphoneAndSystemAudio,
        showInMenuBarOnly: false
    )
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

@MainActor
final class AppState: ObservableObject {
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
    @Published var captureMode: RecordingCaptureMode = .microphoneAndSystemAudio
    @Published var showInMenuBarOnly = false
    @Published var pendingUploadedAudio: PendingUploadedAudio?

    let recorder = RecordingController()
    let shortcutManager = ShortcutManager()
    let audioPlayer = AudioPlaybackController()

    private let keychain = KeychainStore(service: "com.wisper.mac", account: "openai-api-key")
    private let transcriptionService = OpenAITranscriptionService()
    private let overlayController = OverlayWindowController()
    private let historyURL: URL
    private let settingsURL: URL
    private var overlayTimer: Timer?

    init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wisper", directoryHint: .isDirectory)
        historyURL = supportDirectory.appending(path: "history.json")
        settingsURL = supportDirectory.appending(path: "settings.json")
        let settings = loadSettings()
        shortcut = settings.shortcut
        chunkingEnabled = settings.chunkingEnabled
        chunkSeconds = settings.chunkSeconds
        selectedAudioSourceID = settings.audioSourceID
        captureMode = settings.captureMode ?? .microphoneAndSystemAudio
        showInMenuBarOnly = settings.showInMenuBarOnly ?? false
        recorder.refreshAudioSources()
        loadHistory()
        refreshAPIKeyStatus()
        configureOverlayActions()
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
        } catch {
            handleRecordingStartError(error)
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            refreshAPIKeyStatus()
            statusMessage = "API key removed"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() async {
        guard isProcessing == false else { return }

        guard pendingUploadedAudio == nil else {
            errorMessage = "Transcribe or cancel the uploaded audio before recording."
            return
        }

        guard hasAPIKey else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before recording. Wisper transcribes automatically when you stop."
            return
        }

        do {
            try await recorder.start(captureMode: captureMode, audioSourceID: selectedAudioSourceID)
            latestTranscriptText = "Recording..."
            statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
            showOverlay()
            startOverlayTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        do {
            if let url = try await recorder.stop() {
                statusMessage = "Saved recording to \(url.lastPathComponent)"
                stopOverlayTimer()
                await transcribeRecording(url, durationSeconds: recorder.lastDurationSeconds)
            }
        } catch {
            stopOverlayTimer()
            overlayController.hide()
            errorMessage = error.localizedDescription
            statusMessage = "Recording failed"
        }
    }

    func transcribeLatestRecording() async {
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

        do {
            latestTranscriptText = "Importing \(sourceURL.lastPathComponent)..."
            statusMessage = "Importing \(sourceURL.lastPathComponent)"
            clearPendingUploadedAudio(deleteFile: true)
            let imported = try await recorder.importAudioFile(from: sourceURL)
            pendingUploadedAudio = PendingUploadedAudio(
                originalName: sourceURL.lastPathComponent,
                audioURL: imported.url,
                durationSeconds: imported.durationSeconds
            )
            latestTranscriptText = "Audio uploaded. Confirm when you are ready to transcribe."
            statusMessage = "Ready to transcribe \(sourceURL.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            latestTranscriptText = error.localizedDescription
            statusMessage = "Upload failed"
        }
    }

    func transcribePendingUploadedAudio() async {
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
    }

    func pauseRecording() {
        recorder.pause()
        statusMessage = "Recording paused"
        updateOverlay()
    }

    func resumeRecording() {
        recorder.resume()
        statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
        updateOverlay()
    }

    func discardRecording() async {
        do {
            try await recorder.discard()
            latestTranscriptText = "Recording discarded."
            statusMessage = "Ready to record"
            stopOverlayTimer()
            overlayController.hide()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartRecording() async {
        do {
            try await recorder.restart(captureMode: captureMode, audioSourceID: selectedAudioSourceID)
            latestTranscriptText = "Recording..."
            statusMessage = "Recording from \(recorder.lastRecordingSourceName)"
            showOverlay()
            startOverlayTimer()
        } catch {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCaptureMode(_ mode: RecordingCaptureMode) {
        captureMode = mode
        do {
            try saveSettings()
            statusMessage = "Capture mode set to \(mode.displayName)"
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
        guard let apiKey = try? keychain.read(), apiKey.isEmpty == false else {
            selectedSection = .settings
            errorMessage = "Save an OpenAI API key before transcribing."
            return
        }

        isProcessing = true
        statusMessage = "Transcribing \(audioURL.lastPathComponent)"
        latestTranscriptText = "Transcribing..."
        updateOverlay(detail: "Transcribing audio")

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
            updateOverlay(detail: "Transcription failed")
            hideOverlay(after: 2.4)
        }

        isProcessing = false
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

    private func loadSettings() -> AppSettings {
        do {
            guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .default }
            let data = try Data(contentsOf: settingsURL)
            if let settings = try? JSONDecoder.wisper.decode(AppSettings.self, from: data) {
                return settings
            }

            let storedShortcut = try JSONDecoder.wisper.decode(KeyboardShortcut.self, from: data)
            var settings = AppSettings.default
            settings.shortcut = storedShortcut
            return settings
        } catch {
            return .default
        }
    }

    private func saveSettings() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.wisper.encode(AppSettings(
            shortcut: shortcut,
            chunkingEnabled: chunkingEnabled,
            chunkSeconds: chunkSeconds,
            audioSourceID: selectedAudioSourceID,
            captureMode: captureMode,
            showInMenuBarOnly: showInMenuBarOnly
        ))
        try data.write(to: settingsURL, options: .atomic)
    }

    private func loadHistory() {
        do {
            guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
            let data = try Data(contentsOf: historyURL)
            history = try JSONDecoder.wisper.decode([Transcript].self, from: data)
        } catch {
            errorMessage = "Could not load local history: \(error.localizedDescription)"
        }
    }

    private func saveHistory() throws {
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.wisper.encode(history)
        try data.write(to: historyURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var wisper: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var wisper: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
