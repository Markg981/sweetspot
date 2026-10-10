# Sweetspot

Player e server di musica liquida con uscita ALSA diretta, open source (GPLv3), pensato
come alternativa a Daphile: stesso motore (Lyrion Music Server con i suoi
plugin, Squeezelite come player), con un sistema costruito per far suonare il
DAC nel modo più pulito possibile. Gira su un PC (da una chiavetta USB o, dopo
l'installazione, dal disco interno) o su un Raspberry Pi 4 o 5 (dalla scheda
SD), copia tutto in RAM e si usa dal browser del telefono o del computer.

## Cosa fa all'accensione

1. GRUB parte dalla chiavetta o dal disco interno (BIOS o UEFI a 64/32 bit),
   sceglie quale delle due copie del sistema avviare (vedi *Aggiornamenti*) e
   carica kernel e sistema in RAM.
2. Legge impostazioni, libreria e plugin salvati sulla chiavetta.
3. Riconosce il computer e calcola i parametri di avvio: core dedicati
   all'audio (anche sulle CPU ibride Intel), Hyper-Threading spento, CPU limitata
   allo stato C1. Al primo avvio li scrive sulla chiavetta e riavvia **una sola
   volta**.
4. Fissa la frequenza della CPU, spegne Turbo, Bluetooth, Wi-Fi non usato e
   risparmio energetico USB e di rete.
5. Trova i dischi con la musica (interni e USB: NTFS, exFAT, ext4, FAT, HFS+) e
   li monta **in sola lettura**; dai dischi di Windows e Linux prende solo le
   cartelle Musica degli utenti. Monta le cartelle di rete (NAS, PC) indicate.
6. Avvia **Lyrion Music Server** (utente proprio, priorità bassa, core di
   sistema) con l'interfaccia **Material** e il plugin di Sweetspot.
7. Attende il DAC e avvia **Squeezelite**:
   - uscita diretta `hw:` su ALSA, senza plug, dmix o ricampionamento;
   - volume fisso al 100% e volume interno del DAC a 0 dB (bit-perfect);
   - DSD nativo se il DAC lo dichiara, altrimenti DoP o PCM a scelta;
   - buffer ampi per anticipare lettura e decodifica: non garantiscono il
     caricamento e la decodifica dell'intero brano prima di suonare; i servizi
     streaming e le radio possono continuare a usare la rete;
   - thread di riproduzione real-time (priorità 80) sul suo core isolato,
     interruzioni del controller USB del DAC (priorità 90) sull'altro.
8. **Modalità ascolto**: mentre la musica suona, la lettura della libreria si
   sospende e riprende quando la musica si ferma; il salvataggio sulla chiavetta
   aspetta la fine dell'ascolto.

## Come si usa

Dal telefono o dal computer apri `http://sweetspot.local/` (oppure l'indirizzo
che compare sullo schermo): si apre l'interfaccia **Material** di Lyrion, con
libreria, radio e servizi in streaming. Funzionano anche le app per Lyrion
(iPeng, Squeezer, Material) e gli altri player Squeezebox della casa.

Nel menu di Material, **Impostazioni Sweetspot** apre le sezioni, come su
Daphile:

| Sezione | Cosa contiene |
| --- | --- |
| **Audio** | DAC riconosciuto, formato aperto sul DAC e configurazione del percorso (l'integrità dei campioni richiede una prova dedicata), volume (fisso, del DAC, software), DSD, ricampionamento facoltativo con scelta del filtro, **correzione ambientale** con REW, opzioni per esperti (buffer, periodi, pause) |
| **Musica** | stato della libreria, dischi trovati (escludi/includi), cartelle di rete (aggiunta con prova di accesso) |
| **Archivio** | il disco dove Sweetspot scrive: copia di cartelle da altri dischi e dal NAS, cartella di rete **Musica** per copiare dal PC o dal Mac, **copia dei CD** |
| **Plugin** | streaming (Qobuz, TIDAL, Spotify, Deezer, Bandcamp, YouTube), radio (Radio Paradise in FLAC, Radio Browser, radio.net), collegamenti (AirPlay in ingresso, UPnP/DLNA, Chromecast, gruppi): installazione con un clic dal repository ufficiale |
| **Rete** | schede di rete, Wi-Fi, indirizzo fisso, nome in rete |
| **Sistema** | nome, modalità, profilo del processore, modalità ascolto, SSH, **aggiornamenti**, **installazione sul disco interno**, riavvio e spegnimento |
| **Stato** | tutte le ottimizzazioni con un pallino verde o arancione, interruzioni dell'audio, traffico di rete |

Le impostazioni restano nella chiavetta, nel file `sweetspot.txt` (modificabile
anche con il Blocco note).

### Correzione ambientale (REW)

Facoltativa e spenta di serie: quando è spenta non c'è niente in mezzo e il
percorso resta bit-perfect. Si misura la stanza con **REW** e un microfono di
misura (UMIK-1/UMIK-2): REW crea uno sweep che si suona da Sweetspot, poi
l'equalizzatore *Generic* calcola i filtri. Il loro testo (*Export filter
settings as text*) si incolla in *Audio → Correzione ambientale*, uno per il
diffusore sinistro e uno per il destro.

- I filtri li applica **CamillaDSP** in virgola mobile a 64 bit, alla
  frequenza di ogni brano (il plugin ALSA *cdsp* lo riavvia a ogni cambio di
  frequenza), sul core dedicato all'audio con priorità real-time; DAC a 16 bit
  con dither.
- Sweetspot calcola la curva della correzione e un'**attenuazione** conservativa
  dal massimo guadagno dei singoli filtri, comprese le risonanze: i picchi
  stretti non dipendono dalla griglia usata per disegnare la curva. Il margine
  copre il guadagno in frequenza; i picchi della forma d'onda possono richiedere
  ulteriore attenuazione, da verificare sul segnale elaborato.
- **Confronto a pari volume**: "esclusa" passa per CamillaDSP con la sola
  attenuazione, così il confronto con la correzione accesa non è falsato dal
  volume.
- Il DSD diventa PCM mentre la correzione è accesa.
- I filtri restano sulla chiavetta, nella cartella `correzione-ambientale`
  (testo di REW, leggibile anche dal computer).

### Archivio musicale e cartella di rete

Tutti i dischi restano in sola lettura tranne uno, scelto come **archivio**
nella pagina Archivio: un disco di dati collegato (ext4, exFAT, NTFS), il resto
del disco interno dopo l'installazione, oppure lo **spazio libero del disco da
cui parte Sweetspot**. L'immagine usa solo la prima parte della scheda SD del
Raspberry Pi, della chiavetta o dell'SSD. Con *Crea l'archivio* il resto
diventa una partizione ext4 "Sweetspot Musica". Si aggiunge solo la seconda
voce della tabella delle partizioni: partizione di sistema e avvio non si
toccano, e il kernel vede la nuova partizione subito, senza riavviare. Lì si copiano cartelle da chiavette, dischi o NAS (la copia si
sospende mentre la musica suona) e lì finiscono i CD. Con *Condividi in rete*
l'archivio compare sul PC come `\\sweetspot.local\Musica` e sul Mac come
`smb://sweetspot.local/Musica` (server SMB del kernel, ksmbd; password
facoltativa). Sull'archivio stanno anche le copertine già ridimensionate da
Lyrion (cartella `.sweetspot-cache`): non occupano RAM e non si rifanno a ogni
avvio.

La scelta salva l'identità UUID o PARTUUID della partizione, così due dischi
con lo stesso nome non vengono confusi. Le vecchie configurazioni con il
nome restano valide solo se quel nome identifica un'unica partizione.

### Copia dei CD

Con un lettore CD collegato, nella pagina Archivio: **Leggi il CD** cerca titoli
e copertina su MusicBrainz (modificabili), **Copia** legge in modo sicuro
(cd-paranoia, con la correzione del lettore trovata da sola al primo CD),
verifica ogni traccia con il database **AccurateRip** e salva FLAC con tag e
copertina in `Artista/Album (Anno)`, con un registro della copia
(`sweetspot-copia.txt`).

### Installazione sul disco interno

*Sistema → Installazione sul disco interno*, come su Daphile: si sceglie il
disco (viene mostrato cosa contiene, e va confermato che sarà cancellato).
Sweetspot crea una partizione di sistema da 4 GB (FAT32, `SWEETSPOT`) e, se si
vuole, usa il resto del disco come archivio musicale (ext4). Copia la versione
in uso con impostazioni, plugin e libreria: si spegne, si toglie la chiavetta e
il computer parte dal disco, con BIOS o UEFI. Il sistema continua a girare
tutto in RAM; la chiavetta resta valida come copia di riserva.

### Aggiornamenti

*Sistema → Cerca aggiornamenti* controlla le release di GitHub; senza internet
basta copiare il pacchetto `sweetspot-x86_64-aggiornamento.tar` (sul
Raspberry Pi `sweetspot-rpi-aggiornamento.tar`) su un disco
collegato o nella cartella di rete Musica. Sulla partizione di sistema ci sono
**due copie del sistema**: l'aggiornamento si scrive in quella non in uso
(controllato con SHA-256), poi GRUB la avvia **una volta sola**. Se il nuovo
sistema arriva in fondo all'avvio e risponde, diventa quello in uso; se non
parte (il kernel si ferma, riavvio automatico dopo 10 secondi) riparte da solo
quello di prima e la pagina Sistema lo segnala. La versione precedente resta
installata: si torna indietro con un clic.

Gli aggiornamenti sono **firmati**: la compilazione ufficiale firma l'elenco dei
file del pacchetto con una chiave privata che sta solo nei segreti del
repository su GitHub (`SWEETSPOT_FIRMA`), e Sweetspot installa solo pacchetti
con una firma valida per la sua chiave pubblica
(`/etc/sweetspot/aggiornamenti.pub`); la firma vale per versione e
architettura del pacchetto. La coppia di chiavi si crea con
`scripts/genera-chiave-firma.sh` (chi pubblica una propria copia del progetto
crea le sue).

Senza una chiave pubblica incorporata, l'installazione degli aggiornamenti è
disabilitata. Una release ufficiale richiede chiave, firma e test Lyrion
riusciti per entrambe le architetture. Le compilazioni di sviluppo possono
produrre artifact non firmati, che il player rifiuta. Il pacchetto viene
controllato prima dell'estrazione: solo file previsti, tutti coperti dal
manifesto, senza collegamenti o percorsi esterni. Per un aggiornamento serve
spazio temporaneo anche per il tar completo, oltre ai file estratti.

### Modalità

- **completa** (predefinita): tutto su Sweetspot, come Daphile.
- **player**: solo Squeezelite, per un Lyrion Music Server su un altro
  computer (per chi vuole server e player separati).

## Cosa serve

- Un PC x86 a 64 bit con almeno 2 GB di RAM (consigliati 4 GB o più).
  Prototipo di riferimento: Asus N550JV con 16 GB.
  Oppure un Raspberry Pi 4, 400, 5 o 500 (anche Compute Module 4 e 5), meglio
  con almeno 2 GB: vedi [Raspberry Pi](#raspberry-pi).
- Un DAC USB (sul Raspberry Pi anche una scheda DAC I2S, tipo HiFiBerry).
- Il cavo di rete (il Wi-Fi funziona, ma è un ripiego).
- Una chiavetta USB da almeno 1 GB (per l'installazione: un disco interno da
  almeno 2 GB, che viene cancellato).

Secure Boot va disattivato nel BIOS/UEFI.

## Ottenere l'immagine

### Con GitHub (consigliato, non serve un PC Linux)

1. Crea un repository su GitHub e caricaci questo progetto.
2. La compilazione parte da sola (scheda **Actions**, "Compila Sweetspot") e
   dura circa un'ora e mezza la prima volta, meno le successive grazie alla
   cache.
3. A fine compilazione scarica dalla sezione **Artifacts** `sweetspot.img.xz`
   (PC) o `sweetspot-rpi.img.xz` (Raspberry Pi): si scaricano già come file
   pronti da scrivere, non dentro uno zip.

La CI usa le versioni più recenti dei server di GitHub (Ubuntu 26.04, anche
ARM) e delle sue azioni. Ogni lunedì il workflow *Controllo versioni* confronta
i componenti di Sweetspot con le ultime versioni pubblicate: Buildroot, kernel,
firmware del Raspberry Pi, Lyrion, Material, CamillaDSP, azioni di GitHub e
immagine Docker. Se qualcosa è indietro apre (o aggiorna) la segnalazione
*Aggiornamenti disponibili*. Lo stesso controllo si fa a mano con
`scripts/controlla-versioni.sh`.

Pubblicando un tag `v0.1.0` l'immagine finisce anche nella pagina Releases.

### Su Linux o WSL2

```sh
sudo apt install bc build-essential cpio file git libelf-dev libssl-dev rsync unzip wget xz-utils
./scripts/build.sh                           # PC
./scripts/build.sh sweetspot_rpi_defconfig   # Raspberry Pi 4 e 5
```

L'immagine è in `output/images/sweetspot.img.xz` (Raspberry Pi:
`sweetspot-rpi.img.xz`). Servono circa 15 GB liberi, 25 GB per il Raspberry Pi.

### Con Docker

```sh
./scripts/build-docker.sh
```

## Provarla prima, in una macchina virtuale

Su Linux si può avviare l'immagine in QEMU, che simula un PC a 4 core con
Hyper-Threading, la chiavetta e un DAC USB Audio sullo stesso controller:

```sh
sudo apt install qemu-system-x86 mtools ovmf
./tests/qemu-avvio.sh output/images/sweetspot.img.xz          # BIOS
./tests/qemu-avvio.sh output/images/sweetspot.img.xz uefi     # UEFI
```

Si vede il primo avvio con il riavvio di adattamento; poi l'interfaccia è su
`http://localhost:9000/material/` e le impostazioni su
`http://localhost:8080/cgi-bin/audio`. Ctrl+A e poi X per uscire.

### In VMware (Workstation Pro, Player, Fusion)

Ogni compilazione produce anche `sweetspot-vmware.vmdk` (tra gli artifact):
la stessa chiavetta, come disco virtuale.

1. *Crea una nuova macchina virtuale* → *Personalizzata* → *Installerò il
   sistema operativo più tardi* → sistema **Linux**, versione **Altro Linux
   6.x a 64 bit** (o "Other Linux 5.x and later kernel 64-bit").
2. Processore: **almeno 2 core** (con un solo core non c'è il core dedicato
   all'audio). Memoria: **4 GB**.
3. Rete: **Bridged** (con la NAT il telefono e le app Lyrion non vedono
   Sweetspot).
4. Disco: *Usa un disco virtuale esistente* → `sweetspot-vmware.vmdk`
   (se chiede di convertirlo al formato nuovo, va bene).
5. Per provare l'installazione e l'archivio aggiungi un secondo disco nuovo,
   per esempio da 20 GB.
6. Firmware: BIOS o UEFI vanno bene entrambi (con UEFI, Secure Boot spento).
7. Accendi: Sweetspot si adatta e si riavvia una volta; l'indirizzo compare
   sulla console della macchina virtuale.
8. Il DAC si collega dal menu di VMware (*VM → Dispositivi rimovibili →
   il DAC → Connetti*), con il controller USB 3.1.

In macchina virtuale si provano interfaccia, plugin, libreria, archivio,
installazione e aggiornamenti; **il suono no**: l'audio passa per l'USB
virtuale di VMware e per lo scheduler di Windows, e core dedicati e kernel
real-time non possono fare il loro lavoro. Per ascoltare serve il PC vero.

## Scrivere la chiavetta

Con **Raspberry Pi Imager** ("Usa immagine personalizzata"), **balenaEtcher** o
**Rufus** (modalità DD) si scrive direttamente `sweetspot.img.xz`, senza
decomprimerlo. La chiavetta resta leggibile da Windows e macOS come unità
`SWEETSPOT` e contiene `sweetspot.txt` e `LEGGIMI.txt`.

## Raspberry Pi

Un'unica immagine, `sweetspot-rpi.img.xz`, per Raspberry Pi 4, 400, 5, 500 e
Compute Module 4/5: si scrive sulla scheda SD (o su una chiavetta USB, se il Pi
parte da USB) come per il PC, con Raspberry Pi Imager senza personalizzazioni.

- **Kernel**: quello della Raspberry Pi Foundation nella serie LTS più recente
  (6.18, la stessa del PC e di Raspberry Pi OS) con PREEMPT_RT e pagine da 4 KB,
  uguale per il Pi 4 e il Pi 5. Firmware dall'ultima release della Raspberry Pi
  Foundation; gli overlay delle schede DAC li compila il kernel stesso.
  Programmi compilati per Cortex-A72, che girano identici sul Cortex-A76 del
  Pi 5. Due core su quattro dedicati a riproduzione e interruzioni USB,
  frequenza fissa, nessuno stato di risparmio della CPU (`cpuidle.off=1`).
- **Uscite spente**: jack e HDMI audio (`dtparam=audio=off`), Bluetooth
  (`disable-bt`), Wi-Fi se non configurato.
- **DAC USB** come sul PC. **Schede DAC I2S** (HiFiBerry, Allo, IQaudio, Raspberry
  Pi DAC+/DAC Pro, JustBoom, I-Sabre...): si sceglie la scheda in *Impostazioni
  Sweetspot → Audio*, o si scrive il nome del suo overlay; il Pi si riavvia una
  volta per caricarla. Con una scheda I2S il DSD arriva in PCM.
- **Avvio e aggiornamenti**: la partizione FAT32 `SWEETSPOT` contiene il
  firmware e due copie complete del sistema, nelle cartelle `a` e `b` (kernel,
  sistema in RAM, alberi dei dispositivi, overlay, `cmdline.txt`). `config.txt`
  sceglie la copia in uso (`os_prefix`); un aggiornamento si prova con il
  riavvio *tryboot* del firmware, che usa `tryboot.txt` una volta sola. Se la
  nuova versione non si conferma, al riavvio successivo (o staccando la
  corrente) riparte quella di prima.
- **Lyrion**: Lyrion non fornisce i suoi moduli compilati per ARM con Perl 5.42.
  Li compila il workflow *Moduli di Lyrion* (`.github/workflows/moduli-lyrion.yml`)
  con lo script ufficiale di Lyrion, in Fedora 43 su un server ARM di GitHub, e
  li pubblica nella release `dipendenze-lyrion`; Buildroot li scarica con
  impronta SHA-256 fissa. La CI avvia poi Lyrion nel sistema compilato, su un
  server ARM, prima di considerare buona l'immagine.
- Non c'è l'installazione sul disco interno: il sistema sta già sulla scheda SD.

## Primo avvio

1. DAC acceso e collegato, cavo di rete collegato, chiavetta inserita.
2. Accendi e scegli la chiavetta dal menu di avvio del PC.
3. Sweetspot si adatta al computer e si riavvia una volta.
4. Sul monitor compare l'indirizzo; dal telefono apri `http://sweetspot.local`.
5. Collega un disco con la musica o aggiungi la cartella del NAS in
   *Impostazioni Sweetspot → Musica*: la libreria si crea da sola.

## Impostazioni (`sweetspot.txt`)

| Voce | Valori | Predefinito |
| --- | --- | --- |
| `NOME_PLAYER` | testo | Sweetspot |
| `MODALITA` | `completa`, `player` | completa |
| `SERVER` | solo modalità player: indirizzo di Lyrion, vuoto = ricerca automatica | vuoto |
| `MODALITA_ASCOLTO` | `si`, `no` | si |
| `DISCHI`, `ESCLUDI_DISCHI` | dischi locali, nomi da escludere | si, vuoto |
| `CONDIVISIONE_n`, `_UTENTE`, `_PASSWORD` | cartelle di rete (fino a 9) | vuoto |
| `DAC` | `auto`, nome ALSA (es. `R26`) o `VID:PID` | auto |
| `VOLUME` | `fisso`, `dac`, `software` | fisso |
| `DSD` | `auto`, `nativo`, `dop`, `no` | auto |
| `RICAMPIONAMENTO`, `FILTRO` | `no`/`sincrono`/`asincrono`, `lineare`/`intermedio`/`minimo` | no, lineare |
| `FREQUENZA_MAX` | Hz, 0 = quella del DAC | 0 |
| `PAUSA_DSD_MS`, `PAUSA_FREQUENZA_MS` | pause per i DAC che perdono l'inizio | 500, 0 |
| `NOME_RETE` | nome in rete (`http://NOME.local`) | sweetspot |
| `WIFI_NOME`, `WIFI_PASSWORD` | rete Wi-Fi, solo senza cavo | vuoto |
| `IP_FISSO`, `GATEWAY`, `DNS` | indirizzo fisso, es. `192.168.1.50/24` | vuoto |
| `RISPARMIO_RETE` | risparmio energetico Ethernet (EEE) | no |
| `PROFILO` | `bilanciato`, `silenzio`, `prestazioni` | bilanciato |
| `USCITA_INTEGRATA` | usa la scheda audio del PC | no |
| `SCHERMO_MINUTI` | spegnimento dello schermo, 0 = mai | 2 |
| `SSH`, `SSH_PASSWORD` | accesso remoto per l'assistenza | no |
| `OTTIMIZZAZIONI` | `no` per confronti alla cieca o problemi | si |
| `CORREZIONE` | `no`, `si`, `confronto` (pari volume, senza filtri) | no |
| `ARCHIVIO` | UUID/PARTUUID dell'archivio; nome nelle vecchie configurazioni se univoco | vuoto |
| `ARCHIVIO_CONDIVISO`, `ARCHIVIO_PASSWORD` | cartella di rete Musica | no, vuoto |
| `AGGIORNAMENTI_URL` | altra fonte degli aggiornamenti (API release di GitHub) | questo progetto |

I profili cambiano solo la frequenza della CPU: *silenzio* la fissa alla
minima, *bilanciato* a metà strada, *prestazioni* alla nominale tenendo i core
sempre svegli. Il Turbo è sempre spento.

## Verifiche

| Verifica | Come |
| --- | --- |
| Stato ALSA, formato e percorso configurato | *Impostazioni Sweetspot → Audio*, riquadro "Uscita audio": endpoint selezionato, substream e stato osservato; non confronta i campioni |
| Sistema in RAM, chiavetta non in uso | pagina di stato, voci "Sistema in RAM" e "Chiavetta" |
| Ottimizzazioni attive | pagina di stato: tutte le voci verdi |
| DSD nativo sul R26 | pagina di stato, voce "DSD": `nativo (u32be)` |
| Campioni e continuità nel backend software | `tests/prova-lyrion.sh`: confronto completo PCM/DoP, incluse sorgenti DSF/DFF; [protocollo](docs/audio-verification.md) |
| Riconoscimento DoP del DAC | `tools/genera-test-dop.py`: vedi sotto |
| Latenza real-time | `sweetspot-latenza 300` da terminale (Alt+F2 o SSH), obiettivo sotto 50 µs |
| XRUN ALSA e recuperi falliti | pagina di stato: conteggi separati nel registro disponibile, anche di avvii precedenti; zero eventi non esclude carenza di dati, errori DSP o altre interruzioni |
| Traffico durante l'ascolto | pagina di stato, "Traffico di rete ora"; read-ahead e streaming non garantiscono rete inattiva |

### Prova di riconoscimento con il file DoP

```sh
python3 tools/genera-test-dop.py
```

Crea `sweetspot-test-dop.wav`: un PCM 24 bit / 176,4 kHz che contiene un tono
DSD64 a 1 kHz in formato DoP. Copialo nella libreria, **abbassa
l'amplificatore** e riproducilo. Se il DAC indica DSD e si sente un tono pulito,
il DAC riconosce il trasporto DoP di quel file. Questo controllo non confronta
ogni campione e non certifica tutte le sorgenti o impostazioni. Se indica PCM
o si sente fruscio, controlla supporto DoP, volume e conversioni del server.

Per certificare PCM bit-perfect, registra l'uscita digitale della catena,
allinea i campioni decodificati di riferimento e confrontali bit per bit,
tenendo conto del contenitore ALSA. Conserva file, impostazioni e risultati
per ogni formato e frequenza. Una prova con DAC emulato verifica quel percorso
software; non misura il clock o il rumore dell'uscita analogica di un DAC reale.

Il [comparatore PCM e la prova Lyrion/Squeezelite](docs/audio-verification.md)
confrontano ogni campione e il passaggio fra due brani, con report JSON e
capture conservate dalla CI. Il backend software stdout viene controllato
a 44,1/48/96 kHz e 16/24 bit, inclusi passaggi fra profondità diverse, e sul
payload DoP a 176,4/352,8 kHz, anche decodificando sorgenti DSF/DFF DSD64/128.
Sul PC gli stessi casi si ripetono anche nel driver ALSA del kernel di
Sweetspot, avviato in QEMU, su `hw:Loopback` (snd-aloop) con buffer, periodi e
mmap del player; un XRUN fa fallire la prova.
Restano aperti il cambio di frequenza su ALSA e la certificazione dei DAC reali.

### Qualità sonora e compatibilità

Il [piano di parità con Daphile e dei miglioramenti](docs/daphile-parity.md)
definisce le funzioni da conservare, le lacune ancora aperte e i criteri
di accettazione. Le correzioni recenti sono una base, non il completamento
dell'alternativa a Daphile.

Sweetspot e Daphile condividono Lyrion/Squeezelite. RAM, kernel real-time e
core dedicati non dimostrano da soli una superiorità sonora. Una catena
bit-perfect preserva i campioni; il DSP li modifica intenzionalmente. Il
confronto richiede lo stesso hardware, DAC e volume, misure digitali e
analogiche e ascolto alla cieca quando si valutano differenze percepite.

Con USB asincrona il clock della conversione è quello del DAC. Il programma
alimenta i buffer tramite il driver ALSA; non può sostituire l'oscillatore del
DAC con il clock del PC né realizzare un filtro elettrico sulle linee USB.
La latenza misurata da `sweetspot-latenza` riguarda lo scheduler, non il jitter
del clock audio. Per riferimenti: [Daphile](https://www.daphile.com/index.html),
[clock USB XMOS](https://www.xmos.com/documentation/XM-012296-UG/html/doc/rst/sw_ep0.html).

Il riconoscimento del DAC considera le uscite playback e il loro numero di
dispositivo: un microfono USB collegato per REW non diventa l'uscita audio.
Le capacità USB di acquisizione non vengono offerte alla riproduzione. La
correzione sceglie formati e frequenze delle configurazioni stereo, senza
confonderle con quelle multicanale. Per I2S interroga ALSA; se non può verificare le capacità, segnala
l'errore senza inventare un formato o frequenze supportati.

La compatibilità va riferita alla combinazione release, computer, DAC e
firmware: **compatibile** (riconosciuto), **verificato** (prove funzionali) e
**certificato audio** (confronto campioni e prove di continuità). Il progetto
non garantisce tutti i DAC o tutti gli hardware. Prima della distribuzione
servono una matrice PCM/DSD/gapless/hotplug su hardware reale, prove di
aggiornamento con interruzione di alimentazione e protezione amministrativa
del pannello web, attualmente accessibile dalla rete locale senza login.

## Struttura del progetto

```
configs/sweetspot_x86_64_defconfig    configurazione di Buildroot per i PC
configs/sweetspot_rpi_defconfig       configurazione di Buildroot per Raspberry Pi 4 e 5
board/sweetspot/common/               kernel PREEMPT_RT (parte comune), BusyBox
board/sweetspot/x86/                  kernel dei PC, GRUB (due copie del sistema), chiavetta
board/sweetspot/rpi/                  kernel del Pi, config.txt, scheda SD, LEGGIMI
board/sweetspot/stick/                sweetspot.txt e LEGGIMI.txt
board/sweetspot/rootfs-overlay/       script di sistema, pagine di impostazione,
                                      plugin di Sweetspot per Lyrion
package/lms, package/lms-material     Lyrion Music Server e Material Skin
package/sweetspot-tools               firme AccurateRip per la copia dei CD
package/camilladsp, package/alsa-cdsp CamillaDSP e plugin ALSA per la correzione ambientale
scripts/                              compilazione locale e con Docker
tests/run.sh                          test degli script con /sys e /proc simulati
tests/cd-simulato.sh                  copia completa di un CD con un lettore finto
tests/qemu-avvio.sh                   prova dell'immagine in QEMU (BIOS e UEFI)
tests/prova-lyrion.sh                 Lyrion avviato nel sistema compilato (CI, anche su ARM)
tools/moduli-lyrion/                  prova dei moduli di Lyrion compilati per ARM
tools/genera-test-dop.py              file di prova bit-perfect
```

Basato su Buildroot 2026.08 e sul kernel LTS 6.18 con PREEMPT_RT: 6.18.55 sul
PC, il ramo rpi-6.18.y della Raspberry Pi Foundation sul Raspberry Pi.

## Licenza

GNU General Public License versione 3 o successiva. Vedi `LICENSE`.
