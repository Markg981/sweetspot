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
	printf '%s' "$body" | env SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="${RUN_T:-$RUNDIR}" SWEETSPOT_LOG="$A/log" \
		SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" GATEWAY_INTERFACE=CGI/1.1 \
		HTTP_HOST="${HOST_T:-127.0.0.1}" REMOTE_ADDR="${REMOTE_T:-127.0.0.1}" REQUEST_METHOD="$method" CONTENT_LENGTH=${#body} \
		HTTP_COOKIE="$cookie" REQUEST_URI="${URI_T:-/cgi-bin/audio}" SCRIPT_NAME="${SCRIPT_NAME_T:-/cgi-bin/prova}" QUERY_STRING="${QUERY_T:-}" \
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
# CGI reali dei dati: stato.json e copertina non possono saltare l'accesso.
printf '{"ts":1}\n' > "$RUNDIR/stato.json"
mkdir -p "$RUNDIR/cd"; printf 'JPEGFINTO' > "$RUNDIR/cd/copertina.jpg"
for c in stato.json copertina; do
	out=$(SCRIPT_NAME_T=/cgi-bin/$c req "$CGI/$c" GET "" "")
	if [ "$c" = copertina ]; then
		# Un'immagine non puo' mostrare un errore: senza sessione risponde con
		# il segnaposto (200, SVG), cosi' la pagina non mostra un'immagine rotta.
		expect "$c reale senza sessione: segnaposto SVG, non errore" "|image/svg+xml" "$(status "$out")|$(header "$out" Content-Type)"
		expect "$c reale senza sessione: contiene un SVG" "1" "$(printf '%s' "$out" | grep -c '<svg')"
	else
		expect "$c reale senza sessione: 401" "401" "$(status "$out")"
	fi
	expect "$c reale senza sessione: nessun dato" "0" "$(printf '%s' "$out" | grep -c -e '"ts"' -e JPEGFINTO)"
	out=$(SCRIPT_NAME_T=/cgi-bin/$c req "$CGI/$c" GET "sweetspot_sid=$sid" "")
	expect "$c reale con sessione: 200 con i dati" "1" "$(printf '%s' "$out" | grep -c -e '"ts"' -e JPEGFINTO)"
	expect "$c reale con sessione: nessun Status di errore" "" "$(status "$out")"
done
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

echo "Limite per indirizzo: chi sbaglia non blocca gli altri"
for i in 1 2 3 4 5 6; do REMOTE_T=10.0.0.9 req "$CGI/accesso" POST "" "password=no$i" > /dev/null; done
out=$(REMOTE_T=10.0.0.9 req "$CGI/accesso" POST "" "password=segreta")
expect "l'indirizzo che ha sbagliato 6 volte aspetta (429)" "429" "$(status "$out")"
case "$out" in *"riprova tra "[1-9]*" secondi"*) ok "il messaggio dice quanto aspettare (backoff: 60 s al sesto errore)" ;; *) expect "attesa" "riprova tra N secondi" "$out" ;; esac
out=$(REMOTE_T=10.0.0.10 req "$CGI/accesso" POST "" "password=segreta")
expect "un altro indirizzo entra lo stesso" "303" "$(status "$out")"
out=$(REMOTE_T=10.0.0.9 req "$CGI/accesso" POST "" "password=segreta")
expect "l'indirizzo bloccato resta bloccato" "429" "$(status "$out")"
# Il tetto globale c'e' ancora ma molto piu' in alto (6 volte la soglia per indirizzo).
rm -rf "$RUNDIR/web/tentativi"; mkdir -p "$RUNDIR/web/tentativi"
printf '29 %s\n' "$(date +%s)" > "$RUNDIR/web/tentativi/globale"
out=$(REMOTE_T=10.0.0.11 req "$CGI/accesso" POST "" "password=segreta")
expect "sotto il tetto globale (29 errori) si entra" "303" "$(status "$out")"
printf '30 %s\n' "$(date +%s)" > "$RUNDIR/web/tentativi/globale"
out=$(REMOTE_T=10.0.0.11 req "$CGI/accesso" POST "" "password=segreta")
expect "al tetto globale (30 errori) si aspetta" "429" "$(status "$out")"
rm -rf "$RUNDIR/web/tentativi"

echo "Intestazioni di sicurezza"
out=$(REMOTE_T=10.0.0.12 req "$CGI/accesso" POST "" "password=segreta")
sid=$(cookie_id "$out")
sec() { # SCRIPT_NAME -> risposta con sessione
	SCRIPT_NAME_T=$1 req "$A/pagina2" GET "sweetspot_sid=$sid" ""
}
cat > "$A/pagina2" <<EOF
#!/bin/sh
. "$SWEETSPOT_LIB/web.sh"
page_start "Prova" sistema
page_end
EOF
out=$(sec /cgi-bin/sistema)
expect "pagina normale: frame-ancestors 'none'" "1" "$(printf '%s' "$out" | grep -c "^Content-Security-Policy: frame-ancestors 'none'")"
expect "pagina normale: X-Frame-Options DENY" "DENY" "$(header "$out" X-Frame-Options)"
expect "pagina normale: X-Content-Type-Options nosniff" "nosniff" "$(header "$out" X-Content-Type-Options)"
expect "pagina normale: Referrer-Policy" "same-origin" "$(header "$out" Referrer-Policy)"
expect "pagina normale: form-action e base-uri limitati" "1|1" "$(printf '%s' "$out" | grep "^Content-Security-Policy" | grep -c "form-action 'self'")|$(printf '%s' "$out" | grep "^Content-Security-Policy" | grep -c "base-uri 'self'")"
for pg in audio stato accesso; do
	out=$(sec /cgi-bin/$pg)
	expect "$pg: incorporabile da Material (porta 9000) e da se stessa" "1" "$(printf '%s' "$out" | grep -c "^Content-Security-Policy: frame-ancestors 'self' http://\*:9000 https://\*:9000")"
	expect "$pg: senza X-Frame-Options (non sa dire la porta)" "" "$(header "$out" X-Frame-Options)"
	expect "$pg: nosniff" "nosniff" "$(header "$out" X-Content-Type-Options)"
done
out=$(sec /cgi-bin/audio)
for pg in musica archivio plugin rete bluetooth sistema; do
	expect "navigazione da Material a $pg: esce dal riquadro" "1" \
		"$(printf '%s' "$out" | grep "href=\"/cgi-bin/$pg\"" | grep -c 'target="_top"')"
done
for pg in audio stato; do
	expect "navigazione fra pagine incorporabili ($pg): resta nel riquadro" "0" \
		"$(printf '%s' "$out" | grep "href=\"/cgi-bin/$pg\"" | grep -c 'target="_top"')"
done
out=$(SCRIPT_NAME_T=/cgi-bin/sistema req "$A/pagina" GET "" "")
expect "reindirizzamento all'accesso con le intestazioni" "DENY|nosniff" "$(header "$out" X-Frame-Options)|$(header "$out" X-Content-Type-Options)"
out=$(SCRIPT_NAME_T=/cgi-bin/stato.json req "$A/pagina" GET "" "")
expect "401 dei dati con le intestazioni" "401|DENY" "$(status "$out")|$(header "$out" X-Frame-Options)"
out=$(SCRIPT_NAME_T=/cgi-bin/copertina req "$CGI/copertina" GET "" "")
expect "segnaposto della copertina con le intestazioni" "DENY|nosniff" "$(header "$out" X-Frame-Options)|$(header "$out" X-Content-Type-Options)"
out=$(HOST_T=evil.example req "$A/pagina" GET "" "")
expect "403 dell'Host non valido con le intestazioni" "403|DENY|nosniff" "$(status "$out")|$(header "$out" X-Frame-Options)|$(header "$out" X-Content-Type-Options)"
out=$(SCRIPT_NAME_T=/cgi-bin/vivo req "$CGI/vivo" GET "" "")
expect "vivo con le intestazioni" "nosniff" "$(header "$out" X-Content-Type-Options)"
out=$(SCRIPT_NAME_T=/cgi-bin/accesso req "$CGI/accesso" POST "sweetspot_sid=$sid" "a=esci&t=tokenfinto")
expect "uscita con le intestazioni" "nosniff" "$(header "$out" X-Content-Type-Options)"
out=$(SCRIPT_NAME_T=/cgi-bin/accesso req "$CGI/accesso" POST "" "password=segreta")
expect "accesso riuscito con le intestazioni" "nosniff" "$(header "$out" X-Content-Type-Options)"

echo "Nome in rete scelto dall'utente (host_guard legge la configurazione leggibile)"
# Le pagine girano come "web" e non leggono sweetspot.conf (solo di root):
# host_guard gira appena si carica common.sh, prima che web.sh scelga la copia
# senza password. Qui sweetspot.conf manca (come illeggibile), c'e' solo la copia.
R2=$A/run2
mkdir -p "$R2/web"
printf 'NOME_RETE=salotto\n' > "$R2/sweetspot.web"
out=$(RUN_T=$R2 HOST_T=salotto.local req "$A/pagina" GET "" "")
expect "salotto.local con NOME_RETE=salotto: nessun 403 (arriva al controllo di accesso)" "303" "$(status "$out")"
out=$(RUN_T=$R2 HOST_T=salotto req "$A/pagina" GET "" "")
expect "salotto (senza .local) accettato" "303" "$(status "$out")"
out=$(RUN_T=$R2 HOST_T=sweetspot.local req "$A/pagina" GET "" "")
expect "il nome predefinito non vale piu'" "403" "$(status "$out")"
expect "il messaggio del 403 dice il nome giusto" "1" "$(printf '%s' "$out" | grep -c 'http://salotto.local/')"
out=$(RUN_T=$R2 HOST_T=evil.example req "$A/pagina" GET "" "")
expect "un Host estraneo resta 403" "403" "$(status "$out")"

echo "Cookie Secure con HTTPS"
out=$(HTTPS=on REMOTE_HOST=192.168.1.77 REMOTE_T=local: req "$CGI/accesso" POST "" "password=segreta")
case "$(header "$out" Set-Cookie)" in
	*"; Secure") ok "con HTTPS il cookie e' Secure" ;;
	*) expect "con HTTPS il cookie e' Secure" "...; Secure" "$(header "$out" Set-Cookie)" ;;
esac
out=$(req "$CGI/accesso" POST "" "password=segreta")
case "$(header "$out" Set-Cookie)" in
	*Secure*) expect "in chiaro il cookie non e' Secure" "senza Secure" "$(header "$out" Set-Cookie)" ;;
	*) ok "in chiaro il cookie non e' Secure" ;;
esac
# Con HTTPS i tentativi si contano per l'indirizzo vero del client (REMOTE_HOST di stunnel).
rm -rf "$RUNDIR/web/tentativi"
(HTTPS=on REMOTE_HOST=192.168.1.77 REMOTE_T=local: req "$CGI/accesso" POST "" "password=no" > /dev/null)
expect "con HTTPS il limite e' per l'IP del client, non per quello del terminatore" "1" "$(ls "$RUNDIR/web/tentativi" | grep -c '^ip-192.168.1.77$')"
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

echo "Senza password le pagine restano chiuse (primo accesso)"
printf 'NOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"
out=$(req "$A/pagina" GET "" "")
expect "senza PASSWORD_WEB la pagina non e' mai anonima" "303|/cgi-bin/primo-accesso|0" "$(status "$out")|$(header "$out" Location)|$(printf '%s' "$out" | grep -c PAGINA)"
out=$(req "$CGI/accesso" GET "" "")
expect "senza PASSWORD_WEB l'accesso rimanda alle pagine, che portano al primo accesso" "303|/cgi-bin/audio" "$(status "$out")|$(header "$out" Location)"

printf 'PASSWORD_WEB=*\nNOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"
echo "HTTPS: rimando delle pagine in chiaro (flag di sweetspot-https)"
out=$(REMOTE_T=192.168.1.5 req "$A/pagina" GET "sweetspot_sid=$sid" "")
expect "senza HTTPS acceso nessun rimando" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
: > "$RUNDIR/https.reindirizza"
out=$(REMOTE_T=192.168.1.5 HOST_T=localhost URI_T="/cgi-bin/sistema?msg=ok" req "$A/pagina" GET "" "")
expect "con il rimando acceso: 301 verso https, stesso indirizzo" "301|https://localhost/cgi-bin/sistema?msg=ok" "$(status "$out")|$(header "$out" Location)"
expect "il rimando non esegue la pagina" "0" "$(printf '%s' "$out" | grep -c PAGINA)"
expect "il rimando ha le intestazioni di sicurezza" "nosniff" "$(header "$out" X-Content-Type-Options)"
out=$(REMOTE_T=127.0.0.1 req "$A/pagina" GET "sweetspot_sid=$sid" "")
expect "le richieste dal computer stesso non rimandano" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
out=$(HTTPS=on REMOTE_HOST=192.168.1.5 REMOTE_T=local: req "$A/pagina" GET "sweetspot_sid=$sid" "")
expect "gia' in https: nessun rimando" "PAGINA" "$(printf '%s' "$out" | grep PAGINA)"
out=$(REMOTE_T=192.168.1.5 SCRIPT_NAME_T=/cgi-bin/vivo req "$CGI/vivo" GET "" "")
expect "vivo (verifica degli aggiornamenti) non rimanda mai" "ok" "$(printf '%s' "$out" | sed -n 's/^\(ok\) .*/\1/p')"
rm -f "$RUNDIR/https.reindirizza"
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Prova\n' > "$RUNDIR/sweetspot.web"

echo "Verifica della password (sweetspot-accesso verifica)"
V=$A/verifica
mkdir -p "$V"
vrun() { # PASSWORD_WEB password
	printf 'PASSWORD_WEB=%s\n' "$1" > "$V/s.txt"
	printf '%s\n' "$2" | SWEETSPOT_RUN="$V/run" SWEETSPOT_LOG="$V/log" SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" \
		SWEETSPOT_VERIFICA_PAUSA=0 SWEETSPOT_VERIFICA_LIBERI=${VLIBERI:-20} \
		sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $V/s.txt; SWEETSPOT_TEST=1; . $OVERLAY/usr/bin/sweetspot-accesso; verify && echo si || echo no"
}
expect "password in chiaro in sweetspot.txt: giusta" "si" "$(vrun segreta segreta)"
expect "password in chiaro in sweetspot.txt: sbagliata" "no" "$(vrun segreta altra)"
expect "senza password impostata: sempre no" "no" "$(vrun '' x)"
# Limite tenuto da root: vale anche per chi chiama "verifica" direttamente.
rm -f "$V/run/accesso.errori"
VLIBERI=3
for i in 1 2 3; do vrun segreta altra > /dev/null; done
expect "troppi errori di fila: anche la password giusta e' rifiutata" "no" "$(vrun segreta segreta)"
expect "gli errori li conta root, nella sua cartella" "3" "$(cut -d' ' -f1 "$V/run/accesso.errori")"
printf '3 %s\n' "$(( $(date +%s) - 31 ))" > "$V/run/accesso.errori"
expect "passata l'attesa la password giusta vale" "si" "$(vrun segreta segreta)"
expect "una password giusta azzera gli errori" "no" "$([ -f "$V/run/accesso.errori" ] && echo si || echo no)"
VLIBERI=20
expect "verifica: un errore costa una pausa (2 secondi)" "1" "$(grep -c 'VERIFICA_PAUSA=${SWEETSPOT_VERIFICA_PAUSA:-2}' "$OVERLAY/usr/bin/sweetspot-accesso")"
expect "verifica: le verifiche passano una alla volta" "1" "$(grep -c '^	flock 8$' "$OVERLAY/usr/bin/sweetspot-accesso")"
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
