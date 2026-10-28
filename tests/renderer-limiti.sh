#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renderer UPnP: corpo POST massimo di 32 KB (413), lettura degli argomenti
# SOAP in tempo lineare, coda SSDP con tetto e rate limit per IP.
# Le funzioni si estraggono da renderer.pl e si provano da sole.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export RENDERER=$ROOT/board/sweetspot/rootfs-overlay/usr/lib/sweetspot/renderer.pl
if ! command -v perl >/dev/null 2>&1; then echo "perl non trovato: test del renderer saltato"; exit 0; fi
echo "Renderer: limiti di POST e SSDP"
exec perl - <<'PERL'
use strict; use warnings;
use Socket qw(inet_aton inet_ntoa pack_sockaddr_in unpack_sockaddr_in AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Select; use IO::Handle;
use Time::HiRes qw(time);
my ($pass, $fail) = (0, 0);
sub ok { my ($n, $c) = @_; if ($c) { $pass++; print "  ok  $n\n" } else { $fail++; print "  NO  $n\n" } }

open my $f, '<', $ENV{RENDERER} or die $!;
my $src = do { local $/; <$f> };
$src =~ s/\r\n/\n/g;
my $code = '';
$code .= $1 if $src =~ /^(my \$MAX_BODY.*?^\}\n)/ms;
$code .= $1 if $src =~ /^(# Argomenti di una azione SOAP.*?^\}\n)/ms;
$code .= $1 if $src =~ /^(my \@pending_resp.*?^\}\n.*?^\}\n)/ms;
our @NT = map { [ "urn:x:$_", "uuid:x::$_" ] } 1 .. 6;
sub nt_list { @NT }
our $AP_IP = '192.168.4.1';
sub addr_for_peer { '10.0.0.1' }    # i peer del test non arrivano dall'hotspot
our (@pending_resp, %ssdp_rate);
our %slow_until;
$code =~ s{^my (@pending_resp|%ssdp_rate|%slow_until)}{our $1}mg;
eval "$code; 1" or die $@;
ok('funzioni estratte', defined &read_request && defined &soap_args && defined &handle_ssdp);

# Argomenti SOAP
my $b = '<s:Envelope><s:Body><u:SetVolume xmlns:u="x"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>42</DesiredVolume></u:SetVolume></s:Body></s:Envelope>';
my %a = soap_args($b, 'SetVolume');
ok('argomenti SOAP letti', ($a{DesiredVolume} // '') eq '42' && ($a{Channel} // '') eq 'Master' && ($a{InstanceID} // '') eq '0');
%a = soap_args('<u:Play><Speed>1</Speed><X/></u:Play>', 'Play');
ok('tag vuoto e valore', ($a{Speed} // '') eq '1' && exists $a{X} && $a{X} eq '');
%a = soap_args('<u:Stop></u:Stop>', 'Stop');
ok('azione senza argomenti', !%a);

# POST grande: 413 senza leggere tutto, e veloce
socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
my $t = time;
syswrite($cli, "POST /ctl/AVTransport HTTP/1.1\r\nContent-Length: 256000\r\n\r\n" . ('<a ' x 1000));
my ($h, $bd, $e) = read_request($srv);
ok('POST da 250 KB rifiutata con 413', !defined $h && ($e // 0) == 413);
ok('POST da 250 KB in meno di 1 s', time - $t < 1);
my $mal = '<u:Play>' . ('<a ' x 10000) . '</u:Play>';
$t = time; soap_args($mal, 'Play');
ok('30 KB di tag aperti senza chiusura in meno di 1 s', time - $t < 1);

# SSDP: 1000 M-SEARCH da molti IP, poi 100 da uno solo
my $ms = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: ssdp:all\r\n\r\n";
for my $i (1 .. 1000) {
	handle_ssdp($ms, pack_sockaddr_in(1000 + $i, inet_aton('10.0.' . ($i % 250) . '.' . (1 + $i % 200))));
}
ok('1000 M-SEARCH: coda sotto 64', @pending_resp < 64 + 1);
@pending_resp = (); %ssdp_rate = ();
handle_ssdp($ms, pack_sockaddr_in(5000, inet_aton('10.1.1.1'))) for 1 .. 100;
ok('stesso IP: rate limit (al massimo 8 M-SEARCH)', @pending_resp > 0 && @pending_resp <= 8 * @NT);
# Client lenti: 5 connessioni mute di fila non bloccano il ciclo per 5 * scadenza
use IO::Socket::INET;
my $ls = IO::Socket::INET->new(Proto => 'tcp', Listen => 16, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1) or die $!;
my $port = $ls->sockport;
my @mute = map { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) or die $! } 1 .. 5;
$t = time;
for (1 .. 5) { my $c = $ls->accept; my ($hh) = read_request($c); close $c }
my $dt = time - $t;
ok('5 client muti: blocco totale sotto 2 s', $dt < 2);
%slow_until = ();
my $norm = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) or die $!;
syswrite($norm, "GET /x HTTP/1.1
Host: a

");
my ($nh) = read_request($ls->accept);
ok('client normale servito dopo i lenti', defined $nh && $nh =~ /^GET /);
print "Risultato: $pass ok, $fail falliti\n";
exit($fail ? 1 : 0);
PERL
