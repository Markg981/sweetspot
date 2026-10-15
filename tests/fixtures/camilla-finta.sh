#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - sweetspot-camilla finto per i test del volume.
# $1 porta, $2 comando. In $R (SWEETSPOT_RUN):
#   camilla.call   i comandi ricevuti
#   camilla.fail   quanti comandi falliscono ancora (errore IPC, nessuna risposta)
#   camilla.vol    volume (dB) che CamillaDSP ha davvero
#   camilla.mute   sordina (true/false) che CamillaDSP ha davvero
R=${SWEETSPOT_RUN:?}
printf '%s\n' "$2" >> "$R/camilla.call"
n=$(cat "$R/camilla.fail" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then
	echo $((n - 1)) > "$R/camilla.fail"
	exit 1
fi
case "$2" in
	GetVolume) echo "{\"GetVolume\":{\"result\":\"Ok\",\"value\":$(cat "$R/camilla.vol")}}" ;;
	GetMute) echo "{\"GetMute\":{\"result\":\"Ok\",\"value\":$(cat "$R/camilla.mute")}}" ;;
	*SetVolume*)
		echo "$2" | sed 's/[^0-9.-]//g' > "$R/camilla.vol"
		echo '{"SetVolume":{"result":"Ok"}}' ;;
	*SetMute*)
		case "$2" in *true*) echo true ;; *) echo false ;; esac > "$R/camilla.mute"
		echo '{"SetMute":{"result":"Ok"}}' ;;
	*) echo '{}' ;;
esac
