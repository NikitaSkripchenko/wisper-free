import SwiftUI

/// Settings: the key, the permissions, recording, appearance, shortcut and
/// storage — one card per section, matching the Meetings workspace's visual
/// language rather than a native macOS Form.
struct SettingsView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Color.text)

                apiKeySection
                permissionsSection
                recordingSection
                shortcutSection
                storageSection
            }
            .padding(EdgeInsets(top: 24, leading: 36, bottom: 28, trailing: 36))
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.Color.canvas)
        .navigationTitle("Settings")
        .onAppear {
            appViewModel.refreshPermissionStatuses()
            appViewModel.refreshMeetingStorageStats()
        }
    }

    // MARK: - OpenAI key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "OpenAI key")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Text("API key")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Color.text)
                    Text(appViewModel.apiKeyStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appViewModel.hasAPIKey ? Theme.Color.successText : Theme.Color.textTertiary)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(
                            appViewModel.hasAPIKey ? Theme.Color.successSoft : Theme.Color.segmentTrack,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                Text("Kept in your macOS Keychain, never in a file next to your recordings. Used for transcription and for writing notes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textTertiary)

                HStack(spacing: 8) {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.Color.controlBorder)
                        }
                        .accessibilityLabel("OpenAI API key")

                    Button("Save Key") {
                        appViewModel.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .buttonStyle(.plain)
                    .secondaryButtonStyle()

                    Button("Delete Key", role: .destructive) {
                        appViewModel.deleteAPIKey()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.dangerText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.Color.controlBorder)
                    }
                    .disabled(appViewModel.hasAPIKey == false)
                    .opacity(appViewModel.hasAPIKey ? 1 : 0.4)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .cardBackground()
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Permissions")
            VStack(spacing: 0) {
                permissionRow(
                    title: "Microphone",
                    description: "Records your side of the conversation.",
                    status: appViewModel.microphonePermissionStatus,
                    requestTitle: "Request Access",
                    onRequest: { Task { await appViewModel.requestMicrophonePermission() } },
                    onOpenSettings: { appViewModel.openMicrophoneSettings() }
                )
                Rectangle().fill(Theme.Color.border.opacity(0.6)).frame(height: 1).padding(.leading, 16)
                permissionRow(
                    title: "System audio",
                    description: "Records the other people on the call. Needed only for the “Microphone + system audio” source. Requires macOS 15 or later.",
                    status: appViewModel.screenAudioPermissionStatus,
                    requestTitle: "Request Access",
                    onRequest: { appViewModel.requestScreenAudioPermission() },
                    onOpenSettings: { appViewModel.openScreenAudioSettings() }
                )
            }
            .cardBackground()
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        status: PermissionReadiness,
        requestTitle: String,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        let info = permissionStatusInfo(status)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Color.text)
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(info.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(info.tint)
                if status == .notDetermined {
                    Button(requestTitle, action: onRequest)
                        .buttonStyle(.plain)
                        .secondaryButtonStyle()
                } else if status == .denied {
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.plain)
                        .primaryButtonStyle()
                }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
    }

    // MARK: - Recording

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recording")
            VStack(spacing: 0) {
                HStack {
                    Text("Capture mode")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Color.text)
                    Spacer()
                    Picker("Capture mode", selection: captureModeBinding) {
                        ForEach(RecordingCaptureMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)
                }
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))

                Rectangle().fill(Theme.Color.border.opacity(0.6)).frame(height: 1).padding(.leading, 16)
                HStack {
                    Text("Microphone")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Color.text)
                    Spacer()
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
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(appViewModel.captureMode.usesMicrophone == false || appViewModel.recorder.isRecording || appViewModel.isProcessing)
                }
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))

                Rectangle().fill(Theme.Color.border.opacity(0.6)).frame(height: 1).padding(.leading, 16)
                HStack {
                    Text("Selected")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Spacer()
                    Text(appViewModel.selectedAudioSourceName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 13, trailing: 16))

                Rectangle().fill(Theme.Color.border.opacity(0.6)).frame(height: 1).padding(.leading, 16)
                Toggle(isOn: showOverlayBinding) {
                    Text("Show the floating overlay while recording")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.Color.text)
                }
                .toggleStyle(.checkbox)
                .tint(Theme.Color.accent)
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            }
            .cardBackground()
        }
    }

    // MARK: - Global shortcut

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Global Shortcut")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Start and stop shortcut")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Color.text)
                    Spacer()
                    Text(appViewModel.shortcut.displayText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Theme.Color.segmentTrack, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.Color.controlBorder)
                        }
                }

                ShortcutCaptureField(shortcut: $appViewModel.shortcut) { shortcut in
                    appViewModel.saveShortcut(shortcut)
                } onInvalid: {
                    appViewModel.shortcutCaptureMessage = "Press at least one modifier plus a key."
                }
                .frame(height: 28)

                Text(appViewModel.shortcutCaptureMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textTertiary)

                Button("Reset to Command Shift Space") {
                    appViewModel.saveShortcut(.default)
                }
                .buttonStyle(.plain)
                .secondaryButtonStyle()
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            .cardBackground()
        }
    }

    // MARK: - Storage & diagnostics

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Where Your Data Goes")
            VStack(alignment: .leading, spacing: 12) {
                Text("Your audio and the text of your transcript are uploaded to OpenAI — that is where transcription and note writing happen. Nothing is processed on this Mac alone. Everything Wisper keeps afterwards — the recording, the transcript and the notes — is written to this Mac only.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Color.textBody)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppStorageLocation.supportDirectory.path)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(MeetingStorageStats.summaryText(
                            meetingCount: appViewModel.meetingCoordinator.records.count,
                            audioBytes: appViewModel.meetingStorageAudioBytes
                        ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Color.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button("Reveal in Finder") {
                        appViewModel.revealMeetingStorage()
                    }
                    .buttonStyle(.plain)
                    .secondaryButtonStyle()
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .cardBackground()

            HStack(spacing: 14) {
                Text("If something fails, the log records what happened. It stays on this Mac and is plain text you can read.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer(minLength: 0)
                Button("Open log") {
                    appViewModel.revealLocalLogFile()
                }
                .buttonStyle(.plain)
                .secondaryButtonStyle()
            }
        }
    }

    // MARK: - Bindings

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

    private var showOverlayBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.showOverlayWhileRecording },
            set: { appViewModel.saveShowOverlayWhileRecording($0) }
        )
    }
}
