#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compila l'immagine Sweetspot con Buildroot.
#   ./scripts/build.sh                            PC x86 a 64 bit
#   ./scripts/build.sh sweetspot_rpi_defconfig    Raspberry Pi 4 e 5
# Richiede Linux (o WSL2 su Windows) con gli strumenti di compilazione
# elencati nel README, oppure Docker (vedi scripts/build-docker.sh).
# La prima compilazione richiede da 40 minuti a qualche ora e circa 15 GB.

set -e
BR_VERSION=2026.08
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BR=${BUILDROOT_DIR:-$ROOT/buildroot}
OUT=${OUTPUT_DIR:-$ROOT/output}
DEFCONFIG=${1:-sweetspot_x86_64_defconfig}

if [ ! -d "$BR" ]; then
	git clone --depth 1 --branch "$BR_VERSION" https://gitlab.com/buildroot.org/buildroot.git "$BR" ||
		git clone --depth 1 --branch "$BR_VERSION" https://github.com/buildroot/buildroot.git "$BR"
fi

# I permessi di esecuzione si perdono se il progetto passa da Windows o
# dal caricamento via web di GitHub: Buildroot ne ha bisogno.
chmod +x "$ROOT"/board/sweetspot/*.sh "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh 2>/dev/null || true

make -C "$BR" BR2_EXTERNAL="$ROOT" O="$OUT" "$DEFCONFIG"
make -C "$BR" O="$OUT"

echo
echo "Fatto. Immagine da scrivere sulla chiavetta (o sulla scheda SD):"
ls "$OUT"/images/sweetspot*.img.xz
