#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - Reference Studio contro un Lyrion Music Server vero.
# Con Docker avvia il container ufficiale di Lyrion (versione fissata, la
# stessa che compila il repo), una libreria di prova generata al momento
# (FLAC sintetici) e un player finto (squeezelite senza scheda audio) in un
# secondo container, da cui gira tests/studio-lyrion.py.
#
#   sh tests/prova-studio-lyrion.sh

set -eu

IMMAGINE=${LYRION_IMMAGINE:-lmscommunity/lyrionmusicserver:9.1.1}
BASE=${PROVA_IMMAGINE_BASE:-debian:trixie-slim}
MAC=02:00:00:00:00:01
REPO=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
N=sweetspot-studio-$$
export MSYS_NO_PATHCONV=1

cleanup() {
	rc=$?
	if [ "$rc" != 0 ]; then
		echo "--- registro di Lyrion (ultime righe) ---"
		docker logs --tail 40 "$N-lms" 2>&1 || true
		docker exec "$N-prova" sh -c 'tail -n 20 /tmp/squeezelite.log' 2>&1 || true
	fi
	docker rm -f "$N-lms" "$N-prova" > /dev/null 2>&1 || true
	docker volume rm "$N-music" > /dev/null 2>&1 || true
	docker network rm "$N" > /dev/null 2>&1 || true
	exit "$rc"
}
trap cleanup EXIT INT TERM

docker network create "$N" > /dev/null
docker volume create "$N-music" > /dev/null
docker run -d --name "$N-prova" --network "$N" -v "$N-music:/music" \
	-v "$REPO:/repo:ro" "$BASE" sleep infinity > /dev/null
docker exec "$N-prova" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends busybox-static flac sox jq python3 squeezelite ca-certificates > /dev/null && ln -s /bin/busybox /usr/local/bin/wget'
docker exec "$N-prova" python3 /repo/tests/studio-lyrion.py --genera /music
docker run -d --name "$N-lms" --network "$N" -v "$N-music:/music:ro" "$IMMAGINE" > /dev/null
docker exec -d "$N-prova" sh -c "squeezelite -n Prova -m $MAC -s $N-lms -o - 2> /tmp/squeezelite.log | python3 /repo/tests/studio-lyrion.py --pozzo"
docker exec -e LYRION_HOST="$N-lms" -e LYRION_PLAYER_MAC="$MAC" "$N-prova" python3 -I /repo/tests/studio-lyrion.py -v
