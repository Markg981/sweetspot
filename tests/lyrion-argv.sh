#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# C-22: la password di Lyrion non deve comparire nella riga di comando di
# nessun processo (ps e /proc/*/cmdline sono leggibili da ogni utente locale).
# Si registra l'argv di wget e curl finti: con le credenziali la richiesta va a
# curl e l'intestazione arriva solo da stdin; senza, resta wget.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/run"
FAIL=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (atteso '$2', ottenuto '$3')"; FAIL=1; fi; }

cat > "$W/bin/wget" <<FINTO
#!/bin/sh
echo "\$*" >> "$W/run/wget.argv"
echo '{"result":{"_version":"9.1.1"}}'
FINTO
# curl legge la configurazione da stdin: la si registra per vederla arrivare.
cat > "$W/bin/curl" <<FINTO
#!/bin/sh
echo "\$*" >> "$W/run/curl.argv"
cat >> "$W/run/curl.stdin"
echo '{"result":{"_version":"9.1.1"}}'
FINTO
chmod +x "$W/bin/wget" "$W/bin/curl"

chiama() {
	rm -f "$W"/run/*
	# Configurazione scritta direttamente (config_build e' lento su Windows).
	printf '%s\n' "$1" > "$W/run/sweetspot.conf"
	SWEETSPOT_RUN=$W/run SWEETSPOT_LOG=$W/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_WGET=$W/bin/wget SWEETSPOT_CURL=$W/bin/curl \
		sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; lms_json '' version '?' > /dev/null" < /dev/null
}

chiama "$(printf 'LYRION_UTENTE=marco\nLYRION_PASSWORD=SegretaLunga99')"
B64=$(printf 'marco:SegretaLunga99' | base64)
expect "con credenziali: richiesta fatta da curl" "si" "$([ -s "$W/run/curl.argv" ] && echo si || echo no)"
expect "con credenziali: wget non usato" "no" "$([ -e "$W/run/wget.argv" ] && echo si || echo no)"
expect "intestazione passata a curl da stdin" "1" "$(grep -c '^header = "Authorization: Basic' "$W/run/curl.stdin")"
expect "password assente da argv" "0" "$(cat "$W"/run/*.argv 2>/dev/null | grep -c SegretaLunga99)"
expect "base64 delle credenziali assente da argv" "0" "$(cat "$W"/run/*.argv 2>/dev/null | grep -cF "$B64")"

chiama ''
expect "senza credenziali: wget e non curl" "si no" "$([ -s "$W/run/wget.argv" ] && echo si) $([ -e "$W/run/curl.argv" ] && echo si || echo no)"

[ "$FAIL" -eq 0 ]
