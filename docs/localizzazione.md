# Localizzazione: stato e proposta

Sweetspot oggi è **solo in italiano**: interfaccia web, messaggi dei
programmi e documentazione. Questo documento descrive lo stato attuale e
propone un approccio; non cambia il codice. Tradurre è una decisione di
prodotto: serve prima sapere se c'è un pubblico non italiano.

## Stato attuale

- Interfaccia: pagine generate dagli script CGI in
  `board/sweetspot/rootfs-overlay/usr/share/sweetspot/www/cgi-bin/` (18 script
  di shell, circa 3.150 righe, testo scritto direttamente in `echo`/`printf`
  o in here-document) più `studio.js` (circa 590 righe, testi nel JavaScript).
- Punto centrale: esiste solo per la struttura. `usr/lib/sweetspot/web.sh`
  emette l'intestazione HTML con `<html lang="it">` fissato e le funzioni
  comuni; non c'è un catalogo di stringhe né una funzione di traduzione.
- Le pagine statiche (`index.html`, `canonical.html`, `hotspot-detect.html`)
  sono piccole e hanno lo stesso `lang="it"`.
- Altri testi: messaggi di log e di console degli script in `scripts/` e
  `usr/lib/sweetspot/`, README e `docs/*.md` (11 file), tutti in italiano.
- Stima grezza delle stringhe visibili all'utente: alcune centinaia nei CGI
  (le più dense sono `sistema`, `audio`, `azione`, `correzione`) e un centinaio
  in `studio.js`. Il numero esatto va contato con uno script di estrazione.

## Approccio proposto

1. **Catalogo per lingua**: un file `lingue/<codice>.sh` (es. `it.sh`,
   `en.sh`) con assegnazioni `T_chiave='testo'`, caricato con `.` da
   `web.sh`. Niente gettext: su BusyBox non c'è in modo affidabile e un file
   `sh` si legge in pochi millisecondi.
2. **Funzione `t chiave`** in `web.sh` che stampa `$T_chiave` oppure, se manca,
   il testo italiano (lingua di riserva). Le stringhe con parametri usano
   `printf` con segnaposto.
3. **Scelta della lingua**: ordine di priorità: cookie o impostazione
   `LINGUA=` in `sweetspot.txt`, poi intestazione `Accept-Language`, poi `it`.
   `web.sh` imposta `lang=` dell'HTML di conseguenza.
4. **JavaScript**: i testi di `studio.js` passano da un oggetto JSON
   generato dal catalogo (un endpoint CGI o un blocco nella pagina).
5. **Migrazione graduale**: prima `web.sh` e il catalogo `it.sh` (nessun
   cambiamento visibile), poi uno script CGI alla volta, poi `en.sh`.
   Un test controlla che ogni chiave usata esista in `it.sh`.
6. **Documentazione**: restare in italiano per README e `docs/`; eventuale
   `README.en.md` ridotto (cosa è, come si installa) come passo a parte.

## Stima del lavoro

- Infrastruttura (`t`, caricamento, scelta lingua, test sulle chiavi):
  1-2 giorni.
- Estrazione in `it.sh` e sostituzione nei CGI e in `studio.js`:
  4-6 giorni, quasi tutto meccanico ma da rivedere.
- Traduzione inglese e revisione sull'interfaccia: 2-3 giorni.
- Documentazione in inglese completa: non stimata, lavoro a parte e grande.

Totale per interfaccia bilingue: circa 2 settimane di una persona.

## Rischi

- **Conflitti**: toccare tutte le stringhe in tutti i CGI genera conflitti con
  qualunque altra modifica; farlo in una finestra senza altri lavori aperti.
- **Quoting della shell**: apostrofi, `$` e `%` nelle traduzioni possono
  rompere pagine o aprire iniezioni; i cataloghi vanno trattati come codice
  e le stringhe inserite in HTML devono restare scappate.
- **Test**: i test che cercano frasi italiane nell'output si romperebbero
  con lingue diverse; vanno forzati su `it`.
- **Manutenzione**: due lingue da tenere allineate; senza qualcuno che le
  controlli, l'inglese resterà indietro (la lingua di riserva limita il danno).
- **Spazio e RAM**: trascurabili (pochi KB per catalogo).
- **Messaggi di log**: restano in italiano, per non complicare la diagnostica.
