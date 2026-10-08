#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova completa della copia di un CD con un lettore finto
# (tests/cd/finto.py): lettura dell'indice, titoli e copertina, ricerca
# della correzione del lettore, copia sicura, FLAC con i tag, verifica
# AccurateRip. Serve: python3, flac, jq, gcc, busybox.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/sys/block/sr0" "$W/run" "$W/media/Archivio"
gcc -O2 -o "$W/bin/sweetspot-arcrc" "$ROOT/package/sweetspot-tools/src/sweetspot-arcrc.c"
for t in cd-paranoia curl; do
	printf '#!/bin/sh\nexec python3 %s %s "$@"\n' "$ROOT/tests/cd/finto.py" "$t" > "$W/bin/$t"
done
printf '#!/bin/sh\n[ "$1" = archivio ] && echo %s\n' "$W/media/Archivio" > "$W/bin/sweetspot-dischi"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sweetspot-lms"
printf '#!/bin/sh\n[ "$1" = imposta ] && printf "%%s=%%s\\n" "$2" "$3" >> %s\n' "$W/run/sweetspot.txt" > "$W/bin/sweetspot-config"
chmod +x "$W/bin"/*
export SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$W/run SWEETSPOT_SYSFS=$W/sys \
	SWEETSPOT_LOG=$W/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	SWEETSPOT_PATH="$W/bin" SWEETSPOT_ARCRC="$W/bin/sweetspot-arcrc"
CD=$OVERLAY/usr/bin/sweetspot-cd
: > "$W/run/sweetspot.txt"
busybox sh -c ". $SWEETSPOT_LIB/common.sh; config_build $W/run/sweetspot.txt"

busybox sh "$CD" leggi
jq -c '{album, artist, year, discid, accuraterip, cover, n: (.tracks | length)}' "$W/run/cd/info.json"
busybox sh "$CD" _copia
echo "stato: $(busybox sh "$CD" stato)"
echo "offset salvato: $(cat "$W/run/sweetspot.txt")"
find "$W/media/Archivio" -type f | sed "s#$W/media/Archivio/##" | sort
cat "$W/media/Archivio"/*/*/sweetspot-copia.txt
f=$(find "$W/media/Archivio" -name '01 - *.flac')
metaflac --export-tags-to=- "$f"
metaflac --list --block-type=PICTURE "$f" | grep -c 'type: 3' | sed 's/^/copertine incorporate: /'
grep -q 'tutte le tracce verificate' "$W/run/cd/stato" && echo "PROVA RIUSCITA" || { echo "PROVA FALLITA"; exit 1; }
