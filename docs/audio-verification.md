# Verifica riproducibile del percorso audio

La prima parte del traguardo 1 confronta i campioni PCM e il payload DoP prodotti
dal percorso Lyrion → Squeezelite nel backend stdout del binario compilato.
Verifica anche la continuità fra due brani consecutivi della stessa frequenza,
incluse le transizioni fra profondità PCM diverse.
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

Il driver genera due WAV locali per ciascuno dei 14 casi:

| Tipo di prova | Frequenza | Profondità/carrier | Casi |
| --- | --- | --- | --- |
| PCM omogeneo | 44,1/48/96 kHz | 16→16 e 24→24 bit | 6 |
| PCM misto | 44,1/48/96 kHz | 16→24 e 24→16 bit | 6 |
| WAV contenente DoP | 176,4/352,8 kHz | PCM24, payload DSD64/128 | 2 |

Riproduce una playlist completa con volume 100,
controllo digitale del volume disattivato, ReplayGain e transizioni spenti;
verifica le preferenze tramite RPC. Non attiva il ricampionamento. Acquisisce
stdout PCM stereo a 32 bit little endian con limiti di tempo e spazio,
confrontando l'intera sequenza con i riferimenti normalizzati.

Ogni esecuzione usa una nuova cartella `run.*`, così una prova interrotta non
può lasciare visibile il verdetto riuscito di una precedente esecuzione.
Il report `run.*/report.json` identifica versione della rootfs, hash del binario,
ID univoco, tipo, profondità dei due riferimenti, numero di frame e verdetto di
ciascun caso. Casi mancanti, duplicati o falliti impediscono un esito positivo.
Un errore nella capture o nella pulizia invalida il caso anche quando il
confronto dei campioni era riuscito. I riferimenti, le capture e i log rimangono
nella cartella di evidenza anche se una prova fallisce.
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

## Confronto DoP

```sh
python3 tools/audio_verification.py generate-dop \
  --output graphify-out/dop-reference --rate 176400

python3 tools/audio_verification.py compare-dop \
  --reference primo-dop.wav --reference secondo-dop.wav \
  --capture uscita-dop.raw --capture-format s32_le --capture-rate 176400 \
  --max-lead-frames 1764000 --report graphify-out/dop-comparison.json
```

I file generati contengono payload diagnostici distinti fra canali e tracce,
destinati alla capture digitale; non sono brani da ascoltare. Le fixture sono
WAV24 a 176,4 o 352,8 kHz. Il driver usa `-D 0:dop` e conserva lo stdout a
32 bit, senza passare attraverso un DAC.

Il confronto DoP controlla tutti i 16 bit di payload per ogni canale e frame,
ogni marker `0x05`/`0xFA`, l'alternanza continua, l'uguaglianza dei marker L/R
e il padding nullo del contenitore S32. Squeezelite riscrive i marker: la fase
iniziale può essere diversa da quella del WAV. Una fase legale differente
preserva il payload; un marker illegale o un salto dell'alternanza falliscono.
Questa regola è specifica del DoP: il confronto PCM rimane esatto su tutti i
bit significativi.

Ai bordi sono ammessi startup PCM nullo e silenzio DoP con payload `0x6969`
su entrambi i canali, entro il limite iniziale dichiarato. Dopo il primo frame
DoP i marker devono continuare ad alternarsi anche nel silenzio. Pause, frame
duplicati o persi dentro la sequenza falliscono, senza riallineamenti interni.
Il report distingue `payload_match`, `markers_match` e `sequence_match`.
Il guardrail che impedisce di sovrascrivere riferimenti o capture con il report
vale anche per `compare-dop`.

La prova è classificata `dop_pcm_passthrough`: copre WAV contenenti DoP nel
decoder PCM e nel backend stdout. La conversione DSF/DFF→DoP e il trasporto
DSD nativo richiedono protocolli aggiuntivi. Per il comportamento dei marker:
[Squeezelite stdout](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/output_stdout.c#L66),
[framing DoP](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/dop.c#L64)
e [DoP Open Standard](https://dsd-guide.com/dop-open-standard).

## Evidenza di sviluppo

La prima esecuzione di sviluppo ha superato tutti i sei casi nella rootfs x86
dell'artifact della [compilazione 37961556191](https://github.com/Markg981/sweetspot/actions/runs/37961556191),
versione `dipendenze-lyrion-24-g3f03ade-dirty`, Lyrion 9.1.1 e Squeezelite SHA-256
`2a4c847aa51a2172947c4b378deeea53d263d275bd22aadf1bd112868b8badb8`.
La matrice estesa ha superato tutti i 14 casi nella rootfs x86 dell'artifact
della [compilazione 37977755339](https://github.com/Markg981/sweetspot/actions/runs/37977755339),
versione `dipendenze-lyrion-27-gf1dafae-dirty`, con Lyrion 9.1.1 e lo stesso
SHA-256 di Squeezelite. Il report locale è
`graphify-out/audio-evidence/run.STLgVR/report.json`, scope `software_stdout`.
La suite locale ha superato 405 controlli, inclusi 55 test del comparatore e
31 del driver. La CI del branch deve validare le proprie rootfs x86 e ARM;
la compilazione collegata identifica l'artifact usato, non certifica il nuovo
commit con la matrice estesa.

Una prima esecuzione della matrice estesa aveva invalidato due casi per
timeout di chiusura della capture su WSL con output nel filesystem Windows;
non aveva ottenuto un verdetto sui loro campioni. La successiva esecuzione
completa è riuscita. Un errore simile richiede un nuovo collaudo completo,
conservando anche il report fallito; non si riutilizzano i casi riusciti di
esecuzioni diverse.

## Copertura ancora da completare

Questo gate copre PCM locale, profondità PCM miste e payload DoP, frequenza
costante e due brani consecutivi nel backend software. Restano aperti DSD
nativo, DSF/DFF→DoP, cambi di frequenza,
ALSA, USB/I2S/S/PDIF reali, hotplug, rete/NAS, carico prolungato e la matrice
computer/DAC/firmware per release. Non misura jitter del clock, rumore elettrico
USB o fedeltà dell'uscita analogica. Il traguardo 1 rimane parzialmente coperto
finché queste prove non hanno evidenza riproducibile.
