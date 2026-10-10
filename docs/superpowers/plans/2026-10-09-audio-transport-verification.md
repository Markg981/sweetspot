# Audio transport verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** Estendere il gate del percorso audio a profondità PCM miste e al payload DoP, conservando report riproducibili.

**Architecture:** Il confronto PCM esistente mantiene la corrispondenza esatta di tutti i bit. Un confronto DoP separato verifica tutti i payload stereo e l'alternanza dei marker, consentendo soltanto la fase iniziale legale riscritta da Squeezelite. Il driver aggiunge sei coppie PCM miste e due coppie DoP alla matrice originale, senza modificare il player del prodotto.

**Tech Stack:** Python 3 standard library, unittest, Lyrion JSON-RPC, Squeezelite stdout, chroot Linux esistente.

**Spec:** `docs/daphile-parity.md`, traguardo 1; continuazione di `docs/audio-verification.md`.

## Global Constraints

- Scope `software_stdout`: niente certificazione ALSA, DAC o DSD nativo.
- Frequenza costante per ciascuna coppia. Il raw non prova il cambio del clock; conservare il controllo sul rate del comparatore PCM.
- PCM misto 16→24 e 24→16 a 44100/48000/96000 Hz; DoP WAV24 a 176400/352800 Hz (payload equivalente DSD64/128).
- Il DoP usa marker 0x05/0xFA alternati e uguali sui due canali, con payload stereo di 16 bit per frame. S32_LE contiene [00, newer byte, older byte, marker]. Nessuna riduzione della precisione o ricerca arbitraria del contenuto.
- Ammessi ai bordi solo startup PCM nullo e silenzio DoP con payload 0x6969 per canale; il limite iniziale resta dichiarato. Dentro la sequenza nessun frame rimosso.
- Capture e RPC mantengono i limiti di tempo/spazio e la pulizia dei processi già verificati.
- Nessuna dipendenza Python nuova. PR verso `main`, push esplicitamente autorizzato; nessun merge.

## Review Focus

- Un bit significativo alterato nel segmento PCM24 deve fallire in entrambe le direzioni di transizione.
- Un bit del payload DoP alterato, canali invertiti o un frame perso/duplicato devono fallire anche se il DAC potrebbe ancora riconoscere i marker.
- Marker illegali, non alternanti o diversi fra L/R e padding S32 non nullo devono fallire; la sola fase iniziale legale può differire.
- Il silenzio DoP ai bordi non deve nascondere pause interne o contenuto non nullo; sorgente completamente silenziosa ambigua richiede un offset esplicito.
- Ogni caso ha un ID univoco e una cartella distinta; casi mancanti, duplicati o non riusciti non possono produrre un verdetto aggregato positivo.

## Task 1 — Fixture e confronto DoP

**Ownership:** `tools/audio_verification.py`, `tests/audio-verification.py`.

**Interfaces:**

```python
generate_dop_fixtures(directory: Path, rate: int,
                      frames: int | None = None) -> list[Path]
compare_dop_capture(references: list[Path], capture: Path, *,
                    capture_format: str, capture_rate: int,
                    offset_frames: int | None = None,
                    max_lead_frames: int = 0) -> dict
```

- [x] Test RED per confronto PCM misto esatto e corrotto, difetti ai confini in entrambe le direzioni, DoP payload/marker/packing e bordi.
- [x] Generare due WAV24 deterministici, brevi, con payload L/R e tracce distinti; dati diagnostici per capture digitale.
- [x] Implementare confronto DoP completo a memoria limitata; report `status`, `payload_match`, `markers_match`, `sequence_match`, frame, confini, primo errore, hash e fase dei marker.
- [x] Esporre CLI `generate-dop --output DIR --rate RATE` e `compare-dop` con le opzioni già usate da `compare`; conservare guardia report/input alias ed exit 0/1/2.
- [x] Test GREEN senza indebolire il confronto PCM originale.

## Task 2 — Matrice del motore reale

**Ownership:** `tests/prova-audio.py`, `tests/prova-audio-tests.py`.

- [x] Test RED per identità dei casi misti/DoP, selezione del confronto e aggregazione fail-closed.
- [x] Conservare i sei casi PCM originali e aggiungere sei casi misti più DoP176400/352800, per 14 casi totali con ID univoco e `source_bits` espliciti.
- [x] Le coppie miste usano la prima traccia a una profondità e la seconda all'altra. Le coppie DoP usano le nuove fixture, `-D 0:dop` e il confronto payload/marker; niente `-R`.
- [x] Test GREEN: prova orchestrata con pipe vere per PCM misto e DoP positivo/negativo; casi mancanti o duplicati falliscono.

## Task 3 — Collaudo e pubblicazione

**Ownership:** documentazione e Git/PR; integrazione CI soltanto se necessaria.

- [x] Eseguire i 14 casi nella rootfs x86 disponibile, registrando versione/hash esatti; la nuova CI resta distinta da questa prova di sviluppo.
- [x] Eseguire suite completa, diff-check e revisione indipendente del branch.
- [x] Aggiornare README, protocollo e stato del traguardo 1: copertura PCM misto e DoP nel backend software, DSD nativo/hardware/rate switching ancora aperti.
- [x] Commit e push sul nuovo branch, PR verso main con risultati e limiti, attach della PR alla chat e avvio/verifica dello stato CI sul commit pubblicato.

La base è `origin/main` commit `6ee1e6e`, che contiene la PR precedente #13.

Checkpoint di collaudo del 2026-10-10: 405 controlli locali superati;
14/14 casi nella rootfs `dipendenze-lyrion-27-gf1dafae-dirty` dell'artifact
37977755339, report `graphify-out/audio-evidence/run.STLgVR/report.json`.
SHA-256 Squeezelite:
`2a4c847aa51a2172947c4b378deeea53d263d275bd22aadf1bd112868b8badb8`.
Le due revisioni indipendenti hanno confermato le correzioni dei falsi positivi
per PCM nullo dentro il DoP e per errori di pulizia dopo un confronto riuscito.
Pubblicato come PR #14, commit `3ae1796`, con CI 38026669051 superata su x86 e
ARM. Il merge in main è `9e53ed2`; la successiva estensione DSF/DFF conserva
questa baseline di 14 casi.
