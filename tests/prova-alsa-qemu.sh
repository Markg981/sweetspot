#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - verifica dei campioni sul percorso ALSA del kernel di Sweetspot
# (PREEMPT_RT). Avvia l'immagine x86 in QEMU, carica snd-aloop nel sistema
# avviato e ripete i casi di tests/prova-audio.py su hw:Loopback: Squeezelite
# e aplay girano nel sistema avviato (via SSH), Lyrion e' quello dell'immagine.
# Serve perche' i kernel dei runner della CI non hanno snd-aloop.
#
#   sudo sh tests/prova-alsa-qemu.sh sweetspot.img.xz [versione]
#
# Serve: qemu-system-x86, mtools, xz-utils, sshpass, curl e python3.
# Le porte 9000 e 2222 (SSH_PORT) di 127.0.0.1 devono essere libere.
# Report, capture e registri in $SWEETSPOT_AUDIO_REPORT_DIR/alsa-qemu.*.

set -eu
export LC_ALL=C LANG=C
umask 022
TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$TEST_DIR")
IMG=$(readlink -f "$1")
VERSIONE=${2:-$(basename "$IMG")}
SSH_PORT=${SSH_PORT:-2222}
REPORT_DIR=${SWEETSPOT_AUDIO_REPORT_DIR:-$REPO_DIR/graphify-out/audio-evidence}
mkdir -p "$REPORT_DIR"
OUT=$(mktemp -d "$(readlink -f "$REPORT_DIR")/alsa-qemu.XXXXXX")
chmod 755 "$OUT"
echo "Evidenza della prova ALSA: $OUT"
W=$(mktemp -d)

cleanup() {
	rc=$?
	if [ -f "$W/qemu.pid" ]; then
		kill "$(cat "$W/qemu.pid")" 2>/dev/null || true
		sleep 1
	fi
	[ -f "$W/seriale.log" ] && cp "$W/seriale.log" "$OUT/console-seriale.log"
	# L'evidenza si carica come artifact da un utente non root.
	chmod -R a+rX "$OUT"
	rm -rf "$W"
	return "$rc"
}
trap cleanup EXIT

# Password casuale, valida solo per questa copia dell'immagine.
SSHPASS=$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
export SSHPASS
guest() {
	sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1 "$@"
}

echo "== Copia di prova dell'immagine"
case "$IMG" in
	*.xz) xz -dc "$IMG" > "$W/disco.img" ;;
	*) cp "$IMG" "$W/disco.img" ;;
esac
# Console seriale e, nelle impostazioni, SSH con la password di prova; il DAC
# indicato non esiste, cosi' il player di Sweetspot non apre hw:Loopback.
mcopy -o -i "$W/disco.img@@1M" ::/boot/grub/grub.cfg "$W/grub.cfg"
sed -i 's/quiet loglevel=3 /console=tty0 console=ttyS0,115200 /' "$W/grub.cfg"
mcopy -o -i "$W/disco.img@@1M" "$W/grub.cfg" ::/boot/grub/grub.cfg
mcopy -o -i "$W/disco.img@@1M" ::/sweetspot.txt "$W/sweetspot.txt"
printf '\nSSH=si\nSSH_PASSWORD=%s\nMODALITA_ASCOLTO=no\nDAC=prova-alsa-nessun-dac\n' "$SSHPASS" >> "$W/sweetspot.txt"
mcopy -o -i "$W/disco.img@@1M" "$W/sweetspot.txt" ::/sweetspot.txt

ACCEL=tcg
CPU=max
if [ -w /dev/kvm ]; then
	ACCEL=kvm
	CPU=host
fi
echo "== Avvio in QEMU ($ACCEL)"
qemu-system-x86_64 -machine q35,accel=$ACCEL -cpu $CPU -m 4096 -smp 4,sockets=1,cores=4,threads=1 \
	-device qemu-xhci,id=xhci \
	-drive if=none,id=chiavetta,format=raw,file="$W/disco.img" \
	-device usb-storage,bus=xhci.0,drive=chiavetta,bootindex=0 \
	-nic user,model=e1000,hostfwd=tcp:127.0.0.1:9000-:9000,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
	-display none -monitor none -serial file:"$W/seriale.log" \
	-pidfile "$W/qemu.pid" -daemonize

i=0
until guest true 2>/dev/null; do
	i=$((i + 1))
	if [ $i -gt 100 ]; then
		echo "SSH non risponde dopo circa 500 secondi. Console:"
		tail -n 80 "$W/seriale.log"
		exit 1
	fi
	sleep 5
done
echo "SSH pronto dopo circa $((i * 5)) secondi"

i=0
ans=""
while [ $i -lt 120 ]; do
	ans=$(curl -s -m 5 -H 'Content-Type: application/json' \
		-d '{"id":1,"method":"slim.request","params":["",["serverstatus",0,0]]}' \
		http://127.0.0.1:9000/jsonrpc.js 2>/dev/null) || ans=""
	printf '%s' "$ans" | grep -q '"version"' && break
	i=$((i + 1))
	sleep 5
done
printf '%s' "$ans" | grep -q '"version"' || { echo "Lyrion non risponde"; tail -n 60 "$W/seriale.log"; exit 1; }
echo "Lyrion risponde"

echo "== Scheda hw:Loopback nel kernel di Sweetspot"
guest 'uname -a; modprobe snd-aloop id=Loopback pcm_substreams=1 && cat /proc/asound/cards' | tee "$OUT/kernel.txt"
if guest 'pidof squeezelite' >/dev/null 2>&1; then
	echo "il player di Sweetspot e' in esecuzione: la prova userebbe la stessa scheda"
	guest 'ps' > "$OUT/processi.txt" 2>&1 || true
	exit 1
fi

echo "== Verifica PCM/DoP sul percorso ALSA del sistema avviato"
rc=0
python3 "$TEST_DIR/prova-audio.py" --ssh-port "$SSH_PORT" --backend alsa_loopback \
	--server http://127.0.0.1:9000 --output "$OUT" --version "$VERSIONE" || rc=1
guest 'dmesg' > "$OUT/dmesg.txt" 2>&1 || true
guest 'cat /var/log/messages' > "$OUT/messages.txt" 2>&1 || true
[ "$rc" -eq 0 ] || { echo "== Verifica ALSA non riuscita"; exit 1; }
echo "== Verifica ALSA riuscita"
