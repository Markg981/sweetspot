#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - test degli script di sistema.
# Usa la shell e le applet di BusyBox, come sul player, con un /sys e un
# /proc finti che riproducono computer reali (Asus N550JV, CPU ibrida
# Intel Lunar Lake, dual core, single core) e un DAC Gustard R26.
#
#   ./tests/run.sh

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
export SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
PASS=0

# Le applet di BusyBox davanti a tutto, come sul player.
BB=$(command -v busybox || true)
if [ -n "$BB" ]; then
	mkdir -p "$WORK/bin"
	for a in $("$BB" --list); do ln -sf "$BB" "$WORK/bin/$a"; done
	TEST_SH="$BB sh"
	export SWEETSPOT_PATH="$WORK/bin"
else
	echo "busybox non trovato: uso la shell di sistema"
	TEST_SH="sh"
	export SWEETSPOT_PATH=/usr/bin
fi

ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  NO  %s\n      atteso: [%s]\n      ottenuto: [%s]\n' "$1" "$2" "$3"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }

# Esegue una funzione di common.sh nell'ambiente finto $1.
run() {
	local env=$1
	shift
	SWEETSPOT_SYSFS=$env/sys SWEETSPOT_PROCFS=$env/proc SWEETSPOT_RUN=$env/run \
		SWEETSPOT_LOG=$env/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; $*"
}

# --- Costruzione dei computer finti ------------------------------------------

mkcpu() { # env cpu siblings
	mkdir -p "$1/sys/devices/system/cpu/cpu$2/topology"
	echo "$3" > "$1/sys/devices/system/cpu/cpu$2/topology/thread_siblings_list"
}

base_env() { # env online smt
	mkdir -p "$1/sys/devices/system/cpu/smt" "$1/proc" "$1/run"
	echo "$2" > "$1/sys/devices/system/cpu/online"
	echo "$3" > "$1/sys/devices/system/cpu/smt/control"
	printf 'MemTotal:       16303112 kB\n' > "$1/proc/meminfo"
	printf 'model name\t: Intel(R) Core(TM) i7-4700HQ CPU @ 2.40GHz\nflags\t\t: fpu tsc constant_tsc nonstop_tsc sse2\n' > "$1/proc/cpuinfo"
	echo "BOOT_IMAGE=/bzImage quiet" > "$1/proc/cmdline"
}

# Asus N550JV: 4 core, 8 thread (Hyper-Threading), coppie 0-4, 1-5, 2-6, 3-7.
N550=$WORK/n550jv
base_env "$N550" 0-7 on
for c in 0 1 2 3; do mkcpu "$N550" $c "$c,$((c + 4))"; mkcpu "$N550" $((c + 4)) "$c,$((c + 4))"; done

# Lo stesso dopo il riavvio con nosmt: solo i primi thread online.
N550B=$WORK/n550jv-nosmt
base_env "$N550B" 0-3 off
for c in 0 1 2 3; do mkcpu "$N550B" $c "$c"; done

# Intel Lunar Lake (Galaxy Book5 Pro 360): 4 P-core (0-3) + 4 E-core (4-7).
LNL=$WORK/lunarlake
base_env "$LNL" 0-7 notsupported
for c in 0 1 2 3 4 5 6 7; do mkcpu "$LNL" $c "$c"; done
mkdir -p "$LNL/sys/devices/cpu_core" "$LNL/sys/devices/cpu_atom"
echo 0-3 > "$LNL/sys/devices/cpu_core/cpus"
echo 4-7 > "$LNL/sys/devices/cpu_atom/cpus"

# CPU ibrida con due soli core veloci (0-1) e otto efficienti.
HYB=$WORK/ibrida2p
base_env "$HYB" 0-9 notsupported
for c in 0 1 2 3 4 5 6 7 8 9; do mkcpu "$HYB" $c "$c"; done
mkdir -p "$HYB/sys/devices/cpu_core" "$HYB/sys/devices/cpu_atom"
echo 0-1 > "$HYB/sys/devices/cpu_core/cpus"
echo 2-9 > "$HYB/sys/devices/cpu_atom/cpus"

# Vecchio dual core con Hyper-Threading, 2 GB di RAM.
DUAL=$WORK/dualcore
base_env "$DUAL" 0-3 on
mkcpu "$DUAL" 0 "0,2"; mkcpu "$DUAL" 2 "0,2"; mkcpu "$DUAL" 1 "1,3"; mkcpu "$DUAL" 3 "1,3"
printf 'MemTotal:        2005000 kB\n' > "$DUAL/proc/meminfo"

# Single core, 1 GB.
ONE=$WORK/singlecore
base_env "$ONE" 0 notsupported
mkcpu "$ONE" 0 0
printf 'MemTotal:         990000 kB\n' > "$ONE/proc/meminfo"

# DAC Gustard R26 sul controller USB 0000:00:14.0, scheda integrata come card0.
mkdac() { # env con_dsd(si/no)
	local e=$1 usb=devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0
	mkdir -p "$e/proc/asound/card0" "$e/proc/asound/card1" "$e/sys/$usb" \
		"$e/sys/class/sound/card1" "$e/sys/bus/pci/devices/0000:00:14.0/msi_irqs/125"
	echo PCH > "$e/proc/asound/card0/id"
	echo R26 > "$e/proc/asound/card1/id"
	echo 292b:0a26 > "$e/proc/asound/card1/usbid"
	cat > "$e/proc/asound/cards" <<-'C'
	 0 [PCH            ]: HDA-Intel - HDA Intel PCH
	                      HDA Intel PCH at 0xf7d10000 irq 33
	 1 [R26            ]: USB-Audio - GUSTARD R26
	                      GUSTARD GUSTARD R26 at usb-0000:00:14.0-2, high speed
	C
	{
		echo "GUSTARD R26 at usb-0000:00:14.0-2, high speed : USB Audio"
		echo
		echo "Playback:"
		echo "  Status: Stop"
		echo "  Interface 1"
		echo "    Altset 1"
		echo "    Format: S32_LE"
		echo "    Channels: 2"
		echo "    Rates: 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000"
		if [ "$2" = si ]; then
			echo "  Interface 1"
			echo "    Altset 3"
			echo "    Format: DSD_U32_BE"
			echo "    Rates: 88200, 176400, 352800, 705600"
		fi
	} > "$e/proc/asound/card1/stream0"
	ln -sfn "../../../$usb" "$e/sys/class/sound/card1/device"
}
mkdac "$N550" si
mkdac "$N550B" no

# --- Test -------------------------------------------------------------------------

echo "Impostazioni"
printf '# commento\r\nnome_player = Sala d'"'"'ascolto \r\nDSD="nativo"   # forzato\r\nWIFI_PASSWORD=abc#123 \r\n\r\n; altro commento\r\nRIGA SENZA UGUALE\r\nPROFILO=silenzio' > "$WORK/sweetspot.txt"
mkdir -p "$WORK/cfg/run"
expect "riga con spazi e apostrofo" "Sala d'ascolto" "$(run "$WORK/cfg" "config_build $WORK/sweetspot.txt; conf NOME_PLAYER")"
expect "virgolette e commento in linea" "nativo" "$(run "$WORK/cfg" "conf DSD")"
expect "password con #" "abc#123" "$(run "$WORK/cfg" "conf WIFI_PASSWORD")"
expect "ultima riga senza a capo" "silenzio" "$(run "$WORK/cfg" "conf PROFILO")"
expect "valore predefinito" "400" "$(run "$WORK/cfg" "conf BUFFER_ALSA_MS")"
expect "si/no" "si" "$(run "$WORK/cfg" "is_yes Sì && echo si || echo no")"

echo "Liste di core"
expect "expand_list" "0 1 2 3 6" "$(run "$ONE" "expand_list 0-3,6")"
expect "join_list" "2,3" "$(run "$ONE" "join_list 2 3")"

layout() { run "$1" 'cpu_layout; echo "$LAYOUT_AUDIO|$LAYOUT_IRQ|$LAYOUT_ISO|$LAYOUT_HK|$LAYOUT_NOSMT"'; }
echo "Disposizione dei core (riproduzione|interruzioni|isolati|sistema|nosmt)"
expect "Asus N550JV" "2|3|2 3|0 1|1" "$(layout "$N550")"
expect "Asus N550JV dopo nosmt (stabile)" "2|3|2 3|0 1|1" "$(layout "$N550B")"
expect "Lunar Lake: P-core dedicati" "2|3|2 3|0 1 4 5 6 7|0" "$(layout "$LNL")"
expect "ibrida con 2 P-core" "1|9|1 9|0 2 3 4 5 6 7 8|0" "$(layout "$HYB")"
expect "dual core con HT" "1|0|1|0|1" "$(layout "$DUAL")"
expect "single core" "0|0||0|0" "$(layout "$ONE")"

echo "Memoria"
expect "classe 16 GB" "completa" "$(run "$N550" machine_class)"
expect "classe 2 GB" "essenziale" "$(run "$DUAL" machine_class)"
expect "classe 1 GB" "leggera" "$(run "$ONE" machine_class)"
expect "buffer 16 GB" "1048576:2000000" "$(run "$N550" player_buffers)"
expect "buffer 2 GB" "250625:501250" "$(run "$DUAL" player_buffers)"

echo "DAC"
expect "trova il DAC USB, non la scheda integrata" "1" "$(run "$N550" dac_find)"
expect "nome" "GUSTARD R26" "$(run "$N550" "dac_name 1")"
expect "DSD nativo dichiarato" "u32be" "$(run "$N550" "dac_native_dsd 1")"
expect "DSD non dichiarato" "" "$(run "$N550B" "dac_native_dsd 1")"
expect "frequenze" "44100 48000 88200 96000 176400 192000 352800 384000 705600 768000" "$(run "$N550" "dac_rates 1")"
expect "controller USB" "0000:00:14.0" "$(run "$N550" "dac_controller 1")"
expect "interruzioni del controller" "125" "$(run "$N550" "pci_irqs 0000:00:14.0")"
mkdir -p "$N550/run"; echo "DAC=r26" > "$WORK/dac.txt"
expect "DAC scelto per nome" "1" "$(run "$N550" "config_build $WORK/dac.txt; dac_find")"
echo "DAC=292b:0a26" > "$WORK/dac.txt"
expect "DAC scelto per identificativo USB" "1" "$(run "$N550" "config_build $WORK/dac.txt; dac_find")"
rm -f "$N550/run/sweetspot.conf"

echo "Server Lyrion"
mkdir -p "$N550/proc/net"
cat > "$N550/proc/net/tcp" <<'T'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1
   1: 0F01A8C0:C350 0A01A8C0:0D9B 01 00000000:00000000 00:00000000 00000000     0        0 2 1
T
expect "indirizzo dal collegamento sulla porta 3483" "192.168.1.10" "$(run "$N550" lms_server_ip)"

echo "Parametri di avvio"
AUTOTUNE="$OVERLAY/usr/bin/sweetspot-autotune"
tune() {
	SWEETSPOT_SYSFS=$1/sys SWEETSPOT_PROCFS=$1/proc SWEETSPOT_RUN=$1/run SWEETSPOT_LOG=$1/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c "sed 's#^\. /usr/lib/sweetspot/common.sh#. $OVERLAY/usr/lib/sweetspot/common.sh#' $AUTOTUNE > $WORK/autotune.sh; $TEST_SH $WORK/autotune.sh --stampa"
}
p=$(tune "$N550")
expect "N550JV" "nosmt intel_idle.max_cstate=1 processor.max_cstate=1 isolcpus=managed_irq,domain,2,3 nohz_full=2,3 rcu_nocbs=2,3 irqaffinity=0,1 tsc=reliable" "${p% sweetspot.tune=*}"
case "$p" in *" sweetspot.tune="????????) ok "impronta dei parametri" ;; *) ko "impronta dei parametri" "sweetspot.tune=xxxxxxxx" "$p" ;; esac
p2=$(tune "$N550B")
expect "stessi parametri dopo il riavvio (nessun ciclo di riavvii)" "$p" "$p2"
mkdir -p "$N550B/run"; printf 'DSD=nativo\n' > "$WORK/dsd.txt"
run "$N550B" "config_build $WORK/dsd.txt" >/dev/null
p3=$(tune "$N550B")
case "$p3" in *"snd_usb_audio.quirk_flags=292b:0a26:dsd_raw"*) ok "DSD nativo forzato per il DAC" ;; *) ko "DSD nativo forzato" "...quirk_flags=292b:0a26:dsd_raw..." "$p3" ;; esac
echo "BOOT_IMAGE=/bzImage snd_usb_audio.quirk_flags=292b:0a26:dsd_raw" > "$N550B/proc/cmdline"
p4=$(tune "$N550B")
expect "DSD forzato stabile dopo il riavvio" "$p3" "$p4"
printf 'OTTIMIZZAZIONI=no\n' > "$WORK/off.txt"
run "$N550B" "config_build $WORK/off.txt" >/dev/null
p5=$(tune "$N550B")
case "$p5" in "sweetspot.tune="????????) ok "ottimizzazioni spente" ;; *) ko "ottimizzazioni spente" "sweetspot.tune=xxxxxxxx" "$p5" ;; esac
p6=$(tune "$ONE")
case "$p6" in *isolcpus*|*nosmt*) ko "single core senza isolamento" "nessun isolcpus" "$p6" ;; *) ok "single core senza isolamento" ;; esac

echo "Modifica di sweetspot.txt (senza chiavetta: copia in RAM)"
CFG=$WORK/cfgedit
mkdir -p "$CFG/run" "$CFG/proc"
printf '# Impostazioni\r\nNOME_PLAYER=Sala\r\nCONDIVISIONE_1_UTENTE=marco\r\n\r\nDSD=auto\r\n' > "$CFG/run/sweetspot.txt"
cfgset() {
	SWEETSPOT_RUN=$CFG/run SWEETSPOT_PROCFS=$CFG/proc SWEETSPOT_LOG=$CFG/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-config" "$@" >/dev/null 2>&1
	echo $?
}
expect "senza chiavetta: valida fino al riavvio (codice 2)" "2" "$(cfgset imposta CONDIVISIONE_1 '//192.168.1.10/Musica')"
cfgset imposta dsd nativo >/dev/null
cfgset imposta NOME_PLAYER "Sala d'ascolto" >/dev/null
cfgset rimuovi CONDIVISIONE_1_UTENTE >/dev/null
expect "chiave nuova in fondo, chiave esistente sostituita, prefissi intatti, a capo Windows" \
	"$(printf '# Impostazioni\r\nNOME_PLAYER=Sala d'"'"'ascolto\r\n\r\nDSD=nativo\r\nCONDIVISIONE_1=//192.168.1.10/Musica\r\n')" \
	"$(cat "$CFG/run/sweetspot.txt")"
expect "configurazione ricostruita" "nativo" "$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; conf DSD")"
expect "rifiuta valori su piu' righe" "1" "$(cfgset imposta NOME_PLAYER "$(printf 'a\nB=c')")"
expect "rifiuta chiavi non valide" "1" "$(cfgset imposta 'A;B' x)"

echo "Nomi e percorsi"
expect "nome di cartella sicuro" "Musica _rock_ 2024" "$(run "$ONE" "safe_name 'Musica /rock\$ 2024'")"
expect "percorso di rete //" "//192.168.1.10/Musica/FLAC" "$(run "$ONE" "normalize_unc '//192.168.1.10/Musica/FLAC/'")"
expect "percorso di rete Windows" "//NAS/Musica" "$(run "$ONE" "normalize_unc '\\\\\\\\NAS\\\\Musica'")"
expect "percorso di rete smb://" "//nas.local/Musica" "$(run "$ONE" "normalize_unc 'smb://nas.local/Musica'")"
expect "percorso di rete incompleto" "no" "$(run "$ONE" "normalize_unc '//192.168.1.10' || echo no")"
expect "modalita' predefinita" "completa" "$(run "$ONE" mode)"
expect "precarica 16 GB" "3980" "$(run "$N550" cache_mb)"
expect "precarica 1 GB" "241" "$(run "$ONE" cache_mb)"

echo "Configurazione di MPD"
mpdconf() { # ambiente scheda [impostazioni]
	mkdir -p "$1/run"
	printf '%s\n' "${3:-}" > "$WORK/mpd.txt"
	SWEETSPOT_SYSFS=$1/sys SWEETSPOT_PROCFS=$1/proc SWEETSPOT_RUN=$1/run SWEETSPOT_LOG=$1/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WORK/mpd.txt; . $OVERLAY/usr/bin/sweetspot-mpd-conf" sh "$2"
}
c=$(mpdconf "$N550" 1)
for want in 'device          "hw:CARD=R26,DEV=0"' 'mixer_type      "none"' 'auto_resample   "no"' \
	'auto_format     "no"' 'auto_channels   "no"' 'dop             "no"' 'size "3980 MB"' \
	'replaygain              "off"' 'buffer_time     "400000"'; do
	case "$c" in *"$want"*) ok "MPD: $want" ;; *) ko "MPD: $want" "$want" "(assente)" ;; esac
done
case "$(mpdconf "$N550" 1 DSD=dop)" in *'dop             "yes"'*) ok "MPD: DoP su richiesta" ;; *) ko "MPD: DoP" "dop yes" "-" ;; esac
case "$(mpdconf "$N550" 1 DSD=no)" in *'allowed_formats "*:16:* *:24:* *:32:*"'*) ok "MPD: DSD convertito in PCM" ;; *) ko "MPD: DSD in PCM" "allowed_formats" "-" ;; esac
case "$(mpdconf "$N550" "")" in *'type            "null"'*) ok "MPD: senza DAC uscita fittizia" ;; *) ko "MPD senza DAC" "null" "-" ;; esac
case "$(mpdconf "$N550" 1 'NOME_PLAYER=Sala "grande"')" in *'zeroconf_name           "Sala grande"'*) ok "MPD: nome senza virgolette" ;; *) ko "MPD nome" "Sala grande" "-" ;; esac

echo "Dischi nella libreria"
DSK=$WORK/dischi
mkdir -p "$DSK/media/Win/Windows/System32" "$DSK/media/Win/Users/marco/Music" "$DSK/media/Win/Users/Public/Music" \
	"$DSK/media/Linux/usr/bin" "$DSK/media/Linux/etc" "$DSK/media/Linux/home/anna/Musica" \
	"$DSK/media/Archivio/FLAC" "$DSK/musica" "$DSK/run"
touch "$DSK/media/Win/Users/marco/Music/a.flac"
links() {
	SWEETSPOT_MUSICA=$DSK/musica SWEETSPOT_MEDIA=$DSK/media SWEETSPOT_RUN=$DSK/run SWEETSPOT_LOG=$DSK/log SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-dischi; library_links \"\$1\" \"\$2\"" sh "$DSK/media/$1" "$1"
}
expect "disco Windows: solo le cartelle Musica non vuote" "Win - marco" "$(links Win)"
expect "disco Linux: cartelle Musica degli utenti" "Linux - anna" "$(links Linux)"
expect "disco dati: tutto il disco" "Archivio" "$(links Archivio)"
expect "collegamenti nella libreria" "Archivio Linux - anna Win - marco" "$(ls "$DSK/musica" | tr '\n' ' ' | sed 's/ $//')"
expect "collegamento al disco" "$DSK/media/Archivio" "$(readlink "$DSK/musica/Archivio")"

echo "Analisi statica (shellcheck)"
if command -v shellcheck >/dev/null; then
	files="$OVERLAY/usr/lib/sweetspot/common.sh $OVERLAY/usr/lib/sweetspot/web.sh $OVERLAY/usr/bin/sweetspot-* $OVERLAY/etc/init.d/S*
		$OVERLAY/usr/share/sweetspot/www/cgi-bin/* $ROOT/board/sweetspot/*.sh $ROOT/scripts/*.sh"
	# SC1091: file inclusi; SC3043: 'local' (supportato dalla shell di BusyBox).
	if out=$(shellcheck -s dash -S warning -e SC1091,SC3043 $files 2>&1); then
		ok "nessun avviso"
	else
		ko "shellcheck" "nessun avviso" "$out"
	fi
else
	echo "  (shellcheck non installato, saltato)"
fi

echo
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
