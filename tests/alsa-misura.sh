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
run() { SWEETSPOT_PROCFS=$WORK SWEETSPOT_SQLOG=$WORK/squeezelite.log SWEETSPOT_CAMPIONI=3 sh "$TOOL" -c 1 -i 0 "$@"; }
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

# XRUN recuperati entro l'intervallo: lo stato resta RUNNING a ogni campione,
# ma le fonti cumulative crescono fra un campione e l'altro. Un finto sleep
# le fa avanzare (un XRUN a ogni attesa fra due campioni).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sleep" <<'EOS'
#!/bin/sh
[ -f "$FINTO_CONTATORE" ] && echo $(( $(cat "$FINTO_CONTATORE") + 1 )) > "$FINTO_CONTATORE"
[ -n "$FINTO_REGISTRO" ] && echo "[12:00:00] _output_frames:1 XRUN" >> "$FINTO_REGISTRO"
exit 0
EOS
chmod +x "$WORK/bin/sleep"
status RUNNING 100 3900
echo 7 > "$S/xrun_counter"
out=$(PATH=$WORK/bin:$PATH; export PATH; FINTO_CONTATORE=$S/xrun_counter; export FINTO_CONTATORE; run); rc=$?
expect "xrun_counter cresciuto fra i campioni: XRUN recuperati contati" "XRUN: 2|3" "$(riga "$out" XRUN)|$rc"
rm -f "$S/xrun_counter"
printf '[12:00:00] _output_frames:1 XRUN\n[12:00:01] _output_frames:2 XRUN recover failed: -32\n' > "$WORK/squeezelite.log"
out=$(PATH=$WORK/bin:$PATH; export PATH; FINTO_REGISTRO=$WORK/squeezelite.log; export FINTO_REGISTRO; run); rc=$?
expect "registro di Squeezelite: XRUN recuperati contati (non i recuperi falliti)" "XRUN: 2|3" "$(riga "$out" XRUN)|$rc"
rm -f "$WORK/squeezelite.log"
out=$(run)
expect "senza fonti cumulative e stato RUNNING: nessun XRUN" "XRUN: 0" "$(riga "$out" XRUN)"

status CLOSED 0 0
out=$(run)
expect "uscita ferma: nessuna riproduzione" "in riproduzione: 0" "$(riga "$out" "in rip")"

SWEETSPOT_PROCFS=$WORK sh "$TOOL" -c 9 >/dev/null 2>&1; expect "scheda assente: esito 1" 1 "$?"
SWEETSPOT_PROCFS=$WORK sh "$TOOL" -c x >/dev/null 2>&1; expect "scheda non valida: esito 2" 2 "$?"

echo "alsa-misura: superati $PASS, falliti $FAIL"
[ "$FAIL" -eq 0 ]
