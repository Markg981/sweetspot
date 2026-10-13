#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Profilo energetico: parametri di avvio (autotune), applicazione a runtime
# (sweetspot-cpu) e script di misura/confronto (sweetspot-energia), con
# /sys e /proc finti.
# shellcheck disable=SC2016
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

# Computer finto: 2 core con SMT, cpufreq, cpuidle, termica, RAPL, DAC.
E=$WORK/pc
S=$E/sys/devices/system/cpu
mkdir -p "$E/proc/pressure" "$E/proc/asound/card0/pcm0p/sub0" "$E/run" "$S/smt"
for c in 0 1 2 3; do
	mkdir -p "$S/cpu$c/topology" "$S/cpu$c/cpuidle/state1"
	echo "$((c % 2)),$(( (c % 2) + 2 ))" > "$S/cpu$c/topology/thread_siblings_list"
	echo 0 > "$S/cpu$c/cpuidle/state1/disable"
done
echo 0-3 > "$S/online"
echo on > "$S/smt/control"
printf 'flags\t: tsc\n' > "$E/proc/cpuinfo"
P=$S/cpufreq/policy0
mkdir -p "$P"
echo 800000 > "$P/cpuinfo_min_freq"; echo 2400000 > "$P/cpuinfo_max_freq"
echo "performance schedutil" > "$P/scaling_available_governors"
echo performance > "$P/scaling_governor"
echo 800000 > "$P/scaling_min_freq"; echo 2400000 > "$P/scaling_max_freq"
echo 1600000 > "$P/scaling_cur_freq"

# Esegue un comando con la configurazione ENERGIA=$1 (vuota: predefinita).
env_run() {
	local en=$1
	shift
	rm -f "$E/run/sweetspot.conf"
	[ -n "$en" ] && echo "ENERGIA=$en" > "$E/run/sweetspot.conf"
	SWEETSPOT_SYSFS=$E/sys SWEETSPOT_PROCFS=$E/proc SWEETSPOT_RUN=$E/run SWEETSPOT_LOG=$E/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf "$@"
}
LIB=$SWEETSPOT_LIB/common.sh

echo "Profilo energetico: selezione"
expect "predefinito: fisso" "fisso" "$(env_run "" sh -c ". $LIB; energia")"
expect "conservativo selezionato" "conservativo" "$(env_run conservativo sh -c ". $LIB; energia")"
expect "valore sconosciuto: fisso" "fisso" "$(env_run boh sh -c ". $LIB; energia")"

echo "Profilo energetico: parametri di avvio"
# Si legge solo la funzione tune_params dallo script, senza eseguirlo.
tp() { env_run "$1" sh -c ". $LIB; $(awk '/^tune_params\(\)/,/^}/' "$OVERLAY/usr/bin/sweetspot-autotune"); tune_params"; }
p=$(tp fisso)
case "$p" in *max_cstate=1*) ok "fisso: stati C limitati" ;; *) expect "fisso: stati C limitati" "max_cstate=1" "$p" ;; esac
p=$(tp conservativo)
case "$p" in *max_cstate*|*nosmt*|*cpuidle.off*) expect "conservativo: niente nosmt/cstate" "" "$p" ;; *) ok "conservativo: niente nosmt/cstate" ;; esac

echo "Profilo energetico: runtime"
echo off > "$S/smt/control"
echo 1 > "$S/cpu1/cpuidle/state1/disable"
env_run conservativo sh "$OVERLAY/usr/bin/sweetspot-cpu" >/dev/null 2>&1
expect "governor schedutil" "schedutil" "$(cat "$P/scaling_governor")"
expect "frequenza minima libera" "800000" "$(cat "$P/scaling_min_freq")"
expect "frequenza massima libera" "2400000" "$(cat "$P/scaling_max_freq")"
expect "SMT riattivato" "on" "$(cat "$S/smt/control")"
expect "stati C riabilitati" "0" "$(cat "$S/cpu1/cpuidle/state1/disable")"
env_run fisso sh "$OVERLAY/usr/bin/sweetspot-cpu" >/dev/null 2>&1
expect "fisso: governor performance" "performance" "$(cat "$P/scaling_governor")"
expect "fisso: frequenza bloccata" "$(cat "$P/scaling_min_freq")" "$(cat "$P/scaling_max_freq")"

echo "sweetspot-energia"
printf 'cpu  100 0 100 800 0 0 0 0\ncpu0 1 0 1 1 0 0 0 0\ncpu1 1 0 1 1 0 0 0 0\n' > "$E/proc/stat"
printf 'some avg10=1.50 avg60=0.00 avg300=0.00 total=0\n' > "$E/proc/pressure/cpu"
printf 'some avg10=0.25 avg60=0.00 avg300=0.00 total=0\n' > "$E/proc/pressure/memory"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$E/proc/pressure/io"
printf 'state: XRUN\ndelay : 4096\n' > "$E/proc/asound/card0/pcm0p/sub0/status"
mkdir -p "$E/proc/42" "$E/sys/class/thermal/thermal_zone0" "$E/sys/class/powercap/intel-rapl:0"
echo squeezelite > "$E/proc/42/comm"
printf 'Name:\tsqueezelite\nVmRSS:\t   12345 kB\n' > "$E/proc/42/status"
echo 61000 > "$E/sys/class/thermal/thermal_zone0/temp"
echo 1000000 > "$E/sys/class/powercap/intel-rapl:0/energy_uj"
echo 1600000 > "$P/scaling_cur_freq"
out=$(env_run conservativo sh "$OVERLAY/usr/bin/sweetspot-energia" misura 3 0)
has() { if printf '%s\n' "$out" | grep -qx "$2"; then ok "$1"; else expect "$1" "$2" "$out"; fi; }
has "profilo nel riepilogo" "profilo=conservativo"
has "SMT nel riepilogo" "smt=on"
has "XRUN contati" "xrun_campioni=3"
has "ritardo massimo" "ritardo_max=4096"
has "memoria squeezelite" "rss_kb_squeezelite=12345"
has "PSI cpu" "psi_cpu=1.50"
has "PSI memoria" "psi_memoria=0.25"
has "temperatura massima" "temp_max_mC=61000"
has "frequenza media" "freq_media_kHz=1600000"
has "throttling assente" "throttling=0"
env_run fisso sh "$OVERLAY/usr/bin/sweetspot-energia" misura 1 0 "$WORK/b.txt" >/dev/null
printf '%s\n' "$out" > "$WORK/a.txt"
tab=$(sh "$OVERLAY/usr/bin/sweetspot-energia" confronta "$WORK/a.txt" "$WORK/b.txt")
case "$tab" in *"profilo"*"conservativo"*"fisso"*) ok "confronto affianca i profili" ;; *) expect "confronto affianca i profili" "tabella" "$tab" ;; esac

echo
echo "Energia - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
