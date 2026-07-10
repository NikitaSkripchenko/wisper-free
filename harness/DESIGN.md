# Wisper Design Language

## Direction

Wisper is a native macOS Swift application. The design language should come from the platform first: SwiftUI layouts, system controls, system materials, SF Symbols, Keychain-backed settings, and the interaction rhythm of focused Apple utilities. It should feel closer to Voice Memos, System Settings, or a focused audio utility than a SaaS dashboard.

## Visual Rules

- Use `NavigationSplitView`, `List`, `Form`, `ContentUnavailableView`, native buttons, native alerts, native focus, and system toolbar behavior before custom views.
- Use system semantic colors and materials instead of hard-coded decorative palettes. Prefer `.regularMaterial`, `.secondary`, `.quaternary`, `.blue`, and platform text styles.
- Use SF Pro through SwiftUI text styles. Prefer `.largeTitle`, `.headline`, `.body`, `.caption`, and rounded/monospaced variants only when they serve the recording timer.
- Use SF Symbols for navigation and state. Avoid custom icon sets unless the app mark needs one.
- Use native corner radii and grouped form/list styling. Avoid web-card grids, shadows, gradients, and dashboard decoration.

## Layout Rules

- Sidebar: native `NavigationSplitView` with Record, History, and Settings.
- Record screen: one primary recording panel with native buttons, timer, local status text, and a clear Transcribe action.
- History screen: a single native archive list. Each row contains title, date, and a transcript preview.
- Settings screen: grouped native form focused on OpenAI key management and local privacy copy.
- Future overlay: use a small AppKit/SwiftUI floating panel with native material, not a web overlay.

## Interaction Rules

- Let SwiftUI/AppKit provide standard hover, active, disabled, focus, keyboard, VoiceOver, and menu behaviors unless there is a product reason to customize.
- Dropdown menus are used for per-row history actions only when actions outgrow one primary click.
- Global shortcut capture must feel like a native preference: click the field, press the shortcut, save, then show whether it registered system-wide.
- Errors are specific and local to the place where recovery happens.
- Empty states provide one next action.

## Do Not Add

- Model marketplace, upgrade prompts, contact links, external tool promotions, iOS promotion, or screenshot-only features.
- Purple/blue marketing gradients, decorative blobs, heavy glass, custom web sidebars, or generic dashboard cards.
