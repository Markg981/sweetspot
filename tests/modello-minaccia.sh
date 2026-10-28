#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - il modello di minaccia non deve invecchiare in silenzio: niente
# numeri di riga (file:riga) e ogni percorso citato esiste ancora.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV=$ROOT/board/sweetspot/rootfs-overlay
D=$ROOT/docs/modello-minaccia.md
FAIL=0
echo "== modello di minaccia allineato al codice"

if grep -nE '`[A-Za-z0-9_./-]+:[0-9]+([-,][0-9]+)*`' "$D"; then
	echo "  NO  numeri di riga nel documento (citare file e funzione)"; FAIL=1
else
	echo "  ok  nessun numero di riga"
fi

for p in $(grep -oE '`(tests|usr|etc|board|package)/[A-Za-z0-9_./-]+`' "$D" | tr -d '`' | sort -u); do
	if [ -e "$ROOT/$p" ] || [ -e "$OV/$p" ]; then :; else
		echo "  NO  percorso citato che non esiste: $p"; FAIL=1
	fi
done
[ "$FAIL" -eq 0 ] && echo "  ok  percorsi citati presenti"
exit "$FAIL"
