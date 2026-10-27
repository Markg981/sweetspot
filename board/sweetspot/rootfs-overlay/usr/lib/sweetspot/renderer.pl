#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - renderer UPnP/DLNA in entrata (MediaRenderer:1).
#
# BubbleUPnP, JPlay, mconnect e le altre app UPnP vedono Sweetspot come un
# renderer. L'audio non passa da qui: SetAVTransportURI/Play diventano
# "playlist play" verso Lyrion, che apre l'indirizzo e lo suona sul player
# Squeezelite di Sweetspot. Il percorso e' quello della libreria (bit-perfect,
# DSD, correzione, un solo programma sul DAC): questo demone e' solo il
# telecomando UPnP, non apre mai il DAC.
#
#   RENDERER_UPNP=si|no     (predefinito no) acceso dal pannello (Sistema)
#
# Fa tre cose: risponde a SSDP (M-SEARCH) e annuncia il dispositivo,
# serve il descrittore e i tre servizi (AVTransport, RenderingControl,
# ConnectionManager) con SOAP ed eventi, e traduce le azioni in comandi
# JSON-RPC di Lyrion. Lo stato per la pagina Stato sta in $RUN/renderer.json.
#
# Variabili per i test: SWEETSPOT_RUN, SWEETSPOT_LMS_HOST, SWEETSPOT_LMS_HTTP_PORT,
# SWEETSPOT_RENDERER_PORTA (HTTP, predefinita 49494),
# SWEETSPOT_RENDERER_SSDP_PORTA (predefinita 1900),
# SWEETSPOT_RENDERER_ADDR (indirizzi annunciati, separati da virgola).

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Socket qw(inet_aton inet_ntoa pack_sockaddr_in unpack_sockaddr_in
	IPPROTO_IP IP_ADD_MEMBERSHIP IP_MULTICAST_IF IP_MULTICAST_TTL INADDR_ANY);
use HTTP::Tiny;
use JSON::PP ();
use Digest::MD5 qw(md5_hex);
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);

$| = 1;
my $RUN       = $ENV{SWEETSPOT_RUN} // '/run/sweetspot';
# Da utente senza privilegi: configurazione ridotta (renderer.conf) e stato nella
# cartella $RUN/renderer; se non c'e' (prove, sviluppo) si usa $RUN come prima.
my $DIR       = $ENV{SWEETSPOT_RENDERER_DIR} // "$RUN/renderer";
$DIR = $RUN unless -d $DIR;
my $CONF      = -r "$DIR/renderer.conf" ? "$DIR/renderer.conf" : "$RUN/sweetspot.conf";
my $AP_IP     = $ENV{SWEETSPOT_AP_IP} // '192.168.4.1';    # hotspot di configurazione: mai servito
my $LMS_HOST  = $ENV{SWEETSPOT_LMS_HOST} // '127.0.0.1';
my $LMS_PORT  = $ENV{SWEETSPOT_LMS_HTTP_PORT} // 9000;
my $HTTP_PORT = $ENV{SWEETSPOT_RENDERER_PORTA} // 49494;
my $SSDP_PORT = $ENV{SWEETSPOT_RENDERER_SSDP_PORTA} // 1900;
my $SSDP_ADDR = '239.255.255.250';
my $LOGFILE   = $ENV{SWEETSPOT_LOG} // ($DIR ne $RUN ? "$DIR/renderer.log" : '/var/log/sweetspot.log');
my $SERVER_ID = 'Linux/6 UPnP/1.0 Sweetspot/1';
my $MAX_AGE   = 1800;
# Limiti GENA: un abbonato lento o ostile non deve poter consumare memoria o processi.
my $MAX_SUBS      = ($ENV{SWEETSPOT_RENDERER_MAX_ABBONATI} // 0) =~ /^[1-9]\d*$/ ? $ENV{SWEETSPOT_RENDERER_MAX_ABBONATI} + 0 : 32;
my $MAX_SUBS_HOST = 8;       # abbonamenti per indirizzo di callback
my $MAX_CALLBACKS = 3;       # URL per abbonamento
my $MAX_CB_LEN    = 512;
my $MAX_NOTIFY    = 8;       # invii NOTIFY contemporanei (processi figli)
my $MAX_FAILS     = 3;       # invii falliti di fila prima di rimuovere l'abbonato

my $json = JSON::PP->new->utf8->allow_nonref;
my $http = HTTP::Tiny->new(timeout => 5, agent => 'Sweetspot-renderer/1');

sub logm {
	my $msg = join ' ', @_;
	if (open my $f, '>>', $LOGFILE) {
		print $f strftime('%Y-%m-%d %H:%M:%S', localtime), " renderer UPnP: $msg\n";
		close $f;
	}
}

# --- Impostazioni -------------------------------------------------------------

sub conf {
	my ($key, $default) = @_;
	my $v;
	if (open my $f, '<', $CONF) {
		while (my $line = <$f>) {
			$line =~ s/\r?\n$//;
			$v = $1 if $line =~ /^\Q$key\E=(.*)$/;
		}
		close $f;
	}
	return (defined $v && length $v) ? $v : $default;
}

sub is_yes { return lc($_[0] // '') =~ /^(si|sì|s|yes|y|1|true|on|vero|attivo)$/ ? 1 : 0 }

sub solo_player { return lc(conf('MODALITA', 'completa')) =~ /^(player|solo-player|soloplayer|squeezelite|lyrion|lms)$/ ? 1 : 0 }

sub read_first {
	my ($path) = @_;
	open my $f, '<', $path or return '';
	my $l = <$f>;
	close $f;
	return '' unless defined $l;
	$l =~ s/\s+$//;
	return $l;
}

sub player_mac { return read_first("$RUN/player.mac") }

sub xml_esc {
	my ($s) = @_;
	$s //= '';
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

sub xml_unesc {
	my ($s) = @_;
	$s //= '';
	$s =~ s/&lt;/</g;
	$s =~ s/&gt;/>/g;
	$s =~ s/&quot;/"/g;
	$s =~ s/&apos;/'/g;
	$s =~ s/&#(\d+);/chr($1)/ge;
	$s =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
	$s =~ s/&amp;/&/g;
	return $s;
}

# --- Identita' del dispositivo ----------------------------------------------------

sub friendly_name {
	my $n = conf('NOME_PLAYER', 'Sweetspot');
	$n =~ s/[[:cntrl:]]//g;
	return length $n ? $n : 'Sweetspot';
}

# UDN stabile: dipende dal player (MAC di Squeezelite), cosi' resta lo stesso
# a ogni avvio e le app non vedono dispositivi doppi.
sub device_uuid {
	my $seed = player_mac();
	$seed = read_first('/etc/machine-id') if $seed eq '';
	$seed = 'sweetspot' if $seed eq '';
	my $h = md5_hex("sweetspot-renderer-upnp:$seed");
	return sprintf '%s-%s-3%s-8%s-%s', substr($h, 0, 8), substr($h, 8, 4), substr($h, 13, 3),
		substr($h, 17, 3), substr($h, 20, 12);
}

# --- Lyrion ------------------------------------------------------------------------

sub lms {
	my ($player, @cmd) = @_;
	my %headers = ('Content-Type' => 'application/json');
	my $user = conf('LYRION_UTENTE', '');
	if (length $user) {
		require MIME::Base64;
		$headers{Authorization} = 'Basic ' . MIME::Base64::encode_base64("$user:" . conf('LYRION_PASSWORD', ''), '');
	}
	my $body = $json->encode({ id => 1, method => 'slim.request', params => [ $player, [ map { "$_" } @cmd ] ] });
	my $r = eval { $http->post("http://$LMS_HOST:$LMS_PORT/jsonrpc.js", { headers => \%headers, content => $body }) };
	return undef unless $r && $r->{success};
	my $d = eval { $json->decode($r->{content}) };
	return undef unless ref $d eq 'HASH' && ref $d->{result} eq 'HASH' && !defined $d->{error};
	return $d->{result};
}

# --- Stato della riproduzione --------------------------------------------------------
#
# Il renderer controlla il player locale di Sweetspot. "owned" e' vero quando
# la riproduzione in corso l'ha avviata una app UPnP: se qualcuno suona
# altro da Lyrion, il renderer risulta fermo, senza toccare quello che suona.

my %S = (
	uri => '', meta => '', next_uri => '', next_meta => '',
	owned => 0, loaded => 0, started => 0, index0 => -1, tracks_added => 0,
	state => 'NO_MEDIA_PRESENT', status => 'OK',
	time => 0, duration => 0, volume => 0, mute => 0, cur_uri => '', cur_meta => '',
	lyrion => 0, player => '', commands => 0, last_action => '', last_poll => 0,
);

sub hms {
	my ($s) = @_;
	$s = 0 unless defined $s && $s =~ /^\d+(?:\.\d+)?$/;
	$s = int($s);
	return sprintf '%d:%02d:%02d', int($s / 3600), int($s / 60) % 60, $s % 60;
}

sub from_hms {
	my ($t) = @_;
	return undef unless defined $t && $t =~ /^(\d+):(\d{1,2}):(\d{1,2})(?:\.\d+)?$/;
	return $1 * 3600 + $2 * 60 + $3;
}

sub title_from_meta {
	my ($meta) = @_;
	return '' unless defined $meta;
	return xml_unesc($1) if $meta =~ m{<dc:title[^>]*>(.*?)</dc:title>}s;
	return '';
}

# Rilegge Lyrion e aggiorna $S. Ritorna la lista dei servizi il cui stato
# osservabile e' cambiato (per gli eventi).
sub poll_player {
	my $before = join '|', @S{qw(state cur_uri volume mute uri)};
	my $mac = player_mac();
	$S{player} = $mac;
	if ($mac eq '') {
		$S{lyrion} = 0;
		$S{state} = 'NO_MEDIA_PRESENT';
		return;
	}
	my $st = lms($mac, 'status', '-', 1, 'tags:du');
	if (!$st) {
		# Lyrion o il player non rispondono (ancora): senza una riproduzione
		# nostra lo stato dipende solo dall'indirizzo impostato dalla app.
		$S{lyrion} = 0;
		$S{state} = $S{uri} eq '' ? 'NO_MEDIA_PRESENT' : 'STOPPED' unless $S{owned};
		return;
	}
	$S{lyrion} = 1;
	$S{last_poll} = time;
	my $mode = $st->{mode} // 'stop';
	my $item = (ref $st->{playlist_loop} eq 'ARRAY') ? $st->{playlist_loop}[0] : undef;
	my $url = $item ? ($item->{url} // '') : '';
	my $idx = $st->{playlist_cur_index} // 0;
	$S{time} = $st->{time} // 0;
	$S{duration} = ($item && $item->{duration}) ? $item->{duration} : ($st->{duration} // 0);
	my $vol = $st->{'mixer volume'};
	$S{volume} = int($vol) if defined $vol && $vol =~ /^-?\d+/ && $vol >= 0;
	$S{mute} = (defined $vol && $vol =~ /^-/) ? 1 : 0;

	if ($S{owned}) {
		# Il brano successivo (SetNextAVTransportURI) e' gia' in coda in Lyrion.
		if ($S{tracks_added} && $idx > $S{index0} && $S{next_uri} ne '') {
			@S{qw(uri meta)} = @S{qw(next_uri next_meta)};
			@S{qw(next_uri next_meta)} = ('', '');
			$S{tracks_added} = 0;
			$S{index0} = $idx;
		}
		if ($mode eq 'play') {
			$S{state} = 'PLAYING';
			$S{started} = 1;
		} elsif ($mode eq 'pause') {
			$S{state} = 'PAUSED_PLAYBACK';
			$S{started} = 1;
		} elsif (!$S{started} && time - $S{loaded} < 10) {
			# Appena avviato: Lyrion sta ancora aprendo il flusso.
			$S{state} = 'TRANSITIONING';
		} else {
			$S{state} = 'STOPPED';
			$S{owned} = 0;
			$S{started} = 0;
		}
		$S{cur_uri} = $S{uri};
		$S{cur_meta} = $S{meta};
	} else {
		$S{state} = $S{uri} eq '' ? 'NO_MEDIA_PRESENT' : 'STOPPED';
		$S{cur_uri} = $S{uri};
		$S{cur_meta} = $S{meta};
	}
	my $after = join '|', @S{qw(state cur_uri volume mute uri)};
	return $before ne $after;
}

# --- Descrizione dei servizi ----------------------------------------------------------

my $AV  = 'urn:schemas-upnp-org:service:AVTransport:1';
my $RC  = 'urn:schemas-upnp-org:service:RenderingControl:1';
my $CM  = 'urn:schemas-upnp-org:service:ConnectionManager:1';
my $DEV = 'urn:schemas-upnp-org:device:MediaRenderer:1';

my %SERVICES = (
	AVTransport      => { type => $AV, id => 'urn:upnp-org:serviceId:AVTransport' },
	RenderingControl => { type => $RC, id => 'urn:upnp-org:serviceId:RenderingControl' },
	ConnectionManager => { type => $CM, id => 'urn:upnp-org:serviceId:ConnectionManager' },
);

# Variabili di stato: nome => [tipo, eventi (si/no), valori ammessi...]
# Azioni: nome => [ [direzione, argomento, variabile], ... ]
my %SCPD = (
	AVTransport => {
		vars => [
			[ TransportState => 'string', 'no', qw(STOPPED PAUSED_PLAYBACK PLAYING TRANSITIONING NO_MEDIA_PRESENT) ],
			[ TransportStatus => 'string', 'no', qw(OK ERROR_OCCURRED) ],
			[ PlaybackStorageMedium => 'string', 'no' ],
			[ RecordStorageMedium => 'string', 'no' ],
			[ PossiblePlaybackStorageMedia => 'string', 'no' ],
			[ PossibleRecordStorageMedia => 'string', 'no' ],
			[ CurrentPlayMode => 'string', 'no', qw(NORMAL) ],
			[ TransportPlaySpeed => 'string', 'no', qw(1) ],
			[ RecordMediumWriteStatus => 'string', 'no' ],
			[ CurrentRecordQualityMode => 'string', 'no' ],
			[ PossibleRecordQualityModes => 'string', 'no' ],
			[ NumberOfTracks => 'ui4', 'no' ],
			[ CurrentTrack => 'ui4', 'no' ],
			[ CurrentTrackDuration => 'string', 'no' ],
			[ CurrentMediaDuration => 'string', 'no' ],
			[ CurrentTrackMetaData => 'string', 'no' ],
			[ CurrentTrackURI => 'string', 'no' ],
			[ AVTransportURI => 'string', 'no' ],
			[ AVTransportURIMetaData => 'string', 'no' ],
			[ NextAVTransportURI => 'string', 'no' ],
			[ NextAVTransportURIMetaData => 'string', 'no' ],
			[ RelativeTimePosition => 'string', 'no' ],
			[ AbsoluteTimePosition => 'string', 'no' ],
			[ RelativeCounterPosition => 'i4', 'no' ],
			[ AbsoluteCounterPosition => 'ui4', 'no' ],
			[ CurrentTransportActions => 'string', 'no' ],
			[ LastChange => 'string', 'yes' ],
			[ A_ARG_TYPE_SeekMode => 'string', 'no', qw(REL_TIME TRACK_NR) ],
			[ A_ARG_TYPE_SeekTarget => 'string', 'no' ],
			[ A_ARG_TYPE_InstanceID => 'ui4', 'no' ],
		],
		actions => [
			[ SetAVTransportURI => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => CurrentURI => 'AVTransportURI' ],
				[ in => CurrentURIMetaData => 'AVTransportURIMetaData' ] ],
			[ SetNextAVTransportURI => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => NextURI => 'NextAVTransportURI' ],
				[ in => NextURIMetaData => 'NextAVTransportURIMetaData' ] ],
			[ GetMediaInfo => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => NrTracks => 'NumberOfTracks' ],
				[ out => MediaDuration => 'CurrentMediaDuration' ], [ out => CurrentURI => 'AVTransportURI' ],
				[ out => CurrentURIMetaData => 'AVTransportURIMetaData' ], [ out => NextURI => 'NextAVTransportURI' ],
				[ out => NextURIMetaData => 'NextAVTransportURIMetaData' ], [ out => PlayMedium => 'PlaybackStorageMedium' ],
				[ out => RecordMedium => 'RecordStorageMedium' ], [ out => WriteStatus => 'RecordMediumWriteStatus' ] ],
			[ GetTransportInfo => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => CurrentTransportState => 'TransportState' ],
				[ out => CurrentTransportStatus => 'TransportStatus' ], [ out => CurrentSpeed => 'TransportPlaySpeed' ] ],
			[ GetPositionInfo => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => Track => 'CurrentTrack' ],
				[ out => TrackDuration => 'CurrentTrackDuration' ], [ out => TrackMetaData => 'CurrentTrackMetaData' ],
				[ out => TrackURI => 'CurrentTrackURI' ], [ out => RelTime => 'RelativeTimePosition' ],
				[ out => AbsTime => 'AbsoluteTimePosition' ], [ out => RelCount => 'RelativeCounterPosition' ],
				[ out => AbsCount => 'AbsoluteCounterPosition' ] ],
			[ GetDeviceCapabilities => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => PlayMedia => 'PossiblePlaybackStorageMedia' ],
				[ out => RecMedia => 'PossibleRecordStorageMedia' ], [ out => RecQualityModes => 'PossibleRecordQualityModes' ] ],
			[ GetTransportSettings => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => PlayMode => 'CurrentPlayMode' ],
				[ out => RecQualityMode => 'CurrentRecordQualityMode' ] ],
			[ Stop => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ] ],
			[ Play => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Speed => 'TransportPlaySpeed' ] ],
			[ Pause => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ] ],
			[ Seek => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Unit => 'A_ARG_TYPE_SeekMode' ],
				[ in => Target => 'A_ARG_TYPE_SeekTarget' ] ],
			[ Next => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ] ],
			[ Previous => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ] ],
			[ SetPlayMode => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => NewPlayMode => 'CurrentPlayMode' ] ],
			[ GetCurrentTransportActions => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => Actions => 'CurrentTransportActions' ] ],
		],
	},
	RenderingControl => {
		vars => [
			[ PresetNameList => 'string', 'no' ],
			[ LastChange => 'string', 'yes' ],
			[ Mute => 'boolean', 'no' ],
			[ Volume => 'ui2', 'no', 'range:0:100:1' ],
			[ A_ARG_TYPE_Channel => 'string', 'no', qw(Master) ],
			[ A_ARG_TYPE_InstanceID => 'ui4', 'no' ],
			[ A_ARG_TYPE_PresetName => 'string', 'no', qw(FactoryDefaults) ],
		],
		actions => [
			[ ListPresets => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ out => CurrentPresetNameList => 'PresetNameList' ] ],
			[ SelectPreset => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => PresetName => 'A_ARG_TYPE_PresetName' ] ],
			[ GetMute => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Channel => 'A_ARG_TYPE_Channel' ],
				[ out => CurrentMute => 'Mute' ] ],
			[ SetMute => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Channel => 'A_ARG_TYPE_Channel' ],
				[ in => DesiredMute => 'Mute' ] ],
			[ GetVolume => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Channel => 'A_ARG_TYPE_Channel' ],
				[ out => CurrentVolume => 'Volume' ] ],
			[ SetVolume => [ in => InstanceID => 'A_ARG_TYPE_InstanceID' ], [ in => Channel => 'A_ARG_TYPE_Channel' ],
				[ in => DesiredVolume => 'Volume' ] ],
		],
	},
	ConnectionManager => {
		vars => [
			[ SourceProtocolInfo => 'string', 'yes' ],
			[ SinkProtocolInfo => 'string', 'yes' ],
			[ CurrentConnectionIDs => 'string', 'yes' ],
			[ A_ARG_TYPE_ConnectionStatus => 'string', 'no', qw(OK ContentFormatMismatch InsufficientBandwidth UnreliableChannel Unknown) ],
			[ A_ARG_TYPE_ConnectionManager => 'string', 'no' ],
			[ A_ARG_TYPE_Direction => 'string', 'no', qw(Input Output) ],
			[ A_ARG_TYPE_ProtocolInfo => 'string', 'no' ],
			[ A_ARG_TYPE_ConnectionID => 'i4', 'no' ],
			[ A_ARG_TYPE_AVTransportID => 'i4', 'no' ],
			[ A_ARG_TYPE_RcsID => 'i4', 'no' ],
		],
		actions => [
			[ GetProtocolInfo => [ out => Source => 'SourceProtocolInfo' ], [ out => Sink => 'SinkProtocolInfo' ] ],
			[ GetCurrentConnectionIDs => [ out => ConnectionIDs => 'CurrentConnectionIDs' ] ],
			[ GetCurrentConnectionInfo => [ in => ConnectionID => 'A_ARG_TYPE_ConnectionID' ], [ out => RcsID => 'A_ARG_TYPE_RcsID' ],
				[ out => AVTransportID => 'A_ARG_TYPE_AVTransportID' ], [ out => ProtocolInfo => 'A_ARG_TYPE_ProtocolInfo' ],
				[ out => PeerConnectionManager => 'A_ARG_TYPE_ConnectionManager' ], [ out => PeerConnectionID => 'A_ARG_TYPE_ConnectionID' ],
				[ out => Direction => 'A_ARG_TYPE_Direction' ], [ out => Status => 'A_ARG_TYPE_ConnectionStatus' ] ],
		],
	},
);

# Formati che Lyrion apre da un indirizzo HTTP e manda al player.
my @FORMATS = (
	'audio/flac', 'audio/x-flac', 'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave',
	'audio/aiff', 'audio/x-aiff', 'audio/mpeg', 'audio/mp3', 'audio/mp4', 'audio/x-m4a', 'audio/aac',
	'audio/ogg', 'audio/x-ogg', 'audio/opus',
	'audio/L16;rate=44100;channels=2', 'audio/L16;rate=48000;channels=2', 'audio/L16;rate=96000;channels=2',
	'audio/L24;rate=96000;channels=2', 'audio/L24;rate=192000;channels=2',
);

sub sink_info { return join ',', map { "http-get:*:$_:*" } @FORMATS }

sub scpd_xml {
	my ($name) = @_;
	my $d = $SCPD{$name};
	my $x = qq{<?xml version="1.0" encoding="utf-8"?>\n<scpd xmlns="urn:schemas-upnp-org:service-1-0">\n<specVersion><major>1</major><minor>0</minor></specVersion>\n<actionList>\n};
	for my $a (@{ $d->{actions} }) {
		my ($an, @args) = @$a;
		$x .= "<action><name>$an</name>";
		if (@args) {
			$x .= '<argumentList>';
			for my $g (@args) {
				my ($dir, $arg, $var) = @$g;
				$x .= "<argument><name>$arg</name><direction>$dir</direction><relatedStateVariable>$var</relatedStateVariable></argument>";
			}
			$x .= '</argumentList>';
		}
		$x .= "</action>\n";
	}
	$x .= "</actionList>\n<serviceStateTable>\n";
	for my $v (@{ $d->{vars} }) {
		my ($vn, $type, $ev, @allowed) = @$v;
		$x .= qq{<stateVariable sendEvents="$ev"><name>$vn</name><dataType>$type</dataType>};
		if (@allowed && $allowed[0] =~ /^range:(\d+):(\d+):(\d+)$/) {
			$x .= "<allowedValueRange><minimum>$1</minimum><maximum>$2</maximum><step>$3</step></allowedValueRange>";
		} elsif (@allowed) {
			$x .= '<allowedValueList>' . join('', map { "<allowedValue>$_</allowedValue>" } @allowed) . '</allowedValueList>';
		}
		$x .= "</stateVariable>\n";
	}
	return $x . "</serviceStateTable>\n</scpd>\n";
}

sub device_xml {
	my ($base) = @_;
	my $udn = 'uuid:' . device_uuid();
	my $x = qq{<?xml version="1.0" encoding="utf-8"?>\n<root xmlns="urn:schemas-upnp-org:device-1-0">\n}
		. qq{<specVersion><major>1</major><minor>0</minor></specVersion>\n}
		. "<device>\n<deviceType>$DEV</deviceType>\n"
		. '<friendlyName>' . xml_esc(friendly_name()) . "</friendlyName>\n"
		. "<manufacturer>Sweetspot</manufacturer>\n<manufacturerURL>https://github.com/Markg981/SweetSpot</manufacturerURL>\n"
		. "<modelDescription>Sweetspot, renderer UPnP/DLNA tramite Lyrion</modelDescription>\n"
		. "<modelName>Sweetspot</modelName>\n<modelNumber>1</modelNumber>\n"
		. "<UDN>$udn</UDN>\n<serviceList>\n";
	for my $n (qw(AVTransport RenderingControl ConnectionManager)) {
		$x .= "<service><serviceType>$SERVICES{$n}{type}</serviceType><serviceId>$SERVICES{$n}{id}</serviceId>"
			. "<SCPDURL>/scpd/$n.xml</SCPDURL><controlURL>/ctl/$n</controlURL><eventSubURL>/evt/$n</eventSubURL></service>\n";
	}
	return $x . "</serviceList>\n</device>\n</root>\n";
}

# --- Azioni SOAP -------------------------------------------------------------------------

# Ritorna ([nome => valore, ...]) per la risposta, oppure (undef, codice, testo) per l'errore.
sub action {
	my ($svc, $name, $in) = @_;
	$S{commands}++;
	$S{last_action} = $name;
	my $mac = player_mac();
	my $lms_ok = sub { return $mac ne '' && defined lms($mac, @_) };

	if ($svc eq 'AVTransport') {
		if ($name eq 'SetAVTransportURI') {
			my $uri = xml_unesc($in->{CurrentURI} // '');
			return (undef, 714, 'Illegal MIME-type') if $uri !~ m{^https?://}i && $uri ne '';
			if ($S{owned} && $mac ne '') {
				lms($mac, 'stop');
				$S{owned} = 0;
			}
			@S{qw(uri meta next_uri next_meta tracks_added loaded started)} = ($uri, xml_unesc($in->{CurrentURIMetaData}), '', '', 0, 0, 0);
			$S{state} = $uri eq '' ? 'NO_MEDIA_PRESENT' : 'STOPPED';
			return [];
		}
		if ($name eq 'SetNextAVTransportURI') {
			my $uri = xml_unesc($in->{NextURI} // '');
			return (undef, 714, 'Illegal MIME-type') if $uri ne '' && $uri !~ m{^https?://}i;
			@S{qw(next_uri next_meta)} = ($uri, xml_unesc($in->{NextURIMetaData}));
			if ($S{owned} && $uri ne '' && $mac ne '') {
				my $title = title_from_meta($S{next_meta});
				$S{tracks_added} = 1 if lms($mac, 'playlist', 'add', $uri, length $title ? $title : ());
			}
			return [];
		}
		if ($name eq 'Play') {
			return (undef, 701, 'Transition not available') if $mac eq '';
			if ($S{owned} && $S{state} eq 'PAUSED_PLAYBACK') {
				$lms_ok->('pause', 0) or return (undef, 501, 'Action Failed');
			} elsif ($S{owned} && $S{state} eq 'PLAYING') {
				# gia' in riproduzione
			} else {
				return (undef, 701, 'No contents') if $S{uri} eq '';
				my $title = title_from_meta($S{meta});
				$lms_ok->('playlist', 'repeat', 0) or return (undef, 501, 'Action Failed');
				lms($mac, 'playlist', 'shuffle', 0);
				$lms_ok->('playlist', 'play', $S{uri}, length $title ? $title : $S{uri}) or return (undef, 501, 'Action Failed');
				$S{owned} = 1;
				$S{started} = 0;
				$S{loaded} = time;
				$S{state} = 'TRANSITIONING';
				my $st = lms($mac, 'status', '-', 1);
				$S{index0} = $st ? ($st->{playlist_cur_index} // 0) : 0;
				$S{tracks_added} = 0;
				if ($S{next_uri} ne '') {
					my $nt = title_from_meta($S{next_meta});
					$S{tracks_added} = 1 if lms($mac, 'playlist', 'add', $S{next_uri}, length $nt ? $nt : ());
				}
			}
			return [];
		}
		if ($name eq 'Pause') {
			return (undef, 701, 'Transition not available') unless $S{owned};
			$lms_ok->('pause', 1) or return (undef, 501, 'Action Failed');
			return [];
		}
		if ($name eq 'Stop') {
			if ($S{owned}) {
				$lms_ok->('stop') or return (undef, 501, 'Action Failed');
				$S{owned} = 0;
				$S{started} = 0;
			}
			$S{state} = $S{uri} eq '' ? 'NO_MEDIA_PRESENT' : 'STOPPED';
			return [];
		}
		if ($name eq 'Seek') {
			return (undef, 701, 'Transition not available') unless $S{owned};
			my $unit = $in->{Unit} // '';
			if ($unit eq 'REL_TIME' || $unit eq 'ABS_TIME') {
				my $t = from_hms($in->{Target});
				return (undef, 711, 'Illegal seek target') unless defined $t;
				$lms_ok->('time', $t) or return (undef, 501, 'Action Failed');
				return [];
			}
			return (undef, 710, 'Seek mode not supported') unless $unit eq 'TRACK_NR';
			# Le tracce note sono la corrente (1) e, se gia' in coda, la successiva (2).
			my $t = $in->{Target} // '';
			return (undef, 711, 'Illegal seek target') unless $t =~ /^\d+$/;
			if ($t == 1) {
				$lms_ok->('time', 0) or return (undef, 501, 'Action Failed');
			} elsif ($t == 2 && $S{tracks_added}) {
				$lms_ok->('playlist', 'index', '+1') or return (undef, 501, 'Action Failed');
			} else {
				return (undef, 711, 'Illegal seek target');
			}
			return [];
		}
		if ($name eq 'Next') {
			return (undef, 701, 'Transition not available') unless $S{owned} && $S{next_uri} ne '';
			$lms_ok->('playlist', 'index', '+1') or return (undef, 501, 'Action Failed');
			return [];
		}
		if ($name eq 'Previous') {
			$lms_ok->('time', 0) if $S{owned};
			return [];
		}
		if ($name eq 'SetPlayMode') {
			return (undef, 712, 'Play mode not supported') unless ($in->{NewPlayMode} // '') eq 'NORMAL';
			return [];
		}
		poll_player();
		if ($name eq 'GetTransportInfo') {
			return [ CurrentTransportState => $S{state}, CurrentTransportStatus => $S{status}, CurrentSpeed => '1' ];
		}
		if ($name eq 'GetPositionInfo') {
			my $own = $S{owned} && $S{started};
			my $dur = $own ? hms($S{duration}) : '0:00:00';
			my $pos = $own ? hms($S{time}) : '0:00:00';
			return [ Track => ($S{uri} ne '' ? 1 : 0), TrackDuration => $dur, TrackMetaData => $S{meta}, TrackURI => $S{uri},
				RelTime => $pos, AbsTime => $pos, RelCount => 2147483647, AbsCount => 2147483647 ];
		}
		if ($name eq 'GetMediaInfo') {
			return [ NrTracks => ($S{uri} ne '' ? 1 : 0), MediaDuration => hms($S{owned} ? $S{duration} : 0),
				CurrentURI => $S{uri}, CurrentURIMetaData => $S{meta}, NextURI => $S{next_uri},
				NextURIMetaData => $S{next_meta}, PlayMedium => 'NETWORK', RecordMedium => 'NOT_IMPLEMENTED',
				WriteStatus => 'NOT_IMPLEMENTED' ];
		}
		if ($name eq 'GetDeviceCapabilities') {
			return [ PlayMedia => 'NETWORK', RecMedia => 'NOT_IMPLEMENTED', RecQualityModes => 'NOT_IMPLEMENTED' ];
		}
		if ($name eq 'GetTransportSettings') {
			return [ PlayMode => 'NORMAL', RecQualityMode => 'NOT_IMPLEMENTED' ];
		}
		if ($name eq 'GetCurrentTransportActions') {
			return [ Actions => ($S{owned} ? 'Play,Pause,Stop,Seek,Next' : 'Play,Stop') ];
		}
		return (undef, 401, 'Invalid Action');
	}

	if ($svc eq 'RenderingControl') {
		if ($name eq 'ListPresets') { return [ CurrentPresetNameList => 'FactoryDefaults' ] }
		if ($name eq 'SelectPreset') { return [] }
		if ($name eq 'GetVolume') { poll_player(); return [ CurrentVolume => $S{volume} ] }
		if ($name eq 'GetMute') { poll_player(); return [ CurrentMute => $S{mute} ] }
		if ($name eq 'SetVolume') {
			my $v = $in->{DesiredVolume};
			return (undef, 402, 'Invalid Args') unless defined $v && $v =~ /^\d+$/ && $v <= 100;
			$lms_ok->('mixer', 'volume', $v) or return (undef, 501, 'Action Failed');
			$S{volume} = $v;
			return [];
		}
		if ($name eq 'SetMute') {
			my $m = $in->{DesiredMute};
			return (undef, 402, 'Invalid Args') unless defined $m && $m =~ /^(0|1|true|false)$/i;
			$lms_ok->('mixer', 'muting', ($m =~ /^(1|true)$/i ? 1 : 0)) or return (undef, 501, 'Action Failed');
			$S{mute} = ($m =~ /^(1|true)$/i) ? 1 : 0;
			return [];
		}
		return (undef, 401, 'Invalid Action');
	}

	if ($svc eq 'ConnectionManager') {
		if ($name eq 'GetProtocolInfo') { return [ Source => '', Sink => sink_info() ] }
		if ($name eq 'GetCurrentConnectionIDs') { return [ ConnectionIDs => '0' ] }
		if ($name eq 'GetCurrentConnectionInfo') {
			return [ RcsID => 0, AVTransportID => 0, ProtocolInfo => '', PeerConnectionManager => '', PeerConnectionID => -1,
				Direction => 'Input', Status => 'OK' ];
		}
		return (undef, 401, 'Invalid Action');
	}
	return (undef, 401, 'Invalid Action');
}

sub soap_response {
	my ($svc, $name, $vals) = @_;
	my $x = qq{<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" }
		. qq{s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${name}Response xmlns:u="$SERVICES{$svc}{type}">};
	for (my $i = 0; $i < @$vals; $i += 2) {
		$x .= "<$vals->[$i]>" . xml_esc($vals->[$i + 1]) . "</$vals->[$i]>";
	}
	return $x . "</u:${name}Response></s:Body></s:Envelope>";
}

sub soap_fault {
	my ($code, $text) = @_;
	return qq{<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" }
		. qq{s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode>}
		. qq{<faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">}
		. '<errorCode>' . $code . '</errorCode><errorDescription>' . xml_esc($text) . '</errorDescription>'
		. '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';
}

# --- Eventi (GENA) -------------------------------------------------------------------------

my %SUBS;    # sid => { svc, urls[], seq, expires }

sub last_change_xml {
	my ($svc) = @_;
	if ($svc eq 'AVTransport') {
		my @p = (
			TransportState => $S{state}, TransportStatus => $S{status}, AVTransportURI => $S{uri},
			AVTransportURIMetaData => $S{meta}, CurrentTrackURI => $S{cur_uri}, CurrentTrackMetaData => $S{cur_meta},
			CurrentTransportActions => ($S{owned} ? 'Play,Pause,Stop,Seek,Next' : 'Play,Stop'),
			NumberOfTracks => ($S{uri} ne '' ? 1 : 0), CurrentTrack => ($S{uri} ne '' ? 1 : 0),
		);
		my $x = '<Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">';
		$x .= '<InstanceID val="0">';
		for (my $i = 0; $i < @p; $i += 2) { $x .= qq{<$p[$i] val="} . xml_esc($p[$i + 1]) . '"/>' }
		return $x . '</InstanceID></Event>';
	}
	return '<Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/"><InstanceID val="0">'
		. qq{<Volume channel="Master" val="$S{volume}"/><Mute channel="Master" val="$S{mute}"/>}
		. '</InstanceID></Event>';
}

sub event_body {
	my ($svc) = @_;
	my @pairs;
	if ($svc eq 'ConnectionManager') {
		@pairs = (SourceProtocolInfo => '', SinkProtocolInfo => sink_info(), CurrentConnectionIDs => '0');
	} else {
		@pairs = (LastChange => last_change_xml($svc));
	}
	my $x = qq{<?xml version="1.0" encoding="utf-8"?>\n<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">};
	for (my $i = 0; $i < @pairs; $i += 2) {
		$x .= "<e:property><$pairs[$i]>" . xml_esc($pairs[$i + 1]) . "</$pairs[$i]></e:property>";
	}
	return $x . '</e:propertyset>';
}

my %CHILD;   # pid => sid, invii NOTIFY in corso

sub cb_host {
	my ($url) = @_;
	return lc(($url =~ m{^https?://(?:[^/@]*@)?(\[[^\]]+\]|[^/:?#]+)}i)[0] // '');
}

# L'invio non blocca mai il ciclo (SOAP e SSDP restano reattivi): lo fa un
# processo figlio con tempo limite. Per ogni abbonato c'e' al piu' un invio in
# corso; se nel frattempo lo stato cambia, a invio concluso ne parte uno solo
# con lo stato piu' recente (LastChange e' uno stato, non un registro).
sub send_event {
	my ($sid) = @_;
	my $sub = $SUBS{$sid} or return;
	if ($sub->{pid} || keys(%CHILD) >= $MAX_NOTIFY) {
		$sub->{dirty} = 1;
		return;
	}
	$sub->{dirty} = 0;
	my $body = event_body($sub->{svc});
	my $seq = $sub->{seq}++;
	my @urls = @{ $sub->{urls} };
	my $pid = fork();
	if (!defined $pid) {
		$sub->{fails}++;
		return;
	}
	if (!$pid) {
		$SIG{TERM} = 'DEFAULT';
		my $ok = 0;
		for my $url (@urls) {
			my $r = eval {
				HTTP::Tiny->new(timeout => 2, agent => 'Sweetspot-renderer/1')->request('NOTIFY', $url, {
					headers => { NT => 'upnp:event', NTS => 'upnp:propchange', SID => $sid, SEQ => $seq,
						'Content-Type' => 'text/xml; charset="utf-8"' },
					content => $body,
				});
			};
			if ($r && $r->{status} && $r->{status} < 400) { $ok = 1; last }
		}
		POSIX::_exit($ok ? 0 : 1);
	}
	$sub->{pid} = $pid;
	$CHILD{$pid} = $sid;
}

sub reap_events {
	for my $pid (keys %CHILD) {
		my $r = waitpid($pid, POSIX::WNOHANG());
		next if $r == 0;
		my $sid = delete $CHILD{$pid};
		my $sub = $SUBS{$sid} or next;
		$sub->{pid} = 0;
		if ($r > 0 && $? == 0) {
			$sub->{fails} = 0;
		} elsif (++$sub->{fails} >= $MAX_FAILS) {
			logm("abbonato $sid rimosso: callback non raggiungibile");
			delete $SUBS{$sid};
			next;
		}
		send_event($sid) if $sub->{dirty};
	}
	# Invii rimasti in attesa del limite di processi.
	for my $sid (keys %SUBS) {
		send_event($sid) if $SUBS{$sid}{dirty} && !$SUBS{$sid}{pid};
	}
}

sub expire_subs {
	my $now = time;
	for my $sid (keys %SUBS) { delete $SUBS{$sid} if $SUBS{$sid}{expires} < $now }
}

sub notify_services {
	my (@svcs) = @_;
	for my $sid (keys %SUBS) {
		send_event($sid) if grep { $_ eq $SUBS{$sid}{svc} } @svcs;
	}
}

# --- SSDP ---------------------------------------------------------------------------------------

sub local_addrs {
	if (defined $ENV{SWEETSPOT_RENDERER_ADDR} && length $ENV{SWEETSPOT_RENDERER_ADDR}) {
		return grep { /^\d+\.\d+\.\d+\.\d+$/ && $_ ne $AP_IP } split /,/, $ENV{SWEETSPOT_RENDERER_ADDR};
	}
	my @ips;
	if (open my $p, '-|', 'ip', '-4', '-o', 'addr', 'show', 'scope', 'global') {
		while (my $l = <$p>) { push @ips, $1 if $l =~ /\binet (\d+\.\d+\.\d+\.\d+)/ && $1 ne $AP_IP }
		close $p;
	}
	return @ips;
}

sub nt_list {
	my $udn = 'uuid:' . device_uuid();
	return (
		[ 'upnp:rootdevice', "$udn\::upnp:rootdevice" ],
		[ $udn, $udn ],
		[ $DEV, "$udn\::$DEV" ],
		(map { [ $SERVICES{$_}{type}, "$udn\::$SERVICES{$_}{type}" ] } qw(AVTransport RenderingControl ConnectionManager)),
	);
}

# Indirizzo locale con cui si raggiunge $peer (quello da mettere in LOCATION).
sub addr_for_peer {
	my ($peer) = @_;
	my $s = IO::Socket::INET->new(Proto => 'udp', PeerAddr => $peer, PeerPort => 9) or return undef;
	my $a = $s->sockhost;
	close $s;
	return $a;
}

sub ssdp_msg {
	my ($kind, $ip, $nt, $usn) = @_;
	my $date = strftime('%a, %d %b %Y %H:%M:%S GMT', gmtime);
	my $loc = "http://$ip:$HTTP_PORT/desc.xml";
	return "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=$MAX_AGE\r\nDATE: $date\r\nEXT:\r\nLOCATION: $loc\r\n"
		. "SERVER: $SERVER_ID\r\nST: $nt\r\nUSN: $usn\r\n\r\n" if $kind eq 'resp';
	my $nts = $kind eq 'alive' ? 'ssdp:alive' : 'ssdp:byebye';
	my $m = "NOTIFY * HTTP/1.1\r\nHOST: $SSDP_ADDR:1900\r\nNT: $nt\r\nNTS: $nts\r\nUSN: $usn\r\n";
	$m .= "CACHE-CONTROL: max-age=$MAX_AGE\r\nLOCATION: $loc\r\nSERVER: $SERVER_ID\r\n" if $kind eq 'alive';
	return $m . "\r\n";
}

sub announce {
	my ($kind) = @_;
	for my $ip (local_addrs()) {
		my $s = IO::Socket::INET->new(Proto => 'udp', LocalAddr => $ip) or next;
		setsockopt($s, IPPROTO_IP, IP_MULTICAST_IF, inet_aton($ip));
		setsockopt($s, IPPROTO_IP, IP_MULTICAST_TTL, pack('C', 2));
		my $dest = pack_sockaddr_in(1900, inet_aton($SSDP_ADDR));
		for my $e (nt_list()) {
			send($s, ssdp_msg($kind, $ip, $e->[0], $e->[1]), 0, $dest);
		}
		close $s;
	}
}

my @pending_resp;    # [ due, ip, port, nt, usn ]
# Le risposte vanno alla porta sorgente della M-SEARCH, che si falsifica: coda e
# frequenza hanno un tetto, così non si amplifica né si riempie la memoria.
my $MAX_PENDING = 64;
my $SSDP_RATE_MAX = 8;       # M-SEARCH accettate per IP in ogni finestra
my $SSDP_RATE_WIN = 10;      # secondi
my %ssdp_rate;               # ip => [ inizio finestra, conteggio ]

sub ssdp_rate_ok {
	my ($ip) = @_;
	my $now = time;
	%ssdp_rate = () if keys %ssdp_rate > 1024;    # tetto anche alla tabella
	my $r = $ssdp_rate{$ip};
	if (!$r || $now - $r->[0] >= $SSDP_RATE_WIN) { $ssdp_rate{$ip} = [ $now, 1 ]; return 1 }
	return ++$r->[1] <= $SSDP_RATE_MAX;
}

sub handle_ssdp {
	my ($data, $from) = @_;
	return unless $data =~ /^M-SEARCH \* HTTP\/1\.1/i;
	my ($man) = $data =~ /^MAN:\s*"?([^"\r\n]+)"?\s*$/mi;
	return unless defined $man && lc($man) eq 'ssdp:discover';
	my ($st) = $data =~ /^ST:\s*(\S+)\s*$/mi;
	return unless defined $st;
	my ($mx) = $data =~ /^MX:\s*(\d+)/mi;
	$mx = 1 if !defined $mx || $mx < 1;
	$mx = 5 if $mx > 5;
	my ($port, $addr) = unpack_sockaddr_in($from);
	my $ip = inet_ntoa($addr);
	return if (addr_for_peer($ip) // '') eq $AP_IP;    # arriva dall'hotspot di configurazione
	return unless ssdp_rate_ok($ip);
	for my $e (nt_list()) {
		next unless $st eq 'ssdp:all' || lc($st) eq lc($e->[0]);
		last if @pending_resp >= $MAX_PENDING;
		push @pending_resp, [ time + rand($mx * 0.4), $ip, $port, @$e ];
	}
}

sub flush_ssdp {
	my ($sock) = @_;
	my $now = time;
	my @keep;
	for my $r (@pending_resp) {
		if ($r->[0] > $now) { push @keep, $r; next }
		my $loc = addr_for_peer($r->[1]) // '127.0.0.1';
		send($sock, ssdp_msg('resp', $loc, $r->[3], $r->[4]), 0, pack_sockaddr_in($r->[2], inet_aton($r->[1])));
	}
	@pending_resp = @keep;
}

sub join_multicast {
	my ($sock) = @_;
	my $n = 0;
	for my $ip (local_addrs(), '0.0.0.0') {
		my $mreq = inet_aton($SSDP_ADDR) . inet_aton($ip);
		$n++ if setsockopt($sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, $mreq);
		last if $ip eq '0.0.0.0' && $n;
	}
	return $n;
}

# --- HTTP ------------------------------------------------------------------------------------------

sub http_reply {
	my ($c, $status, $ctype, $body, %extra) = @_;
	my %text = (200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found', 405 => 'Method Not Allowed',
		412 => 'Precondition Failed', 413 => 'Payload Too Large', 500 => 'Internal Server Error', 503 => 'Service Unavailable');
	my $head_only = delete $extra{HEAD};
	my $h = "HTTP/1.1 $status " . ($text{$status} // 'OK') . "\r\n";
	$h .= "Content-Type: $ctype\r\n" if defined $ctype;
	$h .= 'Content-Length: ' . length($body // '') . "\r\n";
	$h .= "Server: $SERVER_ID\r\nEXT:\r\nConnection: close\r\n";
	$h .= "$_: $extra{$_}\r\n" for sort keys %extra;
	print $c $h . "\r\n" . ($head_only ? '' : ($body // ''));
}

my $MAX_BODY = 32768;    # una azione SOAP è di poche centinaia di byte

sub read_request {
	my ($c) = @_;
	my $sel = IO::Select->new($c);
	my $buf = '';
	my $deadline = time + 3;
	my ($head, $len);
	while (time < $deadline) {
		last unless $sel->can_read(0.5);
		my $n = sysread($c, my $chunk, 8192);
		last unless $n;
		$buf .= $chunk;
		return (undef, undef, 413) if !defined $head && length($buf) > 16384;
		if (!defined $head && $buf =~ /\r?\n\r?\n/) {
			$head = substr($buf, 0, $+[0]);
			$buf = substr($buf, $+[0]);
			($len) = $head =~ /^Content-Length:\s*(\d+)/mi;
			$len //= 0;
			return (undef, undef, 413) if $len > $MAX_BODY;
		}
		last if defined $head && length($buf) >= $len;
	}
	return undef unless defined $head;
	return ($head, $buf);
}

# Argomenti di una azione SOAP, in tempo lineare: le espressioni con (.*) e
# backtracking su un corpo grande bloccavano il ciclo per decine di secondi.
sub soap_args {
	my ($body, $name) = @_;
	my %in;
	return %in unless $body =~ m{<(?:\w+:)?\Q$name\E\b[^<>]*>}g;
	my $pos = pos($body);
	my $end = length $body;
	for (my $i = rindex($body, '</'); $i >= $pos; $i = $i > 0 ? rindex($body, '</', $i - 1) : -1) {
		if (substr($body, $i, 80) =~ m{^</(?:\w+:)?\Q$name\E>}) { $end = $i; last }
	}
	my $args = substr($body, $pos, $end - $pos);
	while ($args =~ m{\G.*?<(\w+)((?:\s[^<>]*)?)(/?)>}sgc) {
		my ($tag, $selfclose) = ($1, $3);
		if ($selfclose) { $in{$tag} = ''; next }
		my $close = index($args, "</$tag>", pos($args));
		next if $close < 0;
		$in{$tag} = substr($args, pos($args), $close - pos($args));
		pos($args) = $close + length($tag) + 3;
	}
	return %in;
}

sub handle_http {
	my ($c) = @_;
	my ($head, $body, $err) = read_request($c);
	return http_reply($c, 413, 'text/plain', "corpo troppo grande
") if ($err // 0) == 413;
	return http_reply($c, 400, 'text/plain', "richiesta non valida\n") unless defined $head;
	my ($method, $path) = $head =~ m{^(\w+)\s+(\S+)\s+HTTP/1\.[01]};
	return http_reply($c, 400, 'text/plain', "richiesta non valida\n") unless defined $method;
	$path =~ s/\?.*$//;
	my ($host) = $head =~ /^Host:\s*(\S+)/mi;

	if ($method eq 'GET' || $method eq 'HEAD') {
		my %ex = $method eq 'HEAD' ? (HEAD => 1) : ();
		if ($path eq '/desc.xml' || $path eq '/') {
			return http_reply($c, 200, 'text/xml; charset="utf-8"', device_xml(), %ex);
		}
		if ($path =~ m{^/scpd/(AVTransport|RenderingControl|ConnectionManager)\.xml$}) {
			return http_reply($c, 200, 'text/xml; charset="utf-8"', scpd_xml($1), %ex);
		}
		return http_reply($c, 404, 'text/plain', "non trovato\n", %ex);
	}

	if ($method eq 'POST' && $path =~ m{^/ctl/(AVTransport|RenderingControl|ConnectionManager)$}) {
		my $svc = $1;
		my ($sa) = $head =~ /^SOAPACTION:\s*"?([^"\r\n]+)"?\s*$/mi;
		my ($stype, $name) = defined $sa ? $sa =~ /^(.*)#(\w+)\s*$/ : ();
		return http_reply($c, 400, 'text/plain', "SOAPACTION mancante\n") unless defined $name;
		return http_reply($c, 500, 'text/xml; charset="utf-8"', soap_fault(401, 'Invalid Action'))
			unless $stype eq $SERVICES{$svc}{type};
		my %in;
		%in = soap_args($body, $name);
		my ($vals, $code, $text) = action($svc, $name, \%in);
		if (!defined $vals) {
			logm("$svc.$name: errore $code ($text)");
			return http_reply($c, 500, 'text/xml; charset="utf-8"', soap_fault($code, $text));
		}
		http_reply($c, 200, 'text/xml; charset="utf-8"', soap_response($svc, $name, $vals));
		close $c;
		# Dopo una azione che cambia lo stato, gli abbonati lo sanno subito.
		if ($name =~ /^(SetAVTransportURI|SetNextAVTransportURI|Play|Pause|Stop|Seek|Next|Previous)$/) {
			poll_player();
			notify_services('AVTransport');
		} elsif ($name =~ /^Set(Volume|Mute)$/) {
			notify_services('RenderingControl');
		}
		return;
	}

	if ($path =~ m{^/evt/(AVTransport|RenderingControl|ConnectionManager)$}) {
		my $svc = $1;
		if ($method eq 'SUBSCRIBE') {
			my ($sid) = $head =~ /^SID:\s*(\S+)/mi;
			my ($cb) = $head =~ /^CALLBACK:\s*(.+?)\s*$/mi;
			my ($to) = $head =~ /^TIMEOUT:\s*Second-(\d+)/mi;
			$to = 1800 if !$to || $to > 3600;
			if (defined $sid) {
				return http_reply($c, 412, 'text/plain', "SID sconosciuto\n") unless $SUBS{$sid};
				$SUBS{$sid}{expires} = time + $to;
				return http_reply($c, 200, undef, '', SID => $sid, TIMEOUT => "Second-$to");
			}
			my @urls = defined $cb ? ($cb =~ /<(http:\/\/[^>]+)>/gi) : ();
			return http_reply($c, 412, 'text/plain', "CALLBACK mancante\n") unless @urls;
			return http_reply($c, 412, 'text/plain', "CALLBACK troppo lungo\n") if grep { length $_ > $MAX_CB_LEN } @urls;
			splice @urls, $MAX_CALLBACKS if @urls > $MAX_CALLBACKS;
			# Anti-SSRF: niente userinfo, frammento, query, backslash, spazi o caratteri di controllo: con
			# 'http://127.0.0.1:9000#@IP/x' cb_host vedrebbe IP mentre HTTP::Tiny contatterebbe 127.0.0.1.
			if (grep { !m{^http://[^/@#?\\[:space:][:cntrl:]]+(?:/[^@#?\\[:space:][:cntrl:]]*)?$}i } @urls) {
				logm("SUBSCRIBE rifiutato: CALLBACK con caratteri non ammessi");
				return http_reply($c, 412, 'text/plain', "CALLBACK non ammessa\n");
			}
			# Anti-SSRF: il NOTIFY parte solo verso chi ha chiesto l'abbonamento, mai verso altri host della LAN.
			my $peer = lc($c->peerhost // '');
			$peer =~ s/^::ffff://;
			if (grep { cb_host($_) ne $peer } @urls) {
				logm("SUBSCRIBE rifiutato: CALLBACK diversa dal richiedente ($peer)");
				return http_reply($c, 412, 'text/plain', "CALLBACK non ammessa
");
			}
			my $host = cb_host($urls[0]);
			if (keys(%SUBS) >= $MAX_SUBS || (grep { cb_host($_->{urls}[0]) eq $host } values %SUBS) >= $MAX_SUBS_HOST) {
				logm("SUBSCRIBE rifiutato: troppi abbonamenti");
				return http_reply($c, 503, 'text/plain', "troppi abbonamenti\n", 'Retry-After' => 30);
			}
			my $h = md5_hex(time . rand() . $$ . scalar(keys %SUBS));
			my $new = 'uuid:' . join('-', substr($h, 0, 8), substr($h, 8, 4), substr($h, 12, 4), substr($h, 16, 4), substr($h, 20, 12));
			$SUBS{$new} = { svc => $svc, urls => \@urls, seq => 0, expires => time + $to, pid => 0, dirty => 0, fails => 0 };
			http_reply($c, 200, undef, '', SID => $new, TIMEOUT => "Second-$to");
			close $c;
			send_event($new);
			return;
		}
		if ($method eq 'UNSUBSCRIBE') {
			my ($sid) = $head =~ /^SID:\s*(\S+)/mi;
			return http_reply($c, 412, 'text/plain', "SID sconosciuto\n") unless defined $sid && $SUBS{$sid};
			delete $SUBS{$sid};
			return http_reply($c, 200, undef, '');
		}
	}
	return http_reply($c, 405, 'text/plain', "metodo non ammesso\n");
}

# --- Stato per la pagina Stato --------------------------------------------------------------------

sub write_state {
	my ($stato, $detail) = @_;
	my %j = (
		stato => $stato, dettaglio => $detail // '', nome => friendly_name(), porta => $HTTP_PORT + 0,
		comandi => $S{commands} + 0, ultima_azione => $S{last_action}, trasporto => $S{state},
		abbonati => scalar(keys %SUBS) + 0, aggiornato => int(time),
	);
	my $tmp = "$DIR/renderer.json.tmp";
	if (open my $f, '>', $tmp) {
		print $f JSON::PP->new->canonical->utf8->encode(\%j), "\n";
		close $f;
		chmod 0644, $tmp;
		rename $tmp, "$DIR/renderer.json";
	}
}

# --- Ciclo principale -------------------------------------------------------------------------------------

my ($ssdp, $listen, $sel);
my $running = 0;
my $stop_requested = 0;
$SIG{TERM} = $SIG{INT} = sub { $stop_requested = 1 };
$SIG{PIPE} = 'IGNORE';

sub start_service {
	my $http_sock = IO::Socket::INET->new(Proto => 'tcp', Listen => 16, LocalPort => $HTTP_PORT, ReuseAddr => 1);
	unless ($http_sock) {
		write_state('errore', "porta $HTTP_PORT occupata");
		logm("porta HTTP $HTTP_PORT non disponibile: $!");
		return 0;
	}
	my $ssdp_sock = eval { IO::Socket::INET->new(Proto => 'udp', LocalPort => $SSDP_PORT, ReuseAddr => 1, ReusePort => 1) };
	$ssdp_sock ||= IO::Socket::INET->new(Proto => 'udp', LocalPort => $SSDP_PORT, ReuseAddr => 1);
	unless ($ssdp_sock) {
		close $http_sock;
		write_state('errore', "porta SSDP $SSDP_PORT occupata");
		logm("porta SSDP $SSDP_PORT non disponibile: $!");
		return 0;
	}
	my $joined = join_multicast($ssdp_sock);
	logm("acceso: '" . friendly_name() . "' su http porta $HTTP_PORT" . ($joined ? '' : ' (nessun gruppo multicast: rete assente?)'));
	($listen, $ssdp) = ($http_sock, $ssdp_sock);
	$sel = IO::Select->new($listen, $ssdp);
	announce('alive');
	$running = 1;
	return 1;
}

sub stop_service {
	return unless $running;
	announce('byebye');
	close $_ for grep { defined } ($listen, $ssdp);
	($listen, $ssdp, $sel) = ();
	%SUBS = ();
	@pending_resp = ();
	$running = 0;
	logm('spento');
}

my $next_alive = 0;
my $next_poll = 0;
my $next_state = 0;
my $last_state = '';
my $last_name = '';
my $since_fail = 0;

while (!$stop_requested) {
	my $want = is_yes(conf('RENDERER_UPNP', 'no')) && !solo_player();
	if ($want && !$running) {
		if (!start_service()) {
			sleep 5;
			next;
		}
		$next_alive = time + 600;
	} elsif (!$want && $running) {
		stop_service();
		write_state('spento', solo_player() ? 'modalità solo player: serve Lyrion su questo Sweetspot' : '');
	}
	if (!$running) {
		write_state('spento', solo_player() ? 'modalità solo player: serve Lyrion su questo Sweetspot' : '') if time >= $next_state;
		$next_state = time + 5 if time >= $next_state;
		sleep 1;
		next;
	}

	for my $h ($sel->can_read(0.25)) {
		if ($h == $ssdp) {
			my $from = recv($ssdp, my $data, 2048, 0);
			handle_ssdp($data, $from) if defined $from && length $data;
		} elsif ($h == $listen) {
			my $c = $listen->accept or next;
			# Il socket ascolta su tutte le schede: chi arriva dall'hotspot di configurazione non si serve.
			if ($c->sockhost eq $AP_IP) { close $c; next }
			$c->autoflush(1);
			eval { handle_http($c); 1 } or logm("richiesta HTTP: $@");
			close $c;
		}
	}
	flush_ssdp($ssdp);
	reap_events();
	expire_subs();

	my $now = time;
	if ($now >= $next_poll) {
		$next_poll = $now + 2;
		my $changed = poll_player();
		notify_services('AVTransport', 'RenderingControl') if $changed;
		# Il nome cambiato dal pannello vale subito per gli annunci.
		my $name = friendly_name() . '|' . device_uuid();
		if ($last_name ne '' && $name ne $last_name) { announce('alive'); $next_alive = $now + 600 }
		$last_name = $name;
	}
	if ($now >= $next_alive) {
		announce('alive');
		$next_alive = $now + 600;
	}
	if ($now >= $next_state) {
		$next_state = $now + 5;
		my ($stato, $detail) = $S{lyrion} ? ('attivo', '') : ('attesa', player_mac() eq '' ? 'il player non è ancora pronto' : 'Lyrion non risponde');
		write_state($stato, $detail);
	}
}
stop_service();
write_state('spento', '');
exit 0;
