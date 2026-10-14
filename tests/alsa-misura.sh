#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Test di sweetspot-alsa-misura con /proc/asound simulato.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL=$ROOT/board/sweetspot/rootfs-overlay/usr/bin/sweetspot-alsa-misura
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
expect() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok  $1"; else FAIL=$((FAIL + 1)); printf '  NO  %s\n      atteso: [%s]\n      ottenuto: [%s]\n' "$1" "$2" "$3"; fi; }

S=$WORK/asound/card1/pcm0p/sub0
mkdir -p "$S"
printf 'access: RW_INTERLEAVED\nformat: S32_LE\nrate: 48000 (48000/1)\nperiod_size: 1024\nbuffer_size: 4096\n' > "$S/hw_params"
status() { printf 'state: %s\nowner_pid   : 10\ntstamp      : 0.0\ndelay       : %s\navail       : %s\navail_max   : %s\n' "$1" "$2" "$3" "$3" > "$S/status"; }
run() { SWEETSPOT_PROCFS=$WORK SWEETSPOT_CAMPIONI=3 sh "$TOOL" -c 1 -i 0 "$@"; }
riga() { echo "$1" | grep "^$2" | head -n 1; }

status RUNNING 3000 1096
out=$(run); rc=$?
expect "riproduzione regolare: esito 0" 0 "$rc"
expect "delay massimo" "delay massimo: 3000 frame (62.5 ms)" "$(riga "$out" delay)"
expect "avail minimo e occupazione" "avail minimo: 1096 frame (occupazione massima 73%)" "$(riga "$out" avail)"
expect "nessun XRUN" "XRUN: 0" "$(riga "$out" XRUN)"
expect "campioni" "campioni: 3" "$(riga "$out" campioni)"

status XRUN 0 4096
out=$(run); rc=$?
expect "XRUN: esito 3" 3 "$rc"
expect "XRUN contato una volta" "XRUN: 1" "$(riga "$out" XRUN)"

status RUNNING 100 3900
echo 7 > "$S/xrun_counter"
out=$(run)
expect "xrun_counter costante: nessun XRUN" "XRUN: 0" "$(riga "$out" XRUN)"
rm -f "$S/xrun_counter"

status CLOSED 0 0
out=$(run)
expect "uscita ferma: nessuna riproduzione" "in riproduzione: 0" "$(riga "$out" "in rip")"

SWEETSPOT_PROCFS=$WORK sh "$TOOL" -c 9 >/dev/null 2>&1; expect "scheda assente: esito 1" 1 "$?"
SWEETSPOT_PROCFS=$WORK sh "$TOOL" -c x >/dev/null 2>&1; expect "scheda non valida: esito 2" 2 "$?"

echo "alsa-misura: superati $PASS, falliti $FAIL"
[ "$FAIL" -eq 0 ]
