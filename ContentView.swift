import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $appState.selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Wisper")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            switch appState.selectedSection ?? .record {
            case .record:
                RecordView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .alert("Wisper", isPresented: errorBinding) {
            Button("OK") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    appState.errorMessage = nil
                }
            }
        )
    }
}

private struct RecordView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
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

                Text(appState.recorder.isRecording || appState.isProcessing ? appState.recorder.elapsedDisplay : "Ready")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()

                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)

                Text("Source: \(appState.activeAudioSourceName)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Picker("Audio Source", selection: audioSourceBinding) {
                        Text("System Default").tag("")
                        ForEach(appState.recorder.audioSources) { source in
                            Text(source.name).tag(source.id)
                        }
                        if let selectedAudioSourceID = appState.selectedAudioSourceID,
                           appState.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                            Text("Unavailable Source").tag(selectedAudioSourceID)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    .disabled(appState.recorder.isRecording || appState.isProcessing)

                    Button("Refresh") {
                        appState.refreshAudioSources()
                    }
                    .disabled(appState.recorder.isRecording || appState.isProcessing)
                }

                HStack(spacing: 12) {
                    Button {
                        if appState.recorder.phase == .recording || appState.recorder.phase == .paused {
                            Task { await appState.stopRecording() }
                        } else {
                            Task { await appState.startRecording() }
                        }
                    } label: {
                        Label(primaryRecordLabel, systemImage: appState.recorder.isRecording ? "stop.fill" : "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(appState.isProcessing)

                    Button {
                        if appState.recorder.isPaused {
                            appState.resumeRecording()
                        } else {
                            appState.pauseRecording()
                        }
                    } label: {
                        Label(appState.recorder.isPaused ? "Resume" : "Pause", systemImage: appState.recorder.isPaused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.large)
                    .disabled(appState.recorder.isRecording == false || appState.isProcessing)

                    Button(role: .destructive) {
                        Task { await appState.discardRecording() }
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .controlSize(.large)
                    .disabled(appState.recorder.isRecording == false || appState.isProcessing)

                    Button {
                        Task { await appState.transcribeLatestRecording() }
                    } label: {
                        Label("Transcribe", systemImage: "text.quote")
                    }
                    .controlSize(.large)
                    .disabled(appState.recorder.isRecording || appState.recorder.lastRecordingURL == nil || appState.isProcessing)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.quaternary)
            }

            if let recordingURL = appState.recorder.lastRecordingURL {
                LabeledContent("Last recording", value: recordingURL.lastPathComponent)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Latest Transcript")
                    .font(.headline)
                Text(appState.latestTranscriptText)
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
    }

    private var primaryRecordLabel: String {
        if appState.recorder.phase == .paused { return "Stop and Transcribe" }
        if appState.recorder.phase == .recording { return "Stop and Transcribe" }
        return "Start Recording"
    }

    private var recordIconName: String {
        if appState.isProcessing { return "waveform.badge.magnifyingglass" }
        if appState.recorder.isPaused { return "pause.circle.fill" }
        if appState.recorder.isRecording { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private var recordIconColor: Color {
        if appState.isProcessing { return .blue }
        if appState.recorder.isPaused { return .orange }
        if appState.recorder.isRecording { return .red }
        return .blue
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appState.selectedAudioSourceID ?? "" },
            set: { appState.saveAudioSource($0.isEmpty ? nil : $0) }
        )
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeaderView(
                eyebrow: "Local history",
                title: "Transcripts stay on this Mac.",
                subtitle: "Completed transcripts are stored in Application Support and listed with native rows."
            )

            if appState.history.isEmpty {
                ContentUnavailableView(
                    "No Transcripts Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Record audio and transcribe it to build your local archive.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.history) { transcript in
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

                            Button(appState.audioPlayer.playingURL == transcript.audioURL ? "Stop" : "Play") {
                                appState.playAudio(transcript)
                            }
                            .disabled(transcript.canUseAudio == false)

                            Menu("Actions") {
                                Button("Reveal Audio in Finder") { appState.revealAudio(transcript) }
                                    .disabled(transcript.canUseAudio == false)
                                Button("Copy Transcript") { appState.copyTranscript(transcript) }
                                    .disabled(transcript.transcriptionText.isEmpty)
                                Button("Save Transcript...") { appState.exportTranscript(transcript) }
                                    .disabled(transcript.transcriptionText.isEmpty)
                                Button("Retranscribe") {
                                    Task { await appState.retranscribe(transcript) }
                                }
                                .disabled(transcript.canUseAudio == false || appState.isProcessing)
                                Divider()
                                Button("Remove from History", role: .destructive) {
                                    appState.removeFromHistory(transcript)
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
    @EnvironmentObject private var appState: AppState
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                LabeledContent("API key", value: appState.apiKeyStatus)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        appState.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Delete Key", role: .destructive) {
                        appState.deleteAPIKey()
                    }
                    .disabled(appState.hasAPIKey == false)
                }
            }

            Section("Audio Source") {
                Picker("Source", selection: audioSourceBinding) {
                    Text("System Default").tag("")
                    ForEach(appState.recorder.audioSources) { source in
                        Text(source.name).tag(source.id)
                    }
                    if let selectedAudioSourceID = appState.selectedAudioSourceID,
                       appState.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                        Text("Unavailable Source").tag(selectedAudioSourceID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.recorder.isRecording || appState.isProcessing)

                HStack {
                    LabeledContent("Selected", value: appState.selectedAudioSourceName)
                    Spacer()
                    Button("Refresh") {
                        appState.refreshAudioSources()
                    }
                    .disabled(appState.recorder.isRecording || appState.isProcessing)
                }

                Text("Choose the input Wisper should use for new recordings. Existing recordings keep their original source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Shortcut") {
                LabeledContent("Current", value: appState.shortcut.displayText)

                ShortcutCaptureField(shortcut: $appState.shortcut) { shortcut in
                    appState.saveShortcut(shortcut)
                } onInvalid: {
                    appState.shortcutCaptureMessage = "Press at least one modifier plus a key."
                }
                .frame(height: 28)

                Text(appState.shortcutCaptureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to Command Shift Space") {
                    appState.saveShortcut(.default)
                }
            }

            Section("Chunking") {
                Toggle("Chunk long recordings", isOn: Binding(
                    get: { appState.chunkingEnabled },
                    set: { appState.saveChunkingSettings(enabled: $0) }
                ))

                Stepper(value: Binding(
                    get: { appState.chunkSeconds },
                    set: { appState.saveChunkingSettings(seconds: $0) }
                ), in: 60...3_600, step: 60) {
                    LabeledContent("Chunk length", value: "\(appState.chunkSeconds) seconds")
                }
                .disabled(appState.chunkingEnabled == false)

                Text("When a recording is longer than this, Wisper splits it into local .m4a chunks, transcribes each chunk, then stitches the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Wisper stores the API key in Keychain. Recordings and transcript history are stored locally under Application Support.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appState.selectedAudioSourceID ?? "" },
            set: { appState.saveAudioSource($0.isEmpty ? nil : $0) }
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
