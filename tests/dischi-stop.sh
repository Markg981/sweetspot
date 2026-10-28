#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# C-13: lo stop di S25sweetspot-dischi ferma i lavori attivi (TERM, poi KILL)
# e i temporanei vengono rimossi dalla trap del lavoro.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
INIT=$ROOT/board/sweetspot/rootfs-overlay/etc/init.d/S25sweetspot-dischi
command -v setsid > /dev/null 2>&1 || { echo "dischi-stop: setsid assente, test saltato"; exit 0; }
W=$(mktemp -d)
trap 'kill -KILL "-$P1" "-$P2" 2>/dev/null; rm -rf "$W"' EXIT
FAIL=0
expect() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else FAIL=1; echo "  NO  $1: atteso [$2], ottenuto [$3]"; fi; }
mkdir -p "$W/cd"
export SWEETSPOT_RUN=$W SWEETSPOT_STOP_ATTESA=2 SWEETSPOT_STOP_ATTESA_DISCO=1

# Lavoro 1: come il rip, ha la trap TERM e toglie il temporaneo.
touch "$W/cd/lavoro.tmp"
setsid sh -c 'trap "rm -f \"$1\"; exit 143" TERM; while :; do sleep 1; done' sh "$W/cd/lavoro.tmp" > /dev/null 2>&1 < /dev/null &
P1=$!; echo "$P1" > "$W/cd/pid"
# Lavoro 2: ignora TERM, deve cadere con KILL.
setsid sh -c 'trap "" TERM; while :; do sleep 1; done' > /dev/null 2>&1 < /dev/null &
P2=$!; echo "$P2" > "$W/copia.pid"; echo copia > "$W/copia.stato"
sleep 1
sh "$INIT" stop > /dev/null 2>&1
sleep 1
kill -0 "$P1" 2>/dev/null; expect "lavoro con trap terminato" 1 $?
kill -0 "$P2" 2>/dev/null; expect "lavoro che ignora TERM ucciso con KILL" 1 $?
[ -e "$W/cd/lavoro.tmp" ]; expect "temporaneo rimosso dalla trap" 1 $?
expect "stato copia annullata" annullata "$(cat "$W/copia.stato")"
exit $FAIL
