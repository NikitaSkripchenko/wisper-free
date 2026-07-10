import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appViewModel: AppViewModel

    var body: some View {
        Group {
            if appViewModel.onboardingCompleted {
                NavigationSplitView {
                    List(SidebarSection.allCases, selection: $appViewModel.selectedSection) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                    .navigationTitle("Wisper")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    switch appViewModel.selectedSection ?? .record {
                    case .record:
                        RecordView()
                    case .history:
                        HistoryView()
                    case .settings:
                        SettingsView()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .alert("Wisper", isPresented: errorBinding) {
            Button("OK") {
                appViewModel.errorMessage = nil
            }
        } message: {
            Text(appViewModel.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.errorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    appViewModel.errorMessage = nil
                }
            }
        )
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                HeaderView(
                    eyebrow: "Setup",
                    title: "Prepare Wisper to record.",
                    subtitle: "Finish the required local permissions before your first transcription."
                )
                .padding(.bottom, 8)
            }

            Section("OpenAI") {
                LabeledContent("API key", value: appViewModel.apiKeyStatus)

                HStack {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        appViewModel.saveAPIKey(apiKey)
                        apiKey = ""
                    } label: {
                        Label("Save", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Permissions") {
                PermissionSetupRow(
                    title: "Microphone",
                    status: appViewModel.microphonePermissionStatus,
                    requestTitle: "Request",
                    onRequest: { Task { await appViewModel.requestMicrophonePermission() } },
                    onOpenSettings: { appViewModel.openMicrophoneSettings() }
                )

                PermissionSetupRow(
                    title: "Screen & System Audio",
                    status: appViewModel.screenAudioPermissionStatus,
                    requestTitle: "Request",
                    onRequest: { appViewModel.requestScreenAudioPermission() },
                    onOpenSettings: { appViewModel.openScreenAudioSettings() }
                )
            }

            Section {
                Button {
                    appViewModel.completeOnboarding()
                } label: {
                    Label("Finish Setup", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appViewModel.canCompleteOnboarding == false)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Onboarding")
        .onAppear {
            appViewModel.refreshPermissionStatuses()
        }
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}

private struct PermissionSetupRow: View {
    let title: String
    let status: PermissionReadiness
    let requestTitle: String
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                PermissionStatusBadge(status: status)
            }

            Spacer()

            Button(requestTitle, action: onRequest)
                .disabled(status == .granted || status == .unsupported)

            Button("Settings", action: onOpenSettings)
                .disabled(status == .unsupported)
        }
    }
}

private struct PermissionStatusBadge: View {
    let status: PermissionReadiness

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .granted:
            "Ready"
        case .notDetermined:
            "Needs Approval"
        case .denied:
            "Blocked"
        case .unsupported:
            "Unsupported"
        }
    }

    private var tint: Color {
        switch status {
        case .granted:
            .green
        case .notDetermined:
            .orange
        case .denied:
            .red
        case .unsupported:
            .secondary
        }
    }
}

private struct RecordView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var isFileDropTargeted = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 28) {
                HeaderView(
                    eyebrow: "Native macOS transcription",
                    title: "Record clean audio, then transcribe it.",
                    subtitle: "Wisper uses SwiftUI, system controls, Keychain, and the macOS microphone stack."
                )

                VStack(spacing: 18) {
                    Image(systemName: recordIconName)
                        .font(.system(size: 72, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(recordIconColor)

                    Text(appViewModel.recorder.isRecording || appViewModel.isProcessing ? appViewModel.recorder.elapsedDisplay : "Ready")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()

                    Text(appViewModel.statusMessage)
                        .foregroundStyle(.secondary)

                    Text("Capture: \(appViewModel.captureModeDescription) • Source: \(appViewModel.activeAudioSourceName)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        Picker("Capture Mode", selection: captureModeBinding) {
                            ForEach(RecordingCaptureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                        .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)

                        Picker("Microphone", selection: audioSourceBinding) {
                            Text("System Default").tag("")
                            ForEach(appViewModel.recorder.audioSources) { source in
                                Text(source.name).tag(source.id)
                            }
                            if let selectedAudioSourceID = appViewModel.selectedAudioSourceID,
                               appViewModel.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                                Text("Unavailable Source").tag(selectedAudioSourceID)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                        .disabled(appViewModel.captureMode.usesMicrophone == false || appViewModel.recorder.isRecording || appViewModel.isProcessing)

                        Button("Refresh") {
                            appViewModel.refreshAudioSources()
                        }
                        .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if appViewModel.recorder.phase == .recording || appViewModel.recorder.phase == .paused {
                                Task { await appViewModel.stopRecording() }
                            } else {
                                Task { await appViewModel.startRecording() }
                            }
                        } label: {
                            Label(primaryRecordLabel, systemImage: appViewModel.recorder.isRecording ? "stop.fill" : "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appViewModel.isProcessing)

                        Button {
                            if appViewModel.recorder.isPaused {
                                appViewModel.resumeRecording()
                            } else {
                                appViewModel.pauseRecording()
                            }
                        } label: {
                            Label(appViewModel.recorder.isPaused ? "Resume" : "Pause", systemImage: appViewModel.recorder.isPaused ? "play.fill" : "pause.fill")
                        }
                        .controlSize(.large)
                        .disabled(appViewModel.recorder.canPause == false || appViewModel.isProcessing)

                        Button(role: .destructive) {
                            Task { await appViewModel.discardRecording() }
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .controlSize(.large)
                        .disabled(appViewModel.recorder.isRecording == false || appViewModel.isProcessing)

                        Button {
                            Task { await appViewModel.transcribeLatestRecording() }
                        } label: {
                            Label("Transcribe", systemImage: "text.quote")
                        }
                        .controlSize(.large)
                        .disabled(appViewModel.recorder.isRecording || appViewModel.recorder.lastRecordingURL == nil || appViewModel.isProcessing)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.quaternary)
                }

                if let recordingURL = appViewModel.recorder.lastRecordingURL {
                    LabeledContent("Last recording", value: recordingURL.lastPathComponent)
                        .font(.callout)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Latest Transcript")
                        .font(.headline)
                    Text(appViewModel.latestTranscriptText)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary)
                }

                Spacer()
            }
            .padding(32)

            if isFileDropTargeted {
                AudioFileDropOverlay(isBusy: appViewModel.recorder.isRecording || appViewModel.isProcessing)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
            } else if let pendingUploadedAudio = appViewModel.pendingUploadedAudio {
                AudioUploadConfirmationOverlay(
                    upload: pendingUploadedAudio,
                    onConfirm: { Task { await appViewModel.transcribePendingUploadedAudio() } },
                    onCancel: { appViewModel.cancelPendingUploadedAudio() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard fileURLs.isEmpty == false else { return false }
            Task { await appViewModel.importDroppedAudioFiles(fileURLs) }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.16)) {
                isFileDropTargeted = isTargeted
            }
        }
    }

    private var primaryRecordLabel: String {
        if appViewModel.recorder.phase == .paused { return "Stop and Transcribe" }
        if appViewModel.recorder.phase == .recording { return "Stop and Transcribe" }
        return "Start Recording"
    }

    private var recordIconName: String {
        if appViewModel.isProcessing { return "waveform.badge.magnifyingglass" }
        if appViewModel.recorder.isPaused { return "pause.circle.fill" }
        if appViewModel.recorder.isRecording { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private var recordIconColor: Color {
        if appViewModel.isProcessing { return .blue }
        if appViewModel.recorder.isPaused { return .orange }
        if appViewModel.recorder.isRecording { return .red }
        return .blue
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appViewModel.selectedAudioSourceID ?? "" },
            set: { appViewModel.saveAudioSource($0.isEmpty ? nil : $0) }
        )
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}

private struct AudioUploadConfirmationOverlay: View {
    let upload: PendingUploadedAudio
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 58, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)

                VStack(spacing: 6) {
                    Text("Transcribe this audio?")
                        .font(.title2.weight(.semibold))

                    Text(upload.originalName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(durationText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("The file has been imported locally. Transcription will start only after you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .controlSize(.large)

                    Button(action: onConfirm) {
                        Label("Transcribe File", systemImage: "text.quote")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(34)
            .frame(maxWidth: 500)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.blue.opacity(0.65), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        }
    }

    private var durationText: String {
        guard let durationSeconds = upload.durationSeconds else {
            return "Duration unavailable"
        }

        let totalSeconds = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct AudioFileDropOverlay: View {
    let isBusy: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: isBusy ? "hourglass" : "waveform.badge.plus")
                    .font(.system(size: 58, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isBusy ? .orange : .blue)

                Text(isBusy ? "Wisper is busy" : "Drop audio to upload")
                    .font(.title2.weight(.semibold))

                Text(isBusy ? "Finish the current recording or transcription before uploading a file." : "Supported: \(RecordingController.supportedAudioFileTypesDescription).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(34)
            .frame(maxWidth: 480)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(isBusy ? .orange.opacity(0.6) : .blue.opacity(0.65), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        }
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var appViewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeaderView(
                eyebrow: "Local history",
                title: "Transcripts stay on this Mac.",
                subtitle: "Completed transcripts are stored in Application Support and listed with native rows."
            )

            if appViewModel.history.isEmpty {
                ContentUnavailableView(
                    "No Transcripts Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Record audio and transcribe it to build your local archive.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appViewModel.history) { transcript in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(transcript.title)
                                .font(.headline)
                            Spacer()
                            StatusPill(status: transcript.status)
                            Text(transcript.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(historyPreview(transcript))
                            .lineLimit(3)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Text(historyMetadata(transcript))
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Spacer()

                            Button(appViewModel.audioPlayer.playingURL == transcript.audioURL ? "Stop" : "Play") {
                                appViewModel.playAudio(transcript)
                            }
                            .disabled(transcript.canUseAudio == false)

                            Menu("Actions") {
                                Button("Reveal Audio in Finder") { appViewModel.revealAudio(transcript) }
                                    .disabled(transcript.canUseAudio == false)
                                Button("Copy Transcript") { appViewModel.copyTranscript(transcript) }
                                    .disabled(transcript.transcriptionText.isEmpty)
                                Button("Save Transcript...") { appViewModel.exportTranscript(transcript) }
                                    .disabled(transcript.transcriptionText.isEmpty)
                                Button("Retranscribe") {
                                    Task { await appViewModel.retranscribe(transcript) }
                                }
                                .disabled(transcript.canUseAudio == false || appViewModel.isProcessing)
                                Divider()
                                Button("Remove from History", role: .destructive) {
                                    appViewModel.removeFromHistory(transcript)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(32)
    }

    private func historyPreview(_ transcript: Transcript) -> String {
        if transcript.status == .failed {
            return transcript.errorMessage ?? "Transcription failed. Use Actions to retranscribe this audio."
        }

        if transcript.status == .processing {
            return "Transcribing audio..."
        }

        return transcript.transcriptionText.isEmpty ? "No transcript text is stored for this recording." : transcript.transcriptionText
    }

    private func historyMetadata(_ transcript: Transcript) -> String {
        var parts = [transcript.source]
        if let duration = transcript.durationSeconds {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            parts.append(String(format: "%d:%02d", minutes, seconds))
        }
        if transcript.canUseAudio == false {
            parts.append("audio missing")
        }
        return parts.joined(separator: " - ")
    }
}

private struct StatusPill: View {
    let status: HistoryStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .completed: "Transcribed"
        case .failed: "Needs Retry"
        case .processing: "Processing"
        }
    }

    private var tint: Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .processing: .blue
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                LabeledContent("API key", value: appViewModel.apiKeyStatus)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        appViewModel.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Delete Key", role: .destructive) {
                        appViewModel.deleteAPIKey()
                    }
                    .disabled(appViewModel.hasAPIKey == false)
                }
            }

            Section("Audio Capture") {
                Picker("Capture mode", selection: captureModeBinding) {
                    ForEach(RecordingCaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)

                Text("System Audio and Microphone + System Audio capture what you hear, including headset output. These modes require macOS 15 or later in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Microphone", selection: audioSourceBinding) {
                    Text("System Default").tag("")
                    ForEach(appViewModel.recorder.audioSources) { source in
                        Text(source.name).tag(source.id)
                    }
                    if let selectedAudioSourceID = appViewModel.selectedAudioSourceID,
                       appViewModel.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                        Text("Unavailable Source").tag(selectedAudioSourceID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appViewModel.captureMode.usesMicrophone == false || appViewModel.recorder.isRecording || appViewModel.isProcessing)

                HStack {
                    LabeledContent("Selected", value: appViewModel.selectedAudioSourceName)
                    Spacer()
                    Button("Refresh") {
                        appViewModel.refreshAudioSources()
                    }
                    .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)
                }

                Text("Choose the microphone Wisper should use when the capture mode includes microphone audio. Existing recordings keep their original source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionSetupRow(
                    title: "Microphone",
                    status: appViewModel.microphonePermissionStatus,
                    requestTitle: "Request",
                    onRequest: { Task { await appViewModel.requestMicrophonePermission() } },
                    onOpenSettings: { appViewModel.openMicrophoneSettings() }
                )

                PermissionSetupRow(
                    title: "Screen & System Audio",
                    status: appViewModel.screenAudioPermissionStatus,
                    requestTitle: "Request",
                    onRequest: { appViewModel.requestScreenAudioPermission() },
                    onOpenSettings: { appViewModel.openScreenAudioSettings() }
                )
            }

            Section("Appearance") {
                Toggle("Show in menu bar only", isOn: Binding(
                    get: { appViewModel.showInMenuBarOnly },
                    set: { appViewModel.saveShowInMenuBarOnly($0) }
                ))

                Text("When enabled, Wisper hides from the Dock and lives in the menu bar. When disabled, Wisper opens as a normal app window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Shortcut") {
                LabeledContent("Current", value: appViewModel.shortcut.displayText)

                ShortcutCaptureField(shortcut: $appViewModel.shortcut) { shortcut in
                    appViewModel.saveShortcut(shortcut)
                } onInvalid: {
                    appViewModel.shortcutCaptureMessage = "Press at least one modifier plus a key."
                }
                .frame(height: 28)

                Text(appViewModel.shortcutCaptureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to Command Shift Space") {
                    appViewModel.saveShortcut(.default)
                }
            }

            Section("Chunking") {
                Toggle("Chunk long recordings", isOn: Binding(
                    get: { appViewModel.chunkingEnabled },
                    set: { appViewModel.saveChunkingSettings(enabled: $0) }
                ))

                Stepper(value: Binding(
                    get: { appViewModel.chunkSeconds },
                    set: { appViewModel.saveChunkingSettings(seconds: $0) }
                ), in: 60...3_600, step: 60) {
                    LabeledContent("Chunk length", value: "\(appViewModel.chunkSeconds) seconds")
                }
                .disabled(appViewModel.chunkingEnabled == false)

                Text("When a recording is longer than this, Wisper splits it into local .m4a chunks, transcribes each chunk, then stitches the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Wisper stores the API key in Keychain. Recordings and transcript history are stored locally under Application Support.")
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Local log", value: appViewModel.localLogFileURL.path)

                Button {
                    appViewModel.revealLocalLogFile()
                } label: {
                    Label("Reveal Log File", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
        .onAppear {
            appViewModel.refreshPermissionStatuses()
        }
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appViewModel.selectedAudioSourceID ?? "" },
            set: { appViewModel.saveAudioSource($0.isEmpty ? nil : $0) }
        )
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}

private struct HeaderView: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)

            Text(title)
                .font(.largeTitle.weight(.semibold))

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
