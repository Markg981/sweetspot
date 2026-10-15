#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Profili CPU (sweetspot-cpu) e banco di prova (sweetspot-banco), con /sys e
# /proc finti: bilanciato a frequenza fissa, dinamico con governor libero e
# stati C profondi esclusi solo sui core isolati; percentili e confronto.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot"
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

E=$WORK/pc
S=$E/sys/devices/system/cpu
P=$S/cpufreq/policy0
mkdir -p "$E/proc" "$E/run" "$P"
for c in 0 1 2 3; do
	for st in 1 2; do
		mkdir -p "$S/cpu$c/cpuidle/state$st"
		echo $((st == 1 ? 2 : 200)) > "$S/cpu$c/cpuidle/state$st/latency"
	done
done
echo 2-3 > "$S/isolated"
echo 800000 > "$P/cpuinfo_min_freq"; echo 3000000 > "$P/cpuinfo_max_freq"
echo 2400000 > "$P/base_frequency"
echo "performance schedutil" > "$P/scaling_available_governors"
reset() {
	echo performance > "$P/scaling_governor"
	echo 800000 > "$P/scaling_min_freq"; echo 3000000 > "$P/scaling_max_freq"
	for d in "$S"/cpu*/cpuidle/state*; do echo 1 > "$d/disable"; done
}
cpu() {
	reset
	SWEETSPOT_SYSFS=$E/sys SWEETSPOT_PROCFS=$E/proc SWEETSPOT_RUN=$E/run SWEETSPOT_LOG=$E/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf sh "$OVERLAY/usr/bin/sweetspot-cpu" "$1" >/dev/null 2>&1
}
g() { cat "$P/scaling_governor"; }
mn() { cat "$P/scaling_min_freq"; }
mx() { cat "$P/scaling_max_freq"; }

echo "Profili CPU: bilanciato resta a frequenza fissa"
cpu bilanciato
expect "bilanciato: governor performance" "performance" "$(g)"
expect "bilanciato: minimo = massimo" "$(mn)" "$(mx)"
expect "bilanciato: a meta' tra minima e nominale" "1600000" "$(mx)"
cpu silenzio
expect "silenzio: fisso alla minima" "800000 800000" "$(mn) $(mx)"
cpu prestazioni
expect "prestazioni: fisso alla nominale" "2400000 2400000" "$(mn) $(mx)"

echo "Profili CPU: dinamico"
cpu dinamico
expect "dinamico: governor schedutil" "schedutil" "$(g)"
expect "dinamico: minima libera" "800000" "$(mn)"
expect "dinamico: massima = nominale (Turbo escluso)" "2400000" "$(mx)"
expect "dinamico: stati C profondi consentiti sui core normali" "0 0" "$(cat "$S/cpu0/cpuidle/state2/disable") $(cat "$S/cpu1/cpuidle/state2/disable")"
expect "dinamico: stato C profondo escluso sui core isolati" "1 1" "$(cat "$S/cpu2/cpuidle/state2/disable") $(cat "$S/cpu3/cpuidle/state2/disable")"
expect "dinamico: stato C veloce consentito sui core isolati" "0 0" "$(cat "$S/cpu2/cpuidle/state1/disable") $(cat "$S/cpu3/cpuidle/state1/disable")"
echo "ondemand" > "$P/scaling_available_governors"
cpu dinamico
expect "dinamico: ripiego su ondemand" "ondemand" "$(g)"
echo "performance schedutil" > "$P/scaling_available_governors"
rm -f "$S/isolated"
cpu dinamico
expect "dinamico: senza core isolati tutti gli stati C sono attivi" "0" "$(cat "$S/cpu2/cpuidle/state2/disable")"
expect "stato registrato" "dinamico schedutil" "$(cat "$E/run/cpu.stato" 2>/dev/null)"

echo "Interfaccia: profilo dinamico ammesso, bilanciato non spacciato per dinamico"
expect "azione: profilo dinamico ammesso" "1" "$(grep -c 'bilanciato|silenzio|prestazioni|dinamico)' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione")"
expect "sistema: voce dinamico" "1" "$(grep -c 'option dinamico' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/sistema")"
expect "sistema: bilanciato dichiarato non dinamico" "1" "$(grep -c 'Bilanciato: frequenza fissa intermedia, non dinamica' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/sistema")"
expect "nessun testo promette meno jitter dal profilo" "0" "$(grep -rhiE 'riduc[a-z]* (il )?jitter|meno jitter|jitter (piu|più) basso' "$OVERLAY/usr/share/sweetspot/www" "$OVERLAY/usr/bin" | grep -vc 'non ')"

echo "Banco di prova: percentili, throttling e confronto"
B="$OVERLAY/usr/bin/sweetspot-banco"
bf() { SWEETSPOT_BANCO_SOLO_FUNZIONI=1 SWEETSPOT_SYSFS=$E/sys SWEETSPOT_PROCFS=$E/proc sh -c ". $B; $*"; }
printf '# Histogram\n000001 50\n000002 40\n000003 9\n000010 1\n# Max Latencies: 000010\n' > "$WORK/h.txt"
expect "p99 dell'istogramma" "3" "$(bf p99_istogramma "$WORK/h.txt")"
expect "massimo dell'istogramma" "10" "$(bf max_istogramma "$WORK/h.txt")"
expect "istogramma vuoto: nessun valore" "" "$(bf p99_istogramma /dev/null)"
mkdir -p "$S/cpu0/thermal_throttle" "$S/cpu1/thermal_throttle"
echo 3 > "$S/cpu0/thermal_throttle/core_throttle_count"; echo 4 > "$S/cpu1/thermal_throttle/core_throttle_count"
expect "throttling x86 sommato" "7" "$(bf throttle_conta)"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "throttled=0x50005"\n' > "$WORK/bin/vcgencmd"; chmod +x "$WORK/bin/vcgencmd"
expect "throttling Pi: bit 16-19 di vcgencmd" "5" "$(PATH="$WORK/bin:$PATH" bf throttle_conta)"
printf 't_s,temp_mC,freq_kHz\n0,40000,800000\n5,60000,1600000\n' > "$WORK/c.csv"
expect "colonna: minimo media massimo" "40000 50000 60000" "$(bf colonna "$WORK/c.csv" 2)"

printf '{\n  "profilo": "dinamico",\n  "xrun": 0\n}\n' > "$WORK/a.json"
printf '{\n  "profilo": "bilanciato",\n  "xrun": 2\n}\n' > "$WORK/b.json"
tab=$(sh "$B" confronta "$WORK/a.json" "$WORK/b.json")
case "$tab" in *profilo*dinamico*bilanciato*xrun*0*2*) ok "confronto affianca i profili" ;; *) expect "confronto affianca i profili" "tabella" "$tab" ;; esac

# Esecuzione completa breve con carico finto.
mkdir -p "$E/sys/class/thermal/thermal_zone0"
echo 45000 > "$E/sys/class/thermal/thermal_zone0/temp"
echo 1600000 > "$P/scaling_cur_freq"
printf 'MemAvailable:    1000000 kB\n' > "$E/proc/meminfo"
SWEETSPOT_SYSFS=$E/sys SWEETSPOT_PROCFS=$E/proc SWEETSPOT_RUN=$E/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	SWEETSPOT_BANCO_PCM="exec sleep 30" sh "$B" -c pcm -d 1 -i 1 -o "$WORK/r" >/dev/null 2>&1
expect "banco: CSV con intestazione" "t_s,temp_mC,freq_kHz,throttle,energia_uJ,mem_libera_kB,xrun" "$(head -n 1 "$WORK/r.csv")"
expect "banco: temperatura nel riepilogo" "1" "$(grep -c '"temp_max_mC": 45000' "$WORK/r.json")"
expect "banco: latenza assente = null" "1" "$(grep -c '"latenza_p99_us": null' "$WORK/r.json")"
sh "$B" -c boh >/dev/null 2>&1
expect "banco: carico sconosciuto rifiutato" "2" "$?"

echo
echo "Profili CPU - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
