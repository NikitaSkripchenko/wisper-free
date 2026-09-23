import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if appViewModel.onboardingCompleted {
                MeetingsView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.curve(0.32), value: appViewModel.onboardingCompleted)
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
/// setup steps. The first unfinished step is highlighted, but every
/// unfinished step keeps its control so the order is a suggestion, not a gate.
private struct OnboardingView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apiKey = ""
    @FocusState private var isKeyFieldFocused: Bool

    private enum StepState: Equatable { case done, active, upcoming }

    private var keyState: StepState { appViewModel.hasAPIKey ? .done : .active }

    private var microphoneState: StepState {
        if appViewModel.microphonePermissionStatus == .granted { return .done }
        return keyState == .done ? .active : .upcoming
    }

    private var systemAudioState: StepState {
        if appViewModel.screenAudioPermissionStatus == .granted { return .done }
        return microphoneState == .done && keyState == .done ? .active : .upcoming
    }

    private var showsSystemAudioStep: Bool {
        appViewModel.screenAudioPermissionStatus != .unsupported
    }

    private var requiredDoneCount: Int {
        [keyState, microphoneState].filter { $0 == .done }.count
    }

    private var stepMotion: Animation? {
        reduceMotion ? nil : Theme.Motion.stageComplete
    }

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
            if appViewModel.hasAPIKey == false { isKeyFieldFocused = true }
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
                    .fixedSize(horizontal: false, vertical: true)
                Text("Two quick steps, then record your first meeting.")
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
            HStack(alignment: .firstTextBaseline) {
                Text("Setup")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Color.text)
                Spacer()
                Text("\(requiredDoneCount) of 2 done")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(requiredDoneCount == 2 ? Theme.Color.successText : Theme.Color.textTertiary)
                    .contentTransition(.numericText())
            }

            VStack(spacing: 10) {
                apiKeyStep
                microphoneStep
                if showsSystemAudioStep {
                    systemAudioStep
                }
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 38, leading: 36, bottom: 38, trailing: 36))
        .animation(stepMotion, value: [keyState, microphoneState, systemAudioState])
        .animation(stepMotion, value: appViewModel.screenAudioPermissionStatus)
        .animation(stepMotion, value: appViewModel.microphonePermissionStatus)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your audio and its transcript are sent to OpenAI only after you stop recording — that is where transcription and note writing happen. The recording, transcript and notes stay on this Mac. Tell the people in the room that you are recording.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.privacy")

            HStack(spacing: 12) {
                Button {
                    appViewModel.completeOnboarding()
                } label: {
                    Label("Start Using Wisper", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .primaryButtonStyle()
                .opacity(appViewModel.canCompleteOnboarding ? 1 : 0.45)
                .disabled(appViewModel.canCompleteOnboarding == false)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.finish")

                Text(appViewModel.canCompleteOnboarding
                     ? "Then press \(appViewModel.shortcut.symbolText) anywhere to record."
                     : "You can change any of this later in Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(appViewModel.canCompleteOnboarding ? Theme.Color.textSecondary : Theme.Color.textTertiary)
                    .contentTransition(.opacity)
            }
            .animation(stepMotion, value: appViewModel.canCompleteOnboarding)
        }
    }

    // MARK: Step 1 — OpenAI key

    private var apiKeyStep: some View {
        stepCard(state: keyState, number: "1") {
            stepHeader(title: keyState == .done ? "OpenAI key added" : "Add your OpenAI key", state: keyState)
            if keyState == .done {
                stepDetail("Saved to your macOS Keychain.", state: keyState)
            } else {
                stepDetail("Wisper uses it to transcribe your audio and write the notes. It is kept in your macOS Keychain, never in a file.", state: keyState)
                HStack(spacing: 8) {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isKeyFieldFocused ? Theme.Color.accent : Theme.Color.controlBorder)
                        }
                        .focused($isKeyFieldFocused)
                        .onSubmit(saveKey)
                        .accessibilityLabel("OpenAI API key")

                    Button("Save Key", action: saveKey)
                        .buttonStyle(.plain)
                        .primaryButtonStyle()
                        .frame(height: 28)
                        .opacity(trimmedKey.isEmpty ? 0.45 : 1)
                        .disabled(trimmedKey.isEmpty)
                }
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    Label("Get a key from OpenAI", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Color.accent)
                }
            }
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey() {
        guard trimmedKey.isEmpty == false else { return }
        appViewModel.saveAPIKey(apiKey)
        apiKey = ""
    }

    // MARK: Step 2 — Microphone

    private var microphoneStep: some View {
        let status = appViewModel.microphonePermissionStatus
        return stepCard(state: microphoneState, number: "2") {
            stepHeader(title: microphoneState == .done ? "Microphone allowed" : "Allow the microphone", state: microphoneState)
            switch status {
            case .granted:
                stepDetail("Wisper can hear your side of the conversation.", state: microphoneState)
            case .denied:
                stepDetail("Microphone access is off. Turn on Wisper in Privacy & Security → Microphone, then come back here.", state: microphoneState)
                permissionButton("Open System Settings", state: microphoneState) {
                    appViewModel.openMicrophoneSettings()
                }
            case .notDetermined, .unsupported:
                stepDetail("Records your side of the conversation. macOS will ask you to confirm.", state: microphoneState)
                permissionButton("Allow Microphone", state: microphoneState) {
                    Task { await appViewModel.requestMicrophonePermission() }
                }
            }
        }
    }

    // MARK: Step 3 — System audio (optional)

    private var systemAudioStep: some View {
        let status = appViewModel.screenAudioPermissionStatus
        return stepCard(state: systemAudioState, number: "3") {
            stepHeader(title: systemAudioState == .done ? "System audio allowed" : "Allow system audio", state: systemAudioState, optional: true)
            switch status {
            case .granted:
                stepDetail("Wisper can record the other people on a call.", state: systemAudioState)
            case .denied:
                stepDetail("Turn on Wisper in Privacy & Security → Screen & System Audio Recording. macOS will offer to reopen Wisper — accept it and you'll land back here.", state: systemAudioState)
                permissionButton("Open System Settings", state: systemAudioState) {
                    appViewModel.openScreenAudioSettings()
                }
            case .notDetermined, .unsupported:
                stepDetail("Records the other people on a call. Skip it and Wisper records just your microphone.", state: systemAudioState)
                permissionButton("Allow System Audio", state: systemAudioState) {
                    appViewModel.requestScreenAudioPermission()
                }
            }
        }
    }

    // MARK: Step building blocks

    private func stepCard(state: StepState, number: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 13) {
            stepBadge(state: state, number: number)
            VStack(alignment: .leading, spacing: state == .active ? 9 : 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
        .background(state == .upcoming ? Theme.Color.chrome.opacity(0.5) : Theme.Color.card,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(state == .active ? Theme.Color.accent : Theme.Color.border, lineWidth: state == .active ? 1.5 : 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func stepBadge(state: StepState, number: String) -> some View {
        ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(Theme.Color.successSoft)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Color.successText)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .active:
                Circle()
                    .fill(Theme.Color.accent)
                    .overlay {
                        Text(number)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
            case .upcoming:
                Circle()
                    .strokeBorder(Theme.Color.controlBorder, lineWidth: 1.5)
                    .overlay {
                        Text(number)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func stepHeader(title: String, state: StepState, optional: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(state == .upcoming ? Theme.Color.textSecondary : Theme.Color.text)
            if state == .done {
                Text("Done")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Color.successText)
            } else if optional {
                Text("Optional")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }

    private func stepDetail(_ text: String, state: StepState) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(state == .active ? Theme.Color.textSecondary : Theme.Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The highlighted step gets the filled button; later steps keep a quieter
    /// one so they can still be done out of order.
    @ViewBuilder
    private func permissionButton(_ title: String, state: StepState, action: @escaping () -> Void) -> some View {
        if state == .active {
            Button(title, action: action)
                .buttonStyle(.plain)
                .primaryButtonStyle()
        } else {
            Button(title, action: action)
                .buttonStyle(.plain)
                .secondaryButtonStyle()
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
