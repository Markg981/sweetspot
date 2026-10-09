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

set -eu
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
	stop_all
	sleep 1
	for m in dev/pts dev sys proc run tmp; do
		umount "$R/$m" 2>/dev/null || true
	done
	rm -rf "$W"
}
trap cleanup EXIT

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
chroot "$R" /usr/bin/perl /tmp/moduli.pl

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
	echo "== Lyrion funziona"
	exit 0
fi
echo "Lyrion non risponde. Registro di avvio:"
tail -n 60 "$W/avvio.log"
tail -n 60 "$R"/tmp/lms/log/server.log 2>/dev/null || true
exit 1
