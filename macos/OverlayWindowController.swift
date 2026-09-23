import AppKit
import SwiftUI

/// What the recording surface is showing. Derived once by `AppViewModel`
/// rather than inferred from the capability flags below, which cannot tell
/// "paused" from "no longer recording at all".
enum RecordingSurfacePhase: Equatable {
    case recording
    case paused
    case processing

    var title: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Transcribing"
        }
    }

    /// Only a live capture has a meaningful microphone waveform; a paused or
    /// finished one would otherwise flatten into a row of dots.
    var showsWaveform: Bool { self == .recording }
}

struct RecordingOverlayState: Equatable {
    var phase: RecordingSurfacePhase
    var elapsedText: String
    var canPause: Bool
    var canResume: Bool
    var canStop: Bool
    var canDiscard: Bool
    var canRestart: Bool
    var microphoneLevels: [CGFloat]
    var showsMicrophoneWaveform: Bool
}

/// Facade over the recording surface: picks the notch presentation on a
/// screen that has one, and falls back to the pill otherwise. The choice is
/// re-resolved on every `show(state:)` rather than cached, since an external
/// display can appear or disappear mid-recording.
@MainActor
final class OverlayWindowController {
    enum Layout {
        static let pillSize = NSSize(width: 720, height: 96)
        static let pillDiscardSize = NSSize(width: 720, height: 140)
        static let pillCornerRadius: CGFloat = 16
    }

    var onDiscard: (() -> Void)?
    var onRestart: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?

    private let notchController = NotchWindowController()
    private var pillPanel: NSPanel?
    private var pillHostingView: NSHostingView<PillSurfaceView>?
    private var didPlacePillPanel = false
    private var pillIsConfirmingDiscard = false
    private var isShown = false

    init() {
        notchController.onDiscard = { [weak self] in self?.onDiscard?() }
        notchController.onPause = { [weak self] in self?.onPause?() }
        notchController.onResume = { [weak self] in self?.onResume?() }
        notchController.onStop = { [weak self] in self?.onStop?() }
    }

    /// The notch/pill decision, factored out as a pure function of the
    /// screen's top safe-area inset so it can be unit tested without a real
    /// `NSScreen`.
    nonisolated static func prefersNotch(topSafeAreaInset: CGFloat) -> Bool {
        topSafeAreaInset > 0
    }

    func show(state: RecordingOverlayState) {
        isShown = true
        guard let screen = Self.targetScreen() else { return }

        if Self.prefersNotch(topSafeAreaInset: screen.safeAreaInsets.top) {
            pillPanel?.orderOut(nil)
            notchController.show(state: state, on: screen)
        } else {
            notchController.hide()
            showPill(state: state, on: screen)
        }
    }

    func update(state: RecordingOverlayState) {
        guard isShown else { return }
        show(state: state)
    }

    func hide() {
        isShown = false
        notchController.hide()
        pillPanel?.orderOut(nil)
        // Fresh view state for the next recording (see NotchWindowController.hide).
        pillPanel?.contentView = nil
        pillHostingView = nil
        pillDiscardConfirmingChanged(false)
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    // MARK: - Pill fallback

    private func showPill(state: RecordingOverlayState, on screen: NSScreen) {
        let panel = pillPanel ?? makePillPanel()
        pillPanel = panel
        if let pillHostingView {
            pillHostingView.rootView = PillSurfaceView(state: state, controller: self)
        } else {
            let view = NSHostingView(rootView: PillSurfaceView(state: state, controller: self))
            panel.contentView = view
            pillHostingView = view
        }
        if didPlacePillPanel == false {
            positionPill(panel, size: Layout.pillSize, on: screen)
            didPlacePillPanel = true
        }
        panel.orderFrontRegardless()
    }

    private func makePillPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        return panel
    }

    private func positionPill(_ panel: NSPanel, size: NSSize, on screen: NSScreen) {
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 64, width: size.width, height: size.height),
            display: false
        )
    }

    func dragPillPanel(with event: NSEvent) {
        pillPanel?.performDrag(with: event)
    }

    /// Called by `PillSurfaceView` when the local discard-confirmation state
    /// toggles, so the panel can grow/shrink (96pt <-> 140pt) while keeping
    /// its top edge and horizontal position — wherever the user dragged it —
    /// fixed.
    func pillDiscardConfirmingChanged(_ confirming: Bool) {
        pillIsConfirmingDiscard = confirming
        guard let panel = pillPanel else { return }
        let size = confirming ? Layout.pillDiscardSize : Layout.pillSize
        var frame = panel.frame
        let topY = frame.maxY
        frame.size = size
        frame.origin.y = topY - size.height
        panel.setFrame(frame, display: true)
    }
}

private struct PillSurfaceView: View {
    let state: RecordingOverlayState
    let controller: OverlayWindowController
    @State private var isConfirmingDiscard = false

    var body: some View {
        Group {
            if isConfirmingDiscard {
                PillDiscardConfirmContent(
                    onKeep: { setConfirming(false) },
                    onDelete: { controller.onDiscard?() }
                )
            } else if state.phase == .processing {
                PillProcessingContent(state: state)
            } else if state.phase == .paused {
                PillPausedContent(
                    state: state,
                    onResume: { controller.onResume?() },
                    onStop: { controller.onStop?() },
                    onDiscard: { setConfirming(true) }
                )
            } else {
                PillRecordingContent(
                    state: state,
                    onPause: { controller.onPause?() },
                    onStop: { controller.onStop?() },
                    onDiscard: { setConfirming(true) }
                )
            }
        }
        .frame(
            width: OverlayWindowController.Layout.pillSize.width,
            height: isConfirmingDiscard ? OverlayWindowController.Layout.pillDiscardSize.height : OverlayWindowController.Layout.pillSize.height
        )
        .background(Theme.Notch.pillBackground, in: RoundedRectangle(cornerRadius: OverlayWindowController.Layout.pillCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OverlayWindowController.Layout.pillCornerRadius, style: .continuous)
                .strokeBorder(Theme.Notch.pillBorder)
        )
        .onMouseDown { event in controller.dragPillPanel(with: event) }
        .onChange(of: state.canDiscard) { _, canDiscard in
            if canDiscard == false { setConfirming(false) }
        }
    }

    private func setConfirming(_ value: Bool) {
        isConfirmingDiscard = value
        controller.pillDiscardConfirmingChanged(value)
    }
}

private struct PillRecordingContent: View {
    let state: RecordingOverlayState
    let onPause: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                NotchStatusDot(phase: state.phase)
                Text(state.phase.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Notch.primaryText)
            }

            Text(state.elapsedText)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Notch.primaryText)

            NotchWaveformView(levels: state.microphoneLevels, barCount: 5, barWidth: 3, maxHeight: 16, animated: state.phase.showsWaveform && state.showsMicrophoneWaveform)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                Button {
                    onPause()
                } label: {
                    Text("Pause").padding(.horizontal, 16)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.translucentFill, foreground: Theme.Notch.primaryText, cornerRadius: 9))
                .disabled(state.canPause == false)

                Button {
                    onStop()
                } label: {
                    Text("Stop & save").padding(.horizontal, 18)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.primaryText, foreground: Color(hex: 0x1C1B19), cornerRadius: 9))
                .disabled(state.canStop == false)

                Button(action: onDiscard) {
                    Text("Discard…").padding(.horizontal, 15)
                }
                .buttonStyle(SurfaceOutlineButtonStyle(cornerRadius: 9))
                .disabled(state.canDiscard == false)
                .accessibilityLabel("Discard recording")
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PillPausedContent: View {
    let state: RecordingOverlayState
    let onResume: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                HStack(spacing: 3) {
                    Capsule().fill(Theme.Notch.pausedDot).frame(width: 3.5, height: 12)
                    Capsule().fill(Theme.Notch.pausedDot).frame(width: 3.5, height: 12)
                }
                .accessibilityHidden(true)
                Text(state.phase.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Notch.primaryText)
            }

            Text(state.elapsedText)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Notch.secondaryText)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                Button {
                    onResume()
                } label: {
                    Text("Resume").padding(.horizontal, 17)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.primaryText, foreground: Color(hex: 0x1C1B19), cornerRadius: 9))
                .disabled(state.canResume == false)

                Button {
                    onStop()
                } label: {
                    Text("Stop & save").padding(.horizontal, 16)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.translucentFill, foreground: Theme.Notch.primaryText, cornerRadius: 9))
                .disabled(state.canStop == false)

                Button(action: onDiscard) {
                    Text("Discard…").padding(.horizontal, 15)
                }
                .buttonStyle(SurfaceOutlineButtonStyle(cornerRadius: 9))
                .disabled(state.canDiscard == false)
                .accessibilityLabel("Discard recording")
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// After the recording stops the capture controls are all inert, so the pill
/// shows the processing state instead of three dead buttons.
private struct PillProcessingContent: View {
    let state: RecordingOverlayState

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                NotchStatusDot(phase: state.phase)
                Text(state.phase.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Notch.primaryText)
            }

            Text(state.elapsedText)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Notch.secondaryText)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PillDiscardConfirmContent: View {
    let onKeep: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(hex: 0x4A2C26))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Notch.destructiveText)
                    )
                    .accessibilityHidden(true)

                Text("Discard this recording?")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.Notch.primaryText)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button("Keep recording", action: onKeep)
                    .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.translucentFill, foreground: Theme.Notch.primaryText, cornerRadius: 9))
                    .padding(.horizontal, 8)
                Button("Delete the audio", action: onDelete)
                    .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.destructiveFill, foreground: Theme.Notch.primaryText, cornerRadius: 9))
                    .padding(.horizontal, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MouseDownModifier: ViewModifier {
    let action: (NSEvent) -> Void

    func body(content: Content) -> some View {
        content.background(MouseDownRepresentable(action: action))
    }
}

private struct MouseDownRepresentable: NSViewRepresentable {
    let action: (NSEvent) -> Void

    func makeNSView(context: Context) -> MouseDownView {
        let view = MouseDownView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MouseDownView, context: Context) {
        nsView.action = action
    }
}

private final class MouseDownView: NSView {
    var action: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        action?(event)
    }
}

private extension View {
    func onMouseDown(_ action: @escaping (NSEvent) -> Void) -> some View {
        modifier(MouseDownModifier(action: action))
    }
}
