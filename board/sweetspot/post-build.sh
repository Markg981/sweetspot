#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - ritocchi al sistema prima di impacchettarlo nell'initramfs.
# Argomenti forniti da Buildroot: $1 = cartella del sistema (TARGET_DIR).

set -e
TARGET_DIR=$1
BOARD_DIR=$(dirname "$0")

# Il menu di GRUB vive sulla chiavetta, non nel sistema in RAM.
rm -rf "${TARGET_DIR:?}/boot"

# SSH parte solo se attivato in sweetspot.txt (S45sweetspot-ssh).
rm -f "$TARGET_DIR/etc/init.d/S50dropbear"

# Permessi degli script, anche se il repository e' stato copiato da Windows.
chmod 0755 "$TARGET_DIR"/etc/init.d/S*sweetspot-* \
	"$TARGET_DIR"/usr/bin/sweetspot-* \
	"$TARGET_DIR"/usr/share/sweetspot/www/cgi-bin/*

# Versione mostrata nella pagina di stato.
VERSION=$(git -C "$BOARD_DIR" describe --tags --always --dirty 2>/dev/null || echo sviluppo)
echo "$VERSION ($(date -u '+%Y-%m-%d'))" > "$TARGET_DIR/etc/sweetspot-version"
