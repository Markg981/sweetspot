#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prove di robustezza sull'immagine x86 avviata in QEMU:
#   1. watchdog attivo (i6300ESB, il watchdog hardware emulato da QEMU);
#   2. DAC USB collegato a caldo: il player parte;
#   3. DAC scollegato a caldo: il player si ferma e aspetta;
#   4. DAC ricollegato: il player riparte con un nuovo processo;
#   5. blocco simulato (servizio del watchdog fermato con SIGSTOP): il
#      computer riparte da solo, come dopo un'interruzione brusca, e il
#      player torna attivo;
#   6. a macchina spenta, il file system della chiavetta e' integro.
#
#   sudo sh tests/prova-robustezza-qemu.sh sweetspot.img.xz
#
# Serve: qemu-system-x86, mtools, xz-utils, sshpass, dosfstools e python3.
# La porta 2223 (SSH_PORT) di 127.0.0.1 deve essere libera.
# Esito e registri in $SWEETSPOT_AUDIO_REPORT_DIR/robustezza-qemu.*.

set -eu
export LC_ALL=C LANG=C
umask 022
TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$TEST_DIR")
IMG=$(readlink -f "$1")
SSH_PORT=${SSH_PORT:-2223}
REPORT_DIR=${SWEETSPOT_AUDIO_REPORT_DIR:-$REPO_DIR/graphify-out/audio-evidence}
mkdir -p "$REPORT_DIR"
OUT=$(mktemp -d "$(readlink -f "$REPORT_DIR")/robustezza-qemu.XXXXXX")
chmod 755 "$OUT"
echo "Evidenza delle prove di robustezza: $OUT"
W=$(mktemp -d)
FAIL=0

cleanup() {
	rc=$?
	stop_vm
	[ -f "$W/seriale.log" ] && cp "$W/seriale.log" "$OUT/console-seriale.log"
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

# Un comando QMP (JSON) al monitor di QEMU; stampa la risposta.
qmp() {
	python3 - "$W/qmp.sock" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
def reply():
    while True:
        m = json.loads(f.readline())
        if "event" not in m:
            return m
reply()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); reply()
f.write(sys.argv[2] + "\n"); f.flush()
r = reply()
print(json.dumps(r))
sys.exit(1 if "error" in r else 0)
EOF
}

wait_ssh() { # secondi
	i=0
	until guest true 2>/dev/null; do
		i=$((i + 5))
		[ $i -ge "$1" ] && return 1
		sleep 5
	done
}

# Attende che lo stato del player contenga il testo; ultimo stato in $STATO.
wait_player() { # testo secondi
	i=0
	while :; do
		STATO=$(guest 'cat /run/sweetspot/player.stato' 2>/dev/null) || STATO=""
		case "$STATO" in *"$1"*) return 0 ;; esac
		i=$((i + 2))
		[ $i -ge "$2" ] && return 1
		sleep 2
	done
}
squeezelite_pid() { guest 'pidof squeezelite' 2>/dev/null || true; }

echo "== Copia di prova dell'immagine"
case "$IMG" in
	*.xz) xz -dc "$IMG" > "$W/disco.img" ;;
	*) cp "$IMG" "$W/disco.img" ;;
esac
mcopy -o -i "$W/disco.img@@1M" ::/boot/grub/grub.cfg "$W/grub.cfg"
sed -i 's/quiet loglevel=3 /console=tty0 console=ttyS0,115200 /' "$W/grub.cfg"
mcopy -o -i "$W/disco.img@@1M" "$W/grub.cfg" ::/boot/grub/grub.cfg
mcopy -o -i "$W/disco.img@@1M" ::/sweetspot.txt "$W/sweetspot.txt"
printf '\nSSH=si\nSSH_PASSWORD=%s\nMODALITA_ASCOLTO=no\nBLUETOOTH=si\n' "$SSHPASS" >> "$W/sweetspot.txt"
mcopy -o -i "$W/disco.img@@1M" "$W/sweetspot.txt" ::/sweetspot.txt

ACCEL=tcg
CPU=max
if [ -w /dev/kvm ]; then
	ACCEL=kvm
	CPU=host
fi
echo "== Avvio in QEMU ($ACCEL) con watchdog i6300ESB"
qemu-system-x86_64 -machine q35,accel=$ACCEL -cpu $CPU -m 4096 -smp 4,sockets=1,cores=4,threads=1 \
	-device qemu-xhci,id=xhci \
	-drive if=none,id=chiavetta,format=raw,file="$W/disco.img" \
	-device usb-storage,bus=xhci.0,drive=chiavetta,bootindex=0 \
	-nic user,model=e1000,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
	-audiodev none,id=nessuno \
	-device i6300esb -action watchdog=reset \
	-qmp unix:"$W/qmp.sock",server=on,wait=off \
	-display none -monitor none -serial file:"$W/seriale.log" \
	-pidfile "$W/qemu.pid" -daemonize

if ! wait_ssh 500; then
	echo "SSH non risponde dopo circa 500 secondi. Console:"
	tail -n 80 "$W/seriale.log"
	exit 1
fi
echo "SSH pronto"
# Fine dell'avvio: i servizi sono partiti tutti.
i=0
until guest 'test -f /run/sweetspot/avvio-completato' 2>/dev/null || [ $i -ge 300 ]; do i=$((i + 5)); sleep 5; done

echo "== 1. Watchdog"
guest 'cat /sys/class/watchdog/watchdog0/identity /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeout; pidof watchdog' \
	> "$OUT/watchdog.txt" 2>&1 || true
if grep -q i6300ESB "$OUT/watchdog.txt" && grep -qx active "$OUT/watchdog.txt"; then
	esito OK "watchdog i6300ESB attivo e alimentato"
else
	esito NO "watchdog non attivo: $(tr '\n' ' ' < "$OUT/watchdog.txt")"
fi

echo "== 2. DAC collegato a caldo"
qmp '{"execute":"device_add","arguments":{"driver":"usb-audio","id":"dac","bus":"xhci.0","audiodev":"nessuno"}}' >> "$OUT/qmp.txt"
if wait_player "attivo su" 90 && [ -n "$(squeezelite_pid)" ]; then
	esito OK "DAC collegato: player attivo ($STATO)"
else
	esito NO "DAC collegato: player non attivo (stato: $STATO)"
fi
pid1=$(squeezelite_pid)

echo "== 3. DAC scollegato a caldo"
qmp '{"execute":"device_del","arguments":{"id":"dac"}}' >> "$OUT/qmp.txt"
if wait_player "in attesa del DAC" 60 && [ -z "$(squeezelite_pid)" ]; then
	esito OK "DAC scollegato: player fermo in attesa"
else
	esito NO "DAC scollegato: stato '$STATO', squeezelite $(squeezelite_pid)"
fi

echo "== 4. DAC ricollegato"
qmp '{"execute":"device_add","arguments":{"driver":"usb-audio","id":"dac","bus":"xhci.0","audiodev":"nessuno"}}' >> "$OUT/qmp.txt"
if wait_player "attivo su" 90 && pid2=$(squeezelite_pid) && [ -n "$pid2" ] && [ "$pid2" != "$pid1" ]; then
	esito OK "DAC ricollegato: player ripartito (processo $pid1 -> $pid2)"
else
	esito NO "DAC ricollegato: stato '$STATO'"
fi

echo "== 4b. Bluetooth acceso senza adattatore"
guest 'pidof bluetoothd; pidof bluealsa; cat /run/sweetspot/bluetooth.stato; pidof squeezelite' > "$OUT/bluetooth.txt" 2>&1 || true
if [ "$(guest 'pidof bluetoothd bluealsa | wc -w')" -ge 2 ] && grep -q 'nessun adattatore' "$OUT/bluetooth.txt" && [ -n "$(squeezelite_pid)" ]; then
	esito OK "Bluetooth: servizi avviati senza hardware, stato 'nessun adattatore', player intatto"
else
	esito NO "Bluetooth: $(tr '\n' ' ' < "$OUT/bluetooth.txt")"
	guest 'tail -n 20 /var/log/sweetspot.log' >> "$OUT/bluetooth.txt" 2>&1 || true
fi

echo "== 5. Blocco simulato: il watchdog deve far ripartire il computer"
boot1=$(guest 'cat /proc/sys/kernel/random/boot_id')
guest 'kill -STOP $(pidof watchdog)' || true
sleep 20
boot2=""
i=0
while [ $i -lt 600 ]; do
	boot2=$(guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || boot2=""
	[ -n "$boot2" ] && [ "$boot2" != "$boot1" ] && break
	i=$((i + 5))
	sleep 5
done
if [ -n "$boot2" ] && [ "$boot2" != "$boot1" ]; then
	esito OK "blocco: ripartito da solo dopo circa $((i + 20)) secondi"
	if wait_player "attivo su" 300; then
		esito OK "dopo il riavvio il player e' di nuovo attivo"
	else
		esito NO "dopo il riavvio il player non e' attivo (stato: $STATO)"
	fi
else
	esito NO "blocco: il computer non e' ripartito"
fi
guest 'cat /var/log/sweetspot.log' > "$OUT/sweetspot.log" 2>&1 || true
guest 'dmesg' > "$OUT/dmesg.txt" 2>&1 || true

echo "== 6. File system della chiavetta dopo il riavvio brusco"
stop_vm
# La partizione SWEETSPOT inizia a 1 MiB (come per mtools).
dd if="$W/disco.img" of="$W/chiavetta.img" bs=1M skip=1 status=none
if fsck.fat -n "$W/chiavetta.img" > "$OUT/fsck.txt" 2>&1; then
	esito OK "chiavetta integra (fsck.fat)"
else
	esito NO "chiavetta: $(tail -n 3 "$OUT/fsck.txt" | tr '\n' ' ')"
fi

[ "$FAIL" -eq 0 ] || { echo "== Prove di robustezza non riuscite"; exit 1; }
echo "== Prove di robustezza riuscite"
