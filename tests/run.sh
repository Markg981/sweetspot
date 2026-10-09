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
expect "buffer 2 GB" "203094:406189" "$(run "$DUAL" player_buffers)"
expect "buffer 1 GB" "33928:67856" "$(run "$ONE" player_buffers)"

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
cfgset imposta VOLUME dac RICAMPIONAMENTO sincrono FILTRO minimo >/dev/null
cfgset rimuovi RICAMPIONAMENTO FILTRO >/dev/null
expect "piu' chiavi in una volta (tolte: tornano i predefiniti)" "dac|no|lineare" \
	"$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; echo \"\$(conf VOLUME)|\$(conf RICAMPIONAMENTO)|\$(conf FILTRO)\"")"
expect "numero dispari di argomenti rifiutato" "1" "$(cfgset imposta VOLUME)"
expect "un valore non valido blocca tutto" "1" "$(cfgset imposta VOLUME software NOME_PLAYER "$(printf 'x\ny')")"
expect "niente cambiato dopo il rifiuto" "dac" "$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; conf VOLUME")"

echo "Nomi e percorsi"
expect "nome di cartella sicuro" "Musica _rock_ 2024" "$(run "$ONE" "safe_name 'Musica /rock\$ 2024'")"
expect "percorso di rete //" "//192.168.1.10/Musica/FLAC" "$(run "$ONE" "normalize_unc '//192.168.1.10/Musica/FLAC/'")"
expect "percorso di rete Windows" "//NAS/Musica" "$(run "$ONE" "normalize_unc '\\\\\\\\NAS\\\\Musica'")"
expect "percorso di rete smb://" "//nas.local/Musica" "$(run "$ONE" "normalize_unc 'smb://nas.local/Musica'")"
expect "percorso di rete incompleto" "no" "$(run "$ONE" "normalize_unc '//192.168.1.10' || echo no")"
expect "modalita' predefinita" "completa" "$(run "$ONE" mode)"
printf 'MODALITA=player\n' > "$WORK/m.txt"
expect "modalita' solo player" "player" "$(run "$ONE" "config_build $WORK/m.txt; mode")"
printf 'MODALITA=lyrion\n' > "$WORK/m.txt"
expect "vecchio nome della modalita' accettato" "player" "$(run "$ONE" "config_build $WORK/m.txt; mode")"
expect "stringa JSON" '"a\"b\\c"' "$(run "$ONE" "json_str 'a\"b\\c'")"
expect "bit dei formati ALSA" "16 24 32 1" "$(run "$ONE" 'echo $(alsa_bits S16_LE) $(alsa_bits S24_3LE) $(alsa_bits S32_LE) $(alsa_bits DSD_U32_BE)')"

echo "Volume del DAC"
mkdir -p "$WORK/amx"
cat > "$WORK/amx/amixer" <<'FINTO'
#!/bin/sh
cat <<'OUT'
Simple mixer control 'PCM',0
  Capabilities: pvolume pswitch pswitch-joined
  Playback channels: Front Left - Front Right
Simple mixer control 'Mic',0
  Capabilities: cvolume cswitch
Simple mixer control 'Clock Source 41 Validity',0
  Capabilities: pswitch pswitch-joined
OUT
FINTO
chmod +x "$WORK/amx/amixer"
expect "controlli di riproduzione del DAC" "PCM|Clock Source 41 Validity|" \
	"$(SWEETSPOT_PATH="$WORK/amx:$SWEETSPOT_PATH" SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player; dac_volume_controls 1" | tr '\n' '|')"

echo "Plugin consigliati"
CAT=$OVERLAY/usr/share/sweetspot/plugin-consigliati.txt
bad=$(grep -v '^#' "$CAT" | grep . | awk -F'|' 'NF != 4 || $1 !~ /^[A-Za-z0-9_]+$/ || $3 == "" || $4 == ""')
expect "catalogo: quattro campi e nomi validi" "" "$bad"
dups=$(grep -v '^#' "$CAT" | grep . | cut -d'|' -f1 | sort | uniq -d)
expect "catalogo: nessun doppione" "" "$dups"

echo "Pagine web (con un Lyrion finto)"
# Lyrion finto: risponde ai comandi JSON usati dalle pagine.
WEB=$WORK/web
mkdir -p "$WEB/bin" "$WEB/run"
cp -r "$N550/sys" "$N550/proc" "$WEB/"
cat > "$WEB/bin/wget" <<'FINTO'
#!/bin/sh
for a; do case "$a" in --post-data=*) d=${a#--post-data=} ;; esac; done
prev=""; for a; do [ "$prev" = --post-data ] && d=$a; prev=$a; done
case "$d" in
	*serverstatus*) echo '{"result":{"version":"9.1.1","info total songs":1200,"info total albums":100,"info total artists":80}}' ;;
	*plugin-stato*) echo '{"result":{"plugins_loop":[{"nome":"MaterialSkin","versione":"6.4.12","stato":"enabled","errore":""},{"nome":"Qobuz","versione":"3.7.2","stato":"enabled","errore":""},{"nome":"Altro","versione":"1.0","stato":"enabled","errore":""}],"scaricamenti":0,"riavvio":1}}' ;;
	*'"status"'*) echo '{"result":{"mode":"play","playlist_loop":[{"samplerate":"96000","samplesize":"24","type":"flc","title":"Brano","artist":"Artista"}]}}' ;;
	*version*) echo '{"result":{"_version":"9.1.1"}}' ;;
	*) echo '{"result":{}}' ;;
esac
FINTO
mkdir -p "$WEB/proc/sys/kernel"
echo sweetspot > "$WEB/proc/sys/kernel/hostname"
chmod +x "$WEB/bin/wget"
ln -sf "$OVERLAY/usr/bin/sweetspot-lms" "$WEB/bin/sweetspot-lms"
mkdir -p "$WEB/proc/asound/card1/pcm0p/sub0"
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 96000 (96000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
echo "00:11:22:33:44:55" > "$WEB/run/player.mac"
page() { # pagina [impostazioni]
	printf '%s\n' "${2:-}" > "$WEB/s.txt"
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$WEB/bin:$SWEETSPOT_PATH" \
		SWEETSPOT_PLUGIN_CATALOG=$OVERLAY/usr/share/sweetspot/plugin-consigliati.txt \
		SWEETSPOT_WGET=$WEB/bin/wget REQUEST_METHOD=GET QUERY_STRING="" HTTP_HOST=sweetspot.local \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; . $OVERLAY/usr/share/sweetspot/www/cgi-bin/$1" 2>&1
}
for p in audio musica archivio plugin rete sistema; do
	out=$(page "$p")
	case "$out" in
		"Content-Type: text/html"*"</html>") ok "pagina $p completa" ;;
		*) ko "pagina $p" "pagina HTML completa" "$(printf '%s' "$out" | tail -n 3)" ;;
	esac
done
case "$(page audio)" in *"Bit-perfect"*"24 bit"*) ok "audio: FLAC 24/96 su S32_LE 96 kHz e' bit-perfect" ;; *) ko "audio bit-perfect" "Bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 192000 (192000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"Non bit-perfect"*"96000 Hz"*) ok "audio: frequenza cambiata segnalata" ;; *) ko "audio ricampionato" "Non bit-perfect" "-" ;; esac
case "$(page audio 'VOLUME=software')" in *"Non bit-perfect"*) ok "audio: volume software segnalato" ;; *) ko "audio volume software" "Non bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: DSD_U32_BE\nsubformat: STD\nchannels: 2\nrate: 88200 (88200/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"DSD nativo"*"DSD64"*) ok "audio: DSD64 nativo riconosciuto" ;; *) ko "audio DSD nativo" "DSD64" "-" ;; esac
out=$(page plugin)
case "$out" in *"Riavvia Lyrion ora"*) ok "plugin: richiesta di riavvio mostrata" ;; *) ko "plugin riavvio" "Riavvia Lyrion ora" "-" ;; esac
case "$out" in *"Qobuz"*"Installato"*) ok "plugin: Qobuz installato" ;; *) ko "plugin Qobuz" "Installato" "-" ;; esac
case "$out" in *"Altri plugin installati"*"Altro"*) ok "plugin: plugin fuori catalogo elencati" ;; *) ko "plugin altri" "Altro" "-" ;; esac
case "$(page musica)" in *"1200 brani, 100 album, 80 artisti"*) ok "musica: numeri della libreria" ;; *) ko "musica libreria" "1200 brani" "-" ;; esac
case "$(page musica 'MODALITA=player')" in *"solo player"*) ok "musica: modalita' solo player" ;; *) ko "musica player" "solo player" "-" ;; esac

echo "Archivio musicale"
AR=$WORK/arch
mkdir -p "$AR/run" "$AR/proc/sys/kernel" "$AR/media/USB/Rock/Album" "$AR/media/Musica/Gia copiato" "$AR/media/rete-1/Jazz" "$AR/fuori"
echo salotto > "$AR/proc/sys/kernel/hostname"
echo "$AR/media/Musica" > "$AR/run/archivio"
ln -s "$AR/fuori" "$AR/media/USB/scappa"
arun() { # comando [impostazioni]
	printf '%s\n' "${2:-}" > "$AR/s.txt"
	SWEETSPOT_RUN=$AR/run SWEETSPOT_PROCFS=$AR/proc SWEETSPOT_LOG=$AR/log SWEETSPOT_MEDIA=$AR/media \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $AR/s.txt; . $OVERLAY/usr/bin/sweetspot-copia; . $OVERLAY/usr/bin/sweetspot-nas; archive() { cat $AR/run/archivio; }; $1"
}
expect "copia da un disco USB" "si" "$(arun "valid_source $AR/media/USB/Rock && echo si || echo no")"
expect "copia da una cartella di rete" "si" "$(arun "valid_source $AR/media/rete-1/Jazz && echo si || echo no")"
expect "niente copia dall'archivio" "no" "$(arun "valid_source '$AR/media/Musica/Gia copiato' && echo si || echo no")"
expect "niente copia da fuori /media" "no" "$(arun "valid_source $AR/fuori && echo si || echo no")"
expect "niente fuga con un collegamento" "no" "$(arun "valid_source $AR/media/USB/scappa && echo si || echo no")"
expect "niente fuga con .." "no" "$(arun "valid_source $AR/media/USB/../../fuori && echo si || echo no")"
expect "si toglie solo dentro l'archivio" "si no no" "$(arun "inside_archive '$AR/media/Musica/Gia copiato' && echo si || echo no; inside_archive $AR/media/Musica && echo si || echo no; inside_archive $AR/media/USB/Rock && echo si || echo no" | tr '\n' ' ' | sed 's/ $//')"
c=$(arun "ksmbd_conf /media/Musica")
case "$c" in *"netbios name = SALOTTO"*"path = /media/Musica"*"guest ok = yes"*) ok "cartella di rete libera" ;; *) ko "cartella di rete libera" "guest ok = yes" "$c" ;; esac
c=$(arun "ksmbd_conf /media/Musica" "ARCHIVIO_PASSWORD=segreta")
case "$c" in *"guest ok = no"*"valid users = sweetspot"*) ok "cartella di rete con password" ;; *) ko "cartella di rete con password" "valid users" "$c" ;; esac
case "$c" in *segreta*) ko "password fuori dalla configurazione" "assente" "presente" ;; *) ok "password fuori dalla configurazione" ;; esac

echo "Copia dei CD"
CD=$WORK/cd
mkdir -p "$CD"
# Indice dell'esempio della documentazione di MusicBrainz
printf '1 0 15213\n2 15213 16951\n3 32164 14278\n4 46442 16822\n5 63264 17075\n6 80339 14973\n' > "$CD/indice"
cdrun() { SWEETSPOT_TEST=1 SWEETSPOT_RUN=$CD/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-cd; $1"; }
expect "identificativo MusicBrainz (esempio ufficiale)" "49HHV7Eb8UKF3aQiNmu1GR8vKTY-" "$(cdrun "mb_discid $CD/indice")"
expect "identificativi AccurateRip" "6 000513be 001b2231 3404f606" "$(cdrun "ar_ids $CD/indice")"
# Database AccurateRip finto: due stampe dello stesso CD, due tracce
printf '\002\276\023\005\000\061\042\033\000\006\366\004\064\005\104\063\042\021\000\000\000\000\007\210\167\146\125\000\000\000\000\002\276\023\005\000\061\042\033\000\006\366\004\064\002\335\314\273\252\000\000\000\000\001\004\003\002\001\000\000\000\000' > "$CD/db.bin"
expect "database AccurateRip letto" "1 5 11223344|2 7 55667788|1 2 aabbccdd|2 1 01020304" "$(cdrun "ar_parse $CD/db.bin" | tr '\n' '|' | sed 's/|$//')"
expect "nomi di file validi ovunque" "AC-DC - Back in Black_" "$(cdrun "file_name 'AC/DC: Back in Black?'")"
expect "nomi di file: virgolette e punti finali" "Sinfonia 'Eroica'" "$(cdrun "file_name ' Sinfonia \"Eroica\"...'")"
expect "posizione sul disco" "21:12.62" "$(cdrun "sect_time 95462")"

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

echo "Blocchi"
LK=$WORK/lk
mkdir -p "$LK/run" "$LK/proc"
echo "BOOT_IMAGE=/bzImage" > "$LK/proc/cmdline"
expect "montare la chiavetta non scioglie il blocco del salvataggio dei dati" "tenuto" \
	"$(SWEETSPOT_RUN=$LK/run SWEETSPOT_PROCFS=$LK/proc SWEETSPOT_LOG=$LK/log $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh
		exec 8> $LK/dati.lock; flock 8; stick_mount ro; stick_umount
		if flock -n $LK/dati.lock true; then echo sciolto; else echo tenuto; fi")"

echo "Aggiornamenti (due copie del sistema)"
UPD=$WORK/upd
mkdir -p "$UPD/proc" "$UPD/run" "$UPD/sys" "$UPD/stick/boot/grub" "$UPD/stick/boot/versioni" "$UPD/media/USB" \
	"$UPD/avvio" "$UPD/bin" "$UPD/pkg"
echo "BOOT_IMAGE=/bzImage sweetspot.slot=a sweetspot.part=ABCD-1234" > "$UPD/proc/cmdline"
echo "v1.0.0 (2026-10-01)" > "$UPD/version"
echo A-kernel > "$UPD/stick/bzImage"
echo A-rootfs > "$UPD/stick/rootfs.cpio.zst"
echo v1.0.0 > "$UPD/stick/boot/versioni/a"
echo "menu vecchio" > "$UPD/stick/boot/grub/grub.cfg"
echo "menu nuovo" > "$UPD/avvio/grub.cfg"
printf '#!/bin/sh\nexit 0\n' > "$UPD/bin/wget-ok"
printf '#!/bin/sh\nexit 1\n' > "$UPD/bin/wget-ko"
chmod +x "$UPD/bin"/*
mkpkg() { # versione architettura [rovina]
	rm -rf "$UPD/pkg"; mkdir -p "$UPD/pkg"
	echo "kernel $1" > "$UPD/pkg/bzImage"
	echo "rootfs $1" > "$UPD/pkg/rootfs.cpio.zst"
	echo "$1" > "$UPD/pkg/versione"
	echo "$2" > "$UPD/pkg/architettura"
	(cd "$UPD/pkg" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
	[ -n "${3:-}" ] && echo "rovinato" >> "$UPD/pkg/rootfs.cpio.zst"
	tar -C "$UPD/pkg" -cf "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar" SHA256SUMS versione architettura bzImage rootfs.cpio.zst
}
upd() {
	SWEETSPOT_SYSFS=$UPD/sys SWEETSPOT_PROCFS=$UPD/proc SWEETSPOT_RUN=$UPD/run SWEETSPOT_LOG=$UPD/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_STICK_DIR=$UPD/stick \
		SWEETSPOT_MEDIA=$UPD/media SWEETSPOT_ARCH=x86_64 SWEETSPOT_VERSION_FILE=$UPD/version \
		SWEETSPOT_AVVIO=$UPD/avvio SWEETSPOT_WGET=${UPD_WGET:-$UPD/bin/wget-ok} SWEETSPOT_CONFERMA_ATTESA=2 \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-aggiorna" "$@"
}
genv() { $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; grubenv_get \"\$1\" \"\$2\"" sh "$UPD/stick/boot/grub/grubenv" "$1"; }
setenv() { $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; f=\$1; shift; grubenv_set \"\$f\" \"\$@\"" sh "$UPD/stick/boot/grub/grubenv" "$@"; }
setenv slot=a
expect "ambiente di GRUB di 1024 byte" "1024" "$(wc -c < "$UPD/stick/boot/grub/grubenv" | tr -d ' ')"
if command -v grub-editenv > /dev/null; then
	expect "ambiente leggibile da GRUB" "slot=a" "$(grub-editenv "$UPD/stick/boot/grub/grubenv" list)"
fi
mkpkg v1.1.0 x86_64
expect "pacchetto trovato sul disco" "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar" "$(upd pacchetti)"
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "aggiornamento pronto" "pronto|v1.1.0" "$(cat "$UPD/run/aggiornamento/stato")"
expect "nuova versione nella copia B" "kernel v1.1.0|rootfs v1.1.0|v1.1.0" \
	"$(cat "$UPD/stick/b/bzImage")|$(cat "$UPD/stick/b/rootfs.cpio.zst")|$(cat "$UPD/stick/boot/versioni/b")"
expect "copia A intatta" "A-kernel" "$(cat "$UPD/stick/bzImage")"
expect "GRUB la prova una volta" "a|b" "$(genv slot)|$(genv prova)"
expect "stato per la pagina" "v1.1.0|pronto|v1.1.0" "$(upd stato | sed -n 's/^altra_versione=//p')|$(upd stato | sed -n 's/^lavoro=//p')"
# GRUB avvia la copia B e consuma "prova"
setenv prova= tentato=b
echo "BOOT_IMAGE=/b/bzImage sweetspot.slot=b sweetspot.part=ABCD-1234" > "$UPD/proc/cmdline"
UPD_WGET=$UPD/bin/wget-ko upd conferma
expect "senza risposta dalla rete non si conferma" "a|b" "$(genv slot)|$(genv tentato)"
upd conferma
expect "la nuova versione si conferma" "b|" "$(genv slot)|$(genv tentato)"
expect "aggiornamento riuscito segnalato" "riuscita=1" "$(upd stato | grep '^riuscita=')"
expect "menu di avvio aggiornato dopo la conferma" "menu nuovo" "$(cat "$UPD/stick/boot/grub/grub.cfg")"
# Secondo aggiornamento (va nella copia A), che non parte: si torna a B
rm -f "$UPD/run/aggiornamento/riuscita"
mkpkg v1.2.0 x86_64
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "secondo aggiornamento nella copia A" "kernel v1.2.0|a" "$(cat "$UPD/stick/bzImage")|$(genv prova)"
setenv prova= tentato=a
upd conferma
expect "versione non partita: si resta su B" "b|" "$(genv slot)|$(genv tentato)"
expect "versione non partita segnalata" "fallita=v1.2.0" "$(upd stato | grep '^fallita=')"
# Pacchetti sbagliati
mkpkg v1.3.0 x86_64 rovina
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "pacchetto rovinato rifiutato" "errore" "$(cut -d'|' -f1 "$UPD/run/aggiornamento/stato")"
expect "nessuna prova dopo un pacchetto rovinato" "" "$(genv prova)"
expect "pacchetto rovinato: copia vuota" "no" "$([ -f "$UPD/stick/bzImage" ] && echo si || echo no)"
mkpkg v1.3.0 aarch64
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "pacchetto di un'altra architettura rifiutato" "errore|pacchetto per un altro tipo di computer (aarch64)" "$(cat "$UPD/run/aggiornamento/stato")"
mkpkg v1.3.0 x86_64
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
upd altra
expect "ritorno manuale all'altra versione" "a" "$(genv prova)"
expect "file fuori dai dischi rifiutato" "file non valido" "$(upd file /etc/passwd)"
cat > "$UPD/bin/curl" <<'EOF2'
#!/bin/sh
cat <<'JSON'
{"tag_name":"v2.0.0","published_at":"2026-11-01T10:00:00Z","body":"Novità: <b>prova</b>",
 "assets":[{"name":"sweetspot.img.xz","browser_download_url":"https://example.com/img","size":1},
           {"name":"sweetspot-x86_64-aggiornamento.tar","browser_download_url":"https://example.com/upd.tar","size":104857600}]}
JSON
EOF2
chmod +x "$UPD/bin/curl"
expect "ricerca su GitHub" "versione=v2.0.0 url=https://example.com/upd.tar dimensione=104857600 data=2026-11-01" \
	"$(SWEETSPOT_PATH="$UPD/bin:$SWEETSPOT_PATH" upd cerca | tr '\n' ' ' | sed 's/ $//')"

echo "Installazione sul disco interno"
INS=$WORK/ins
mkdir -p "$INS/sys/block/sda/queue" "$INS/sys/block/sda/device" "$INS/sys/block/sda/sda1" "$INS/sys/block/mmcblk0boot0" \
	"$INS/sys/devices/pci0000:00/usb1/1-1/block/sdb/queue" "$INS/proc" "$INS/run" "$INS/avvio"
echo 976773168 > "$INS/sys/block/sda/size"
echo 512 > "$INS/sys/block/sda/queue/logical_block_size"
printf 'ATA     \n' > "$INS/sys/block/sda/device/vendor"
printf 'Samsung SSD 860 \n' > "$INS/sys/block/sda/device/model"
echo 1 > "$INS/sys/block/sda/sda1/partition"
echo 976771072 > "$INS/sys/block/sda/sda1/size"
ln -s ../devices/pci0000:00/usb1/1-1/block/sdb "$INS/sys/block/sdb"
echo 15728640 > "$INS/sys/devices/pci0000:00/usb1/1-1/block/sdb/size"
echo 512 > "$INS/sys/devices/pci0000:00/usb1/1-1/block/sdb/queue/logical_block_size"
echo 8192 > "$INS/sys/block/mmcblk0boot0/size"
echo "BOOT_IMAGE=/bzImage" > "$INS/proc/cmdline"
ins() {
	SWEETSPOT_SYSFS=$INS/sys SWEETSPOT_PROCFS=$INS/proc SWEETSPOT_RUN=$INS/run SWEETSPOT_LOG=$INS/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_DEV=$INS/dev SWEETSPOT_AVVIO=$INS/avvio \
		SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-installa; $1"
}
expect "dischi adatti" "sda|465|Samsung SSD 860|interno|partizione sda1 (sconosciuta, 465 GB)|si sdb|7|Disco sdb|USB||no" \
	"$(ins do_disks | tr '\n' ' ' | sed 's/ $//')"
expect "partizioni di un disco da 500 GB" "2048 8388608 8390656 968380416" "$(ins 'plan 976773168')"
expect "disco piccolo: niente archivio" "2048 6287360 6289408 0" "$(ins 'plan 6291456')"
expect "disco da 4 TB: archivio fino al limite MBR" "2048 8388608 8390656 4286574592" "$(ins 'plan 8589934592')"
expect "nomi delle partizioni" "sda1 nvme0n1p2 mmcblk0p1" "$(ins 'echo $(part_name sda 1) $(part_name nvme0n1 2) $(part_name mmcblk0 1)')"
head -c 512 /dev/zero | tr '\0' '\353' > "$INS/avvio/boot.img"
head -c 3000 /dev/zero | tr '\0' '\147' > "$INS/avvio/grub.img"
truncate -s 1G "$INS/disco.img"
ins "write_mbr $INS/disco.img 2048 1048576 1050624 1048576"
expect "tabella: firma e prima partizione FAT32 avviabile" "55aa 80 0c 00080000 00001000" \
	"$(od -An -tx1 -j510 -N2 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j446 -N1 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j450 -N1 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j454 -N4 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j458 -N4 "$INS/disco.img" | tr -d ' ')"
expect "tabella: seconda partizione Linux" "83 00081000 00001000" \
	"$(od -An -tx1 -j466 -N1 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j470 -N4 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j474 -N4 "$INS/disco.img" | tr -d ' ')"
expect "GRUB nel settore 0 e nei settori successivi" "ebeb 6767" \
	"$(od -An -tx1 -j0 -N2 "$INS/disco.img" | tr -d ' ') $(od -An -tx1 -j3000 -N2 "$INS/disco.img" | tr -d ' ')"
if command -v sfdisk > /dev/null; then
	expect "tabella letta da sfdisk" "start=2048,size=1048576,type=c,bootable start=1050624,size=1048576,type=83" \
		"$(sfdisk -d "$INS/disco.img" 2>/dev/null | grep start= | sed -n 's/.*: //p' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
fi
expect "disco non adatto rifiutato" "disco non adatto" "$(ins 'do_start sdz si')"

echo "Cache delle copertine"
CC=$WORK/cc
mkdir -p "$CC/lms/cache" "$CC/archivio" "$CC/bin" "$CC/run"
echo vecchia > "$CC/lms/cache/artwork.db"
printf '#!/bin/sh\n[ "$1" = archivio ] && echo "%s"\n' "$CC/archivio" > "$CC/bin/sweetspot-dischi"
chmod +x "$CC/bin/sweetspot-dischi"
lmsfn() {
	SWEETSPOT_LMS_DATA=$CC/lms SWEETSPOT_RUN=$CC/run SWEETSPOT_LOG=$CC/log SWEETSPOT_PATH="$CC/bin:$SWEETSPOT_PATH" \
		SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-lms; $1"
}
lmsfn link_caches
expect "copertine sull'archivio: collegamenti in RAM" "$CC/archivio/.sweetspot-cache/artwork.db $CC/archivio/.sweetspot-cache/imgproxy.db" \
	"$(readlink "$CC/lms/cache/artwork.db") $(readlink "$CC/lms/cache/imgproxy.db")"
expect "cache gia' in RAM spostata sull'archivio" "vecchia" "$(cat "$CC/archivio/.sweetspot-cache/artwork.db")"
lmsfn link_caches
expect "secondo avvio: stessa cache" "vecchia" "$(cat "$CC/lms/cache/artwork.db")"
printf '#!/bin/sh\nexit 0\n' > "$CC/bin/sweetspot-dischi"
rm -f "$CC/lms/cache/artwork.db"
lmsfn link_caches
expect "senza archivio: cache in RAM come prima" "no" "$([ -e "$CC/lms/cache/artwork.db" ] && echo si || echo no)"

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
