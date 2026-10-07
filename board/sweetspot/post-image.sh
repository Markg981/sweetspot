#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prepara il contenuto della chiavetta e crea l'immagine
# sweetspot.img (e sweetspot.img.xz da scrivere con Raspberry Pi Imager,
# balenaEtcher o Rufus).

set -e
BOARD_DIR=$(dirname "$0")
STICK="$BINARIES_DIR/chiavetta"

rm -rf "$STICK"
mkdir -p "$STICK/boot/grub" "$STICK/EFI/BOOT"

cp "$BINARIES_DIR/bzImage" "$STICK/bzImage"
cp "$BINARIES_DIR/rootfs.cpio.zst" "$STICK/rootfs.cpio.zst"

# GRUB per UEFI a 64 e 32 bit (la configurazione incorporata trova il menu).
cp "$BINARIES_DIR/efi-part/EFI/BOOT/bootx64.efi" "$STICK/EFI/BOOT/BOOTX64.EFI"
cp "$BINARIES_DIR/efi-part/EFI/BOOT/bootia32.efi" "$STICK/EFI/BOOT/BOOTIA32.EFI"
cp "$BOARD_DIR/x86/grub.cfg" "$STICK/boot/grub/grub.cfg"

# Primo stadio di GRUB per BIOS, preso dalla cartella di compilazione.
BOOT_IMG=$(ls "$BUILD_DIR"/grub2-*/build-i386-pc/grub-core/boot.img 2>/dev/null | head -n 1)
if [ -z "$BOOT_IMG" ]; then
	echo "boot.img di GRUB non trovato" >&2
	exit 1
fi
cp "$BOOT_IMG" "$BINARIES_DIR/boot.img"

# File per l'utente, con a capo in stile Windows per il Blocco note.
for f in sweetspot.txt LEGGIMI.txt; do
	sed 's/$/\r/' "$BOARD_DIR/stick/$f" > "$STICK/$f"
done

support/scripts/genimage.sh -c "$BOARD_DIR/x86/genimage.cfg"

xz -T0 -6 -k -f "$BINARIES_DIR/sweetspot.img"
echo
echo "Immagine pronta: $BINARIES_DIR/sweetspot.img.xz"
