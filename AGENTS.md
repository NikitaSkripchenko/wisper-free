# Wisper project guidance

## Project context

- Wisper is a native macOS transcription and meeting-notes app for macOS 14+.
- The app is written in Swift and SwiftUI and is built with `Wisper.xcodeproj` using Xcode 16+.
- Audio capture uses AVFoundation and ScreenCaptureKit. API credentials are stored in Keychain. Audio, transcripts, notes, diagnostics, and meeting history are stored locally in Application Support.
- OpenAI integration boundaries live in `macos/TranscriptionService/`. Do not log, commit, or expose API keys, private signing keys, certificates, or raw user recordings/transcripts.

## Codebase map

- `macos/TranscriptionService/`: audio chunking, transcription, grounded note generation, and OpenAI SDK calls.
- `macos/Persistence/`: atomic meeting-history storage, recovery, and migrations.
- `macos/Models/`: app, meeting, artifact, and persisted-settings types.
- `macos/ViewModels/`: observable state and app coordination.
- `macos/Views/`: SwiftUI screens and components.
- `macos/`: capture, playback, permissions, shortcuts, updates, logging, app lifecycle, and project resources.
- `WisperTests/`: unit and integration tests. `WisperUITests` contains isolated meeting-history UI scenarios.
- `.github/workflows/`: CI and release automation. Treat signing, notarization, and Sparkle-release behavior as security-sensitive.

## Working conventions

- Inspect the affected execution path before changing it. Keep diffs focused and preserve unrelated work in a dirty worktree.
- Favor small, typed Swift changes that make cancellation, errors, persistence, and main-thread UI updates explicit.
- Preserve the existing separation between capture, processing, persistence, view models, and SwiftUI views.
- Add or update focused tests when behavior changes. Do not rely on live microphone or ScreenCaptureKit permission prompts in automated tests.
- Do not alter release tags, published releases, signing configuration, or secrets unless the user explicitly requests it.

## Verification

Run the smallest relevant check first. For broad native-app changes, use:

```sh
xcodebuild test -project Wisper.xcodeproj -scheme Wisper -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath build/SourcePackages
xcodebuild -project Wisper.xcodeproj -scheme Wisper -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath build/SourcePackages build
```

The opt-in `MeetingNotesLiveEvalTests` require `WISPER_LIVE_EVAL_OPENAI_API_KEY`; never run them or print their environment without explicit user authorization.

## Subagents

Project-local read-only agents are defined in `.codex/agents/`:

- `pr_explorer`: maps affected code paths and returns evidence with files and symbols.
- `reviewer`: identifies correctness, security, regression, and test-coverage risks.

For an explicit PR or branch review, spawn both agents in parallel, give them the base branch and review scope, wait for both results, then consolidate only actionable findings. Report each finding with severity, file/symbol, impact, and reproduction or evidence. Do not report style-only observations as defects.

Suggested request:

```text
Review this branch against main. Have pr_explorer map the affected execution paths and reviewer identify correctness, security, regression, and test risks. Wait for both agents, then summarize actionable findings with file references.
```

For implementation work with unclear impact, use `pr_explorer` before editing when a focused read-only map would reduce risk. Skip subagents for trivial, single-file changes where delegation would not add useful independent evidence.
