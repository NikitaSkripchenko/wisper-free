import AppKit
import SwiftUI

struct RecordingOverlayState: Equatable {
    var state: String
    var detail: String
    var elapsedText: String
    var canPause: Bool
    var canResume: Bool
    var canStop: Bool
    var canDiscard: Bool
    var canRestart: Bool
}

@MainActor
final class OverlayWindowController {
    fileprivate enum Layout {
        static let size = NSSize(width: 380, height: 96)
        static let cornerRadius: CGFloat = 24
    }

    var onDiscard: (() -> Void)?
    var onRestart: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?

    private var panel: NSPanel?
    private var didPlacePanel = false

    func show(state: RecordingOverlayState) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(state: state, controller: self))
        if didPlacePanel == false {
            position(panel)
            didPlacePanel = true
        }
        panel.orderFrontRegardless()
    }

    func update(state: RecordingOverlayState) {
        guard panel?.isVisible == true else { return }
        show(state: state)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func dragPanel(with event: NSEvent) {
        panel?.performDrag(with: event)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.size),
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

    private func position(_ panel: NSPanel) {
        let frame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 64
        ))
    }
}

private struct RecordingOverlayView: View {
    let state: RecordingOverlayState
    let controller: OverlayWindowController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.detail.isEmpty ? state.state : state.detail)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(state.elapsedText)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button {
                    controller.onDiscard?()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Discard")
                .buttonStyle(.borderless)
                    .disabled(state.canDiscard == false)

                Button {
                    controller.onRestart?()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Start Over")
                .buttonStyle(.borderless)
                    .disabled(state.canRestart == false)

                Button {
                    state.canResume ? controller.onResume?() : controller.onPause?()
                } label: {
                    Image(systemName: state.canResume ? "play.fill" : "pause.fill")
                }
                .help(state.canResume ? "Resume" : "Pause")
                .buttonStyle(.borderless)
                .disabled((state.canPause || state.canResume) == false)

                Button {
                    controller.onStop?()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop")
                    .buttonStyle(.borderedProminent)
                    .disabled(state.canStop == false)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: OverlayWindowController.Layout.size.width, height: OverlayWindowController.Layout.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OverlayWindowController.Layout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OverlayWindowController.Layout.cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 34, height: 4)
                .padding(.top, 6)
        }
        .onMouseDown { event in
            controller.dragPanel(with: event)
        }
    }

    private var iconName: String {
        if state.canResume { return "pause.circle.fill" }
        if state.state.lowercased().contains("processing") { return "waveform.badge.magnifyingglass" }
        return "waveform.circle.fill"
    }

    private var iconColor: Color {
        if state.canResume { return .orange }
        if state.state.lowercased().contains("processing") { return .blue }
        return .red
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
