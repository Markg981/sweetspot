# Sweetspot

Player e server di musica liquida bit-perfect, open source (GPLv3), pensato
come alternativa a Daphile: stesso motore (Lyrion Music Server con i suoi
plugin, Squeezelite come player), con un sistema costruito per far suonare il
DAC nel modo più pulito possibile. Si avvia da una chiavetta USB (o, dopo
l'installazione, dal disco interno), copia tutto in RAM e si usa dal browser
del telefono o del computer.

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
   - buffer da centinaia di MB: il brano arriva tutto in RAM ed è già
     decodificato prima di suonare, anche da Qobuz o TIDAL;
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
| **Audio** | DAC riconosciuto, formato che arriva al DAC in quel momento con la **verifica bit-perfect**, volume (fisso, del DAC, software), DSD, ricampionamento facoltativo con scelta del filtro, opzioni per esperti (buffer, periodi, pause) |
| **Musica** | stato della libreria, dischi trovati (escludi/includi), cartelle di rete (aggiunta con prova di accesso) |
| **Archivio** | il disco dove Sweetspot scrive: copia di cartelle da altri dischi e dal NAS, cartella di rete **Musica** per copiare dal PC o dal Mac, **copia dei CD** |
| **Plugin** | streaming (Qobuz, TIDAL, Spotify, Deezer, Bandcamp, YouTube), radio (Radio Paradise in FLAC, Radio Browser, radio.net), collegamenti (AirPlay in ingresso, UPnP/DLNA, Chromecast, gruppi): installazione con un clic dal repository ufficiale |
| **Rete** | schede di rete, Wi-Fi, indirizzo fisso, nome in rete |
| **Sistema** | nome, modalità, profilo del processore, modalità ascolto, SSH, **aggiornamenti**, **installazione sul disco interno**, riavvio e spegnimento |
| **Stato** | tutte le ottimizzazioni con un pallino verde o arancione, interruzioni dell'audio, traffico di rete |

Le impostazioni restano nella chiavetta, nel file `sweetspot.txt` (modificabile
anche con il Blocco note).

### Archivio musicale e cartella di rete

Tutti i dischi restano in sola lettura tranne uno, scelto come **archivio**
nella pagina Archivio (dopo l'installazione sul disco interno è il resto del
disco). Lì si copiano cartelle da chiavette, dischi o NAS (la copia si
sospende mentre la musica suona) e lì finiscono i CD. Con *Condividi in rete*
l'archivio compare sul PC come `\\sweetspot.local\Musica` e sul Mac come
`smb://sweetspot.local/Musica` (server SMB del kernel, ksmbd; password
facoltativa). Sull'archivio stanno anche le copertine già ridimensionate da
Lyrion (cartella `.sweetspot-cache`): non occupano RAM e non si rifanno a ogni
avvio.

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
basta copiare il pacchetto `sweetspot-x86_64-aggiornamento.tar` su un disco
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

### Modalità

- **completa** (predefinita): tutto su Sweetspot, come Daphile.
- **player**: solo Squeezelite, per un Lyrion Music Server su un altro
  computer (per chi vuole server e player separati).

## Cosa serve

- Un PC x86 a 64 bit con almeno 2 GB di RAM (consigliati 4 GB o più).
  Prototipo di riferimento: Asus N550JV con 16 GB.
- Un DAC USB.
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
3. A fine compilazione scarica `sweetspot-x86_64` dalla sezione **Artifacts**:
   contiene `sweetspot.img.xz`.

Pubblicando un tag `v0.1.0` l'immagine finisce anche nella pagina Releases.

### Su Linux o WSL2

```sh
sudo apt install bc build-essential cpio file git libelf-dev libssl-dev rsync unzip wget xz-utils
./scripts/build.sh
```

L'immagine è in `output/images/sweetspot.img.xz`. Servono circa 15 GB liberi.

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

Ogni compilazione produce anche `sweetspot-vmware.vmdk` (artifact
`sweetspot-vmware`): la stessa chiavetta, come disco virtuale.

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
| `ARCHIVIO` | nome del disco usato come archivio musicale | vuoto |
| `ARCHIVIO_CONDIVISO`, `ARCHIVIO_PASSWORD` | cartella di rete Musica | no, vuoto |
| `AGGIORNAMENTI_URL` | altra fonte degli aggiornamenti (API release di GitHub) | questo progetto |

I profili cambiano solo la frequenza della CPU: *silenzio* la fissa alla
minima, *bilanciato* a metà strada, *prestazioni* alla nominale tenendo i core
sempre svegli. Il Turbo è sempre spento.

## Verifiche

| Verifica | Come |
| --- | --- |
| Bit-perfect, in tempo reale | *Impostazioni Sweetspot → Audio*, riquadro "In riproduzione" |
| Sistema in RAM, chiavetta non in uso | pagina di stato, voci "Sistema in RAM" e "Chiavetta" |
| Ottimizzazioni attive | pagina di stato: tutte le voci verdi |
| DSD nativo sul R26 | pagina di stato, voce "DSD": `nativo (u32be)` |
| Bit-perfect | `tools/genera-test-dop.py`: vedi sotto |
| Latenza real-time | `sweetspot-latenza 300` da terminale (Alt+F2 o SSH), obiettivo sotto 50 µs |
| 24 ore senza interruzioni | playlist lunga, poi pagina di stato: "Interruzioni dell'audio: nessuna" |
| Rete muta durante l'ascolto | pagina di stato, "Traffico di rete ora" a brano caricato |

### Prova bit-perfect con il file DoP

```sh
python3 tools/genera-test-dop.py
```

Crea `sweetspot-test-dop.wav`: un PCM 24 bit / 176,4 kHz che contiene un tono
DSD64 a 1 kHz in formato DoP. Copialo nella libreria, **abbassa
l'amplificatore** e riproducilo. Se il DAC indica DSD e si sente un tono pulito,
nessuno stadio ha toccato i campioni. Se indica PCM o si sente fruscio, qualcosa
li altera: quasi sempre un volume diverso da "fisso".

In macchina virtuale la catena è stata verificata registrando ciò che arriva al
DAC USB emulato: i campioni sono identici a quelli del file, bit per bit.

## Struttura del progetto

```
configs/sweetspot_x86_64_defconfig    configurazione di Buildroot
board/sweetspot/common/               kernel PREEMPT_RT, BusyBox
board/sweetspot/x86/                  GRUB (due copie del sistema) e struttura della chiavetta
board/sweetspot/stick/                sweetspot.txt e LEGGIMI.txt
board/sweetspot/rootfs-overlay/       script di sistema, pagine di impostazione,
                                      plugin di Sweetspot per Lyrion
package/lms, package/lms-material     Lyrion Music Server e Material Skin
package/sweetspot-tools               firme AccurateRip per la copia dei CD
scripts/                              compilazione locale e con Docker
tests/run.sh                          test degli script con /sys e /proc simulati
tests/cd-simulato.sh                  copia completa di un CD con un lettore finto
tests/qemu-avvio.sh                   prova dell'immagine in QEMU (BIOS e UEFI)
tools/genera-test-dop.py              file di prova bit-perfect
```

Basato su Buildroot 2026.08 e sul kernel LTS 6.18.55 con PREEMPT_RT.

## Licenza

GNU General Public License versione 3 o successiva. Vedi `LICENSE`.
