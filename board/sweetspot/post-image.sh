#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prepara il contenuto della chiavetta (o della scheda SD) e
# crea l'immagine da scrivere con Raspberry Pi Imager, balenaEtcher o Rufus:
# sweetspot.img.xz per i PC, sweetspot-rpi.img.xz per il Raspberry Pi.
# Crea anche il pacchetto di aggiornamento sweetspot-<scheda>-aggiornamento.tar.
# Argomenti forniti da Buildroot: $1 = cartella delle immagini, $2 = scheda.

set -e
BOARD_DIR=$(dirname "$0")
BOARD=${2:-x86_64}
STICK="$BINARIES_DIR/chiavetta"
UPD="$BINARIES_DIR/aggiornamento"

AVVIO="$TARGET_DIR/usr/share/sweetspot/avvio"
VERSION=$(cut -d' ' -f1 "$TARGET_DIR/etc/sweetspot-version")

rm -rf "$STICK" "$UPD"
mkdir -p "$STICK/boot/versioni" "$UPD"
cp "$AVVIO/sweetspot.txt" "$AVVIO/LEGGIMI.txt" "$STICK/"
echo "$VERSION" > "$STICK/boot/versioni/a"

case "$BOARD" in
	rpi*)
		IMG=sweetspot-rpi.img
		GENIMAGE=rpi
		# Copia A del sistema nella cartella a (la B si crea con il primo
		# aggiornamento): kernel, sistema in RAM, alberi dei dispositivi
		# dei modelli supportati e overlay. Il firmware li cerca li' grazie
		# a os_prefix in config.txt.
		SYS="$UPD/sistema"
		mkdir -p "$SYS"
		cp "$BINARIES_DIR/Image.gz" "$BINARIES_DIR/rootfs.cpio.zst" "$BINARIES_DIR"/*.dtb "$SYS/"
		cp -r "$BINARIES_DIR/rpi-firmware/overlays" "$SYS/overlays"
		cp -r "$SYS" "$STICK/a"
		# Riga di comando della copia A (i parametri adattati a questo Pi li
		# aggiunge Sweetspot al primo avvio), config.txt e scheda DAC con le
		# stesse funzioni usate dal sistema, in una subshell: common.sh
		# cambia PATH.
		(
			. "$TARGET_DIR/usr/lib/sweetspot/common.sh"
			rpi_cmdline a > "$STICK/a/cmdline.txt"
			rpi_boot_config "$STICK/config.txt" a "$AVVIO/config.txt"
			rpi_scheda_txt "" > "$STICK/sweetspot-scheda.txt"
		)
		cp "$AVVIO"/firmware/* "$STICK/"
		# Stato dell'avvio: copia in uso A (stesso formato di grubenv).
		{
			printf '# GRUB Environment Block\nslot=a\n'
			head -c 1024 /dev/zero | tr '\0' '#'
		} | head -c 1024 > "$STICK/sweetspot-avvio.env"
		;;
	*)
		IMG=sweetspot.img
		GENIMAGE=x86
		mkdir -p "$STICK/boot/grub" "$STICK/EFI/BOOT"
		# Copia A del sistema (la B si crea con il primo aggiornamento).
		SYS="$UPD/sistema"
		mkdir -p "$SYS"
		cp "$BINARIES_DIR/bzImage" "$BINARIES_DIR/rootfs.cpio.zst" "$SYS/"
		cp "$SYS/bzImage" "$SYS/rootfs.cpio.zst" "$STICK/"
		# Menu e GRUB: gli stessi file che il sistema usa per installarsi sul
		# disco interno (preparati da post-build.sh).
		cp "$AVVIO/BOOTX64.EFI" "$AVVIO/BOOTIA32.EFI" "$STICK/EFI/BOOT/"
		cp "$AVVIO/grub.cfg" "$STICK/boot/grub/grub.cfg"
		cp "$AVVIO/boot.img" "$BINARIES_DIR/boot.img"
		# Ambiente di GRUB (1024 byte): copia in uso A.
		{
			printf '# GRUB Environment Block\nslot=a\n'
			head -c 1024 /dev/zero | tr '\0' '#'
		} | head -c 1024 > "$STICK/boot/grub/grubenv"
		;;
esac

# Pacchetto di aggiornamento: si installa dalla pagina Sistema (da internet
# o da un disco) nella copia del sistema non in uso. Contiene i file della
# copia (anche in sottocartelle, come gli overlay del Raspberry Pi), con
# l'impronta SHA-256 di ognuno in SHA256SUMS.
echo "$VERSION" > "$SYS/versione"
echo "$BOARD" > "$SYS/architettura"
(cd "$SYS" && find . -type f | sed 's|^\./||' | LC_ALL=C sort |
	while read -r f; do sha256sum "$f"; done > ../SHA256SUMS)
mv "$UPD/SHA256SUMS" "$SYS/SHA256SUMS"
PKG="$BINARIES_DIR/sweetspot-$BOARD-aggiornamento.tar"
(cd "$SYS" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$PKG" -- *)

support/scripts/genimage.sh -c "$BOARD_DIR/$GENIMAGE/genimage.cfg"

xz -T0 -6 -k -f "$BINARIES_DIR/$IMG"
echo
echo "Immagine pronta: $BINARIES_DIR/$IMG.xz"
echo "Aggiornamento: $PKG"
