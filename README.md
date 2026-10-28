# Sweetspot

Player e server di musica liquida con uscita ALSA diretta, open source (GPLv3), pensato
come alternativa a Daphile: stesso motore (Lyrion Music Server con i suoi
plugin, Squeezelite come player), con un sistema costruito per far suonare il
DAC nel modo più pulito possibile. Gira su un PC (da una chiavetta USB o, dopo
l'installazione, dal disco interno) o su un Raspberry Pi 4 o 5 (dalla scheda
SD), copia tutto in RAM e si usa dal browser del telefono o del computer.

Interfaccia e documentazione sono solo in italiano; un piano per la localizzazione è in `docs/localizzazione.md`.

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
   minuti) e la pagina Stato avvisa. Se il ripristino all'avvio non riesce,
   un marcatore in RAM (`dati.ripristino-fallito`) blocca salvataggio e
   checkpoint: la copia buona sulla chiavetta (valutazioni e statistiche
   comprese) non viene sovrascritta da una RAM vuota. Lo stesso vale se
   all'avvio la chiavetta non si monta e compare più tardi con dati già
   salvati: basta riavviare per ripristinarli. Il blocco cade da solo a
   un ripristino riuscito, o a mano con `sweetspot-dati sblocca` /
   `sweetspot-dati salva --forza`. Il rallentamento usa un cgroup v2 (`cpu.max` 5%,
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
   `ionice` idle) e bloccati in RAM (`mlock`), entro il budget unificato che
   riserva memoria a sistema, servizi e buffer del player. Nel capitale
   rientrano solo i file caricati con successo, non quelli soltanto pianificati.
   Quando tutti i file previsti risultano caricati, i dischi meccanici che li
   contengono vanno in standby; lo stato mostrato è quello vero (`hdparm -C`):
   un disco svegliato da altro esce dall'elenco e si riprova a fermarlo dopo
   un minuto. Con la coda invariata il piano non si ricalcola (niente `stat`
   sulle cartelle di rete a ogni giro). Lo streaming non si precarica, i file
   oltre `PRECARICO_FILE_MAX_MB` restano sul disco e la pagina Stato mostra
   brani caricati, memoria usata, esclusioni e dischi fermi. Le righe `#inizio-fine`
   dei brani CUE contano come il loro file (letto una volta sola) e la coda si
   legge a pagine da 500. Il caricatore non tronca il manifest a 4096 file;
   lo stato viene aggiornato durante il caricamento e al completamento.

## Come si usa

Dal telefono o dal computer apri `http://sweetspot.local/` (oppure l'indirizzo
che compare sullo schermo): dopo l'accesso si apre **Reference Studio**
(`/cgi-bin/studio`), l'interfaccia musicale di Sweetspot: home, album con
filtri e paginazione, artisti, ricerca, dettaglio album, riproduzione con
seek e volume, coda, playlist, scelta del player e delle zone, percorso audio
e collegamento alle impostazioni. È un frontend statico leggero (JS e CSS
senza dipendenze esterne) che legge i dati veri di Lyrion attraverso una CGI
autenticata con sessione e gettone anti-CSRF, e un elenco chiuso di comandi
in sola lettura/riproduzione (`sweetspot-priv`); non sostituisce il server e
non interroga il percorso audio con polling pesante (stato ogni 5 s a scheda
visibile, tempo interpolato in locale). Responsive da 320 px in su, con
tastiera ed etichette. Le copertine passano da `/cgi-bin/studio-copertina`.

L'interfaccia **Material** di Lyrion resta raggiungibile dal collegamento
*Material* e come ripiego. Per aprirla di default imposta
`INTERFACCIA_ASCOLTO=material` in `sweetspot.txt` (predefinito: `studio`);
nessuna preferenza esistente viene cancellata. Funzionano anche le app per
Lyrion (iPeng, Squeezer, Material) e gli altri player Squeezebox della casa.
Il frontend è provato con Lyrion e `sweetspot-priv` simulati
(`tests/reference-studio.py` e prove in browser a 320, 390, 768 e 1440 px) e,
lato server, con un Lyrion vero: `tests/prova-studio-lyrion.sh` (job
`studio-lyrion` della CI) avvia il container ufficiale Lyrion 9.1.1, una
libreria generata (FLAC sintetici, due album, una copertina incorporata) e
un player finto (squeezelite con scheda audio simulata a tempo reale) e fa
girare le vere CGI `studio-api.json` e `studio-copertina` con la vera
`sweetspot-lms`: elenchi di album, artisti, generi, brani, cartelle e player,
ricerca (anche con accenti e più parole), copertine JPEG, e i comandi al
player (carica/aggiungi, play, pausa, stop, avanti, indietro, salta, togli,
svuota, volume, posizione, zona) verificati sullo stato reale del player.
Non coperti: la separazione di utenti di `sweetspot-priv` (nella prova è un
passacarte), Lyrion protetto da password, la pagina `studio.js` in un
browser contro il Lyrion vero, e l'audio su hardware.

L'aspetto **Reference Studio** usa grafite, blu e controlli leggibili su
telefono, tablet e computer. Le impostazioni SweetSpot hanno la stessa
identità visiva della skin musicale: navigazione laterale sugli schermi ampi
e navigazione compatta a scorrimento sugli schermi piccoli. Il tema non
introduce dipendenze da font o CDN esterni.

Per Material vengono installati il tema **Reference-Studio** e il colore
omonimo attraverso il supporto ufficiale ai temi utente, senza modificare
il plugin. Sono i predefiniti quando non sono state salvate altre scelte.
Le preferenze esplicite, anche quelle già memorizzate nel browser, restano:
per applicare il nuovo aspetto a un client già personalizzato seleziona
tema e colore Reference-Studio nelle impostazioni dell'interfaccia Material.
I file di questo tema sono gestiti da SweetSpot; gli altri temi e colori
personalizzati non vengono modificati.

Nel menu di Material, **Impostazioni Sweetspot** apre le sezioni, come su
Daphile.

Audio e Stato possono restare nel riquadro di Material. I collegamenti alle
altre impostazioni, compresa la correzione ambientale, aprono la pagina completa:
le protezioni contro l'incorporamento da siti esterni restano attive.

| Sezione | Cosa contiene |
| --- | --- |
| **Audio** | DAC riconosciuto, formato aperto sul DAC e configurazione del percorso (l'integrità dei campioni richiede una prova dedicata), volume (fisso, del DAC, software), DSD, ricampionamento facoltativo con scelta del filtro, **correzione ambientale** con REW, opzioni per esperti (buffer, periodi, pause) |
| **Musica** | stato della libreria, dischi trovati (escludi/includi), cartelle di rete (aggiunta con prova di accesso) |
| **Archivio** | il disco dove Sweetspot scrive: copia di cartelle da altri dischi e dal NAS, cartella di rete **Musica** per copiare dal PC o dal Mac, **copia dei CD** |
| **Plugin** | streaming (Qobuz, TIDAL, Spotify, Deezer, Bandcamp, YouTube), radio (Radio Paradise in FLAC, Radio Browser, radio.net), collegamenti (AirPlay in ingresso, UPnP/DLNA, Chromecast, gruppi): installazione con un clic dal repository ufficiale |
| **Rete** | schede di rete, Wi-Fi (scelta tra le reti vicine), indirizzo fisso, nome in rete |
| **Sistema** | nome, modalità, profilo del processore, modalità ascolto, renderer UPnP/DLNA, SSH, **aggiornamenti**, **installazione sul disco interno** o **accanto a Windows**, riavvio e spegnimento |
| **Stato** | tutte le ottimizzazioni con un pallino verde o arancione, interruzioni dell'audio, traffico di rete, e la prova dell'ascolto puro: letture dal disco e byte di rete dall'inizio dell'ascolto. Non rifà i controlli a ogni visita: legge la cache del demone a eventi `sweetspot-stato` (core di sistema, `nice 19`), che la aggiorna quando succede qualcosa (CLI di Lyrion, udev per sound/block/net, inotify sulla configurazione), quando qualcuno la legge ed è più vecchia di 10 secondi (40 durante l'ascolto) e come battito di sicurezza ogni 15 minuti; a riposo non lancia processi (meno di 100 fork al minuto in tutto il sistema, misurati da `tests/forks-riposo.sh`; gli altri cicli di servizio attendono con `read -t` su una FIFO senza scrittori (`nap` in `common.sh`) invece di `sleep`, e a riposo, con il DAC fermo, la sorveglianza del player gira ogni 60 s, la sonda Bluetooth ogni 5 s (30 s senza adattatore) e il diario ogni 30 s; mentre il DAC riproduce i ritmi di prima restano). Avvisa se è assente o vecchia. Lo stesso stato in JSON, in sola lettura: `/cgi-bin/stato.json` (protetto da `auth_gate` di `web.sh`, come ogni pagina: senza sessione risponde 401; `httpd.conf` contiene solo la regola di `vivo`) e, da Lyrion o Material via JSON-RPC, `["sweetspot","stato"]` |

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
  frequenza di ogni brano. Un'**unica istanza per sessione**: la avvia il
  player (non il thread real-time di Squeezelite), sui core di sistema, con i
  campioni da una pipe (`/run/sweetspot/camilladsp.fifo`, aperta in lettura e
  scrittura, quindi senza fine del file tra un brano e l'altro). Il plugin ALSA
  *cdsp* (patch `package/alsa-cdsp/0002-session-mode.patch`) scrive nella pipe
  e, a ogni cambio di frequenza, chiede al websocket di CamillaDSP
  (`SetConfigFilePath` e `Reload`) la configurazione di quella frequenza,
  `camilladsp-FREQUENZA.yml`, scritta da `sweetspot-dsp`: il processo (e il suo
  PID) resta lo stesso, cambia solo la frequenza sul DAC. A fine stream il
  plugin scrive il silenzio della coda dei filtri (`extra_samples`) fino a un
  blocco intero, così il suono ancora dentro i filtri arriva al DAC. Se
  CamillaDSP muore il player lo riavvia. Il DAC resta aperto da CamillaDSP per
  tutta la sessione, anche tra un brano e l'altro. I suoi **thread audio**
  (cattura dalla pipe, elaborazione, riproduzione ALSA) stanno sul core
  dedicato all'audio con priorità real-time sotto il player (`SCHED_FIFO`,
  `PRIORITA_DSP`, 70, sotto il player a 80 che lo alimenta), per ruolo: la
  riproduzione al DAC ha la più alta (70), l'elaborazione una in meno (69),
  la cattura due in meno (68), così il thread che serve il DAC non è mai più
  basso di quello che lo alimenta. La misura della latenza in ascolto
  (`LATENZA_ASCOLTO=si`, cyclictest) gira un gradino sotto il player (79), mai
  sopra. Gli altri (principale, segnali, websocket e le connessioni di
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
  chiavetta, **uno per ogni frequenza di campionamento** con la frequenza nel
  nome: `fir-44100.wav`, `fir-48000.wav`, `fir-96000.wav`... (un file per i due
  canali: mono per entrambi, stereo canale 0 al sinistro e 1 al destro) oppure
  `fir-sinistro-44100.wav` e `fir-destro-44100.wav` (il destro senza file usa il
  sinistro). I nomi `fir-sinistro.wav` e `fir-destro.wav`, senza frequenza,
  valgono per la frequenza scritta nel file. Mono o stereo, fino a 16 MB; la
  frequenza del file deve essere quella del nome, e a ogni frequenza i due
  canali hanno gli stessi canali. Si applicano dopo i filtri di REW, con la
  correzione accesa. Ogni brano usa il FIR della sua frequenza: CamillaDSP
  lavora a quella frequenza e **non ricampiona**. Le frequenze del DAC senza
  FIR seguono `CORREZIONE_SE_ASSENTE`: `blocca` (predefinito) non le offre a
  Squeezelite, quei brani non suonano e lo Stato e la pagina Correzione
  elencano le frequenze (`avviso` in `dsp.stato`); `diretto` le suona senza
  FIR (solo filtri di REW e attenuazione), con lo stesso avviso. Solo con
  `FIR_RICAMPIONA=si` il brano si ricampiona al FIR più vicino, di preferenza
  della stessa famiglia 44,1/48 kHz (ricampionatore `Synchronous`). Con i soli
  FIR a frequenze che il DAC non accetta la correzione non si applica (vale la
  politica). Attenuazione in
  più `FIR_MARGINE_DB` (3 dB): i FIR di rePhase e Acourate sono di solito già
  normalizzati, la voce "Clipping di CamillaDSP" della pagina Stato dice se
  basta. La coda di ogni brano non viene tagliata: quando lo stream si chiude
  (stop, cambio di frequenza, pausa lunga) CamillaDSP legge ancora tanti
  campioni di silenzio quanti i tap del FIR di quella frequenza più due
  blocchi (`extra_samples`), così il suono ancora dentro i filtri arriva al
  DAC.
- **Confronto a pari volume**: "esclusa" passa per CamillaDSP con la sola
  attenuazione, così il confronto con la correzione accesa non è falsato dal
  volume.
- Il DSD diventa PCM mentre la correzione è accesa.
- I filtri restano sulla chiavetta, nella cartella `correzione-ambientale`
  (testo di REW, leggibile anche dal computer). Il salvataggio prepara e verifica
  una nuova generazione prima di pubblicarla; i FIR esistenti sono conservati.
  Salvataggio e ripristino includono anche tutti i FIR con la frequenza nel
  nome; la copia in RAM resta leggibile dal pannello senza concedergli scrittura.
  La generazione precedente resta in `correzione-ambientale.vecchio` e viene
  usata all'avvio se un'interruzione ha lasciato assente la cartella principale.
  Se la chiavetta manca o la scrittura fallisce, il pannello avvisa che i nuovi
  filtri valgono solo fino al riavvio. Un errore nella preparazione in memoria
  lascia invece invariati i filtri precedenti, senza riavviare il player.

### Bluetooth come sorgente

Un telefono può suonare su Sweetspot (A2DP sink). È **spento di serie**: si
accende nella pagina *Bluetooth* (o con `BLUETOOTH=si` in `sweetspot.txt`;
`BLUETOOTH_NOME` cambia il nome che vede il telefono). L'abbinamento si apre
dalla pagina per 2, 5 o 9 minuti: fuori dalla finestra Sweetspot non si fa
trovare e non accetta telefoni. La pagina elenca i dispositivi abbinati (con
*Rimuovi*) e *Stato* mostra se il servizio aspetta, è in abbinamento o suona.
Gli abbinamenti si conservano sulla chiavetta (`sweetspot-dati/bluetooth.tar`).

Scelta di integrazione: **passaggio esclusivo**. Quando il telefono comincia a
trasmettere, il player si ferma e `bluealsa-aplay` suona sul DAC con l'uscita
`hw:` diretta, senza mixer né secondo clock; quando il telefono smette, il DAC
torna al player. Non c'è un ingresso nativo in Lyrion (servirebbe un plugin) e
un loopback ALSA aggiungerebbe un dominio di clock e un ricampionamento. Limiti:
la musica di Lyrion si ferma mentre suona il telefono e va ripresa a mano;
l'audio è SBC (compresso), AAC richiede fdk-aac (licenza non libera), aptX e
LDAC non sono in Buildroot; sul PC servono un dongle USB e, per alcuni modelli,
il suo firmware. Il Bluetooth gira solo sui core di sistema, mai su quello
isolato dell'audio né sulle sue interruzioni.

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
per copiare la musica, con la **firma SMB obbligatoria** (`ARCHIVIO_FIRMA=si`,
predefinito; i client SMB1 non si collegano comunque). La **cifratura SMB3**
(`ARCHIVIO_CIFRATURA=si`) è opzionale e spenta di default: pesa sulla CPU e
esclude i client senza SMB3 (Windows 7, vecchi NAS). **Senza password** è
aperta agli ospiti ma in **sola lettura**, senza firma obbligatoria (l'ospite
non può firmare). Il server lavora come utente `nas`, non come root, e non mostra i
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

**Privacy.** Durante la lettura e la copia Sweetspot contatta, sempre in
HTTPS: `musicbrainz.org` e `coverartarchive.org` (titoli e copertina; ricevono
l'identificativo del disco) e `www.accuraterip.com` (verifica; riceve l'indice
del disco). Per non contattarli, in `sweetspot.txt` imposta
`CD_CERCA_TITOLI=no` e/o `CD_ACCURATERIP=no` (predefiniti `si`). La copia
funziona lo stesso: titoli generici ("Traccia 1"...), nessuna copertina,
nessuna verifica AccurateRip né ricerca automatica della correzione del
lettore (il registro lo segnala).

Le tracce esistenti **non vengono sovrascritte**: un conflitto interrompe la
copia prima di leggere il CD e viene segnalato nella pagina Archivio. Per
una nuova copia scegli un nome album diverso. Ogni FLAC viene codificato con
verifica in una cartella temporanea dello stesso filesystem e pubblicato solo
quando completo; anche un file comparso durante la codifica viene preservato.
Copertina e rapporti precedenti non vengono sovrascritti. Un errore di scrittura
non viene contato come una traccia copiata e verificata.

### Installazione sul disco interno

*Sistema → Installazione sul disco interno*, come su Daphile: si sceglie il
disco (viene mostrato cosa contiene, e va confermato che sarà cancellato).
Sweetspot crea una partizione di sistema da 4 GB (FAT32, `SWEETSPOT`) e, se si
vuole, usa il resto del disco come archivio musicale (ext4). Copia la versione
in uso con impostazioni, plugin e libreria: si spegne, si toglie la chiavetta e
il computer parte dal disco, con BIOS o UEFI. Il sistema continua a girare
tutto in RAM; la chiavetta resta valida come copia di riserva.

### Installazione accanto a Windows

*Sistema → Installazione accanto a Windows* lascia il disco com'è: Sweetspot
aggiunge solo una partizione da 4 GB (FAT32, `SWEETSPOT`, tipo "dati di base", nascosta a Windows)
nello **spazio non allocato** e una voce "Sweetspot" nel menu di avvio UEFI. Le
partizioni che ci sono già non vengono né spostate né ridimensionate.

1. In Windows: *Gestione disco* → tasto destro sul volume `C:` → *Riduci
   volume*, almeno 4096 MB. Lo spazio liberato resta "Non allocato" (non
   serve creare un volume). Con BitLocker attivo tieni a portata di mano la
   chiave di ripristino: disattivare il Secure Boot e avviare Windows dal
   menu di Sweetspot (GRUB in catena) cambiano le misure del TPM (PCR 4 e 7) e
   Windows può chiederla. Avviando Windows dal menu di avvio del computer
   (voce "Windows Boot Manager") il percorso di avvio resta quello originale.
   La voce "Sweetspot" viene messa prima nell'ordine di avvio, quindi non
   è Windows la voce predefinita. La partizione `SWEETSPOT` è nascosta e senza
   lettera in Windows (attributi GPT 62 e 63).
2. Nel BIOS/UEFI: **Secure Boot disattivato**, come per la chiavetta.
3. Si avvia la chiavetta **in modalità UEFI**; nella pagina Sistema compaiono i
   dischi GPT con almeno 4 GB liberi. Si conferma scrivendo la dimensione del
   disco e la password delle pagine.
4. Si spegne, si toglie la chiavetta e si riaccende: parte il menu di
   Sweetspot, con la voce **Windows** in fondo quando sul computer c'è il boot
   manager di Windows (`\EFI\Microsoft\Boot\bootmgfw.efi` in una qualunque
   partizione).

Requisiti e limiti: disco GPT (i dischi MBR non vengono proposti) e avvio UEFI;
dischi con almeno 4 GB liberi in un unico blocco. Prima di scrivere, Sweetspot
salva una copia della tabella delle partizioni e, se un passo successivo non
riesce, la rimette com'era. La libreria e le impostazioni restano nella
partizione di Sweetspot; l'archivio musicale si può mettere nello spazio
libero rimasto (*Archivio musicale*).

Se all'accensione parte direttamente Windows (alcuni firmware, o un
aggiornamento di Windows, rimettono primo il boot manager di Windows): dal
menu di avvio del computer (F12, F11, F8 o Esc a seconda del modello) si
sceglie *Sweetspot*, oppure lo si rimette primo nell'ordine di avvio del
BIOS/UEFI. Da Windows (prompt dei comandi come amministratore) la voce si
rimette prima così:

```
bcdedit /enum firmware
bcdedit /set {fwbootmgr} displayorder {ID-DI-SWEETSPOT} /addfirst
```

Se il firmware non ha accettato la voce (la pagina lo dice a fine
installazione), la si crea da Windows: la partizione di Sweetspot compare in
Esplora risorse con una lettera, per esempio `D:`.

```
bcdedit /copy {bootmgr} /d Sweetspot
bcdedit /set {ID-STAMPATO} device partition=D:
bcdedit /set {ID-STAMPATO} path \EFI\BOOT\BOOTX64.EFI
bcdedit /set {fwbootmgr} displayorder {ID-STAMPATO} /addfirst
```

Per togliere Sweetspot: *Gestione disco* → elimina il volume `SWEETSPOT` (lo
spazio torna non allocato e si può riassegnare a `C:` con *Estendi volume*) e
`bcdedit /delete {ID-DI-SWEETSPOT}` per la voce di avvio.

**Mac con processore Intel**: il disco interno è GPT e il firmware è UEFI, ma
macOS usa APFS e la sua partizione non lascia spazio libero da sola: va
liberato prima con *Utility Disco* (ridurre il contenitore APFS). All'accensione
si tiene premuto **Option (⌥)** e si sceglie *EFI Boot*. Sui Mac con chip T2
serve *Utility Sicurezza Avvio* → "Nessuna sicurezza" e "Consenti l'avvio da
supporti esterni". Il menu di Sweetspot non offre macOS: si sceglie dal menu
Option. I Mac con chip Apple (M1 e successivi) non sono supportati.

Provato in QEMU con firmware UEFI (OVMF) e un SSD NVMe preparato come lo lascia
Windows (`tests/prova-accanto-qemu.sh`); non ancora su un PC o un Mac veri.

### Aggiornamenti

*Sistema → Cerca aggiornamenti* controlla le release di GitHub; senza internet
basta copiare il pacchetto `sweetspot-x86_64-aggiornamento.tar` (sul
Raspberry Pi `sweetspot-rpi-aggiornamento.tar`) su un disco
collegato o nella cartella di rete Musica. Sulla partizione di sistema ci sono
**due copie del sistema**: l'aggiornamento si scrive in quella non in uso
(controllato con SHA-256), poi GRUB la avvia **una volta sola**. Se il nuovo
sistema arriva in fondo all'avvio e risponde dalla rete (una scheda con
indirizzo e collegamento, oppure l'hotspot acceso), diventa quello in uso; se non
parte (il kernel si ferma, riavvio automatico dopo 10 secondi) riparte da solo
quello di prima e la pagina Sistema lo segnala. La versione precedente resta
installata: si torna indietro con un clic. Viene sostituita solo quando il
nuovo pacchetto è scaricato e verificato; se sulla chiavetta non c'è posto per
tutti e due, la pagina Sistema lo dice e chiede di cancellarla prima.

**Niente downgrade per sbaglio**: prima di installare, la versione del
pacchetto (formato di `git describe`, es. `v1.2.3` o `v1.2.3-5-gabcdef`) si
confronta con quella in uso (`/etc/sweetspot-version`). Un pacchetto più
vecchio, anche se firmato, è rifiutato: potrebbe contenere falle note. Per
installarlo comunque si spunta *Consenti una versione più vecchia* nel modulo
del pacchetto da disco (insieme alla conferma con la password) o si usa
`sweetspot-aggiorna file-downgrade PACCHETTO`. La stessa versione è ammessa
(reinstallazione); una versione non confrontabile (compilazione di sviluppo)
non blocca. L'aggiornamento scaricato da GitHub (`scarica`) non ha l'opzione:
installa sempre l'ultima release.

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
controllato in due tempi. Prima dell'estrazione si ispeziona l'elenco del tar:
solo file previsti, senza collegamenti, dispositivi, percorsi esterni o membri
ripetuti. Poi si estrae in una cartella temporanea e lì si verifica che il
manifesto (`SHA256SUMS`, con la firma) copra tutti i file estratti, nessuno in
più e nessuno mancante; solo allora il pacchetto viene accettato. Per un aggiornamento serve
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

### Media server UPnP/DLNA

Con `SERVER_UPNP=si` (pagina Sistema, spento di serie) la libreria compare come
archivio (MediaServer) negli streamer e nei DAC di rete che leggono i file da
soli: per esempio un Gustard con streamer integrato, guidato da BubbleUPnP,
mconnect o dall'app del produttore. Il PC con i dischi puo' stare in un'altra
stanza e il DAC accanto all'impianto, senza altri apparecchi in mezzo.

Il server e' MiniDLNA (`sweetspot-mediaserver`, avviato da
`S71sweetspot-mediaserver`): i file partono cosi' come sono, mai convertiti, e
DSF e DFF arrivano al renderer in DSD alla frequenza del file (fino a DSD512, se
il renderer li accetta in rete: lo dice il display del DAC). In questo percorso
Lyrion, il player e la correzione ambientale non intervengono: il suono lo fa
il renderer. Gira senza privilegi (utente `dlna`), sui core di sistema con la
priorita' piu' bassa e non viene mai sospeso dalla modalita' ascolto, per non
interrompere uno stream in corso. Lo stato e' in Stato ("Media server
UPnP/DLNA").

Il database sta in RAM e si ricostruisce a ogni avvio; dischi e cartelle di
rete collegati dopo entrano da soli. Limiti: i file aggiunti alle cartelle di
rete da altri computer compaiono dopo aver spento e riacceso il server dalla
pagina Sistema; con librerie molto grandi il database occupa qualche decina di
MB di RAM; serve `MODALITA=completa`.

### Servizi in streaming e ingressi: stato e qualificazione

"Disponibile come plugin" non significa "integrazione verificata". La pagina
**Plugin** installa dal repository ufficiale di Lyrion i plugin del catalogo
(`usr/share/sweetspot/plugin-consigliati.txt`); SweetSpot non li sviluppa e,
a oggi, nessuno è stato qualificato con un account reale.

| Servizio o ingresso | Plugin | Stato | Limiti noti |
| --- | --- | --- | --- |
| Qobuz, TIDAL | `Qobuz`, `TIDAL` | disponibile come plugin; integrazione non verificata | Serve l'abbonamento. Il formato massimo dipende dal piano e dal plugin. |
| Spotify / Spotify Connect | `Spotty` | disponibile come plugin; non verificato | Serve Premium. Usa un programma ausiliario compilato per l'architettura. |
| Radio (Radio Paradise, Radio Browser, radio.net) | `RadioParadise`, `RadioBrowser`, `RadioNet` | disponibile come plugin; non verificato | Dipendono dal servizio remoto. |
| AirPlay in ingresso | `ShairTunes2W` | disponibile come plugin; non verificato | AirPlay 2 non dimostrato. |
| UPnP/DLNA verso altri diffusori | `UPnPBridge` | disponibile come plugin; non verificato | Invia a renderer esterni: non rende SweetSpot un renderer. |
| UPnP/DLNA in ingresso | integrato (`RENDERER_UPNP=si`, vedi sopra) | su main, di serie spento; coperto dalla CI, non provato con app reali | Un'app alla volta; l'audio passa da Lyrion. |
| Libreria verso streamer e DAC di rete | integrato (`SERVER_UPNP=si`, MiniDLNA, vedi sopra) | di serie spento; coperto dalla CI, non provato con renderer reali | DSF/DFF inviati senza conversione: il DSD in rete dipende dal renderer. |
| Chromecast, AirPlay verso altri diffusori, gruppi | `CastBridge`, `RaopBridge`, `Groups` | disponibile come plugin; non verificato | La sincronia fra più uscite non è dimostrata. |
| RAAT / Roon | assente | non supportato | Roon Ready richiede l'SDK e la certificazione ufficiali di Roon Labs. |
| WASAPI / CoreAudio | non applicabile | fuori ambito | SweetSpot è un'appliance Linux con ALSA diretto. |

**Architetture.** Le immagini sono per x86_64 e aarch64 (Raspberry Pi 4/5).
I programmi inclusi in Lyrion (`Bin`) e quelli dei plugin sono presenti per
`x86_64-linux` e `aarch64-linux`; ARM a 32 bit (armv7) non è un target e un
plugin con binari solo armv7 non funziona.

**Checklist di qualificazione** (per ogni servizio, annotare esito e data):

1. Account: il piano richiesto è attivo e il plugin lo riconosce.
2. Autenticazione: accesso dal pannello di Lyrion e permanenza dopo un riavvio.
3. Riconnessione: ripresa dopo scollegamento della rete e dopo la sospensione del servizio.
4. Formati massimi: frequenza e profondità effettivamente aperte sull'uscita ALSA (pagina Audio), non quelle dichiarate dal servizio.
5. Gapless: transizione fra due brani consecutivi dello stesso album, senza interruzioni.
6. Volume: livello fisso senza DSP, se non richiesto.

Una riga passa a "verificato" solo con questi sei esiti in un rapporto
pubblico (vedi la [matrice](docs/compatibilita.md)).

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
  (6.18, la stessa di Raspberry Pi OS) con PREEMPT_RT e pagine da 4 KB,
  uguale per il Pi 4 e il Pi 5. Firmware dall'ultima release della Raspberry Pi
  Foundation; gli overlay delle schede DAC li compila il kernel stesso.
  Programmi compilati per Cortex-A72, che girano identici sul Cortex-A76 del
  Pi 5. Due core su quattro dedicati a riproduzione e interruzioni USB,
  frequenza fissa, nessuno stato di risparmio della CPU (`cpuidle.off=1`).
- **Uscite spente**: jack e HDMI audio (`dtparam=audio=off`), Bluetooth
  Wi-Fi se non configurato. Il Bluetooth integrato non è disabilitato nel
  firmware ma il servizio è spento di serie (vedi *Bluetooth come sorgente*).
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

**Cambiare rete Wi-Fi dopo il primo avvio**: con l'hotspot spento la pagina
Rete mostra *Reti Wi-Fi vicine* se c'è una scheda Wi-Fi (anche senza modalità
AP). **Cerca le reti** accende la radio per la ricerca (e la rispegne se il
Wi-Fi non è configurato); scelta la rete e scritta la password, **Collega** la
salva e collega subito la scheda, senza riavviare. Con la stessa rete già
salvata e la password vuota resta quella salvata. Se entro `HOTSPOT_PROVA`
secondi la rete non risponde e non c'è il cavo riparte la sorveglianza, quindi
dopo `HOTSPOT_ATTESA` secondi l'hotspot.

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
| `INTERFACCIA_ASCOLTO` | `studio` (Reference Studio) o `material`: pagina aperta da *Ascolta* e dalla home | studio |
| `SERVER` | solo modalità player: indirizzo di Lyrion, vuoto = ricerca automatica | vuoto |
| `MODALITA_ASCOLTO` | `si`, `no`: mentre la musica suona lettura della libreria, copie e ripping restano sospesi. Nella pagina Sistema un'unica scelta, che vale subito: *ascolto puro* (questa più `PRECARICO=si`: coda in RAM e dischi fermi), *lavori sospesi* (`PRECARICO=no`) o *spenta*; la pagina Stato, voce "Ascolto", dice quale è attiva e quanti lavori sono sospesi ora | si |
| `PRECARICO` | `si`, `no`: coda di ascolto in RAM | si |
| `PRECARICO_MB` | `auto` (metà della memoria libera, tolti i buffer di Squeezelite ancora da riempire) o MB; mai oltre la memoria libera meno quei buffer e 256 MB | auto |
| `PRECARICO_FILE_MAX_MB` | file più grandi letti dal disco | 1024 |
| `PRECARICO_STANDBY` | `si`, `no`: dischi meccanici in standby a coda caricata | si |
| `LYRION_MEM_MB`, `SCANNER_MEM_MB` | tetto di memoria (cgroup v2: `memory.max`, con `memory.high` all'85%) di Lyrion e del suo scanner: MB o `auto` (70% e 40% della RAM). Il tmpfs scritto da Lyrion (database della libreria) conta nel suo tetto | auto |
| `ARTWORK_RAM_MB` | cache delle copertine in RAM, in un tmpfs a parte con `size=`, quando non c'è l'archivio musicale: MB o `auto` (4% della RAM, tra 32 e 256 MB). Piena, la pagina Stato avvisa e le nuove copertine non si salvano | auto |
| `CACHE_COPERTINE` | dove tenere la cache delle copertine di Lyrion: `auto` (archivio musicale se c'è, altrimenti RAM), `ram` (tmpfs con tetto `ARTWORK_RAM_MB`, i dischi non si svegliano), `archivio`, `disco` (un altro disco scrivibile indicato in `CACHE_COPERTINE_DISCO`). Al cambio la cache si sposta con una copia e solo a copia riuscita si toglie l'originale; se il disco manca o non è scrivibile si ripiega in RAM e la pagina Sistema/Stato lo dichiara. Vale dal prossimo avvio; `sweetspot-lms copertine` mostra posizione, tetto e MB usati | auto |
| `CACHE_COPERTINE_DISCO` | nome (come in `/media`) del disco per `CACHE_COPERTINE=disco` | vuoto |
| `CACHE_COPERTINE_MB` | tetto della cache sul disco, in MB: oltre il tetto la cache si azzera e si ricostruisce | auto (1024) |
| `DISCHI`, `ESCLUDI_DISCHI` | dischi locali, nomi da escludere | si, vuoto |
| `CONDIVISIONE_n`, `_UTENTE`, `_PASSWORD`, `_SMB1` | cartelle di rete (fino a 9): `//server/cartella` (SMB) o `nfs://server/cartella` (NFS); `_SMB1=si` ammette SMB1, insicuro | vuoto |
| `DAC` | DAC principale: `auto` (il primo DAC USB trovato; con le zone resta lui per tutto l'avvio), nome ALSA (es. `R26`) o `VID:PID`. Nella pagina Audio si sceglie tra i DAC collegati | auto |
| `ALTRI_DAC` | `si`: ogni altro DAC USB con un'uscita ha il suo Squeezelite, cioè un player separato in Lyrion ("Sweetspot - nome del DAC", MAC stabile per DAC da identificativo USB e numero di serie), da raggruppare e sincronizzare in Lyrion. Il DAC principale resta com'è (core isolato, correzione, volume a 64 bit); gli altri suonano sui core di sistema con priorità un po' più bassa, uscita diretta, mixer a 0 dB e volume da Lyrion. Si avviano e fermano da soli con il collegamento del DAC, anche mentre il DAC principale manca: se il principale si spegne il player lo aspetta e non passa mai a una zona; pagina Stato, voce "Altri DAC (zone)" | no |
| `VOLUME` | `fisso`, `dac`, `software` (Squeezelite arrotonda con dither TPDF, patch 0006, senza troncare: non bit-perfect, peggiore del fisso, segnalato in Audio e Stato), `dsp`: volume a 64 bit in CamillaDSP con dither TPDF alla risoluzione del DAC (24 o 16 bit, sempre presente, anche al 100%: per il percorso bit-perfect scegli `fisso`); Squeezelite lascia i campioni invariati (opzione `-F`, patch di Sweetspot) mentre Lyrion tiene il controllo digitale del volume, così Material e le app mostrano il cursore, che `sweetspot-volume` segue dalla CLI con la stessa scala di Lyrion per Squeezelite (100 = 0 dB, 50 = −24,7 dB, 25 = −37 dB, 1 = −72,5 dB, 0 = sordina; mai sopra 0 dB), riletto anche a ogni ricollegamento del player. I file DSD si convertono in PCM. L'unica istanza di CamillaDSP della sessione parte già al volume giusto (`-g`/`-m` dal file di volume, che se manca dà silenzio e non volume massimo; il cursore poi la regola dal websocket). In modalità player serve anche `SERVER` (il volume si legge da quel Lyrion; senza, volume software, e lo Stato e la pagina Audio dicono perché); se CamillaDSP non parte si usa il volume software | fisso |
| `DSD` | `auto`, `nativo`, `dop`, `no`. Con il volume software (`VOLUME=software`, o il ripiego software di `dac`/`dsp`) il DSD si converte sempre in PCM, anche con `nativo` o `dop`: Squeezelite non applica il volume al DSD nativo e dopo un brano PCM attenuato un DSF suonerebbe al 100% (circa 30 dB più forte), un rischio per orecchie e diffusori. Vale anche per le zone (`ALTRI_DAC`), il cui volume è software | auto |
| `DSD_PCM_MARGINE_DB` | margine in dB della conversione DSD → PCM, da -24 a 0 (mai sopra 0). I DSD "over" superano 0 dBFS fino a +3 dB (il 50% di modulazione oltre lo standard) e senza margine la conversione a 32 bit li taglierebbe; con -3 dB tutto il DSD convertito suona 3 dB più piano (il volume lo compensa). 0 = nessun margine. Non vale per il DSD nativo né per il DoP. Pagine Audio e Stato | -3 |
| `RICAMPIONAMENTO`, `FILTRO` | `no`/`sincrono`/`asincrono`, `lineare`/`intermedio`/`minimo`. Il ricampionatore abbassa il segnale di 1 dB (dichiarato in Stato e Audio, anche per il ricampionamento di ripiego `FREQUENZA_NON_SUPPORTATA=ricampiona`, anche sulle zone). Stato dichiara anche l'uscita a 16 bit, dove i brani a 24 bit si riducono con dither TPDF (patch 0006 di Squeezelite, anche con il volume software; i blocchi di silenzio digitale restano silenzio e le sorgenti a 16 bit a volume pieno restano bit-perfect) e il ricampionamento di Lyrion con sox quando il brano in riproduzione supera la frequenza massima dichiarata dal player (probe del DAC o `FREQUENZA_MAX`) | no, lineare |
| `CORREZIONE_SE_ASSENTE`, `FIR_RICAMPIONA` | `blocca`/`diretto` (correzione o FIR di una frequenza mancanti: non si suona / si suona senza); `no`/`si` (ricampiona al FIR più vicino invece) | blocca, no |
| `FREQUENZA_MAX` | Hz, 0 = quella del DAC | 0 |
| `PAUSA_DSD_MS`, `PAUSA_FREQUENZA_MS` | pause per i DAC che perdono l'inizio; la pausa al cambio di frequenza non scende mai sotto il buffer ALSA | 500, 0 |
| `LIVENESS_FUNZ_PERIODO`, `LIVENESS_FUNZ_FALLIMENTI`, `LIVENESS_FUNZ_ATTESA`, `LIVENESS_RIAVVII_MAX`, `LIVENESS_RIAVVII_FINESTRA` | controlli funzionali della liveness, uno ogni `LIVENESS_FUNZ_PERIODO` s (minimo 30) senza processi permanenti: il player principale e ogni zona devono risultare connessi a Lyrion e, se Lyrion dice "play", il PCM ALSA del player deve essere RUNNING con `hw_ptr` che avanza fra due controlli (non il `time ?` di Lyrion, che Lyrion estrapola e con Squeezelite bloccato continua ad avanzare); se il PCM non suona ma il processo lavora (ribuffering per rete lenta) lo stato è `attesa`, senza riavvio, finché dura meno di `LIVENESS_FUNZ_ATTESA` controlli; CamillaDSP, se è nel percorso, deve rispondere sul websocket. Dopo `LIVENESS_FUNZ_FALLIMENTI` controlli falliti di fila si ferma solo quel componente (lo riparte il supervisore). Se Lyrion non risponde non si giudica il player. Al più `LIVENESS_RIAVVII_MAX` riavvii per componente (Lyrion, player, zone, CamillaDSP) in `LIVENESS_RIAVVII_FINESTRA` s, poi stato `limite` e nessun altro riavvio finché i vecchi escono dalla finestra. Il contatore dei riavvii per componente è in `stato.json` (`liveness.funzionali`) e nella pagina Stato | 120, 3, 5, 3, 1800 |
| `LIVENESS` | `si`: liveness applicativa nel demone dello stato (nessun processo in più, guidata dagli eventi). Ogni `LIVENESS_LYRION_PING` s (45) il demone scrive `version ?` nella connessione CLI di Lyrion (porta 9090, già aperta per gli eventi) e deve avere la risposta entro `LIVENESS_LYRION_TIMEOUT` s, senza lanciare processi; se manca la conferma con il JSON-RPC `serverstatus` e dopo `LIVENESS_LYRION_FALLIMENTI` fallimenti consecutivi Lyrion viene riavviato. Il modo (play/pausa/stop) arriva dagli eventi playlist; se Lyrion dice "play" i PCM ALSA si guardano ogni 5 s con la sola shell (nessun fork mentre suonano) e, se nessuno è RUNNING da `LIVENESS_PLAYER_SECONDI` s (rilevato entro circa 20 s), il player risulta "bloccato" e Squeezelite viene riavviato. I riavvii hanno un backoff (da `LIVENESS_BACKOFF_MIN` a `LIVENESS_BACKOFF_MAX` s) e compaiono nel log, nella pagina Stato e in `stato.json` (`liveness`) | si, 8, 3, 20, 60, 900 |
| `NOME_RETE` | nome in rete (`http://NOME.local`) | sweetspot |
| `WIFI_NOME`, `WIFI_PASSWORD` | rete Wi-Fi, solo senza cavo | vuoto |
| `HOTSPOT`, `HOTSPOT_ATTESA`, `HOTSPOT_PROVA`, `HOTSPOT_PASSWORD` | hotspot di configurazione del primo avvio (vedi [sotto](#hotspot-di-configurazione-wi-fi)): `si`/`no`, secondi di attesa senza rete prima di accenderlo, secondi concessi alla rete scelta prima che riparta, password scelta da te (8-63 caratteri; vuoto = casuale a ogni accensione, 16 caratteri senza ambigui a gruppi di 4, 80 bit, mostrata sullo schermo) | si, 60, 40, vuoto |
| `IP_FISSO`, `GATEWAY`, `DNS` | indirizzo fisso, es. `192.168.1.50/24` | vuoto |
| `RISPARMIO_RETE` | risparmio energetico Ethernet (EEE) | no |
| `PROFILO` | `bilanciato`, `silenzio`, `prestazioni` | bilanciato |
| `ENERGIA` | profilo energetico del PC: `fisso` (SMT spento, stati C limitati, frequenza fissa) o `conservativo` (SMT attivo, stati C liberi, governor schedutil/ondemand); altri valori valgono `fisso` | fisso |
| `VOLUME_SICURO` | volume di Lyrion (0-100, intero; vuoto o non numerico vale 25) a cui si riporta il player quando si passa a caldo dal volume `fisso` (Lyrion tenuto a 100) a `software` o `dsp`: con il controllo digitale acceso quel 100 diventerebbe il volume reale, un picco. Si applica solo se il volume attuale lo supera e solo in quel passaggio: non limita il volume scelto dopo né l'avvio normale. Letto da `sweetspot-player` | 25 |
| `BLUETOOTH_VOLUME_MAX` | tetto del volume del telefono, 0-100 (% della scala A2DP 0-127; oltre 100 vale 100, non numerico 25). Il percorso Bluetooth non passa da CamillaDSP né dal limitatore: senza tetto il livello lo decide il telefono. Il tetto è applicato a polling, una volta al secondo, non è un limite istantaneo: un picco può durare fino a un secondo. Ogni canale sopra il tetto (anche il primo livello del telefono) viene riportato al tetto; sotto, il telefono regola liberamente. Serve `bluealsa-cli`: senza, avviso nel registro e nessun tetto. Letto all'avvio del servizio Bluetooth. Vedi *Bluetooth come sorgente* | 25 |
| `SCHEDA_I2S` | Raspberry Pi: nome dell'overlay della scheda DAC I2S; con `DAC=auto` si usa la prima scheda audio non USB che non sia HDMI o il jack del Pi | vuoto |
| `PRIORITA_AUDIO`, `PRIORITA_IRQ_USB` | priorità real-time del thread di riproduzione e delle interruzioni USB: stabilità temporale dell'alimentazione dei buffer, non jitter del DAC | 80, 90 |
| `DATI_ETA_MAX_MIN` | età massima (minuti) dei dati non salvati sulla chiavetta durante l'ascolto: oltre si salva comunque, a bassa priorità; 0 = solo a sistema fermo | 30 |
| `LOG_SQUEEZELITE_KB` | dimensione (KB) oltre la quale si ruota il registro di Squeezelite; gli XRUN già contati restano nei contatori della pagina Stato | 1024 |
| `LOG_FILE_KB`, `LOG_QUOTA_KB`, `LOG_QUOTA_SECONDI` | quota dei log in RAM (`/var/log`, `/run`, `/tmp`, anche Lyrion e le zone): tetto di ogni file e dimensione complessiva in KB; oltre si tronca il meno recente. `LOG_QUOTA_SECONDI` è l'intervallo minimo fra due controlli | 512, 4096, 120 |
| `USCITA_INTEGRATA` | usa la scheda audio del PC | no |
| `SCHERMO_MINUTI` | spegnimento dello schermo, 0 = mai | 2 |
| `PERIFERICHE_INUTILIZZATE` | `spente`: su qualunque computer, per classe di dispositivo e mai per modello. USB con sole interfacce smart card, video, Bluetooth/wireless (webcam, adattatori BT) scollegate dai driver (`authorized=0`), anche se collegate dopo l'avvio (regola udev). PCI inutilizzati a riposo quando inattivi (`power/control=auto`, e il ponte PCI sopra se porta solo a loro): scheda video che non mostra la console, audio integrato se `USCITA_INTEGRATA=no`, multimedia, modem, FireWire, lettore di schede, Wi-Fi senza `WIFI_NOME`, Bluetooth, schede di rete attive ma senza cavo né indirizzo (decise a rete su, da `S40sweetspot-net`, dopo qualche secondo per il collegamento: una scheda non ancora attivata non si tocca). Mai DAC, dischi, tastiere, hub o la rete in uso; `accese` lascia tutto com'è | spente |
| `WATCHDOG` | `si`: watchdog hardware (Intel iTCO, AMD SP5100, Raspberry Pi; i moduli del chipset sono caricati da `S21sweetspot-watchdog`, in blacklist solo con `no`; softdog se manca) alimentato ogni 5 s, tempo limitato al massimo del dispositivo (15 s sul Pi); un blocco totale fa ripartire il computer e, dopo un aggiornamento, la versione precedente; un riavvio causato dal watchdog è annotato nel registro (`bootstatus`) | si |
| `PASSWORD_WEB` | password delle pagine di Sweetspot (impronta SHA-512-crypt con sale; una vecchia impronta MD5-crypt viene riscritta al primo accesso giusto, una password scritta in chiaro in `sweetspot.txt` all'avvio; accesso da `/cgi-bin/accesso` con sessione: cookie HttpOnly e SameSite=Strict, 8 ore, ID casuale; dopo 5 errori di fila **dallo stesso indirizzo** si aspetta 30 secondi per ogni errore in più, fino a 15 minuti, e chi sbaglia non blocca gli altri (non c'è un contatore comune, che chiunque nella rete potrebbe usare per bloccare l'accesso); il gettone anti-CSRF è legato alla sessione (derivato da un segreto di ogni avvio, mai mostrato a chi non ha fatto l'accesso); il modulo di accesso ha un gettone suo, legato a un cookie del modulo (contro il login CSRF); ogni risposta porta `Content-Security-Policy: frame-ancestors`, `X-Frame-Options`, `X-Content-Type-Options` e `Referrer-Policy` (solo Audio, Stato e Accesso possono stare nel riquadro di Material, dalla porta 9000); senza sessione la copertina del CD risponde con un segnaposto e non con un errore; ogni azione richiede sessione e gettone anti-CSRF; il pulsante *Esci* chiude la sessione): obbligatoria: al primo avvio (e dopo un ripristino) le pagine mostrano solo *Primo accesso*, dove si inserisce il **codice univoco del dispositivo** (`XXXX-XXXX-XXXX`, casuale, mostrato su console e scritto in `PRIMO-ACCESSO.txt` sulla chiavetta, anche senza schermo) e si sceglie la password (minimo 10 caratteri, nessuna password predefinita). Non si puo' piu' togliere dalla pagina Sistema, solo cambiare, e per cambiarla serve la **conferma forte** con la password attuale (come per `SSH`): una sessione rubata non basta a chiudere fuori il proprietario. La stessa conferma serve per installare un pacchetto dal disco, che sostituisce il sistema anche se firmato ma vecchio. Le verifiche della password fatte da root (conferma forte compresa) hanno un loro contatore, fuori dalla portata delle pagine: dopo 20 errori di fila si aspetta 30 secondi per ogni errore in più, fino a 15 minuti, e ogni errore costa comunque 2 secondi. Dimenticata, anche senza schermo: togliere la riga `PASSWORD_WEB` da `sweetspot.txt` sulla chiavetta e riavviare; il codice viene riemesso su console e chiavetta. La conferma degli aggiornamenti (`/cgi-bin/vivo`) resta possibile con una chiave casuale di ogni avvio, solo per root. Le pagine rispondono solo se l'indirizzo usato è quello del player (`NOME_RETE.local`, il nome breve, i suoi indirizzi IP, `localhost`), altrimenti 403: è la difesa dal DNS rebinding di un sito esterno. Lyrion (porta 9000) e la sua CLI (9090) sono protetti da utente e password: vedi `LYRION_UTENTE`; Sweetspot tiene attiva la protezione CSRF di Lyrion al livello 1 (media, compatibile con Material Skin, iPeng e Squeezer; un livello 2 scelto da te resta). Nella pagina Sistema c'è anche *Ripristina le impostazioni iniziali* (`sweetspot-config ripristina`): musica, archivio e filtri restano | vuota |
| `LYRION_UTENTE`, `LYRION_PASSWORD` | credenziali di Lyrion, sempre attive (`authorize`): HTTP 9000 (anche Material e `/jsonrpc.js`) risponde 401 senza Basic e la CLI 9090 vuole `login`. Se mancano, al primo avvio Sweetspot genera una password casuale (utente `sweetspot`) e la salva qui; la pagina Sistema la mostra sempre, generata o scelta (blocco *Accesso a Lyrion*, *Mostra la password di Lyrion*), e permette di sceglierne una nuova (da 10 a 64 caratteri ASCII, senza spazi ne' `%`, che la CLI di Lyrion decodificherebbe): si salva qui e Lyrion si riavvia per applicarla, riallineando le credenziali mentre e' fermo. Va inserita una volta nelle app (Material, iPeng, Squeezer, UPnP/DLNA con credenziali, ecc.). Sweetspot le usa per volume, precarico, pagine, prova DoP e impostazioni del player. Credenziali Lyrion **preesistenti** non vengono sovrascritte: restano valide e vanno scritte qui perche' Sweetspot le usi, oppure sostituite con una password scelta dalla pagina Sistema (utente `sweetspot`). Scrivendo qui una password propria la si applica a ogni avvio; togliendo `LYRION_PASSWORD` se ne genera una nuova (rotazione). Sono in chiaro in `sweetspot.txt`, come `WIFI_PASSWORD`. Slimproto (3483) non ha autenticazione nativa: i player non sono toccati, ma quella porta e' protetta solo dalla rete locale | generate |
| `RENDERER_UPNP` | `si`: Sweetspot compare come diffusore UPnP/DLNA (MediaRenderer) per BubbleUPnP, JPlay, mconnect e simili; l'audio passa da Lyrion e dal player, vedi [Renderer UPnP/DLNA](#renderer-upnpdlna-in-entrata). Solo con `MODALITA=completa` | no |
| `SERVER_UPNP` | `si`: la libreria compare come media server UPnP/DLNA (MiniDLNA) per streamer e DAC di rete; DSF e DFF partono senza conversioni, vedi [Media server UPnP/DLNA](#media-server-upnpdlna). Solo con `MODALITA=completa` | no |
| `DLNA_INTERFACCE` | interfacce di rete su cui il media server UPnP/DLNA ascolta, separate da virgola (`eth0,wlan0`; solo lettere, cifre, `_`, `.`, `-`). Vuota (predefinito): tutte le schede LAN (cavo, Wi-Fi client), esclusa quella dell'hotspot di configurazione se acceso all'avvio del server. Un valore non valido viene ignorato. Si scrive in `sweetspot.txt` | LAN |
| `DLNA_HOTSPOT` | `si`: con `DLNA_INTERFACCE` vuota il media server ascolta anche sull'hotspot di configurazione. Si scrive in `sweetspot.txt` | no |
| `SSH`, `SSH_PASSWORD`, `SSH_UTENTE` | accesso remoto per l'assistenza. `SSH_UTENTE` è `assistenza` (predefinito), un utente senza privilegi, oppure `root` se lo si sceglie in modo esplicito (con `assistenza` il login di root è disattivato). La password SSH deve avere almeno 12 caratteri: se è più corta SSH con password non si avvia e il motivo si legge nel diario. Se sulla chiavetta c'è un file `authorized_keys`, SSH accetta **solo le chiavi** (password spente, anche per root); altrimenti resta la password, con al massimo 3 tentativi per connessione e, dopo 5 errori dallo stesso indirizzo, un'attesa di 5 secondi in più a ogni nuova connessione (fino a 60). La chiave dell'host si crea una volta e si salva sulla chiavetta (`sweetspot-ssh-host-key`), così non cambia a ogni avvio. **Attenzione:** quella chiave privata sta in chiaro sulla chiavetta (FAT, senza permessi), per scelta, perché l'identità del player resti la stessa dopo un aggiornamento; chi ha la chiavetta in mano può impersonare il player davanti ai client SSH (non entra nel player, che resta protetto da password o chiavi). Custodisci la chiavetta di conseguenza; per rigenerare la chiave cancella `sweetspot-ssh-host-key` dalla chiavetta e riavvia (i client vedranno un nuovo avviso sull'impronta). Dalla pagina Sistema queste tre chiavi aprono il sistema come amministratore e si cambiano solo con la **conferma forte**: serve avere `PASSWORD_WEB`, riscriverla nel campo di conferma e un gettone monouso (valido 10 minuti) emesso da root; la verifica la fa l'helper privilegiato, non la pagina, e un tentativo sbagliato conta come un errore di accesso. Senza `PASSWORD_WEB` da web non si cambiano: si scrivono in `sweetspot.txt` con il computer | no |
| `HTTPS`, `HTTPS_REINDIRIZZA` | connessione protetta delle pagine (porta 443) con `stunnel` davanti all'httpd di BusyBox; certificato autofirmato creato al primo avvio con `HTTPS=si` e salvato sulla chiavetta (`sweetspot-https.pem`), impronta SHA-256 nella pagina Sistema. Con HTTPS il cookie di accesso è `Secure`. `HTTPS_REINDIRIZZA=si` fa rimandare a https le pagine richieste in chiaro (non `/cgi-bin/vivo` né le richieste dal computer stesso). Lyrion (porta 9000) resta in chiaro, anche se con password | no |
| `DIARIO`, `DIARIO_ORE`, `DIARIO_KB` | diario di bordo sulla chiavetta (cartella `diagnostica`): `si`/`no`; ogni quante ore (1-24, 2 predefinite) si salvano registro e timeline; dimensione massima in KB di ogni file prima della rotazione (256 predefiniti, tre generazioni). Vedi [Diagnostica](#diagnostica-registro-persistente-timeline-e-crash-dump) | si, 2, 256 |
| `OTTIMIZZAZIONI` | `no` per confronti alla cieca o problemi | si |
| `CORREZIONE` | `no`, `si`, `confronto` (pari volume, senza filtri) | no |
| `ARCHIVIO` | UUID/PARTUUID dell'archivio; nome nelle vecchie configurazioni se univoco | vuoto |
| `ARCHIVIO_CONDIVISO`, `ARCHIVIO_PASSWORD` | cartella di rete Musica | no, vuoto |
| `ARCHIVIO_FIRMA`, `ARCHIVIO_CIFRATURA` | firma SMB obbligatoria (con la password) e cifratura SMB3 obbligatoria (costosa, opzionale) | si, no |
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

## Sicurezza

Sweetspot parte dall'ipotesi che la rete di casa sia fidata, che il
dispositivo non sia esposto su Internet e che l'hotspot del primo avvio non lo
sia. Ipotesi, superfici di attacco, difese, rischi accettati e requisiti
verificabili (RS-1, RS-2, ...) sono in
[docs/modello-minaccia.md](docs/modello-minaccia.md).

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
| Latenza durante l'ascolto | `LATENZA_ASCOLTO=si` in `sweetspot.txt`: finestre di 30 s a 100 risvegli al secondo sul core della riproduzione, solo mentre l'uscita suona; pagina di stato, massima e ultima finestra. Spenta in modo predefinito: il thread di misura (priorità 79, un gradino sotto il player) toglie pochi µs ogni 10 ms al player |
| XRUN della sessione | pagina di stato, "XRUN nella sessione": eventi e recuperi falliti dall'ultimo avvio del player; lo storico del registro resta come informazione. Zero eventi non esclude carenza di dati, errori DSP o altre interruzioni |
| Ascolto puro | pagina di stato, "Letture dal disco durante l'ascolto" e "Rete durante l'ascolto": settori letti dai dischi con la musica (`/sys/block/*/stat`) e byte di rete (`/proc/net/dev`, senza `lo`) dall'inizio dell'ascolto in corso o dell'ultimo, annotati da `sweetspot-ascolto` quando il DAC parte. Con il precarico finito le letture sono zero ("la musica suona dalla RAM"); la rete, in modalità completa, è solo il controllo dal browser e dalle app (sotto 2 KB/s), altrimenti streaming, cartelle di rete o precarico dalla rete |
| Interruzioni sul core audio | pagina di stato: IRQ dei dispositivi arrivati sul core della riproduzione nella sessione, uno per uno, e frequenza di quelle di sistema (timer, IPI) |
| Clipping della correzione | pagina di stato, "Clipping di CamillaDSP": campioni tagliati nella sessione |
| Underrun e picchi della correzione | pagina di stato, "Underrun di CamillaDSP" (righe "underrun" di `camilladsp.log` dall'inizio della sessione, contate dal player: CamillaDSP non li espone nel websocket) e "Picco di CamillaDSP" (massimo di sessione per canale, dal websocket) |
| Traffico durante l'ascolto | pagina di stato, "Traffico di rete ora"; read-ahead e streaming non garantiscono rete inattiva |
| Attività elettrica superflua | pagina di stato: "LED" (spenti tranne quelli della tastiera), "USB inutilizzate", "PCI a riposo" (ogni dispositivo con il suo stato reale: a riposo o attivo), "Lavoro differito del kernel" (workqueue non legate a un core solo sui core di sistema) e "Schermo" (stato DPMS dei connettori collegati e retroilluminazione). Le applica `sweetspot-silenzio` all'avvio, se le ottimizzazioni sono attive; è una riduzione di attività, non una misura del rumore analogico |
| Robustezza | CI (`tests/prova-robustezza-qemu.sh`, immagine x86 in QEMU): watchdog i6300ESB attivo, DAC USB emulato collegato, scollegato e ricollegato a caldo con il player che si ferma e riparte, blocco simulato (servizio del watchdog fermato) con riavvio automatico e player di nuovo attivo, file system della chiavetta integro dopo il riavvio brusco. Taglio di corrente durante l'aggiornamento A/B (`tests/prova-taglio-corrente-qemu.sh`, SIGKILL a QEMU durante la scrittura della copia, prima del marcatore e prima della conferma): riparte la copia buona, la copia interrotta non è valida, FAT integra. Installazione accanto a Windows (`tests/prova-accanto-qemu.sh`, UEFI con OVMF): SSD NVMe GPT con partizione EFI, MSR e Windows, installazione nello spazio libero, tabella GPT integra, partizioni di Windows identiche byte per byte, avvio senza chiavetta dalla voce UEFI creata e voce Windows nel menu. Sull'hardware: `sweetspot-durata 24 &` con una playlist lunga in riproduzione, esito in `/run/sweetspot/durata.txt` e sulla chiavetta; collaudo prolungato con guasti iniettati e benchmark di grandi librerie in [`docs/collaudo.md`](docs/collaudo.md) (nessun XRUN, nessun riavvio del player, uscita in riproduzione almeno il 95% del tempo, memoria calata meno del 10%); pagina di stato, voce "Watchdog" |
| Conversione PCM → DSD | non implementata e non prevista, per scelta: costo di CPU del modulatore, rischio di peggiorare il suono su hardware modesto, supporto dei DAC; motivi in [docs/pcm-dsd.md](docs/pcm-dsd.md) |
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
Limiti noti: il cambio di frequenza su ALSA e la certificazione dei DAC reali
non sono ancora provati.

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
Profili CPU (compreso `dinamico`), `sweetspot-banco` e la distinzione fra
scheduling e jitter: `docs/profili-cpu.md`.
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
aggiornamento con interruzione di alimentazione (la protezione del pannello web è già nel
sistema: password obbligatoria e sessione, vedi `PASSWORD_WEB`).

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
tests/prova-accanto-qemu.sh           installazione accanto a Windows in QEMU (UEFI)
tests/prova-lyrion.sh                 Lyrion avviato nel sistema compilato (CI, anche su ARM)
tests/renderer-upnp.py                renderer UPnP/DLNA: SSDP, descrittore, SOAP, eventi e riproduzione
tools/moduli-lyrion/                  prova dei moduli di Lyrion compilati per ARM
tools/genera-test-dop.py              file di prova bit-perfect
```

Basato su Buildroot 2026.08.1 e sul kernel con PREEMPT_RT: l'ultimo stabile
(7.3) sul PC, il ramo LTS rpi-6.18.y della Raspberry Pi Foundation sul
Raspberry Pi.

## Licenza

GNU General Public License versione 3 o successiva. Vedi `LICENSE`.
