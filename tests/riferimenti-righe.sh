#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - i riferimenti a righe di codice nei docs non devono invecchiare:
# per ogni `percorso:riga`, `percorso:riga-riga` e `percorso` (riga N / righe N-M)
# in docs/*.md, docs/evidenze/*.md e README.md il file deve esistere, le righe
# citate rientrare nel file e la prima non essere vuota.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
PASS=0
FAIL=0
t() { if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  NO  $1"; fi; }
LISTA=${TMPDIR:-/tmp}/riferimenti.$$

echo "== riferimenti file:riga nei docs"
for md in docs/*.md docs/evidenze/*.md README.md; do
	[ -f "$md" ] || continue
	sed -nE \
		-e 's/.*`([A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+):([0-9]+)(-([0-9]+))?`.*/\1 \2 \4/p' \
		-e 's/.*`([A-Za-z0-9_.\/-]+\/[A-Za-z0-9_.-]+)`,? \(righe? ([0-9]+)(-([0-9]+))?\).*/\1 \2 \4/p' \
		"$md" | while read -r f a b; do
		echo "$md $f $a ${b:-$a}"
	done
done > "$LISTA"
while read -r md f a b; do
	if [ ! -f "$f" ]; then t "$md: $f non esiste" 1; continue; fi
	n=$(wc -l < "$f")
	[ "$b" -le "$n" ] && [ "$a" -le "$b" ]; t "$md: $f:$a-$b fuori dal file ($n righe)" $?
	[ -n "$(sed -n "${a}p" "$f" | tr -d ' \t\r')" ]; t "$md: $f:$a e' una riga vuota" $?
done < "$LISTA"
rm -f "$LISTA"
echo "riferimenti-righe: $PASS ok, $FAIL falliti"
[ "$FAIL" -eq 0 ]
