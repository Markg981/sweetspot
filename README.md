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
     interruzioni del controller USB del DAC (priorità 90) sull'altro: servono
     alla stabilità temporale dell'alimentazione dei buffer, non a ridurre il
     jitter del clock di conversione del DAC.
8. **Modalità ascolto**: mentre la musica suona, la lettura della libreria e i
   lavori di fondo (copie, ripping) vengono rallentati e riprendono a velocità
   normale quando la musica si ferma; il salvataggio completo sulla chiavetta
   aspetta la fine dell'ascolto, ma ogni 15 minuti (se la libreria è cambiata)
   un *checkpoint* dei soli database, con il backup online di SQLite scritto
   direttamente sulla chiavetta (niente copia in RAM) da un processo a bassa
   priorità: cgroup con `io.weight` minimo, `ionice` idle, `nice` 19, solo sui
   core di sistema. Così una lettura lunga durante un ascolto lungo non si perde
   se manca la corrente. Il riavvio del solo player ("Salva e applica" nella
   pagina Audio) non fa più alcuna copia del database. Prima di scrivere si
   controlla lo spazio: a chiavetta piena non si riprova ogni minuto (ogni 30
   minuti) e la pagina Stato avvisa. Il rallentamento usa un cgroup v2 (`cpu.max` 5%,
   `cpu.weight` minimo) e `ionice -c3`: i processi restano vivi, così lo scanner
   non resta congelato con una transazione del database aperta. Se il kernel
   non ha cgroup v2 si ripiega sul vecchio `SIGSTOP`. All'avvio il demone
   riprende comunque quanto un'esecuzione precedente aveva lasciato fermo.
8b. **Memoria sotto pressione**: il sistema non ha swap (e non si aggiunge, nemmeno
   zram: riempirebbe di compressione e latenza il percorso del suono e
   richiederebbe un kernel con swap). Per questo, se la RAM finisse (tipico
   sui 2 GB, classe «essenziale»), l'OOM killer segue una scala di priorità
   (`oom_score_adj`): Squeezelite e CamillaDSP a -1000 (mai uccisi), Lyrion a
   -100, scanner di Lyrion, copie, estrazione dei CD e precarico a +500, i
   primi a cadere. Resta il limite dei buffer di Squeezelite (`player_buffers`),
   che lascia 768 MB al resto.
9. **Precarico in RAM** (modalità completa): i file della coda, dal brano in
   corso alla fine, vengono letti dietro a tutti gli altri processi (`nice`,
   `ionice` idle) e bloccati in RAM (`mlock`), entro un budget di memoria (per
   difetto metà di quella libera, tolti i buffer di Squeezelite ancora da
   riempire). Quando tutta la coda è in RAM, i dischi meccanici che la
   contengono vanno in standby; lo stato mostrato è quello vero (`hdparm -C`):
   un disco svegliato da altro esce dall'elenco e si riprova a fermarlo dopo
   un minuto. Con la coda invariata il piano non si ricalcola (niente `stat`
   sulle cartelle di rete a ogni giro). Lo streaming non si precarica, i file
   oltre `PRECARICO_FILE_MAX_MB` restano sul disco e la pagina Stato mostra
   brani caricati, memoria usata, esclusioni e dischi fermi. Le righe `#inizio-fine`
   dei brani CUE contano come il loro file (letto una volta sola) e la coda si
   legge a pagine da 500: anche le code oltre 1000 brani sono precaricate.

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
| **Sistema** | nome, modalità, profilo del processore, modalità ascolto, renderer UPnP/DLNA, SSH, **aggiornamenti**, **installazione sul disco interno**, riavvio e spegnimento |
| **Stato** | tutte le ottimizzazioni con un pallino verde o arancione, interruzioni dell'audio, traffico di rete, e la prova dell'ascolto puro: letture dal disco e byte di rete dall'inizio dell'ascolto. Non rifà i controlli a ogni visita: legge la cache del demone `sweetspot-stato` (ogni 10 secondi, ogni 45 durante l'ascolto; core di sistema, `nice 19`) e avvisa se è assente o vecchia. Lo stesso stato in JSON, in sola lettura: `/cgi-bin/stato.json` (stessa password del pannello) e, da Lyrion o Material via JSON-RPC, `["sweetspot","stato"]` |

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
  frequenza): i suoi **thread audio** (cattura dal plugin, elaborazione,
  riproduzione ALSA) sul core dedicato all'audio con priorità real-time
  (`SCHED_FIFO` 70, `PRIORITA_DSP`, sotto il player a 80 che lo alimenta), gli
  altri (principale, segnali, websocket e le connessioni di
  `sweetspot-camilla`) sui core di sistema con la priorità normale, così sul
  core isolato gira solo l'audio. Il thread di elaborazione si riconosce dal
  nome grazie alla patch `patches/camilladsp/0001-name-processing-thread.patch`;
  la pagina Stato verifica, alla voce "CamillaDSP in real-time", priorità e
  core dei thread audio e segnala un thread non audio rimasto in real-time.
  All'uscita sempre il dither TPDF alla
  risoluzione del DAC (16 o 24 bit): CamillaDSP modifica i campioni, e il
  passaggio da 64 bit all'uscita non va troncato.
- Sweetspot calcola la curva della correzione e un'**attenuazione** conservativa
  dal massimo guadagno dei singoli filtri, comprese le risonanze: i picchi
  stretti non dipendono dalla griglia usata per disegnare la curva. Il margine
  copre il guadagno in frequenza; i picchi della forma d'onda possono richiedere
  ulteriore attenuazione, da verificare sul segnale elaborato: la pagina Stato,
  voce "Clipping di CamillaDSP", somma i campioni tagliati nella sessione
  (letti ogni pochi secondi dal websocket di CamillaDSP, aperto solo su
  127.0.0.1:1234).
- Con `CORREZIONE=si` o `confronto` e `CORREZIONE_SE_ASSENTE=blocca` (predefinito)
  il player non suona se i filtri mancano, sono illeggibili, malformati (REW
  senza righe `Filter N:` o con errori, WAV non valido), incoerenti (FIR con
  frequenze o canali diversi, `destro` senza `sinistro`) o se CamillaDSP rifiuta
  la configurazione: la pagina Stato e Correzione mostrano il motivo. Con
  `diretto` suona senza correzione e lo stesso avviso resta visibile.
- **Filtri FIR** (convoluzione): impulsi WAV esportati da rePhase, Acourate o
  REW, copiati dal computer nella cartella `correzione-ambientale` della
  chiavetta come `fir-sinistro.wav` e, se diverso, `fir-destro.wav` (un file
  stereo da solo vale per i due canali; mono o stereo, fino a 16 MB, stessa
  frequenza). Si applicano dopo i filtri di REW, con la correzione accesa.
  CamillaDSP lavora alla frequenza degli impulsi e ricampiona i brani a
  frequenze diverse (ricampionatore `Synchronous`; con la stessa frequenza il
  ricampionamento si spegne da solo); il DAC deve accettarla. Attenuazione in
  più `FIR_MARGINE_DB` (3 dB): i FIR di rePhase e Acourate sono di solito già
  normalizzati, la voce "Clipping di CamillaDSP" della pagina Stato dice se
  basta. La coda di ogni brano non viene tagliata: quando lo stream si chiude
  (stop, cambio di frequenza, pausa lunga) CamillaDSP legge ancora tanti
  campioni di silenzio quanti i tap dei FIR più due blocchi
  (`extra_samples`), così il suono ancora dentro i filtri arriva al DAC.
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
`smb://sweetspot.local/Musica` (server SMB del kernel, ksmbd, minimo SMB 2.1).
Con una **password** (utente `sweetspot`) la cartella è in lettura e scrittura,
per copiare la musica; **senza password** è aperta agli ospiti ma in **sola
lettura**. Il server lavora come utente `nas`, non come root, e non mostra i
file interni (cartella `.sweetspot-cache`, `artwork.db`, `imgproxy.db`). Si
scrive solo dove l'utente `nas` ha i permessi: la cartella radice dell'archivio
gli viene assegnata, le cartelle già presenti create da altri restano in sola
lettura finché non se ne cambia il proprietario.

Le **cartelle di rete** della pagina Musica possono essere SMB (NAS, PC
Windows, Mac) oppure **NFS** (NAS e server Linux; client del kernel, NFSv4 con
ripiego su NFSv3). SMB usa almeno la versione 2.1, con la 3.x preferita; **SMB1
è insicuro** (niente firma né cifratura) e va richiesto esplicitamente, cartella
per cartella, solo per NAS molto vecchi. I montaggi sono `hard`: se il NAS si
spegne o il Wi-Fi cade, la lettura riprende da sola al ritorno invece di dare
errori di I/O a Squeezelite o alla scansione (il processo in attesa si può
sempre interrompere e lo smontaggio è immediato); il montaggio iniziale ha
invece un tempo massimo e, se fallisce, valgono i ritentativi a intervalli
crescenti. Sull'archivio stanno anche le copertine già ridimensionate da
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

### Renderer UPnP/DLNA in entrata

Con `RENDERER_UPNP=si` (pagina Sistema, spento di serie) Sweetspot compare come
diffusore UPnP/DLNA (MediaRenderer:1) in BubbleUPnP, JPlay, mconnect e nelle
altre app. L'audio non ha un percorso proprio: `SetAVTransportURI` e `Play`
diventano un `playlist play` verso Lyrion, che apre l'indirizzo e lo manda al
player Squeezelite. Il percorso e' quello della libreria (bit-perfect, DSD,
correzione ambientale), e il DAC lo apre solo il player: nessun programma in
concorrenza. Il demone (`/usr/lib/sweetspot/renderer.pl`, Perl come Lyrion,
avviato da `S70sweetspot-renderer`) e' solo il telecomando UPnP: SSDP, descrittore,
AVTransport, RenderingControl e ConnectionManager con eventi, stato in Stato
("Renderer UPnP/DLNA").

Perche' cosi' e non altrimenti: non esiste un plugin di Lyrion mantenuto che
esponga i player come MediaRenderer (UPnPBridge fa l'inverso: usa i diffusori
UPnP come player); upmpdcli richiede un MPD completo e un ponte verso Lyrion;
gmrender-resurrect suona con GStreamer e aprirebbe il DAC in concorrenza con
Squeezelite, oltre a portare con se' GStreamer.

Limiti: servono Lyrion su questo Sweetspot (`MODALITA=completa`) e indirizzi
HTTP leggibili da Lyrion (FLAC, WAV, AIFF, MP3, AAC, Ogg); il volume della app
agisce sul volume di Lyrion e quindi conta solo con `VOLUME` software o del DAC;
niente OpenHome (le app lo usano solo se c'e', altrimenti ripiegano su
AVTransport); un'app alla volta controlla il renderer, e la musica avviata da
Lyrion non viene fermata da un `Stop` UPnP.

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
  corrente) riparte quella di prima. La conferma a fine avvio
  (`sweetspot-aggiorna conferma`) verifica in ordine: impostazioni
  leggibili, pagina locale `/cgi-bin/vivo`, supervisore del player in
  esecuzione, Lyrion che risponde (solo in modalità completa; fino a 10
  minuti di attesa, `SWEETSPOT_CONFERMA_ATTESA_LMS`), musica e dati di Lyrion
  accessibili. Un DAC assente o scollegato ("in attesa del DAC") non è un
  guasto e non causa il ritorno alla versione precedente. Il controllo
  fallito resta nel registro e compare nella pagina Sistema e nel rapporto.
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

### Hotspot di configurazione Wi-Fi

Senza cavo e senza aver scritto `WIFI_NOME` in `sweetspot.txt`, il primo avvio
non resta senza rete. Se dopo `HOTSPOT_ATTESA` secondi (60) non c'è nessuna
connessione (nessun cavo con collegamento, nessun indirizzo, Wi-Fi non
configurato o non collegato) e c'è un adattatore Wi-Fi che sa fare da access
point, Sweetspot accende la rete **`Sweetspot-XXXX`** (XXXX = ultime cifre del
MAC), WPA2, canale 6 (2,4 GHz), con DHCP e DNS minimi (`udhcpd`, `dnsd` di
BusyBox):

1. Il nome e la **password** compaiono sullo schermo (console), con il **codice
   QR** `WIFI:T:WPA;S:...;P:...;;` da inquadrare. Senza schermo: la password è
   casuale la prima volta, poi resta la stessa e viene scritta, insieme al
   nome, in `sweetspot-hotspot.txt` sulla partizione di avvio (la chiavetta
   `SWEETSPOT`, FAT, leggibile da un PC) con il QR in `sweetspot-hotspot.svg`
   (da aprire col browser del PC). Non finisce nel registro. Per sceglierla tu
   scrivi `HOTSPOT_PASSWORD` (8-63 caratteri) in `sweetspot.txt`.
2. Collega il telefono a quella rete e apri `http://192.168.4.1/` (anche
   `http://sweetspot.local/`, via mDNS con Avahi, se il telefono lo supporta): si
   apre la pagina **Rete**. Il DNS dell'hotspot risolve i controlli di
   connettività dei telefoni (Apple, Windows, Firefox, Android...) verso
   Sweetspot; iPhone, Mac e Firefox aprono la pagina da soli (`hotspot-detect.html`,
   `canonical.html`), su Android compare "Accedi alla rete" (non c'è una
   risposta 204 statica: la pagina si apre comunque dall'avviso o digitando
   l'indirizzo).
3. In *Collega Sweetspot al Wi-Fi di casa* scegli la rete dall'elenco (o scrivi
   il nome) e la password, poi **Collega**. Il nome e la password sono salvati
   con `sweetspot-config` (chiavetta), l'hotspot si spegne e Sweetspot si
   collega.
4. **Recupero**: se entro `HOTSPOT_PROVA` secondi (40) la rete scelta non dà un
   indirizzo (password sbagliata, router spento) l'hotspot riparte e puoi
   riprovare. La stessa cosa succede a un avvio con `WIFI_NOME` sbagliato.

**Primo avvio senza schermo**: oppure preconfigura il Wi-Fi di casa prima
dell'accensione scrivendo `WIFI_NOME` e `WIFI_PASSWORD` in `sweetspot.txt`
sulla partizione di avvio (da un PC): l'hotspot non serve.

L'hotspot non si accende mai con la rete funzionante e si spegne da solo se
arriva un cavo. Con `HOTSPOT=no` non si accende mai; le radio Wi-Fi restano
spente come negli altri casi (`radios_off` in `S20sweetspot-tune`) e vengono
accese solo per l'hotspot. Servono i pacchetti `hostapd` e `iw` (già nelle
immagini x86 e Raspberry Pi) e un driver che supporti la modalità AP.

## Impostazioni (`sweetspot.txt`)

| Voce | Valori | Predefinito |
| --- | --- | --- |
| `NOME_PLAYER` | testo | Sweetspot |
| `MODALITA` | `completa`, `player` | completa |
| `SERVER` | solo modalità player: indirizzo di Lyrion, vuoto = ricerca automatica | vuoto |
| `MODALITA_ASCOLTO` | `si`, `no`: mentre la musica suona lettura della libreria, copie e ripping restano sospesi. Nella pagina Sistema un'unica scelta, che vale subito: *ascolto puro* (questa più `PRECARICO=si`: coda in RAM e dischi fermi), *lavori sospesi* (`PRECARICO=no`) o *spenta*; la pagina Stato, voce "Ascolto", dice quale è attiva e quanti lavori sono sospesi ora | si |
| `PRECARICO` | `si`, `no`: coda di ascolto in RAM | si |
| `PRECARICO_MB` | `auto` (metà della memoria libera, tolti i buffer di Squeezelite ancora da riempire) o MB; mai oltre la memoria libera meno quei buffer e 256 MB | auto |
| `PRECARICO_FILE_MAX_MB` | file più grandi letti dal disco | 1024 |
| `PRECARICO_STANDBY` | `si`, `no`: dischi meccanici in standby a coda caricata | si |
| `LYRION_MEM_MB`, `SCANNER_MEM_MB` | tetto di memoria (cgroup v2: `memory.max`, con `memory.high` all'85%) di Lyrion e del suo scanner: MB o `auto` (70% e 40% della RAM). Il tmpfs scritto da Lyrion (database della libreria) conta nel suo tetto | auto |
| `ARTWORK_RAM_MB` | cache delle copertine in RAM, in un tmpfs a parte con `size=`, quando non c'è l'archivio musicale: MB o `auto` (4% della RAM, tra 32 e 256 MB). Piena, la pagina Stato avvisa e le nuove copertine non si salvano | auto |
| `DISCHI`, `ESCLUDI_DISCHI` | dischi locali, nomi da escludere | si, vuoto |
| `CONDIVISIONE_n`, `_UTENTE`, `_PASSWORD`, `_SMB1` | cartelle di rete (fino a 9): `//server/cartella` (SMB) o `nfs://server/cartella` (NFS); `_SMB1=si` ammette SMB1, insicuro | vuoto |
| `DAC` | DAC principale: `auto` (il primo DAC USB trovato; con le zone resta lui per tutto l'avvio), nome ALSA (es. `R26`) o `VID:PID`. Nella pagina Audio si sceglie tra i DAC collegati | auto |
| `ALTRI_DAC` | `si`: ogni altro DAC USB con un'uscita ha il suo Squeezelite, cioè un player separato in Lyrion ("Sweetspot - nome del DAC", MAC stabile per DAC da identificativo USB e numero di serie), da raggruppare e sincronizzare in Lyrion. Il DAC principale resta com'è (core isolato, correzione, volume a 64 bit); gli altri suonano sui core di sistema con priorità un po' più bassa, uscita diretta, mixer a 0 dB e volume da Lyrion. Si avviano e fermano da soli con il collegamento del DAC, anche mentre il DAC principale manca: se il principale si spegne il player lo aspetta e non passa mai a una zona; pagina Stato, voce "Altri DAC (zone)" | no |
| `VOLUME` | `fisso`, `dac`, `software` (Squeezelite tronca i bit bassi senza dither: peggiore del fisso, segnalato in Audio e Stato), `dsp`: volume a 64 bit in CamillaDSP con dither TPDF alla risoluzione del DAC (24 o 16 bit, sempre presente, anche al 100%: per il percorso bit-perfect scegli `fisso`); Squeezelite lascia i campioni invariati (opzione `-F`, patch di Sweetspot) mentre Lyrion tiene il controllo digitale del volume, così Material e le app mostrano il cursore, che `sweetspot-volume` segue dalla CLI con la stessa scala di Lyrion per Squeezelite (100 = 0 dB, 50 = −24,7 dB, 25 = −37 dB, 1 = −72,5 dB, 0 = sordina; mai sopra 0 dB), riletto anche a ogni ricollegamento del player. I file DSD si convertono in PCM. Ogni CamillaDSP parte già al volume giusto (`vol_file` del plugin cdsp: se manca, silenzio e non volume massimo). Solo in modalità completa; se CamillaDSP non parte si usa il volume software | fisso |
| `DSD` | `auto`, `nativo`, `dop`, `no` | auto |
| `DSD_PCM_MARGINE_DB` | margine in dB della conversione DSD → PCM, da -24 a 0 (mai sopra 0). I DSD "over" superano 0 dBFS fino a +3 dB (il 50% di modulazione oltre lo standard) e senza margine la conversione a 32 bit li taglierebbe; con -3 dB tutto il DSD convertito suona 3 dB più piano (il volume lo compensa). 0 = nessun margine. Non vale per il DSD nativo né per il DoP. Pagine Audio e Stato | -3 |
| `RICAMPIONAMENTO`, `FILTRO` | `no`/`sincrono`/`asincrono`, `lineare`/`intermedio`/`minimo` | no, lineare |
| `FREQUENZA_MAX` | Hz, 0 = quella del DAC | 0 |
| `PAUSA_DSD_MS`, `PAUSA_FREQUENZA_MS` | pause per i DAC che perdono l'inizio; la pausa al cambio di frequenza non scende mai sotto il buffer ALSA | 500, 0 |
| `LIVENESS` | `si`: liveness applicativa nel demone dello stato (nessun processo in più). Lyrion deve rispondere a una richiesta JSON-RPC `serverstatus` entro `LIVENESS_LYRION_TIMEOUT` s; dopo `LIVENESS_LYRION_FALLIMENTI` fallimenti consecutivi viene riavviato. Se Lyrion dice "play" ma nessun PCM ALSA è RUNNING da `LIVENESS_PLAYER_SECONDI` s, il player risulta "bloccato" e Squeezelite viene riavviato. I riavvii hanno un backoff (da `LIVENESS_BACKOFF_MIN` a `LIVENESS_BACKOFF_MAX` s) e compaiono nel log, nella pagina Stato e in `stato.json` (`liveness`) | si, 8, 3, 20, 60, 900 |
| `NOME_RETE` | nome in rete (`http://NOME.local`) | sweetspot |
| `WIFI_NOME`, `WIFI_PASSWORD` | rete Wi-Fi, solo senza cavo | vuoto |
| `HOTSPOT`, `HOTSPOT_ATTESA`, `HOTSPOT_PROVA`, `HOTSPOT_PASSWORD` | hotspot di configurazione del primo avvio (vedi [sotto](#hotspot-di-configurazione-wi-fi)): `si`/`no`, secondi di attesa senza rete prima di accenderlo, secondi concessi alla rete scelta prima che riparta, password scelta da te (8-63 caratteri; vuoto = casuale a ogni accensione, mostrata sullo schermo) | si, 60, 40, vuoto |
| `IP_FISSO`, `GATEWAY`, `DNS` | indirizzo fisso, es. `192.168.1.50/24` | vuoto |
| `RISPARMIO_RETE` | risparmio energetico Ethernet (EEE) | no |
| `PROFILO` | `bilanciato`, `silenzio`, `prestazioni` | bilanciato |
| `USCITA_INTEGRATA` | usa la scheda audio del PC | no |
| `SCHERMO_MINUTI` | spegnimento dello schermo, 0 = mai | 2 |
| `PERIFERICHE_INUTILIZZATE` | `spente`: su qualunque computer, per classe di dispositivo e mai per modello. USB con sole interfacce smart card, video, Bluetooth/wireless (webcam, adattatori BT) scollegate dai driver (`authorized=0`), anche se collegate dopo l'avvio (regola udev). PCI inutilizzati a riposo quando inattivi (`power/control=auto`, e il ponte PCI sopra se porta solo a loro): scheda video che non mostra la console, audio integrato se `USCITA_INTEGRATA=no`, multimedia, modem, FireWire, lettore di schede, Wi-Fi senza `WIFI_NOME`, Bluetooth, schede di rete attive ma senza cavo né indirizzo (decise a rete su, da `S40sweetspot-net`, dopo qualche secondo per il collegamento: una scheda non ancora attivata non si tocca). Mai DAC, dischi, tastiere, hub o la rete in uso; `accese` lascia tutto com'è | spente |
| `WATCHDOG` | `si`: watchdog hardware (Intel iTCO, AMD SP5100, Raspberry Pi; i moduli del chipset sono caricati da `S21sweetspot-watchdog`, in blacklist solo con `no`; softdog se manca) alimentato ogni 5 s, tempo limitato al massimo del dispositivo (15 s sul Pi); un blocco totale fa ripartire il computer e, dopo un aggiornamento, la versione precedente; un riavvio causato dal watchdog è annotato nel registro (`bootstatus`) | si |
| `PASSWORD_WEB` | password delle pagine di Sweetspot (impronta MD5-crypt con sale; accesso da `/cgi-bin/accesso` con sessione: cookie HttpOnly e SameSite=Strict, 8 ore, ID casuale; dopo 5 errori di fila **dallo stesso indirizzo** si aspetta 30 secondi per ogni errore in più, fino a 15 minuti, e chi sbaglia non blocca gli altri; c'è anche un tetto globale, sei volte più alto, contro chi cambia indirizzo; ogni risposta porta `Content-Security-Policy: frame-ancestors`, `X-Frame-Options`, `X-Content-Type-Options` e `Referrer-Policy` (solo Audio, Stato e Accesso possono stare nel riquadro di Material, dalla porta 9000); senza sessione la copertina del CD risponde con un segnaposto e non con un errore; ogni azione richiede sessione e gettone anti-CSRF; il pulsante *Esci* chiude la sessione): vuota = pagine aperte nella rete di casa; si imposta e si toglie dalla pagina Sistema e vale subito; dimenticata: togliere la riga da `sweetspot.txt`. La conferma degli aggiornamenti (`/cgi-bin/vivo`) resta possibile con una chiave casuale di ogni avvio, solo per root. Anche senza password le pagine rispondono solo se l'indirizzo usato è quello del player (`NOME_RETE.local`, il nome breve, i suoi indirizzi IP, `localhost`), altrimenti 403: è la difesa dal DNS rebinding di un sito esterno. Lyrion (porta 9000) ha la sua protezione: vedi `LYRION_UTENTE`; Sweetspot tiene attiva la protezione CSRF di Lyrion al livello 1 (media, compatibile con Material Skin, iPeng e Squeezer; un livello 2 scelto da te resta). Nella pagina Sistema c'è anche *Ripristina le impostazioni iniziali* (`sweetspot-config ripristina`): musica, archivio e filtri restano | vuota |
| `LYRION_UTENTE`, `LYRION_PASSWORD` | utente e password di Lyrion quando lo si protegge dalle sue impostazioni (Avanzate > Sicurezza): Sweetspot li usa nelle richieste JSON (Basic) e nella CLI (`login`) per volume a 64 bit, precarico, pagine, prova DoP e impostazioni del player. Senza, con Lyrion protetto, tutto questo si ferma | vuoti |
| `SSH`, `SSH_PASSWORD` | accesso remoto per l'assistenza | no |
| `RENDERER_UPNP` | `si`: Sweetspot compare come diffusore UPnP/DLNA (MediaRenderer) per BubbleUPnP, JPlay, mconnect e simili; l'audio passa da Lyrion e dal player, vedi [Renderer UPnP/DLNA](#renderer-upnpdlna-in-entrata). Solo con `MODALITA=completa` | no |
| `SSH`, `SSH_PASSWORD`, `SSH_UTENTE` | accesso remoto per l'assistenza. `SSH_UTENTE` è `root` (predefinito) oppure `assistenza`, un utente senza privilegi (con `assistenza` il login di root è disattivato). Dalla pagina Sistema queste tre chiavi aprono il sistema come amministratore e si cambiano solo con la **conferma forte**: serve avere `PASSWORD_WEB`, riscriverla nel campo di conferma e un gettone monouso (valido 10 minuti) emesso da root; la verifica la fa l'helper privilegiato, non la pagina, e un tentativo sbagliato conta come un errore di accesso. Senza `PASSWORD_WEB` da web non si cambiano: si scrivono in `sweetspot.txt` con il computer | no |
| `HTTPS`, `HTTPS_REINDIRIZZA` | connessione protetta delle pagine (porta 443) con `stunnel` davanti all'httpd di BusyBox; certificato autofirmato creato al primo avvio con `HTTPS=si` e salvato sulla chiavetta (`sweetspot-https.pem`), impronta SHA-256 nella pagina Sistema. Con HTTPS il cookie di accesso è `Secure`. `HTTPS_REINDIRIZZA=si` fa rimandare a https le pagine richieste in chiaro (non `/cgi-bin/vivo` né le richieste dal computer stesso). Lyrion (porta 9000) resta in chiaro | no |
| `DIARIO`, `DIARIO_ORE`, `DIARIO_KB` | diario di bordo sulla chiavetta (cartella `diagnostica`): `si`/`no`; ogni quante ore (1-24, 2 predefinite) si salvano registro e timeline; dimensione massima in KB di ogni file prima della rotazione (256 predefiniti, tre generazioni). Vedi [Diagnostica](#diagnostica-registro-persistente-timeline-e-crash-dump) | si, 2, 256 |
| `OTTIMIZZAZIONI` | `no` per confronti alla cieca o problemi | si |
| `CORREZIONE` | `no`, `si`, `confronto` (pari volume, senza filtri) | no |
| `ARCHIVIO` | UUID/PARTUUID dell'archivio; nome nelle vecchie configurazioni se univoco | vuoto |
| `ARCHIVIO_CONDIVISO`, `ARCHIVIO_PASSWORD` | cartella di rete Musica | no, vuoto |
| `AGGIORNAMENTI_URL` | altra fonte degli aggiornamenti (API release di GitHub) | questo progetto |

I profili cambiano solo la frequenza della CPU: *silenzio* la fissa alla
minima, *bilanciato* a metà strada, *prestazioni* alla nominale tenendo i core
sempre svegli. Il Turbo è sempre spento.

## Diagnostica: registro persistente, timeline e crash dump

Il sistema gira in RAM e il registro di `/var/log` si perde a ogni riavvio.
Per non restare senza prove dopo un guasto (la reazione udev al DAC era stata
annullata proprio perché il registro di prima del riavvio non c'era),
`sweetspot-diario` conserva sulla chiavetta, nella cartella `diagnostica`:

| File | Contenuto |
|---|---|
| `sweetspot.log`, `.1`, `.2` | registro di sistema, solo le righe nuove aggiunte in coda |
| `timeline.log`, `.1`, `.2` | una riga per fatto: `DATA\|SORGENTE\|EVENTO\|DETTAGLI` (avvio, riavvii del player e di Lyrion anche della liveness, XRUN, cambi di frequenza, aggiornamenti, rollback, montaggi della chiavetta, spegnimento) |
| `kernel.ultimo` | ultime 300 righe del log del kernel all'ultimo salvataggio |
| `pstore/DATA/` | crash dump del kernel (panic, console) copiati da `/sys/fs/pstore` all'avvio, al massimo 8 raccolte |
| `pulito` | presente se l'ultimo spegnimento è stato ordinato; l'avvio successivo lo annota ("spegnimento precedente ordinato: no" = corrente tolta o blocco) |

- **Poche scritture**: si aggiunge solo il nuovo, ogni `DIARIO_ORE` ore e subito
  solo per gli eventi critici (aggiornamenti, rollback, riavvii dei servizi,
  spegnimento), al massimo una volta al minuto. Durante l'ascolto i salvataggi
  periodici aspettano (al massimo tre intervalli). Ogni file ruota a `DIARIO_KB`
  KB e restano tre generazioni, quindi lo spazio è limitato (circa 1,5 MB).
- **Montaggio**: la chiavetta si monta in scrittura solo per la durata della
  copia, con il conteggio condiviso degli altri servizi (`stick_mount`); lo
  spegnimento fa l'ultimo salvataggio (`S04sweetspot-diario stop`).
- **Crash dump**: il kernel ha pstore con console, `dmesg` al panic e ramoops.
  Sul Raspberry Pi la regione di memoria è riservata da `dtoverlay=ramoops`
  in `config.txt`; sul PC si usa efi-pstore (NVRAM UEFI), dove il firmware lo
  permette. Se né l'una né l'altra c'è, il registro persistente funziona
  comunque, ma dopo un panic non ci sono crash dump.
- **Limiti**: XRUN e cambi di frequenza si osservano ogni 5 secondi (un cambio
  più breve può sfuggire); l'ultima parte prima di un'interruzione di corrente
  non è sulla chiavetta se non c'è stato un evento critico dopo l'ultimo
  salvataggio. L'overlay `ramoops` e `CONFIG_EFI_VARS_PSTORE` vanno verificati
  su hardware.
- **Pacchetto diagnostico**: pagina **Sistema** → *Scarica il pacchetto
  diagnostico* (dietro l'accesso, se `PASSWORD_WEB` è impostata): un `tar.gz`
  con registro e timeline (persistenti e di questo avvio), crash dump, log di
  Squeezelite e del kernel, configurazione, versioni, `aplay -l`,
  `/proc/asound` e `stato.json`. Password, chiavi, token, credenziali negli
  indirizzi e intestazioni di autorizzazione sono oscurati.

## Verifiche

| Verifica | Come |
| --- | --- |
| Stato ALSA, formato e percorso configurato | *Impostazioni Sweetspot → Audio*, riquadro "Uscita audio": endpoint selezionato, substream e stato osservato; non confronta i campioni |
| Sistema in RAM, chiavetta non in uso | pagina di stato, voci "Sistema in RAM" e "Chiavetta" |
| Ottimizzazioni attive | pagina di stato: tutte le voci verdi |
| DSD nativo sul R26 | pagina di stato, voce "DSD": `nativo (u32be)` |
| Campioni, continuità e cambi di frequenza nel backend software | `tests/prova-lyrion.sh`: confronto completo PCM/DoP, incluse sorgenti DSF/DFF e sei transizioni PCM fra 44,1/48/96 kHz; [protocollo](docs/audio-verification.md) |
| Riconoscimento DoP del DAC | pagina Audio, "Prova DoP" (DAC senza DSD nativo), oppure `tools/genera-test-dop.py`: vedi sotto |
| Latenza real-time | `sweetspot-latenza 300` da terminale (Alt+F2 o SSH) a riproduzione ferma, obiettivo sotto 50 µs |
| Latenza durante l'ascolto | `LATENZA_ASCOLTO=si` in `sweetspot.txt`: finestre di 30 s a 100 risvegli al secondo sul core della riproduzione, solo mentre l'uscita suona; pagina di stato, massima e ultima finestra. Spenta in modo predefinito: il thread di misura (priorità 85) toglie pochi µs ogni 10 ms al player |
| XRUN della sessione | pagina di stato, "XRUN nella sessione": eventi e recuperi falliti dall'ultimo avvio del player; lo storico del registro resta come informazione. Zero eventi non esclude carenza di dati, errori DSP o altre interruzioni |
| Ascolto puro | pagina di stato, "Letture dal disco durante l'ascolto" e "Rete durante l'ascolto": settori letti dai dischi con la musica (`/sys/block/*/stat`) e byte di rete (`/proc/net/dev`, senza `lo`) dall'inizio dell'ascolto in corso o dell'ultimo, annotati da `sweetspot-ascolto` quando il DAC parte. Con il precarico finito le letture sono zero ("la musica suona dalla RAM"); la rete, in modalità completa, è solo il controllo dal browser e dalle app (sotto 2 KB/s), altrimenti streaming, cartelle di rete o precarico dalla rete |
| Interruzioni sul core audio | pagina di stato: IRQ dei dispositivi arrivati sul core della riproduzione nella sessione, uno per uno, e frequenza di quelle di sistema (timer, IPI) |
| Clipping della correzione | pagina di stato, "Clipping di CamillaDSP": campioni tagliati nella sessione |
| Underrun e picchi della correzione | pagina di stato, "Underrun di CamillaDSP" (righe "underrun" di `camilladsp.log` dall'inizio della sessione, contate dal player: CamillaDSP non li espone nel websocket) e "Picco di CamillaDSP" (massimo di sessione per canale, dal websocket) |
| Traffico durante l'ascolto | pagina di stato, "Traffico di rete ora"; read-ahead e streaming non garantiscono rete inattiva |
| Attività elettrica superflua | pagina di stato: "LED" (spenti tranne quelli della tastiera), "USB inutilizzate", "PCI a riposo" (ogni dispositivo con il suo stato reale: a riposo o attivo), "Lavoro differito del kernel" (workqueue non legate a un core solo sui core di sistema) e "Schermo" (stato DPMS dei connettori collegati e retroilluminazione). Le applica `sweetspot-silenzio` all'avvio, se le ottimizzazioni sono attive; è una riduzione di attività, non una misura del rumore analogico |
| Robustezza | CI (`tests/prova-robustezza-qemu.sh`, immagine x86 in QEMU): watchdog i6300ESB attivo, DAC USB emulato collegato, scollegato e ricollegato a caldo con il player che si ferma e riparte, blocco simulato (servizio del watchdog fermato) con riavvio automatico e player di nuovo attivo, file system della chiavetta integro dopo il riavvio brusco. Sull'hardware: `sweetspot-durata 24 &` con una playlist lunga in riproduzione, esito in `/run/sweetspot/durata.txt` e sulla chiavetta (nessun XRUN, nessun riavvio del player, uscita in riproduzione almeno il 95% del tempo, memoria calata meno del 10%); pagina di stato, voce "Watchdog" |
| Conversione PCM → DSD | non disponibile, per scelta: costo di CPU continuo e modulatore di qualità mancante; motivi e condizioni per riaprirla in [docs/pcm-dsd.md](docs/pcm-dsd.md) |
| Compatibilità | [Matrice di compatibilità](docs/compatibilita.md), generata solo dai rapporti reali: pagina di stato → *Scarica il rapporto di compatibilità* (`sweetspot-rapporto`: computer, CPU, schede di rete con driver, DAC con identificativo USB e firmware, esiti della pagina Stato e della prova di durata, senza indirizzi né dati personali), poi una segnalazione *Rapporto di compatibilità* su GitHub |
| Coda in RAM e dischi fermi | pagina di stato, voce "Precarico in RAM": brani caricati, MB usati sul budget, esclusioni e dischi in standby; `sweetspot-precarica residenza FILE` misura quanto di un file è in RAM |

### Prova di riconoscimento con il file DoP

Con un DAC USB che non dichiara il DSD nativo, `DSD=auto` fa convertire i file
DSD in PCM con Squeezelite (alla frequenza più alta che il DAC accetta, ad
esempio 176,4 kHz per DSD64 su un DAC da 192 kHz), senza provare il DoP. Molti DAC accettano
comunque il DoP: la pagina **Audio** propone la **Prova DoP**. Genera sul
player lo stesso file descritto sotto (`sweetspot-prova-dop`), lo fa suonare
per 6 secondi (con `playlist preview` di Lyrion: la coda di ascolto viene
messa da parte e torna com'era, ferma, quando si indica l'esito) e chiede
l'esito: se il DAC ha mostrato DSD/DoP e si è sentito il tono, imposta
`DSD=dop`; altrimenti non cambia nulla. La prova non parte con volume software
o a 64 bit, correzione ambientale o ricampionamento attivi, con l'uscita
forzata a 16 bit, né se il DAC non dichiara 176,4 kHz a 24 o 32 bit (i
marcatori DoP stanno nei bit alti dei campioni a 24 bit), perché l'esito non
sarebbe affidabile. Se il DAC non riconosce il DoP il tono diventa un fruscio
forte con una componente ultrasonica: volume dell'amplificatore basso.

Lo stesso file si può creare anche sul computer:

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
Sul PC i casi a frequenza costante si ripetono anche nel driver ALSA del kernel di
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
del clock audio. `sweetspot-alsa-misura [-c scheda] [-d dispositivo] [-t secondi]`
campiona `/proc/asound/cardX/pcmYp/sub0/status` e `hw_params` e riassume delay
massimo, avail minimo e XRUN: misura il margine del buffer, non il clock. Il
buffer ALSA parte conservativo (`BUFFER_ALSA_MS=400`, `PERIODI_ALSA=4`) ed è
modificabile in `sweetspot.txt`. Per riferimenti: [Daphile](https://www.daphile.com/index.html),
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
tests/diario.sh                       diario di bordo: timeline, registro persistente, pstore, bundle
tests/qemu-avvio.sh                   prova dell'immagine in QEMU (BIOS e UEFI)
tests/prova-lyrion.sh                 Lyrion avviato nel sistema compilato (CI, anche su ARM)
tests/renderer-upnp.py                renderer UPnP/DLNA: SSDP, descrittore, SOAP, eventi e riproduzione
tools/moduli-lyrion/                  prova dei moduli di Lyrion compilati per ARM
tools/genera-test-dop.py              file di prova bit-perfect
```

Basato su Buildroot 2026.08 e sul kernel LTS 6.18 con PREEMPT_RT: 6.18.56 sul
PC, il ramo rpi-6.18.y della Raspberry Pi Foundation sul Raspberry Pi.

## Licenza

GNU General Public License versione 3 o successiva. Vedi `LICENSE`.
