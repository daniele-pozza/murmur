# Murmur YouTube

Press-to-toggle dictation for macOS, multilingual. Press a key, talk in Italian, English,
or a mix of the two, press again — cleaned-up text lands in whatever text field has focus.
Fully on-device: audio never leaves the machine.

This is a personal fork of [per-simmons/murmur-youtube](https://github.com/per-simmons/murmur-youtube),
trimmed to one engine, one hotkey mode, and no dictionary/comparison/Windows surface —
see `git log upstream/main..main` for what changed.

**Status:** working skeleton. Builds, launches, arms the hotkey, transcribes, injects.
Voice has not been tested end to end with a human yet (see Verified below).

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.murmur-youtube`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `MurmurYouTube`** — distinct enough that `pkill -x MurmurYouTube` cannot
  match a differently-named binary. The `Makefile` only ever targets `$(EXEC)`.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘) precisely because another tool may
  already own the key you'd reach for first. The event tap inspects only its own keycode
  and passes everything else through untouched.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant two permissions — neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |

Restart Murmur YouTube after granting Accessibility. Then press **Right ⌥** to start
talking, press it again to stop.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore signs with a stable Developer ID (auto-detected via
`security find-identity`, falling back to ad-hoc). Verified: rebuild + reinstall keeps both
grants with no re-prompt.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur-youtube
tccutil reset Microphone   ai.pivotstudio.murmur-youtube
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

---

## Architecture

```
 press key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                 │
                      ┌──────────┼──────────┐
                      ▼          ▼          ▼
               AudioCapture  HUDPanel   TranscriptionEngine
                      │                      │
                 (AudioChunk) ──ordered──► NemotronEngine
                                             │
                                        (transcript)
                                             ▼
                                       TextFormatter
                                             ▼
                                       TextInjector ─► focused app
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
discrimination don't surface through `NSEvent.addGlobalMonitorForEvents` or the Carbon
hotkey API. A session event tap is the only way to see them — which is why Accessibility
permission is a hard requirement rather than a nicety.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols so the
two components most likely to change can change without touching anything else.

### Layout

```
Sources/MurmurYouTube/
├── MurmurYouTubeApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything, toggle logic
│   ├── HotkeyMonitor.swift         CGEventTap on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap + format conversion + RMS
│   └── TextInjector.swift          AX insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   └── NemotronEngine.swift        Nemotron 3.5 ASR streaming, auto language detection
├── Formatting/
│   └── TextFormatter.swift         protocol + RuleBasedFormatter
├── UI/
│   ├── MainWindow.swift            transcription history
│   ├── HUDPanel.swift              non-activating floating panel
│   └── HUDView.swift               waveform + live transcript, Brand palette
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift, RunLog.swift
```

---

## Speech engine

**Nemotron 3.5 ASR streaming (0.6B, GGUF)** via
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) on ggml/Metal —
multilingual (~30 languages including Italian and English) with automatic per-utterance
language detection, so one hotkey covers Italian, English, or a mix with a dominant
language, no manual language switch.

The native library is consumed as transcribe.cpp's prebuilt `TranscribeCpp.xcframework`
release asset (a SwiftPM `binaryTarget`, see `Package.swift`); its thin Swift wrapper is
vendored under `Sources/TranscribeCpp/` (MIT, no published SwiftPM mirror exists yet — see
that folder's `LICENSE`). No CMake build step needed.

Unlike the CoreML/ANE path this replaced, there's no ahead-of-time compile: the model
loads from its GGUF weights in about a second. Streaming is real, too —
`NemotronEngine.feed()` yields committed/tentative text as audio arrives (via
`transcribe.cpp`'s stream API), so the HUD updates live instead of only at release.

**The model file itself isn't bundled or downloaded by this app.** It expects the GGUF
already sitting in the shared Hugging Face cache at
`~/.cache/huggingface/hub/models--handy-computer--nemotron-3.5-asr-streaming-0.6b-gguf/`
— the same path the [Handy](https://github.com/cjpais/Handy) dictation app populates on
its first run. Install Handy once (even if you don't keep using it) to get the weights;
this app never talks to Handy itself, it only reads that cache path. `NemotronEngine`
fails with a clear error at dictation start if the file isn't there.

---

## Not built yet

1. **LLM cleanup tier.** `RuleBasedFormatter` strips fillers, fixes spacing, capitalizes
   sentences and adds terminal punctuation — genuinely useful, entirely deterministic, and
   language-agnostic enough to not need per-locale rules yet. An LLM-backed tier (Apple
   Foundation Models, or Claude) would be the next step if this stops being enough.
2. **Personal dictionary.** Names and jargon the ASR keeps missing. Cut in this fork along
   with the comparison/dashboard tooling it depended on — add back if recognition errors
   turn out to be recurring in practice rather than one-off.
3. **Branding.** `Brand` in `HUDView.swift` is a two-color placeholder gradient. App icon,
   real palette, HUD motion design, onboarding.
4. **Developer ID signing + notarization.** Ends the TCC-reset churn and makes the app
   distributable (not a goal for this fork — personal use only).

---

## Verified

- `swift build` and `make app` both complete clean under Swift 6 strict concurrency,
  including the `TranscribeCpp` binary target and its vendored Swift wrapper.
- Signs (ad-hoc or Developer ID) and assembles into a real `.app` bundle.

**Not yet verified:** the actual dictation path — press key, talk, press again, get text.
That needs a human with a microphone, Accessibility + Microphone permissions granted, and
the Nemotron GGUF present in the shared Hugging Face cache (see "Speech engine" above).
Also unverified: whether Nemotron's per-utterance language detection is good enough in
practice for Italian/English mixed speech, and whether `RuleBasedFormatter`'s cleanup
rules hold up on Italian output (see "Not built yet" above).
