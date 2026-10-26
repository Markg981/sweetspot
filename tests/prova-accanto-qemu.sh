#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - installazione accanto a Windows, sull'immagine x86 avviata in
# QEMU con firmware UEFI (OVMF):
#   1. un SSD NVMe GPT come lo lascia Windows dopo "Riduci volume": partizione
#      EFI con \EFI\Microsoft\Boot\bootmgfw.efi, MSR, "Windows" piena di dati
#      e spazio non allocato; la chiavetta USB avvia Sweetspot;
#   2. "sweetspot-installa affianca nvme0n1 GB" via SSH: la partizione nuova
#      e la voce "Sweetspot" nella NVRAM UEFI;
#   3. a macchina spenta: tabella GPT integra, partizioni di Windows identiche
#      byte per byte, caricatore UEFI nella partizione nuova;
#   4. riavvio senza chiavetta, con la stessa NVRAM: parte Sweetspot dalla
#      voce UEFI creata, dalla partizione nuova, e il menu offre Windows.
#
#   sudo sh tests/prova-accanto-qemu.sh sweetspot.img.xz
#
# Serve: qemu-system-x86, ovmf, gdisk, dosfstools, mtools, xz-utils e sshpass.
# La porta 2224 (SSH_PORT) di 127.0.0.1 deve essere libera.
# Esito e registri in $SWEETSPOT_AUDIO_REPORT_DIR/accanto-qemu.*.

set -eu
export LC_ALL=C LANG=C
umask 022
TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$TEST_DIR")
IMG=$(readlink -f "$1")
SSH_PORT=${SSH_PORT:-2224}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
REPORT_DIR=${SWEETSPOT_AUDIO_REPORT_DIR:-$REPO_DIR/graphify-out/audio-evidence}
mkdir -p "$REPORT_DIR"
OUT=$(mktemp -d "$(readlink -f "$REPORT_DIR")/accanto-qemu.XXXXXX")
chmod 755 "$OUT"
echo "Evidenza della prova di installazione accanto: $OUT"
W=$(mktemp -d)
FAIL=0

cleanup() {
	rc=$?
	stop_vm
	for f in "$W"/seriale*.log; do
		[ -f "$f" ] && cp "$f" "$OUT/console-$(basename "$f")"
	done
	chmod -R a+rX "$OUT"
	rm -rf "$W"
	return "$rc"
}
stop_vm() {
	if [ -f "$W/qemu.pid" ]; then
		kill "$(cat "$W/qemu.pid")" 2>/dev/null || true
		i=0
		while kill -0 "$(cat "$W/qemu.pid")" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
		rm -f "$W/qemu.pid"
	fi
}
trap cleanup EXIT

esito() { # OK|NO descrizione
	echo "$1 $2" | tee -a "$OUT/esito.txt"
	[ "$1" = OK ] || FAIL=1
}

SSHPASS=$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
export SSHPASS
guest() {
	sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1 "$@"
}

wait_ssh() { # secondi
	i=0
	until guest true 2>/dev/null; do
		i=$((i + 5))
		[ $i -ge "$1" ] && return 1
		sleep 5
	done
}

# Primo settore e lunghezza (in settori) di una partizione dell'SSD.
off() { sgdisk -i "$1" "$W/ssd.img" | awk '/First sector/ { print $3 }'; }
len() { sgdisk -i "$1" "$W/ssd.img" | awk '/Partition size/ { print $3 }'; }
impronte() { # file: sha256 delle partizioni di Windows
	for n in 1 2 3; do
		printf 'p%s %s\n' "$n" "$(dd if="$W/ssd.img" bs=512 skip="$(off $n)" count="$(len $n)" status=none | sha256sum | cut -c1-64)"
	done > "$1"
}

ACCEL=tcg
CPU=max
if [ -w /dev/kvm ]; then
	ACCEL=kvm
	CPU=host
fi
# avvia NOME [opzioni di QEMU]: la stessa NVRAM ($W/vars.fd) per tutti gli avvii.
avvia() {
	n=$1
	shift
	rm -f "$W/seriale.log"
	qemu-system-x86_64 -machine q35,accel=$ACCEL -cpu $CPU -m 4096 -smp 4 \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$W/vars.fd" \
		-drive if=none,id=ssd,format=raw,file="$W/ssd.img" -device nvme,drive=ssd,serial=SSD1 \
		-nic user,model=e1000,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
		-display none -monitor none -serial file:"$W/seriale.log" \
		-pidfile "$W/qemu.pid" -daemonize "$@"
	if ! wait_ssh 500; then
		echo "SSH non risponde dopo circa 500 secondi ($n). Console:"
		tail -n 80 "$W/seriale.log"
		cp "$W/seriale.log" "$W/seriale-$n.log"
		exit 1
	fi
	echo "SSH pronto ($n)"
	qemu_attendi_stabile 600 || exit 1
}
# Spegne il sistema e conserva la console dell'avvio.
spegni() { # nome
	guest poweroff > /dev/null 2>&1 || true
	i=0
	while kill -0 "$(cat "$W/qemu.pid")" 2>/dev/null && [ $i -lt 90 ]; do sleep 1; i=$((i + 1)); done
	[ $i -lt 90 ] || echo "  (spegnimento non concluso in 90 s: QEMU fermato)"
	stop_vm
	cp "$W/seriale.log" "$W/seriale-$1.log"
}
. "$TEST_DIR/qemu-attesa.sh"

echo "== Chiavetta di prova"
case "$IMG" in
	*.xz) xz -dc "$IMG" > "$W/chiavetta.img" ;;
	*) cp "$IMG" "$W/chiavetta.img" ;;
esac
mcopy -o -i "$W/chiavetta.img@@1M" ::/boot/grub/grub.cfg "$W/grub.cfg"
sed -i 's/quiet loglevel=3 /console=tty0 console=ttyS0,115200 /' "$W/grub.cfg"
mcopy -o -i "$W/chiavetta.img@@1M" "$W/grub.cfg" ::/boot/grub/grub.cfg
mcopy -o -i "$W/chiavetta.img@@1M" ::/sweetspot.txt "$W/sweetspot.txt"
# Le impostazioni della chiavetta passano al disco: SSH anche dopo.
printf '\nSSH=si\nSSH_PASSWORD=%s\n' "$SSHPASS" >> "$W/sweetspot.txt"
mcopy -o -i "$W/chiavetta.img@@1M" "$W/sweetspot.txt" ::/sweetspot.txt

echo "== SSD con Windows e 5 GB non allocati"
truncate -s 8G "$W/ssd.img"
sgdisk -o \
	-n 1:1M:+260M -t 1:EF00 -c 1:"EFI system partition" \
	-n 2:0:+16M -t 2:0C01 -c 2:"Microsoft reserved partition" \
	-n 3:0:+2G -t 3:0700 -c 3:"Basic data partition" "$W/ssd.img" > /dev/null
# Partizione EFI di Windows: il boot manager (finto) e' il file che il menu
# di Sweetspot cerca per offrire la voce Windows.
mkfs.vfat -F 32 -n SYSTEM --offset "$(off 1)" "$W/ssd.img" $(($(len 1) / 2)) > /dev/null 2>&1
printf 'finto boot manager di Windows\n' > "$W/bootmgfw.efi"
mmd -i "$W/ssd.img@@1M" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot
mcopy -i "$W/ssd.img@@1M" "$W/bootmgfw.efi" ::/EFI/Microsoft/Boot/bootmgfw.efi
# "Windows": dati casuali all'inizio e alla fine della partizione.
for s in "$(off 3)" "$(($(off 3) + $(len 3) - 131072))"; do
	head -c 64M /dev/urandom | dd of="$W/ssd.img" bs=512 seek="$s" conv=notrunc status=none
done
impronte "$OUT/impronte-prima.txt"
sgdisk -p "$W/ssd.img" > "$OUT/partizioni-prima.txt"
cp "$OVMF_VARS" "$W/vars.fd"

echo "== 1. Avvio dalla chiavetta (UEFI, $ACCEL)"
avvia chiavetta -device qemu-xhci,id=xhci \
	-drive if=none,id=chiavetta,format=raw,file="$W/chiavetta.img" \
	-device usb-storage,bus=xhci.0,drive=chiavetta,bootindex=0
guest 'sweetspot-installa accanto' > "$OUT/accanto.txt" 2>&1 || true
riga=$(grep '^nvme0n1|' "$OUT/accanto.txt" || true)
gb=$(echo "$riga" | cut -d'|' -f2)
if [ -n "$riga" ] && [ "$(echo "$riga" | cut -d'|' -f6)" -ge 4 ]; then
	esito OK "SSD proposto per l'installazione accanto: $riga"
else
	esito NO "SSD non proposto: $(tr '\n' ' ' < "$OUT/accanto.txt")"
fi

echo "== 2. Installazione accanto"
i=0
# Se l'installazione non parte non c'e' nulla da aspettare.
guest "sweetspot-installa affianca nvme0n1 ${gb:-8}" > "$OUT/affianca.txt" 2>&1 || i=600
stato=""
while [ $i -lt 600 ]; do
	stato=$(guest 'sweetspot-installa stato' 2>/dev/null) || stato=""
	case "$stato" in finita*|errore*) break ;; esac
	i=$((i + 5))
	sleep 5
done
echo "$stato" > "$OUT/stato.txt"
if [ "$stato" = "finita|6|6|accanto nvme0n1 si" ]; then
	esito OK "installazione accanto conclusa, voce UEFI creata"
else
	esito NO "installazione accanto: '$stato' ($(tr '\n' ' ' < "$OUT/affianca.txt"))"
fi
guest 'efibootmgr' > "$OUT/efibootmgr-1.txt" 2>&1 || true
spegni chiavetta

echo "== 3. SSD a macchina spenta"
sgdisk -v "$W/ssd.img" > "$OUT/sgdisk-v.txt" 2>&1 || true
if grep -q 'No problems found' "$OUT/sgdisk-v.txt"; then
	esito OK "tabella GPT integra"
else
	esito NO "tabella GPT: $(tr '\n' ' ' < "$OUT/sgdisk-v.txt")"
fi
sgdisk -p "$W/ssd.img" > "$OUT/partizioni-dopo.txt"
p4=$(awk '$1 == 4 { print $6, $7 }' "$OUT/partizioni-dopo.txt")
if [ "$p4" = "0700 Sweetspot" ] && [ "$(len 4)" = 8388608 ]; then
	esito OK "partizione 4 da 4 GiB, tipo dati di base, nome Sweetspot"
else
	esito NO "partizione 4: '$p4' ($(len 4 2>/dev/null) settori)"
fi
impronte "$OUT/impronte-dopo.txt"
if cmp -s "$OUT/impronte-prima.txt" "$OUT/impronte-dopo.txt"; then
	esito OK "partizioni di Windows identiche (EFI, MSR, Windows)"
else
	esito NO "partizioni di Windows cambiate: $(diff "$OUT/impronte-prima.txt" "$OUT/impronte-dopo.txt" | tr '\n' ' ')"
fi
if mdir -b -i "$W/ssd.img@@$(($(off 4) * 512))" ::/EFI/BOOT/BOOTX64.EFI > /dev/null 2>&1; then
	esito OK "caricatore UEFI nella partizione nuova"
else
	esito NO "manca \\EFI\\BOOT\\BOOTX64.EFI nella partizione nuova"
fi

echo "== 4. Avvio dall'SSD, senza chiavetta"
avvia ssd
guest 'efibootmgr; echo; cat /proc/cmdline; blkid /dev/nvme0n1p4' > "$OUT/avvio-ssd.txt" 2>&1 || true
cur=$(awk '/^BootCurrent:/ { print $2 }' "$OUT/avvio-ssd.txt")
if [ -n "$cur" ] && grep -Eq "^Boot$cur\\*? Sweetspot" "$OUT/avvio-ssd.txt"; then
	esito OK "avviato dalla voce UEFI Sweetspot (Boot$cur)"
else
	esito NO "voce di avvio: BootCurrent '$cur' non e' Sweetspot"
fi
part=$(tr ' ' '\n' < "$OUT/avvio-ssd.txt" | sed -n 's/^sweetspot\.part=//p' | head -n 1)
if [ -n "$part" ] && grep '^/dev/nvme0n1p4:' "$OUT/avvio-ssd.txt" | grep -q "\"$part\""; then
	esito OK "sistema caricato dalla partizione nuova ($part)"
else
	esito NO "sweetspot.part='$part' non e' nvme0n1p4"
fi
# Il menu di GRUB passa anche dalla console seriale del firmware.
if tr -d '\033' < "$W/seriale.log" | grep -aq 'Windows'; then
	esito OK "il menu di avvio offre Windows"
else
	esito NO "voce Windows assente dal menu di avvio"
fi
spegni ssd

echo "== Esito"
cat "$OUT/esito.txt"
[ "$FAIL" -eq 0 ]
