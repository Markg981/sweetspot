#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - lock di avvio dei lavori in background (C-10): due avvii
# concorrenti non devono partire entrambi, un lock orfano si recupera.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
ok=0; ko=0
expect() { # descrizione atteso ottenuto
	if [ "$2" = "$3" ]; then ok=$((ok + 1)); echo "  ok  $1"
	else ko=$((ko + 1)); echo "  NO  $1 (atteso [$2], ottenuto [$3])"; fi
}
echo "== Lock di avvio dei lavori"
LIB="SWEETSPOT_RUN=$W/run; . $OVERLAY/usr/lib/sweetspot/common.sh"

# Molti avvii contemporanei: il lavoro simulato parte una volta sola.
mkdir -p "$W/run"
for i in 1 2 3 4 5 6 7 8; do
	sh -c "$LIB; if avvio_lock $W/run/job; then sleep 5; echo \$\$ >> $W/partiti; fi" &
done
wait
expect "8 avvii concorrenti: ne parte uno solo" 1 "$(wc -l < "$W/partiti" | tr -d ' ')"

# Dopo il rilascio si puo' riavviare.
sh -c "$LIB; avvio_lock $W/run/job && avvio_unlock $W/run/job; avvio_lock $W/run/job" && r=si || r=no
expect "dopo il rilascio il lock si riprende" si "$r"

# Lock orfano (pid morto): recuperato.
rm -rf "$W/run/job.lock"; mkdir "$W/run/job.lock"
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" > "$W/run/job.lock/pid"
sh -c "$LIB; avvio_lock $W/run/job" && r=si || r=no
expect "lock orfano recuperato" si "$r"

# Lock di un processo vivo: rifiutato.
rm -rf "$W/run/job.lock"; mkdir "$W/run/job.lock"
sleep 20 > /dev/null 2>&1 & vivo=$!
echo "$vivo" > "$W/run/job.lock/pid"
sh -c "$LIB; avvio_lock $W/run/job" && r=si || r=no
kill "$vivo" 2>/dev/null; wait "$vivo" 2>/dev/null
expect "lock di un processo vivo rifiutato" no "$r"

# Tutti e quattro gli script usano il lock attorno all'avvio.
for s in installa copia cd spazio; do
	expect "sweetspot-$s prende il lock" si \
		"$(grep -q 'avvio_lock' "$OVERLAY/usr/bin/sweetspot-$s" && echo si || echo no)"
done
echo "lock-avvio: $ok ok, $ko falliti"
[ "$ko" = 0 ]
