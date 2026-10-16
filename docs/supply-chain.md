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

## Vulnerabilita' (CVE)

Non e' incluso alcun esito di scansione: dipende dalla data e dal database.
Per ottenerlo, sulla stessa build:

    make O=/percorso/output pkg-stats

(richiede rete verso NVD). Il risultato va conservato con la data accanto
all'inventario; "nessuna vulnerabilita' nota" non e' una garanzia, solo
l'esito di quel database in quel giorno. Le versioni sono anche confrontate
con le ultime pubblicate da `scripts/controlla-versioni.sh`.
