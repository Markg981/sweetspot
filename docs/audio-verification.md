# Verifica riproducibile del percorso audio

La prima parte del traguardo 1 confronta i campioni PCM prodotti dal percorso
Lyrion → Squeezelite nel backend stdout del binario compilato. Verifica anche
la continuità fra due brani consecutivi della stessa frequenza e profondità.
Il report dichiara lo scope `software_stdout`: ALSA e il DAC richiedono prove
successive sulla relativa uscita digitale.

## Prova del sistema compilato

Su Linux della stessa architettura del pacchetto, con privilegi per il chroot:

```sh
sudo env SWEETSPOT_AUDIO_REPORT_DIR="$PWD/graphify-out/audio-evidence" \
  sh tests/prova-lyrion.sh sweetspot-x86_64-aggiornamento.tar
```

Occorrono Python 3, zstd, cpio e curl. La prova avvia un Lyrion isolato usando
la rootfs del pacchetto; le porte 9000 e 3483 devono essere libere. Non eseguirla
sull'istanza che stai usando per ascoltare musica.

Il driver genera due WAV locali per ciascuna delle sei combinazioni
44,1/48/96 kHz × 16/24 bit. Riproduce una playlist completa con volume 100,
controllo digitale del volume disattivato, ReplayGain e transizioni spenti;
verifica le preferenze tramite RPC. Non attiva il ricampionamento. Acquisisce
stdout PCM stereo a 32 bit little endian con limiti di tempo e spazio,
confrontando l'intera sequenza con i riferimenti normalizzati.

Ogni esecuzione usa una nuova cartella `run.*`, così una prova interrotta non
può lasciare visibile il verdetto riuscito di una precedente esecuzione.
Il report `run.*/report.json` identifica versione della rootfs, hash del binario,
formati, numero di frame e verdetto di ciascun caso. I riferimenti, le capture
e i log rimangono nella cartella di evidenza anche se una prova fallisce.
In CI gli artifact `verifica-audio-x86_64` e `verifica-audio-rpi` accompagnano
il job Lyrion; una verifica fallita blocca la pubblicazione delle release.

## Confronto di una capture esterna

Il comparatore funziona anche senza rootfs o Lyrion, usando solo Python 3:

```sh
python3 tools/audio_verification.py generate \
  --output graphify-out/pcm-reference --rate 48000 --bits 24

python3 tools/audio_verification.py compare \
  --reference primo.wav --reference secondo.wav \
  --capture uscita.raw --capture-format s32_le --capture-rate 48000 \
  --max-lead-frames 480000 --report graphify-out/comparison.json
```

Sostituisci i nomi dei riferimenti con i file generati e registra la sequenza
senza alterarne i campioni. Per una capture ALSA indica il contenitore realmente
usato: `s16_le`, `s24_3le`, `s24_le` o `s32_le`. `s24_le` contiene i 24 bit
significativi nei tre byte meno significativi di ogni parola di quattro byte;
il quarto byte è padding. La normalizzazione preserva tutti i bit significativi.
I riferimenti accettati sono WAV PCM interi stereo a 16/24/32 bit.

L'allineamento automatico ammette soltanto frame nulli prima della sequenza,
entro il limite dichiarato; dopo la sequenza ammette soltanto silenzio.
Non elimina pause fra brani o campioni diversi. Una sorgente completamente
silenziosa richiede un offset esplicito perché non consente un allineamento
univoco. `--offset-frames N` registra nel report una scelta manuale.

Exit code: 0 corrispondenza completa, 1 differenza nei campioni o nella sequenza,
2 input invalido. Il report conserva hash, confini dei brani e primo errore;
una capture troncata o un rate dichiarato diverso non costituiscono una prova
riuscita.

## Copertura ancora da completare

La prima esecuzione di sviluppo ha superato tutti i sei casi nella rootfs x86
dell'artifact della [compilazione 37961556191](https://github.com/Markg981/sweetspot/actions/runs/37961556191),
versione `dipendenze-lyrion-24-g3f03ade-dirty`, Lyrion 9.1.1 e Squeezelite SHA-256
`2a4c847aa51a2172947c4b378deeea53d263d275bd22aadf1bd112868b8badb8`.
Questo risultato valida lo sviluppo del harness sul binario disponibile;
la CI del nuovo branch deve ancora validare le proprie rootfs x86 e ARM.

Questo gate copre PCM locale, frequenza costante e due brani consecutivi nel
backend software. Restano aperti DSD nativo/DoP, cambi di frequenza e profondità,
ALSA, USB/I2S/S/PDIF reali, hotplug, rete/NAS, carico prolungato e la matrice
computer/DAC/firmware per release. Non misura jitter del clock, rumore elettrico
USB o fedeltà dell'uscita analogica. Il traguardo 1 rimane parzialmente coperto
finché queste prove non hanno evidenza riproducibile.
