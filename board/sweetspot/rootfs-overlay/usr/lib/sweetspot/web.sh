# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - funzioni per le pagine web (CGI dell'httpd di BusyBox).

. "${SWEETSPOT_LIB:-/usr/lib/sweetspot}/common.sh"

# --- Privilegi -----------------------------------------------------------------
# Le pagine girano come utente "web" (httpd -u web:web). Quello che richiede
# root passa da sweetspot-priv (setuid, elenco chiuso di comandi): priv
# COMANDO ARGOMENTI... Senza l'helper (test, sviluppo) il comando e' eseguito
# direttamente.
SWEETSPOT_PRIV=${SWEETSPOT_PRIV:-/usr/sbin/sweetspot-priv}
# shellcheck disable=SC2034
WEBDIR=$RUN/web

priv() {
	if [ -x "$SWEETSPOT_PRIV" ]; then
		"$SWEETSPOT_PRIV" "$@"
	else
		"$@"
	fi
}

# Conferma forte per le operazioni che aprono root o il pannello (SSH,
# password del pannello, pacchetti di aggiornamento da disco): gettone
# monouso emesso da root + password attuale del pannello, riverificata da
# root. Senza PASSWORD_WEB la conferma non e' possibile (nessuna password da
# richiedere): si imposta prima quella.
confirm_token() {
	if [ -x "$SWEETSPOT_PRIV" ]; then
		"$SWEETSPOT_PRIV" @conferma-nuova 2>/dev/null
	else
		printf 'prova'
	fi
}

# priv_confirm GETTONE PASSWORD COMANDO ARGOMENTI...: 126 se la conferma e'
# rifiutata (nulla viene eseguito, come con l'helper), altrimenti l'esito
# del comando.
priv_confirm() {
	local tok=$1 pw=$2
	shift 2
	if [ -x "$SWEETSPOT_PRIV" ]; then
		printf '%s\n' "$pw" | SWEETSPOT_SORGENTE=$(client_ip) "$SWEETSPOT_PRIV" @conferma "$tok" "$@"
	else
		printf '%s\n' "$pw" | sweetspot-accesso verifica "$(client_ip)" || return 126
		"$@"
	fi
}

# Con l'helper le pagine leggono la configurazione senza password.
# shellcheck disable=SC2034
[ -x "$SWEETSPOT_PRIV" ] && CONF=$CONF_WEB

# Registro: lo scrive root (il file non e' delle pagine).
log() {
	if [ -x "$SWEETSPOT_PRIV" ]; then
		"$SWEETSPOT_PRIV" @log "$*"
	else
		mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
		echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
	fi
}

# Lyrion: le credenziali stanno in CONF (solo root), quindi la richiesta
# la fa l'helper, e solo per i pochi comandi che le pagine usano.
lms_json() {
	if [ -x "$SWEETSPOT_PRIV" ]; then
		"$SWEETSPOT_PRIV" sweetspot-lms json "$@"
	else
		lms_json_locale "$@"
	fi
}

# lms_avviso CODICE: titolo e spiegazione (HTML) per un errore di lms_json,
# distinti per causa: non in esecuzione, in avvio, non risponde, errore di
# Lyrion, troppe richieste. Prima era sempre "si sta avviando".
lms_avviso() {
	local t v
	case "$1" in
		2) t="Lyrion non è in esecuzione"; v="Il servizio non risulta attivo: guarda la pagina Stato. La pagina riprova da sola." ;;
		3) t="Lyrion si sta avviando"; v="La pagina si aggiorna da sola tra poco." ;;
		4) t="Lyrion non risponde"; v="Ha superato il tempo di attesa: potrebbe essere occupato o bloccato. La pagina riprova da sola." ;;
		5) t="Lyrion ha risposto con un errore"; v="La risposta non è utilizzabile: se dura, guarda il registro nella pagina Stato." ;;
		6) t="Lyrion è occupato"; v="Ci sono troppe richieste in corso: la pagina riprova da sola tra poco." ;;
		*) t="Lyrion non è raggiungibile"; v="La pagina riprova da sola." ;;
	esac
	printf '<div class="k">%s</div><div class="v">%s</div>\n' "$t" "$v"
}

# Testo sicuro dentro l'HTML (anche tra virgolette negli attributi).
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'; }

# Segreto anti-CSRF di questo avvio: non esce mai in una pagina, serve solo a
# derivare i gettoni (sessione e modulo di accesso).
token_secret() {
	# Sull'immagine lo crea root all'avvio (S03); qui solo se manca (test).
	if [ ! -s "$RUN/web.token" ]; then
		mkdir -p "$RUN"
		head -c 16 /dev/urandom | md5sum | cut -c1-24 > "$RUN/web.token"
	fi
	cat "$RUN/web.token"
}

# Gettone derivato dal segreto e da un contesto (sessione o modulo di accesso).
token_derive() {
	printf '%s:%s' "$1" "$(token_secret)" | sha256sum | cut -c1-32
}

# Gettone anti-CSRF legato alla sessione: lo vede solo chi ha fatto l'accesso
# (le pagine che lo mostrano stanno dietro auth_gate), una pagina esterna non
# puo' leggerlo e quello di un'altra sessione non vale. Senza PASSWORD_WEB (solo
# prove: sull'immagine le pagine sono chiuse finche' non c'e') resta il segreto.
token() {
	local id
	auth_enabled || { token_secret; return 0; }
	id=$(session_valid && session_id) || id=nessuna
	token_derive "sessione:$id"
}

# --- Autenticazione dell'amministratore ------------------------------------------
# Con PASSWORD_WEB le pagine chiedono l'accesso (/cgi-bin/accesso): password
# verificata da root (sweetspot-accesso verifica, impronta salata SHA-512-crypt),
# poi una sessione con cookie HttpOnly e SameSite=Strict. Il gettone anti-CSRF
# resta richiesto a ogni azione: la sessione dice CHI e', il gettone che la
# richiesta viene dalle nostre pagine. PASSWORD_WEB e' obbligatoria: finche'
# non c'e' (primo avvio o dopo un ripristino) si vede solo Primo accesso.
# Le sessioni sono file in $WEBDIR/sessioni (nome = ID casuale da /dev/urandom,
# contenuto = scadenza): spariscono al riavvio.
SESSION_DIR=$WEBDIR/sessioni
SESSION_TTL=${SWEETSPOT_SESSIONE_DURATA:-28800}
SESSION_COOKIE=sweetspot_sid
LOGIN_DIR=$WEBDIR/tentativi
# shellcheck disable=SC2034
LOGIN_FREE=${SWEETSPOT_TENTATIVI_LIBERI:-5}

auth_enabled() { [ -n "$(conf PASSWORD_WEB)" ]; }

# Valore esadecimale di 32 cifre di un cookie (altrimenti niente).
cookie_hex() { # nome
	local c id
	c=$(printf ';%s;' "${HTTP_COOKIE:-}" | tr -d ' ')
	case "$c" in *";$1="*) ;; *) return 1 ;; esac
	id=${c#*";$1="}
	id=${id%%;*}
	case "$id" in *[!0-9a-f]*|'') return 1 ;; esac
	[ ${#id} -eq 32 ] || return 1
	printf '%s' "$id"
}

# ID della sessione dal cookie.
session_id() { cookie_hex "$SESSION_COOKIE"; }

session_valid() {
	local id exp
	id=$(session_id) || return 1
	exp=$(cat "$SESSION_DIR/$id" 2>/dev/null)
	case "$exp" in *[!0-9]*|'') return 1 ;; esac
	if [ "$exp" -le "$(date +%s)" ]; then
		rm -f "$SESSION_DIR/$id"
		return 1
	fi
	return 0
}

# Crea una sessione e stampa l'ID. Toglie quelle scadute e tiene al massimo 16
# sessioni: se sono piene, la piu' vecchia lascia posto.
session_new() {
	local id now f e n=0 oldest="" oldest_exp=0
	now=$(date +%s)
	mkdir -p "$SESSION_DIR" 2>/dev/null
	chmod 700 "$SESSION_DIR" 2>/dev/null
	for f in "$SESSION_DIR"/*; do
		[ -f "$f" ] || continue
		e=$(cat "$f" 2>/dev/null)
		case "$e" in *[!0-9]*|'') rm -f "$f"; continue ;; esac
		if [ "$e" -le "$now" ]; then rm -f "$f"; continue; fi
		n=$((n + 1))
		if [ -z "$oldest" ] || [ "$e" -lt "$oldest_exp" ]; then oldest=$f; oldest_exp=$e; fi
	done
	[ "$n" -ge 16 ] && [ -n "$oldest" ] && rm -f "$oldest"
	id=$(od -An -N16 -tx1 "${SWEETSPOT_URANDOM:-/dev/urandom}" | tr -d ' \n')
	[ ${#id} -eq 32 ] || return 1
	( umask 077; printf '%s\n' "$((now + SESSION_TTL))" > "$SESSION_DIR/$id" ) || return 1
	printf '%s' "$id"
}

session_end() {
	local id
	id=$(session_id) && rm -f "$SESSION_DIR/$id"
	return 0
}

# Intestazione per impostare (ID) o cancellare (vuoto) il cookie.
session_cookie() {
	local sec=""
	is_https && sec="; Secure"
	if [ -n "$1" ]; then
		printf 'Set-Cookie: %s=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%s%s\r\n' "$SESSION_COOKIE" "$1" "$SESSION_TTL" "$sec"
	else
		printf 'Set-Cookie: %s=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0%s\r\n' "$SESSION_COOKIE" "$sec"
	fi
}

# Gettone dei moduli di accesso (accesso, primo accesso), quando ancora non c'e'
# una sessione: legato a un cookie casuale dato da questa stessa pagina
# (SameSite=Strict), cosi' una pagina esterna non puo' far entrare il browser
# dell'utente con una password scelta da lei (login CSRF) e il gettone non
# vale per le azioni. login_prepare va chiamata dopo la riga Status e prima di
# page_start, nella shell principale (non in $(...)).
LOGIN_COOKIE=sweetspot_lt
LOGIN_LT=""
login_prepare() {
	local sec=""
	LOGIN_LT=$(cookie_hex "$LOGIN_COOKIE") && return 0
	LOGIN_LT=$(od -An -N16 -tx1 "${SWEETSPOT_URANDOM:-/dev/urandom}" | tr -d ' \n')
	is_https && sec="; Secure"
	printf 'Set-Cookie: %s=%s; Path=/cgi-bin; HttpOnly; SameSite=Strict; Max-Age=3600%s\r\n' "$LOGIN_COOKIE" "$LOGIN_LT" "$sec"
}
login_token() { token_derive "accesso:$LOGIN_LT"; }
# Il gettone ricevuto vale solo con il cookie del modulo.
login_token_ok() { # gettone
	local lt
	lt=$(cookie_hex "$LOGIN_COOKIE") || return 1
	[ -n "$1" ] && [ "$1" = "$(token_derive "accesso:$lt")" ]
}

# Limitazione dei tentativi di accesso, solo per indirizzo di chi li fa: un
# contatore comune a tutti permetterebbe a chiunque nella rete di bloccare
# l'accesso dell'amministratore. Dopo la soglia di errori di fila si aspetta
# 30 secondi per ogni errore in piu' (al massimo 15 minuti). login_wait stampa
# i secondi da attendere (0 = si puo' provare).
login_key() {
	printf 'ip-%s' "$(client_ip)" | tr -c 'a-zA-Z0-9.:-' '_'
}

# Indirizzo di chi fa la richiesta. Con HTTPS il terminatore TLS (stunnel)
# lancia l'httpd in modalita' inetd e gli indirizzi li da' lui: l'IP vero del
# client sta in REMOTE_HOST (variabile d'ambiente di stunnel, non un'intestazione
# della richiesta: chi scrive la richiesta non puo' falsificarla).
client_ip() {
	case "${REMOTE_HOST:-}" in
		''|*[!0-9a-fA-F.:]*) ;;
		*) is_https && { printf '%s' "$REMOTE_HOST"; return 0; } ;;
	esac
	printf '%s' "${REMOTE_ADDR:-locale}"
}

# La richiesta e' arrivata per HTTPS? (lo dice il lancio dell'httpd da stunnel)
is_https() {
	[ "${HTTPS:-}" = on ] && return 0
	# Se l'httpd non passa l'ambiente alle pagine: dalla porta 80 l'indirizzo
	# di chi chiede e' sempre un IP, dal terminatore TLS (ingresso non TCP) no.
	case "${REMOTE_ADDR-x}" in
		''|local*) [ -f "$RUN/https.attivo" ] ;;
		*) return 1 ;;
	esac
}

login_wait() { # chiave soglia
	local f n last w
	f=$LOGIN_DIR/$(login_key "$1")
	n="" last=""
	[ -f "$f" ] && read -r n last < "$f"
	case "$n$last" in *[!0-9]*|'') echo 0; return 0 ;; esac
	[ -n "$last" ] || { echo 0; return 0; }
	[ "$n" -ge "$2" ] || { echo 0; return 0; }
	w=$(( (n - $2 + 1) * 30 ))
	[ "$w" -gt 900 ] && w=900
	w=$((last + w - $(date +%s)))
	[ "$w" -lt 0 ] && w=0
	echo "$w"
}

login_fail() { # chiave
	local f n="" last=""
	mkdir -p "$LOGIN_DIR" 2>/dev/null
	# Un file per indirizzo, in RAM (tmpfs): senza tetto chi cambia indirizzo a
	# ogni tentativo li accumulerebbe. I contatori fermi da piu' di 30 minuti
	# (oltre l'attesa massima di 15) si cancellano: il blocco in corso resta.
	find "$LOGIN_DIR" -maxdepth 1 -type f -mmin +30 -exec rm -f {} + 2>/dev/null
	f=$LOGIN_DIR/$(login_key "$1")
	[ -f "$f" ] && read -r n last < "$f"
	case "$n" in *[!0-9]*|'') n=0 ;; esac
	printf '%s %s\n' "$((n + 1))" "$(date +%s)" > "$f"
}

login_ok() { rm -f "$LOGIN_DIR/$(login_key "$1")"; }

# Chiamato quando si carica una pagina (CGI): con la password e senza sessione
# valida le pagine rimandano all'accesso e le richieste di dati rispondono 401.
# Fuori da una richiesta web (script di sistema, test) non fa nulla. Le pagine
# che devono restare pubbliche (accesso, vivo) impostano WEB_PUBLIC=1 prima.
auth_gate() {
	[ -n "${GATEWAY_INTERFACE:-}" ] || return 0
	[ "${WEB_PUBLIC:-}" = 1 ] && return 0
	if ! auth_enabled; then
		# Primo accesso (nessuna password scelta): niente pagine finche' non si
		# sceglie la password con il codice del dispositivo. Vale sempre, anche
		# se il codice e' in rigenerazione: mai una finestra anonima.
		case "${SCRIPT_NAME:-}" in
			*/copertina|*/studio-copertina) cover_placeholder ;;
			*.json)
				printf 'Status: 401 Unauthorized\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n'
				sec_headers
				printf '\r\nprimo accesso richiesto\n' ;;
			*)
				printf 'Status: 303 See Other\r\nLocation: /cgi-bin/primo-accesso\r\nCache-Control: no-store\r\n'
				sec_headers
				printf '\r\n' ;;
		esac
		exit 0
	fi
	session_valid && return 0
	case "${SCRIPT_NAME:-}" in
		# Un'immagine non puo' mostrare un errore: senza sessione risponde con
		# il segnaposto (altrimenti il browser disegna un'immagine rotta).
		*/copertina|*/studio-copertina) cover_placeholder ;;
		*.json)
			printf 'Status: 401 Unauthorized\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n'
			sec_headers
			printf '\r\naccesso richiesto\n' ;;
		*)
			printf 'Status: 303 See Other\r\nLocation: /cgi-bin/accesso\r\nCache-Control: no-store\r\n'
			sec_headers
			printf '\r\n' ;;
	esac
	exit 0
}

# Segnaposto della copertina (immagine SVG, risposta 200): nota musicale su
# fondo neutro. Lo usano la pagina senza sessione e l'assenza della copertina.
cover_placeholder() {
	printf 'Content-Type: image/svg+xml\r\nCache-Control: no-store\r\n'
	sec_headers
	printf '\r\n'
	printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200" role="img" aria-label="Copertina non disponibile">' \
		'<rect width="200" height="200" rx="12" fill="#e5e7eb"/>' \
		'<path d="M120 50v70a22 18 0 1 1-10-15V68l-30 8v54a22 18 0 1 1-10-15V62z" fill="#9ca3af"/></svg>'
}

# Con HTTPS_REINDIRIZZA=si le pagine richieste in chiaro rimandano a https
# (tranne /cgi-bin/vivo, per la verifica degli aggiornamenti, e le richieste dal
# computer stesso). Il flag lo scrive root (sweetspot-https applica).
https_redirect() {
	local h u
	[ -n "${GATEWAY_INTERFACE:-}" ] || return 0
	[ "${WEB_NO_REDIRECT:-}" = 1 ] && return 0
	is_https && return 0
	[ -f "$RUN/https.reindirizza" ] || return 0
	case "${REMOTE_ADDR:-}" in 127.*|::1) return 0 ;; esac
	h=$(host_bare "${HTTP_HOST:-}")
	case "$h" in *:*) h="[$h]" ;; esac
	case "${REQUEST_URI:-/}" in /*) u=$REQUEST_URI ;; *) u=/ ;; esac
	printf 'Status: 301 Moved Permanently\r\nLocation: https://%s%s\r\nCache-Control: no-store\r\n' "$h" "$u"
	sec_headers
	printf '\r\n'
	exit 0
}
https_redirect
auth_gate

# Legge i campi di un modulo inviato (POST) in variabili F_nome.
read_form() {
	local body pair k v
	set -f
	body=""
	if [ "$REQUEST_METHOD" = POST ] && [ -n "$CONTENT_LENGTH" ]; then
		body=$(head -c "$CONTENT_LENGTH")
	fi
	for pair in $(printf '%s' "$body" | tr '&' ' '); do
		k=${pair%%=*}
		v=${pair#*=}
		case "$k" in *[!a-z0-9_]*|'') continue ;; esac
		v=$(httpd -d "$v")
		eval "F_$k=\$v"
	done
	set +f
}

# Testo sicuro in un indirizzo (parametro di una pagina).
urlenc() {
	printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'
}

# printf con a capo: read scarta l'ultimo parametro se manca il fine riga.
query_param() {
	printf '%s\n' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | while IFS= read -r v; do httpd -d "$v"; done
}

# Risposta di reindirizzamento dopo un'azione (POST -> GET).
redirect() {
	printf 'Status: 303 See Other\r\nLocation: %s\r\nCache-Control: no-store\r\n' "$1"
	sec_headers
	# Sessione nuova da consegnare con la risposta (REDIRECT_COOKIE = ID).
	[ -n "${REDIRECT_COOKIE:-}" ] && session_cookie "$REDIRECT_COOKIE"
	printf '\r\n'
}

# Indirizzo con cui il browser ha raggiunto Sweetspot (nome o IP).
web_host() {
	local h
	h=${HTTP_HOST%%:*}
	[ -n "$h" ] || h=$(net_ipv4)
	printf '%s' "$h"
}

# Interfaccia di Lyrion (Material Skin).
player_url() { printf 'http://%s:9000/material/' "$(web_host)"; }
# Interfaccia di ascolto: Reference Studio (predefinita) o Material con
# INTERFACCIA_ASCOLTO=material. Material resta raggiungibile dal link nello
# Studio; le preferenze di Lyrion/Material non vengono toccate.
listen_url() {
	if [ "$(lower "$(conf INTERFACCIA_ASCOLTO studio)")" = material ]; then player_url; else echo /cgi-bin/studio; fi
}

# Sezioni delle impostazioni, come su Daphile. In modalita' player libreria
# e plugin stanno sul server Lyrion dell'altro computer.
web_sections() {
	if [ "$(mode)" = completa ]; then
		echo "audio:Audio musica:Musica archivio:Archivio plugin:Plugin rete:Rete bluetooth:Bluetooth sistema:Sistema stato:Stato"
	else
		echo "audio:Audio rete:Rete bluetooth:Bluetooth sistema:Sistema stato:Stato"
	fi
}

page_start() {
	local title=$1 active=$2 refresh=$3 p msg target current description
	case "$active" in
		audio) description="Controlla il percorso audio, il volume e le impostazioni del tuo DAC." ;;
		musica) description="Le tue sorgenti, la libreria e le operazioni di scansione." ;;
		archivio) description="Dischi, spazio disponibile e copie dei tuoi CD." ;;
		plugin) description="Servizi musicali e collegamenti, nel tuo impianto." ;;
		rete) description="Connessione locale, Wi-Fi e cartelle condivise." ;;
		bluetooth) description="Ascolta dal telefono e gestisci i dispositivi abbinati." ;;
		sistema) description="Il tuo player: preferenze, manutenzione e aggiornamenti." ;;
		stato) description="Diagnostica e misure del sistema, senza interrompere l'ascolto." ;;
		accesso) description="Accedi alle impostazioni del tuo impianto." ;;
		*) description="" ;;
	esac
	printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n'
	sec_headers
	printf '\r\n'
	cat <<HTML
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${refresh:+<meta http-equiv="refresh" content="$refresh">}
<meta name="theme-color" content="#10151d">
<title>$(esc "$title") - SweetSpot</title>
<link rel="stylesheet" href="/reference-studio.css?v=2">
<link rel="stylesheet" href="/style.css?v=reference-studio-2">
<script src="/tema.js?v=1"></script>
</head>
<body>
<a class="skip" href="#contenuto">Vai al contenuto</a>
<div class="app-shell">
<header class="app-header">
<a class="brand" href="/" target="_top">
<svg class="brand-mark" viewBox="0 0 28 32" fill="currentColor" aria-hidden="true"><rect x="1" y="10" width="4" height="13" rx="2"/><rect x="8" y="4" width="4" height="25" rx="2"/><rect x="15" y="1" width="4" height="30" rx="2"/><rect x="22" y="7" width="4" height="19" rx="2"/></svg>
<span><strong>SweetSpot</strong><small>Reference Studio</small></span>
</a>
<p class="nav-label">Il tuo impianto</p>
<nav aria-label="Impostazioni SweetSpot">
HTML
	if [ "$(mode)" = completa ]; then
		printf '<a class="play" href="%s" target="_top"><svg class="nav-icon" viewBox="0 0 24 24" aria-hidden="true"><use href="/reference-icons.svg#play"></use></svg>Ascolta</a>\n' "$(listen_url)"
	fi
	for p in $(web_sections); do
		target=""
		page_embeddable "/cgi-bin/${p%%:*}" || target=' target="_top"'
		current=""
		[ "${p%%:*}" = "$active" ] && current=' class="on" aria-current="page"'
		printf '<a%s href="/cgi-bin/%s"%s><svg class="nav-icon" viewBox="0 0 24 24" aria-hidden="true"><use href="/reference-icons.svg#%s"></use></svg>%s</a>\n' \
			"$current" "${p%%:*}" "$target" "${p%%:*}" "${p#*:}"
	done
	echo '<button type="button" class="tema" data-tema-switch hidden>Tema chiaro</button>'
	if auth_enabled && [ "$active" != accesso ]; then
		printf '<form method="post" action="/cgi-bin/accesso" class="inline"><input type="hidden" name="t" value="%s"><input type="hidden" name="a" value="esci"><button>Esci</button></form>\n' "$(token)"
	fi
	echo '</nav></header>'
	cat <<HTML
<main id="contenuto" tabindex="-1">
<div class="page-heading">
<p class="eyebrow">SweetSpot / Controllo dell'impianto</p>
<h1>$(esc "$title")</h1>
${description:+<p class="page-description">$(esc "$description")</p>}
</div>
HTML
	msg=$(query_param msg)
	[ -n "$msg" ] && printf '<p class="msg" role="status">%s</p>\n' "$(esc "$msg")"
	return 0
}

# Opzione di un elenco: VALORE ETICHETTA VALORE_ATTUALE
option() {
	local sel=''
	[ "$(lower "$3")" = "$(lower "$1")" ] && sel=' selected'
	printf '<option value="%s"%s>%s</option>' "$(esc "$1")" "$sel" "$(esc "$2")"
}

# Riga informativa: STATO(OK|ATTENZIONE|"") TITOLO TESTO
info_row() {
	printf '<div class="row %s"><span class="dot"></span><div class="grow"><div class="k">%s</div><div class="v">%s</div></div></div>\n' \
		"$1" "$(esc "$2")" "$(esc "$3")"
}

form_start() { # azione
	printf '<form method="post" action="/cgi-bin/azione">\n<input type="hidden" name="t" value="%s">\n<input type="hidden" name="a" value="%s">\n' "$(token)" "$1"
}

page_end() {
	local version
	version=$(cat /etc/sweetspot-version 2>/dev/null)
	if [ -n "$version" ]; then version="Versione $version"; else version="Versione non disponibile"; fi
	printf '<footer class="page-footer"><span>SweetSpot / Reference Studio</span><span>%s</span></footer>\n' "$(esc "$version")"
	echo '</main></div></body></html>'
}

# Pulsante che invia un'azione con il gettone.
button() { # azione etichetta [campo valore] [classe]
	printf '<form method="post" action="/cgi-bin/azione" class="inline">'
	printf '<input type="hidden" name="t" value="%s">' "$(token)"
	printf '<input type="hidden" name="a" value="%s">' "$1"
	[ -n "$3" ] && printf '<input type="hidden" name="%s" value="%s">' "$3" "$(esc "$4")"
	printf '<button class="%s">%s</button></form>' "${5:-}" "$(esc "$2")"
}

# Il DAC accetta 176,4 kHz in un formato di almeno 24 bit? Il DoP mette i
# marcatori nei 8 bit alti di campioni a 24 bit: a 16 bit spariscono.
dac_dop_capable() { # scheda
	local f
	for f in S32_LE S24_3LE S24_LE; do
		printf ' %s ' "$(dac_rates "$1" "$f" 2>/dev/null)" | grep -q ' 176400 ' && return 0
	done
	return 1
}

# Prova DoP della pagina Audio: perche' adesso non darebbe un esito
# affidabile (vuoto: si puo' fare). Argomento: scheda del DAC.
dop_test_blocker() { # scheda
	if [ "$(mode)" != completa ]; then
		echo "il file di prova sta su questo player: serve la modalità completa (Lyrion su Sweetspot)"
	elif [ "$(lower "$(conf VOLUME fisso)")" = software ]; then
		echo "il volume software altera i campioni e cancella i marcatori DoP: scegli Fisso o Dal DAC"
	elif [ "$(lower "$(conf VOLUME fisso)")" = dsp ]; then
		echo "il volume a 64 bit altera i campioni e cancella i marcatori DoP: scegli Fisso o Dal DAC"
	elif [ -f "$RUN/correzione.attiva" ]; then
		echo "la correzione ambientale elabora i campioni: spegnila per la durata della prova"
	elif [ "$(lower "$(conf RICAMPIONAMENTO no)")" != no ]; then
		echo "il ricampionamento altera i campioni: spegnilo per la durata della prova"
	elif [ "$(conf FORMATO_USCITA)" = 16 ]; then
		echo "l'uscita è forzata a 16 bit (FORMATO_USCITA) e i marcatori DoP stanno nei bit alti dei campioni a 24 bit"
	elif ! dac_dop_capable "$1"; then
		echo "il DAC non dichiara 176,4 kHz a 24 o 32 bit, che il DoP richiede per il DSD64"
	fi
}
