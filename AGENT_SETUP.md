# Guida di installazione per agenti

Murmur è un sostituto gratuito e open di Wispr Flow per macOS: dettatura locale,
on-device, nessun abbonamento, nessun audio che lascia il computer. Questo file è
scritto per un agente (Claude Code, pi, Cursor, …) che deve installarlo sulla
macchina di un membro del team. Seguilo in ordine e non inventarti passaggi extra.

## Requisiti

- macOS 26+ con Xcode o Command Line Tools (`xcode-select --install`)
- ~720 MB di disco per il modello
- Permessi Accessibility + Microphone (l'app li chiede al primo avvio)

## Installazione

```bash
git clone https://github.com/lellopz05/murmur.git
cd murmur
make app && make install   # build, firma e copia in /Applications/Murmur.app
open /Applications/Murmur.app
```

Il clone scarica da solo la dipendenza binaria (transcribe.cpp via SwiftPM) al primo
`swift build`. Nessun passo aggiuntivo.

## Modello (fallo tu, non l'utente)

L'engine è Nemotron 3.5 ASR streaming 0.6B (Q5_K_M, gguf, via transcribe.cpp su
ggml/Metal). L'app **non** lo scarica: mettilo tu, prima del primo uso:

```bash
mkdir -p ~/Library/"Application Support"/MurmurYouTube
curl -L -o ~/Library/"Application Support"/MurmurYouTube/nemotron-3.5-asr-streaming-0.6b-Q5_K_M.gguf \
  https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/main/nemotron-3.5-asr-streaming-0.6b-Q5_K_M.gguf
```

Verifica: `ls -la` del file — deve essere ~700 MB. Se il download è interrotto,
riprendilo con `curl -C -` (stesso comando). Senza questo file la prima dettatura
fallisce con "Nemotron GGUF not found".

## Impostazioni

I default sono già quelli giusti — **non toccare nulla**:

- Hotkey: `F19` (toggle: premi per iniziare, premi per fermare)
- Clean up text: ON (strippa filler, fix punteggiatura e spazi)
- Sound: ON (tick a inizio/fine)
- HUD style: "Word + timer" (pillola compatta fissa: wave + ultime parole + timer)

Se l'utente vuole un altro stile HUD o un altro tasto: menu bar (icona waveform) o
⌘, in Settings. Tutto persistito in UserDefaults, niente file di config.

## Primo avvio

1. Al primo avvio l'app chiede Accessibility (serve per l'hotkey globale e per
   iniettare testo) e Microphone. Concedili in System Settings.
2. Il primo use dopo un riavvio carica il modello a freddo: la pillola mostra
   "Loading…" per ~25 s. È normale; poi il modello sta caldo 20 s tra una
   dettatura e l'altra.
3. Test: metti il focus in un campo di testo, premi F19, parla, premi F19. Il testo
   pulito appare dove era il cursore. La cronologia è nella finestra principale
   (menu bar ▸ Open Murmur…).

## Se qualcosa non funziona

- `swift build` fallisce → quasi sempre Xcode/CLT mancanti o versioni vecchie.
- Nessun testo iniettato → Accessibility non concessa per Murmur.
- "Nemotron GGUF not found" → il passo Modello sopra non è stato fatto/bene.
- Log: `log stream --predicate 'process == "MurmurYouTube"'` (o Console.app).
