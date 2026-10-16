# Supply chain: integrita' dei sorgenti, inventario e vulnerabilita'

## Sorgenti fissati

Ogni pacchetto proprio (`package/*`) scarica un sorgente con una riga
`sha256` (o `sha512`) nel proprio `.hash`; Buildroot rifiuta il download se
l'impronta non torna. `BR_NO_CHECK_HASH_FOR` non e' piu' usato.

| Pacchetto | Sorgente | Note |
|---|---|---|
| lms | archivio del tag 9.1.1 di slimserver | sha256 calcolato dall'archivio generato da GitHub |
| lms (moduli ARM) | release `dipendenze-lyrion` del progetto | sha256 |
| lms-material | zip della release 6.4.13 | sha1 del repository dei plugin + sha256 |
| camilladsp | archivio del tag v4.1.3 | dipendenze Rust fissate da `Cargo.lock` con i checksum del registro (`cargo --locked`) |
| alsa-cdsp | archivio del commit fissato | sha256 |

Gli archivi "generati" da GitHub possono, in teoria, cambiare se GitHub cambia
la compressione. In quel caso la build fallisce (fail-closed): si verifica che
il contenuto sia identico e si aggiorna l'hash, non si disattiva il controllo.

Il controllo e' automatico: `./scripts/inventario.sh verifica` (e' anche in
`tests/run.sh`).

## Inventario (SBOM)

Dopo aver configurato una build di Buildroot:

    BUILDROOT_DIR=/percorso/buildroot ./scripts/inventario.sh sbom /percorso/output

Produce `inventario/manifest.csv` (pacchetti, versioni e licenze realmente
inclusi nell'immagine, da `make legal-info`) e `inventario/show-info.json`.
Riguarda solo cio' che la configurazione distribuisce.

### Eseguito: SBOM CycloneDX del rootfs x86_64 e scansione grype

Il 16/10/2026 su un rootfs x86_64 estratto dall'artifact CI (run 38861841635,
build di main 8638df6, **non** di questo ramo) con syft 1.54.1:
`docs/evidenze/sbom-x86_64.cdx.json` (221 componenti: 102 moduli kernel e
librerie, 113 file, 5 applicazioni: busybox, curl, ffmpeg, jq, openssl).
Scansione con grype 0.120.1 (database del 2026-10-16): 59 corrispondenze,
tutte su binari rilevati da syft: ffmpeg 6.1.5 (43, di cui 1 Critical,
CVE-2026-40962, corretta in 8.1), openssl 3.6.4 (13), busybox 1.38.0 (3).
Dettaglio in `docs/evidenze/grype-x86_64.json`.

Copertura reale e limiti, da non nascondere:

- le corrispondenze sono per versione/CPE dei binari: non dicono se la
  funzione vulnerabile e' raggiungibile ne' se Buildroot ha gia' applicato
  patch (possibili falsi positivi); nessun triage e' stato fatto;
- **non coperti/opachi**: kernel (moduli con versione `UNKNOWN`, `bzImage` non
  scansionata), Perl e moduli CPAN inclusi in Lyrion, lms-material, CamillaDSP
  (binario Rust senza metadati), firmware; solo la build x86_64, non ARM;
- l'inventario di `scripts/inventario.sh` (hash e versioni) NON e' questo SBOM e
  non sostituisce una scansione;
- per esiti della build corrente serve la CI sulla build completa (`build`
  oggi e' saltata sui rami): ripetere i due comandi sull'artifact.

Riproduzione: `syft dir:ROOTFS -o cyclonedx-json=sbom.json` poi
`grype sbom:sbom.json -o json`.

## Vulnerabilita' (CVE)

Non e' incluso alcun esito di scansione: dipende dalla data e dal database.
Per ottenerlo, sulla stessa build:

    make O=/percorso/output pkg-stats

(richiede rete verso NVD). Il risultato va conservato con la data accanto
all'inventario; "nessuna vulnerabilita' nota" non e' una garanzia, solo
l'esito di quel database in quel giorno. Le versioni sono anche confrontate
con le ultime pubblicate da `scripts/controlla-versioni.sh`.
