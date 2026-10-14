#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Accesso dell'amministratore alle pagine: sessione con cookie, uscita,
# limite ai tentativi e operazioni privilegiate solo con sessione + gettone.
# La verifica vera della password (mkpasswd di BusyBox) si prova solo dove
# c'e' BusyBox con quell'applet; il resto gira con un helper finto.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
CGI=$OVERLAY/usr/share/sweetspot/www/cgi-bin
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot"
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

A=$WORK/a
RUNDIR=$A/run
mkdir -p "$A/bin" "$RUNDIR/web"
printf 'tokenfinto\n' > "$RUNDIR/web.token"
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"
printf 'PASSWORD_WEB=$1$sale$impronta\nNOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.conf"
# Helper finto: la password giusta e' "segreta"; il resto si annota.
cat > "$A/priv" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "sweetspot-accesso verifica" ]; then
	read -r pw
	[ "$pw" = segreta ]
	exit
fi
printf '%s\n' "$*" >> "$PRIVLOG"
exit 0
EOF
chmod +x "$A/priv"
export PRIVLOG=$A/priv.log
: > "$PRIVLOG"
# "httpd -d" di BusyBox per decodificare i moduli (come in privilegi.sh).
BB=$(command -v busybox || true)
if [ -n "$BB" ] && "$BB" httpd --help 2>&1 | grep -q -- ' -d'; then
	ln -sf "$BB" "$A/bin/httpd"
else
	printf '#!/bin/bash\n[ "$1" = -d ] || exit 1\nv=$(printf "%%s" "$2" | sed "s/+/ /g; s/%%\\(..\\)/\\\\\\\\x\\1/g")\nprintf "%%b" "$v"\n' > "$A/bin/httpd"
	chmod +x "$A/bin/httpd"
fi
PATH=$A/bin:$PATH
export PATH

# Pagina di prova: carica web.sh come ogni CGI e risponde.
cat > "$A/pagina" <<EOF
#!/bin/sh
. "$SWEETSPOT_LIB/web.sh"
printf 'Content-Type: text/plain\r\n\r\nPAGINA\n'
EOF

# req SCRIPT METODO COOKIE CORPO -> risposta del CGI
req() {
	local script=$1 method=$2 cookie=$3 body=$4
	printf '%s' "$body" | env SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$RUNDIR" SWEETSPOT_LOG="$A/log" \
		SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" GATEWAY_INTERFACE=CGI/1.1 \
		HTTP_HOST=127.0.0.1 REMOTE_ADDR=127.0.0.1 REQUEST_METHOD="$method" CONTENT_LENGTH=${#body} \
		HTTP_COOKIE="$cookie" SCRIPT_NAME="${SCRIPT_NAME_T:-/cgi-bin/prova}" QUERY_STRING="${QUERY_T:-}" \
		sh "$script" 2>&1 | tr -d '\r'
}
status() { printf '%s\n' "$1" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1; }
header() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -n 1; }
cookie_id() { printf '%s\n' "$1" | sed -n 's/^Set-Cookie: sweetspot_sid=\([0-9a-f]*\);.*/\1/p' | head -n 1; }

echo "Struttura"
expect "l'helper ammette sweetspot-accesso verifica" "1" "$(grep -c '"sweetspot-accesso", "verifica"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
expect "BusyBox con mkpasswd" "1" "$(grep -c '^CONFIG_MKPASSWD=y' "$ROOT/board/sweetspot/common/busybox.fragment")"
expect "vivo resta pubblica per l'aggiornamento" "1" "$(grep -c '^WEB_PUBLIC=1' "$CGI/vivo")"
expect "la password non compare tra gli argomenti dell'helper" "0" "$(grep -c 'verifica "' "$CGI/accesso")"

echo "Pagine dietro l'accesso"
out=$(req "$A/pagina" GET "" "")
expect "senza sessione: reindirizza all'accesso" "303|/cgi-bin/accesso" "$(status "$out")|$(header "$out" Location)"
expect "senza sessione: la pagina non viene eseguita" "0" "$(printf '%s' "$out" | grep -c PAGINA)"
out=$(SCRIPT_NAME_T=/cgi-bin/stato.json req "$A/pagina" GET "" "")
expect "dati JSON senza sessione: 401" "401" "$(status "$out")"
out=$(req "$A/pagina" GET "sweetspot_sid=../../etc/passwd" "")
expect "cookie con percorso: rifiutato" "303" "$(status "$out")"
out=$(req "$A/pagina" GET "sweetspot_sid=$(printf 'a%.0s' $(seq 1 32))" "")
expect "cookie con ID inesistente: rifiutato" "303" "$(status "$out")"

echo "Accesso"
out=$(req "$CGI/accesso" POST "" "password=sbagliata")
expect "password errata: 401 senza cookie" "401|" "$(status "$out")|$(header "$out" Set-Cookie)"
out=$(req "$CGI/accesso" POST "" "password=")
expect "password vuota: 401" "401" "$(status "$out")"
out=$(req "$CGI/accesso" POST "" "password=segreta&next=/cgi-bin/sistema")
sid=$(cookie_id "$out")
expect "password giusta: 303 alla pagina richiesta" "303|/cgi-bin/sistema" "$(status "$out")|$(header "$out" Location)"
expect "ID della sessione: 32 cifre esadecimali" "32" "${#sid}"
case "$(header "$out" Set-Cookie)" in
	*"; Path=/; HttpOnly; SameSite=Strict; Max-Age="*) ok "cookie HttpOnly e SameSite=Strict" ;;
	*) expect "cookie HttpOnly e SameSite=Strict" "HttpOnly;SameSite=Strict" "$(header "$out" Set-Cookie)" ;;
esac
# Su file system senza permessi Unix (sviluppo su Windows) il controllo non vale.
: > "$A/perm"; chmod 600 "$A/perm"
if [ "$(stat -c %a "$A/perm" 2>/dev/null)" = 600 ]; then
	expect "sessione salvata, solo del proprietario" "600" "$(stat -c %a "$RUNDIR/web/sessioni/$sid")"
else
	echo "  (permessi Unix non disponibili: controllo dei permessi della sessione saltato)"
fi
exp=$(cat "$RUNDIR/web/sessioni/$sid")
now=$(date +%s)
[ "$exp" -gt "$now" ] && [ "$exp" -le $((now + 28800)) ] && r=scadenza-ok || r=$exp
expect "la sessione scade entro 8 ore" "scadenza-ok" "$r"
out2=$(req "$CGI/accesso" POST "" "password=segreta")
expect "ogni accesso ha un ID diverso" "diverso" "$([ "$(cookie_id "$out2")" != "$sid" ] && echo diverso)"
out=$(req "$CGI/accesso" POST "" "password=segreta&next=http://evil.example/")
expect "next verso un altro sito: ignorato" "/cgi-bin/audio" "$(header "$out" Location)"
out=$(req "$CGI/accesso" POST "" "password=segreta&next=/cgi-bin/../x")
expect "next con .. : ignorato" "/cgi-bin/audio" "$(header "$out" Location)"
out=$(req "$A/pagina" GET "sweetspot_sid=$sid" "")
expect "con la sessione la pagina risponde" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
out=$(req "$A/pagina" GET "altro=1; sweetspot_sid=$sid; x=y" "")
expect "cookie tra altri cookie" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
printf '%s\n' "$((now - 5))" > "$RUNDIR/web/sessioni/$sid"
out=$(req "$A/pagina" GET "sweetspot_sid=$sid" "")
expect "sessione scaduta: reindirizza" "303" "$(status "$out")"
expect "sessione scaduta: il file viene tolto" "no" "$([ -f "$RUNDIR/web/sessioni/$sid" ] && echo si || echo no)"

echo "Limite ai tentativi"
rm -rf "$RUNDIR/web/tentativi"
for i in 1 2 3 4; do req "$CGI/accesso" POST "" "password=no$i" > /dev/null; done
out=$(req "$CGI/accesso" POST "" "password=no5")
expect "quinto errore: ancora 401" "401" "$(status "$out")"
out=$(req "$CGI/accesso" POST "" "password=segreta")
expect "dopo 5 errori anche la password giusta aspetta (429)" "429|" "$(status "$out")|$(cookie_id "$out")"
case "$out" in *"riprova tra "*" secondi"*) ok "il messaggio dice quanto aspettare" ;; *) expect "messaggio di attesa" "riprova tra N secondi" "$out" ;; esac
f=$(ls "$RUNDIR/web/tentativi"/ip-* | head -n 1)
printf '5 %s\n' "$(( $(date +%s) - 120 ))" > "$f"
rm -f "$RUNDIR/web/tentativi/globale"
out=$(req "$CGI/accesso" POST "" "password=segreta")
expect "passata l'attesa si puo' entrare" "303" "$(status "$out")"
expect "l'accesso riuscito azzera i tentativi" "0" "$(ls "$RUNDIR/web/tentativi" | grep -c .)"
printf '40 %s\n' "$(date +%s)" > "$RUNDIR/web/tentativi/globale"
out=$(req "$CGI/accesso" POST "" "password=segreta")
expect "limite globale oltre il limite per indirizzo" "429" "$(status "$out")"
rm -rf "$RUNDIR/web/tentativi"

echo "Uscita"
out=$(req "$CGI/accesso" POST "" "password=segreta")
sid=$(cookie_id "$out")
out=$(req "$CGI/accesso" POST "sweetspot_sid=$sid" "a=esci&t=sbagliato")
expect "uscita senza gettone: la sessione resta" "si" "$([ -f "$RUNDIR/web/sessioni/$sid" ] && echo si || echo no)"
out=$(req "$CGI/accesso" POST "sweetspot_sid=$sid" "a=esci&t=tokenfinto")
expect "uscita: sessione tolta e cookie cancellato" "no|1" "$([ -f "$RUNDIR/web/sessioni/$sid" ] && echo si || echo no)|$(printf '%s' "$out" | grep -c 'sweetspot_sid=;.*Max-Age=0')"

echo "Operazioni privilegiate: sessione e gettone"
out=$(req "$CGI/accesso" POST "" "password=segreta")
sid=$(cookie_id "$out")
: > "$PRIVLOG"
SCRIPT_NAME_T=/cgi-bin/azione req "$CGI/azione" POST "" "t=tokenfinto&a=riavvia" > /dev/null
expect "riavvio con gettone ma senza sessione: nulla" "0" "$(wc -c < "$PRIVLOG" | tr -d ' ')"
SCRIPT_NAME_T=/cgi-bin/azione req "$CGI/azione" POST "sweetspot_sid=$sid" "a=riavvia" > /dev/null
expect "riavvio con sessione ma senza gettone: nulla" "0" "$(wc -c < "$PRIVLOG" | tr -d ' ')"
SCRIPT_NAME_T=/cgi-bin/azione req "$CGI/azione" POST "sweetspot_sid=$sid" "t=sbagliato&a=riavvia" > /dev/null
expect "riavvio con sessione e gettone sbagliato: nulla" "0" "$(wc -c < "$PRIVLOG" | tr -d ' ')"
SCRIPT_NAME_T=/cgi-bin/azione req "$CGI/azione" POST "sweetspot_sid=$sid" "t=tokenfinto&a=riavvia" > /dev/null
expect "riavvio con sessione e gettone: eseguito" "@riavvia" "$(cat "$PRIVLOG")"

echo "Senza password le pagine restano aperte"
printf 'NOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"
out=$(req "$A/pagina" GET "" "")
expect "senza PASSWORD_WEB nessun accesso richiesto" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
out=$(req "$CGI/accesso" GET "" "")
expect "senza PASSWORD_WEB l'accesso rimanda alle pagine" "303|/cgi-bin/audio" "$(status "$out")|$(header "$out" Location)"
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"

echo "Verifica della password (sweetspot-accesso verifica)"
V=$A/verifica
mkdir -p "$V"
vrun() { # PASSWORD_WEB password
	printf 'PASSWORD_WEB=%s\n' "$1" > "$V/s.txt"
	printf '%s\n' "$2" | SWEETSPOT_RUN="$V/run" SWEETSPOT_LOG="$V/log" SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" \
		sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $V/s.txt; SWEETSPOT_TEST=1; . $OVERLAY/usr/bin/sweetspot-accesso; verify && echo si || echo no"
}
expect "password in chiaro in sweetspot.txt: giusta" "si" "$(vrun segreta segreta)"
expect "password in chiaro in sweetspot.txt: sbagliata" "no" "$(vrun segreta altra)"
expect "senza password impostata: sempre no" "no" "$(vrun '' x)"
if [ -n "$BB" ] && "$BB" mkpasswd -m md5 -S ab test 2>/dev/null | grep -q '^\$1\$ab\$'; then
	ln -sf "$BB" "$V/mkpasswd"
	PATH=$V:$PATH
	h=$("$BB" mkpasswd -m md5 -S sale1234 segreta)
	expect "impronta salata: password giusta" "si" "$(vrun "$h" segreta)"
	expect "impronta salata: password sbagliata" "no" "$(vrun "$h" segreta2)"
	expect "impronta salata: la sale e' nell'impronta" '$1$sale1234$' "$(printf '%s' "$h" | cut -c1-12)"
else
	echo "  (mkpasswd di BusyBox non disponibile: verifica dell'impronta salata saltata)"
fi

echo
echo "Accesso - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
