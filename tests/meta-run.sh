#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Meta-test di tests/run.sh: un expect fallito DOPO l'ultimo controllo
# intermedio (la coda: release-gates, riepilogo) deve far uscire la suite con 1.
# Si estraggono da run.sh le definizioni (ok/ko/expect/verifica_salti) e la
# coda reale, si inietta un expect e si controlla il codice d'uscita.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUN=$ROOT/tests/run.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0

# Definizioni: da "FAIL=0" fino a expect() compresa.
sed -n '/^FAIL=0$/,/^expect() /p' "$RUN" > "$WORK/def.sh"
# Coda: dall'ultima chiamata a release-gates alla fine.
sed -n '/^python3 "\$ROOT\/tests\/release-gates.py"/,$p' "$RUN" > "$WORK/coda.sh"
for f in def coda; do
	[ -s "$WORK/$f.sh" ] || {
		echo "  NO  meta-run: $f non trovato in run.sh"
		exit 1
	}
done

prova() { # nome rc-atteso comando-iniettato rc-release-gates
	{
		echo 'ROOT=/nonesiste'
		cat "$WORK/def.sh"
		echo "python3() { return $4; }"
		echo "$3"
		cat "$WORK/coda.sh"
	} > "$WORK/t.sh"
	sh "$WORK/t.sh" > "$WORK/out" 2>&1
	rc=$?
	if [ "$rc" = "$2" ]; then
		echo "  ok  meta-run: $1"
	else
		echo "  NO  meta-run: $1 (atteso rc $2, ottenuto $rc)"
		FAIL=$((FAIL + 1))
	fi
}

prova "expect fallito in coda, release-gates verde: esce con 1" 1 'expect "iniettato" a b' 0
prova "nessun fallimento: esce con 0" 0 ':' 0
prova "release-gates rosso senza altri ko: esce con 1" 1 ':' 1
[ "$FAIL" -eq 0 ] || exit 1
