#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - taglio di corrente durante l'aggiornamento A/B, sull'immagine
# x86 avviata in QEMU. Il "taglio" e' un SIGKILL a QEMU: la cache del file
# system del sistema ospite (scritture non ancora su disco) va persa, come
# toglie la corrente a un computer vero.
#
#   1. durante la scrittura della copia B (primo file spostato, non ancora
#      su disco): la copia B non e' valida;
#   2. a scrittura finita ma prima del marcatore di copia completa
#      (boot/versioni/b): la copia B ha i file ma non e' valida;
#   3. dopo l'installazione completa, durante la prima prova della copia
#      nuova e prima della conferma (sweetspot-aggiorna conferma): GRUB ha
#      gia' consumato "prova", ma lo stato "tentato" resta e al riavvio
#      riparte la copia A, che poi chiude la prova.
#
# Dopo ogni taglio la prova controlla, a macchina spenta e poi al riavvio:
# la FAT della chiavetta (fsck.fat), il marcatore, grubenv, la copia da cui
# riparte il sistema (sweetspot.slot=a) e che "altra" rifiuti la copia
# interrotta.
#
# Il pacchetto e' firmato con una chiave creata qui (SWEETSPOT_CHIAVE_FIRMA
# la sostituisce a quella del progetto, solo per il processo di prova): il
# kernel e' quello vero dell'immagine, il sistema (rootfs) e' un file casuale
# di 1 MiB, perche' la chiavetta da 512 MB non ha posto per due sistemi
# completi accanto a un pacchetto. Basta: nella prova 3 il kernel parte e si
# ferma subito, la copia nuova non deve funzionare davvero.
#
#   sudo sh tests/prova-taglio-corrente-qemu.sh sweetspot.img.xz
#
# Serve: qemu-system-x86, mtools, xz-utils, sshpass, dosfstools, minisign.
# La porta 2224 (SSH_PORT) di 127.0.0.1 deve essere libera.
# Esito e registri in $SWEETSPOT_AUDIO_REPORT_DIR/taglio-corrente-qemu.*.

set -eu
export LC_ALL=C LANG=C
umask 022
TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$TEST_DIR")
IMG=$(readlink -f "$1")
SSH_PORT=${SSH_PORT:-2224}
REPORT_DIR=${SWEETSPOT_AUDIO_REPORT_DIR:-$REPO_DIR/graphify-out/audio-evidence}
mkdir -p "$REPORT_DIR"
OUT=$(mktemp -d "$(readlink -f "$REPORT_DIR")/taglio-corrente-qemu.XXXXXX")
chmod 755 "$OUT"
echo "Evidenza delle prove di taglio di corrente: $OUT"
W=$(mktemp -d)
FAIL=0
VERSIONE_PROVA=v99.0.0-prova
PKG=sweetspot-x86_64-aggiornamento.tar

cleanup() {
	rc=$?
	stop_vm
	[ -f "$W/seriale.log" ] && cp "$W/seriale.log" "$OUT/console-seriale-finale.log"
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

ACCEL=tcg
CPU=max
if [ -w /dev/kvm ]; then
	ACCEL=kvm
	CPU=host
fi
avvia_vm() {
	qemu-system-x86_64 -machine q35,accel=$ACCEL -cpu $CPU -m 2048 -smp 4,sockets=1,cores=4,threads=1 \
		-device qemu-xhci,id=xhci \
		-drive if=none,id=chiavetta,format=raw,file="$W/disco.img" \
		-device usb-storage,bus=xhci.0,drive=chiavetta,bootindex=0 \
		-nic user,model=e1000,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
		-display none -monitor none -serial file:"$W/seriale.log" \
		-pidfile "$W/qemu.pid" -daemonize
}

# Il taglio di corrente: nessuna chiusura ordinata, niente sync del guest.
taglia() { # nome
	pid=$(cat "$W/qemu.pid")
	kill -9 "$pid"
	i=0
	while kill -0 "$pid" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
	rm -f "$W/qemu.pid"
	cp "$W/seriale.log" "$OUT/console-seriale-$1.log" 2>/dev/null || true
}

# Riavvia dopo il taglio e aspetta il sistema stabile.
riavvia() {
	avvia_vm
	wait_ssh 500 || { echo "SSH non risponde dopo il riavvio. Console:"; tail -n 60 "$W/seriale.log"; return 1; }
	qemu_attendi_stabile 600
}

# La partizione SWEETSPOT (parte a 1 MiB, come per mtools), a macchina spenta.
chiavetta() { echo "$W/disco.img@@1M"; }
grubenv() { mtype -i "$(chiavetta)" ::/boot/grub/grubenv 2>/dev/null | sed -n "s/^$1=//p" | head -n 1; }
marcatore_b() { mdir -b -i "$(chiavetta)" ::/boot/versioni 2>/dev/null | grep -qi '/versioni/b$'; }
file_in_b() { mdir -b -i "$(chiavetta)" ::/b 2>/dev/null | grep -qi "/b/$1\$"; }

# La FAT, dopo il taglio: nessun errore di struttura. Il solo "non smontata
# bene" (bit di sporco, riepilogo dei cluster liberi) e' atteso; qualunque
# altro errore, o un fsck -a che non basta a rimetterla a posto, no.
GUASTI='cross-linked|contains a free cluster|truncat|reclaim|does not point|bad file|invalid|differences between|beyond|lost'
controlla_fat() { # nome
	dd if="$W/disco.img" of="$W/fat.img" bs=1M skip=1 status=none
	rc=0
	fsck.fat -n "$W/fat.img" > "$OUT/fsck-$1.txt" 2>&1 || rc=$?
	if [ $rc -eq 0 ]; then
		esito OK "$1: FAT integra (fsck.fat)"
	elif grep -Ei "$GUASTI" "$OUT/fsck-$1.txt" | grep -vxFf "$OUT/fsck-base.txt" > "$OUT/nuovi-$1.txt" && [ -s "$OUT/nuovi-$1.txt" ]; then
		esito NO "$1: FAT corrotta (errori nuovi rispetto all'immagine integra): $(head -n 3 "$OUT/nuovi-$1.txt" | tr '\n' ' ')"
	else
		fsck.fat -a "$W/fat.img" >> "$OUT/fsck-$1.txt" 2>&1 || true
		fsck.fat -n "$W/fat.img" > "$OUT/fsck2-$1.txt" 2>&1 && rc=0 || rc=$?
		cat "$OUT/fsck2-$1.txt" >> "$OUT/fsck-$1.txt"
		if [ $rc -eq 0 ] || ! { grep -Ei "$GUASTI" "$OUT/fsck2-$1.txt" | grep -qvxFf "$OUT/fsck-base.txt"; }; then
			esito OK "$1: FAT senza errori di struttura (solo bit di sporco, sistemato da fsck -a)"
		else
			esito NO "$1: FAT non riparabile: $(tail -n 3 "$OUT/fsck-$1.txt" | tr '\n' ' ')"
		fi
	fi
	rm -f "$W/fat.img"
}

echo "== Copia di prova dell'immagine"
case "$IMG" in
	*.xz) xz -dc "$IMG" > "$W/disco.img" ;;
	*) cp "$IMG" "$W/disco.img" ;;
esac
mcopy -o -i "$W/disco.img@@1M" ::/boot/grub/grub.cfg "$W/grub.cfg"
sed -i 's/quiet loglevel=3 /console=tty0 console=ttyS0,115200 /' "$W/grub.cfg"
mcopy -o -i "$W/disco.img@@1M" "$W/grub.cfg" ::/boot/grub/grub.cfg
mcopy -o -i "$W/disco.img@@1M" ::/sweetspot.txt "$W/sweetspot.txt"
printf '\nSSH=si\nSSH_PASSWORD=%s\nMODALITA_ASCOLTO=no\nBLUETOOTH=no\nLYRION_UTENTE=prova\nLYRION_PASSWORD=%s\n' \
	"$SSHPASS" "$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> "$W/sweetspot.txt"
mcopy -o -i "$W/disco.img@@1M" "$W/sweetspot.txt" ::/sweetspot.txt
# Segnalazioni gia' presenti nell'immagine prima di ogni taglio (ad esempio la
# copia del settore di avvio): non dipendono dal taglio e non si contano.
dd if="$W/disco.img" of="$W/fat.img" bs=1M skip=1 status=none
fsck.fat -n "$W/fat.img" > "$OUT/fsck-base.txt" 2>&1 || true
grep -Ei "$GUASTI" "$OUT/fsck-base.txt" > "$OUT/fsck-base.guasti" 2>/dev/null || true
mv "$OUT/fsck-base.guasti" "$OUT/fsck-base.txt"
rm -f "$W/fat.img"

echo "== Pacchetto di prova firmato con una chiave creata qui"
mkdir -p "$W/pkg" "$W/guest-cut"
mcopy -o -i "$W/disco.img@@1M" ::/bzImage "$W/pkg/bzImage"
head -c 1048576 /dev/urandom > "$W/pkg/rootfs.cpio.zst"
echo "$VERSIONE_PROVA" > "$W/pkg/versione"
echo x86_64 > "$W/pkg/architettura"
(cd "$W/pkg" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
minisign -G -W -f -p "$W/prova.pub" -s "$W/prova.key" > /dev/null
minisign -S -W -s "$W/prova.key" -m "$W/pkg/SHA256SUMS" -x "$W/pkg/SHA256SUMS.minisig" \
	-t "Sweetspot $VERSIONE_PROVA x86_64" > /dev/null
(cd "$W/pkg" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$W/$PKG" -- *)
# Guardiano nel guest: aspetta il punto scelto, ferma tutto il lavoro di
# aggiornamento (SIGSTOP al gruppo) e scrive su disco quello che c'e' fino a
# quel momento; poi segnala. Il taglio vero (kill -9 di QEMU) lo fa l'host.
# Cosi' il taglio cade tra due scritture note, senza gare di tempo. (Un sync
# finto davanti al vero non e' affidabile: BusyBox non lo cerca nel PATH.)
cat > "$W/guest-cut/ferma.sh" <<'FINTO'
S=/run/sweetspot/chiavetta
D=/run/sweetspot/aggiornamento
while :; do
	case "$1" in
		scrittura) [ -f "$S/b/bzImage" ] && [ ! -f "$S/b/rootfs.cpio.zst" ] && break ;;
		marcatore) [ -f "$D/hash.copia" ] && break ;;
	esac
done
pid=$(cat "$D/pid" 2>/dev/null)
kill -STOP "-$pid"
echo "fermo con: b=$(ls "$S/b" 2>&1 | tr '\n' ' ') versioni=$(ls "$S/boot/versioni" 2>&1 | tr '\n' ' ')" > /tmp/cut/raggiunto.tmp
sync
mv /tmp/cut/raggiunto.tmp /tmp/cut/raggiunto
FINTO
# Legge "tentato" da grubenv nel guest (montando la chiavetta in sola lettura).
cat > "$W/guest-cut/tentato.sh" <<'FINTO'
. /usr/lib/sweetspot/common.sh
stick_mount ro || exit 1
echo "tentato=$(grubenv_get "$(boot_env)" tentato)"
echo "prova=$(grubenv_get "$(boot_env)" prova)"
stick_umount
FINTO

echo "== Primo avvio in QEMU ($ACCEL)"
avvia_vm
if ! wait_ssh 500; then
	echo "SSH non risponde dopo circa 500 secondi. Console:"
	tail -n 80 "$W/seriale.log"
	exit 1
fi
. "$TEST_DIR/qemu-attesa.sh"
qemu_attendi_stabile 600 || exit 1

slot_guest() { guest "tr ' ' '\n' < /proc/cmdline | sed -n 's/^sweetspot.slot=//p'" 2>/dev/null || true; }
[ "$(slot_guest)" = a ] || { echo "il sistema non e' partito dalla copia A"; exit 1; }
guest 'df -k /run/sweetspot/chiavetta 2>/dev/null; true' > "$OUT/spazio.txt" 2>&1 || true

# Porta nel guest pacchetto, chiave e script (/tmp si perde a ogni riavvio).
prepara_guest() {
	guest 'rm -rf /tmp/cut; mkdir -p /tmp/cut/bin /tmp/cut/media'
	guest 'cat > /tmp/cut/media/'"$PKG" < "$W/$PKG"
	guest 'cat > /tmp/cut/prova.pub' < "$W/prova.pub"
	guest 'cat > /tmp/cut/ferma.sh' < "$W/guest-cut/ferma.sh"
	guest 'cat > /tmp/cut/tentato.sh' < "$W/guest-cut/tentato.sh"
}
# Avvia l'aggiornamento col "sync" finto; $1 = punto del taglio (vuoto: nessuno).
avvia_aggiornamento() {
	[ -z "$1" ] || guest "setsid sh /tmp/cut/ferma.sh '$1' > /dev/null 2>&1 < /dev/null &"
	guest "SWEETSPOT_MEDIA=/tmp/cut/media SWEETSPOT_CHIAVE_FIRMA=/tmp/cut/prova.pub sweetspot-aggiorna file-downgrade /tmp/cut/media/$PKG"
}
attendi_guest() { # comando secondi
	i=0
	until guest "$1" > /dev/null 2>&1; do
		i=$((i + 2))
		[ $i -ge "$2" ] && return 1
		sleep 2
	done
}

# Dopo il riavvio che segue un taglio nell'aggiornamento (copia B interrotta).
verifica_copia_interrotta() { # nome
	if [ "$(slot_guest)" = a ]; then
		esito OK "$1: al riavvio parte la copia A"
	else
		esito NO "$1: al riavvio la copia e' '$(slot_guest)', non A"
	fi
	rc=0
	msg=$(guest 'sweetspot-aggiorna altra' 2>&1) || rc=$?
	prova=$(guest 'sweetspot-aggiorna stato' | sed -n 's/^prova=//p')
	if [ $rc -ne 0 ] && [ -z "$prova" ]; then
		esito OK "$1: la copia B interrotta non e' valida (altra rifiutata: $msg)"
	else
		esito NO "$1: 'altra' ha accettato la copia B interrotta (rc=$rc, prova=$prova)"
	fi
}

# Un taglio durante l'aggiornamento: $1 nome, $2 punto.
taglio_aggiornamento() {
	nome=$1
	echo "== Taglio: $nome"
	prepara_guest
	avvia_aggiornamento "$2"
	if ! attendi_guest 'test -f /tmp/cut/raggiunto' 180; then
		esito NO "$nome: l'aggiornamento non e' arrivato al punto del taglio ($(guest 'cat /run/sweetspot/aggiornamento/stato' 2>&1))"
		guest 'ls -l /tmp/cut /run/sweetspot/aggiornamento /run/sweetspot/chiavetta/b; ps | grep -c ferma' 2>&1 | sed 's/^/    diag: /'
		taglia "$nome"
		return 0
	fi
	taglia "$nome"
	if marcatore_b; then
		esito NO "$nome: dopo il taglio il marcatore della copia B c'e' gia'"
	else
		esito OK "$nome: dopo il taglio il marcatore della copia B non c'e'"
	fi
	if [ -z "$(grubenv prova)" ] && [ "$(grubenv slot)" = a ]; then
		esito OK "$nome: grubenv senza prova, predefinita A"
	else
		esito NO "$nome: grubenv: slot=$(grubenv slot) prova=$(grubenv prova)"
	fi
	controlla_fat "$nome"
}

taglio_aggiornamento scrittura scrittura
if riavvia; then
	verifica_copia_interrotta scrittura
else
	esito NO "scrittura: il sistema non e' ripartito dopo il taglio"
	exit 1
fi

taglio_aggiornamento marcatore marcatore
if file_in_b bzImage && file_in_b rootfs.cpio.zst; then
	esito OK "marcatore: i file della copia B sono su disco ma senza marcatore"
else
	esito NO "marcatore: i file della copia B non sono tutti su disco, il taglio non e' dopo la scrittura"
fi
if riavvia; then
	verifica_copia_interrotta marcatore
else
	esito NO "marcatore: il sistema non e' ripartito dopo il taglio"
	exit 1
fi

echo "== Taglio: prima della conferma"
prepara_guest
avvia_aggiornamento ""
if attendi_guest 'grep -q "^pronto|" /run/sweetspot/aggiornamento/stato' 180; then
	esito OK "conferma: installazione completa ($(guest 'cat /run/sweetspot/aggiornamento/stato'))"
else
	esito NO "conferma: installazione non riuscita ($(guest 'cat /run/sweetspot/aggiornamento/stato' 2>&1))"
	exit 1
fi
[ "$(guest 'sweetspot-aggiorna stato' | sed -n 's/^prova=//p')" = b ] ||
	esito NO "conferma: dopo l'installazione 'prova' non e' b"
off=$(wc -c < "$W/seriale.log")
guest 'sync; reboot' > /dev/null 2>&1 || true
i=0
until tail -c +$((off + 1)) "$W/seriale.log" | grep -q 'sweetspot.slot=b'; do
	i=$((i + 1))
	if [ $i -ge 600 ]; then
		esito NO "conferma: la copia B non e' partita in prova"
		tail -n 40 "$W/seriale.log"
		exit 1
	fi
	sleep 1
done
# Il kernel della copia nuova e' partito, la conferma (a fine avvio) no.
taglia conferma
if [ "$(grubenv slot)" = a ] && [ -z "$(grubenv prova)" ] && [ "$(grubenv tentato)" = b ]; then
	esito OK "conferma: dopo il taglio GRUB ha consumato 'prova' e segna tentato=b, predefinita A"
else
	esito NO "conferma: grubenv slot=$(grubenv slot) prova=$(grubenv prova) tentato=$(grubenv tentato)"
fi
if marcatore_b; then
	esito OK "conferma: la copia B resta completa (marcatore presente)"
else
	esito NO "conferma: marcatore della copia B perso"
fi
controlla_fat conferma
if riavvia; then
	if [ "$(slot_guest)" = a ]; then
		esito OK "conferma: al riavvio dopo il taglio parte la copia A, non quella mai confermata"
	else
		esito NO "conferma: al riavvio parte la copia '$(slot_guest)'"
	fi
	# La conferma di A (S99, in sottofondo) chiude la prova interrotta.
	guest 'mkdir -p /tmp/cut; cat > /tmp/cut/tentato.sh' < "$W/guest-cut/tentato.sh"
	i=0
	while :; do
		stato=$(guest 'sh /tmp/cut/tentato.sh' 2>/dev/null) || stato=""
		case "$stato" in "tentato="*) [ "$stato" != "$(printf 'tentato=\nprova=')" ] || break ;; esac
		i=$((i + 5))
		[ $i -ge 180 ] && break
		sleep 5
	done
	if [ "$stato" = "$(printf 'tentato=\nprova=')" ]; then
		esito OK "conferma: la copia A chiude la prova interrotta (tentato azzerato)"
	else
		esito NO "conferma: la prova interrotta non si e' chiusa ($(echo "$stato" | tr '\n' ' '))"
	fi
else
	esito NO "conferma: il sistema non e' ripartito dopo il taglio"
fi
guest 'cat /var/log/sweetspot.log' > "$OUT/sweetspot.log" 2>&1 || true

echo "== FAT della chiavetta a fine prova"
stop_vm
controlla_fat finale

[ "$FAIL" -eq 0 ] || { echo "== Prove di taglio di corrente non riuscite"; exit 1; }
echo "== Prove di taglio di corrente riuscite"
