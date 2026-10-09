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

# File di avvio dentro il sistema: servono per installare Sweetspot sul
# disco interno e per aggiornare menu e GRUB insieme al sistema.
if [ -f "$BINARIES_DIR/grub.img" ]; then
	AVVIO="$TARGET_DIR/usr/share/sweetspot/avvio"
	rm -rf "$AVVIO"
	mkdir -p "$AVVIO"
	cp "$BOARD_DIR/x86/grub.cfg" "$AVVIO/grub.cfg"
	cp "$BINARIES_DIR/grub.img" "$AVVIO/grub.img"
	cp "$BINARIES_DIR/efi-part/EFI/BOOT/bootx64.efi" "$AVVIO/BOOTX64.EFI"
	cp "$BINARIES_DIR/efi-part/EFI/BOOT/bootia32.efi" "$AVVIO/BOOTIA32.EFI"
	BOOT_IMG=$(ls "$BUILD_DIR"/grub2-*/build-i386-pc/grub-core/boot.img 2>/dev/null | head -n 1)
	if [ -z "$BOOT_IMG" ]; then
		echo "boot.img di GRUB non trovato" >&2
		exit 1
	fi
	cp "$BOOT_IMG" "$AVVIO/boot.img"
	for f in sweetspot.txt LEGGIMI.txt; do
		sed 's/$/\r/' "$BOARD_DIR/stick/$f" > "$AVVIO/$f"
	done
fi
