#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Quota dei log in RAM e metriche di diagnostica: un log che supera il tetto o
# la quota complessiva viene troncato (tenendo la coda), anche quelli di Lyrion
# e delle zone; le metriche leggono buffer, riconnessioni, restart, PSI e XRUN.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

E=$WORK/e
mkdir -p "$E/run" "$E/log/lms" "$E/proc/pressure" "$E/tmp"
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot" SWEETSPOT_RUN="$E/run" SWEETSPOT_LOG="$E/log/sweetspot.log" \
	SWEETSPOT_LOGDIR="$E/log" SWEETSPOT_TMPLOG="$E/tmp" SWEETSPOT_PROCFS="$E/proc" SWEETSPOT_SQLOG="$E/log/squeezelite.log"
printf 'LOG_FILE_KB=16\nLOG_QUOTA_KB=40\nLOG_QUOTA_SECONDI=0\n' > "$E/run/sweetspot.conf"
lib() { sh -c ". '$SWEETSPOT_LIB/common.sh'; $1"; }
dim() { wc -c < "$1" | tr -d ' '; }
# Righe di 100 byte, N volte.
riempi() { awk -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%099d\n", i }' > "$1"; }

echo "Quota dei log"
riempi "$E/log/squeezelite-dac2.log" 600   # zona secondaria: 60 KB > 16 KB
riempi "$E/log/lms/avvio.log" 600          # avvio di Lyrion
riempi "$E/log/camilladsp.log" 50
lib 'log_quota'
expect "zona secondaria: oltre il tetto per file, tronca" "si" "$([ "$(dim "$E/log/squeezelite-dac2.log")" -le 8192 ] && echo si || echo no)"
expect "avvio di Lyrion: oltre il tetto per file, tronca" "si" "$([ "$(dim "$E/log/lms/avvio.log")" -le 8192 ] && echo si || echo no)"
expect "si tiene la coda (righe piu' recenti)" "599" "$(tail -n 1 "$E/log/lms/avvio.log" | awk '{ print $1 + 0 }')"
expect "file sotto il tetto: intatto" "5000" "$(dim "$E/log/camilladsp.log")"

echo "Quota complessiva"
rm -f "$E/log/"*.log "$E/log/lms/"*.log
for n in a b c d e; do riempi "$E/log/zona-$n.log" 150; sleep 1; done  # 5 x 15 KB = 75 KB > 40 KB
lib 'log_quota'
tot=$(cat "$E"/log/zona-*.log | wc -c | tr -d ' ')
expect "totale riportato sotto la quota (40 KB)" "si" "$([ "$tot" -le 40960 ] && echo si || echo no)"
expect "nessun file azzerato: si tiene la coda di ciascuno" "0" "$(for f in "$E"/log/zona-*.log; do [ -s "$f" ] || echo vuoto; done | wc -l | tr -d " ")"
expect "il piu' vecchio e' stato ridotto" "si" "$([ "$(dim "$E/log/zona-a.log")" -lt 15000 ] && echo si || echo no)"

echo "Registro di sistema, timeline, /run e /tmp"
rm -f "$E/log/zona-"*.log
riempi "$E/log/sweetspot.log" 400; riempi "$E/run/timeline.log" 400; riempi "$E/run/prova.log" 400; riempi "$E/tmp/sweetspot-x.log" 400
lib 'log_quota'
expect "nessun log oltre il tetto" "" "$(for f in "$E/log/sweetspot.log" "$E/run/timeline.log" "$E/run/prova.log" "$E/tmp/sweetspot-x.log"; do [ "$(dim "$f")" -gt 16384 ] && echo "$f"; done)"
rm -f "$E/run/log.quota.ts"
riempi "$E/log/sweetspot.log" 400
lib 'log_quota_tick'
expect "log_quota_tick applica la quota" "si" "$([ "$(dim "$E/log/sweetspot.log")" -le 16384 ] && echo si || echo no)"
printf 'LOG_FILE_KB=16\nLOG_QUOTA_KB=40\nLOG_QUOTA_SECONDI=3600\n' > "$E/run/sweetspot.conf"
riempi "$E/log/sweetspot.log" 400
lib 'log_quota_tick'
expect "entro l'intervallo non fa nulla" "40000" "$(dim "$E/log/sweetspot.log")"

echo "Metriche"
rm -f "$E/log/"*.log "$E/run/"*.log "$E/tmp/"*.log
cat > "$E/log/squeezelite.log" <<'LOG'
[10:00:00.000000] slimproto:100 connecting to 127.0.0.1:3483
[10:00:00.500000] slimproto:101 unable to connect to server 1
[10:00:03.250000] slimproto:200 connected
[10:05:00.000000] output:300 streambuf: 1234 outputbuf: 5678
[10:05:01.000000] output:301 XRUN
[10:05:02.000000] output:302 streambuf: 2000 outputbuf: 4000
[23:59:58.000000] slimproto:100 connecting to 127.0.0.1:3483
[00:00:02.000000] slimproto:200 connected
LOG
printf 'MemTotal: 1000 kB\nMemAvailable: 777 kB\n' > "$E/proc/meminfo"
printf 'some avg10=1.50 avg60=0.50 avg300=0.10 total=100\nfull avg10=0.25 avg60=0.00 avg300=0.00 total=10\n' > "$E/proc/pressure/memory"
lib 'evento lyrion riavvio-lyrion x; evento lyrion riavvio-lyrion y; evento player riavvio-player z; evento player stato w'
sh "$OVERLAY/usr/bin/sweetspot-metriche" > "$WORK/m.txt"
m() { sed -n "s/^$1=//p" "$WORK/m.txt"; }
expect "buffer stream (ultimo valore)" "2000" "$(m buffer_stream_squeezelite)"
expect "buffer output (ultimo valore)" "4000" "$(m buffer_output_squeezelite)"
expect "riconnessioni a Lyrion" "2" "$(m riconnessioni_lyrion)"
expect "tempo dell'ultima riconnessione (attraversa la mezzanotte)" "4" "$(m riconnessione_ultima_s)"
expect "tempo massimo di riconnessione" "4" "$(m riconnessione_max_s)"
expect "restart per componente" "2|1" "$(m restart_lyrion)|$(m restart_player)"
expect "MemAvailable" "777" "$(m memoria_disponibile_kb)"
expect "pressione memoria" "1.50|0.25" "$(m pressione_memoria_some_avg10)|$(m pressione_memoria_full_avg10)"
expect "XRUN" "1|0" "$(m xrun_eventi)|$(m xrun_recuperi)"
expect "quota dei log riportata" "40960" "$(m log_quota_byte)"
rm -f "$E/log/squeezelite.log" "$E/proc/pressure/memory"
sh "$OVERLAY/usr/bin/sweetspot-metriche" > "$WORK/m.txt"
expect "dati assenti: nd, nessun errore" "nd|nd" "$(m buffer_stream_squeezelite)|$(m pressione_memoria_some_avg10)"
expect "defaults.conf dichiara la quota" "3" "$(grep -c '^LOG_\(FILE_KB\|QUOTA_KB\|QUOTA_SECONDI\)=' "$OVERLAY/etc/sweetspot/defaults.conf")"
expect "il bundle include le metriche" "1" "$(grep -c 'sweetspot-metriche' "$OVERLAY/usr/bin/sweetspot-diario")"

echo
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
