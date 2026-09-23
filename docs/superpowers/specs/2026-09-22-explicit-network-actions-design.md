# Explicit network actions for Wisper

## Intent

Wisper must not initiate a network request without a specific user action that makes the destination and purpose clear. Recording, importing, transcribing, reading history, and opening existing notes must work without sending meeting content from the Mac. The user may explicitly request an AI summary; that request sends the saved transcript to OpenAI. The app must not infer permission to send content from a recording stop, an import, a saved API key, or a previous summary request.

This rule covers all Wisper-initiated requests, including update checks and speech-model downloads. It does not claim to control operating-system network activity outside Wisper.

## User flow

1. On first use, Wisper explains that speech recognition runs locally. If the required speech model is absent, it offers a **Download speech model** action showing the download source and approximate size. The app makes no model-download request before that action. A model can also be installed from an offline package if the chosen runtime supports one.
2. **Stop recording** and **Import audio** save the audio locally and run local transcription and speaker diarization. Neither action sends content to a server. If a required model is unavailable, the saved audio remains in history with a clear local-processing error and a retry action. There is no automatic cloud fallback. If diarization fails after transcription succeeds, retain the unlabeled transcript and offer a separate local diarization retry.
3. After transcription, the meeting shows the transcript and a separate **Create summary with OpenAI** action. Before the first request for that meeting, the UI states that the transcript text, but not the audio file, will be sent to OpenAI using the user's API key. Pressing this action is the authorization for that one request. Canceling or dismissing it sends nothing.
4. The OpenAI summary response is saved locally. Opening, copying, searching, or exporting that saved result sends nothing. **Regenerate summary** makes a new request only when pressed, with the same destination and content disclosure available at the point of action.
5. **Check for Updates** is manual. Wisper performs no scheduled Sparkle checks, downloads, or installs. A check is authorized by pressing that menu item; a download or install still follows Sparkle's explicit user interface.

## Architecture

- Preserve the capture, processing, persistence, and UI boundaries. Replace the OpenAI-only transcription dependency with a local `MeetingTranscribing` implementation. Keep its cancellation, progress, and persisted failure behavior. The processing pipeline ends after local transcription; note generation becomes a separate coordinator command that accepts the meeting ID and the API key only after the user presses the summary action.
- Keep `OpenAIMeetingNotesService` behind the existing `MeetingNotesGenerating` protocol and the current grounded-note validation. There is no automatic note generation after capture/import, after transcription retry, or after app relaunch.
- Remove the API-key prerequisite from recording, import, local transcription, and local retry. Require it only for explicit summary generation. A missing or invalid key must not damage the local transcript or audio.
- English is the first transcription priority; Ukrainian is the second and is required. Other languages are desirable. Compare FluidAudio with Parakeet TDT v3 and WhisperKit with a multilingual Whisper model on the same fixed corpus of real Wisper recordings. Include English, Ukrainian, language switching, long meetings, names and technical terms, speed, memory, model size, cancellation, macOS 14+, and supported Mac architectures. Start with Parakeet v3 as the candidate for the required languages; use WhisperKit as the broad-language candidate. Select the runtime from measured results rather than comparing unrelated published benchmarks. If none meets the release bar, do not silently restore cloud transcription.
- Diarization is required. Compare FluidAudio's offline diarization pipeline and the open-source SpeakerKit/Pyannote implementation on the same English, Ukrainian, and mixed-language meeting recordings. Test two, four, and more than four speakers, short turns, overlap, and long calls; measure diarization error rate and wrong speaker attribution in the final transcript. Do not make a streaming-only, four-speaker model the default for recorded meetings. Check macOS 14 behavior on real supported hardware before selecting a Core ML pipeline.
- On macOS 15+, first evaluate source-aware transcription: transcribe the microphone and system-audio tracks separately, diarize the system-audio track for multiple remote speakers, and merge timed segments. Compare this against diarizing the existing mixed transcription input; detect echo and duplicate speech before assigning **You** from the microphone track. If source attribution is uncertain, keep a neutral speaker ID. Imported audio and microphone-only capture require regular diarization. Never infer participant names from a voice alone; allow the user to rename speaker IDs locally.
- Extend the transcription artifact with timed text segments and speaker IDs, preserving a readable plain-text transcript for existing history and summary generation. Align timed ASR output with diarization segments, preserve overlapping speech when supported, and keep uncertain attribution visible instead of assigning an unsupported owner. Version the persisted format and migrate older plain-text transcripts without inventing speaker labels.
- Model installation is a separate, user-triggered operation with local cache, integrity verification, progress, retry, and a clear disk-space error. Startup and recording must not implicitly fetch a model.
- Set Sparkle's automatic checks off and retain the explicit menu action. Audit third-party runtime behavior so initialization cannot download models or call home.

## Existing records and failures

Existing audio, transcripts, and summaries remain readable. A completed transcript with no summary displays a ready state and summary action. Interrupted local transcription remains retryable from its saved audio. A failed summary retains the transcript and any last valid summary. Retrying transcription never implicitly regenerates a summary; the UI should make stale summary provenance visible when the transcript changes.

## Verification and release bar

- Coordinator tests prove that stop/import/retry perform local transcription without calling the note generator; only the explicit summary command calls it. They also prove cancellation, persistence, and existing-record behavior.
- Diarization tests cover source-track attribution, timestamp alignment, overlapping speech, unknown speakers, speaker renaming, older transcripts, and a diarization failure that leaves the transcript usable.
- Tests with a network-client spy prove no app-owned network invocation on launch, recording, import, local transcription, history reads, or opening saved notes. They prove exactly one user-triggered summary request and one user-triggered update check.
- On a clean Mac test installation, inspect Wisper-owned network traffic during launch, recording, import, transcription, and history use. Run the same check after opting into a model download and a summary request, confirming the disclosed destinations and payload classes.
- Run the native test and build commands from `AGENTS.md`; exclude the opt-in live OpenAI evaluation tests unless separately authorized.

## Product language

Say: **“Wisper sends nothing without your action. Recording and transcription stay on your Mac. If you choose to create an AI summary, Wisper sends the transcript to OpenAI.”** Do not claim that every summary is generated offline or that no content ever leaves the Mac.
