#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prepara il contenuto della chiavetta e crea l'immagine
# sweetspot.img (e sweetspot.img.xz da scrivere con Raspberry Pi Imager,
# balenaEtcher o Rufus).

set -e
BOARD_DIR=$(dirname "$0")
STICK="$BINARIES_DIR/chiavetta"

AVVIO="$TARGET_DIR/usr/share/sweetspot/avvio"
VERSION=$(cut -d' ' -f1 "$TARGET_DIR/etc/sweetspot-version")
ARCH=$(sed -n 's/^BR2_ARCH="\(.*\)"$/\1/p' "$BR2_CONFIG")

rm -rf "$STICK"
mkdir -p "$STICK/boot/grub" "$STICK/boot/versioni" "$STICK/EFI/BOOT"

# Copia A del sistema (la B si crea con il primo aggiornamento).
cp "$BINARIES_DIR/bzImage" "$STICK/bzImage"
cp "$BINARIES_DIR/rootfs.cpio.zst" "$STICK/rootfs.cpio.zst"
echo "$VERSION" > "$STICK/boot/versioni/a"

# Menu e GRUB: gli stessi file che il sistema usa per installarsi sul disco
# interno (preparati da post-build.sh).
cp "$AVVIO/BOOTX64.EFI" "$AVVIO/BOOTIA32.EFI" "$STICK/EFI/BOOT/"
cp "$AVVIO/grub.cfg" "$STICK/boot/grub/grub.cfg"
cp "$AVVIO/boot.img" "$BINARIES_DIR/boot.img"
cp "$AVVIO/sweetspot.txt" "$AVVIO/LEGGIMI.txt" "$STICK/"

# Ambiente di GRUB (1024 byte): copia in uso A.
{
	printf '# GRUB Environment Block\nslot=a\n'
	head -c 1024 /dev/zero | tr '\0' '#'
} | head -c 1024 > "$STICK/boot/grub/grubenv"

# Pacchetto di aggiornamento: si installa dalla pagina Sistema (da internet
# o da un disco) nella copia del sistema non in uso.
UPD="$BINARIES_DIR/aggiornamento"
rm -rf "$UPD"
mkdir -p "$UPD"
cp "$BINARIES_DIR/bzImage" "$BINARIES_DIR/rootfs.cpio.zst" "$UPD/"
echo "$VERSION" > "$UPD/versione"
echo "$ARCH" > "$UPD/architettura"
(cd "$UPD" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
tar -C "$UPD" -cf "$BINARIES_DIR/sweetspot-$ARCH-aggiornamento.tar" \
	SHA256SUMS versione architettura bzImage rootfs.cpio.zst

support/scripts/genimage.sh -c "$BOARD_DIR/x86/genimage.cfg"

xz -T0 -6 -k -f "$BINARIES_DIR/sweetspot.img"
echo
echo "Immagine pronta: $BINARIES_DIR/sweetspot.img.xz"
echo "Aggiornamento: $BINARIES_DIR/sweetspot-$ARCH-aggiornamento.tar"
