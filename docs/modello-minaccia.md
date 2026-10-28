# Modello di minaccia e requisiti di sicurezza

Questo documento fissa ipotesi, beni, superfici di attacco e requisiti di
sicurezza verificabili di Sweetspot. Ogni affermazione sul comportamento è
controllata nel codice di `main` e cita il file (e, dove serve, la funzione):
niente numeri di riga, che invecchiano a ogni modifica. Le modifiche ancora
in una pull request aperta andrebbero indicate come **PR aperta**: non fanno
parte di `main` e non vanno lette come difese presenti. Al momento non ce
ne sono: le correzioni citate sotto (#165, #181, #187, #189, #193, #195, #196)
sono tutte già in `main`.

## 1. Ipotesi (decise da Marco)

| Ipotesi | Significato |
| --- | --- |
| **LAN di casa fidata** | Chi è sulla rete cablata o sul Wi-Fi di casa non è un avversario deliberato; può però essere un dispositivo compromesso (TV, telefono, IoT) che si comporta male. |
| **Niente Internet in entrata** | Il dispositivo non è raggiungibile da Internet: nessun port forwarding, nessuna esposizione diretta. |
| **Hotspot di primo avvio non fidato** | Chi si collega a `Sweetspot-XXXX` è uno sconosciuto fino al primo accesso. |
| **Accesso fisico = fiducia** | Chi ha in mano il dispositivo o la chiavetta è fuori ambito. Segreti in chiaro sulla chiavetta FAT e chiave host SSH sulla chiavetta sono una scelta dichiarata (PR #168, già in `main`: `board/sweetspot/rootfs-overlay/etc/init.d/S45sweetspot-ssh`). |

## 2. Beni da proteggere

| Bene | Dove vive | Note |
| --- | --- | --- |
| Password del pannello web | `PASSWORD_WEB` in `sweetspot.txt`, solo come impronta SHA-512-crypt (`usr/bin/sweetspot-accesso`) | Le impronte MD5-crypt vecchie vengono riscritte (`sweetspot-accesso`). |
| Password SMB, SSH, Wi-Fi, hotspot | `ARCHIVIO_PASSWORD`, `SSH_PASSWORD`, `WIFI_PASSWORD`, `HOTSPOT_PASSWORD` in `sweetspot.txt` e `sweetspot-hotspot.txt` | **In chiaro** sulla chiavetta FAT (accettato, vedi 1). |
| Libreria musicale | disco/USB, cartella di rete | Lettura per ospite se `ARCHIVIO_CONDIVISO=si` senza password (`usr/bin/sweetspot-nas`). |
| Configurazione | `sweetspot.txt`, stato in `/run/sweetspot` | Scrivibile dal pannello solo tramite `sweetspot-priv`. |
| Integrità degli aggiornamenti | firma minisign del file `SHA256SUMS`, chiave pubblica `etc/sweetspot/aggiornamenti.pub`, release gate in CI | Vedi 3.8. |
| Chiave host SSH | `sweetspot-ssh-host-key` sulla chiavetta | In chiaro per scelta (PR #168). |

## 3. Superfici di attacco

Per ogni superficie: minaccia, difesa presente, rischio residuo accettato con
la LAN fidata, e cosa cambierebbe con una LAN non fidata.

### 3.1 Pannello web (httpd BusyBox, porta 80)

- **Minaccia.** Un client della LAN (o una pagina web aperta dal browser
  dell'amministratore) invia comandi al player; indovinare la password;
  rubare una sessione.
- **Difesa presente.**
  - `auth_gate`: senza sessione le pagine rimandano all'accesso (303) e i dati
    JSON rispondono 401 (`usr/lib/sweetspot/web.sh`); senza password
    scelta si vede solo *Primo accesso* (`web.sh`).
  - Sessione: ID casuale a 32 cifre esadecimali, cookie
    `HttpOnly; SameSite=Strict`, durata 8 ore (`web.sh`, funzioni di sessione).
  - Gettone anti-CSRF richiesto a ogni azione (`usr/share/sweetspot/www/cgi-bin/azione`),
    **legato alla sessione**: `token()` lo deriva con SHA-256 da ID di sessione
    e da un segreto di avvio preso da `/dev/urandom` (`web.sh`, `token_secret`,
    `token_derive`; PR #193). Il modulo di accesso ha un gettone suo, legato
    a un cookie del modulo (`login_token`, `login_token_ok`): protegge dal
    login CSRF.
  - Limite ai tentativi per indirizzo di chi li fa, non globale
    (`web.sh`, applicato anche a HTTPS con `REMOTE_HOST` di stunnel). Anche
    gli errori di verifica del codice di *Primo accesso* si contano per
    sorgente e non in comune (PR #196).
  - L'httpd gira come utente `web` (`etc/default/httpd`); le operazioni da
    root passano da `sweetspot-priv` (3.2).
- **Rischio residuo accettato.** Su HTTP la password viaggia in chiaro sulla
  LAN. Il segreto da cui derivano i gettoni è uno solo per tutto il dispositivo
  e cambia a ogni avvio (`web.sh`, `token_secret`): chi ruba una sessione
  ne ha anche il gettone.
- **Con LAN non fidata.** HTTPS sempre acceso (`HTTPS=si`, `HTTPS_REINDIRIZZA=si`;
  il certificato è autofirmato, `usr/bin/sweetspot-https`, e di default
  è spento, `sweetspot-https`), gettone già legato alla sessione,
  un blocco per account (il cookie ha già `Secure` su HTTPS, `web.sh`).

### 3.2 `sweetspot-priv` (helper setuid root)

- **Minaccia.** Un'azione del pannello (o chi ruba una sessione) esegue
  comandi come root o apre accessi permanenti (SSH, password del pannello).
- **Difesa presente.** Elenco chiuso di script, sottocomandi e argomenti
  tipizzati; niente shell, niente percorsi dal chiamante, ambiente ripulito;
  esce con 126 se la richiesta non è nell'elenco
  (`package/sweetspot-tools/src/sweetspot-priv.c`). Installato
  `4755` (`package/sweetspot-tools/sweetspot-tools.mk`, verificato da
  `tests/privilegi.sh`). Le operazioni che aprono root o cancellano un disco
  richiedono `@conferma`: gettone monouso emesso da root, valido 600 secondi,
  più la password attuale del pannello (`sweetspot-priv.c`;
  lato pagine `web.sh`). `PR_SET_DUMPABLE=0` (`sweetspot-priv.c`).
- **Rischio residuo accettato.** Un bug nell'elenco o nei controlli degli
  argomenti vale come escalation a root; l'elenco è ampio (config, rete,
  dischi, LMS, plugin).
- **Con LAN non fidata.** Nessun cambiamento: la difesa non dipende dalla
  rete. Va rafforzata la revisione dell'elenco a ogni nuova voce.

### 3.3 SMB (ksmbd)

- **Minaccia.** Lettura o scrittura della libreria da parte di un client SMB;
  intercettazione o manomissione del traffico.
- **Difesa presente.** Spento di default (`ARCHIVIO_CONDIVISO=no`,
  `usr/bin/sweetspot-nas`). Senza password: ospite in **sola lettura**;
  con password: utente `sweetspot` autenticato, `guest ok = no`
  (`sweetspot-nas`). Protocollo minimo SMB 2.1 e, con la password, firma
  obbligatoria (`server signing = mandatory`, `ARCHIVIO_FIRMA=si`); cifratura
  SMB3 opzionale (`ARCHIVIO_CIFRATURA=si`, spenta per il costo di CPU).
  Hash NT in file `600` (`sweetspot-nas`); la password passa da stdin
  (`sweetspot-nas`).
- **Rischio residuo accettato.** Nessuna cifratura di default: il contenuto
  è leggibile da chi intercetta il traffico (la firma impedisce la
  manomissione solo con la password; l'ospite non è firmato). Ascolta su tutte le interfacce. Con l'ospite chiunque
  sulla LAN legge la libreria.
- **Con LAN non fidata.** Password obbligatoria (mai ospite), firma SMB
  obbligatoria (già di default con la password), `ARCHIVIO_CIFRATURA=si`, `interfaces`/`hosts allow` limitati alla scheda di casa.

### 3.4 MiniDLNA (media server UPnP/DLNA)

- **Minaccia.** Elenco e lettura della libreria da parte di qualunque
  dispositivo sulla LAN; DLNA non ha autenticazione.
- **Difesa presente.** Spento di default (`SERVER_UPNP=no`) e solo in
  modalità completa (`usr/bin/sweetspot-mediaserver`); gira come utente
  `dlna` (`sweetspot-mediaserver`); l'hotspot non lo raggiunge
  (3.7).
  Con `DLNA_INTERFACCE` (nomi separati da virgola, PR #189) ascolta solo sulle
  interfacce indicate (`dlna_ifaces`, `dlna_conf`).
- **Rischio residuo accettato.** Senza `DLNA_INTERFACCE` (predefinito, o valore
  non valido) ascolta su tutte le interfacce, senza autenticazione;
  `wide_links=yes` (`dlna_conf`) segue i collegamenti simbolici nella
  libreria.
- **Con LAN non fidata.** Server UPnP spento (`SERVER_UPNP=no`) oppure
  `DLNA_INTERFACCE` limitata alla scheda di casa.

### 3.5 Renderer UPnP/DLNA in entrata

- **Minaccia.** Qualunque host della LAN comanda la riproduzione (SOAP non
  autenticato); abuso del SUBSCRIBE GENA come SSRF verso altri host; esaurimento
  di memoria o processi.
- **Difesa presente.** Limiti: corpo POST massimo 32 KB, coda SSDP con tetto e
  rate limit per IP (`tests/renderer-limiti.sh`), abbonamenti
  massimi 32, 8 per host, 3 URL per abbonamento, 512 caratteri
  (`usr/lib/sweetspot/renderer.pl`). Anti-SSRF in `main`: la CALLBACK
  deve avere lo stesso host del richiedente e non contenere `@ # ? \`, spazi o
  caratteri di controllo (`renderer.pl`, gestione di SUBSCRIBE; PR #165).
  Il demone gira come utente dedicato `renderer`, con configurazione ridotta
  (`renderer.conf`), avviato con `start-stop-daemon -c renderer`
  (`etc/init.d/S70sweetspot-renderer`, `board/sweetspot/users.txt`), e chi
  arriva dall'hotspot di configurazione non viene servito (`renderer.pl`,
  confronto con `$AP_IP`; PR #187).
- **Rischio residuo accettato.** Le azioni SOAP non hanno autenticazione
  (`renderer.pl`) e il demone ascolta su tutte le interfacce (con il solo
  rifiuto dell'hotspot).
- **Proprietà dichiarata: SSRF cieco da `SetAVTransportURI`.** Il renderer non
  ha autenticazione: un host della LAN può far aprire a Lyrion (che gira
  sull'apparecchio) qualunque URL `http(s)://`, compresi loopback e indirizzi
  interni (`renderer.pl`, gestione di `SetAVTransportURI`; l'unico filtro è lo
  schema). L'esito non torna al chiamante (cieco), ma la richiesta GET parte
  dall'apparecchio. Mitigazione: renderer spento di serie (`RENDERER_UPNP=no`).
  Non si filtrano gli indirizzi locali perché il contenuto può stare
  sull'apparecchio stesso (MiniDLNA) e un filtro sui nomi si aggira con DNS.
  Rischio residuo: con il renderer acceso, ogni host della LAN può provocare GET
  verso servizi interni (es. Lyrion su 127.0.0.1:9000).
- **Con LAN non fidata.** Renderer spento (`RENDERER_UPNP=no`, predefinito in `sweetspot.txt`), usare solo il controllo da Lyrion con autenticazione.

### 3.6 SSH (dropbear)

- **Minaccia.** Accesso da remoto per forza bruta o password debole.
- **Difesa presente.** Spento di default (`SSH=no`, `S45sweetspot-ssh`).
  Senza `authorized_keys` serve una password e il servizio non parte se
  manca (`S45sweetspot-ssh`); al massimo 3 tentativi per connessione
  (`-T 3`, `S45sweetspot-ssh`) e, tra le connessioni, un'attesa crescente
  (5 secondi in più a ogni connessione, fino a 60) dopo 5 errori dallo stesso
  indirizzo (`usr/bin/sweetspot-ssh-conn`; PR #195). L'utente predefinito è
  `assistenza`, senza privilegi (dropbear `-w`, root escluso); `root` solo se
  scelto con `SSH_UTENTE=root`. Senza chiavi la password deve avere almeno 12
  caratteri, altrimenti il servizio non parte. Con `authorized_keys` sulla chiavetta le
  password sono spente (`-s`) e root non entra con la password (`-g`)
  (`S45sweetspot-ssh`). La password va a `chpasswd` da stdin
  (`S45sweetspot-ssh`). Le impostazioni che aprono SSH richiedono la
  conferma forte (3.2).
- **Rischio residuo accettato.** Chi sceglie `SSH_UTENTE=root` ottiene accesso
  root da remoto; la password è in chiaro in `sweetspot.txt`; la chiave host
  è in chiaro sulla chiavetta FAT (scelta dichiarata, PR #168,
  `S45sweetspot-ssh`). Il ritardo è per indirizzo: non ferma un attacco
  distribuito.
- **Con LAN non fidata.** Solo chiavi (`authorized_keys`), mai password;
  utente `assistenza` (mai root); SSH acceso solo per il tempo dell'assistenza.

### 3.7 Hotspot di configurazione e firewall nftables

- **Minaccia.** Un estraneo vicino al dispositivo si collega all'hotspot di
  primo avvio e raggiunge servizi interni (Lyrion, SMB, DLNA, renderer, SSH)
  o il pannello.
- **Difesa presente.** WPA con password casuale a 80 bit (16 caratteri,
  `usr/bin/sweetspot-hotspot`). Firewall `nftables` sulla sola scheda
  dell'access point: ammessi DHCP, DNS, 80 e 443, tutto il resto scartato
  (`etc/sweetspot/firewall.nft`, PR #169 già in `main`); cavo e Wi-Fi
  di casa non sono toccati (`firewall.nft`). Senza password scelta il
  pannello mostra solo *Primo accesso* con codice del dispositivo
  (`web.sh`, `sweetspot-accesso`).
- **Rischio residuo accettato.** Se `nft` non carica le regole il firewall
  **lascia tutto aperto** e lo scrive nel registro
  (`usr/bin/sweetspot-firewall`, provato in `tests/run.sh`).
  La password dell'hotspot è salvata in chiaro sulla chiavetta
  (`sweetspot-hotspot`).
- **Con LAN non fidata.** Il caso hotspot non cambia (già non fidato); il
  firewall dovrebbe fallire chiuso e impostare `policy drop` sulla catena.

### 3.8 Aggiornamenti via `curl` https

- **Minaccia.** Pacchetto alterato o sostituito (rete, chiavetta, mirror),
  declassamento a http, file enorme che riempie disco o tmpfs.
- **Difesa presente.** `curl --proto =https --proto-redir =https`
  (`usr/bin/sweetspot-aggiorna`, provato da `tests/run.sh`);
  limite di dimensione (`MAX_JSON`, `MAX_PKG`, `sweetspot-aggiorna`). Firma
  minisign obbligatoria su `SHA256SUMS` e legata a versione e architettura
  (`sweetspot-aggiorna`); senza chiave pubblica l'installazione è
  **disabilitata**; l'eccezione `unsigned_fixture` esiste solo con
  `SWEETSPOT_TEST` (`sweetspot-aggiorna`). Manifesto con copertura
  esatta e hash ricontrollati dopo la scrittura (`sweetspot-aggiorna`).
  Release gate in CI: pubblicazione solo su tag, dopo tutti i job obbligatori
  e con firma verificata sugli archivi scaricati (`tests/release-gates.py`).
  Un pacchetto da disco richiede la conferma forte (3.2).
- **Rischio residuo accettato.** `AGGIORNAMENTI_URL` può essere impostato a
  `http://` apposta (`sweetspot-aggiorna`): la firma resta comunque
  obbligatoria. Il segreto di firma è in un ambiente GitHub limitato ai tag
  (`tests/release-gates.py`); la sua compromissione non è coperta. Nessuna
  protezione dal **rollback** a una versione firmata ma vecchia.
- **Con LAN non fidata.** Nessun cambiamento sostanziale: la difesa non dipende
  dalla rete. Opzionale: fissare il certificato o il mirror.

### 3.9 Ricerche online del CD

- **Minaccia.** Perdita di riservatezza (il disc-id dei CD ascoltati va a
  servizi terzi); manomissione dei dati restituiti.
- **Difesa presente.** Titoli e copertine da MusicBrainz e Cover Art Archive
  e la verifica AccurateRip viaggiano in https (`usr/bin/sweetspot-cd`; PR
  #181); si spengono con `CD_CERCA_TITOLI` e `CD_ACCURATERIP`. I risultati sono trattati come
  dati (JSON via `jq`).
- **Rischio residuo accettato.** Le ricerche sono attive di default
  (`CD_CERCA_TITOLI=si`, `CD_ACCURATERIP=si` in `sweetspot.txt`): il disc-id
  esce verso servizi terzi finché non si spengono. Un host sulla via non può
  scrivere nei file; con https può solo negare il servizio.
- **Con LAN non fidata.** Ricerche online spente (`CD_CERCA_TITOLI=no`,
  `CD_ACCURATERIP=no`).

## 4. Fuori ambito

- Chi ha accesso fisico al dispositivo o alla chiavetta (segreti in chiaro,
  chiave host SSH, boot da altro supporto).
- Attacchi da Internet attraverso il router (port forwarding, UPnP IGD, router
  compromesso).
- Compromissione della catena di build o del segreto di firma delle release
  (solo mitigata da `tests/release-gates.py`).
- Attacchi ai servizi di terzi (Lyrion, plugin e servizi di streaming) oltre
  alla loro configurazione di accesso (`tests/lyrion-auth.sh`).

## 5. Requisiti di sicurezza

Ogni requisito indica il test che lo verifica oppure "senza test". I test
`tests/run.sh`, `tests/accesso.sh`, `tests/privilegi.sh` e gli altri girano
nel job `test` della CI.

| ID | Requisito | Test |
| --- | --- | --- |
| RS-1 | Con la password impostata, senza sessione valida le pagine rimandano all'accesso (303) e i dati JSON rispondono 401. | `tests/accesso.sh` |
| RS-2 | Senza password scelta si vede solo *Primo accesso*, la password si sceglie con il codice del dispositivo e un eccesso di tentativi dà 429 anche col codice giusto. | `tests/primo-accesso.sh` |
| RS-3 | Il cookie di sessione è `HttpOnly; SameSite=Strict`, con ID di 32 cifre esadecimali, e un cookie inesistente è rifiutato. | `tests/accesso.sh` |
| RS-4 | I tentativi di accesso sono limitati per indirizzo di chi li fa (anche con HTTPS) e non esiste un contatore globale. | `tests/accesso.sh` |
| RS-5 | Il modulo di accesso rifiuta redirect esterni (`next=http://...`, `/cgi-bin/../`). | `tests/accesso.sh` |
| RS-6 | Ogni azione del pannello richiede il gettone anti-CSRF. | senza test (nessun test chiama `azione` con gettone errato) |
| RS-7 | Il gettone anti-CSRF è legato alla sessione e il modulo di accesso ha un gettone suo (PR #193). | `tests/accesso.sh` |
| RS-8 | L'httpd e le pagine girano come utente `web`, non root. | `tests/privilegi.sh` |
| RS-9 | `sweetspot-priv` esegue solo l'elenco chiuso (126 altrimenti), senza percorsi, shell o argomenti non validi. | `tests/privilegi.sh` |
| RS-10 | Le operazioni che aprono root o cancellano dischi (SSH, `PASSWORD_WEB`, pacchetti da disco, installazione) richiedono `@conferma` con gettone monouso e password attuale. | `tests/privilegi.sh` |
| RS-11 | Senza password SMB la condivisione è ospite in sola lettura; con la password è autenticata e non ospite. | `tests/run.sh` |
| RS-12 | SMB con firma obbligatoria e protocollo minimo verificato. | senza test (nessuna firma configurata, vedi 3.3) |
| RS-13 | SSH senza chiavi usa password con `-T 3`; con `authorized_keys` password spente (`-s`) e root senza password (`-g`); chiave host riusata dalla chiavetta e non rigenerata. | `tests/run.sh` |
| RS-14 | SSH: utente predefinito `assistenza` (non root), password di almeno 12 caratteri, ritardo dopo gli errori (PR #195). | `tests/run.sh` |
| RS-15 | Gli ospiti dell'hotspot raggiungono solo DHCP, DNS, 80 e 443; Lyrion, SMB, DLNA non sono aperti; le regole sono valide per `nft -c`. | `tests/run.sh` |
| RS-16 | Se il caricamento del firewall fallisce l'esito è 0 e l'errore va nel registro. Comportamento attuale: **apre** (fail-open); un requisito di fail-closed non c'è ancora. | `tests/run.sh` (descrive il fail-open) |
| RS-17 | Il renderer rifiuta CALLBACK verso host diversi dal richiedente, URL troppo lunghi, abbonamenti oltre i limiti, corpi POST oltre 32 KB. | `tests/renderer-upnp.py`, `tests/renderer-limiti.sh` |
| RS-18 | La CALLBACK del SUBSCRIBE rifiuta `@ # ? \` (PR #165). | `tests/renderer-upnp.py` |
| RS-19 | Il renderer gira con un utente dedicato e non serve l'hotspot (PR #187). | `tests/privilegi.sh` |
| RS-20 | MiniDLNA limitabile a una interfaccia (`DLNA_INTERFACCE`, PR #189). | `tests/run.sh` |
| RS-21 | Gli aggiornamenti usano solo https anche dopo un redirect e hanno un limite di dimensione. | `tests/run.sh` |
| RS-22 | Un pacchetto senza firma, con firma di un'altra chiave o alterato dopo la firma è rifiutato; senza chiave pubblica l'installazione è disabilitata. | `tests/run.sh`, `tests/ops-safety.sh` |
| RS-23 | Il rilascio è consentito solo da tag, dopo tutti i job, con segreto di firma obbligatorio per i tag ufficiali e archivi scaricati verificati con la chiave incorporata. | `tests/release-gates.py` |
| RS-24 | Le password di Lyrion sono impostate alla protezione di Lyrion e non sovrascritte. | `tests/lyrion-auth.sh` |
| RS-25 | Le ricerche online del CD si possono disattivare e AccurateRip va in https (PR #181). | `tests/cd-simulato.sh` |
| RS-26 | Protezione dal rollback a una versione firmata più vecchia. | senza test (non implementato) |

## 6. Punti deboli emersi dall'analisi (non corretti qui)

1. Segreto dei gettoni anti-CSRF unico per il dispositivo e valido fino al
   riavvio (`web.sh`, `token_secret`); i gettoni però sono per sessione (#193).
2. Renderer: SOAP senza autenticazione e ascolto su tutte le interfacce
   (`renderer.pl`); il processo non è più root (#187).
3. Firewall dell'hotspot fail-open (`sweetspot-firewall`).
4. Fallback `ksmbd.adduser -p` con la password in `argv`, visibile in
   `/proc/*/cmdline` per pochi millisecondi (`sweetspot-nas`).
5. SMB senza firma né cifratura (`sweetspot-nas`).
6. SSH: `root` ammesso se scelto (`S45sweetspot-ssh`); ritardo solo per
   indirizzo (`sweetspot-ssh-conn`).
7. MiniDLNA su tutte le interfacce se `DLNA_INTERFACCE` è vuota, e
   `wide_links=yes` (`sweetspot-mediaserver`).
8. Ricerche online del CD attive di default (`sweetspot-cd`).
9. Pannello e SMB in chiaro sulla LAN (HTTPS spento di default, certificato
   autofirmato, `sweetspot-https`).
10. Password dell'hotspot e dei servizi in chiaro sulla chiavetta (accettato).
11. Nessuna protezione dal rollback degli aggiornamenti (RS-26).
