#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Regressioni: endpoint di riproduzione ALSA e margine dei filtri stretti.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
BB=$(command -v busybox || true)
MATHAWK=$(command -v gawk || command -v mawk || command -v awk)
if [ -n "$BB" ]; then
	mkdir -p "$WORK/bin"
	for a in $("$BB" --list); do ln -sf "$BB" "$WORK/bin/$a"; done
	TEST_SH="$BB sh"
	export SWEETSPOT_PATH="$WORK/bin"
else
	TEST_SH="sh"
	export SWEETSPOT_PATH=/usr/bin
fi
export SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot
expect() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s\n      atteso: [%s]\n      ottenuto: [%s]\n' "$1" "$2" "$3"; fi
}
E=$WORK/audio
mkdir -p "$E/proc/asound/card0/pcm0c" "$E/proc/asound/card1/pcm1p" "$E/run/correzione" "$E/sys" "$E/bin"
printf 'MemTotal: 2005000 kB\n' > "$E/proc/meminfo"
printf 'UMIK\n' > "$E/proc/asound/card0/id"
printf '2752:0007\n' > "$E/proc/asound/card0/usbid"
printf 'DAC\n' > "$E/proc/asound/card1/id"
printf '1234:5678\n' > "$E/proc/asound/card1/usbid"
cat > "$E/proc/asound/pcm" <<'PCM'
00-00: USB Audio : USB Audio : capture 1
01-01: USB Audio : USB Audio : playback 1 : capture 1
PCM
cat > "$E/proc/asound/cards" <<'CARDS'
 0 [UMIK           ]: USB-Audio - UMIK-1
 1 [DAC            ]: USB-Audio - Stereo DAC
CARDS
cat > "$E/proc/asound/card0/stream0" <<'STREAM'
Capture:
  Interface 1
    Format: S32_LE
    Rates: 48000
STREAM
cat > "$E/proc/asound/card1/stream0" <<'STREAM'
Capture:
  Interface 1
    Format: DSD_U32_BE
    Rates: 768000
STREAM
cat > "$E/proc/asound/card1/stream1" <<'STREAM'
Playback:
  Interface 2
    Format: S24_3LE
    Rates: 44100, 48000, 96000
Capture:
  Interface 3
    Format: S32_LE
    Rates: 192000
STREAM
fn() { # file comando
	local script=$1 command=$2
	SWEETSPOT_RUN=$E/run SWEETSPOT_PROCFS=$E/proc SWEETSPOT_SYSFS=$E/sys SWEETSPOT_LOG=$E/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_AWK=$MATHAWK \
		SWEETSPOT_ASOUND=$E/asound.conf SWEETSPOT_CAMILLADSP=$E/assente SWEETSPOT_APLAY=$E/bin/aplay \
		SWEETSPOT_WGET=$E/bin/wget \
		SWEETSPOT_TEST=1 SWEETSPOT_PATH="$E/bin:$SWEETSPOT_PATH" $TEST_SH -c ". '$script'; $command"
}
common() { fn "$OVERLAY/usr/lib/sweetspot/common.sh" "$1"; }
dsp() { fn "$OVERLAY/usr/bin/sweetspot-dsp" "$1"; }
player() { fn "$OVERLAY/usr/bin/sweetspot-player" "$1"; }
printf 'DAC=auto\nCORREZIONE=si\nMODALITA=player\n' > "$E/settings"
common "config_build '$E/settings'"
echo "Endpoint ALSA"
expect "UMIK prima del DAC: sceglie l'uscita" 1 "$(common dac_find)"
expect "non usa il dispositivo capture 0" 1 "$(common 'dac_playback_dev 1')"
expect "solo formati del playback selezionato" S24_3LE "$(common 'dac_formats 1')"
expect "solo frequenze del playback selezionato" '44100 48000 96000' "$(common 'dac_rates 1')"
expect "DSD disponibile solo in capture: non offerto" '' "$(common 'dac_native_dsd 1')"
printf 'DAC=UMIK\n' > "$E/settings"
common "config_build '$E/settings'"
expect "microfono richiesto esplicitamente: nessun DAC" '' "$(common dac_find)"
printf 'DAC=auto\nCORREZIONE=si\nMODALITA=player\n' > "$E/settings"
common "config_build '$E/settings'"
# Snapshot: DEV0 is a decoy; the player-selected endpoint is DEV1.
echo "Snapshot del PCM selezionato"
P=$E/proc/asound/card1/pcm1p
mkdir -p "$P/sub0" "$E/proc/asound/card1/pcm0p/sub0"
params() {
	printf 'access: RW_INTERLEAVED\nformat: %s\nchannels: 2\nrate: 96000 (96000/1)\nbuffer_size: 4096\nperiod_size: 1024\n' "${2:-S32_LE}" > "$1/hw_params"
}
params "$E/proc/asound/card1/pcm0p/sub0" S16_LE
printf 'state: RUNNING\n' > "$E/proc/asound/card1/pcm0p/sub0/status"
mkdir -p "$E/proc/asound/card1/pcm1c/sub0"
params "$E/proc/asound/card1/pcm1c/sub0" S16_LE
printf 'state: RUNNING\n' > "$E/proc/asound/card1/pcm1c/sub0/status"
params "$P/sub0"
printf 'state: RUNNING\n' > "$P/sub0/status"
expect "hw_now ignora PCM0 configurato" 'S32_LE 96000 2' "$(common 'dac_hw_now 1')"
expect "snapshot DEV1 con buffer" '1|0|RUNNING|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
for state in OPEN SETUP PREPARED RUNNING PAUSED XRUN SUSPENDED DRAINING DISCONNECTED; do
	printf 'state: %s\n' "$state" > "$P/sub0/status"
	expect "stato $state non alterato" "1|0|$state|S32_LE|96000|2|4096|1024" "$(common 'dac_pcm_snapshot 1')"
done
printf 'closed\n' > "$P/sub0/hw_params"
expect "selezionato chiuso, decoy RUNNING" '1|0|CLOSED|||||' "$(common 'dac_pcm_snapshot 1')"
expect "hw_now non ripiega sul decoy" '' "$(common 'dac_hw_now 1')"
mkdir -p "$P/sub1"
params "$P/sub1"
printf 'state: RUNNING\n' > "$P/sub1/status"
expect "sub0 chiuso, sub1 aperto" '1|1|RUNNING|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
params "$P/sub0"
expect "due substream aperti: ownership ambigua" '1|-|AMBIGUOUS|||||' "$(common 'dac_pcm_snapshot 1')"
expect "hw_now rifiuta ownership ambigua" '' "$(common 'dac_hw_now 1')"
rm -r "$P/sub1"
rm "$P/sub0/hw_params"
expect "hw_params mancante" '1|0|UNAVAILABLE|||||' "$(common 'dac_pcm_snapshot 1')"
rm -r "$P/sub0"
expect "substream mancante" '1|-|UNAVAILABLE|||||' "$(common 'dac_pcm_snapshot 1')"
mkdir -p "$P/sub0"
params "$P/sub0"
expect "status assente conserva parametri osservati" '1|0|UNVERIFIED|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
printf 'state: SOMETHING\n' > "$P/sub0/status"
expect "stato sconosciuto non diventa RUNNING" '1|0|UNVERIFIED|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
printf 'state: RUNNING\nstate: PAUSED\n' > "$P/sub0/status"
expect "status duplicato non verificato" '1|0|UNVERIFIED|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
printf 'state: RUNNING\n' > "$P/sub0/status"
for field in format rate channels buffer_size period_size; do
	params "$P/sub0"
	printf '%s: 2\n' "$field" >> "$P/sub0/hw_params"
	expect "$field duplicato invalida parametri" '1|0|UNVERIFIED|||||' "$(common 'dac_pcm_snapshot 1')"
	expect "hw_now rifiuta $field duplicato" '' "$(common 'dac_hw_now 1')"
done
for field in format rate channels; do
	params "$P/sub0"
	sed "/^$field:/d" "$P/sub0/hw_params" > "$E/params.tmp"
	cat "$E/params.tmp" > "$P/sub0/hw_params"
	expect "$field mancante invalida parametri" '1|0|UNVERIFIED|||||' "$(common 'dac_pcm_snapshot 1')"
done
for pair in 'format: BAD_FORMAT' 'format: S32_LE garbage' 'rate: 0' 'rate: 1+2' 'rate: 9999999999999999999999999999' 'channels: -2' 'channels: 0' 'channels: 2 garbage' 'channels: 999999999999999999999999' 'buffer_size: nope' 'period_size: 0'; do
	params "$P/sub0"
	field=${pair%%:*}
	sed "/^$field:/d" "$P/sub0/hw_params" > "$E/params.tmp"
	cat "$E/params.tmp" > "$P/sub0/hw_params"
	printf '%s\n' "$pair" >> "$P/sub0/hw_params"
	expect "$pair invalida parametri" '1|0|UNVERIFIED|||||' "$(common 'dac_pcm_snapshot 1')"
done
for annotation in '(96000/0)' '(0/1)' '(4294967296/1)' '(96000/4294967296)' '(96000/999999999999999999999999)' '(96000//1)' '(96000/)' '(96000/1'; do
	params "$P/sub0"
	sed '/^rate:/d' "$P/sub0/hw_params" > "$E/params.tmp"
	cat "$E/params.tmp" > "$P/sub0/hw_params"
	printf 'rate: 96000 %s\n' "$annotation" >> "$P/sub0/hw_params"
	expect "annotazione rate $annotation invalida parametri" '1|0|UNVERIFIED|||||' "$(common 'dac_pcm_snapshot 1')"
	expect "hw_now rifiuta annotazione rate $annotation" '' "$(common 'dac_hw_now 1')"
done
params "$P/sub0"
sed 's@96000 (96000/1)@96000 (192001/2)@' "$P/sub0/hw_params" > "$E/params.tmp"
cat "$E/params.tmp" > "$P/sub0/hw_params"
expect "annotazione razionale positiva non impone uguaglianza esatta" '1|0|RUNNING|S32_LE|96000|2|4096|1024' "$(common 'dac_pcm_snapshot 1')"
for format in DSD_U8 DSD_U16_LE DSD_U16_BE DSD_U32_LE DSD_U32_BE; do
	params "$P/sub0" "$format"
	expect "DSD nativo $format" "1|0|RUNNING|$format|96000|2|4096|1024" "$(common 'dac_pcm_snapshot 1')"
done
params "$P/sub0"
sed '/^buffer_size:/d; /^period_size:/d' "$P/sub0/hw_params" > "$E/params.tmp"
cat "$E/params.tmp" > "$P/sub0/hw_params"
expect "buffer e periodo opzionali" '1|0|RUNNING|S32_LE|96000|2||' "$(common 'dac_pcm_snapshot 1')"
expect "endpoint non risolto" '-|-|UNAVAILABLE|||||' "$(common 'dac_pcm_snapshot 99')"
mv "$P" "$E/pcm1p-absent"
expect "endpoint selezionato assente non ripiega" '1|-|UNAVAILABLE|||||' "$(common 'dac_pcm_snapshot 1')"
mv "$E/pcm1p-absent" "$P"
rm -r "$P/sub0" "$E/proc/asound/card1/pcm0p" "$E/proc/asound/card1/pcm1c"
# Solo il lancio del processo e' sostituito; gli argomenti e il file sono reali.
printf '#!/bin/sh\nexit 1\n' > "$E/bin/sweetspot-dsp"
chmod +x "$E/bin/sweetspot-dsp"
player 'taskset() { :; }; HK=0; run_player 1; wait "$PID"'
expect "player apre l'endpoint di playback DEV1" 'hw:CARD=DAC,DEV=1' "$(sed -n 's/^-o \([^ ]*\).*/\1/p' "$E/run/player.args")"
printf 'Filter 1: ON PK Fc 814.8 Hz Gain 6 dB Q 50\n' > "$E/run/correzione/sinistro.txt"
dsp 'do_prepare 1' > /dev/null
expect "CamillaDSP apre lo stesso DEV1" 'hw:CARD=DAC,DEV=1' "$(sed -n 's/^    device: "\(.*\)"/\1/p' "$E/run/camilladsp.yml")"
expect "CamillaDSP conserva i 24 bit del playback" S24_3_LE "$(sed -n 's/^    format: //p' "$E/run/camilladsp.yml" | tail -n 1)"
expect "plugin non offre frequenze del capture" '44100 48000 96000' "$(sed -n 's/.*rates = \[ \(.*\) \]/\1/p' "$E/asound.conf")"
cp "$E/proc/asound/card1/stream1" "$E/stream-originale"
cat > "$E/proc/asound/card1/stream1" <<'STREAM'
Playback:
  Interface 2
    Altset 1
    Format: S24_3LE
    Rates: 44100, 48000, 96000
    Altset 2
    Format: S32_LE
    Rates: 48000
    Altset 3
    Format: DSD_U32_BE
    Rates: 176400
Capture:
  Interface 3
    Format: S32_LE
    Rates: 192000
STREAM
expect "frequenze PCM legate al formato S32, senza DSD" 48000 "$(common 'dac_rates 1 S32_LE')"
expect "frequenze S24 restano indipendenti" '44100 48000 96000' "$(common 'dac_rates 1 S24_3LE')"
expect "diagnostica completa del playback conserva gli altri formati" '44100 48000 96000 176400' "$(common 'dac_rates 1')"
dsp 'do_prepare 1' > /dev/null
expect "DSP: solo frequenze disponibili al formato di uscita" 48000 "$(sed -n 's/.*rates = \[ \(.*\) \]/\1/p' "$E/asound.conf")"
printf 'Playback:\n  Interface 2\n    Format: S32_LE\n    Rates: 44100 - 96000 (continuous)\n' > "$E/proc/asound/card1/stream1"
expect "intervallo USB continuo include le frequenze intermedie" '44100 48000 88200 96000' "$(common 'dac_rates 1 S32_LE')"
cat > "$E/proc/asound/card1/stream1" <<'STREAM'
Playback:
  Interface 2
    Altset 1
    Format: S32_LE
    Channels: 8
    Rates: 48000
    Altset 2
    Format: S24_3LE
    Channels: 2
    Rates: 44100
STREAM
expect "diagnostica conserva anche i formati multicanale" 'S24_3LE S32_LE' "$(common 'dac_formats 1')"
expect "DSP stereo: evita S32 disponibile solo a 8 canali" S24_3_LE "$(dsp 'dsp_out_format 1')"
expect "DSP stereo: frequenze del formato a due canali" 44100 "$(dsp 'dsp_rates 1')"
dsp 'do_prepare 1' > /dev/null
expect "configurazione DSP usa il formato stereo" S24_3_LE "$(sed -n 's/^    format: //p' "$E/run/camilladsp.yml" | tail -n 1)"
cat > "$E/proc/asound/card1/stream1" <<'STREAM'
Playback:
  Interface 2
    Altset 1
    Format: S32_LE
    Channels: 8
    Rates: 192000
    Altset 2
    Format: S32_LE
    Channels: 2
    Rates: 48000
STREAM
expect "stesso formato: non unisce frequenze di canali diversi" 48000 "$(dsp 'dsp_rates 1')"
printf 'Playback:\n  Interface 2\n    Format: S32_LE\n    Channels: 8\n    Rates: 48000\n' > "$E/proc/asound/card1/stream1"
# Un dump ALSA generico non deve scavalcare un descrittore USB esplicitamente
# incompatibile col numero di canali richiesto dal DSP.
printf '#!/bin/sh\nprintf "FORMAT: S32_LE\\n"\nexit 1\n' > "$E/bin/aplay"
chmod +x "$E/bin/aplay"
expect "solo multicanale: nessun formato stereo inventato" '' "$(dsp 'dsp_out_format 1')"
expect "solo multicanale: configurazione DSP rifiutata" 1 "$(dsp 'do_prepare 1 > /dev/null; echo $?')"
rm "$E/bin/aplay"
cp "$E/stream-originale" "$E/proc/asound/card1/stream1"

echo "Headroom indipendente dalla griglia e dalla frequenza del brano"
for q in 10 50; do
	printf 'Filter 1: ON PK Fc 814.8 Hz Gain 6 dB Q %s\n' "$q" > "$E/run/correzione/sinistro.txt"
	expect "picco stretto 814.8 Hz, Q$q: copre tutti i 6 dB" -6.5 "$(dsp do_gain)"
done
printf 'Filter 1: ON PK Fc 814.8 Hz Gain 6 dB Q 50\nFilter 2: ON PK Fc 814.8 Hz Gain 6 dB Q 50\n' > "$E/run/correzione/sinistro.txt"
expect "due picchi coincidenti: copre tutti i 12 dB" -12.5 "$(dsp do_gain)"
printf 'Filter 1: ON PK Fc 814.8 Hz Gain 6 dB Q 50\nFilter 2: ON PK Fc 20000 Hz Gain 4 dB Q 50\n' > "$E/run/correzione/sinistro.txt"
expect "catena: limite conservativo anche presso Nyquist" -10.5 "$(dsp do_gain)"
printf 'Filter 1: ON PK Fc 814.8 Hz Gain -6 dB Q 50\n' > "$E/run/correzione/sinistro.txt"
expect "soli tagli: nessuna attenuazione aggiunta" 0.0 "$(dsp do_gain)"
printf 'Filter 1: ON PK Fc 814.8 Hz Gain 9 dB Q 50\n' > "$E/run/correzione/destro.txt"
expect "entrambi i canali usano il maggiore margine" -9.5 "$(dsp do_gain)"
rm "$E/run/correzione/destro.txt"
printf 'Filter 1: ON HPQ Fc 814.8 Hz Q 10\n' > "$E/run/correzione/sinistro.txt"
expect "passa-alto Q10: copre la risonanza senza Gain" -20.6 "$(dsp do_gain)"
printf 'Filter 1: ON LSC Fc 814.8 Hz Gain 6 dB Q 10\n' > "$E/run/correzione/sinistro.txt"
expect "shelf Q10: copre overshoot oltre i 6 dB" -20.7 "$(dsp do_gain)"
printf 'Filter 1: ON PK Fc 814.8 Hz Gain 6 dB Q 50\n' > "$E/run/correzione/sinistro.txt"
gain=$(dsp do_gain)
printf 'CORREZIONE=confronto\n' > "$E/settings"
common "config_build '$E/settings'"
dsp 'do_prepare 1' > /dev/null
expect "confronto: stessa attenuazione della correzione" "$gain" "$(sed -n 's/^      gain: //p' "$E/run/camilladsp.yml")"
expect "confronto: nessun filtro di equalizzazione" 0 "$(grep -c 'type: Biquad' "$E/run/camilladsp.yml")"

echo "I2S senza descrittori USB"
mkdir -p "$E/proc/asound/card2/pcm1p"
printf 'HAT\n' > "$E/proc/asound/card2/id"
printf '02-01: I2S : I2S : playback 1\n' >> "$E/proc/asound/pcm"
cat > "$E/bin/aplay" <<'APLAY'
#!/bin/sh
# Risposta ALSA: niente S16, e 96 kHz disponibile solo sul DEV1 corretto.
case " $* " in *' -D hw:CARD=HAT,DEV=1 '*) ;; *) exit 1 ;; esac
case " $* " in
 *' --dump-hw-params '*) printf 'FORMAT: S32_LE\nRATE: [44100 96000]\n'; exit 1 ;;
esac
rate=0 fmt=''
while [ "$#" -gt 0 ]; do
	case "$1" in -r) shift; rate=$1 ;; -f) shift; fmt=$1 ;; esac
	shift
done
[ "$fmt" = S32_LE ] || exit 1
case "$rate" in
 44100|48000|96000) printf '  rate         : %s\n' "$rate" ;;
 88200) printf '  rate         : 96000\n' ;;
 *) exit 1 ;;
esac
APLAY
chmod +x "$E/bin/aplay"
printf 'CORREZIONE=si\n' > "$E/settings"
common "config_build '$E/settings'"
expect "I2S: formati interrogati da ALSA" S32_LE "$(common 'dac_formats 2')"
expect "I2S: frequenze confermate nel formato scelto" '44100 48000 96000' "$(common 'dac_rates 2')"
dsp 'do_prepare 2' > /dev/null
expect "I2S: uscita DSP a 32 bit" S32_LE "$(sed -n 's/^    format: //p' "$E/run/camilladsp.yml" | tail -n 1)"
expect "I2S: 96 kHz non limitato a 44.1/48" '44100 48000 96000' "$(sed -n 's/.*rates = \[ \(.*\) \]/\1/p' "$E/asound.conf")"
printf '#!/bin/sh\nexit 1\n' > "$E/bin/aplay"
expect "ALSA non disponibile: nessun formato inventato" '' "$(dsp 'dsp_out_format 2')"
expect "ALSA non disponibile: preparazione rifiutata" 1 "$(dsp 'do_prepare 2 > /dev/null; echo $?')"

echo "Preferenze di fedelta' Lyrion: conferma e retry"
cat > "$E/bin/wget" <<'WGET'
#!/bin/sh
state=$(dirname "$0")/..
if [ -f "$state/rpc-response" ]; then cat "$state/rpc-response"; exit 0; fi
prev=''
for arg; do [ "$prev" != --post-data ] || data=$arg; prev=$arg; done
command=$(printf '%s\n' "$data" | jq -r '.params[1] | join(" ")')
if [ "$command" = 'connected ?' ]; then
	printf '{"result":{"_connected":1}}\n'
elif [ "$command" = "$(cat "$state/rpc-fail" 2>/dev/null)" ] && [ ! -f "$state/rpc-failed" ]; then
	: > "$state/rpc-failed"
	printf '{"error":{"code":-32000,"message":"temporary failure"}}\n'
else
	printf '{"result":{}}\n'
fi
WGET
chmod +x "$E/bin/wget"
printf '{"error":{"code":-32602,"message":"invalid params"}}\n' > "$E/rpc-response"
expect "errore RPC HTTP200 non diventa successo" 1 "$(common 'lms_json player playerpref replayGainMode 0 > /dev/null; echo $?')"
printf '<html>unavailable</html>\n' > "$E/rpc-response"
expect "risposta non JSON rifiutata" 1 "$(common 'lms_json player playerpref replayGainMode 0 > /dev/null; echo $?')"
printf '{"result":{}}\n{"result":{}}\n' > "$E/rpc-response"
expect "due risposte concatenate rifiutate" 1 "$(common 'lms_json player playerpref replayGainMode 0 > /dev/null; echo $?')"
printf '{"result":{}}\n' > "$E/rpc-response"
expect "risposta di successo valida accettata" 0 "$(common 'lms_json player playerpref replayGainMode 0 > /dev/null; echo $?')"
rm "$E/rpc-response"
printf 'MODALITA=completa\nVOLUME=fisso\n' > "$E/settings"
common "config_build '$E/settings'"
printf 'playerpref replayGainMode 0\n' > "$E/rpc-fail"
expect "ReplayGain non confermato: retry al giro successivo" '0 1' "$(player 'PREFS_SET=0; PLAYER_MAC=00:11:22:33:44:55; apply_player_prefs; printf "%s " "$PREFS_SET"; apply_player_prefs; echo "$PREFS_SET"')"
rm "$E/rpc-failed"
printf 'mixer volume 100\n' > "$E/rpc-fail"
expect "volume fisso non confermato: retry al giro successivo" '0 1' "$(player 'PREFS_SET=0; PLAYER_MAC=00:11:22:33:44:55; apply_player_prefs; printf "%s " "$PREFS_SET"; apply_player_prefs; echo "$PREFS_SET"')"
printf 'MODALITA=completa\nVOLUME=software\n' > "$E/settings"
common "config_build '$E/settings'"
expect "volume software richiesto: preferenze confermate" 1 "$(player 'PREFS_SET=0; PLAYER_MAC=00:11:22:33:44:55; apply_player_prefs; echo "$PREFS_SET"')"
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
