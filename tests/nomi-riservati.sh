#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - nessun file tracciato puo' avere un nome riservato di Windows
# (nul, con, prn, aux, com1-9, lpt1-9, anche con estensione): romperebbe il
# checkout su Windows. Tipico caso: un redirect `> nul` finito nel repo.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "== Nomi di file riservati su Windows"
BAD=$(git -C "$ROOT" ls-files | awk -F/ '{
	for (i = 1; i <= NF; i++) {
		n = tolower($i); sub(/\..*$/, "", n)
		if (n ~ /^(nul|con|prn|aux|com[1-9]|lpt[1-9])$/) { print $0; break }
	}
}')
if [ -n "$BAD" ]; then
	echo "  NO  nomi riservati tracciati:"; echo "$BAD" | sed 's/^/      /'
	echo "nomi-riservati: 0 ok, 1 falliti"
	exit 1
fi
echo "  ok  nessun nome riservato di Windows tra i file tracciati"
echo "nomi-riservati: 1 ok, 0 falliti"
