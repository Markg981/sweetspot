# Aggiornamenti firmati: chiave e prima release

Gli aggiornamenti sono pacchetti `.tar` con un `SHA256SUMS` firmato con
minisign. Il sistema li accetta solo se la firma torna con la chiave pubblica
`board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub`, che entra
nell'immagine come `/etc/sweetspot/aggiornamenti.pub`. Se il file manca, le
immagini compilate rifiutano ogni aggiornamento: `post-build.sh` stampa un
avviso (con `SWEETSPOT_RICHIEDI_CHIAVE=1` fallisce) e la compilazione di una
release (tag `v*`) senza segreto di firma fallisce.

## Stato attuale della chiave

La coppia e' stata generata con minisign (senza password, per l'uso in CI):
la pubblica (id `7E3A788D23A1E0B5`) e' nel repository; la privata esiste solo
nel segreto `SWEETSPOT_FIRMA` dell'**ambiente** GitHub `firma-aggiornamenti` e
in una copia di recupero fuori dal repository (cartella `~/.sweetspot-firma`
della macchina che l'ha generata, cartella 0700 e file 0600: il trasferimento
su supporto offline lo deve fare il proprietario).
Non c'e' nessun segreto a livello di repository: l'ambiente e' limitato ai tag
`v*`, quindi rami, pull request e workflow piu' vecchi non lo vedono e non
cambiano comportamento. Solo il workflow aggiornato, su un tag `v*`, firma.
Senza segreto una release fallisce (fail-closed); senza pubblica le immagini
rifiutano ogni aggiornamento.

Verifica senza toccare il valore: `gh secret list --env firma-aggiornamenti`
mostra solo nome e data.

## Generare o sostituire la coppia

1. Su una macchina fidata, con minisign installato:
   `./scripts/genera-chiave-firma.sh` (con `--sostituisci` se esiste gia').
2. Lo script scrive la chiave **pubblica** in
   `board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub` e stampa la
   chiave **privata** sul terminale (mai in log di CI, chat o commit).
3. Imposta il segreto senza mostrarlo: salva la privata in un file con
   permessi 600 e `gh secret set SWEETSPOT_FIRMA --env firma-aggiornamenti
   < file`, poi cancella il file (o conservalo offline).
4. Committa il file `.pub` (pubblico per natura).

## Recupero e rotazione

- **Privata persa** (nessuna copia): non si puo' firmare piu' per la vecchia
  pubblica. Gli Sweetspot installati vanno riscritti una volta con
  un'immagine che contiene la nuova pubblica.
- **Privata compromessa**: elimina subito il segreto (`gh secret delete
  SWEETSPOT_FIRMA --env firma-aggiornamenti`), genera una nuova coppia,
  pubblica un'immagine con la nuova pubblica e comunica agli utenti di
  riscriverla; un aggiornamento firmato con la vecchia chiave non e' piu'
  affidabile.
- **Rotazione pianificata**: prima release firmata con la *vecchia* chiave che
  porta la *nuova* pubblica nell'immagine; poi le release successive si
  firmano con la nuova privata (le immagini gia' aggiornate la accettano).
- Dopo ogni rotazione: nuovo test con un payload di prova (firma e verifica)
  e controllo dei metadati del segreto.

## Prima release

1. Dopo che il `.pub` e' nel ramo principale, crea il tag:
   `git tag v1.0.0 && git push origin v1.0.0`.
2. Il workflow `build.yml` compila x86_64 e rpi; il job `firma` (solo sui tag `v*`,
   ambiente `firma-aggiornamenti` dichiarato esplicitamente, e unico job che vede
   il segreto) firma `SHA256SUMS`, controlla
   che la chiave incorporata nell'immagine coincida con quella nel repository
   e pubblica la release con i pacchetti `*-aggiornamento.tar`.
3. Le immagini installate cercano gli aggiornamenti nell'ultima release.

Un'immagine compilata prima di questi passi non accetta aggiornamenti: va
riscritta una volta con un'immagine che contiene la chiave.

## Ritorno automatico

L'aggiornamento va nella copia (A/B) non in uso e GRUB (o `tryboot` sul Pi) la
prova una sola volta. A fine avvio `sweetspot-aggiorna conferma` controlla
impostazioni, pagina web, supervisore, Lyrion e libreria. Se un controllo
fallisce il motivo si salva sulla chiavetta e il sistema si **riavvia da solo**:
la prova e' a colpo unico, quindi riparte la copia precedente.
