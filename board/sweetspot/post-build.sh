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

# Cartelle della libreria: /musica raccoglie i collegamenti a dischi e
# cartelle di rete, montati in /media.
mkdir -p "$TARGET_DIR/musica" "$TARGET_DIR/media" "$TARGET_DIR/var/lib"

# Il sistema gira in RAM: via la documentazione di Perl, che Lyrion non usa.
if [ -d "$TARGET_DIR/usr/lib/perl5" ]; then
	find "$TARGET_DIR/usr/lib/perl5" -name '*.pod' -delete
	rm -rf "$TARGET_DIR"/usr/lib/perl5/*/pod
fi

# Permessi degli script, anche se il repository e' stato copiato da Windows.
chmod 0755 "$TARGET_DIR"/etc/init.d/S*sweetspot-* \
	"$TARGET_DIR"/usr/bin/sweetspot-* \
	"$TARGET_DIR"/usr/share/sweetspot/www/cgi-bin/*
[ -d "$TARGET_DIR/opt/lms/Plugins" ] && chmod -R u=rwX,go=rX "$TARGET_DIR/opt/lms/Plugins"

# Versione mostrata nella pagina di stato.
VERSION=$(git -C "$BOARD_DIR" describe --tags --always --dirty 2>/dev/null || echo sviluppo)
echo "$VERSION ($(date -u '+%Y-%m-%d'))" > "$TARGET_DIR/etc/sweetspot-version"
