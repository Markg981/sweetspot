#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova dei moduli compilati di Lyrion: li carica tutti e ne usa
# qualcuno, come fa il server. Uso: perl -I ARCH -I ARCH/NOME prova.pl
use strict;
use warnings;

my @modules = qw(
	Audio::Scan Class::XSAccessor DBD::SQLite DBI Digest::SHA1 EV
	Encode::Detect::Detector HTML::Parser IO::AIO IO::Interface Image::Scale
	JSON::XS Linux::Inotify2 MP3::Cut::Gapless Sub::Name Template::Stash::XS
	XML::Parser::Expat YAML::XS
);
my $fail = 0;
for my $m (@modules) {
	if (eval "require $m; 1") {
		printf "ok  %-26s %s\n", $m, ($m->VERSION // '');
	} else {
		printf "NO  %-26s %s\n", $m, $@ =~ s/\n.*//sr;
		$fail++;
	}
}
exit 1 if $fail;

# Uso reale: SQLite in memoria, JSON, digest, YAML.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$dbh->do('CREATE TABLE t (a TEXT)');
$dbh->do('INSERT INTO t VALUES (?)', undef, 'Sweetspot');
my ($v) = $dbh->selectrow_array('SELECT a FROM t');
die "SQLite\n" unless $v eq 'Sweetspot';
die "JSON\n" unless JSON::XS->new->encode({ a => 1 }) eq '{"a":1}';
die "SHA1\n" unless Digest::SHA1::sha1_hex('abc') eq 'a9993e364706816aba3e25717850c26c9cd0d89d';
die "YAML\n" unless YAML::XS::Load("a: 1\n")->{a} == 1;
print "prova d'uso: ok\n";
