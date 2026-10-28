#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - C-01: refresh_boot_grub non deve scrivere boot.img/grub.img nei
# settori 1..n di un disco GPT (LBA1 = intestazione, LBA2..33 = voci). Su MBR
# deve continuare a scriverli. Si esegue la funzione vera, estratta dallo
# script, su un'immagine al posto del disco.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$ROOT/board/sweetspot/rootfs-overlay/usr/bin/sweetspot-aggiorna
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAIL=0
echo "== refresh_boot_grub: GPT intatto, MBR scritto"
ck() {
	if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  NO  $1 (atteso '$2', ottenuto '$3')"; FAIL=1; fi
}

mkdir -p "$W/avvio" "$W/dir" "$W/stick/EFI/BOOT" "$W/stick/boot/grub" "$W/sys/class/block/sdx1"
echo 2048 > "$W/sys/class/block/sdx1/start"
head -c 512 /dev/zero | tr '\0' 'B' > "$W/avvio/boot.img"
head -c 1500 /dev/zero | tr '\0' 'G' > "$W/avvio/grub.img"
echo cfg > "$W/avvio/grub.cfg"

# Funzioni reali, con il disco puntato all'immagine e -b sostituito da -f.
sed -n '/^same() /p' "$S" > "$W/funz.sh"
for f in replace_file disco_gpt scrivi_grub_bios refresh_boot_grub; do
	sed -n "/^$f() {/,/^}/p" "$S" >> "$W/funz.sh"
done
sed -i -e "s#/dev/\$disk#$W/disco.img#g" -e 's#\[ -b #[ -f #' "$W/funz.sh"

cat > "$W/prova.sh" <<'EOS'
DIR=$1; AVVIO=$2; STICK_MNT=$3; SYS=$4
log() { :; }
sync() { :; }
blockdev() { :; }
stick_device() { echo /dev/sdx1; }
stick_disk() { echo sdx; }
. "$5"
refresh_boot_grub
EOS
run() { sh "$W/prova.sh" "$W/dir" "$W/avvio" "$W/stick" "$W/sys" "$W/funz.sh"; }

nuova() { # tipo
	dd if=/dev/zero of="$W/disco.img" bs=512 count=64 2>/dev/null
	[ "$1" = gpt ] && printf 'EFI PART' | dd of="$W/disco.img" bs=512 seek=1 conv=notrunc 2>/dev/null
	# voci di partizione riconoscibili in LBA2..
	head -c 4096 /dev/zero | tr '\0' 'V' | dd of="$W/disco.img" bs=512 seek=2 conv=notrunc 2>/dev/null
}
sum() { dd if="$W/disco.img" bs=512 skip=1 count=33 2>/dev/null | cksum; }

nuova gpt
prima=$(sum)
run
ck 'GPT: LBA1..33 byte-identici' "$prima" "$(sum)"
ck 'GPT: firma EFI PART ancora a LBA1' "EFI PART" "$(dd if="$W/disco.img" bs=512 skip=1 count=1 2>/dev/null | head -c 8)"

nuova mbr
prima=$(sum)
run
if [ "$prima" != "$(sum)" ]; then r=scritto; else r=intatto; fi
ck 'MBR: GRUB scritto nei settori 1..n' scritto "$r"
ck 'MBR: grub.img presente nei settori 1..n' "$(cksum < "$W/avvio/grub.img")" "$(dd if="$W/disco.img" bs=512 skip=1 count=3 2>/dev/null | head -c 1500 | cksum)"
exit "$FAIL"
