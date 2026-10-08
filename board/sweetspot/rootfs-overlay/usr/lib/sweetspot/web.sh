# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - funzioni per le pagine web (CGI dell'httpd di BusyBox).

. "${SWEETSPOT_LIB:-/usr/lib/sweetspot}/common.sh"

# Testo sicuro dentro l'HTML.
esc() { httpd -e "$1"; }

# Gettone anti-CSRF valido fino al riavvio: una pagina esterna non puo'
# leggerlo, quindi non puo' inviare comandi al player al posto dell'utente.
token() {
	if [ ! -s "$RUN/web.token" ]; then
		mkdir -p "$RUN"
		head -c 16 /dev/urandom | md5sum | cut -c1-24 > "$RUN/web.token"
	fi
	cat "$RUN/web.token"
}

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

query_param() {
	printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | while IFS= read -r v; do httpd -d "$v"; done
}

# Risposta di reindirizzamento dopo un'azione (POST -> GET).
redirect() {
	printf 'Status: 303 See Other\r\nLocation: %s\r\nCache-Control: no-store\r\n\r\n' "$1"
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
		echo "audio:Audio musica:Musica rete:Rete plugin:Plugin sistema:Sistema stato:Stato"
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
