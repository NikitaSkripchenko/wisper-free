# Wisper

Native macOS transcription app.

Wisper is a native macOS Swift application using SwiftUI, AppKit-era system conventions, Keychain, the native microphone stack, and the OpenAI Swift SDK.

## Native macOS App

Requirements:
- macOS 14+
- Xcode 16+
- OpenAI API key saved inside the app Settings screen

Run from Xcode:

```bash
open Wisper.xcodeproj
```

Then choose the `Wisper` scheme and press Run. The Xcode project builds a native macOS `.app` bundle and includes the microphone privacy usage description required by macOS.

The Swift app currently includes first-run setup plus native Record, History, and Settings surfaces. It records audio to local Application Support storage, saves the OpenAI API key in Keychain, sends recorded audio to `gpt-4o-transcribe` through the Swift SDK, and stores transcript history locally.

Native app features now include:
- Signed over-the-air updates through Sparkle 2.9.3, with automatic daily checks and explicit Install/Later/Skip prompts.
- Configurable system-wide recording shortcut, defaulting to `Command Shift Space`.
- Floating native overlay while recording, with Discard, Start Over, Pause/Resume, and Stop controls.
- Automatic save-and-transcribe when recording stops.
- First-run onboarding for API key, microphone, and screen/system audio permissions.
- Local JSONL diagnostics under Application Support, with a Settings action to reveal the log file.
- Native chunked transcription for longer recordings, enabled by default at 480-second chunks and configurable in Settings.
- History actions for audio playback, reveal in Finder, copy transcript, save transcript, retranscribe, and remove from history.
- Local JSON history and settings under Application Support, with API keys kept in Keychain.

Source layout:
- `macos/TranscriptionService/`: transcription pipeline, chunking, and OpenAI SDK boundary.
- `macos/Models/`: app models and persisted settings types.
- `macos/ViewModels/`: observable view models, including `AppViewModel`.
- `macos/Views/`: SwiftUI views.
- `macos/`: native app services/controllers, assets, Info.plist, and entitlements.
- `WisperTests/`: unit tests for update gating and long-file transcription orchestration.

Native chunking notes:
- The Swift app splits long recordings locally with AVFoundation before sending each chunk to OpenAI.
- Chunked transcripts are stitched in order with chunk labels in the saved transcript text.
- The chunking toggle and chunk length are saved in the native app settings. Chunk length accepts 60 to 3600 seconds.
- The app does not need `ffmpeg` for native chunking.

## Development

Run the Xcode build check:

```bash
xcodebuild -project Wisper.xcodeproj -scheme Wisper -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath build/SourcePackages build
```

Run the unit tests:

```bash
xcodebuild test -project Wisper.xcodeproj -scheme Wisper -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath build/SourcePackages
```

## Releases

Release builds are automated with GitHub Actions on every non-release commit pushed to `main`, including merged PRs. The workflow runs the unit tests, bumps the app patch version by default, builds a Developer ID signed app, packages it into a signed and notarized DMG, staples notarization, generates an EdDSA-signed Sparkle appcast, and commits the version bump back to `main`. It uploads the DMG and appcast to a draft GitHub Release, verifies both assets, then publishes the release atomically.

The workflow also supports manual runs from the GitHub Actions tab. Use `patch`, `minor`, or `major` to choose the bump type, or `none` to rebuild and republish the current checked-in version after a failed release attempt.

For a public repo on a free GitHub account, this uses the standard GitHub-hosted `macos-15` runner and the built-in `GITHUB_TOKEN`; no paid runner or personal access token is required. In repository settings, enable Actions workflow permissions for `Read and write permissions` so the workflow can push the version bump commit, create tags, and create releases. If `main` is branch-protected against direct pushes, the default `GITHUB_TOKEN` may be blocked; use a ruleset/bypass that permits the workflow's release commit or switch to a release-PR flow instead.

Required GitHub repository secrets:
- `APPLE_ID`: Apple Developer account email used for notarization.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for `notarytool`.
- `DEVELOPER_ID_APPLICATION`: Full Developer ID Application identity name, for example `Developer ID Application: Your Name (TEAMID)`.
- `MACOS_CERTIFICATE_BASE64`: Base64-encoded `.p12` Developer ID Application certificate.
- `MACOS_CERTIFICATE_PASSWORD`: Password for the `.p12` certificate.
- `KEYCHAIN_PASSWORD`: Temporary CI keychain password.
- `SPARKLE_ED_PRIVATE_KEY`: Private EdDSA key exported by Sparkle's `generate_keys` tool. Store it only as an encrypted repository secret and in an encrypted offline backup.

### Over-the-air updates

Wisper checks the stable appcast once per day. Checks are always enabled, but automatic downloads and silent installs are disabled. Users choose Install, Later, or Skip in Sparkle's standard update window. “Check for Updates…” is also available from the application menu and menu bar extra.

The stable appcast is published at:

```text
https://github.com/NikitaSkripchenko/wisper-free/releases/latest/download/appcast.xml
```

The first release containing Sparkle must still be installed manually because older versions cannot discover the appcast. Subsequent versions can update in place. If Wisper is recording, importing, stopping, restarting, discarding, or transcribing when installation is requested, relaunch waits until that work reaches a stable idle state.

Published releases are immutable. A failed draft can be rebuilt with the manual `none` option, but a faulty published build must be fixed by shipping a higher `CFBundleVersion`; do not replace a live DMG or appcast under an existing version.

The private update key was generated in the local Keychain under account `com.wisper.mac`. Export an encrypted backup on a trusted Mac with the `generate_keys` binary from the resolved Sparkle package:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.wisper.mac \
  -x /secure/offline/location/wisper-sparkle-private-key
```

Never commit or attach that exported file to a release. If an update key or Developer ID certificate must be rotated, rotate only one of them in a given release.

Local release builds are still available with Fastlane. The release lane builds a Developer ID signed app, packages it into a signed and notarized DMG, staples notarization, creates and pushes the git tag, and uploads the DMG to the matching GitHub Release.

Required local Fastlane credentials:
- `APPLE_ID`: Apple Developer account email used for notarization.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for `notarytool`.
- `DEVELOPER_ID_APPLICATION`: Full Developer ID Application identity name, for example `Developer ID Application: Your Name (TEAMID)`.
- `GITHUB_TOKEN`: GitHub token with Contents read/write access to create tags, create releases, and upload the DMG asset. For a fine-grained token, grant this repo `Contents: Read and write`. For a classic token, use `public_repo` for a public repo or `repo` for a private repo.
- `SPARKLE_ED_PRIVATE_KEY`: Contents of the private key exported from the `com.wisper.mac` Sparkle Keychain account.

Optional local environment variable:
- `GITHUB_REPOSITORY`: GitHub repository in `owner/repo` format. If omitted, Fastlane tries to infer it from `remote.origin.url`.

The Fastlane lane uses your existing macOS login keychain by default, so install your Developer ID Application certificate locally before running it. You only need `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, and `KEYCHAIN_PASSWORD` if you want Fastlane to import a `.p12` into a temporary keychain.

Store credentials in Fastlane's local dotenv file instead of exporting them in your shell:

```bash
cp fastlane/.env.example fastlane/.env
```

Then edit `fastlane/.env` with your real values. `fastlane/.env` is ignored by git.

Use the exact local signing identity shown by this command for `DEVELOPER_ID_APPLICATION`:

```bash
security find-identity -v -p codesigning
```

For public DMG distribution, the identity must start with `Developer ID Application:`. `Apple Development:` identities are only for local development and will not pass notarized distribution signing.

Build and notarize a local DMG without uploading it:

```bash
cd /Users/mykytaskrypchenko/Projects/wisper-public
bundle config set path vendor/bundle
bundle install
bundle exec fastlane mac build_dmg tag:v1.0.0
```

Build, notarize, and upload the DMG to GitHub Releases:

```bash
cd /Users/mykytaskrypchenko/Projects/wisper-public
bundle config set path vendor/bundle
bundle install
bundle exec fastlane mac release tag:v1.0.0
```

The `mac release` lane requires a clean git working tree before it builds. Commit your changes first so the pushed tag points at the exact source used for the DMG.

The commit you are releasing must already exist on GitHub before running `mac release`. Fastlane uses `GITHUB_TOKEN` to publish the tag and release asset, but it does not push branch commits.

Fastlane may resume an existing draft release for the tag. It refuses to modify a published release; publish a higher app version and build number instead.

Fastlane publishes git tags through the GitHub API using `GITHUB_TOKEN`, so local SSH access to `origin` is not required.
