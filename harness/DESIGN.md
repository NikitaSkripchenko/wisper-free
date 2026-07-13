# Wisper Design Language

## Direction

Wisper is a native macOS Swift application. The design language should come from the platform first: SwiftUI layouts, system controls, system materials, SF Symbols, Keychain-backed settings, and the interaction rhythm of focused Apple utilities. It should feel closer to Voice Memos, System Settings, or a focused audio utility than a SaaS dashboard.

## Visual Rules

- Use `NavigationSplitView`, `List`, `Form`, `ContentUnavailableView`, native buttons, local feedback, native focus, and system toolbar behavior before custom views. Reserve modal alerts for destructive confirmation and app-blocking failures.
- Use system semantic colors and materials instead of hard-coded decorative palettes. Prefer `.regularMaterial`, `.secondary`, `.quaternary`, `.blue`, and platform text styles.
- Use SF Pro through SwiftUI text styles. Prefer `.largeTitle`, `.headline`, `.body`, `.caption`, and rounded/monospaced variants only when they serve the recording timer.
- Use SF Symbols for navigation and state. Avoid custom icon sets unless the app mark needs one.
- Use native corner radii and grouped form/list styling. Avoid web-card grids, shadows, gradients, and dashboard decoration.

## Layout Rules

- Sidebar: native `NavigationSplitView` with Record, History, and Settings.
- Record screen: a capture-only panel with native controls, timer, active sources, consent reminder, and automatic processing after Stop. Completed content does not appear here.
- History screen: a searchable native archive list. Each row contains editable title, displayed date, and authoritative stage status; selected detail keeps persistent status above segmented Notes, Raw Transcript, and Audio surfaces.
- Settings screen: grouped native form focused on OpenAI key management, capture preferences, and the same inspectable local/OpenAI privacy boundary shown during onboarding.
- Future overlay: use a small AppKit/SwiftUI floating panel with native material, not a web overlay.

## Interaction Rules

- Let SwiftUI/AppKit provide standard hover, active, disabled, focus, keyboard, VoiceOver, and menu behaviors unless there is a product reason to customize.
- Dropdown and context menus are used for secondary meeting actions; retry, cancel, rename, and the selected artifact remain visible in the main detail context.
- Global shortcut capture must feel like a native preference: click the field, press the shortcut, save, then show whether it registered system-wide.
- Errors are specific and local to the place where recovery happens. Keep valid meeting content visible while recoverable actions fail.
- History’s new-user empty state exposes both supported creation paths: Record a meeting and Import audio. Search zero-results is a separate state with Clear Search.
- Menu-bar status consumes the same coordinator state as the main window and deep-links to the owning meeting; consequential recovery remains in the main window.
- Core workflows must work with keyboard and VoiceOver from 920×620 upward, with no horizontal scrolling and no reliance on color alone.

## Do Not Add

- Model marketplace, upgrade prompts, contact links, external tool promotions, iOS promotion, or screenshot-only features.
- Purple/blue marketing gradients, decorative blobs, heavy glass, custom web sidebars, or generic dashboard cards.
