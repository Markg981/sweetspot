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

# Testo sicuro dentro l'HTML (anche tra virgolette negli attributi).
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'; }

# Gettone anti-CSRF valido fino al riavvio: una pagina esterna non puo'
# leggerlo, quindi non puo' inviare comandi al player al posto dell'utente.
token() {
	# Sull'immagine lo crea root all'avvio (S03); qui solo se manca (test).
	if [ ! -s "$RUN/web.token" ]; then
		mkdir -p "$RUN"
		head -c 16 /dev/urandom | md5sum | cut -c1-24 > "$RUN/web.token"
	fi
	cat "$RUN/web.token"
}

# --- Autenticazione dell'amministratore ------------------------------------------
# Con PASSWORD_WEB le pagine chiedono l'accesso (/cgi-bin/accesso): password
# verificata da root (sweetspot-accesso verifica, impronta salata MD5-crypt),
# poi una sessione con cookie HttpOnly e SameSite=Strict. Il gettone anti-CSRF
# resta richiesto a ogni azione: la sessione dice CHI e', il gettone che la
# richiesta viene dalle nostre pagine. Senza PASSWORD_WEB (predefinito, come
# prima) le pagine restano aperte a chi e' nella rete di casa.
# Le sessioni sono file in $WEBDIR/sessioni (nome = ID casuale da /dev/urandom,
# contenuto = scadenza): spariscono al riavvio.
SESSION_DIR=$WEBDIR/sessioni
SESSION_TTL=${SWEETSPOT_SESSIONE_DURATA:-28800}
SESSION_COOKIE=sweetspot_sid
LOGIN_DIR=$WEBDIR/tentativi
LOGIN_FREE=${SWEETSPOT_TENTATIVI_LIBERI:-5}

auth_enabled() { [ -n "$(conf PASSWORD_WEB)" ]; }

# ID della sessione dal cookie (solo 32 cifre esadecimali, altrimenti niente).
session_id() {
	local c id
	c=$(printf ';%s;' "${HTTP_COOKIE:-}" | tr -d ' ')
	case "$c" in *";$SESSION_COOKIE="*) ;; *) return 1 ;; esac
	id=${c#*";$SESSION_COOKIE="}
	id=${id%%;*}
	case "$id" in *[!0-9a-f]*|'') return 1 ;; esac
	[ ${#id} -eq 32 ] || return 1
	printf '%s' "$id"
}

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
	if [ -n "$1" ]; then
		printf 'Set-Cookie: %s=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%s\r\n' "$SESSION_COOKIE" "$1" "$SESSION_TTL"
	else
		printf 'Set-Cookie: %s=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0\r\n' "$SESSION_COOKIE"
	fi
}

# Limitazione dei tentativi di accesso, per indirizzo di chi li fa e in
# totale. Dopo la soglia di errori di fila si aspetta 30 secondi per ogni
# errore in piu' (al massimo 15 minuti). login_wait stampa i secondi da
# attendere (0 = si puo' provare).
login_key() {
	case "$1" in
		globale) printf globale ;;
		*) printf 'ip-%s' "${REMOTE_ADDR:-locale}" | tr -c 'a-zA-Z0-9.:-' '_' ;;
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
	auth_enabled || return 0
	session_valid && return 0
	case "${SCRIPT_NAME:-}" in
		*.json) printf 'Status: 401 Unauthorized\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n\r\naccesso richiesto\n' ;;
		*) printf 'Status: 303 See Other\r\nLocation: /cgi-bin/accesso\r\nCache-Control: no-store\r\n\r\n' ;;
	esac
	exit 0
}
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

query_param() {
	printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | while IFS= read -r v; do httpd -d "$v"; done
}

# Risposta di reindirizzamento dopo un'azione (POST -> GET).
redirect() {
	printf 'Status: 303 See Other\r\nLocation: %s\r\nCache-Control: no-store\r\n' "$1"
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

# Sezioni delle impostazioni, come su Daphile. In modalita' player libreria
# e plugin stanno sul server Lyrion dell'altro computer.
web_sections() {
	if [ "$(mode)" = completa ]; then
		echo "audio:Audio musica:Musica archivio:Archivio plugin:Plugin rete:Rete sistema:Sistema stato:Stato"
	else
		echo "audio:Audio rete:Rete sistema:Sistema stato:Stato"
	fi
}

page_start() {
	local title=$1 active=$2 refresh=$3 p msg
	printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
	cat <<HTML
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${refresh:+<meta http-equiv="refresh" content="$refresh">}
<title>$(esc "$title") - Sweetspot</title>
<link rel="stylesheet" href="/style.css">
</head>
<body><main>
<header>
<h1>Sweetspot</h1>
<nav>
HTML
	if [ "$(mode)" = completa ]; then
		printf '<a class="play" href="%s" target="_top">Ascolta</a>\n' "$(player_url)"
	fi
	for p in $(web_sections); do
		if [ "${p%%:*}" = "$active" ]; then
			printf '<a class="on" href="/cgi-bin/%s">%s</a>\n' "${p%%:*}" "${p#*:}"
		else
			printf '<a href="/cgi-bin/%s">%s</a>\n' "${p%%:*}" "${p#*:}"
		fi
	done
	if auth_enabled && [ "$active" != accesso ]; then
		printf '<form method="post" action="/cgi-bin/accesso" class="inline"><input type="hidden" name="t" value="%s"><input type="hidden" name="a" value="esci"><button>Esci</button></form>\n' "$(token)"
	fi
	echo '</nav></header>'
	msg=$(query_param msg)
	[ -n "$msg" ] && printf '<p class="msg">%s</p>\n' "$(esc "$msg")"
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
	printf '<p class="sub">Versione %s</p>\n' "$(esc "$(cat /etc/sweetspot-version 2>/dev/null)")"
	echo '</main></body></html>'
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
