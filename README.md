# Sweetspot

Player audio bit-perfect per musica liquida, open source (GPLv3). Si avvia da
una chiavetta USB, copia tutto il sistema in RAM e fa una sola cosa:
consegnare al DAC esattamente i bit del file, con il minimo rumore elettrico e
senza interruzioni.

Questa è la **fase 1** del progetto: un sistema completo e usabile al posto di
Daphile, che riproduce con Squeezelite e si pilota da Lyrion Music Server. Dalla
fase 2 il motore di riproduzione diventa quello di Sweetspot.

## Cosa fa all'accensione

1. GRUB trova la chiavetta dall'etichetta `SWEETSPOT` (BIOS o UEFI a 64/32 bit)
   e carica kernel e sistema in RAM. Da quel momento la chiavetta non viene più
   letta e si può togliere.
2. Legge `sweetspot.txt` dalla chiavetta: impostazioni in italiano, modificabili
   con il Blocco note.
3. Riconosce il computer e calcola i parametri di avvio: core dedicati
   all'audio (anche sulle CPU ibride Intel), Hyper-Threading spento, CPU limitata
   allo stato C1. Al primo avvio li scrive sulla chiavetta e riavvia **una sola
   volta**; da lì in poi sono stabili.
4. Fissa la frequenza della CPU secondo il profilo, spegne il Turbo, il
   Bluetooth, il Wi-Fi non usato e il risparmio energetico USB e di rete, mette
   in standby i dischi meccanici interni.
5. Attende il DAC e avvia Squeezelite:
   - uscita diretta `hw:` su ALSA, senza plug, dmix o ricampionamento;
   - DSD nativo se il DAC lo dichiara (per il Gustard R26 è già riconosciuto
     dal kernel), DoP o conversione dal server a scelta;
   - buffer da centinaia di MB fino a ~3 GB: il brano arriva tutto in RAM, e
     durante l'ascolto la rete resta muta;
   - thread di riproduzione real-time (priorità 80) sul suo core isolato,
     interruzioni del controller USB del DAC (priorità 90) sull'altro.
   Se il DAC viene spento o scollegato, il player riparte da solo quando torna.
6. Mostra sullo schermo l'indirizzo e un QR code, poi lo spegne.

Lo stato completo si vede dal telefono su `http://sweetspot.local`: ogni
ottimizzazione con un pallino verde o arancione, il formato in uscita, le
interruzioni dell'audio dall'accensione e il traffico di rete in quel momento.

## Cosa serve

- Un PC x86 a 64 bit con almeno 1 GB di RAM (consigliati 4 GB o più).
  Prototipo di riferimento: Asus N550JV con 16 GB.
- Un DAC USB.
- Il cavo di rete (il Wi-Fi funziona, ma è un ripiego).
- Una chiavetta USB da almeno 1 GB.
- **Lyrion Music Server** su un altro computer o su un NAS: la libreria
  musicale e l'interfaccia di controllo restano lì, lontano dal DAC. Va bene
  anche un PC Windows (per esempio il Galaxy Book) o la versione Docker.

Secure Boot va disattivato nel BIOS/UEFI: la firma del bootloader arriva in una
fase successiva.

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

Si vede il primo avvio con il riavvio di adattamento, poi la pagina di stato è
su `http://localhost:8080`. Ctrl+A e poi X per uscire.

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
5. In Lyrion il player compare come **Sweetspot** (o con il nome scelto).

### Impostazioni consigliate in Lyrion

- *Impostazioni del player → Audio → Controllo del volume*: **livello di
  uscita fisso al 100%**. Con un volume diverso Squeezelite moltiplica i
  campioni e il percorso non è più bit-perfect.
- Volume regolato dall'amplificatore.
- Per il DSD, plugin **DSD Player** attivo (incluso in Lyrion).

## Impostazioni (`sweetspot.txt`)

| Voce | Valori | Predefinito |
| --- | --- | --- |
| `NOME_PLAYER` | testo | Sweetspot |
| `SERVER` | indirizzo di Lyrion, vuoto = ricerca automatica | vuoto |
| `DAC` | `auto`, nome ALSA (es. `R26`) o `VID:PID` | auto |
| `PROFILO` | `bilanciato`, `silenzio`, `prestazioni` | bilanciato |
| `DSD` | `auto`, `nativo`, `dop`, `no` | auto |
| `PAUSA_DSD_MS` | pausa al passaggio PCM/DSD | 500 |
| `PAUSA_FREQUENZA_MS` | pausa a ogni cambio di frequenza | 0 |
| `WIFI_NOME`, `WIFI_PASSWORD` | rete Wi-Fi, solo senza cavo | vuoto |
| `RISPARMIO_RETE` | risparmio energetico Ethernet (EEE) | no |
| `USCITA_INTEGRATA` | usa la scheda audio del PC | no |
| `SCHERMO_MINUTI` | spegnimento dello schermo, 0 = mai | 2 |
| `SSH`, `SSH_PASSWORD` | accesso remoto per l'assistenza | no |
| `OTTIMIZZAZIONI` | `no` per confronti alla cieca o problemi | si |

I profili cambiano solo la frequenza della CPU: *silenzio* la fissa alla
minima, *bilanciato* a metà strada, *prestazioni* alla nominale tenendo i core
sempre svegli. Il Turbo è sempre spento.

## Verifiche della fase 1

| Verifica | Come |
| --- | --- |
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
li altera: quasi sempre il volume del player in Lyrion.

## Struttura del progetto

```
configs/sweetspot_x86_64_defconfig    configurazione di Buildroot
board/sweetspot/common/               kernel PREEMPT_RT, BusyBox
board/sweetspot/x86/                  GRUB e struttura della chiavetta
board/sweetspot/stick/                sweetspot.txt e LEGGIMI.txt
board/sweetspot/rootfs-overlay/       script di sistema e pagina di stato
scripts/                              compilazione locale e con Docker
tests/run.sh                          test degli script con /sys e /proc simulati
tests/qemu-avvio.sh                   prova dell'immagine in QEMU (BIOS e UEFI)
tools/genera-test-dop.py              file di prova bit-perfect
```

Basato su Buildroot 2026.08 e sul kernel LTS 6.18.55 con PREEMPT_RT.

## Licenza

GNU General Public License versione 3 o successiva. Vedi `LICENSE`.
