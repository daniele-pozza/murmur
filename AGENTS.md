# Working on this repo

Personal fork of [per-simmons/murmur-youtube](https://github.com/per-simmons/murmur-youtube)
(remote `upstream`), trimmed to a minimal single-engine macOS app. Diverges from that
project's own `AGENTS.md`/README in real ways — don't trust upstream docs for this tree.

## What this is

Press-to-toggle dictation: press a key, talk, press again, cleaned-up text is typed into
whatever had focus. macOS only, Swift 6, SwiftUI. One transcription engine
(`WhisperKitEngine`, Whisper large-v3-turbo via WhisperKit — multilingual with automatic
per-utterance language detection). One text formatter (`RuleBasedFormatter`, deterministic
cleanup — no LLM tier).

Cut relative to upstream: the Windows/C# app, the dictionary/correction feature, the
engine-comparison window and dashboard, Parakeet and Apple `SpeechAnalyzer` engines, the
Foundation Models cleanup tier, and the Wispr Flow integration. Don't reintroduce any of
these speculatively — see the README's "Not built yet" for what's actually planned.

Not yet verified end to end: a human has not held the key, talked, and confirmed the
transcript/injection. `swift build` and `make app` both succeed (see README "Verified").

## Working here

- `swift build` from repo root; `make app` / `make install` for a signed bundle.
- The hotkey is a *toggle*, not push-to-talk — `DictationController.toggleDictation()`
  flips idle↔recording on every press of the configured key. `HotkeyMonitor` only reports
  raw press/release transitions; the toggle logic lives in the controller, not the monitor.
- `TranscriptionEngine` and `TextFormatter` are still protocols (single implementation
  each) — keep using them as the seam if you swap either out, don't inline.
- WhisperKit's `WhisperKit` class isn't `Sendable`; it's confined to the private
  `WhisperKitModelCache` actor in `WhisperKitEngine.swift` and never leaves it.
