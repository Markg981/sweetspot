#!/bin/bash
# read_form rifiuta corpi POST senza tetto o con lunghezza non numerica (413).
OVERLAY=$(cd "$(dirname "$0")/.." && pwd)/board/sweetspot/rootfs-overlay
LIB=$OVERLAY/usr/lib/sweetspot
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#!/bin/sh
printf "%%s\n" "$2"
' > "$W/httpd"; chmod +x "$W/httpd"
t() { # NOME ATTESO CONTENT_LENGTH CORPO
	local out
	out=$(printf '%s' "$4" | env -i PATH="$W:$PATH" SWEETSPOT_LIB="$LIB" REQUEST_METHOD=POST CONTENT_LENGTH="$3" \
		sh -c '. "$SWEETSPOT_LIB/web.sh"; read_form; echo "OK:$F_a"' 2>&1 | tr -d '\r')
	case "$out" in
	*"$2"*) echo "ok - $1" ;;
	*) echo "FAIL - $1: $out"; fail=1 ;;
	esac
}
t "corpo piccolo letto" "OK:1" 3 "a=1"
t "troppo grande" "413" 999999999 "a=1"
t "non numerico" "413" "abc" "a=1"
t "negativo" "413" "-5" "a=1"
t "enorme" "413" 99999999999999999999 "a=1"
exit $fail
