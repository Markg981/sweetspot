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

Su WSL è preferibile acquisire su un filesystem Linux nativo, impostando
`SWEETSPOT_AUDIO_REPORT_DIR` per esempio sotto `/tmp`, e copiare su Windows
la cartella completa dopo il termine della prova. Una scrittura o chiusura
bloccata sul filesystem Windows può invalidare la capture senza indicare un
difetto nei campioni audio.

Il driver genera due sorgenti locali per ciascuno dei 18 casi e i relativi
riferimenti WAV. Nei casi DSF/DFF i WAV sono soltanto l'oracle del confronto:
la playlist contiene i due file DSD originali.

| Tipo di prova | Frequenza | Profondità/carrier | Casi |
| --- | --- | --- | --- |
| PCM omogeneo | 44,1/48/96 kHz | 16→16 e 24→24 bit | 6 |
| PCM misto | 44,1/48/96 kHz | 16→24 e 24→16 bit | 6 |
| WAV contenente DoP | 176,4/352,8 kHz | PCM24, payload DSD64/128 | 2 |
| DSF→DoP | carrier 176,4/352,8 kHz | DSD64/128 stereo non compresso | 2 |
| DFF→DoP | carrier 176,4/352,8 kHz | DSD64/128 stereo non compresso | 2 |

Riproduce una playlist completa con volume 100,
controllo digitale del volume disattivato, ReplayGain e transizioni spenti;
verifica le preferenze tramite RPC. Non attiva il ricampionamento. Acquisisce
stdout stereo a 32 bit little endian con limiti di tempo e spazio,
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

La prova dei WAV è classificata `dop_pcm_passthrough`: copre WAV contenenti
DoP nel decoder PCM e nel backend stdout. I casi DSF/DFF descritti sotto
attraversano invece il decoder DSD; il trasporto DSD nativo richiede altre
prove. Per il comportamento dei marker:
[Squeezelite stdout](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/output_stdout.c#L66),
[framing DoP](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/dop.c#L64)
e [DoP Open Standard](https://dsd-guide.com/dop-open-standard).

## Sorgenti DSF e DFF

```sh
python3 tools/audio_verification.py generate-dsd \
  --container dsf --output graphify-out/dsf-reference --rate 176400
```

`--container dff` genera l'altro formato. L'output identifica le due sorgenti
e i due riferimenti WAV DoP; questi ultimi si confrontano con `compare-dop`.
Anche queste fixture contengono dati diagnostici per capture digitale e non
brani da ascoltare.

Il driver riproduce due DSF o due DFF consecutivi a DSD64 (2.822.400 bit/s per
canale) oppure DSD128 (5.644.800 bit/s), con `-D 0:dop` e carrier a 176,4 o
352,8 kHz. Le sorgenti sono stereo non compresse. Il report usa
`kind: dsd_to_dop` e conserva formato, bitrate e hash delle sorgenti separati
dai WAV di riferimento. I log del decoder e dello stream accompagnano la
capture: il gate richiede le aperture DSD, gli header del formato originale
e l'annuncio del carrier DoP atteso per entrambe le tracce. Un fallback a
PCM o un'evidenza del decoder incompleta invalida il caso.

Il DSF usa blocchi di 4096 byte per canale e bit LSB-first; il DFF usa byte
stereo interleaved e bit MSB-first. Le fixture DSF durano un secondo e hanno
l'ultimo blocco parziale: il padding del container non appartiene al payload
audio atteso. Il confronto conserva il conteggio esatto dei frame e verifica
il confine fra brani senza rimuovere padding emesso dal decoder o
riallinearsi. Il test dell'encoder controlla separatamente header, ordine dei
bit/byte e dimensioni contro vettori noti.

Riferimenti del formato: [Sony DSF v1.01](https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf)
e [Philips DSDIFF 1.5](https://www.sonicstudio.com/pdf/dsd/DSDIFF_1.5_Spec.pdf).
Il [decoder Squeezelite](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/dsd.c#L495)
limita il payload DSF al sample count; la prova reale verifica anche questo
comportamento alla transizione fra tracce. Il
[passthrough Lyrion](https://github.com/LMS-Community/slimserver/blob/9.1.1/convert.conf#L389)
mantiene DSF/DFF nel formato originale quando il player annuncia il decoder DSD.

### Correzione del parser DFF

La prima prova delle sorgenti originali ha superato i 14 casi precedenti e i
due DSF, ma ha fallito entrambi i DFF. Il decoder del pin Squeezelite
`72e1fd8` saltava `lunghezza + 12` byte per un chunk DSDIFF: con una lunghezza
dispari lasciava il byte di padding davanti all'header successivo. Il chunk
`CMPR` valido da 19 byte delle fixture riproduce il guasto prima dei dati audio.
La [specifica DSDIFF 1.5, sezione 2.3](https://www.sonicstudio.com/pdf/dsd/DSDIFF_1.5_Spec.pdf)
richiede quel padding e lo esclude dalla lunghezza dichiarata.

La [patch del motore](../patches/squeezelite/0001-dsdiff-even-chunk-padding.patch)
include il byte di padding nel salto dei chunk DSDIFF. Entrambe le
configurazioni Buildroot la applicano tramite `BR2_GLOBAL_PATCH_DIR`.
Il [test sul parser C](../tests/squeezelite-dff-padding.py) applica la patch
reale a un estratto invariato del sorgente fissato, poi lo compila e controlla
chunk pari e dispari, contenitori annidati, ricezione frammentata e DSF.
Richiede Python 3, Git e un compilatore C (`cc`, oppure `CC=gcc`);
`--unpatched` è il controllo negativo e deve fallire sui casi DFF dispari.
Se si riusa una cartella di compilazione Buildroot già popolata, occorre
`make -C buildroot O="$PWD/output" squeezelite-dirclean` prima di rieseguire
`scripts/build.sh` con la configurazione della propria piattaforma,
per riapplicare la patch. La CI costruisce in una cartella nuova.

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
31 del driver. La [CI della PR #14](https://github.com/Markg981/sweetspot/actions/runs/38026669051)
ha poi superato test, compilazioni e prove Lyrion su x86 e ARM, sul commit
`3ae1796`. Quella CI riguarda i 14 casi precedenti; la nuova estensione
DSF/DFF è stata validata nella CI della PR #15 descritta sotto.

La nuova matrice ha prima ottenuto 16/18 sulla stessa rootfs: il report
`graphify-out/dsd-source-evidence-native/run.4h9HVm/report.json` conserva
entrambi i guasti DFF. Dopo la patch, un'unica esecuzione completa ha
superato 18/18 con Lyrion 9.1.1 e il Squeezelite del pin ricompilato in WSL
con `-DDSD -DNO_FAAD -DNO_MAD -DNO_MPG123` e suffisso di sviluppo.
Il runtime è `dipendenze-lyrion-27-gf1dafae-dff-padding-dev`, Squeezelite SHA-256
`1878b3e6c5696c3c4a3fae6621f9e63310b94f426a886945f9c2b8efbfa94305`;
report `graphify-out/dff-fixed-evidence-native/run.ieQJvb/report.json`.
I quattro casi DSF/DFF hanno confrontato tutti i frame delle due tracce,
con header e carrier attesi e senza fallback PCM. Questa ricompilazione
locale sostituisce soltanto il player in un pacchetto privato di prova:
non certifica gli altri codec né le immagini Buildroot complete.
La [CI della PR #15](https://github.com/Markg981/sweetspot/actions/runs/38051082986),
sul commit `8ab322b`, ha poi superato test, entrambe le compilazioni Buildroot
e tutti i 18 casi nelle immagini complete x86 e ARM. I log conservano gli
esiti di ogni caso; l'upload dei report aveva invece una destinazione errata
e non ha prodotto gli artifact di evidenza. Il workflow passa ora la cartella
esplicitamente al comando privilegiato e considera un archivio assente un
errore: la pubblicazione della correzione richiede una nuova esecuzione CI.
La suite Linux finale ha superato 429 controlli, inclusi 65 test del
comparatore/fixture, 35 del driver e 10 del parser C, senza test saltati.

Una prima esecuzione della matrice estesa aveva invalidato due casi per
timeout di chiusura della capture su WSL con output nel filesystem Windows;
non aveva ottenuto un verdetto sui loro campioni. La successiva esecuzione
completa è riuscita. Un errore simile richiede un nuovo collaudo completo,
conservando anche il report fallito; non si riutilizzano i casi riusciti di
esecuzioni diverse.

## Diagnostica del percorso ALSA

Il riquadro **Uscita audio** e la pagina **Stato** leggono il PCM playback
scelto dal player e indicano device e substream. Non cercano un altro PCM
della stessa scheda quando l'uscita selezionata è chiusa. Se `sub0` è chiuso
e un solo altro substream è aperto, osservano quest'ultimo; più substream
aperti danno un risultato ambiguo, senza attribuire il formato al player.

`RUNNING` indica l'uscita in corso; `DRAINING` lo svuotamento del buffer.
`PREPARED`, `PAUSED`, `OPEN` e `SETUP` indicano un'uscita aperta ma senza
riproduzione confermata. `XRUN`, `SUSPENDED` e `DISCONNECTED` richiedono
attenzione. Parametri malformati, stato sconosciuto o file non leggibili
non producono un verdetto positivo. Il formato eventualmente osservato
rimane distinto dal verdetto sullo stato.

I dati provengono dai file `hw_params` e `status` dello stesso substream,
come documentato dal [kernel ALSA](https://www.kernel.org/doc/html/latest/sound/designs/procfile.html).
Sono osservazioni del percorso aperto: non provano la corrispondenza dei
campioni, la continuità fra brani o la qualità analogica del DAC.

Gli eventi `XRUN` e i messaggi `XRUN recover failed` sono conteggiati
separatamente. I conteggi riguardano tutto il registro Squeezelite ancora
disponibile, anche di avvii precedenti; un registro assente è segnalato come
non disponibile. Zero eventi registrati non certifica l'assenza di interruzioni.
Le regressioni con `/proc` simulato verificano la diagnostica, mentre il
collaudo ALSA su dispositivi reali rimane da completare.

## Copertura ancora da completare

Questo gate copre PCM locale, profondità PCM miste, WAV DoP e DSF/DFF→DoP,
frequenza costante e due brani consecutivi nel backend software. Restano
aperti DSD nativo, DFF compressi DST, mono/multicanale, seek, cambi di frequenza,
ALSA, USB/I2S/S/PDIF reali, hotplug, rete/NAS, carico prolungato e la matrice
computer/DAC/firmware per release. Non misura jitter del clock, rumore elettrico
USB o fedeltà dell'uscita analogica. Il traguardo 1 rimane parzialmente coperto
finché queste prove non hanno evidenza riproducibile.
