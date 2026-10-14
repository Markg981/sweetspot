# Aggiornamenti firmati: chiave e prima release

Gli aggiornamenti sono pacchetti `.tar` con un `SHA256SUMS` firmato con
minisign. Il sistema li accetta solo se la firma torna con la chiave pubblica
`board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub`, che entra
nell'immagine come `/etc/sweetspot/aggiornamenti.pub`. Se il file manca, le
immagini compilate rifiutano ogni aggiornamento: `post-build.sh` stampa un
avviso (con `SWEETSPOT_RICHIEDI_CHIAVE=1` fallisce) e la compilazione di una
release (tag `v*`) senza segreto di firma fallisce.

## Generare la coppia di chiavi (una volta sola)

1. Su una macchina fidata, con minisign installato:
   `./scripts/genera-chiave-firma.sh`
2. Lo script scrive la chiave **pubblica** in
   `board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub` e stampa la
   chiave **privata**. Non committare mai la privata.
3. Su GitHub: Settings > Secrets and variables > Actions > New repository
   secret, nome `SWEETSPOT_FIRMA`, valore tutto il testo della chiave privata.
4. Cancella la copia locale della privata, o tienila offline.
5. Committa il file `.pub` (pubblico per natura) e fai la PR.

## Prima release

1. Dopo che il `.pub` e il segreto sono in place, crea il tag:
   `git tag v1.0.0 && git push origin v1.0.0`.
2. Il workflow `build.yml` compila x86_64 e rpi, firma `SHA256SUMS`, controlla
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
