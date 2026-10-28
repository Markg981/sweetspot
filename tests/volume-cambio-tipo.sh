#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# C-06: il passaggio da volume fisso a software/dsp con riavvio del
# dispositivo ($RUN e' tmpfs, il marcatore volume.fisso sparisce) deve
# comunque portare Lyrion al volume sicuro: il tipo precedente sta su disco.
# shellcheck disable=SC2016
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
mkdir -p "$WORK/dati"

# Un avvio: $RUN nuovo (tmpfs vuoto), dati persistenti condivisi.
# Lyrion finto: volume salvato in $WORK/vol, "mixer volume" ricevuto in $WORK/mix.
avvio() { # modalita' [funzione]
	rm -rf "$WORK/run" "$WORK/mix"; mkdir -p "$WORK/run"
	SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$WORK/run SWEETSPOT_LOG=$WORK/log SWEETSPOT_LMS_DATA=$WORK/dati \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player
		PLAYER_MAC=aa:bb; PREFS_SET=0; LMS_HOST=127.0.0.1; VOL_MODO=$1
		mode() { echo completa; }; volume_modalita() { echo $1; }; volume_effettivo() { echo x; }
		log() { :; }
		lms_get() { case \"\$3\" in connected) echo 1 ;; mixer) cat $WORK/vol ;; playerpref) echo 1 ;; esac; }
		lms_json() { [ \"\$2\" = mixer ] && { echo \"\$4\" > $WORK/mix; echo \"\$4\" > $WORK/vol; }; return 0; }
		prefs_divergenti() { :; }; prefs_stato() { :; }
		${2:-apply_player_prefs}" > /dev/null 2>&1
	cat "$WORK/mix" 2>/dev/null || echo nessuno
}

echo 100 > "$WORK/vol"
expect "primo avvio in fisso: Lyrion a 100" "100" "$(avvio fisso)"
expect "il tipo fisso e' persistito su disco" "fisso" "$(cat "$WORK/dati/sweetspot-volume.tipo")"
echo 100 > "$WORK/vol"
expect "dopo il riavvio, fisso -> software: volume sicuro (apply_player_prefs)" "25" "$(avvio software)"
expect "il tipo e' aggiornato" "altro" "$(cat "$WORK/dati/sweetspot-volume.tipo")"

echo 100 > "$WORK/vol"; echo fisso > "$WORK/dati/sweetspot-volume.tipo"
expect "dopo il riavvio, fisso -> dsp: volume sicuro prima di Squeezelite" "25" "$(avvio dsp volume_sicuro_prima)"

echo 100 > "$WORK/vol"; echo altro > "$WORK/dati/sweetspot-volume.tipo"
expect "software -> software: il volume non viene toccato" "nessuno" "$(avvio software)"

echo
echo "Volume cambio tipo - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
