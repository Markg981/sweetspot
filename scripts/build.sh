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
BR_VERSION=2026.08.1
# Commit del tag: un tag si puo' spostare, il commit no (stesso valore su
# GitLab e GitHub).
BR_COMMIT=7fdeadb3b9f12f78e5fccca914d7fef47090ab9a
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BR=${BUILDROOT_DIR:-$ROOT/buildroot}
OUT=${OUTPUT_DIR:-$ROOT/output}
DEFCONFIG=${1:-sweetspot_x86_64_defconfig}

if [ ! -d "$BR" ]; then
	git clone --depth 1 --branch "$BR_VERSION" https://gitlab.com/buildroot.org/buildroot.git "$BR" ||
		git clone --depth 1 --branch "$BR_VERSION" https://github.com/buildroot/buildroot.git "$BR"
fi
if [ "$(git -C "$BR" rev-parse HEAD)" != "$BR_COMMIT" ]; then
	echo "Buildroot in $BR non e' $BR_VERSION ($BR_COMMIT): cancellare la cartella o aggiornarla." >&2
	exit 1
fi

# Correzioni di sicurezza a Buildroot non ancora pubblicate (oggi ffmpeg 9.0.2,
# vedi docs/supply-chain.md). Applicate una sola volta: se una patch e' gia'
# presente si salta.
for p in "$ROOT"/patches/buildroot/*.patch; do
	[ -e "$p" ] || continue
	if git -C "$BR" apply -R --check "$p" 2>/dev/null; then
		continue
	fi
	git -C "$BR" apply "$p"
done

# I permessi di esecuzione si perdono se il progetto passa da Windows o
# dal caricamento via web di GitHub: Buildroot ne ha bisogno.
chmod +x "$ROOT"/board/sweetspot/*.sh "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh 2>/dev/null || true

make -C "$BR" BR2_EXTERNAL="$ROOT" O="$OUT" "$DEFCONFIG"
make -C "$BR" O="$OUT"

echo
echo "Fatto. Immagine da scrivere sulla chiavetta (o sulla scheda SD):"
ls "$OUT"/images/sweetspot*.img.xz
