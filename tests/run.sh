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
printf "state: RUNNING\n" > "$WEB/proc/asound/card1/pcm0p/sub0/status"
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
out=$(page audio)
case "$out" in *"Percorso originale configurato"*"integrità dei campioni non verificata"*) ok "audio: formato compatibile non certifica i campioni" ;; *) ko "audio integrita'" "Percorso originale configurato, integrita' non verificata" "-" ;; esac
case "$out" in *"esattamente i campioni"*) ko "audio: nessuna prova campioni inventata" "nessuna certificazione" "certificazione presente" ;; *) ok "audio: nessuna prova campioni inventata" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 192000 (192000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"Non bit-perfect"*"96000 Hz"*) ok "audio: frequenza cambiata segnalata" ;; *) ko "audio ricampionato" "Non bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nchannels: 2\nrate: 96000 (96000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio 'VOLUME=software')" in *"Non bit-perfect"*"regolato dal software"*) ok "audio: volume software segnalato" ;; *) ko "audio volume software" "Non bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: DSD_U32_BE\nsubformat: STD\nchannels: 2\nrate: 88200 (88200/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"DSD nativo"*"DSD64"*) ok "audio: DSD64 nativo riconosciuto" ;; *) ko "audio DSD nativo" "DSD64" "-" ;; esac
out=$(page plugin)
case "$out" in *"Riavvia Lyrion ora"*) ok "plugin: richiesta di riavvio mostrata" ;; *) ko "plugin riavvio" "Riavvia Lyrion ora" "-" ;; esac
case "$out" in *"Qobuz"*"Installato"*) ok "plugin: Qobuz installato" ;; *) ko "plugin Qobuz" "Installato" "-" ;; esac
case "$out" in *"Altri plugin installati"*"Altro"*) ok "plugin: plugin fuori catalogo elencati" ;; *) ko "plugin altri" "Altro" "-" ;; esac
case "$(page musica)" in *"1200 brani, 100 album, 80 artisti"*) ok "musica: numeri della libreria" ;; *) ko "musica libreria" "1200 brani" "-" ;; esac
case "$(page musica 'MODALITA=player')" in *"solo player"*) ok "musica: modalita' solo player" ;; *) ko "musica player" "solo player" "-" ;; esac
printf '#!/bin/sh\ncase "$1" in stato) echo "mmcblk0|58|si|" ;; lavoro) cat %s/spazio.lavoro 2>/dev/null ;; esac\nexit 0\n' "$WEB" > "$WEB/bin/sweetspot-spazio"
chmod +x "$WEB/bin/sweetspot-spazio"
case "$(page archivio)" in *"58 GB non usati"*'value="archivio_spazio"'*) ok "archivio: spazio libero del disco di Sweetspot offerto" ;; *) ko "archivio spazio libero" "58 GB non usati" "-" ;; esac
echo "formatta|formattazione" > "$WEB/spazio.lavoro"
case "$(page archivio)" in *"Creazione dell&#39;archivio in corso"*"formattazione"*) ok "archivio: creazione in corso mostrata" ;; *) ko "archivio creazione in corso" "in corso" "-" ;; esac
rm -f "$WEB/bin/sweetspot-spazio" "$WEB/spazio.lavoro"

echo "Scelta dell'archivio dalla pagina web"
mkdir -p "$WEB/actionbin"
cat > "$WEB/actionbin/sweetspot-config" <<'FINTO'
#!/bin/sh
printf '%s\n' "$*" > "$SWEETSPOT_RUN/config.call"
exit "${ARCHIVE_CONFIG_RC:-0}"
FINTO
cat > "$WEB/actionbin/sweetspot-dischi" <<'FINTO'
#!/bin/sh
printf '%s\n' "$*" >> "$SWEETSPOT_RUN/dischi.call"
[ "$1" != archivio ] || echo /media/archivio-finto
exit 0
FINTO
printf '#!/bin/sh\nexit 0\n' > "$WEB/actionbin/sweetspot-nas"
cp "$WEB/actionbin/sweetspot-nas" "$WEB/actionbin/sweetspot-lms"
chmod +x "$WEB/actionbin/"*
archive_action() {
	local body
	body="t=$(cat "$WEB/run/web.token")&a=archivio_scegli&nome=Musica.a"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run \
		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		ARCHIVE_CONFIG_RC=${1:-0} $TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione"
}
printf 'MusicaXa|sdb1|ext4|1G|ro|/media/MusicaXa|UUID=sbagliato\nMusica.a|sdc1|ext4|1G|ro|/media/Musica.a|UUID=corretto\n' > "$WEB/run/dischi.list"
archive_action > /dev/null
expect "archivio web: nome letterale e UUID stabile" "imposta ARCHIVIO UUID=corretto" "$(cat "$WEB/run/config.call")"
sed 's/UUID=corretto/PARTUUID=partizione/' "$WEB/run/dischi.list" > "$WEB/list.tmp"
mv "$WEB/list.tmp" "$WEB/run/dischi.list"
archive_action > /dev/null
expect "archivio web: PARTUUID stabile" "imposta ARCHIVIO PARTUUID=partizione" "$(cat "$WEB/run/config.call")"
rm -f "$WEB/run/dischi.call"
archive_action 2 > /dev/null
expect "archivio web: salvataggio fallito non rimonta" "no" "$([ -e "$WEB/run/dischi.call" ] && echo si || echo no)"
printf 'Musica.a|sdc1|ext4|1G|ro|/media/Musica.a|\n' > "$WEB/run/dischi.list"
rm -f "$WEB/run/config.call"
archive_action > /dev/null
expect "archivio web: identita' ambigua non salvata" "no" "$([ -e "$WEB/run/config.call" ] && echo si || echo no)"
rm -f "$WEB/run/dischi.list"

echo "Diagnostica del percorso"
printf 'buffering\n' > "$WEB/squeezelite.log"
: > "$WEB/proc/mounts"
diag=$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati)
case "$diag" in *"XRUN ALSA registrati|0"*) ok "diagnostica: conta gli XRUN senza certificare la continuita'" ;; *) ko "diagnostica XRUN" "XRUN ALSA registrati|0" "-" ;; esac
case "$diag" in *"nessuna dall'accensione"*) ko "diagnostica: nessuna continuita' inventata" "nessuna certificazione" "certificazione presente" ;; *) ok "diagnostica: nessuna continuita' inventata" ;; esac


# Stato e parametri devono provenire dal medesimo PCM selezionato.
check_page_diag() {
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati
}
audio_params() { # substream frequenza
	mkdir -p "$1"
	printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nchannels: 2\nrate: %s (%s/1)\nbuffer_size: 4096\nperiod_size: 1024\n' "$2" "$2" > "$1/hw_params"
}
no_active() { # scenario HTML|CLI
	case "$2" in *'<h2>In riproduzione</h2>'*|*'Uscita in corso'*|*'Percorso originale configurato'*|*'Uscita diretta'*) ko "$1" "nessuna uscita attiva" "presente" ;; *) ok "$1" ;; esac
}
PCM=$WEB/proc/asound/card1/pcm1p
mkdir -p "$PCM/sub0"
printf '01-01: Selected : playback 1\n' > "$WEB/proc/asound/pcm"
audio_params "$PCM/sub0" 48000
printf 'state: RUNNING\n' > "$PCM/sub0/status"
audio_params "$WEB/proc/asound/card1/pcm0p/sub0" 192000
out=$(page audio); diag=$(check_page_diag)
case "$out" in *'Buffer ALSA'*'DEV=1/sub0: 4096 campioni, periodo 1024'*) ok "audio: buffer del PCM selezionato" ;; *) ko "audio buffer selezionato" "DEV=1/sub0 4096/1024" "-" ;; esac
case "$diag" in *'Buffer ALSA|DEV=1/sub0: 4096 campioni, periodo 1024'*) ok "diagnostica: buffer del PCM selezionato" ;; *) ko "diagnostica buffer selezionato" "DEV=1/sub0 4096/1024" "-" ;; esac
case "$out" in *'Uscita in corso'*'DEV=1/sub0'*'S32_LE, 48000 Hz, 2 canali'*) ok "audio: PCM selezionato, decoy ignorato" ;; *) ko "audio PCM selezionato" "DEV=1/sub0 48000" "-" ;; esac
case "$diag" in *'OK|Uscita in corso|DEV=1/sub0: S32_LE, 48000 Hz, 2 canali, RUNNING'*) ok "diagnostica: stesso endpoint e parametri della pagina" ;; *) ko "diagnostica PCM selezionato" "DEV=1/sub0 48000" "-" ;; esac
printf 'closed\n' > "$PCM/sub0/hw_params"
printf 'closed\n' > "$PCM/sub0/status"
no_active "audio: PCM selezionato chiuso, decoy aperto" "$(page audio)"
no_active "diagnostica: PCM selezionato chiuso, decoy aperto" "$(check_page_diag)"
audio_params "$PCM/sub1" 44100
printf 'state: RUNNING\n' > "$PCM/sub1/status"
case "$(page audio)" in *'Uscita in corso'*'DEV=1/sub1'*'44100 Hz'*) ok "audio: sub1 attivo con sub0 chiuso" ;; *) ko "audio sub1" "DEV=1/sub1 44100" "-" ;; esac
case "$(check_page_diag)" in *'OK|Uscita in corso|DEV=1/sub1: S32_LE, 44100 Hz'*) ok "diagnostica: sub1 attivo" ;; *) ko "diagnostica sub1" "DEV=1/sub1 44100" "-" ;; esac
audio_params "$PCM/sub0" 48000
printf 'state: RUNNING\n' > "$PCM/sub0/status"
no_active "audio: substream multipli ambigui" "$(page audio)"
case "$(check_page_diag)" in *'ATTENZIONE|Uscita audio|'*'AMBIGUOUS'*) ok "diagnostica: ambiguita' segnalata" ;; *) ko "diagnostica ambigua" "ATTENZIONE AMBIGUOUS" "-" ;; esac
rm -rf "$PCM/sub1"
for pcm_state in PREPARED PAUSED OPEN SETUP XRUN SUSPENDED DISCONNECTED DRAINING; do
	printf 'state: %s\n' "$pcm_state" > "$PCM/sub0/status"
	out=$(page audio); diag=$(check_page_diag)
	no_active "audio: $pcm_state non e' riproduzione attiva" "$out"
	no_active "diagnostica: $pcm_state non e' riproduzione attiva" "$diag"
	case "$pcm_state" in XRUN|SUSPENDED|DISCONNECTED) severity=ATTENZIONE ;; *) severity=INFO ;; esac
	case "$diag" in *"$severity|Uscita audio|"*"$pcm_state"*) ok "diagnostica: severita' $pcm_state" ;; *) ko "diagnostica severita' $pcm_state" "$severity" "-" ;; esac
	case "$out" in *"row $severity"*"$pcm_state"*) ok "audio: severita' $pcm_state" ;; *) ko "audio severita' $pcm_state" "$severity" "-" ;; esac
	case "$out" in *'Parametri aperti'*'DEV=1/sub0: S32_LE, 48000 Hz, 2 canali'*) ok "audio: parametri aperti separati in $pcm_state" ;; *) ko "audio parametri $pcm_state" "Parametri aperti 48000" "-" ;; esac
done
rm -f "$PCM/sub0/status"
out=$(page audio); diag=$(check_page_diag)
no_active "audio: stato assente non verificabile" "$out"
case "$diag" in *'ATTENZIONE|Uscita audio|'*'UNVERIFIED'*) ok "diagnostica: stato assente non verificabile" ;; *) ko "diagnostica stato assente" "ATTENZIONE UNVERIFIED" "-" ;; esac
printf 'state: MYSTERY\n' > "$PCM/sub0/status"
out=$(page audio)
no_active "audio: stato sconosciuto non attivo" "$out"
case "$out" in *'row ATTENZIONE'*'UNVERIFIED'*) ok "audio: stato sconosciuto richiede attenzione" ;; *) ko "audio stato sconosciuto" "ATTENZIONE UNVERIFIED" "-" ;; esac
diag=$(check_page_diag)
no_active "diagnostica: stato sconosciuto non attivo" "$diag"
case "$diag" in *'ATTENZIONE|Uscita audio|'*'UNVERIFIED'*) ok "diagnostica: stato sconosciuto richiede attenzione" ;; *) ko "diagnostica stato sconosciuto" "ATTENZIONE UNVERIFIED" "-" ;; esac
printf 'state: RUNNING\n' > "$PCM/sub0/status"
printf 'format: S32_LE\nrate: nonsense\nchannels: 2\nbuffer_size: bad\nperiod_size: 1024\n' > "$PCM/sub0/hw_params"
no_active "audio: parametri malformati non attivi" "$(page audio)"
no_active "diagnostica: parametri malformati non attivi" "$(check_page_diag)"
case "$(page audio)" in *'<div class="k">Buffer ALSA</div>'*) ko "audio: buffer malformato omesso" "assente" "presente" ;; *) ok "audio: buffer malformato omesso" ;; esac
rm -rf "$PCM/sub0"
case "$(page audio)" in *'row ATTENZIONE'*'UNAVAILABLE'*) ok "audio: PCM senza substream non verificabile" ;; *) ko "audio indisponibile" "ATTENZIONE UNAVAILABLE" "-" ;; esac
case "$(check_page_diag)" in *'ATTENZIONE|Uscita audio|'*'UNAVAILABLE'*) ok "diagnostica: PCM senza substream non verificabile" ;; *) ko "diagnostica indisponibile" "ATTENZIONE UNAVAILABLE" "-" ;; esac
rm -rf "$PCM"
rm -f "$WEB/proc/asound/pcm"
audio_params "$WEB/proc/asound/card1/pcm0p/sub0" 96000
printf 'state: RUNNING\n' > "$WEB/proc/asound/card1/pcm0p/sub0/status"
# Il registro e' storico: gli eventi e i recuperi falliti sono righe distinte.
printf '[12:00:00.123456] _output_frames:123 XRUN\n' > "$WEB/squeezelite.log"
case "$(check_page_diag)" in *'ATTENZIONE|XRUN ALSA registrati|1 nel registro'*) ok "XRUN: un evento esatto" ;; *) ko "XRUN evento" "1" "-" ;; esac
printf '[12:00:00] output_thread:123 XRUN recover failed: Broken pipe\n' >> "$WEB/squeezelite.log"
diag=$(check_page_diag)
case "$diag" in *'XRUN ALSA registrati|1 nel registro'*) ok "XRUN: recupero fallito non raddoppia evento" ;; *) ko "XRUN doppio conto" "1" "-" ;; esac
case "$diag" in *'ATTENZIONE|Recuperi XRUN falliti|1 nel registro'*) ok "XRUN: recupero fallito contato a parte" ;; *) ko "XRUN recupero" "1" "-" ;; esac
printf '[12:00:00] output_thread:123 XRUN recover failed: Broken pipe\n' > "$WEB/squeezelite.log"
diag=$(check_page_diag)
case "$diag" in *'XRUN ALSA registrati|0 nel registro'*) ok "XRUN: solo recupero non inventa evento" ;; *) ko "XRUN solo recupero evento" "0" "-" ;; esac
case "$diag" in *'ATTENZIONE|Recuperi XRUN falliti|1 nel registro'*) ok "XRUN: solo recupero richiede attenzione" ;; *) ko "XRUN solo recupero attenzione" "ATTENZIONE 1" "-" ;; esac
printf 'NOTXRUN\nDescrizione XRUN\nXRUN nei commenti\n[12:00:00] other:1 descriptive XRUN\n' > "$WEB/squeezelite.log"
case "$(check_page_diag)" in *'XRUN ALSA registrati|0 nel registro'*) ok "XRUN: sottostringhe incidentali ignorate" ;; *) ko "XRUN incidentale" "0" "-" ;; esac
rm -f "$WEB/squeezelite.log"
diag=$(check_page_diag)
case "$diag" in *'XRUN ALSA registrati|registro non disponibile'*) ok "XRUN: registro assente dichiarato" ;; *) ko "XRUN registro assente" "non disponibile" "-" ;; esac
case "$diag" in *'Recuperi XRUN falliti|registro non disponibile'*) ok "XRUN: recuperi non disponibili senza registro" ;; *) ko "XRUN recuperi assenti" "non disponibile" "-" ;; esac

echo "Correzione ambientale (REW e CamillaDSP)"
MATHAWK=$(command -v gawk || command -v mawk || command -v awk)
DSPE=$WORK/dsp
mkdir -p "$DSPE/run/correzione" "$DSPE/proc/asound/card1"
echo R26 > "$DSPE/proc/asound/card1/id"
printf 'Playback:\n  Interface 1\n    Format: S32_LE\n    Rates: 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000\n  Interface 1\n    Format: DSD_U32_BE\n    Rates: 88200, 176400\n' > "$DSPE/proc/asound/card1/stream0"
cat > "$DSPE/rew.txt" <<'REW'
Filter Settings file

Room EQ V5.31.3
Notes:Diffusore sinistro

Equaliser: Generic
Filter  1: ON  PK       Fc   38,50 Hz  Gain  -6,80 dB  Q  6,500
Filter  2: ON  PK       Fc   63.30 Hz  Gain  -9.20 dB  Q  4.900
Filter  3: ON  PK       Fc   112.0 Hz  Gain   2.50 dB  Q  3.000
Filter  4: ON  LSC      Fc   80.00 Hz  Gain   1.50 dB  Q  0.707
Filter  5: ON  HS 6dB   Fc   8.00 kHz  Gain  -1.00 dB
Filter  6: OFF PK       Fc   200.0 Hz  Gain  -3.00 dB  Q  2.000
Filter  7: ON  None
Filter  8: ON  PK       Fc   245.0 Hz  Gain  -3.00 dB  BW Oct 0.333
REW
printf 'Filter  1: ON  PK  Fc 41.00 Hz  Gain -5.50 dB  Q 5.000\r\nFilter  2: ON  NO  Fc 50.00 Hz\r\nFilter  3: ON  XYZ  Fc 50.00 Hz\r\nFilter  4: ON  PK  Fc 25000 Hz  Gain -3.00 dB  Q 2.000\r\n' > "$DSPE/rew-errori.txt"
dsp() { # impostazioni comando...
	printf '%s\n' "$1" > "$DSPE/s.txt"
	shift
	SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_AWK=$MATHAWK \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_ASOUND=$DSPE/asound.conf \
		SWEETSPOT_CAMILLADSP=$DSPE/camilladsp-assente \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $DSPE/s.txt; . $OVERLAY/usr/bin/sweetspot-dsp" sh "$@"
}
expect "filtri di REW (virgole, kHz, spenti, larghezza in ottave)" \
	"Peaking 38.5 -6.8 q 6.5|Peaking 63.3 -9.2 q 4.9|Peaking 112 2.5 q 3|Lowshelf 80 1.5 q 0.707|HighshelfFO 8000 -1 none 0|Peaking 245 -3 bandwidth 0.333" \
	"$(dsp '' leggi "$DSPE/rew.txt" | tr '\n' '|' | sed 's/|$//')"
expect "righe sbagliate segnalate" "errore|3|errore|4|1" \
	"$(dsp '' leggi "$DSPE/rew-errori.txt" | grep '^errore' | cut -d'|' -f1-2 | tr '\n' '|')$(dsp '' leggi "$DSPE/rew-errori.txt" > /dev/null; echo $?)"
cp "$DSPE/rew.txt" "$DSPE/run/correzione/sinistro.txt"
expect "attenuazione conservativa dei filtri" "-4.5" "$(dsp '' guadagno)"
expect "curva: 151 punti da 20 Hz" "151 20.0 1.36 1.36" "$(dsp '' risposta | awk 'NR == 1 { f = $0 } END { print NR, f }')"
printf '63.3\n1000\n' > "$DSPE/griglia"
expect "curva uguale alle formule di riferimento" "63.3 -8.12|1000 -0.02" \
	"$(dsp '' leggi "$DSPE/rew.txt" | SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-dsp; $MATHAWK \"\$RESPONSE_AWK\" $DSPE/griglia -" | tr '\n' '|' | sed 's/|$//')"
expect "correzione spenta di serie" "1" "$(dsp '' attiva; echo $?)"
expect "dispositivo della correzione" "sweetspot_correzione" "$(dsp 'CORREZIONE=si' prepara 1)"
yml=$(cat "$DSPE/run/camilladsp.yml")
expect "CamillaDSP: uscita sul DAC a 32 bit" "2" "$(printf '%s\n' "$yml" | grep -c -e 'device: "hw:CARD=R26,DEV=0"' -e 'format: S32_LE' | head -n 1 | sed 's/3/2/')"
expect "CamillaDSP: 12 filtri e l'attenuazione" "12 -4.5" "$(printf '%s\n' "$yml" | grep -c 'type: Biquad') $(printf '%s\n' "$yml" | sed -n 's/^      gain: //p' | head -n 1)"
expect "CamillaDSP: ingresso dal plugin" "type: Stdin" "$(printf '%s\n' "$yml" | grep -o 'type: Stdin')"
expect "ALSA: frequenze del DAC fino a 384 kHz" "rates = [ 44100 48000 88200 96000 176400 192000 352800 384000 ]" \
	"$(grep -o 'rates = \[.*\]' "$DSPE/asound.conf")"
dsp 'CORREZIONE=confronto' prepara 1 > /dev/null
expect "confronto a pari volume: solo l'attenuazione" "0 -4.5" \
	"$(grep -c 'type: Biquad' "$DSPE/run/camilladsp.yml") $(sed -n 's/^      gain: //p' "$DSPE/run/camilladsp.yml")"
printf 'Playback:\n  Interface 1\n    Format: S16_LE\n    Rates: 48000\n' > "$DSPE/proc/asound/card1/stream0"
dsp 'CORREZIONE=si' prepara 1 > /dev/null
expect "DAC a 16 bit: dither" "format: S16_LE|dither 3" \
	"$(grep -o 'format: S16_LE' "$DSPE/run/camilladsp.yml" | tail -n 1)|dither $(grep -c 'dither' "$DSPE/run/camilladsp.yml")"
if command -v camilladsp > /dev/null; then
	if camilladsp -c "$DSPE/run/camilladsp.yml" > /dev/null 2>&1; then ok "configurazione accettata da CamillaDSP"; else ko "camilladsp -c" "valida" "rifiutata"; fi
fi
mkdir -p "$DSPE/chiavetta/sweetspot-dati"
cp "$DSPE/rew.txt" "$DSPE/nuovo.txt"
SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/nuovo.txt" "" ; rc=$?
expect "filtri salvati sulla chiavetta, cartella propria" "0|$(wc -c < "$DSPE/rew.txt" | tr -d ' ')|no" \
	"$rc|$(wc -c < "$DSPE/chiavetta/correzione-ambientale/sinistro.txt" | tr -d ' ')|$([ -f "$DSPE/chiavetta/correzione-ambientale/destro.txt" ] && echo si || echo no)"
SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/run/correzione/sinistro.txt" ""
expect "salvare sopra lo stesso file non lo svuota" "$(wc -c < "$DSPE/rew.txt" | tr -d ' ')" "$(wc -c < "$DSPE/run/correzione/sinistro.txt" | tr -d ' ')"
ln -sf "$OVERLAY/usr/bin/sweetspot-dsp" "$WEB/bin/sweetspot-dsp"
mkdir -p "$WEB/run/correzione"
out=$(SWEETSPOT_AWK=$MATHAWK page correzione)
case "$out" in *"Nessun filtro"*"</html>") ok "pagina correzione senza filtri" ;; *) ko "pagina correzione vuota" "Nessun filtro" "$(printf '%s' "$out" | tail -n 3)" ;; esac
cp "$DSPE/rew.txt" "$WEB/run/correzione/sinistro.txt"
out=$(SWEETSPOT_AWK=$MATHAWK page correzione 'CORREZIONE=si')
case "$out" in *"Correzione accesa"*"6 filtri sul sinistro, 6 sul destro"*"attenuazione di 4,5 dB"*) ok "pagina correzione: stato e attenuazione" ;; *) ko "pagina correzione accesa" "Correzione accesa" "$(printf '%s' "$out" | grep -o 'Correzione[^<]*' | head -3)" ;; esac
expect "pagina correzione: curve sinistra e destra" "2" "$(printf '%s' "$out" | grep -o '<polyline' | wc -l | tr -d ' ')"
echo si > "$WEB/run/correzione.attiva"
printf 'access: RW_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 96000 (96000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio 'CORREZIONE=si')" in *"Correzione ambientale"*"virgola mobile"*) ok "audio: correzione indicata al posto del bit-perfect" ;; *) ko "audio correzione" "Correzione ambientale" "-" ;; esac
rm -f "$WEB/run/correzione.attiva"

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
		SWEETSPOT_CHIAVE_FIRMA=${UPD_PUB:-$UPD/nessuna-chiave.pub} SWEETSPOT_TEST=cli SWEETSPOT_ALLOW_UNSIGNED=1 \
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

if command -v minisign > /dev/null; then
	echo "Aggiornamenti firmati"
	mkdir -p "$UPD/chiavi"
	minisign -G -W -p "$UPD/chiavi/ok.pub" -s "$UPD/chiavi/ok.key" > /dev/null 2>&1
	minisign -G -W -p "$UPD/chiavi/altra.pub" -s "$UPD/chiavi/altra.key" > /dev/null 2>&1
	firma() { # chiave commento
		minisign -S -s "$UPD/chiavi/$1.key" -m "$UPD/pkg/SHA256SUMS" -x "$UPD/pkg/SHA256SUMS.minisig" -t "$2" > /dev/null 2>&1
		tar -C "$UPD/pkg" -rf "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar" SHA256SUMS.minisig
	}
	echo "BOOT_IMAGE=/bzImage sweetspot.slot=a sweetspot.part=ABCD-1234" > "$UPD/proc/cmdline"
	setenv slot=a prova= tentato=
	PKG=$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar
	mkpkg v2.0.0 x86_64
	UPD_PUB=$UPD/chiavi/ok.pub upd _lavoro file "$PKG"
	expect "pacchetto senza firma rifiutato" "errore|pacchetto non firmato: non è un aggiornamento ufficiale" "$(cat "$UPD/run/aggiornamento/stato")"
	mkpkg v2.0.0 x86_64; firma ok "Sweetspot v2.0.0 x86_64"
	UPD_PUB=$UPD/chiavi/ok.pub upd _lavoro file "$PKG"
	expect "pacchetto firmato accettato" "pronto|v2.0.0" "$(cat "$UPD/run/aggiornamento/stato")"
	mkpkg v2.0.1 x86_64; firma altra "Sweetspot v2.0.1 x86_64"
	UPD_PUB=$UPD/chiavi/ok.pub upd _lavoro file "$PKG"
	expect "firma con un'altra chiave rifiutata" "errore|firma non valida: il pacchetto è stato alterato o non è ufficiale" "$(cat "$UPD/run/aggiornamento/stato")"
	mkpkg v2.0.1 x86_64; firma ok "Sweetspot v1.0.0 x86_64"
	UPD_PUB=$UPD/chiavi/ok.pub upd _lavoro file "$PKG"
	expect "firma di un'altra versione rifiutata" "errore|la firma appartiene a un altro pacchetto" "$(cat "$UPD/run/aggiornamento/stato")"
	# Pacchetto firmato e poi alterato: SHA256SUMS cambiato dopo la firma.
	mkpkg v2.0.2 x86_64
	minisign -S -s "$UPD/chiavi/ok.key" -m "$UPD/pkg/SHA256SUMS" -x "$UPD/pkg/SHA256SUMS.minisig" -t "Sweetspot v2.0.2 x86_64" > /dev/null 2>&1
	echo "rootfs alterato" > "$UPD/pkg/rootfs.cpio.zst"
	(cd "$UPD/pkg" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
	tar -C "$UPD/pkg" -cf "$PKG" SHA256SUMS SHA256SUMS.minisig versione architettura bzImage rootfs.cpio.zst
	UPD_PUB=$UPD/chiavi/ok.pub upd _lavoro file "$PKG"
	expect "pacchetto alterato dopo la firma rifiutato" "errore|firma non valida: il pacchetto è stato alterato o non è ufficiale" "$(cat "$UPD/run/aggiornamento/stato")"
	rm -f "$UPD/pkg/SHA256SUMS.minisig"
fi

echo "Raspberry Pi"
PI=$WORK/rpi
mkdir -p "$PI/proc/device-tree/chosen/bootloader" "$PI/run" "$PI/sys/devices/system/cpu/smt" "$PI/stick/a/overlays" \
	"$PI/stick/boot/versioni" "$PI/media/USB" "$PI/avvio/firmware" "$PI/bin" "$PI/pkg"
echo rpi > "$PI/scheda"
export SWEETSPOT_SCHEDA_FILE=$PI/scheda
echo 0-3 > "$PI/sys/devices/system/cpu/online"
echo notsupported > "$PI/sys/devices/system/cpu/smt/control"
for c in 0 1 2 3; do mkcpu "$PI" $c "$c"; done
printf 'MemTotal:        3884000 kB\n' > "$PI/proc/meminfo"
printf 'processor\t: 0\nBogoMIPS\t: 108.00\nFeatures\t: fp asimd evtstrm crc32 cpuid\nCPU implementer\t: 0x41\n' > "$PI/proc/cpuinfo"
printf 'Raspberry Pi 4 Model B Rev 1.5\000' > "$PI/proc/device-tree/model"
printf '\000\000\000\000' > "$PI/proc/device-tree/chosen/bootloader/tryboot"
echo "coherent_pool=1M 8250.nr_uarts=0 console=tty1 quiet loglevel=3 usbcore.autosuspend=-1 audit=0 panic=10 sweetspot.slot=a" > "$PI/proc/cmdline"
echo "v1.0.0 (2026-10-01)" > "$PI/version"
cp "$ROOT/board/sweetspot/rpi/config.txt" "$PI/avvio/config.txt"
echo "firmware nuovo" > "$PI/avvio/firmware/start4.elf"
echo "firmware vecchio" > "$PI/stick/start4.elf"
echo A-kernel > "$PI/stick/a/Image.gz"
echo A-rootfs > "$PI/stick/a/rootfs.cpio.zst"
echo A-dtb > "$PI/stick/a/bcm2711-rpi-4-b.dtb"
echo v1.0.0 > "$PI/stick/boot/versioni/a"
pi() { run "$PI" "SWEETSPOT_STICK_DIR=$PI/stick; STICK_MNT=$PI/stick; SWEETSPOT_AVVIO=$PI/avvio; $*"; }
expect "scheda e avvio del Pi" "rpi rpi Image.gz $PI/stick/b $PI/stick/sweetspot-avvio.env" \
	"$(pi 'echo $(board) $(boot_type) $(kernel_file) $(slot_dir $STICK_MNT b) $(boot_env)')"
expect "modello dall'albero dei dispositivi" "Raspberry Pi 4 Model B Rev 1.5" "$(pi cpu_model)"
expect "non e' un avvio di prova (tryboot)" "no" "$(pi 'rpi_tryboot && echo si || echo no')"
pi "rpi_boot_config $PI/stick/config.txt a"
expect "config.txt dal modello, copia A" "os_prefix=a/|include sweetspot-scheda.txt" \
	"$(grep -E '^(os_prefix|include)' "$PI/stick/config.txt" | tr '\n' '|' | sed 's/|$//')"
pi "rpi_cmdline a 'cpuidle.off=1 isolcpus=managed_irq,domain,2,3 sweetspot.tune=12345678'" > "$PI/stick/a/cmdline.txt"
expect "parametri adattati letti da cmdline.txt" "cpuidle.off=1 isolcpus=managed_irq,domain,2,3 sweetspot.tune=12345678" "$(pi 'rpi_tune a')"
expect "scheda I2S in sweetspot-scheda.txt" "dtparam=i2s=on|dtoverlay=hifiberry-dacplus" \
	"$(pi 'rpi_scheda_txt hifiberry-dacplus' | grep -v '^#' | tr '\n' '|' | sed 's/|$//')"
expect "nessuna scheda I2S: file senza overlay" "" "$(pi 'rpi_scheda_txt ""' | grep -v '^#')"
p=$(SWEETSPOT_SCHEDA_FILE=$PI/scheda tune "$PI")
expect "parametri del Pi" "cpuidle.off=1 isolcpus=managed_irq,domain,2,3 nohz_full=2,3 rcu_nocbs=2,3 irqaffinity=0,1" "${p% sweetspot.tune=*}"
printf 'SCHEDA_I2S=hifiberry-dacplus\n' > "$WORK/i2s.txt"
run "$PI" "config_build $WORK/i2s.txt" >/dev/null
p=$(tune "$PI")
case "$p" in *" sweetspot.i2s=hifiberry-dacplus "*) ok "la scheda I2S entra nei parametri (un solo riavvio)" ;; *) ko "scheda I2S nei parametri" "... sweetspot.i2s=hifiberry-dacplus ..." "$p" ;; esac
# Schede audio del Pi: HDMI (vc4hdmi0) e la scheda I2S
mkdir -p "$PI/proc/asound/card0" "$PI/proc/asound/card1"
echo vc4hdmi0 > "$PI/proc/asound/card0/id"
echo sndrpihifiberry > "$PI/proc/asound/card1/id"
cat > "$PI/proc/asound/cards" <<'C'
 0 [vc4hdmi0       ]: vc4-hdmi - vc4-hdmi-0
                      vc4-hdmi-0
 1 [sndrpihifiberry]: RPi-simple - snd_rpi_hifiberry_dacplus
                      snd_rpi_hifiberry_dacplus
C
expect "DAC I2S trovato (non l'HDMI)" "1 snd_rpi_hifiberry_dacplus" "$(pi 'c=$(dac_find); echo $c $(dac_name $c)')"
printf 'SCHEDA_I2S=\n' > "$WORK/i2s.txt"
run "$PI" "config_build $WORK/i2s.txt" >/dev/null
expect "senza scheda I2S scelta si cerca solo il DAC USB" "" "$(pi dac_find)"
# Aggiornamento sul Pi: la copia B e' una cartella intera, provata con tryboot
pi "grubenv_set $PI/stick/sweetspot-avvio.env slot=a"
mkpkg_pi() { # versione scheda
	rm -rf "$PI/pkg"; mkdir -p "$PI/pkg/overlays"
	echo "kernel $1" > "$PI/pkg/Image.gz"
	echo "rootfs $1" > "$PI/pkg/rootfs.cpio.zst"
	echo "dtb $1" > "$PI/pkg/bcm2711-rpi-4-b.dtb"
	echo "overlay $1" > "$PI/pkg/overlays/hifiberry-dacplus.dtbo"
	echo "$1" > "$PI/pkg/versione"
	echo "$2" > "$PI/pkg/architettura"
	(cd "$PI/pkg" && find . -type f | sed 's|^\./||' | sort | while read -r f; do sha256sum "$f"; done > ../SHA256SUMS && mv ../SHA256SUMS .)
	tar -C "$PI/pkg" -cf "$PI/media/USB/sweetspot-rpi-aggiornamento.tar" .
}
updpi() {
	local s=$1
	shift
	SWEETSPOT_SYSFS=$PI/sys SWEETSPOT_PROCFS=$PI/proc SWEETSPOT_RUN=$PI/run SWEETSPOT_LOG=$PI/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_STICK_DIR=$PI/stick \
		SWEETSPOT_MEDIA=$PI/media SWEETSPOT_VERSION_FILE=$PI/version SWEETSPOT_AVVIO=$PI/avvio \
		SWEETSPOT_WGET=$UPD/bin/wget-ok SWEETSPOT_CONFERMA_ATTESA=2 SWEETSPOT_RCK=$PI/bin/rcK SWEETSPOT_REBOOT=$PI/bin/reboot \
		SWEETSPOT_CHIAVE_FIRMA=${PI_PUB:-$PI/nessuna-chiave} SWEETSPOT_TEST=cli SWEETSPOT_ALLOW_UNSIGNED=1 \
		SWEETSPOT_PATH="$PI/bin:$SWEETSPOT_PATH" $TEST_SH "$OVERLAY/usr/bin/$s" "$@"
}
penv() { pi "grubenv_get $PI/stick/sweetspot-avvio.env $1"; }
mkpkg_pi v1.1.0 rpi
expect "pacchetto del Pi trovato" "$PI/media/USB/sweetspot-rpi-aggiornamento.tar" "$(updpi sweetspot-aggiorna pacchetti)"
updpi sweetspot-aggiorna _lavoro file "$PI/media/USB/sweetspot-rpi-aggiornamento.tar"
expect "aggiornamento del Pi pronto" "pronto|v1.1.0" "$(cat "$PI/run/aggiornamento/stato")"
expect "copia B completa (kernel, sistema, albero, overlay)" "kernel v1.1.0|rootfs v1.1.0|dtb v1.1.0|overlay v1.1.0|v1.1.0" \
	"$(cat "$PI/stick/b/Image.gz")|$(cat "$PI/stick/b/rootfs.cpio.zst")|$(cat "$PI/stick/b/bcm2711-rpi-4-b.dtb")|$(cat "$PI/stick/b/overlays/hifiberry-dacplus.dtbo")|$(cat "$PI/stick/boot/versioni/b")"
expect "nella copia niente file del pacchetto" "no" "$([ -e "$PI/stick/b/SHA256SUMS" ] || [ -e "$PI/stick/b/versione" ] && echo si || echo no)"
expect "riga di comando della copia B con i parametri adattati" \
	"console=tty1 quiet loglevel=3 usbcore.autosuspend=-1 audit=0 panic=10 sweetspot.slot=b cpuidle.off=1 isolcpus=managed_irq,domain,2,3 sweetspot.tune=12345678" \
	"$(cat "$PI/stick/b/cmdline.txt")"
expect "tryboot.txt prova la copia B, config.txt resta su A" "os_prefix=b/|os_prefix=a/" \
	"$(grep '^os_prefix' "$PI/stick/tryboot.txt")|$(grep '^os_prefix' "$PI/stick/config.txt")"
expect "stato: prova della copia B" "a|b" "$(penv slot)|$(penv prova)"
expect "copia A intatta" "A-kernel" "$(cat "$PI/stick/a/Image.gz")"
# Riavvio dalla pagina: servizi fermati, poi riavvio "tryboot" del firmware
printf '#!/bin/sh\necho fermati > %s/fermati\n' "$PI" > "$PI/bin/rcK"
printf '#!/bin/sh\necho "$1" > %s/riavvio\n' "$PI" > "$PI/bin/sweetspot-reboot2"
printf '#!/bin/sh\necho normale > %s/riavvio\n' "$PI" > "$PI/bin/reboot"
chmod +x "$PI/bin"/*
updpi sweetspot-riavvia
expect "riavvio con tryboot dopo aver fermato i servizi" "fermati|0 tryboot|b|" \
	"$(cat "$PI/fermati" 2>/dev/null)|$(cat "$PI/riavvio")|$(penv tentato)|$(penv prova)"
rm -f "$PI/fermati"
updpi sweetspot-riavvia
expect "riavvio normale senza prove in sospeso" "normale|" "$(cat "$PI/riavvio")|$(cat "$PI/fermati" 2>/dev/null)"
# Parte la copia B (tryboot) e si conferma
echo "coherent_pool=1M console=tty1 quiet sweetspot.slot=b" > "$PI/proc/cmdline"
printf '\000\000\000\001' > "$PI/proc/device-tree/chosen/bootloader/tryboot"
expect "avvio di prova riconosciuto" "si" "$(pi 'rpi_tryboot && echo si || echo no')"
updpi sweetspot-aggiorna conferma
expect "la copia B si conferma ed e' quella in uso" "b|" "$(penv slot)|$(penv tentato)"
expect "config.txt ora avvia la copia B" "os_prefix=b/" "$(grep '^os_prefix' "$PI/stick/config.txt")"
expect "firmware del Pi 4 aggiornato" "firmware nuovo" "$(cat "$PI/stick/start4.elf")"
# Secondo aggiornamento (copia A) che non parte: si torna a B
rm -f "$PI/run/aggiornamento/riuscita"
printf '\000\000\000\000' > "$PI/proc/device-tree/chosen/bootloader/tryboot"
mkpkg_pi v1.2.0 rpi
updpi sweetspot-aggiorna _lavoro file "$PI/media/USB/sweetspot-rpi-aggiornamento.tar"
expect "secondo aggiornamento nella copia A, prova con tryboot" "kernel v1.2.0|a|os_prefix=a/" \
	"$(cat "$PI/stick/a/Image.gz")|$(penv prova)|$(grep '^os_prefix' "$PI/stick/tryboot.txt")"
expect "copia A riscritta per intero" "dtb v1.2.0|sweetspot.slot=a" 	"$(cat "$PI/stick/a/bcm2711-rpi-4-b.dtb")|$(grep -o 'sweetspot.slot=[ab]' "$PI/stick/a/cmdline.txt")"
pi "grubenv_set $PI/stick/sweetspot-avvio.env prova= tentato=a"
updpi sweetspot-aggiorna conferma
expect "versione non partita: si resta su B" "b||os_prefix=b/" "$(penv slot)|$(penv tentato)|$(grep '^os_prefix' "$PI/stick/config.txt")"
expect "versione non partita segnalata" "fallita=v1.2.0" "$(updpi sweetspot-aggiorna stato | grep '^fallita=')"
mkpkg_pi v1.3.0 x86_64
updpi sweetspot-aggiorna _lavoro file "$PI/media/USB/sweetspot-rpi-aggiornamento.tar"
expect "pacchetto per PC rifiutato sul Pi" "errore|pacchetto per un altro tipo di computer (x86_64)" "$(cat "$PI/run/aggiornamento/stato")"
if command -v minisign > /dev/null; then
	mkpkg_pi v1.4.0 rpi
	minisign -S -s "$UPD/chiavi/ok.key" -m "$PI/pkg/SHA256SUMS" -x "$PI/pkg/SHA256SUMS.minisig" -t "Sweetspot v1.4.0 rpi" > /dev/null 2>&1
	tar -C "$PI/pkg" -rf "$PI/media/USB/sweetspot-rpi-aggiornamento.tar" SHA256SUMS.minisig
	PI_PUB=$UPD/chiavi/ok.pub updpi sweetspot-aggiorna _lavoro file "$PI/media/USB/sweetspot-rpi-aggiornamento.tar"
	expect "pacchetto del Pi firmato accettato" "pronto|v1.4.0|no" \
		"$(cat "$PI/run/aggiornamento/stato")|$([ -e "$PI/stick/a/SHA256SUMS.minisig" ] && echo si || echo no)"
fi
expect "installazione sul disco interno non disponibile sul Pi" "non serve su questo computer" \
	"$(SWEETSPOT_SYSFS=$PI/sys SWEETSPOT_PROCFS=$PI/proc SWEETSPOT_RUN=$PI/run SWEETSPOT_LOG=$PI/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-installa; do_start sda si" 2>&1)"
unset SWEETSPOT_SCHEDA_FILE

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

echo "Archivio nello spazio libero del disco di avvio"
SP=$WORK/spazio
SPD=$SP/sys/devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0
mkdir -p "$SPD/queue" "$SPD/mmcblk0p1" "$SP/sys/class/block" "$SP/sys/block" "$SP/dev" "$SP/run" "$SP/proc" "$SP/bin"
echo "console=tty1 sweetspot.slot=a" > "$SP/proc/cmdline"
echo 512 > "$SPD/queue/logical_block_size"
ln -s ../devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0 "$SP/sys/block/mmcblk0"
ln -s ../../devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0/mmcblk0p1 "$SP/sys/class/block/mmcblk0p1"
sp() { # comando (funzioni di sweetspot-spazio)
	SWEETSPOT_SYSFS=$SP/sys SWEETSPOT_PROCFS=$SP/proc SWEETSPOT_RUN=$SP/run SWEETSPOT_LOG=$SP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_DEV=$SP/dev \
		SWEETSPOT_STICK_DEV=$SP/dev/mmcblk0p1 SWEETSPOT_TEST=1 SWEETSPOT_PATH="$SP/bin:$SWEETSPOT_PATH" \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-spazio; $1"
}
# Scheda SD come quella scritta dall'immagine del Pi: partizione FAT32 da
# 1 GiB a 4 MiB, il resto libero.
mkcard() { # GiB [tipo1] [voce2]
	rm -f "$SP/dev/mmcblk0" "$SP/dev/mmcblk0p2"
	truncate -s "$1G" "$SP/dev/mmcblk0"
	echo $(($1 * 2097152)) > "$SPD/size"
	head -c 440 /dev/zero | tr '\0' '\372' | dd of="$SP/dev/mmcblk0" conv=notrunc 2>/dev/null
	if [ -n "${3:-}" ]; then e2="0 $3 3000000 1000000"; else e2="0 0 0 0"; fi
	sp "{ mbr_entry 128 ${2:-12} 8192 2097152; mbr_entry $e2; mbr_entry 0 0 0 0; mbr_entry 0 0 0 0; printf '\\125\\252'; } |
		dd of=$SP/dev/mmcblk0 bs=1 seek=446 conv=notrunc 2>/dev/null"
}
mkcard 32
expect "tabella letta" "12 8192 2097152|0 0 0" "$(sp "mbr_read $SP/dev/mmcblk0" | sed -n '1p;2p' | tr '\n' '|' | sed 's/|$//')"
expect "scheda da 32 GB: 30 GB liberi per l'archivio" "mmcblk0|30|si|" "$(sp examine)"
expect "disco da 4 TB: fino al limite della tabella MBR" "2105344 4292859904 4292859904" "$(sp 'free_plan 8589934592 8192 2097152')"
mkcard 4
expect "scheda da 4 GB: spazio insufficiente" "mmcblk0|2|no|spazio libero insufficiente" "$(sp examine)"
mkcard 32 238
expect "tabella GPT non toccata" "mmcblk0|0|no|tabella delle partizioni GPT" "$(sp examine)"
mkcard 32 12 131
expect "disco con altre partizioni non toccato" "mmcblk0|0|no|il disco ha gia' altre partizioni" "$(sp examine)"
# Creazione, con il kernel e la formattazione simulati
mkcard 32
printf '#!/bin/sh\necho "$*" > %s/partizione.args\n: > %s/dev/mmcblk0p2\n' "$SP" "$SP" > "$SP/bin/sweetspot-partizione"
printf '#!/bin/sh\necho "$*" > %s/mkfs.args\n' "$SP" > "$SP/bin/mkfs.ext4"
printf '#!/bin/sh\necho "$*" >> %s/config.args\n' "$SP" > "$SP/bin/sweetspot-config"
printf '#!/bin/sh\ncase "$1" in archivio) [ -f %s/montato ] && echo "/media/Sweetspot Musica" ;; monta) : > %s/montato ;; esac\nexit 0\n' "$SP" "$SP" > "$SP/bin/sweetspot-dischi"
printf '#!/bin/sh\nexit 0\n' > "$SP/bin/sweetspot-nas"
printf '#!/bin/sh\nexit 0\n' > "$SP/bin/sweetspot-lms"
chmod +x "$SP/bin"/*
head -c 512 "$SP/dev/mmcblk0" | head -c 446 | od -An -tx1 > "$SP/prima"
sp job
expect "archivio creato" "finita|30 GB" "$(cat "$SP/run/spazio/stato")"
expect "seconda voce della tabella: Linux nello spazio libero" "12 8192 2097152|131 2105344 65001472|0 0 0|0 0 0" \
	"$(sp "mbr_read $SP/dev/mmcblk0" | tr '\n' '|' | sed 's/|$//')"
expect "settore di avvio intatto" "$(cat "$SP/prima")" "$(head -c 446 "$SP/dev/mmcblk0" | od -An -tx1)"
expect "partizione comunicata al kernel" "$SP/dev/mmcblk0 2 2105344 65001472" "$(cat "$SP/partizione.args")"
expect "formattazione ext4 senza lavoro in sottofondo" "-F -q -m 0 -i 524288 -E lazy_itable_init=0,lazy_journal_init=0 -L Sweetspot Musica $SP/dev/mmcblk0p2" "$(cat "$SP/mkfs.args")"
expect "diventa l'archivio" "imposta ARCHIVIO Sweetspot Musica" "$(cat "$SP/config.args")"
if command -v sfdisk > /dev/null; then
	expect "tabella letta da sfdisk" "start=8192,size=2097152,type=c,bootable start=2105344,size=65001472,type=83" \
		"$(sfdisk -d "$SP/dev/mmcblk0" 2>/dev/null | grep start= | sed -n 's/.*: //p' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
fi
expect "dopo la creazione non si offre piu'" "mmcblk0|0|no|il disco ha gia' altre partizioni" "$(sp examine)"
expect "con un archivio gia' presente non si crea" "c'e' gia' un archivio musicale" "$(sp do_create)"
rm -f "$SP/montato"
expect "disco non piu' adatto: nessuna creazione" "il disco ha gia' altre partizioni" "$(sp do_create)"

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
[ "$FAIL" -eq 0 ] || exit 1
sh "$ROOT/tests/audio-quality.sh" || exit 1
sh "$ROOT/tests/ops-safety.sh" || exit 1
python3 "$ROOT/tests/audio-verification.py" || exit 1
python3 "$ROOT/tests/prova-audio-tests.py" || exit 1
python3 "$ROOT/tests/squeezelite-dff-padding.py" || exit 1
python3 "$ROOT/tests/release-gates.py"
