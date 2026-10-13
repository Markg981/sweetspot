#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova di Lyrion nel sistema compilato, su un computer della
# stessa architettura (nella CI: x86_64 su ubuntu-26.04, ARM a 64 bit su
# ubuntu-26.04-arm). Estrae il sistema dal pacchetto di aggiornamento, ci
# entra con chroot, carica i moduli compilati di Lyrion con il Perl del
# sistema e avvia Lyrion come sul player: deve rispondere alle richieste
# JSON-RPC. Controlla proprio cio' che non si puo' provare senza l'hardware:
# che i moduli compilati per ARM vadano d'accordo con il Perl di Buildroot.
#
#   sudo sh tests/prova-lyrion.sh sweetspot-<scheda>-aggiornamento.tar
#
# Nella CI (GITHUB_ACTIONS=true), se la prova non riesce, le ultime righe
# dell'uscita diventano annotazioni dell'esecuzione: il motivo si legge
# dalla pagina della CI senza scaricare i registri.

set -eu

# Prima esecuzione: si rilancia lo script registrandone l'uscita.
if [ -z "${PROVA_LYRION_LOG:-}" ]; then
	PROVA_LYRION_LOG=$(mktemp)
	export PROVA_LYRION_LOG
	{ rc=0; sh "$0" "$@" 2>&1 || rc=$?; echo "$rc" > "$PROVA_LYRION_LOG.rc"; } | tee "$PROVA_LYRION_LOG"
	rc=$(cat "$PROVA_LYRION_LOG.rc")
	if [ "$rc" != 0 ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
		grep -v '^[[:space:]]*$' "$PROVA_LYRION_LOG" | tail -n 120 | sed 's/%/%25/g; s/\r//g' > "$PROVA_LYRION_LOG.coda"
		split -l 20 "$PROVA_LYRION_LOG.coda" "$PROVA_LYRION_LOG.parte."
		for f in "$PROVA_LYRION_LOG".parte.*; do
			echo "::error title=Prova di Lyrion (${f##*.})::$(awk 'BEGIN{ORS="%0A"} {print}' "$f")"
		done
	fi
	rm -f "$PROVA_LYRION_LOG" "$PROVA_LYRION_LOG".*
	exit "$rc"
fi
# Nel sistema compilato c'e' solo la localizzazione C.
export LC_ALL=C LANG=C
umask 022
TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$TEST_DIR")
SWEETSPOT_AUDIO_REPORT_DIR=${SWEETSPOT_AUDIO_REPORT_DIR:-$REPO_DIR/graphify-out/audio-evidence}
mkdir -p "$SWEETSPOT_AUDIO_REPORT_DIR"
SWEETSPOT_AUDIO_REPORT_DIR=$(readlink -f "$SWEETSPOT_AUDIO_REPORT_DIR")
SWEETSPOT_AUDIO_REPORT_DIR=$(mktemp -d "$SWEETSPOT_AUDIO_REPORT_DIR/run.XXXXXX")
chmod 755 "$SWEETSPOT_AUDIO_REPORT_DIR"
echo "Evidenza della prova: $SWEETSPOT_AUDIO_REPORT_DIR"
PKG=$(readlink -f "$1")
W=$(mktemp -d)
R=$W/sistema
PORT=9000

stop_all() {
	local p
	for p in /proc/[0-9]*; do
		[ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && kill -9 "${p#/proc/}" 2>/dev/null
	done
	return 0
}

cleanup() {
	cleanup_rc=$?
	stop_all
	if [ -d "$R/tmp/lms/log" ]; then
		if ! mkdir -p "$SWEETSPOT_AUDIO_REPORT_DIR/lyrion-log" ||
			! cp -a "$R/tmp/lms/log/." "$SWEETSPOT_AUDIO_REPORT_DIR/lyrion-log/"; then
			echo "impossibile conservare i log Lyrion" >&2
			[ "$cleanup_rc" -ne 0 ] || cleanup_rc=1
		fi
	fi
	if [ -f "$W/avvio.log" ] && ! cp "$W/avvio.log" "$SWEETSPOT_AUDIO_REPORT_DIR/lyrion-startup.log"; then
		echo "impossibile conservare il log di avvio" >&2
		[ "$cleanup_rc" -ne 0 ] || cleanup_rc=1
	fi
	sleep 1
	for m in dev/pts dev sys proc run tmp; do
		umount "$R/$m" 2>/dev/null || true
	done
	# Non eliminare il contenuto di un mount che non siamo riusciti a smontare.
	if awk -v r="$R" '$2 == r || index($2, r "/") == 1 { found=1 } END { exit !found }' /proc/mounts; then
		echo "mount ancora presenti in $R: cartella temporanea conservata" >&2
		[ "$cleanup_rc" -ne 0 ] || cleanup_rc=1
	else
		rm -rf "$W" || cleanup_rc=1
	fi
	return "$cleanup_rc"
}
trap cleanup EXIT

# Non entrare in conflitto con un server musicale gia' in uso sul computer.
python3 - <<'PYTHON'
import socket
for kind, port in ((socket.SOCK_STREAM, 9000), (socket.SOCK_STREAM, 3483), (socket.SOCK_DGRAM, 3483)):
    with socket.socket(socket.AF_INET, kind) as probe:
        try:
            probe.bind(('0.0.0.0', port))
        except OSError as error:
            raise SystemExit(f"porta Lyrion {port} non disponibile: {error}")
PYTHON

echo "== Sistema dal pacchetto $(basename "$PKG")"
tar -xf "$PKG" -C "$W" rootfs.cpio.zst architettura versione
echo "scheda $(cat "$W/architettura"), versione $(cat "$W/versione"), macchina $(uname -m)"
mkdir "$R"
zstd -dc "$W/rootfs.cpio.zst" | (cd "$R" && cpio -idm --quiet 2>/dev/null) || true
[ -x "$R/usr/bin/perl" ] || { echo "perl non trovato nel sistema"; exit 1; }
mount -t proc proc "$R/proc"
mount -t sysfs sys "$R/sys"
mount --bind /dev "$R/dev"
mount -t tmpfs tmpfs "$R/tmp"
mount -t tmpfs tmpfs "$R/run"
cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true

echo "== Moduli compilati di Lyrion con il Perl del sistema"
cat > "$R/tmp/moduli.pl" <<'PERL'
use strict;
use warnings;
use Config;
my $v = sprintf '%vd', $^V;
my ($maj) = $v =~ /^(\d+\.\d+)/;
my $base = "/opt/lms/CPAN/arch/$maj";
unshift @INC, "$base/$Config{archname}", $base, '/opt/lms/CPAN', '/opt/lms/lib', '/opt/lms';
print "Perl $v, $Config{archname}\n";
my $fail = 0;
for my $m (qw(
	Audio::Scan Class::XSAccessor DBD::SQLite DBI Digest::SHA1 EV
	Encode::Detect::Detector HTML::Parser IO::AIO IO::Interface Image::Scale
	JSON::XS Linux::Inotify2 MP3::Cut::Gapless Sub::Name Template::Stash::XS
	XML::Parser::Expat YAML::XS
)) {
	if (eval "require $m; 1") {
		printf "ok  %-26s %s\n", $m, ($m->VERSION // '');
	} else {
		printf "NO  %-26s %s\n", $m, $@ =~ s/\n.*//sr;
		$fail++;
	}
}
exit 1 if $fail;
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$dbh->do('CREATE TABLE t (a TEXT)');
$dbh->do('INSERT INTO t VALUES (?)', undef, 'Sweetspot');
die "SQLite\n" unless ($dbh->selectrow_array('SELECT a FROM t'))[0] eq 'Sweetspot';
die "JSON\n" unless JSON::XS->new->encode({ a => 1 }) eq '{"a":1}';
die "YAML\n" unless YAML::XS::Load("a: 1\n")->{a} == 1;
print "prova d'uso: ok\n";
PERL
if ! chroot "$R" /usr/bin/perl /tmp/moduli.pl; then
	echo "== Perl del sistema e cartelle dei moduli"
	chroot "$R" /usr/bin/perl -V:archname -V:version -V:usethreads -V:useithreads -V:usemultiplicity 2>&1 || true
	ls -la "$R"/opt/lms/CPAN/arch/ 2>&1 | head -n 20
	ls -la "$R"/opt/lms/CPAN/arch/5.*/ 2>&1 | head -n 40
	ls "$R"/usr/lib/perl5/*/ 2>&1 | head -n 10
	exit 1
fi

echo "== Avvio di Lyrion"
chroot "$R" /bin/sh -c '
	mkdir -p /tmp/lms/prefs /tmp/lms/cache /tmp/lms/log
	chown -R lms /tmp/lms
	exec su -s /bin/sh lms -c "exec perl /opt/lms/slimserver.pl --prefsdir /tmp/lms/prefs --cachedir /tmp/lms/cache --logdir /tmp/lms/log --charset utf8"
' > "$W/avvio.log" 2>&1 &

i=0
ans=""
while [ $i -lt 120 ]; do
	sleep 3
	i=$((i + 1))
	ans=$(curl -s -m 5 -H 'Content-Type: application/json' \
		-d '{"id":1,"method":"slim.request","params":["",["serverstatus",0,0]]}' \
		"http://127.0.0.1:$PORT/jsonrpc.js" 2>/dev/null) || ans=""
	[ -n "$ans" ] && break
	if ! kill -0 $! 2>/dev/null; then
		echo "Lyrion si e' fermato"
		break
	fi
done
if printf '%s' "$ans" | grep -q '"version"'; then
	echo "Lyrion risponde dopo circa $((i * 3)) secondi:"
	printf '%s\n' "$ans" | head -c 400
	echo
	# Errori di caricamento dei moduli nel registro di Lyrion.
	if grep -E "Can't locate|Bad handshake|undefined symbol|object version" "$W/avvio.log" "$R"/tmp/lms/log/*.log 2>/dev/null; then
		echo "errori di caricamento nel registro"
		exit 1
	fi
	audio_rc=0
	echo "== Verifica PCM/DoP e continuita' dei brani nel backend software"
	python3 "$TEST_DIR/prova-audio.py" --rootfs "$R" \
		--server "http://127.0.0.1:$PORT" --output "$SWEETSPOT_AUDIO_REPORT_DIR" \
		--version "$(cat "$W/versione")" || audio_rc=1
	# Stessi casi sul percorso ALSA vero: hw:Loopback di snd-aloop, con le
	# impostazioni del player (hw:, mmap, periodi). "richiesta" (nella CI)
	# rende la scheda obbligatoria; "auto" prova solo se c'e'; "no" salta.
	alsa=${SWEETSPOT_AUDIO_ALSA:-auto}
	if [ "$alsa" != no ] && [ -e /proc/asound/Loopback ]; then
		echo "== Verifica PCM/DoP sul percorso ALSA (snd-aloop)"
		python3 "$TEST_DIR/prova-audio.py" --rootfs "$R" --backend alsa_loopback \
			--server "http://127.0.0.1:$PORT" --output "$SWEETSPOT_AUDIO_REPORT_DIR/alsa-loopback" \
			--version "$(cat "$W/versione")" || audio_rc=1
	elif [ "$alsa" = richiesta ]; then
		echo "scheda Loopback assente: serve 'modprobe snd-aloop' prima della prova"
		audio_rc=1
	else
		echo "== Verifica ALSA non eseguita (SWEETSPOT_AUDIO_ALSA=$alsa; serve la scheda di 'modprobe snd-aloop')"
	fi
	[ "$audio_rc" -eq 0 ] || { echo "== Verifica audio non riuscita"; exit 1; }
	echo "== Lyrion e verifica PCM/DoP riusciti"
	exit 0
fi
echo "Lyrion non risponde. Registro di avvio:"
tail -n 60 "$W/avvio.log"
tail -n 60 "$R"/tmp/lms/log/server.log 2>/dev/null || true
exit 1
