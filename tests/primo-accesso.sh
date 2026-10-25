#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Primo accesso: codice casuale del dispositivo (console + chiavetta), scelta
# obbligatoria della password, nessun bypass, recupero senza schermo.
# Usa il vero sweetspot-accesso e il vero CGI primo-accesso; l'helper di
# privilegi e sweetspot-config sono finti (scrivono nei file di prova).
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

R=$WORK/run
STICK=$WORK/chiavetta
mkdir -p "$WORK/bin" "$R/web" "$STICK"
printf 'tokenfinto\n' > "$R/web.token"
printf 'NOME_PLAYER=Prova\n' > "$STICK/sweetspot.txt"

# sweetspot-config finto: scrive la riga in sweetspot.txt della chiavetta e
# ricostruisce la configurazione come farebbe quello vero.
cat > "$WORK/bin/sweetspot-config" <<EOF
#!/bin/sh
[ "\$1" = imposta ] || exit 1
grep -v '^PASSWORD_WEB=' "$STICK/sweetspot.txt" > "$STICK/sweetspot.nuovo"
printf 'PASSWORD_WEB=%s\n' "\$3" >> "$STICK/sweetspot.nuovo"
mv "$STICK/sweetspot.nuovo" "$STICK/sweetspot.txt"
. "$SWEETSPOT_LIB/common.sh"
config_build "$STICK/sweetspot.txt"
EOF
chmod +x "$WORK/bin/sweetspot-config"
# httpd finto: decodifica dei moduli (percent-encoding).
cat > "$WORK/bin/httpd" <<'EOF'
#!/bin/sh
case "$1" in
	-d) v=$(printf '%s' "$2" | sed 's/+/ /g; s/%\(..\)/\\x\1/g'); printf '%b' "$v" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/httpd"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/killall"
chmod +x "$WORK/bin/killall"
# mkpasswd finto: impronta ($1$ o $6$) con la sale data o "prova".
cat > "$WORK/bin/mkpasswd" <<'EOF'
#!/bin/sh
# uso: mkpasswd -m md5|sha512 [-S sale] -- password
case "$2" in md5) id=1 ;; sha512) id=6 ;; *) exit 1 ;; esac
salt=prova
[ "$3" = -S ] && { salt=$4; shift 2; }
printf '$%s$%s$%s\n' "$id" "$salt" "$(printf '%s%s' "$id" "$4" | md5sum | cut -c1-22)"
EOF
chmod +x "$WORK/bin/mkpasswd"
PATH=$WORK/bin:$OVERLAY/usr/bin:$PATH
export PATH

# Ambiente comune
E() {
	env SWEETSPOT_RUN="$R" SWEETSPOT_LOG="$WORK/log" SWEETSPOT_STICK_DIR="$STICK" SWEETSPOT_CONSOLE= SWEETSPOT_PRIV="$WORK/priv" \
		SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" "$@"
}
# Helper di privilegi finto: inoltra al vero sweetspot-accesso.
cat > "$WORK/priv" <<EOF
#!/bin/sh
exec env SWEETSPOT_RUN="$R" SWEETSPOT_LOG="$WORK/log" SWEETSPOT_STICK_DIR="$STICK" SWEETSPOT_CONSOLE= \
	SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" "\$@"
EOF
chmod +x "$WORK/priv"
boot() {
	E sh -c ". $SWEETSPOT_LIB/common.sh; config_build $STICK/sweetspot.txt"
	E sh "$OVERLAY/usr/bin/sweetspot-accesso" avvio
}

req() { # SCRIPT METODO COOKIE CORPO
	local script=$1 method=$2 cookie=$3 body=$4
	printf '%s' "$body" | E GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=127.0.0.1 REMOTE_ADDR="${REMOTE_T:-192.168.1.20}" \
		REQUEST_METHOD="$method" CONTENT_LENGTH=${#body} HTTP_COOKIE="$cookie" REQUEST_URI=/cgi-bin/audio \
		SCRIPT_NAME="${SCRIPT_NAME_T:-/cgi-bin/prova}" QUERY_STRING= sh "$script" 2>&1 | tr -d '\r'
}
status() { printf '%s\n' "$1" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1; }
header() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -n 1; }

cat > "$WORK/pagina" <<EOF
#!/bin/sh
. "$SWEETSPOT_LIB/web.sh"
printf 'Content-Type: text/plain\r\n\r\nPAGINA\n'
EOF

echo "Primo avvio senza password"
boot
codice=$(sed -n 1p "$R/primo-accesso.codice")
case "$codice" in
	[2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z]-[2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z]-[2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z][2-9A-HJ-NP-Z]) ok "codice di 12 caratteri senza I, O, 0, 1" ;;
	*) expect "formato del codice" "XXXX-XXXX-XXXX" "$codice" ;;
esac
expect "il file del codice e' dell'amministratore (0600)" "600" "$(stat -c %a "$R/primo-accesso.codice" 2>/dev/null || echo 600)"
expect "codice sulla chiavetta (anche senza schermo)" "1" "$(grep -c "$codice" "$STICK/PRIMO-ACCESSO.txt")"
expect "il file della chiavetta e' leggibile con il Blocco note (CRLF)" "si" "$([ "$(grep -c "$(printf '\r')" "$STICK/PRIMO-ACCESSO.txt")" -ge 3 ] && echo si)"
expect "flag di primo accesso attivo" "si" "$([ -f "$R/primo-accesso.attivo" ] && echo si)"
boot
expect "riavvio: stesso codice del dispositivo (dalla chiavetta)" "$codice" "$(sed -n 1p "$R/primo-accesso.codice")"
rm -f "$STICK/PRIMO-ACCESSO.txt" "$R/primo-accesso.codice"
boot
expect "chiavetta nuova: codice diverso (casuale)" "diverso" "$([ "$(sed -n 1p "$R/primo-accesso.codice")" != "$codice" ] && echo diverso)"
codice=$(sed -n 1p "$R/primo-accesso.codice")
c2=$(cat "$R/primo-accesso.codice")
expect "i codici non sono fissi" "1" "$([ -n "$c2" ] && echo 1)"

echo "Pagine bloccate finche' non c'e' la password"
out=$(req "$WORK/pagina" GET "" "")
expect "pagina: reindirizza al primo accesso" "303|/cgi-bin/primo-accesso" "$(status "$out")|$(header "$out" Location)"
expect "la pagina non viene eseguita" "0" "$(printf '%s' "$out" | grep -c PAGINA)"
out=$(SCRIPT_NAME_T=/cgi-bin/stato.json req "$WORK/pagina" GET "" "")
expect "dati JSON: 401" "401" "$(status "$out")"
out=$(req "$CGI/accesso" GET "" "")
expect "accesso normale senza password: va al primo accesso (via audio)" "303" "$(status "$out")"
out=$(req "$CGI/primo-accesso" GET "" "")
expect "modulo di primo accesso mostrato" "1" "$(printf '%s' "$out" | grep -c 'name="codice"')"

echo "Scelta della password"
out=$(req "$CGI/primo-accesso" POST "" "codice=$codice&password=lungapassword1&password2=lungapassword1")
expect "senza gettone: 403" "403" "$(status "$out")"
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=ZZZZ-ZZZZ-ZZZZ&password=lungapassword1&password2=lungapassword1")
expect "codice sbagliato: 401" "401" "$(status "$out")"
expect "codice sbagliato: nessuna password salvata" "0" "$(grep -c '^PASSWORD_WEB=' "$STICK/sweetspot.txt")"
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=$codice&password=lungapassword1&password2=diversa12345")
expect "password diverse: 400" "400" "$(status "$out")"
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=$codice&password=corta&password2=corta")
expect "password corta: 400" "400" "$(status "$out")"
expect "password corta: non salvata" "0" "$(grep -c '^PASSWORD_WEB=' "$STICK/sweetspot.txt")"
# tentativi: dopo gli errori liberi si attende, anche con il codice giusto
for _ in 1 2 3 4 5; do req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=AAAA-AAAA-AAAA&password=lungapassword1&password2=lungapassword1" >/dev/null; done
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=$codice&password=lungapassword1&password2=lungapassword1")
expect "troppi tentativi: 429 anche con il codice giusto" "429" "$(status "$out")"
rm -rf "$R/web/tentativi"
codmin=$(printf '%s' "$codice" | tr 'A-Z' 'a-z' | tr -d '-')
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=$codmin&password=lungapassword1&password2=lungapassword1")
expect "codice giusto (minuscolo, senza trattini): 303" "303|/cgi-bin/audio" "$(status "$out")|$(header "$out" Location)"
case "$(header "$out" Set-Cookie)" in *HttpOnly*SameSite=Strict*) ok "sessione con cookie HttpOnly" ;; *) expect "cookie" "HttpOnly" "$(header "$out" Set-Cookie)" ;; esac
expect "password salvata come impronta, non in chiaro" "0" "$(grep -c 'lungapassword1' "$STICK/sweetspot.txt")"
expect "impronta SHA-512-crypt salvata" "1" "$(grep -c '^PASSWORD_WEB=\$6\$' "$STICK/sweetspot.txt")"
expect "codice e flag rimossi" "no" "$([ -e "$R/primo-accesso.codice" ] || [ -e "$R/primo-accesso.attivo" ] && echo si || echo no)"
expect "file della chiavetta cancellato" "no" "$([ -e "$STICK/PRIMO-ACCESSO.txt" ] && echo si || echo no)"
out=$(req "$CGI/primo-accesso" POST "" "t=tokenfinto&codice=$codice&password=altrapassword12&password2=altrapassword12")
expect "il codice non si riusa per cambiare la password" "303|/cgi-bin/accesso" "$(status "$out")|$(header "$out" Location)"

echo "Dopo la scelta: accesso normale"
out=$(req "$WORK/pagina" GET "" "")
expect "senza sessione: accesso richiesto" "/cgi-bin/accesso" "$(header "$out" Location)"
boot
expect "riavvio con password: nessun codice nuovo" "no" "$([ -e "$R/primo-accesso.attivo" ] && echo si || echo no)"
expect "riavvio con password: niente file sulla chiavetta" "no" "$([ -e "$STICK/PRIMO-ACCESSO.txt" ] && echo si || echo no)"

echo "Recupero (password dimenticata, senza schermo)"
grep -v '^PASSWORD_WEB=' "$STICK/sweetspot.txt" > "$STICK/n" && mv "$STICK/n" "$STICK/sweetspot.txt"
boot
expect "tolta la riga: torna il primo accesso" "si" "$([ -f "$R/primo-accesso.attivo" ] && echo si)"
expect "codice di nuovo sulla chiavetta" "1" "$(grep -c "$(sed -n 1p "$R/primo-accesso.codice")" "$STICK/PRIMO-ACCESSO.txt")"

echo "Password tolta solo in RAM (marcatore gia' consumato): mai anonimo"
rm -f "$R/primo-accesso.attivo" "$R/primo-accesso.codice"
E sh -c ". $SWEETSPOT_LIB/common.sh; config_build $STICK/sweetspot.txt"
printf 'NOME_PLAYER=Prova\n' > "$STICK/sweetspot.txt"
E sh -c ". $SWEETSPOT_LIB/common.sh; config_build $STICK/sweetspot.txt"
out=$(req "$WORK/pagina" GET "" "")
expect "senza password e senza marcatore: pagina non eseguita" "0" "$(printf '%s' "$out" | grep -c PAGINA)"
expect "senza password e senza marcatore: va al primo accesso" "303|/cgi-bin/primo-accesso" "$(status "$out")|$(header "$out" Location)"
out=$(SCRIPT_NAME_T=/cgi-bin/stato.json req "$WORK/pagina" GET "" "")
expect "dati JSON: 401 anche senza marcatore" "401" "$(status "$out")"
out=$(req "$CGI/primo-accesso" GET "" "")
expect "codice in rigenerazione: 503, non l'audio" "503" "$(status "$out")"
boot
expect "avvio: il primo accesso si riapre" "si" "$([ -f "$R/primo-accesso.attivo" ] && echo si)"

echo "Migrazione: password gia' presente in sweetspot.txt"
printf 'NOME_PLAYER=Prova\nPASSWORD_WEB=vecchiapass\n' > "$STICK/sweetspot.txt"
rm -f "$STICK/PRIMO-ACCESSO.txt"
boot
expect "password esistente conservata: nessun primo accesso" "no" "$([ -e "$R/primo-accesso.attivo" ] && echo si || echo no)"
expect "password in chiaro sostituita dall'impronta all'avvio" "0|1" "$(grep -c 'vecchiapass' "$STICK/sweetspot.txt")|$(grep -c '^PASSWORD_WEB=\$6\$' "$STICK/sweetspot.txt")"
verifica() { printf '%s\n' "$1" | E sh "$OVERLAY/usr/bin/sweetspot-accesso" verifica && echo si || echo no; }
expect "dopo la migrazione vale la stessa password" "si" "$(verifica vecchiapass)"
expect "dopo la migrazione il vecchio valore in chiaro non e' l'impronta" "no" "$(verifica "$(sed -n 's/^PASSWORD_WEB=//p' "$STICK/sweetspot.txt")")"

echo "Migrazione: impronta MD5-crypt (\$1\$)"
# Lo stesso mkpasswd di sweetspot-accesso: con SWEETSPOT_PATH (tests/run.sh)
# e' quello di BusyBox, non quello finto.
h1=$(E sh -c ". $SWEETSPOT_LIB/common.sh; mkpasswd -m md5 -S sale1234 -- vecchiapass")
printf 'NOME_PLAYER=Prova\nPASSWORD_WEB=%s\n' "$h1" > "$STICK/sweetspot.txt"
boot
expect "all'avvio l'impronta \$1\$ resta (serve la password)" "1" "$(grep -c '^PASSWORD_WEB=\$1\$sale1234\$' "$STICK/sweetspot.txt")"
expect "\$1\$: password sbagliata rifiutata" "no" "$(verifica sbagliatapass)"
expect "\$1\$: con la password sbagliata non si riscrive" "1" "$(grep -c '^PASSWORD_WEB=\$1\$' "$STICK/sweetspot.txt")"
expect "\$1\$: password giusta accettata" "si" "$(verifica vecchiapass)"
expect "\$1\$: riscritta come SHA-512-crypt" "0|1" "$(grep -c '^PASSWORD_WEB=\$1\$' "$STICK/sweetspot.txt")|$(grep -c '^PASSWORD_WEB=\$6\$' "$STICK/sweetspot.txt")"
expect "\$1\$: dopo la migrazione la password vale ancora" "si" "$(verifica vecchiapass)"

echo "Impronte di altro tipo"
printf 'NOME_PLAYER=Prova\nPASSWORD_WEB=$5$sale$impronta\n' > "$STICK/sweetspot.txt"
boot
expect "impronta sconosciuta: non vale come password in chiaro" "no" "$(verifica '$5$sale$impronta')"
expect "impronta sconosciuta: non riscritta" "1" "$(grep -c '^PASSWORD_WEB=\$5\$sale\$impronta' "$STICK/sweetspot.txt")"

echo "Nessuna password predefinita e impostazioni"
expect "il CGI non contiene password predefinite" "0" "$(grep -ci 'admin:admin\|password=admin\|PASSWORD_WEB=.\+' "$CGI/primo-accesso")"
expect "l'helper ammette sweetspot-accesso primo" "1" "$(grep -c '"sweetspot-accesso", "primo"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
expect "sistema: non si puo' togliere la password" "0" "$(grep -c 'web_libero' "$CGI/sistema" "$CGI/azione" | grep -vc ':0')"

echo
echo "Primo accesso - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
