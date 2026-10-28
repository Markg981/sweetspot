#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# sweetspot-installa: dopo la riscrittura della tabella, start e size letti dal
# kernel (/sys finto) devono coincidere con quanto scritto.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
expect() {
	if [ "$2" = "$3" ]; then printf '  ok  %s\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}
mk() { # nome start size
	mkdir -p "$WORK/sys/class/block/$1"
	echo "$2" > "$WORK/sys/class/block/$1/start"
	echo "$3" > "$WORK/sys/class/block/$1/size"
}
tm() {
	SWEETSPOT_TEST=1 SWEETSPOT_SYSFS=$WORK/sys SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
		sh -c ". '$OVERLAY/usr/bin/sweetspot-installa'; table_matches sdb 2048 1000 4096 2000 && echo si || echo no"
}
mk sdb1 2048 1000
mk sdb2 4096 2000
expect "tabella coerente" si "$(tm)"
mk sdb2 4096 1999
expect "size diversa: rifiutata" no "$(tm)"
mk sdb2 4096 2000
mk sdb1 2049 1000
expect "start diverso: rifiutato" no "$(tm)"
rm -rf "$WORK/sys/class/block/sdb2"
mk sdb1 2048 1000
expect "partizione mancante: rifiutata" no "$(tm)"
grep -q 'table_matches "\$disk"' "$OVERLAY/usr/bin/sweetspot-installa" && r=si || r=no
expect "il controllo e' chiamato dopo rereadpt" si "$r"
[ "$FAIL" = 0 ]
