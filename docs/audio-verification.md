# Verifica riproducibile del percorso audio

La prima parte del traguardo 1 confronta i campioni PCM e il payload DoP prodotti
dal percorso Lyrion → Squeezelite nel backend stdout del binario compilato.
Verifica anche la continuità fra due brani consecutivi della stessa frequenza,
incluse le transizioni fra profondità PCM diverse, e le sei transizioni PCM
fra 44,1, 48 e 96 kHz in entrambe le direzioni.
Il report dichiara lo scope `software_stdout`. I 18 casi a frequenza costante,
ripetuti sul percorso ALSA del kernel con la scheda virtuale snd-aloop, hanno
scope `alsa_loopback` (vedi [Percorso ALSA con snd-aloop](#percorso-alsa-con-snd-aloop)).
Il DAC fisico richiede una prova successiva sulla sua uscita digitale.

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

Il driver genera due sorgenti locali per ciascuno dei 24 casi e i relativi
riferimenti WAV. Nei casi DSF/DFF i WAV sono soltanto l'oracle del confronto:
la playlist contiene i due file DSD originali.

| Tipo di prova | Frequenza | Profondità/carrier | Casi |
| --- | --- | --- | --- |
| PCM omogeneo | 44,1/48/96 kHz | 16→16 e 24→24 bit | 6 |
| PCM misto | 44,1/48/96 kHz | 16→24 e 24→16 bit | 6 |
| WAV contenente DoP | 176,4/352,8 kHz | PCM24, payload DSD64/128 | 2 |
| DSF→DoP | carrier 176,4/352,8 kHz | DSD64/128 stereo non compresso | 2 |
| DFF→DoP | carrier 176,4/352,8 kHz | DSD64/128 stereo non compresso | 2 |
| PCM con cambio frequenza | 44,1↔48, 44,1↔96, 48↔96 kHz | 24→24 bit, due brani | 6 |

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

## Percorso ALSA con snd-aloop

La prova ripete i 18 casi passando dal driver ALSA del kernel invece che
dallo stdout, sulla scheda virtuale `hw:Loopback` di snd-aloop. Aggiunge due
casi di DSD convertito in PCM verso un DAC finto che accetta al massimo
192 kHz (snd-aloop non va oltre, e Squeezelite dichiara solo 176,4 kHz):
`dsf-2822400-pcm` (DSD64, una decimazione per 2) e `dff-5644800-pcm` (DSD128,
due). Le sorgenti sono tracce DSF/DFF generate con un tono per canale
(1008 e 2016 Hz in DSD64) più un tono ultrasonico a 117,6 kHz che, se il filtro
non lo eliminasse, ripiegherebbe a 58,8 kHz. Squeezelite parte con
`SWEETSPOT_DSD_MARGINE_DB=-6` (non il predefinito, per provare che la chiave
arrivi). La prova richiede: nel registro la conversione, la decimazione attesa
e il margine; il PCM a 176,4 kHz sul `hw:Loopback`; il tono entro 0,5 dB del
livello atteso con il margine; rapporto segnale/rumore in banda di almeno 60 dB;
nessun picco a 58,8 kHz (60 dB sotto il tono e non sopra il rumore); il tono
dell'altro canale assente; nessun clipping.

**Nel kernel di Sweetspot (CI x86).** Il kernel x86 dell'immagine include
snd-aloop come modulo, che non si carica da solo. `tests/prova-alsa-qemu.sh`
avvia una copia dell'immagine in QEMU (KVM se disponibile). Nella copia
attiva SSH con una password casuale, disattiva la modalità ascolto e indica un
DAC inesistente, così il player di Sweetspot non apre la scheda. Carica poi
snd-aloop nel sistema avviato e lancia `tests/prova-audio.py --ssh-port`:
fixture, Squeezelite, `aplay` e `/proc/asound` sono quelli del sistema
avviato, il server è il Lyrion dell'immagine.

```sh
sudo sh tests/prova-alsa-qemu.sh sweetspot.img.xz "$(tar -xOf sweetspot-x86_64-aggiornamento.tar versione)"
```

Servono `qemu-system-x86`, `mtools`, `xz-utils`, `sshpass`, `curl` e Python 3.
Le porte 9000 e 2222 di `127.0.0.1` devono essere libere. Report e capture
finiscono in `alsa-qemu.*` accanto alle cartelle `run.*`, dentro l'artifact
`verifica-audio-x86_64`. Una prova fallita blocca la release. I kernel dei
runner GitHub non hanno snd-aloop, e il kernel del Raspberry Pi non si avvia in
QEMU: su ARM resta la sola prova stdout.

**Sull'host con il rootfs estratto.** Se l'host ha la scheda (`sudo modprobe
snd-aloop id=Loopback pcm_substreams=1`), anche `tests/prova-lyrion.sh` ripete
i casi su ALSA in chroot, con il kernel dell'host e report in
`run.*/alsa-loopback/`. `SWEETSPOT_AUDIO_ALSA` vale `auto` (predefinito: prova
solo se la scheda c'è), `richiesta` (fallisce se manca) o `no`.

Squeezelite suona su `hw:CARD=Loopback,DEV=0` con gli stessi parametri del
player senza correzione: dispositivo `hw:`, `-a 400:4::1` (buffer di 400 ms in
quattro periodi, formato scelto dal motore, mmap), ricampionamento spento.
`-r F-F` limita le frequenze a quella del caso, così il dispositivo si apre
già alla frequenza giusta e manda silenzio finché non parte la playlist.

Prima di agganciare la capture il driver legge `hw_params` e `status` del
substream di riproduzione in `/proc/asound`. Richiede `state: RUNNING`,
accesso `MMAP_INTERLEAVED`, due canali, la frequenza del caso e un formato
noto (`S16_LE`, `S24_3LE`, `S24_LE`, `S32_LE`). Se un substream della scheda
è già aperto da un altro processo, il caso fallisce. La capture usa `aplay -C`
della rootfs su `hw:CARD=Loopback,DEV=1`, con lo stesso formato e la stessa
frequenza, e una durata esatta in secondi. snd-aloop scandisce i due lati con
il proprio timer, quindi non serve il ritmo di lettura dello stdout. La
capture deve terminare con stato 0 e il numero esatto di byte attesi.

Il confronto è lo stesso del backend stdout: tutti i bit significativi per il
PCM, payload e marker per il DoP, nel contenitore negoziato. Il caso fallisce
anche se il registro di Squeezelite (`-d output=info`) non riporta l'apertura
di `hw:CARD=Loopback,DEV=0`, se contiene `XRUN` o `XRUN recover failed`, o se
`aplay` segnala un overrun in capture. Il report conserva `hw_params`, i
comandi del player e della capture, il registro con il suo SHA-256 e lo
stderr della capture.

Il passaggio da PCM a DoP fa riaprire il dispositivo con gli stessi parametri:
snd-aloop riempie di zeri la capture durante la riapertura, prima del primo
brano, e il confronto lo ammette solo come silenzio iniziale.

Questa prova copre driver, contenitore, mmap e periodi del percorso ALSA, ma
non un clock USB/I2S/S/PDIF, la temporizzazione di un DAC reale o
l'apertura con il formato preferito da un DAC specifico.

### Matrice estesa su ALSA

Oltre ai casi a frequenza costante, la prova ALSA verifica:

- **FLAC e ALAC.** `generate_codec_fixtures` (in `tools/audio_verification.py`)
  produce i sorgenti `flac` e `m4a` dagli stessi WAV di riferimento con encoder
  minimi (frame FLAC verbatim con MD5, pacchetti ALAC non compressi): il decoder
  di Squeezelite percorre il parser vero e l'uscita deve essere identica al WAV,
  campione per campione. Casi `flac-*` e `alac-*` a 44,1/16, 48/24, 96/24 e
  192/24. Gli encoder non comprimono, quindi non provano il predittore né il
  coder di Rice dei decoder: lo fa la matrice del segnale con ffmpeg.
  Un pacchetto ALAC (4096 frame, circa 24,6 KB a 24 bit) supera i 16 KB dopo
  i quali Squeezelite chiama il decoder ffmpeg: se lo stream si svuotava a metà
  pacchetto, ffmpeg lo scartava come corrotto (`Packet corrupt` nel log) e
  `alac-192000-24` falliva ogni tanto. La
  [patch 0008](../patches/squeezelite/0008-alac-whole-packet-before-decode.patch)
  fa partire il decoder ALAC solo con 128 KB nel buffer; la verifica il
  [test sull'estratto di ffmpeg.c](../tests/squeezelite-alac-min-read.py).
- **Cambi di frequenza.** Le sei coppie fra 44,1, 48 e 96 kHz: il primo brano
  dura 4 s, la capture resta alla sua frequenza e se ne confronta l'ultimo
  secondo campione per campione; poi ammette solo silenzio, al massimo 20 ms di
  transitorio del ricampionatore e il tono a 1 kHz del secondo brano. La
  riapertura è senza pausa (`rate delay` 0), quindi nessun campione del primo
  brano può mancare né ripetersi, e una rilettura del ring fallisce.
- **Da DoP a PCM.** `dsf-2822400-dop-pcm-44100` e `dff-2822400-dop-pcm-44100`:
  il primo brano è DSF/DFF suonato come DoP a 176,4 kHz, il secondo un tono PCM
  a 44,1 kHz. La coda DoP deve essere identica al riferimento e con i marcatori
  0x05/0xFA alternati in entrambi i canali; il tono che segue deve essere pulito.
  Il verso PCM → DoP non si verifica con questo schema: la capture resta alla
  frequenza del primo brano e il DoP, ricampionato dal plug, perderebbe i bit.
  Resta provato dal solo avvio con DoP (casi `dsf-*-dop` e `dff-*-dop`).
- **Hotplug.** Non coperto: il kernel rifiuta di scaricare `snd-aloop` con il
  flusso aperto, e non esiste un modo di "staccare" la scheda senza toglierla a
  tutto il sistema. Resta da provare su hardware (scollegare il DAC USB durante
  l'ascolto e verificare il recupero).

Il tempo in più in CI è di pochi minuti: i casi `flac-*`/`alac-*` durano come
quelli PCM (circa 15 s) e ogni transizione circa 25 s.

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

## Cambi di frequenza PCM

Le sei prove aggiuntive riproducono WAV24 a frequenze diverse nella stessa
playlist. Squeezelite annuncia al server le frequenze 44.100, 48.000 e 96.000 Hz
con `-r 44100,48000,96000:0`; il ricampionamento rimane spento. La capture stdout
non ha header né marcatori di frequenza. Il driver conserva quindi anche gli
annunci `track start sample rate` al
[confine delle tracce nel motore](https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/output.c#L153)
e richiede l'esatta sequenza dei
due rate attesi, senza annunci mancanti, aggiuntivi, duplicati o fuori ordine.
Il report conserva percorso e hash del log.

Il confronto concatena tutti i frame nativi delle due sorgenti, normalizzati
nei bit significativi, senza ricampionare o riallineare il secondo brano.
Perdite, duplicazioni o pause interne falliscono anche al cambio di frequenza.
I confini nel report indicano gli indici dei frame e i rate prima e dopo il
cambio; il primo campione errato identifica anche traccia e frame di origine.

Il consumer software legge stdout a un ritmo fisso di 44.100 frame al secondo,
registrato come `pacing_rate`: questo valore non è la frequenza delle tracce
né una misura del clock del DAC. Il limite di capture deriva dalla somma dei
frame dei riferimenti più dieci secondi di silenzio iniziale e dieci finali
al ritmo del consumer. Anche il timeout deriva da questo budget, con un
margine finito per l'arresto; non assume che i due brani abbiano lo stesso rate.
Il primo frame non nullo delle fixture diagnostiche determina il silenzio
iniziale effettivo: il driver termina dopo questo bordo, tutti i frame nativi
e il bordo finale ammesso, sempre entro il limite massimo. Conserva ogni byte
letto, senza tagliare silenzi interni o usare il budget iniziale inutilizzato
per allungare quello finale.

Il comparatore dedicato si può usare separatamente:

```sh
python3 tools/audio_verification.py compare-pcm-sequence \
  --reference primo-44100.wav --reference secondo-48000.wav \
  --capture uscita.raw --capture-format s32_le \
  --observed-rate 44100 --observed-rate 48000 --pacing-rate 44100 \
  --max-lead-frames 441000 --max-trailing-frames 441000 \
  --report graphify-out/rate-comparison.json
```

Sostituisci i riferimenti con i due WAV effettivi e ricava i valori
`--observed-rate` dal log dell'esecuzione. La CLI confronta i valori forniti
con gli header: da sola non acquisisce né autentica il log. Il driver completo
lega invece il verdetto al log conservato della singola prova. Il report
riporta la frequenza della capture come `null` e il pacing separatamente.
Il comando `compare` precedente continua a richiedere una frequenza unica.
Il nuovo comando limita entrambi i bordi nulli, anche usando un offset
esplicito; dentro la sequenza non tollera silenzio aggiunto.

Queste prove riguardano il cambio di rate annunciato dal motore e i frame
nel backend software. L'apertura ALSA e il comportamento del DAC al cambio
di frequenza richiedono un collaudo sulla relativa uscita reale.

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
errore. La [CI della PR #16](https://github.com/Markg981/sweetspot/actions/runs/38056065758),
sul commit `b423231`, ha poi superato test, compilazioni e prove Lyrion su
x86 e ARM e pubblicato entrambi gli artifact `verifica-audio-*`.
Quella CI copre i 18 casi precedenti; la matrice da 24 richiede una nuova prova.
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

## Matrice di verifica del segnale

`tools/matrice-segnale.py` esegue la matrice dichiarata in
`tools/matrice-segnale.json` sopra i confrontatori di
`tools/audio_verification.py` (nessun confronto duplicato). Casi: FLAC, ALAC e
WAV a 16/24/32 bit da 44,1 a 384 kHz (ALAC e FLAC a 32 bit non sono
nella matrice: l'encoder di ffmpeg non li garantisce lossless), WAV DoP e
DSF/DFF da DSD64 a DSD256 (portante DoP 176,4/352,8/705,6 kHz), profondità miste
16/24/32 in coda, cambi PCM↔DSD e DSD64→DSD256, cambio 384→44,1 kHz, hotplug del
DAC (PCM e DSD) e carico prolungato.

Esito per caso:

- **PASS**: la cattura digitale è identica bit a bit alla sorgente decodificata
  (per FLAC/ALAC il riferimento è la decodifica riletta e verificata uguale al
  WAV d'origine; per DSD il payload DoP). L'allineamento ammette solo silenzio
  iniziale; niente ricerca di marcatori interni.
- **FAIL**: cattura presente ma con campioni diversi, troncata o non valida
  (il report riporta il primo scarto).
- **NON ESEGUITO**: con il motivo, per esempio cattura o evidenza assente,
  ffmpeg mancante per FLAC/ALAC. Non è mai un PASS.

Il display del DAC e l'ascolto non dimostrano l'identità dei campioni e non
sono accettati come evidenza.

### Procedura hardware

1. Su un computer di sviluppo: `python3 tools/matrice-segnale.py prepara
   --output prova` (richiede ffmpeg per FLAC/ALAC; `--filtro` seleziona un caso
   o una categoria: `pcm`, `dsd`, `dop`, `profondita-miste`, `cambi-pcm-dsd`,
   `hotplug`, `carico`; `--frames` accorcia i brani). Per il carico il default
   è un'ora e la generazione è lunga.
2. Copiare `prova/sorgenti` sul NAS o sul player e mettere in coda su Lyrion i
   file `sorgenti/<tipo>-<formato>-<freq>-<bit>/` (due brani per segmento;
   `manifesto.json` elenca le sorgenti di ogni caso nell'ordine).
3. Collegare l'uscita digitale del player al registratore: loopback S/PDIF
   (ingresso digitale di una scheda di acquisizione con clock indipendente
   dall'uscita) oppure USB con un secondo DAC/analizzatore che catturi lo stream
   così com'è; volume digitale, ReplayGain e ricampionamento spenti. In test si
   usa `snd-aloop` (`--ambito alsa_loopback`).
4. Catturare un file grezzo per segmento, senza gain né conversioni:
   PCM nel formato nativo (`s16_le`, `s24_3le`, `s32_le`), DoP in `s24_3le`.
   Nome: `<id>.raw` per un segmento, `<id>.<n>.raw` (n da 1) per più segmenti.
   Un segmento per ogni cambio di frequenza o formato: ciascuno è confrontato
   col proprio riferimento, la continuità attraverso il cambio di clock non è
   misurata.
5. Hotplug: catturare il brano prima e dopo lo scollegamento/ricollegamento del
   DAC (segmenti 1 e 2) e salvare in `<id>.eventi.txt` l'estratto di
   `dmesg`/registro con l'orario dell'evento. Carico prolungato: stessa cosa
   con il carico (CPU, rete) attivo, in `carico-prolungato.eventi.txt` il
   carico applicato.
6. `python3 tools/matrice-segnale.py verifica --dir prova --catture catture
   --ambito digitale_spdif --report esito.json [--completa]`. L'ambito
   (`digitale_spdif`, `digitale_usb`, `digitale_i2s`, `alsa_loopback`,
   `software_stdout`) va dichiarato onestamente: va nel report. Con
   `--completa` l'uscita è 1 anche se resta un NON ESEGUITO.

I test della matrice (`python3 tests/audio-verification.py`) usano catture
sintetiche e non sostituiscono la prova hardware. La generazione di FLAC/ALAC
non è coperta dai test se ffmpeg non è installato.

## Copertura ancora da completare

Questo gate copre PCM locale, profondità PCM miste, WAV DoP e DSF/DFF→DoP,
frequenza costante e due brani consecutivi nel backend software e sul
percorso ALSA di snd-aloop, sorgenti FLAC e ALAC (16/24 bit, 44,1-192 kHz),
sei cambi fra 44,1/48/96 kHz sia nel backend software sia su ALSA e il
ritorno da DoP a PCM su ALSA. La [matrice del segnale](#matrice-di-verifica-del-segnale) dichiara
ora anche formati, frequenze fino a 384 kHz, DSD256, cambi PCM/DSD, hotplug e
carico, ma ogni caso resta NON ESEGUITO finché non c'è una cattura digitale
reale. Restano aperti DSD nativo, DFF compressi DST, mono/multicanale,
seek, passaggio da PCM a DoP in sequenza, cambi di frequenza sui DAC, USB/I2S/S/PDIF
reali (a partire da N550JV + R26 con registro pubblicato per release),
hotplug, rete/NAS, carico prolungato e la matrice computer/DAC/firmware per
release. Non misura jitter del clock, rumore elettrico
USB o fedeltà dell'uscita analogica. Il traguardo 1 rimane parzialmente coperto
finché queste prove non hanno evidenza riproducibile.
