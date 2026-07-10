import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayText: String

    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayText: "Command Shift Space"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, displayText: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayText = displayText
    }

    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0, Self.isModifierOnlyKey(event.keyCode) == false else { return nil }

        keyCode = UInt32(event.keyCode)
        carbonModifiers = modifiers
        displayText = Self.displayText(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        [UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_Option), UInt16(kVK_Control), UInt16(kVK_RightCommand), UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl)].contains(keyCode)
    }

    private static func displayText(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Command") }
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Escape: "Escape"
        case kVK_Delete: "Delete"
        case kVK_Tab: "Tab"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        default: "Key \(keyCode)"
        }
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var registeredShortcut: KeyboardShortcut?
    @Published private(set) var statusMessage = "Not registered"

    private static weak var activeManager: ShortcutManager?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func start(shortcut: KeyboardShortcut, action: @escaping () -> Void) {
        self.action = action
        Self.activeManager = self
        installHandlerIfNeeded()
        register(shortcut)
    }

    func register(_ shortcut: KeyboardShortcut) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: 0x53504B4E, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            registeredShortcut = shortcut
            statusMessage = "Registered system-wide: \(shortcut.displayText)"
        } else {
            registeredShortcut = nil
            statusMessage = "Shortcut is unavailable. Another app may already be using it."
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func fire() {
        action?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if hotKeyID.signature == 0x53504B4E, hotKeyID.id == 1 {
                Task { @MainActor in
                    ShortcutManager.activeManager?.fire()
                }
            }
            return noErr
        }, 1, &eventSpec, nil, &handlerRef)
    }
}

struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut
    var onCapture: (KeyboardShortcut) -> Void
    var onInvalid: () -> Void

    func makeNSView(context: Context) -> CaptureTextField {
        let view = CaptureTextField()
        view.onCapture = onCapture
        view.onInvalid = onInvalid
        return view
    }

    func updateNSView(_ nsView: CaptureTextField, context: Context) {
        nsView.stringValue = shortcut.displayText
        nsView.onCapture = onCapture
        nsView.onInvalid = onInvalid
    }

    final class CaptureTextField: NSTextField {
        var onCapture: ((KeyboardShortcut) -> Void)?
        var onInvalid: (() -> Void)?

        init() {
            super.init(frame: .zero)
            isEditable = false
            isSelectable = false
            drawsBackground = true
            bezelStyle = .roundedBezel
            focusRingType = .default
            placeholderString = "Press shortcut"
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                window?.makeFirstResponder(nil)
                return
            }

            guard let shortcut = KeyboardShortcut(event: event) else {
                onInvalid?()
                return
            }

            onCapture?(shortcut)
        }
    }
}
