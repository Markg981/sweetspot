#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# C-16: rilevamento NTFS sporco senza ntfsfix (assente nell'immagine reale),
# su immagini NTFS sintetiche (boot sector + record $Volume della MFT).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/board/sweetspot/rootfs-overlay/usr/bin/sweetspot-installa
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
PASS=0
expect() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}
put() { # file offset byte... (decimali)
	local f=$1 off=$2 b
	shift 2
	for b in "$@"; do
		printf "$(printf '\\%03o' "$b")" | dd of="$f" bs=1 seek="$off" conv=notrunc 2> /dev/null
		off=$((off + 1))
	done
}
# immagine: settore 512, 8 settori/cluster, MFT al cluster 4, record da 1024
mk() { # file byte-dei-flag
	local f=$1 o=$((4 * 8 * 512 + 3 * 1024))
	dd if=/dev/zero of="$f" bs=1024 count=40 2> /dev/null
	put "$f" 11 0 2; put "$f" 13 8; put "$f" 48 4; put "$f" 64 246
	printf 'FILE' | dd of="$f" bs=1 seek=$o conv=notrunc 2> /dev/null
	put "$f" $((o + 20)) 56 0
	# attributo 0x30 (104 byte) e poi 0x70 con i dati a +24
	put "$f" $((o + 56)) 48 0 0 0 104 0 0 0
	put "$f" $((o + 160)) 112 0 0 0 40 0 0 0
	put "$f" $((o + 160 + 20)) 24 0
	put "$f" $((o + 160 + 24 + 10)) "$2" 0
}
mk "$WORK/pulito" 0
mk "$WORK/sporco" 1
mk "$WORK/altribit" 129
: > "$WORK/vuoto"
dd if=/dev/zero of="$WORK/zeri" bs=1024 count=40 2> /dev/null
mkdir -p "$WORK/nobin"
run() { # immagine [funzione ntfsfix_presente] -> sporco/pulito
	PRES=${2:-'ntfsfix_presente() { return 1; }'}
	SWEETSPOT_RUN=$WORK/run SWEETSPOT_LOG=$WORK/log SWEETSPOT_LIB=$ROOT/board/sweetspot/rootfs-overlay/usr/lib/sweetspot PATH=$WORK/nobin:$PATH SWEETSPOT_TEST=1 sh -c ". $SCRIPT; $PRES; ntfs_parts() { echo $1; }; ntfs_hibernated() { return 1; }; ntfs_dirty x && echo sporco || echo pulito" 2>&1 | tail -1
}
echo "NTFS sporco senza ntfsfix"
expect "volume pulito" pulito "$(run "$WORK/pulito")"
expect "flag dirty" sporco "$(run "$WORK/sporco")"
expect "flag dirty con altri bit" sporco "$(run "$WORK/altribit")"
expect "volume illeggibile: non so, sporco" sporco "$(run "$WORK/vuoto")"
expect "senza firma FILE: non so, sporco" sporco "$(run "$WORK/zeri")"
expect "dispositivo inesistente: sporco" sporco "$(run "$WORK/non-esiste")"
printf '#!/bin/sh\nexit 1\n' > "$WORK/nobin/ntfsfix"
chmod +x "$WORK/nobin/ntfsfix"
expect "con ntfsfix che segnala: sporco" sporco "$(run "$WORK/pulito" 'ntfsfix_presente() { return 0; }')"
echo "Avvio rapido / ibernazione (hiberfil.sys)"
# Il montaggio e' simulato: la cartella di montaggio riceve un hiberfil.sys con la firma voluta.
hib() { # firma|- (nessun file)|nomount -> sporco/pulito
	PATH=$WORK/nobin2:$PATH SWEETSPOT_RUN=$WORK/run SWEETSPOT_LOG=$WORK/log SWEETSPOT_LIB=$ROOT/board/sweetspot/rootfs-overlay/usr/lib/sweetspot SWEETSPOT_TEST=1 sh -c ". $SCRIPT; ntfs_umounted=; ntfs_ro_umount() { return 0; }; ntfs_ro_mount() { rm -f \"\$2/hiberfil.sys\"; [ '$1' != nomount ] || return 1; [ '$1' = - ] || printf '$1' > \"\$2/hiberfil.sys\"; }; ntfs_hibernated x && echo sporco || echo pulito" 2>&1 | tail -1
}
mkdir -p "$WORK/nobin2"
expect "hiberfil.sys hibr: sporco" sporco "$(hib hibr)"
expect "hiberfil.sys HIBR: sporco" sporco "$(hib HIBR)"
expect "hiberfil.sys wake: pulito" pulito "$(hib wake)"
expect "senza hiberfil.sys: pulito" pulito "$(hib -)"
expect "montaggio impossibile: non so, sporco" sporco "$(hib nomount)"
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
