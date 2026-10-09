# Audio verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Rendere riproducibile la verifica dei campioni PCM e della continuità fra brani nel percorso Lyrion/Squeezelite.

**Architecture:** Un comparatore Python senza dipendenze esterne normalizza WAV PCM e capture raw a interi signed con precisione 32 bit. Un driver avvia il Squeezelite della rootfs in stdout, controlla un Lyrion isolato già avviato e acquisisce una sequenza di brani con lettore temporizzato e limiti di spazio/tempo. La CI esegue questa prova nelle rootfs x86 e ARM, senza attribuirle una certificazione del DAC.

**Tech Stack:** Python 3 standard library, unittest, BusyBox shell, Lyrion JSON-RPC, Squeezelite stdout, chroot della CI esistente.

**Spec:** `docs/daphile-parity.md`, traguardo 1. Questa prima consegna copre PCM e sequenze gapless nel backend software; DSD/DoP, cambi frequenza, hotplug/carico e certificazione fisica restano esplicitamente aperti.

## Global Constraints

- Conservare il percorso di riproduzione del prodotto e i player dell'utente: utilizzare un server/rootfs isolati e una MAC fixture.
- Un verdetto software stdout non certifica ALSA, clock o uscita analogica.
- Non eliminare campioni diversi per far combaciare la capture; sono ammessi soltanto silenzio iniziale/finale dichiarato e normalizzazione del contenitore.
- Nessun nuovo pacchetto Python; output JSON con formato, frequenza, hash, numero di frame, confini e primo errore.
- Nessun file di capture infinito: limiti di byte e durata, lettura stdout temporizzata e pulizia dei processi anche in caso d'errore.

## Review Focus

- Silenzio inserito, frame perso/duplicato o canali invertiti devono fallire.
- I 24 bit in contenitore packed o ALSA S24_LE e il segno devono essere confrontati correttamente.
- Capture troncate, WAV malformati e rate dichiarato diverso devono fallire chiaramente.
- L'allineamento automatico deve accettare solo silenzio prima della sorgente e rifiutare una sorgente totalmente silenziosa ambigua.
- La prova deve attendere il player, propagare errori RPC e arrestare tutti e soltanto i processi che crea.

## Task 1 — Fixtures e comparatore

**Files:** `tools/audio_verification.py`, `tests/audio-verification.py`.

**Interfaces:**

```python
generate_fixtures(directory: Path, rate: int, bits: int, frames: int | None = None) -> list[Path]
compare_capture(references: list[Path], capture: Path, *, capture_format: str,
                capture_rate: int, offset_frames: int | None = None,
                max_lead_frames: int = 0) -> dict
```

I riferimenti sono WAV integer PCM stereo a 16/24/32 bit; la capture è raw
`s16_le`, `s24_3le`, `s24_le` o `s32_le`. I formati float/compressi non sono
interpretati come PCM. Rate e canali dei riferimenti devono coincidere.
`max_lead_frames` limita il silenzio iniziale; l'allineamento esplicito resta
visibile nel report. Le fixtures hanno due canali distinti, campioni non nulli,
livello contenuto e nomi che distinguono frequenza/profondità/traccia.

- [x] Scrivere unit test per sequenza esatta, difetti di confine, segno/contenitori, troncamenti e metadata errati; eseguire e osservare RED.
- [x] Implementare generazione deterministica, normalizzazione e confronto completo a memoria limitata.
- [x] Esporre CLI `generate --output DIR --rate RATE --bits BITS` e `compare --reference WAV` ripetibile, `--capture RAW --capture-format FORMAT --capture-rate RATE --max-lead-frames N --report JSON`.
- [x] Verificare GREEN: `python3 tests/audio-verification.py`; exit 0 match, 1 mismatch, 2 input invalido.

## Task 2 — Lyrion/Squeezelite reali

**Files:** `tests/prova-audio.py`, `tests/prova-audio-tests.py`.

**Consumes:** le due funzioni del Task 1. **Produces:** CLI
`python3 tests/prova-audio.py --rootfs ROOT --server http://127.0.0.1:9000 --output DIR --version VERSION`.

- [x] Scrivere test delle condizioni d'errore, limiti e pulizia, osservare RED prima di implementare.
- [x] Per ogni coppia rate/profondità (44100/48000/96000 × 16/24), generare due WAV in una cartella locale della rootfs posseduta dalla prova, leggibile da Lyrion. Usare una M3U locale per accodare entrambi i brani prima dell'avvio.
- [x] Avviare `chroot ROOT /usr/bin/squeezelite -o - -a 32 -r RATE -s 127.0.0.1 -m MAC_FIXTURE -f /tmp/audio-verification.log`; acquisire raw stereo con pacing, tempo e byte limitati.
- [x] Attendere la registrazione RPC; volume 100, ReplayGain e transizioni spenti, playlist dei due file. Verificare le risposte e rileggere le preferenze; non modificare player non appartenenti alla fixture.
- [x] Confrontare l'intera sequenza; registrare sei verdetti, hash del Squeezelite, versione rootfs e scope `software_stdout`. Fallire se una prova fallisce o resta incompleta.
- [x] Eseguire una prova reale sulla rootfs CI disponibile, annotando la sua versione esatta; nessuna simulazione deve essere presentata come prova del motore reale.

## Task 3 — Integrazione e consegna

**Files:** `tests/prova-lyrion.sh`, `tests/run.sh`, `.github/workflows/build.yml`, `README.md`, `docs/daphile-parity.md`, `docs/audio-verification.md`.

- [x] Invocare il driver dentro la rootfs già avviata, prima di considerare riuscito il job Lyrion; copiare i report fuori dal chroot prima della pulizia.
- [x] Installare Python3 nel job e allegare l'evidenza anche quando una verifica fallisce.
- [x] Aggiungere i test offline alla suite veloce; adattare i test dei gate della release solo se necessario.
- [x] Documentare CLI, limiti, scope e prove hardware ancora da eseguire; aggiornare il primo traguardo come parzialmente coperto.
- [x] Eseguire la suite completa, ShellCheck e diff-check; revisione indipendente.
- [x] Preparare commit e push sul nuovo branch; esito Git e CI riportato nel riepilogo della chat.

Ruling: il nuovo branch parte da `23410bf`, che include `origin/main` e le
migliorie/piano autorizzati. Una nuova base da main senza quei commit
perderebbe il lavoro necessario alla verifica.
