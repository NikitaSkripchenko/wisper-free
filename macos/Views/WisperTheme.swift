import AppKit
import SwiftUI

/// Design tokens taken from the Wisper product design canvas.
/// Light values drive the main window; `Notch` values drive the dark
/// recording surfaces (notch and fallback pill), which stay dark in both
/// appearances because they sit over the menu bar.
enum Theme {
    /// Light values come straight from the design canvas; dark values are
    /// taken from `Dark.dc.html` where it shows the token, and extrapolated
    /// from that palette's pattern where it doesn't (e.g. the danger tokens,
    /// which the dark artboard never exercises).
    enum Color {
        static let canvas = SwiftUI.Color(light: 0xFFFFFF, dark: 0x1B1A18)
        static let chrome = SwiftUI.Color(light: 0xF4F3F0, dark: 0x232220)
        static let border = SwiftUI.Color(light: 0xE3E0DA, dark: 0x37352F)
        static let controlBorder = SwiftUI.Color(light: 0xD8D4CD, dark: 0x444138)
        /// Elevated surface (note-item cards) — distinct from `canvas` in dark mode.
        static let card = SwiftUI.Color(light: 0xFFFFFF, dark: 0x242320)

        static let text = SwiftUI.Color(light: 0x1C1B19, dark: 0xF1EFEB)
        static let textBody = SwiftUI.Color(light: 0x3A3833, dark: 0xDDD9D2)
        static let textSecondary = SwiftUI.Color(light: 0x55524C, dark: 0xC9C4BC)
        static let textTertiary = SwiftUI.Color(light: 0x6E6A63, dark: 0xA8A39A)

        static let accent = SwiftUI.Color(hex: 0x1160C4)
        static let accentSoft = SwiftUI.Color(light: 0xDDE8F7, dark: 0x2B3A54)
        static let accentSoftText = SwiftUI.Color(light: 0x16294A, dark: 0xEAF1FD)

        static let successSoft = SwiftUI.Color(light: 0xE2F0E8, dark: 0x1E3A2C)
        static let successText = SwiftUI.Color(light: 0x146046, dark: 0x7ED3A6)
        static let dangerSoft = SwiftUI.Color(light: 0xF8E3DF, dark: 0x3A2420)
        static let dangerText = SwiftUI.Color(light: 0x9A2C1E, dark: 0xFF9D8D)

        static let quoteBackground = SwiftUI.Color(light: 0xF6F5F1, dark: 0x242320)
        static let quoteRule = SwiftUI.Color(light: 0xC9C4BA, dark: 0x4A473F)
        static let segmentTrack = SwiftUI.Color(light: 0xECEBE6, dark: 0x2B2926)
        static let segmentBorder = SwiftUI.Color(light: 0xDED9D1, dark: 0x4A473F)
        static let segmentSelected = SwiftUI.Color(light: 0xFFFFFF, dark: 0x3B3934)
        /// The placeholder bars in the welcome pane's sample note.
        static let skeleton = SwiftUI.Color(light: 0xDCD8D0, dark: 0x3B3934)
    }

    /// The dark surfaces that live over the menu bar.
    enum Notch {
        static let background = SwiftUI.Color(hex: 0x08080A)
        static let pillBackground = SwiftUI.Color(hex: 0x24221E)
        static let pillBorder = SwiftUI.Color(hex: 0x403D37)
        static let recordDot = SwiftUI.Color(hex: 0xF0564A)
        static let pausedDot = SwiftUI.Color(hex: 0xE8C86A)
        static let processingDot = SwiftUI.Color(hex: 0x8A8680)
        static let primaryText = SwiftUI.Color.white
        static let secondaryText = SwiftUI.Color(hex: 0xB6B1A9)
        static let tertiaryText = SwiftUI.Color(hex: 0x8A8680)
        static let bodyText = SwiftUI.Color(hex: 0xC9C4BC)
        static let waveform = SwiftUI.Color(hex: 0xCFCAC2)
        static let destructiveBorder = SwiftUI.Color(hex: 0x5D3C36)
        static let destructiveText = SwiftUI.Color(hex: 0xFF9D8D)
        static let destructiveFill = SwiftUI.Color(hex: 0xC2412F)
        static let translucentFill = SwiftUI.Color.white.opacity(0.13)
    }

    /// Four transitions, each tied to one state change. Everything else —
    /// switching tabs, selecting a meeting, opening a menu — changes with
    /// no animation at all, by design.
    enum Motion {
        /// cubic-bezier(0.32, 0.72, 0, 1) — the single easing curve in use.
        static func curve(_ duration: Double) -> Animation {
            .timingCurve(0.32, 0.72, 0, 1, duration: duration)
        }

        static let quoteReveal = curve(0.22)
        static let notchExpand = curve(0.38)
        static let stageComplete = curve(0.26)
        static let press = curve(0.09)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A color that resolves to `light` or `dark` depending on the current appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}
