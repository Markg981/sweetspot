# Supply chain: integrita' dei sorgenti, inventario e vulnerabilita'

## Sorgenti fissati

Ogni pacchetto proprio (`package/*`) scarica un sorgente con una riga
`sha256` (o `sha512`) nel proprio `.hash`; Buildroot rifiuta il download se
l'impronta non torna. `BR_NO_CHECK_HASH_FOR` non e' piu' usato.

| Pacchetto | Sorgente | Note |
|---|---|---|
| lms | archivio del tag 9.1.1 di slimserver | sha256 calcolato dall'archivio generato da GitHub |
| lms (moduli ARM) | release `dipendenze-lyrion` del progetto | sha256 |
| lms-material | zip della release 6.4.14 | sha1 del repository dei plugin + sha256 |
| camilladsp | archivio del tag v4.1.3 | dipendenze Rust fissate da `Cargo.lock` con i checksum del registro (`cargo --locked`) |
| alsa-cdsp | archivio del commit fissato | sha256 |

Gli archivi "generati" da GitHub possono, in teoria, cambiare se GitHub cambia
la compressione. In quel caso la build fallisce (fail-closed): si verifica che
il contenuto sia identico e si aggiorna l'hash, non si disattiva il controllo.

## Kernel x86: serie e politica di aggiornamento

Il kernel x86 e' la serie mainline (oggi 7.3), non una LTS: le LTS attuali
(6.18 e 6.12) non vanno bene sui PC nuovi (Intel Lunar Lake, Samsung Galaxy
Book 5), che si riavviano subito, e il PREEMPT_RT serve a tutte le schede. Il
prezzo e' una finestra di supporto breve, quindi vale questa politica:

- si segue la mainline stabile: a ogni nuova uscita (7.x) si aggiorna
  `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` in `configs/sweetspot_x86_64_defconfig`
  e la riga di `patches/linux/linux.hash`, e si verificano i frammenti
  `linux.fragment` con la compilazione x86 della CI; non si resta su una
  versione che kernel.org ha smesso di mantenere;
- appena una LTS supporta le CPU dei PC di riferimento (con PREEMPT_RT in
  mainline), si torna a una LTS e si toglie questa eccezione;
- il tarball e' verificato da `patches/linux/linux.hash` (sha256 da
  `sha256sums.asc` di kernel.org), perche' non e' detto che il `linux.hash` di
  Buildroot copra una versione cosi' recente; `BR2_GLOBAL_PATCH_DIR` lo cerca
  prima di quello del pacchetto.

Il controllo e' automatico: `./scripts/inventario.sh verifica` (e' anche in
`tests/run.sh`).

Buildroot stesso e' fissato per tag **e** commit (`BR_VERSION` e `BR_COMMIT` in
`scripts/build.sh`): se il tag venisse spostato la compilazione si ferma. Le
correzioni a Buildroot non ancora pubblicate stanno in `patches/buildroot/` e
`build.sh` le applica una volta sola; oggi c'e' l'aggiornamento di ffmpeg da
6.1.5 a 9.0.2 (archivio verificato con la firma GPG di FFmpeg, chiave
FCF986EA15E6E293A5644F10B4322F04D67658D8, prima di fissarne lo sha256). Va
tolta quando Buildroot pubblica la stessa versione.

## Strumenti di compilazione fissati

- Azioni di GitHub: tutte per commit (`uses: proprietario/azione@<sha> # vX.Y.Z`),
  in tutti i workflow; un tag spostato non cambia cio' che gira. Il commento
  dice la versione per gli aggiornamenti. Lo controlla `tests/triage-cve.py`.
- `docker/Dockerfile`: immagine `debian:trixie-slim` per digest (indice
  multi-architettura) e pacchetti apt dalla fotografia di snapshot.debian.org
  indicata da `ARG SNAPSHOT`; si aggiornano insieme.
- Moduli di Lyrion per ARM (`moduli-lyrion.yml`): Fedora 43 per digest e
  slimserver-vendor per commit. La compilazione gira con `contents: read`;
  solo il job `release`, su main e senza eseguire nulla di compilato, puo'
  scrivere nella release `dipendenze-lyrion`. Il tag di quella release e'
  mutabile, ma il pacchetto Buildroot `lms-moduli` ne fissa lo sha256: un file
  sostituito fa fallire la compilazione.
- syft e grype: versione fissata e `checksums.txt` di Anchore.

Rischio residuo dichiarato: i pacchetti apt installati sui runner di GitHub
(`ubuntu-26.04`, job `test`, prove e build) non sono fissati; i runner stessi
sono immagini gestite da GitHub. Restano strumenti, non finiscono nell'immagine.

## Protezione di main

`./scripts/proteggi-main.sh --applica` (da amministratore) rende obbligatorio,
anche per gli amministratori, il controllo `esito` di `build.yml`: un job
finale che fallisce se test, compilazione (con il triage delle CVE) o prove
Lyrion sono falliti **o annullati**. Una pull request con la compilazione
annullata non si puo' piu' unire. Senza argomenti lo script mostra la
protezione attuale.

## Inventario (SBOM)

Dopo aver configurato una build di Buildroot:

    BUILDROOT_DIR=/percorso/buildroot ./scripts/inventario.sh sbom /percorso/output

Produce `inventario/manifest.csv` (pacchetti, versioni e licenze realmente
inclusi nell'immagine, da `make legal-info`) e `inventario/show-info.json`.
Riguarda solo cio' che la configurazione distribuisce.

### Eseguito: SBOM CycloneDX del rootfs x86_64 e scansione grype

Il 27/10/2026 su un rootfs x86_64 estratto dall'artifact CI (run 40499552114,
build di main 39cc3db, **non** di questo ramo) con syft 1.54.1:
`docs/evidenze/sbom-x86_64.cdx.json` (242 componenti: 113 librerie e moduli
kernel, 123 file, 5 applicazioni: busybox, curl, ffmpeg, jq, openssl).
Scansione con grype 0.120.1 (database del 2026-10-27): 9 corrispondenze,
tutte su binari rilevati da syft: ffmpeg 9.0.2 (5, di cui 1 High), curl 8.22.0
(1 High), busybox 1.38.0 (3 High). Dettaglio in `docs/evidenze/grype-x86_64.json`. Il triage di queste
corrispondenze e' sotto ("Triage").

Copertura reale e limiti, da non nascondere:

- le corrispondenze sono per versione/CPE dei binari: non dicono se la
  funzione vulnerabile e' raggiungibile ne' se Buildroot ha gia' applicato
  patch (possibili falsi positivi): per questo serve il triage;
- **non coperti/opachi**: kernel (moduli con versione `UNKNOWN`, `bzImage` non
  scansionata), Perl e moduli CPAN inclusi in Lyrion, lms-material, CamillaDSP
  (binario Rust senza metadati), firmware; solo la build x86_64, non ARM;
- l'inventario di `scripts/inventario.sh` (hash e versioni) NON e' questo SBOM e
  non sostituisce una scansione;
- questi due file sono un'istantanea di main: per la build corrente vale
  l'artifact della CI (sotto).

Riproduzione: `syft dir:ROOTFS -o cyclonedx-json=sbom.json` poi
`grype sbom:sbom.json -o json`.

### In CI, a ogni compilazione

Il job `build` esegue gli stessi due comandi su `output/target` di **entrambe**
le schede (x86_64 e Raspberry Pi), con syft 1.54.1 e grype 0.120.1 scaricati
dalle release di Anchore e verificati con il loro `checksums.txt`. L'artifact
`sbom-<scheda>` contiene `sbom-<scheda>.cdx.json`, `grype-<scheda>.json` e
`grype-<scheda>.txt`; il riepilogo dell'esecuzione riporta il numero di
componenti e le corrispondenze per gravita', con la data del giorno.

Subito dopo, il passo "Triage delle CVE gravi" esegue
`scripts/triage-cve.py` sul rapporto e **blocca** la compilazione (e quindi
firma e release) se una CVE Critical o High non ha una decisione valida (vedi
sotto). Se la scansione non riesce (database di grype irraggiungibile) la build si
ferma su ogni ramo, non solo sui tag `v*`. Valgono le stesse
lacune di copertura elencate sopra (tranne "solo x86_64"). Nelle pull request che non toccano l'immagine non si
compila, quindi non c'e' un SBOM nuovo: vale quello dell'ultima build di main.

## Triage

`docs/triage-cve.tsv` ha una riga per ogni CVE Critical o High: CVE,
pacchetto, versione esatta (niente `*`: un pacchetto nuovo riapre il triage), decisione e motivo.

- `non-affetta`: il codice vulnerabile non e' nell'immagine o non e'
  raggiungibile. Per ffmpeg vale per tutto cio' che non si compila: serve
  solo a Squeezelite per WMA (demuxer asf) e ALAC (demuxer mov), quindi i
  defconfig tengono solo quei decoder e demuxer e tolgono rete, protocolli,
  codificatori, muxer, parser, filtri, bsf, accelerazioni hardware e il
  programma `ffmpeg`. MiniDLNA usa libavformat solo per i video, che non
  indicizza (`media_dir=A`). Per curl 8.22.0 (CVE-2026-92392, HTTP/2): nessun
  defconfig abilita nghttp2, quindi libcurl e' compilata senza HTTP/2;
  `tests/triage-cve.py` si ferma se un defconfig lo abilita.
- `accettata`: rischio residuo consapevole, con `rivedere-entro` obbligatoria;
  a quella data la CI torna a fermarsi finche' la decisione non viene
  rivista. Oggi: le tre CVE di busybox 1.38.0 (awk, ash), senza versione
  corretta pubblicata, da rivedere entro il 31/01/2027. CVE-2026-38754 (ash,
  ifsbreakup) e' quella da guardare: le pagine CGI sono script ash.
- le CVE corrette da un aggiornamento non hanno riga: dopo l'aggiornamento
  spariscono dal rapporto. Le righe legate a una versione che non c'e' piu'
  si tolgono. L'istantanea di main passa il controllo senza eccezioni
  (`tests/triage-cve.py`). La scansione fallita ferma la build su ogni ramo.

Le gravita' Medium e Low si contano nel riepilogo ma non bloccano. Una nuova
CVE grave pubblicata nel database ferma la build di main il giorno stesso:
si aggiunge la riga (o si aggiorna il pacchetto) nella stessa pull request che
sblocca. In locale:

    python3 scripts/triage-cve.py grype-x86_64.json --oggi AAAA-MM-GG

## Vulnerabilita' (CVE)

Nel repository c'e' solo l'istantanea di main descritta sopra; l'esito
aggiornato e' nell'artifact `sbom-<scheda>` di ogni compilazione e dipende
dalla data e dal database. In alternativa, con le fonti di Buildroot:

    make O=/percorso/output pkg-stats

(richiede rete verso NVD). Il risultato va conservato con la data accanto
all'inventario; "nessuna vulnerabilita' nota" non e' una garanzia, solo
l'esito di quel database in quel giorno. Le versioni sono anche confrontate
con le ultime pubblicate da `scripts/controlla-versioni.sh`.
