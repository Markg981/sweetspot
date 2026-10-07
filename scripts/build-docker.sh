#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Compila Sweetspot dentro un contenitore Docker (Linux, macOS, Windows
# con Docker Desktop). Il risultato finisce in output/images/.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
docker build -t sweetspot-build "$ROOT/docker"
docker run --rm -it \
	-u "$(id -u):$(id -g)" \
	-v "$ROOT":/sweetspot \
	-v sweetspot-dl:/home/builder/.buildroot-dl \
	-v sweetspot-ccache:/home/builder/.buildroot-ccache \
	-e BR2_DL_DIR=/home/builder/.buildroot-dl \
	sweetspot-build /sweetspot/scripts/build.sh "$@"
