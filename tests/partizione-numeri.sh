#!/bin/sh
# sweetspot-partizione: numeri > 4 solo su GPT (side_job ha dischi OEM con 4+
# partizioni). Su un file normale l'ioctl BLKPG fallisce (esito 1): quello che
# conta qui e' che il numero NON venga rifiutato (esito 2) prima.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
gcc -o "$T/p" "$ROOT/package/sweetspot-tools/src/sweetspot-partizione.c" || exit 1
dd if=/dev/zero of="$T/gpt" bs=512 count=64 2>/dev/null
printf 'EFI PART' | dd of="$T/gpt" bs=1 seek=512 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$T/mbr" bs=512 count=64 2>/dev/null
printf '\125\252' | dd of="$T/mbr" bs=1 seek=510 conv=notrunc 2>/dev/null
r() { "$T/p" "$@" > /dev/null 2>&1; echo $?; }
out="gpt5=$(r "$T/gpt" 5 2048 2048) gpt128=$(r "$T/gpt" 128 2048 2048) gpt129=$(r "$T/gpt" 129 2048 2048)"
out="$out mbr4=$(r "$T/mbr" 4 2048 2048) mbr5=$(r "$T/mbr" 5 2048 2048)"
exp="gpt5=1 gpt128=1 gpt129=2 mbr4=1 mbr5=2"
[ "$out" = "$exp" ] || { echo "atteso: $exp"; echo "ottenuto: $out"; exit 1; }
