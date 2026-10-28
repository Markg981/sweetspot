# Collaudo prolungato e benchmark di grandi librerie

Due strumenti per le prove che non si fanno in CI: ore di riproduzione con
guasti iniettati, e librerie da 50.000-200.000 brani. Girano su un computer
Linux con Python 3 (l'immagine Sweetspot non ha Python) e vedono il player
via rete e via SSH (`--ssh utente@player`, a chiavi, senza password).
Il comportamento di base del player in QEMU (watchdog, DAC a caldo, riavvio
brusco) resta in `tests/prova-robustezza-qemu.sh`; la misura di memoria e
temperatura di `sweetspot-durata` resta valida per le 24 ore "tranquille".

## Collaudo prolungato

    python3 tools/collaudo-prolungato.py --ssh root@sweetspot.local --ore 24 \
        --json collaudo.json --testo collaudo.txt

Prima: una playlist lunga (o un brano di ore) in riproduzione sul player.
Durante la prova, a rotazione ogni `--intervallo` secondi (300), per
`--durata-guasto` secondi (60), con seme riproducibile (`--seme`):

| Guasto | Cosa fa |
|---|---|
| `rete` | interfaccia giù/su e perdita di pacchetti 10% con ritardo 50 ms (`tc netem`, se c'è; altrimenti solo giù/su) |
| `scansione` | `rescan` della libreria |
| `navigazione` | JSON-RPC come Material Skin: album, artisti, ricerca, copertine |
| `ram` | un allocatore che sale a gradini fino al 60% della RAM libera (`--ram-percento`, `--ram-max-mb`) |

`--guasti rete,ram` ne sceglie alcuni. Con una `rete` che passa per la stessa
interfaccia dell'SSH la connessione cade per qualche secondo: è voluto, lo
strumento riprova; per non perdere l'osservazione si può usare una seconda
interfaccia (`--interfaccia`).

Cosa conta come interruzione (ognuna è un evento con orario e guasto in
corso, non solo gli XRUN):

- `xrun` e `buffer_svuotato`: righe del registro di Squeezelite
  (`/var/log/squeezelite.log`, `--log-squeezelite`);
- `salti_tempo`: il tempo di riproduzione si discosta di più di 1,5 s
  dall'orologio nello stesso brano;
- `interruzioni`: la riproduzione smette senza che nessuno l'abbia chiesto;
- `riconnessioni_player`: player non connesso a Lyrion o nuovo pid di
  Squeezelite;
- `restart_servizi`: cambia il pid di squeezelite, slimserver, supervisori;
- `oom`: nuove segnalazioni OOM nel `dmesg`;
- `rpc_fallite_percento`: richieste JSON-RPC senza risposta.

Esito pass/fail: ogni misura ha una soglia, predefinita 0 (5% per le RPC);
`--soglia xrun=2` la cambia. Il codice di uscita è 0 se tutte rientrano.
In CI: `--secondi 300 --intervallo 60` o la prova senza hardware
`python3 tests/prova-collaudo.py` (Lyrion finto, qualche secondo).

## Prove manuali

Non girano in CI: `tests/qemu-avvio.sh [immagine] [bios|uefi]` avvia
l'immagine in una macchina virtuale QEMU (4 core con Hyper-Threading, DAC USB
simulato) per provarla a mano prima di scriverla sulla chiavetta.

## Libreria sintetica e benchmark

    python3 tools/libreria-sintetica.py /musica/sintetica --brani 100000 --dimensione-kb 64
    python3 tools/benchmark-libreria.py --ssh root@sweetspot.local --brani 100000 \
        --aggiungi-comando 'sh /tmp/aggiungi-1-percento.sh' --json bench.json

Il generatore crea MP3 con tag ID3v2.3 (artista, album, titolo, genere,
anno, traccia) e una copertina piccola; con `--dimensione-kb` i file sono
sparsi (grandi in apparenza, vuoti sul disco). Stesso `--seme`, stessi file.
Si genera sulla macchina di prova e si copia sull'archivio del player (NAS o
disco USB).

Il benchmark misura per ogni profilo: indicizzazione completa
(`wipecache`) e incrementale (dopo `--aggiungi-comando`), latenza p50/p99 di
ricerca, album, artisti e copertine, RAM di Lyrion a riposo e picco durante
la scansione.

**Profili.** Lyrion tiene il database in SQLite in `cachedir`
(`/var/lib/lms/cache`). Il profilo `disco` è il predefinito (pref
`dbhighmem` 0: cache SQLite piccole, il resto su disco); `ram` è `dbhighmem`
2 (il database viene portato in memoria). Il benchmark cambia la pref via
JSON-RPC e, con `--riavvia-comando 'sweetspot-lms riavvia'`, riavvia Lyrion.
Cosa manca: Sweetspot non espone ancora una voce di configurazione per
questo (resta una pref di Lyrion) e non sposta `cache/library.db` su un
volume separato; per un "database su SSD" si usa oggi un archivio con
`.sweetspot-cache` (vedi `sweetspot-lms`, che sposta lì le sole cache delle
copertine). Se i numeri mostrano un vantaggio netto, il passo successivo è
una voce `LYRION_DB` in `sweetspot.txt`.

## Allegare i risultati a `docs/compatibilita.md`

`docs/compatibilita.md` è generata dai rapporti di `sweetspot-rapporto`:
non si modifica a mano. I risultati del collaudo si affiancano al rapporto
dello stesso sistema:

1. creare il rapporto (`sweetspot-rapporto`) a fine collaudo, con
   `sweetspot-durata` se fatta;
2. copiare `collaudo.json`, `collaudo.txt` e `bench.json` in
   `docs/compatibilita/collaudo/` con lo stesso prefisso del rapporto, per
   esempio `2026-10-11-asus-n550jv-r26-collaudo.json` (la sottocartella non
   viene letta dal generatore);
3. aprire la segnalazione *Rapporto di compatibilità* con il rapporto e i
   file allegati, indicando durata, libreria (brani) e profilo di database;
4. rigenerare la pagina: `python3 tools/matrice-compatibilita.py`.
