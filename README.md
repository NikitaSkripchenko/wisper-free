# Wisper

Native macOS transcription app.

Wisper is a native macOS Swift application using SwiftUI, AppKit-era system conventions, Keychain, and the native microphone stack.

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

The Swift app currently includes native Record, History, and Settings surfaces. It records microphone audio to local Application Support storage, saves the OpenAI API key in Keychain, sends recorded audio to `gpt-4o-transcribe`, and stores transcript history locally.

Native app features now include:
- Configurable system-wide recording shortcut, defaulting to `Command Shift Space`.
- Floating native overlay while recording, with Discard, Start Over, Pause/Resume, and Stop controls.
- Automatic save-and-transcribe when recording stops.
- Native chunked transcription for longer recordings, enabled by default at 480-second chunks and configurable in Settings.
- History actions for audio playback, reveal in Finder, copy transcript, save transcript, retranscribe, and remove from history.
- Local JSON history and settings under Application Support, with API keys kept in Keychain.

Native chunking notes:
- The Swift app splits long recordings locally with AVFoundation before sending each chunk to OpenAI.
- Chunked transcripts are stitched in order with chunk labels in the saved transcript text.
- The chunking toggle and chunk length are saved in the native app settings. Chunk length accepts 60 to 3600 seconds.
- The app does not need `ffmpeg` for native chunking.

## Development

Run the Xcode build check:

```bash
xcodebuild -project Wisper.xcodeproj -scheme Wisper -configuration Debug -destination 'platform=macOS' build
```

## Releases

Release builds are automated locally with Fastlane. The release lane builds a Developer ID signed app, packages it into a signed and notarized DMG, staples notarization, creates and pushes the git tag, and uploads the DMG to the matching GitHub Release.

Required local Fastlane credentials:
- `APPLE_ID`: Apple Developer account email used for notarization.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for `notarytool`.
- `DEVELOPER_ID_APPLICATION`: Full Developer ID Application identity name, for example `Developer ID Application: Your Name (TEAMID)`.
- `GITHUB_TOKEN`: GitHub token with `contents:write` permission for uploading the release asset.

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

If the GitHub Release already exists for the tag, Fastlane replaces the existing DMG asset with the newly built notarized DMG.
