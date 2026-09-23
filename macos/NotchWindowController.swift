import AppKit
import SwiftUI

/// The notch-anchored recording surface. The panel is always sized to the
/// expanded footprint (580x220) so the hover target never moves and the
/// pointer can't fall out of the window mid-transition; the dark surface
/// drawn inside it animates between the collapsed peek and the full controls.
@MainActor
final class NotchWindowController {
    enum Layout {
        static let collapsedSize = CGSize(width: 430, height: 40)
        static let expandedSize = CGSize(width: 580, height: 220)
    }

    var onDiscard: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchSurfaceView>?

    func show(state: RecordingOverlayState, on screen: NSScreen) {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: screen)
        if let hostingView {
            hostingView.rootView = NotchSurfaceView(state: state, controller: self)
        } else {
            let view = NSHostingView(rootView: NotchSurfaceView(state: state, controller: self))
            panel.contentView = view
            hostingView = view
        }
        panel.orderFrontRegardless()
    }

    /// Drops the hosting view so the next `show` starts from fresh view state;
    /// a discard hides the surface without a final update, which would
    /// otherwise leave the next recording opening on the discard prompt.
    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        hostingView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        return panel
    }

    // Anchored to screen.frame (not visibleFrame) since the notch lives in
    // the menu bar area.
    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let frame = screen.frame
        let size = Layout.expandedSize
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: false
        )
    }
}

/// Maps however many microphone-level samples the meter produced onto a
/// fixed bar count, so the same data feeds both the 5-bar collapsed peek and
/// the full-width expanded waveform. Interpolates between samples so a wide
/// waveform reads as a curve rather than flat steps.
enum NotchWaveform {
    static func barHeights(from levels: [CGFloat], barCount: Int, maxHeight: CGFloat) -> [CGFloat] {
        guard barCount > 0 else { return [] }
        guard levels.isEmpty == false else {
            return Array(repeating: maxHeight * 0.12, count: barCount)
        }
        return (0..<barCount).map { index in
            let position = barCount == 1 ? 0 : CGFloat(index) * CGFloat(levels.count - 1) / CGFloat(barCount - 1)
            let lower = Int(position)
            let upper = min(lower + 1, levels.count - 1)
            let level = levels[lower] + (levels[upper] - levels[lower]) * (position - CGFloat(lower))
            return max(maxHeight * min(max(level, 0), 1), 2)
        }
    }
}

/// Shared button chrome for both the notch and the fallback pill.
struct SurfaceButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(height: 36)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

struct SurfaceOutlineButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Notch.destructiveText)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Notch.destructiveBorder)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

/// The decorative physical-camera dot in the center of the notch. Purely
/// cosmetic, hidden from accessibility.
struct CameraDot: View {
    var body: some View {
        Circle()
            .fill(Color(hex: 0x0C0C0F))
            .overlay(Circle().strokeBorder(Color(hex: 0x1C1C21), lineWidth: 1))
            .overlay(Circle().fill(Color(hex: 0x23232A)).frame(width: 3, height: 3))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// The status dot: pulsing red while capturing, static amber while paused,
/// static and muted once capture has stopped. It pulses only while something
/// is actually being recorded — a dot that keeps beating after you hit stop
/// reads as "still listening".
struct NotchStatusDot: View {
    let phase: RecordingSurfacePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 9, height: 9)
            .scaleEffect(pulse ? 0.8 : 1)
            .opacity(pulse ? 0.45 : 1)
            .onAppear { syncPulse() }
            .onChange(of: phase) { _, _ in syncPulse() }
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch phase {
        case .recording: Theme.Notch.recordDot
        case .paused: Theme.Notch.pausedDot
        case .processing: Theme.Notch.processingDot
        }
    }

    private func syncPulse() {
        guard reduceMotion == false, phase == .recording else {
            withAnimation(.easeOut(duration: 0.12)) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// A bar-count-agnostic waveform driven by real microphone levels rather
/// than a decorative looping animation. `fillsWidth` spreads the bars
/// evenly across the available width instead of packing them together.
struct NotchWaveformView: View {
    let levels: [CGFloat]
    let barCount: Int
    let barWidth: CGFloat
    let maxHeight: CGFloat
    let animated: Bool
    var fillsWidth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let heights = NotchWaveform.barHeights(from: animated ? levels : [], barCount: barCount, maxHeight: maxHeight)
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Theme.Notch.waveform)
                    .frame(width: barWidth, height: height)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
        }
        .frame(height: maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: heights)
        .accessibilityHidden(true)
    }
}

private struct NotchSurfaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isConfirmingDiscard = false

    let state: RecordingOverlayState
    let controller: NotchWindowController

    private var isExpanded: Bool { isHovering || isConfirmingDiscard }

    var body: some View {
        VStack(spacing: 0) {
            surface
            Spacer(minLength: 0)
        }
        .frame(width: NotchWindowController.Layout.expandedSize.width, height: NotchWindowController.Layout.expandedSize.height, alignment: .top)
        .onChange(of: state.canDiscard) { _, canDiscard in
            if canDiscard == false { isConfirmingDiscard = false }
        }
    }

    private var surface: some View {
        let size = isExpanded ? NotchWindowController.Layout.expandedSize : NotchWindowController.Layout.collapsedSize
        let radius: CGFloat = isExpanded ? 30 : 21

        return ZStack(alignment: .topLeading) {
            if isExpanded {
                Group {
                    if isConfirmingDiscard {
                        NotchDiscardConfirmContent(
                            onKeep: { isConfirmingDiscard = false },
                            onDelete: { controller.onDiscard?() }
                        )
                    } else {
                        NotchExpandedContent(
                            state: state,
                            controller: controller,
                            onDiscardRequested: { isConfirmingDiscard = true }
                        )
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -10)), removal: .opacity))
            } else {
                NotchCollapsedContent(state: state)
                    .transition(.opacity)
            }
        }
        // Expanded height follows the content, so stopped states without
        // controls don't leave an empty dark slab under the notch.
        .frame(width: size.width, height: isExpanded ? nil : size.height, alignment: .topLeading)
        .background(Theme.Notch.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous))
        .animation(reduceMotion ? nil : Theme.Motion.notchExpand, value: isExpanded)
        .onHover { hovering in
            guard isConfirmingDiscard == false else { return }
            isHovering = hovering
        }
    }
}

private struct NotchCollapsedContent: View {
    let state: RecordingOverlayState

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                NotchStatusDot(phase: state.phase)
                Text(state.elapsedText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Notch.primaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CameraDot()
                .frame(width: 40)

            Group {
                if state.phase == .recording {
                    NotchWaveformView(levels: state.microphoneLevels, barCount: 5, barWidth: 2.5, maxHeight: 14, animated: state.showsMicrophoneWaveform)
                } else {
                    Text(state.phase.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Notch.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
}

private struct NotchExpandedContent: View {
    let state: RecordingOverlayState
    let controller: NotchWindowController
    let onDiscardRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    NotchStatusDot(phase: state.phase)
                    Text(state.phase.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Notch.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CameraDot()
                    .frame(width: 40)

                Text(state.elapsedText)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Notch.primaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 34)

            // The waveform is the live microphone; with nothing being
            // captured it would sit at its floor and read as a broken row of
            // dots, so stopped states drop it.
            if state.phase == .recording {
                NotchWaveformView(levels: state.microphoneLevels, barCount: 48, barWidth: 3, maxHeight: 30, animated: state.showsMicrophoneWaveform, fillsWidth: true)
            }

            if state.phase != .processing {
                controls
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 8) {
                Button {
                    state.canResume ? controller.onResume?() : controller.onPause?()
                } label: {
                    Text(state.canResume ? "Resume" : "Pause")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.translucentFill, foreground: Theme.Notch.primaryText))
                .disabled((state.canPause || state.canResume) == false)

                Button {
                    controller.onStop?()
                } label: {
                    Text("Stop & save")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.primaryText, foreground: Color(hex: 0x131316)))
                .disabled(state.canStop == false)

                Button(action: onDiscardRequested) {
                    Text("Discard…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SurfaceOutlineButtonStyle())
                .disabled(state.canDiscard == false)
                .accessibilityLabel("Discard recording")
        }
    }
}

private struct NotchDiscardConfirmContent: View {
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

            HStack(spacing: 8) {
                Spacer()
                Button("Keep recording", action: onKeep)
                    .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.translucentFill, foreground: Theme.Notch.primaryText))
                    .padding(.horizontal, 8)
                Button("Delete the audio", action: onDelete)
                    .buttonStyle(SurfaceButtonStyle(background: Theme.Notch.destructiveFill, foreground: Theme.Notch.primaryText))
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }
}
