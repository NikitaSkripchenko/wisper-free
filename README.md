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

Release builds are automated with GitHub Actions on every non-release commit pushed to `main`, including merged PRs. The workflow bumps the app patch version by default, builds a Developer ID signed app, packages it into a signed and notarized DMG, staples notarization, commits the version bump back to `main`, creates and pushes the git tag, and uploads the DMG to the matching GitHub Release.

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

Local release builds are still available with Fastlane. The release lane builds a Developer ID signed app, packages it into a signed and notarized DMG, staples notarization, creates and pushes the git tag, and uploads the DMG to the matching GitHub Release.

Required local Fastlane credentials:
- `APPLE_ID`: Apple Developer account email used for notarization.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for `notarytool`.
- `DEVELOPER_ID_APPLICATION`: Full Developer ID Application identity name, for example `Developer ID Application: Your Name (TEAMID)`.
- `GITHUB_TOKEN`: GitHub token with Contents read/write access to create tags, create releases, and upload the DMG asset. For a fine-grained token, grant this repo `Contents: Read and write`. For a classic token, use `public_repo` for a public repo or `repo` for a private repo.

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

If the GitHub Release already exists for the tag, Fastlane replaces the existing DMG asset with the newly built notarized DMG.

Fastlane publishes git tags through the GitHub API using `GITHUB_TOKEN`, so local SSH access to `origin` is not required.
