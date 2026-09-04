# Murmur

Dettatura locale per macOS, gratuita e on-device: un sostituto open di Wispr Flow
senza abbonamento e senza audio che lascia il computer.

 Premi il tasto, parli (italiano, inglese o un mix), premi di nuovo — il testo
pulito appare nel campo dove avevi il cursore. Tutto gira in locale: trascrizione
via [Nemotron 3.5 ASR](https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf)
(0.6B, Q5_K_M, ggml/Metal), pulizia del testo deterministica via regole.

Fork ridotto all'osso di [per-simmons/murmur-youtube](https://github.com/per-simmons/murmur-youtube):
un solo engine, una sola modalità hotkey, niente superficie Windows.

## Installazione

Serve macOS 26+, Xcode o i Command Line Tools, e ~720 MB di disco per il modello.

```bash
git clone https://github.com/daniele-pozza/murmur.git
cd murmur
make download-model   # scarica il modello (~700 MB, una volta sola)
make app && make install
```

L'app parte al termine di `make install`. Al primo avvio chiede **Accessibility**
(per l'hotkey globale e l'iniezione del testo) e **Microphone**: concedili in
System Settings. La prima dettatura dopo un riavvio carica il modello a freddo
(~25 s, la pillola mostra "Loading…"); poi resta caldo 20 s tra una dettatura
e l'altra.

Per l'installazione fatta da un agente AI, la guida passo-passo è
[AGENT_SETUP.md](AGENT_SETUP.md).

## Come si usa

1. Metti il focus in un campo di testo qualsiasi (di qualunque app).
2. Premi il tasto hotkey (default **Right ⌥**) — appare la pillola di dettatura.
3. Parla. La pillola mostra il feedback: waveform viva, coda del testo mentre
   arriva, timer.
4. Premi di nuovo — il testo pulito viene digitato dove era il cursore.

La cronologia delle dettature è nella finestra principale (menu bar ▸ Open
Murmur…): ricerca, copia, eliminazione.

### Impostazioni

Dal menu bar (icona waveform) o ⌘,:

- **Tasto hotkey** — Right ⌥ (default), fn, Right ⌘, o ⇪ Caps Lock (via F19)
- **HUD style** — quanto testo mostra la pillola: solo wave / ultima parola /
  coda della frase / parola + timer
- **Clean up text** — strippa filler, fix spazi e punteggiatura
- **Sound** — tick a inizio e fine dettatura

## Sviluppo

```bash
swift build     # build
make app        # bundle firmato
make install    # installa in /Applications e riavvia
swift build && .build/debug/murmur-youtube   # solo console
```

Il modello ggml non è `Sendable` ed è confinato nell'actor `NemotronModelCache`;
l'app fa `shutdown()` prima di `_exit(0)` per evitare che l'atexit di ggml
crashi con il device Metal ancora residente. Dettagli e convenzioni del repo in
[AGENTS.md](AGENTS.md).
