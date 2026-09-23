import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appViewModel: AppViewModel

    var body: some View {
        Group {
            if appViewModel.onboardingCompleted {
                MeetingsView()
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

// MARK: - Shared styling helpers (used by OnboardingView and SettingsView)

/// Uppercase, tracked section label — the recurring "OPENAI KEY" / "PERMISSIONS" heading.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.Color.textTertiary)
    }
}

extension View {
    /// The card container used throughout Main/Onboarding/Settings: a bordered,
    /// rounded surface on top of the app's canvas.
    func cardBackground(cornerRadius: CGFloat = 10) -> some View {
        background(Theme.Color.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Color.border)
            }
    }

    /// The small bordered secondary button style used for "Open System Settings",
    /// "Save Key", "Reveal Log File", etc.
    func secondaryButtonStyle() -> some View {
        font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Color.textBody)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.Color.controlBorder)
            }
    }

    /// The filled accent button style used for primary actions.
    func primaryButtonStyle() -> some View {
        font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Maps a permission's readiness to the label/tint the design uses for its status chip.
func permissionStatusInfo(_ status: PermissionReadiness) -> (label: String, tint: Color) {
    switch status {
    case .granted:
        ("Allowed", Theme.Color.successText)
    case .notDetermined:
        ("Not requested", Theme.Color.textSecondary)
    case .denied:
        ("Not allowed", Theme.Color.dangerText)
    case .unsupported:
        ("Unavailable", Theme.Color.textTertiary)
    }
}

// MARK: - Onboarding

/// First run: framed around the first note the user will get rather than as a
/// wall of permissions. Left panel sets expectations; right panel walks the
/// three setup steps plus what happens next.
private struct OnboardingView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        HStack(spacing: 0) {
            introPanel
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(Theme.Color.chrome)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.Color.border).frame(width: 1)
                }

            setupPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.Color.canvas)
        .onAppear {
            appViewModel.refreshPermissionStatuses()
        }
    }

    // MARK: Left panel

    private var introPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("WISPER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Color.textTertiary)
                Text("Leave a meeting knowing what was decided and where it was said.")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.Color.text)
                Text("Three short steps, then one real meeting. Setup is finished when you have read your first note — not when this window closes.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "What a finished note looks like")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Decisions")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Color.textBody)
                    Text("Ship per-seat pricing for Q4.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.textBody)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Next steps")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Color.textBody)
                    Text("Draft the pricing page copy — Maya")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.textBody)
                }
                Rectangle().fill(Theme.Color.border.opacity(0.6)).frame(height: 1)
                Text("“We're going per seat for Q4. The usage tier is off the table.”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Color.quoteBackground)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.Color.quoteRule).frame(width: 2)
                    }
                    .clipShape(.rect(bottomTrailingRadius: 7, topTrailingRadius: 7))
                Text("Every line opens to the words it came from.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(EdgeInsets(top: 16, leading: 17, bottom: 16, trailing: 17))
            .cardBackground(cornerRadius: 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview of a finished note: decisions, next steps and a source quote.")

            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 40, leading: 34, bottom: 40, trailing: 34))
    }

    // MARK: Right panel

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Color.text)

            VStack(spacing: 10) {
                apiKeyStep
                microphoneStep
                systemAudioStep
                finalStep
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                Text("Before anything is recorded: your audio and its transcript are uploaded to OpenAI, because that is where transcription and note writing happen. The saved recording, transcript and notes stay on this Mac. Tell the people in the room that you are recording.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Color.textTertiary)

                HStack(spacing: 10) {
                    Button {
                        appViewModel.completeOnboarding()
                    } label: {
                        Label("Finish Setup", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .primaryButtonStyle()
                    .opacity(appViewModel.canCompleteOnboarding ? 1 : 0.5)
                    .disabled(appViewModel.canCompleteOnboarding == false)

                    Text("You can change any of this later in Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
        }
        .padding(EdgeInsets(top: 38, leading: 36, bottom: 38, trailing: 36))
    }

    // MARK: Step 1 — OpenAI key

    @ViewBuilder
    private var apiKeyStep: some View {
        if appViewModel.hasAPIKey {
            stepCard(state: .done) {
                stepHeader(title: "OpenAI key added", badge: "Done", badgeColor: Theme.Color.successText)
                Text("Saved to your macOS Keychain. Wisper uses it to transcribe your audio and write the notes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        } else {
            stepCard(state: .active, number: "1") {
                stepHeader(title: "Add your OpenAI key", badge: "Now", badgeColor: Theme.Color.accentSoftText)
                Text("Wisper uses this key to transcribe your audio and write the notes. It is kept in your macOS Keychain, never in a file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
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
                    .primaryButtonStyle()
                    .frame(height: 28)
                }
            }
        }
    }

    // MARK: Step 2 — Microphone

    private var microphoneStep: some View {
        let status = appViewModel.microphonePermissionStatus
        return stepCard(state: status == .granted ? .done : .active, number: "2") {
            stepHeader(
                title: "Allow the microphone",
                badge: status == .granted ? "Done" : "Now",
                badgeColor: status == .granted ? Theme.Color.successText : Theme.Color.accentSoftText
            )
            Text("This records your side of the conversation. macOS will ask you to confirm — Wisper cannot grant it for you.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            permissionAction(status: status, requestTitle: "Ask for microphone access") {
                Task { await appViewModel.requestMicrophonePermission() }
            } onOpenSettings: {
                appViewModel.openMicrophoneSettings()
            }
        }
    }

    // MARK: Step 3 — System audio (optional)

    private var systemAudioStep: some View {
        let status = appViewModel.screenAudioPermissionStatus
        return stepCard(state: status.isReady ? .done : .upcoming, number: "3") {
            stepHeader(
                title: "Allow system audio",
                badge: status == .granted ? "Done" : "Optional",
                badgeColor: status == .granted ? Theme.Color.successText : Theme.Color.textTertiary
            )
            Text("Only needed to record the other people on a call, and only on macOS 15 or later. Skip it and Wisper records just your microphone.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textTertiary)
            if status != .unsupported {
                permissionAction(status: status, requestTitle: "Allow system audio") {
                    appViewModel.requestScreenAudioPermission()
                } onOpenSettings: {
                    appViewModel.openScreenAudioSettings()
                }
            }
        }
    }

    // MARK: Step 4 — Record or import (informational; no control in this app at onboarding time)

    private var finalStep: some View {
        stepCard(state: .upcoming, number: "4") {
            Text("Record or import one meeting")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Already have a file? Import it and skip straight to reading a note.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    // MARK: Step building blocks

    private enum StepState { case done, active, upcoming }

    @ViewBuilder
    private func stepCard(state: StepState, number: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 13) {
            stepBadge(state: state, number: number)
            VStack(alignment: .leading, spacing: state == .active ? 9 : 3) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(state == .active ? EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17)
                                   : EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(state == .upcoming ? Theme.Color.chrome.opacity(0.5) : Theme.Color.card,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(state == .active ? Theme.Color.accent : Theme.Color.border, lineWidth: state == .active ? 1.5 : 1)
        }
    }

    @ViewBuilder
    private func stepBadge(state: StepState, number: String?) -> some View {
        switch state {
        case .done:
            Circle()
                .fill(Theme.Color.successSoft)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Color.successText)
                }
                .accessibilityHidden(true)
        case .active:
            Circle()
                .fill(Theme.Color.accent)
                .frame(width: 22, height: 22)
                .overlay {
                    Text(number ?? "")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
        case .upcoming:
            Circle()
                .strokeBorder(Theme.Color.controlBorder, lineWidth: 1.5)
                .frame(width: 22, height: 22)
                .overlay {
                    Text(number ?? "")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                .accessibilityHidden(true)
        }
    }

    private func stepHeader(title: String, badge: String, badgeColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.Color.text)
            Text(badge)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(badgeColor)
        }
    }

    @ViewBuilder
    private func permissionAction(
        status: PermissionReadiness,
        requestTitle: String,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        switch status {
        case .granted, .unsupported:
            EmptyView()
        case .notDetermined:
            Button(requestTitle, action: onRequest)
                .buttonStyle(.plain)
                .primaryButtonStyle()
        case .denied:
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.plain)
                .primaryButtonStyle()
        }
    }
}
