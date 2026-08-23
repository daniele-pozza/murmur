# Handoff — murmur-mio

Personal fork of [per-simmons/murmur-youtube](https://github.com/per-simmons/murmur-youtube), cut down to
an MVP and switched to a different transcription engine. macOS only, personal use, not published anywhere.

## What this is

Push-to-talk dictation: press a hotkey, talk, press again, cleaned-up text lands in whatever field has
focus. Built because the upstream project used a slow-loading multilingual engine (WhisperKit/CoreML) and
we wanted something faster that handles mixed Italian/English speech.

## Current state: working

Last verified: dictation → transcription → paste works end to end, model loads in ~1s, mixed IT/EN speech
transcribes correctly (see conversation history for the actual test — 372 chars pasted cleanly).

## Key decisions from this fork

- **Scope cut to MVP**: dropped the dictionary/correction feature, comparison window, dashboard, the
  Windows (C#/Avalonia) implementation, and the Wispr Flow integration that shipped upstream. Only:
  hotkey → audio capture → transcription → cleanup → paste → HUD.
- **Hotkey is press-to-toggle, not push-to-talk**: first press starts recording, second press stops and
  transcribes. `DictationController.toggleDictation()`. Configurable key (Right ⌥ / fn / Right ⌘) via
  `Settings`, same as upstream.
- **Transcription engine, twice**: started with `WhisperKitEngine` (Whisper large-v3-turbo via CoreML/ANE).
  Dropped it — first-run ANE compilation was unpredictable, once took 10+ minutes and had to be killed.
  Replaced with **`NemotronEngine`** (`Sources/MurmurYouTube/Transcription/NemotronEngine.swift`), backed by
  [`transcribe.cpp`](https://github.com/handy-computer/transcribe.cpp) (MIT, ggml/Metal, C API) running
  NVIDIA's Nemotron 3.5 ASR streaming 0.6B model in GGUF format. Loads in ~0.6–1.2s, no AOT compile step,
  supports it-IT/en-US and ~30 other locales with automatic language detection, and streams partial
  results (the HUD shows live text while you talk, not just at the end).
- **Model file location**: `~/.cache/huggingface/hub/models--handy-computer--nemotron-3.5-asr-streaming-0.6b-gguf/`
  — the *shared* Hugging Face cache, not owned by any single app. It was originally downloaded by another
  app on this machine ([Handy](https://github.com/cjpais/Handy), already installed, MIT licensed) but this
  fork does **not** depend on Handy at runtime — it only reads the model file from that shared cache path.
  Uninstalling Handy does not delete it (confirmed: Handy's own app-support folder doesn't hold a copy).
  If that cache path is ever cleared, the model needs to be re-fetched from Hugging Face
  (`handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf`) — there's no auto-download wired up in this fork.
- **Language handling**: no manual toggle. One hotkey, automatic per-utterance language detection.
- **`CTranscribe.framework`**: transcribe.cpp is vendored/embedded as a framework in the app bundle;
  library validation is disabled to allow loading it un-notarized. Worth revisiting once Developer ID
  signing is set up (see below) — line up notarization or re-evaluate how the framework is embedded.
- **HUD**: 280×62pt, sits 56pt above the Dock, centered. (Started at 340×76 / 96pt, shrunk and lowered on
  request.)

## Known friction: TCC permissions break on every rebuild

No Developer ID certificate is installed on this machine, so the `Makefile` falls back to **ad-hoc
signing**. macOS ties the Accessibility/Microphone grant to the exact code signature, and an ad-hoc
signature changes on every build — so **every single rebuild silently invalidates both permissions**. The
symptom: Accessibility still shows "on" in System Settings, but `CGEvent.tapCreate` fails and the hotkey
never fires.

Workaround used all session, repeat after every `make install`:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur-youtube
tccutil reset Microphone ai.pivotstudio.murmur-youtube
```

Then: fully quit System Settings (⌘Q — the pane caches its list and won't show the reset otherwise),
reopen it, re-grant Accessibility, relaunch the app.

**Real fix, not yet done**: get a Developer ID Application certificate via Xcode — this requires enrolling
in the paid Apple Developer Program ($99/year) as account holder; a free Apple ID only gets an "Apple
Development" personal-team cert, which is a different thing and doesn't solve this (verified against
Apple's docs, see https://developer.apple.com/developer-id/). The `Makefile` already auto-detects a
Developer ID cert via `security find-identity` and prefers it over ad-hoc — once one exists, grants should
survive rebuilds with no further action needed. Deferred: not worth $99/year for a personal-use app; the
`tccutil reset` workaround stays.

## Build / run

```bash
cd /Users/danielepozza/Projects/Learn/murmur-mio
swift build          # compile check
make install          # build, sign (ad-hoc for now), copy to /Applications, launch
```

After install, if the hotkey doesn't respond: it's almost certainly the TCC issue above — reset and
re-grant.

## Repo layout notes

- `upstream` remote points at the original `per-simmons/murmur-youtube` — this was a real `git clone`, not
  a from-scratch copy, so `git log` has the full original history plus this fork's commits on top.
- No GitHub remote for this fork itself — purely local, per explicit request (personal use, not
  publishing).
- `AGENTS.md` and `README.md` were kept updated as scope changed; check those for any drift if this doc
  goes stale.

## Open items / possible next steps (none committed to, just what's visibly unfinished)

- Developer ID signing (see above) — would remove the rebuild/TCC dance entirely, but costs $99/year;
  deferred for now.
- `CTranscribe.framework` embedding was the fastest path to a working build; not stress-tested across
  macOS updates or a clean machine — if this ever needs to run somewhere else, re-verify it loads.
- No automated tests for `NemotronEngine`/streaming behavior beyond manual verification in this session.
- ~~`RuleBasedFormatter` cleanup step hasn't been specifically checked against Italian text edge cases~~
  Checked: capitalization after periods and elision apostrophes (`l'amico`, `c'è`, accented uppercasing
  à→À/è→È) all work correctly via Swift's Unicode-aware `Character.uppercased()`. Found and fixed one bug:
  `ensureTerminalPunctuation` only treated letters/numbers as word-ending, so truncated Italian forms like
  `po'`, `va'`, `di'` were left without a trailing period — now apostrophe counts too.
- If the model cache at `~/.cache/huggingface/hub/...` is ever missing, there's no in-app re-download path
  — would need to either reintroduce a downloader or manually re-fetch via `huggingface-cli` / `hf`.
