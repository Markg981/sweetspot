# Qualificazione: cosa e' stato eseguito e cosa no

Questo documento separa le prove **eseguite in sviluppo** da quelle che
**richiedono hardware, account o tempo** e non sono state eseguite. Nessun
numero di prestazioni, durata o qualita' audio reale e' riportato qui: non e'
stato misurato.

## Strumenti

| Strumento | Cosa fa |
|---|---|
| `scripts/qualifica-libreria.py corpus DIR --files N` | Crea un corpus FLAC/WAV riproducibile (`--seed`): tag Vorbis, artisti Unicode (NFC e NFD, CJK, ebraico, arabo, greco, cirillico), emoji, tag mancanti e doppi, file corrotti in `_corrotti/` (troncato, intestazione azzerata, vuoto, non-FLAC, WAV troncato, tag da 60 KB), `manifest.json`. |
| `scripts/qualifica-libreria.py misura URL` | Su un Lyrion **vero**: `rescan full` (o `--wipe`), tempo e curva di scansione, brani/s, latenza p50/p95 di ricerca e liste (anche in profondita'), file scartati. Rifiuta di produrre numeri se il server non risponde come Lyrion. |
| `tests/qualifica-corpus.py` | Verifica lo strumento stesso (struttura, tag, determinismo). |
| `tools/audio_verification.py`, `tests/prova-collaudo.py` | Misure audio e collaudo gia' presenti (vedi `docs/audio-verification.md`, `docs/collaudo.md`). |

## Libreria 50k+ con Lyrion vero

Prerequisiti: Lyrion 9.1.1 (la versione fissata da `package/lms/lms.hash`) su
una macchina con la musica su disco rappresentativo del dispositivo.

```sh
python3 scripts/qualifica-libreria.py corpus /musica/qual --files 50000
python3 scripts/qualifica-libreria.py misura http://DISPOSITIVO:9000 \
    --user sweetspot --password '...' --out misura-50k.json --nota "SSD USB, RPi 4"
```

Il corpus e' di file brevissimi (silenzio): misura **catalogo, tag e ricerca**,
non l'I/O di file audio reali. Per l'I/O usare una libreria vera.
Da leggere nel JSON insieme a `ambiente`.

**Eseguito (ambiente di sviluppo, NON il dispositivo).** Lyrion 9.1.1 vero con il
perl del rootfs dell'artifact CI x86_64 (run 38861841635, estratto in una
cartella temporanea), in `unshare -Urmpf` + chroot su WSL, solo loopback
(HTTP 19000), autenticazione attiva, corpus sintetico di 50.000 file validi + 6
corrotti: 50.003 brani, 4.168 album, 1.779 artisti, scansione da zero in 65,3 s
(≈765 brani/s); ricerca brano p50 160 ms, album 25 ms, artista 18 ms, liste
5-62 ms (3 ripetizioni: indicativo, non statistica). Scostamenti dichiarati:
la copia temporanea di `slimserver.pl` e' stata modificata per togliere
`setgroups` (negato nel user namespace); I/O su disco WSL (ext4),
CPU/disco dell'host, nessun cgroup, nessun DAC. Non rappresenta tempi su RPi/SSD
USB: quelli restano **da eseguire sul dispositivo**.

## Scansione incrementale e watch del filesystem

In Lyrion 9.1.1 `canAutoRescan` e' 0 sulla base che usiamo: non c'e' un
controllo continuo del filesystem. Da verificare su LMS reale, in quest'ordine:

1. aggiungere/rimuovere/rinominare file e lanciare `rescan` (veloce) e
   `rescan full`; confrontare `info total songs`;
2. controllare se la schedulazione di rescan di Lyrion e' sufficiente;
3. solo se serve, valutare un trigger esterno (inotify) **senza** poller pesanti.

**Stato: non eseguito.**

## Corpus e corruzione

Il generatore produce i casi; l'esito atteso e' che la scansione termini e che i
file corrotti compaiano in `lastscanfailure` o siano ignorati senza fermarla.
**Stato: corpus generabile e validato con `sox`; comportamento di Lyrion non
verificato.**

## Hardware, power-loss, lunga durata, plugin e account

Nulla di quanto segue e' stato eseguito: servono un DAC fisico, il
dispositivo, una presa comandata e account/abbonamenti.

| Prova | Prerequisiti | Procedura riproducibile |
|---|---|---|
| Qualita' audio su DAC (PCM, DSD/DoP, nativo) | DAC, loopback o analizzatore | `docs/audio-verification.md`, `tools/audio_verification.py`; riportare modello DAC, formato, esito. |
| Collaudo del dispositivo | Dispositivo acceso in rete | `tests/prova-collaudo.py` (`docs/collaudo.md`). |
| Power-loss | Presa comandata, chiavetta, brano in riproduzione/ripping/aggiornamento | Togliere corrente in ognuna delle fasi (ripping CD, salvataggio DSP, aggiornamento, scrittura `sweetspot.txt`); al riavvio verificare: avvio, nessun FLAC parziale, DSP al valore precedente valido, aggiornamento ripreso o annullato. |
| Lunga durata | 72 h di riproduzione continua | Registrare `sweetspot-diario`, memoria, temperatura, glitch (xrun) e dimensione log (`tests/quota-log.sh` copre solo la quota). |
| Plugin e account (Qobuz, Tidal, Spotify, radio) | Abbonamenti dell'utente | Verifica manuale dell'accesso e della riproduzione; non automatizzabile senza credenziali. |

Ogni esito va registrato con data, versione del firmware, hardware e operatore;
quelli non registrati restano "non verificati".
