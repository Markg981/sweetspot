#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova l'immagine in una macchina virtuale prima di scriverla
# sulla chiavetta. QEMU simula un PC a 4 core con Hyper-Threading, la
# chiavetta e un DAC USB Audio sullo stesso controller USB.
#
#   tests/qemu-avvio.sh [immagine] [bios|uefi]
#
# Durante la prova le impostazioni di Sweetspot sono su http://localhost:8080/,
# l'interfaccia Material su http://localhost:9000/material/ e la
# console del player scorre nel terminale. Si esce con Ctrl+A poi X.
#
# Serve: qemu-system-x86, mtools, xz-utils e, per UEFI, ovmf.

set -e
IMG=${1:-output/images/sweetspot.img}
MODE=${2:-bios}
WORK=${WORK:-$(mktemp -d)}

case "$IMG" in
	*.xz) xz -dc "$IMG" > "$WORK/disco.img" ;;
	*) cp "$IMG" "$WORK/disco.img" ;;
esac

# Solo nella copia di prova: console anche sulla porta seriale.
mcopy -o -i "$WORK/disco.img@@1M" ::/boot/grub/grub.cfg "$WORK/grub.cfg"
sed -i 's/quiet loglevel=3 /console=tty0 console=ttyS0,115200 /' "$WORK/grub.cfg"
mcopy -o -i "$WORK/disco.img@@1M" "$WORK/grub.cfg" ::/boot/grub/grub.cfg

ACCEL=tcg
[ -w /dev/kvm ] && ACCEL=kvm

set -- -machine q35,accel=$ACCEL -m 4096 -smp 8,sockets=1,cores=4,threads=2 \
	-cpu max -device qemu-xhci,id=xhci \
	-drive if=none,id=chiavetta,format=raw,file="$WORK/disco.img" \
	-device usb-storage,bus=xhci.0,drive=chiavetta,bootindex=0 \
	-audiodev none,id=audio0 -device usb-audio,bus=xhci.0,audiodev=audio0 \
	-nic user,model=e1000,hostfwd=tcp::8080-:80,hostfwd=tcp::9000-:9000 \
	-display none

if [ -n "${SERIAL_LOG:-}" ]; then
	set -- "$@" -serial "file:$SERIAL_LOG" -monitor none
else
	set -- "$@" -serial mon:stdio
fi

if [ "$MODE" = uefi ]; then
	OVMF=/usr/share/OVMF/OVMF_CODE_4M.fd
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars.fd"
	set -- "$@" -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd"
fi

echo "Avvio ($MODE, $ACCEL): impostazioni su http://localhost:8080/cgi-bin/audio, interfaccia su http://localhost:9000/material/"
exec qemu-system-x86_64 "$@"
