# Local Speech Pipeline Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select a local transcription and speaker-diarization pipeline for Wisper using the same English, Ukrainian, and mixed-language recordings on supported Macs.

**Architecture:** Keep private evaluation audio and model outputs under the already-ignored `audio/` directory. Use each vendor's Swift CLI to run inference locally, a small standard-library scorer for word and character error, and a blinded review of speaker-labeled turns. Record a release decision before adding any speech SDK to the app.

**Tech Stack:** macOS 14+, Swift CLI tools from FluidAudio and Argmax OSS, Python 3 standard library, existing `audio/*` ignore rule, `gh` for GitHub repository access.

**Spec:** `docs/superpowers/specs/2026-09-22-explicit-network-actions-design.md`

## Global Constraints

- Wisper must not initiate a network request without a specific user action that makes the destination and purpose clear.
- English is the first transcription priority; Ukrainian is the second and is required. Other languages are desirable.
- Diarization is required. Test two, four, and more than four speakers, short turns, overlap, and long calls.
- Test macOS 14+ and supported Mac architectures; no silent cloud fallback.
- Keep raw recordings, reference transcripts, model outputs, and speaker annotations out of GitHub. `audio/*` is already ignored by `.gitignore`.
- Do not run `MeetingNotesLiveEvalTests` or print its API key.
- Use `gh` for GitHub repository operations. `rtk` is unavailable on the current host; use raw commands only until it is installed.

## File Map

- `harness/speech_eval/score.py`: deterministic Unicode-preserving WER/CER scorer; reads only local files.
- `harness/speech_eval/test_score.py`: scorer unit tests.
- `harness/speech_eval/README.md`: corpus format, exact local CLI runs, privacy rules, and review rubric.
- `audio/speech-eval/`: ignored, user-supplied or locally prepared audio, reference text, and speaker annotations.
- `docs/superpowers/specs/2026-09-22-explicit-network-actions-design.md`: add the selected runtime and hardware decision only after measured results exist.

## Review Focus

1. A Ukrainian apostrophe or Cyrillic letter must survive normalization; `test_score.py` covers it.
2. Empty reference text must fail validation rather than produce a misleading zero WER; `test_score.py` covers it.
3. Mixed-language speech must be scored as spoken, without English translation; the corpus rubric and output review cover it.
4. A meeting with more than four remote speakers must not appear to pass by silently merging speakers; the diarization review includes one such case.
5. A model loader must not download or call home during an offline inference run; the CLI test repeats with networking disabled after an explicit model download.

---

### Task 1: Prepare a private, representative corpus

**Files:**
- Create: `harness/speech_eval/README.md`
- Local only: `audio/speech-eval/manifest.json` and corresponding media/reference files

**Interfaces:**
- Produces a JSON object with `cases`, each case containing `id`, `language` (`en`, `uk`, or `mixed`), `audio`, `reference`, `speakerTurns`, `captureMode`, and `durationSeconds`.
- Paths are relative to `audio/speech-eval/`; `speakerTurns` points to an RTTM file. Each turn is `SPEAKER <case-id> 1 <start-seconds> <duration-seconds> <NA> <NA> <speaker-id> <NA> <NA>`.

- [ ] **Step 1: Write the corpus contract** in `harness/speech_eval/README.md` with this exact example:

```json
{"cases":[{"id":"en-two-speakers","language":"en","audio":"en-two-speakers.m4a","reference":"en-two-speakers.txt","speakerTurns":"en-two-speakers.rttm","captureMode":"imported","durationSeconds":120}]}
```

- [ ] **Step 2: Assemble local examples**: at least four English, four Ukrainian, two mixed-language, two overlapping-speech, one four-speaker, one five-or-more-speaker, and one 30-minute-or-longer recording. A case may satisfy multiple categories. Obtain consent and correct each reference transcript by hand. Use neutral speaker IDs in `speakerTurns`; do not infer real names.
- [ ] **Step 3: Verify the corpus**: each referenced path exists, every reference contains speech, all turn intervals have `0 <= startSeconds < endSeconds <= durationSeconds`, and each case has a unique ID. Do not proceed to model ranking while any condition fails.
- [ ] **Step 4: Verify privacy**: inspect `.gitignore` to confirm `audio/*` covers the corpus. Never run `gh` with audio or transcript paths as arguments.

### Task 2: Build a deterministic ASR scorer

**Files:**
- Create: `harness/speech_eval/score.py`
- Create: `harness/speech_eval/test_score.py`

**Interfaces:**
- `normalize(text: str) -> str` preserves Unicode letters and digits plus apostrophes inside words, case-folds, and collapses whitespace.
- `error_rate(reference: str, hypothesis: str, unit: str) -> float` supports `word` and `character`, raising `ValueError` for an empty reference or unknown unit.
- CLI: `python3 harness/speech_eval/score.py REFERENCE.txt HYPOTHESIS.txt` prints `WER=... CER=...`.

- [ ] **Step 1: Write failing unit tests**:

```python
import unittest
from score import error_rate, normalize

class ScoreTests(unittest.TestCase):
    def test_ukrainian_text_is_preserved(self):
        self.assertEqual(normalize("П'ять, ґанок! Київ."), "п'ять ґанок київ")
        self.assertEqual(error_rate("Привіт, світе!", "привіт світе", "word"), 0)

    def test_one_substitution_out_of_two_words(self):
        self.assertEqual(error_rate("alpha beta", "alpha gamma", "word"), 0.5)

    def test_empty_reference_is_rejected(self):
        with self.assertRaises(ValueError):
            error_rate(" ", "speech", "word")
```

- [ ] **Step 2: Run** `python3 -m unittest discover -s harness/speech_eval -p 'test_*.py'` and confirm failure before implementation.
- [ ] **Step 3: Implement** `harness/speech_eval/score.py` with this standard-library code:

```python
import argparse
import sys
from pathlib import Path


def normalize(text: str) -> str:
    text = text.casefold().replace("’", "'").replace("ʼ", "'")
    characters = []
    for index, character in enumerate(text):
        if character.isalnum() or character.isspace():
            characters.append(character)
        elif character == "'" and 0 < index < len(text) - 1 and text[index - 1].isalpha() and text[index + 1].isalpha():
            characters.append(character)
        else:
            characters.append(" ")
    return " ".join("".join(characters).split())


def distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for column, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[column] + 1,
                               previous[column - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def error_rate(reference: str, hypothesis: str, unit: str) -> float:
    if unit not in {"word", "character"}:
        raise ValueError("unit must be word or character")
    expected, actual = normalize(reference), normalize(hypothesis)
    if not expected:
        raise ValueError("reference contains no words")
    if unit == "word":
        expected_items, actual_items = expected.split(), actual.split()
    else:
        expected_items, actual_items = list(expected.replace(" ", "")), list(actual.replace(" ", ""))
    return distance(expected_items, actual_items) / len(expected_items)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypothesis", type=Path)
    args = parser.parse_args()
    try:
        reference = args.reference.read_text(encoding="utf-8")
        hypothesis = args.hypothesis.read_text(encoding="utf-8")
        print(f"WER={error_rate(reference, hypothesis, 'word'):.4f} "
              f"CER={error_rate(reference, hypothesis, 'character'):.4f}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Scoring failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
```
- [ ] **Step 4: Run** the same unittest command and confirm all tests pass; then check the CLI manually on the two-word example and confirm `WER=0.5000`.

### Task 3: Run local transcription candidates on the same files

**Files:**
- Modify: `harness/speech_eval/README.md`
- Local only: `audio/speech-eval/outputs/`

**Interfaces:**
- One UTF-8 transcript per `case.id` and candidate. Name files `outputs/<candidate>/<case.id>.txt`.

- [ ] **Step 1: Check out vendor CLIs into `/private/tmp/wisper-speech-eval/` using** `gh repo clone FluidInference/FluidAudio` and `gh repo clone argmaxinc/argmax-oss-swift`. Pin both to immutable release tags and record their version strings in the report. Obtain approval for model downloads when the CLI requests network access; no meeting audio is uploaded.
- [ ] **Step 2: Explicitly download** Parakeet TDT v3 and WhisperKit `large-v3-v20240930_626MB` model assets to local cache. Record URLs, license, bytes, and SHA-256 for each installed model. For the app integration, use vendor-documented local model loading; CLI defaults are acceptable only for this evaluation after confirming an offline run.
- [ ] **Step 3: Probe the named English clip** with `swift run -c release fluidaudiocli transcribe audio/speech-eval/en-two-speakers.m4a --model-version v3` and `swift run -c release argmax-cli transcribe --model-path Models/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB --audio-path audio/speech-eval/en-two-speakers.m4a --incremental-loading`. Run the corresponding Ukrainian clip from the manifest the same way. Disconnect networking during the probe. If a CLI requires a fetch despite cached models, mark that candidate **offline-unverified** and stop its ranking; a separate SDK loading probe is required before it can be selected. Confirm output remains in its source language; write only recognized text to the corresponding ignored output file.
- [ ] **Step 4: Process every case** with both candidates on the same Mac, model version, and input file. For long audio, use WhisperKit's documented incremental loading. Record wall time, peak resident memory, input duration, failures, and whether either CLI makes a network request after its models are already installed.
- [ ] **Step 5: Score** each output with `score.py`; calculate median and worst-case WER/CER separately for `en`, `uk`, and `mixed`. Note names, dates, and action items lost or mistranscribed, since they affect Wisper's summaries more than punctuation differences.

### Task 4: Run local diarization candidates on the same files

**Files:**
- Modify: `harness/speech_eval/README.md`
- Local only: `audio/speech-eval/outputs/`

**Interfaces:**
- One RTTM file per case and candidate, plus a review CSV with `caseId,candidate,missedTurns,wrongSpeakerTurns,overlapErrors,notes`.

- [ ] **Step 1: Explicitly download** SpeakerKit's Pyannote model pack and FluidAudio's offline diarization model pack; record model source, license, byte count, and SHA-256. Load only from the installed local folders during inference.
- [ ] **Step 2: Run the named English case** with `swift run -c release argmax-cli diarize --audio-path audio/speech-eval/en-two-speakers.m4a --rttm-path audio/speech-eval/outputs/speakerkit/en-two-speakers.rttm` and `swift run -c release fluidaudiocli process audio/speech-eval/en-two-speakers.m4a --mode offline --rttm audio/speech-eval/en-two-speakers.rttm`. Repeat for every manifest case, using its own RTTM path. Disconnect networking during inference; mark any CLI that requires a fetch **offline-unverified** and stop its ranking until a separate SDK loading probe succeeds. Keep all outputs under ignored `audio/speech-eval/outputs/`.
- [ ] **Step 3: Review randomized, unlabeled candidate outputs** against the reference RTTM. Count missed turns, wrong speaker assignments, and overlap errors, especially on Ukrainian, five-or-more-speaker, and 30-minute cases. Compute a separate source-aware result for recordings with microphone and system audio tracks; count false **You** labels and duplicate echo turns.
- [ ] **Step 4: Test macOS 14 on supported hardware** before selecting FluidAudio's offline diarizer: its own documentation reports a BNNS/Core ML crash on this OS. A crash disqualifies that candidate for a macOS 14 release regardless of its accuracy elsewhere.

### Task 5: Make and document the engine decision

**Files:**
- Create: `harness/speech_eval/decision.md`
- Modify: `docs/superpowers/specs/2026-09-22-explicit-network-actions-design.md`

**Interfaces:**
- Produces the chosen ASR and diarizer, exact model versions, supported Mac architectures, macOS floor, measured tradeoffs, download size, and any unsupported languages.

- [ ] **Step 1: Fill a comparison table** with per-language median and worst-case WER/CER, speaker-turn errors, long-file behavior, wall time, peak memory, offline behavior, model download size, and macOS 14 result. Do not combine unlike corpora into one score.
- [ ] **Step 2: Choose an ASR** that is usable in both English and Ukrainian; reject any option that silently translates Ukrainian or repeatedly loses key names, dates, or commitments. Prefer Parakeet v3 only if direct results justify it. WhisperKit remains the broad-language option if its required-language quality is acceptable.
- [ ] **Step 3: Choose a diarizer** that remains stable over full meetings and can handle the observed speaker count; reject a candidate that crashes on supported macOS releases or often assigns another person's commitments to **You**.
- [ ] **Step 4: Update the spec** with the measured choice and source-aware versus mixed-audio strategy. If neither candidate clears these gates, record the failing evidence and revise the product scope before writing the app-integration plan. No cloud transcription is enabled as a fallback.

## Verification

Run `python3 -m unittest discover -s harness/speech_eval -p 'test_*.py'`. Audit that all corpus and generated files remain under ignored `audio/`; test one inference after disconnecting the Mac from the network. The test report must state that model authors' published benchmarks were not used as a substitute for same-corpus measurements.
