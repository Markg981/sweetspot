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
[ -n "$SWEETSPOT_RUN" ] && printf '%s\n' "$d" >> "$SWEETSPOT_RUN/wget.post"
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
case "$out" in *'name="dac"'*'<option value="auto" selected>'*'<option value="292b:0a26">GUSTARD R26 (USB 292b:0a26)</option>'*) ok "audio: scelta del DAC principale tra i DAC USB collegati" ;; *) ko "audio DAC principale" "auto selezionato e R26 per identificativo USB" "-" ;; esac
case "$(page audio 'DAC=R26')" in *'<option value="r26" selected>r26 (da sweetspot.txt)</option>'*) ok "audio: DAC scritto a mano in sweetspot.txt resta scelto" ;; *) ko "audio DAC da sweetspot.txt" "opzione r26 selezionata" "-" ;; esac
case "$out" in *"esattamente i campioni"*) ko "audio: nessuna prova campioni inventata" "nessuna certificazione" "certificazione presente" ;; *) ok "audio: nessuna prova campioni inventata" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 192000 (192000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"Non bit-perfect"*"96000 Hz"*) ok "audio: frequenza cambiata segnalata" ;; *) ko "audio ricampionato" "Non bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nchannels: 2\nrate: 96000 (96000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
out=$(page audio 'VOLUME=software')
case "$out" in *"Non bit-perfect"*"abbassato dal software, che tronca i bit bassi senza dither"*) ok "audio: volume software segnalato" ;; *) ko "audio volume software" "Non bit-perfect, senza dither" "-" ;; esac
case "$out" in *'<option value="software" selected'*'Volume software: Squeezelite abbassa i campioni troncando i bit bassi, senza dither'*) ok "audio: volume software spiegato sotto la scelta" ;; *) ko "audio nota volume software" "nota senza dither" "-" ;; esac
case "$(page audio 'VOLUME=fisso')" in *'Volume software: Squeezelite'*) ko "audio: nessuna nota con il volume fisso" "nessuna nota" "nota presente" ;; *) ok "audio: nessuna nota con il volume fisso" ;; esac
volcheck() { # impostazioni
	printf '%s\n' "$1" > "$WEB/s.txt"
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" 2>/dev/null | grep '^[A-Z]*|Volume|'
}
expect "stato: volume software e' un avviso" \
	"ATTENZIONE|Volume|dal software: sotto il 100% Squeezelite tronca i bit bassi senza dither, peggio del volume fisso o del DAC" \
	"$(volcheck VOLUME=software)"
expect "stato: volume del DAC resta informativo" \
	"INFO|Volume|regolabile (dac): sotto il 100% il segnale non e' piu' bit-perfect" "$(volcheck VOLUME=dac)"
rm -f "$WEB/s.txt"
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
system_action() { # ascolto
	local body
	body="t=$(cat "$WEB/run/web.token")&a=sistema&nome=Sweetspot&modalita=completa&profilo=bilanciato&ascolto=$1&ssh=no&ottimizzazioni=si"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run \
		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione" > /dev/null
	grep -o 'MODALITA_ASCOLTO [a-z]* PRECARICO [a-z]*' "$WEB/run/config.call"
}
expect "sistema: ascolto puro = lavori sospesi + precarico" "MODALITA_ASCOLTO si PRECARICO si" "$(system_action puro)"
expect "sistema: solo lavori sospesi" "MODALITA_ASCOLTO si PRECARICO no" "$(system_action si)"
expect "sistema: modalita' ascolto spenta" "MODALITA_ASCOLTO no PRECARICO no" "$(system_action no)"
expect "sistema: valore sconosciuto = solo lavori sospesi" "MODALITA_ASCOLTO si PRECARICO no" "$(system_action xyz)"
case "$(page sistema)" in *'<option value="puro" selected'*) ok "sistema: ascolto puro di serie" ;; *) ko "sistema ascolto puro" "puro selezionato" "-" ;; esac
case "$(page sistema 'PRECARICO=no')" in *'<option value="si" selected'*) ok "sistema: senza precarico solo lavori sospesi" ;; *) ko "sistema ascolto si" "si selezionato" "-" ;; esac
case "$(page sistema "$(printf 'MODALITA_ASCOLTO=no\nPRECARICO=si')")" in *'<option value="no" selected'*) ok "sistema: ascolto spento" ;; *) ko "sistema ascolto no" "no selezionato" "-" ;; esac


echo "Password delle pagine e impostazioni iniziali"
acc() { # impostazioni
	printf '%s\n' "$1" > "$WEB/s.txt"
	SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c "killall() { :; }; . $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; set -- applica; . $OVERLAY/usr/bin/sweetspot-accesso"
	cat "$WEB/run/httpd.conf"
}
expect "pagine aperte senza password" "" "$(acc '')"
expect "impronta salvata usata cosi' com'e'" '/:admin:$1$abcd$efgh' "$(acc 'PASSWORD_WEB=$1$abcd$efgh' | tail -n 1)"
case "$(acc 'PASSWORD_WEB=segreta' | tail -n 1)" in '/:admin:$1$'*) ok "password in chiaro trasformata in impronta" ;; *) ko "password in chiaro" '/:admin:$1$...' "$(cat "$WEB/run/httpd.conf")" ;; esac
expect "file dell'accesso leggibile solo da root" "600" "$(stat -c %a "$WEB/run/httpd.conf")"
# La pagina vivo resta raggiungibile dall'aggiornamento: utente sweetspot
# con la chiave casuale dell'avvio, regola prima di quella generale.
vivo_key=$(cat "$WEB/run/vivo.chiave")
expect "chiave della pagina vivo: 32 cifre esadecimali, solo root" "32|600" "${#vivo_key}|$(stat -c %a "$WEB/run/vivo.chiave")"
case "$vivo_key" in *[!0-9a-f]*) ko "chiave della pagina vivo" "esadecimale" "$vivo_key" ;; *) ok "chiave della pagina vivo esadecimale" ;; esac
expect "regola della pagina vivo con la chiave, prima di quella generale" "/cgi-bin/vivo:sweetspot:$vivo_key" "$(head -n 1 "$WEB/run/httpd.conf")"
expect "a ogni applicazione una chiave nuova" "diversa" "$(acc 'PASSWORD_WEB=segreta' > /dev/null; [ "$(cat "$WEB/run/vivo.chiave")" != "$vivo_key" ] && echo diversa)"
acc '' > /dev/null
expect "senza password niente chiave della pagina vivo" "no" "$([ -f "$WEB/run/vivo.chiave" ] && echo si || echo no)"
printf '#!/bin/sh\n[ "$1" = hash ] && echo "\\$1\\$prova\\$impronta"\nexit 0\n' > "$WEB/actionbin/sweetspot-accesso"
chmod +x "$WEB/actionbin/sweetspot-accesso"
web_action() { # corpo senza gettone
	local body
	body="t=$(cat "$WEB/run/web.token")&$1"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run \
		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione"
}
rm -f "$WEB/run/config.call"
web_action "a=audio&volume=fisso&dsd=auto&altri_dac=si&dac=292B:0A26&ricampionamento=no&filtro=lineare&frequenza_max=0&buffer=400&periodi=4&pausa_frequenza=0&pausa_dsd=500" > /dev/null
case "$(cat "$WEB/run/config.call")" in *"ALTRI_DAC si DAC 292b:0a26"*) ok "audio: DAC principale salvato per identificativo USB" ;; *) ko "audio DAC salvato" "DAC 292b:0a26" "$(cat "$WEB/run/config.call")" ;; esac
rm -f "$WEB/run/config.call"
out=$(web_action "a=audio&volume=fisso&dsd=auto&altri_dac=no&dac=R26;reboot&ricampionamento=no&filtro=lineare&frequenza_max=0&buffer=400&periodi=4&pausa_frequenza=0&pausa_dsd=500")
case "$out" in *"Location: /cgi-bin/audio?msg=%44%41%43%20%70%72%69%6e%63%69%70%61%6c%65%20%6e%6f%6e%20%76%61%6c%69%64%6f"*) ok "audio: DAC principale non valido rifiutato" ;; *) ko "audio DAC non valido" "rifiutato (DAC principale non valido)" "$out" ;; esac
expect "audio: DAC non valido, niente salvato" "no" "$([ -f "$WEB/run/config.call" ] && echo si || echo no)"
rm -f "$WEB/run/config.call"
web_action "a=sistema&nome=Sweetspot&modalita=completa&profilo=bilanciato&ascolto=si&ssh=no&ottimizzazioni=si&web_password=segreta" > /dev/null
expect "sistema: si salva l'impronta, non la password" '1|0' \
	"$(grep -c 'PASSWORD_WEB $1$prova$impronta' "$WEB/run/config.call")|$(grep -c segreta "$WEB/run/config.call")"
out=$(web_action "a=ripristina")
case "$out" in *"Location: /cgi-bin/sistema"*) ok "ripristino: senza conferma non parte" ;; *) ko "ripristino senza conferma" "torna a sistema" "$out" ;; esac
expect "ripristino: nessuna modifica senza conferma" "0" "$(grep -c ripristina "$WEB/run/config.call")"
web_action "a=ripristina&conferma=si" > /dev/null
expect "ripristino confermato" "ripristina" "$(tail -n 1 "$WEB/run/config.call")"
RS=$WORK/ripristino
mkdir -p "$RS/avvio" "$RS/chiavetta" "$RS/run"
printf 'VOLUME=fisso\r\n' > "$RS/avvio/sweetspot.txt"
printf 'VOLUME=software\r\nPASSWORD_WEB=x\r\n' > "$RS/chiavetta/sweetspot.txt"
SWEETSPOT_RUN=$RS/run SWEETSPOT_LOG=$RS/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	SWEETSPOT_STICK_DIR=$RS/chiavetta SWEETSPOT_AVVIO=$RS/avvio $TEST_SH "$OVERLAY/usr/bin/sweetspot-config" ripristina; rc=$?
expect "ripristino: sweetspot.txt iniziale sulla chiavetta e in memoria" "0|VOLUME=fisso|fisso" \
	"$rc|$(tr -d '\r' < "$RS/chiavetta/sweetspot.txt")|$(sed -n 's/^VOLUME=//p' "$RS/run/sweetspot.conf" | tail -n 1)"
SWEETSPOT_RUN=$RS/run SWEETSPOT_LOG=$RS/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	SWEETSPOT_STICK_DIR=$RS/assente SWEETSPOT_AVVIO=$RS/avvio $TEST_SH "$OVERLAY/usr/bin/sweetspot-config" ripristina; rc=$?
expect "ripristino senza chiavetta: vale solo fino al riavvio" "2" "$rc"
printf 'Musica.a|sdc1|ext4|1G|ro|/media/Musica.a|\n' > "$WEB/run/dischi.list"
rm -f "$WEB/run/config.call"
archive_action > /dev/null
expect "archivio web: identita' ambigua non salvata" "no" "$([ -e "$WEB/run/config.call" ] && echo si || echo no)"
rm -f "$WEB/run/dischi.list"

echo "Credenziali di Lyrion"
# Lyrion protetto: le richieste JSON portano l'intestazione Basic, la CLI
# fa il login prima di iscriversi; senza credenziali niente cambia.
cat > "$WEB/bin/wget-auth" <<'FINTO'
#!/bin/sh
prev=""; for a; do [ "$prev" = --header ] && printf '%s\n' "$a" >> "$SWEETSPOT_RUN/wget.headers"; prev=$a; done
echo '{"result":{"_version":"9.1.1"}}'
FINTO
chmod +x "$WEB/bin/wget-auth"
lmsauth() { # impostazioni
	printf '%s\n' "$1" > "$WEB/s.txt"
	rm -f "$WEB/run/wget.headers"
	SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_WGET=$WEB/bin/wget-auth \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; lms_json '' version '?' > /dev/null"
	grep -c '^Authorization: ' "$WEB/run/wget.headers"
}
expect "Lyrion aperto: nessuna intestazione di autenticazione" "0" "$(lmsauth '')"
expect "Lyrion protetto: Basic con utente e password" "1|Authorization: Basic bWFyY286cGE6c3M=" \
	"$(lmsauth "$(printf 'LYRION_UTENTE=marco\nLYRION_PASSWORD=pa:ss')")|$(grep '^Authorization' "$WEB/run/wget.headers")"
printf 'LYRION_UTENTE=marco\nLYRION_PASSWORD=segreta\n' > "$WEB/s.txt"
clisub() {
	SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; . $OVERLAY/usr/bin/sweetspot-volume; cli_subscribe" | tr '\n' '|' | sed 's/|$//'
}
expect "CLI di Lyrion: login prima dell'iscrizione" "login marco segreta|subscribe mixer,client" "$(clisub)"
printf '' > "$WEB/s.txt"
expect "CLI di Lyrion aperto: solo l'iscrizione" "subscribe mixer,client" "$(clisub)"
rm -f "$WEB/s.txt" "$WEB/run/wget.headers"
printf '' > "$WEB/s.txt"
run "$WEB" "config_build $WEB/s.txt"

echo "Prova DoP guidata"
mkdac "$WEB" no
out=$(page audio)
case "$out" in *"Automatico: il DAC non dichiara il DSD nativo, quindi Lyrion converte i file DSD in PCM sul server, senza provare il DoP"*) ok "audio: DSD automatico senza nativo spiegato" ;; *) ko "audio DSD automatico" "conversione sul server, senza DoP" "-" ;; esac
case "$out" in *"<h2>Prova DoP</h2>"*"Avvia la prova (6 secondi)"*) ok "audio: prova DoP proposta" ;; *) ko "audio prova DoP" "pulsante della prova" "-" ;; esac
case "$out" in *"Com&#39;è andata?"*) ko "audio: esito chiesto solo dopo la prova" "nessun esito" "esito presente" ;; *) ok "audio: esito chiesto solo dopo la prova" ;; esac
case "$(page audio 'VOLUME=software')" in *"Prova non disponibile"*"il volume software altera i campioni"*) ok "audio: prova DoP bloccata dal volume software" ;; *) ko "audio prova DoP volume" "prova non disponibile" "-" ;; esac
case "$(page audio 'DSD=dop')" in *"Tramite DoP, come scelto"*) ok "audio: DoP scelto segnalato" ;; *) ko "audio DoP scelto" "Tramite DoP" "-" ;; esac
cat > "$WEB/actionbin/sweetspot-prova-dop" <<'FINTO'
#!/bin/sh
printf '%s\n' "$*" > "$SWEETSPOT_RUN/prova-dop.call"
echo RIFF > "$1"
FINTO
chmod +x "$WEB/actionbin/sweetspot-prova-dop"
dop_action() { # azione [esito]
	local body
	body="t=$(cat "$WEB/run/web.token")&a=$1${2:+&esito=$2}"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run \
		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" SWEETSPOT_WGET=$WEB/bin/wget \
		SWEETSPOT_PROVA_DOP_DIR=$WEB/prova-dop REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione"
}
printf 'VOLUME=fisso\n' > "$WEB/s.txt"
run "$WEB" "config_build $WEB/s.txt"
rm -f "$WEB/run/wget.post"
out=$(dop_action prova_dop)
expect "prova DoP: tono di 6 secondi generato sul player" "$WEB/prova-dop/prova-dop.wav 6" "$(cat "$WEB/run/prova-dop.call" 2>/dev/null)"
expect "prova DoP: esito atteso dopo l'avvio" "si" "$([ -f "$WEB/run/prova-dop.avviata" ] && echo si || echo no)"
expect "prova DoP: la coda di ascolto e' messa da parte (preview), non cancellata" "1|0" \
	"$(grep -c "\"playlist\",\"preview\",\"url:file://$WEB/prova-dop/prova-dop.wav\",\"title:Prova DoP\"" "$WEB/run/wget.post")|$(grep -c '"playlist","play"' "$WEB/run/wget.post")"
case "$out" in *"%50%72%6f%76%61%20%44%6f%50%20%61%76%76%69%61%74%61"*) ok "prova DoP: pagina con le istruzioni" ;; *) ko "prova DoP messaggio" "Prova DoP avviata" "$(printf '%s' "$out" | head -c 200)" ;; esac
case "$(page audio)" in *"usa DoP"*"lascia la conversione"*) ok "audio: dopo la prova si sceglie l'esito" ;; *) ko "audio esito prova DoP" "due pulsanti" "-" ;; esac
rm -f "$WEB/run/config.call" "$WEB/run/wget.post"
dop_action prova_dop_esito no > /dev/null
expect "esito negativo: nessuna impostazione cambiata" "no|no" \
	"$([ -e "$WEB/run/config.call" ] && echo si || echo no)|$([ -f "$WEB/run/prova-dop.avviata" ] && echo si || echo no)"
expect "esito: la coda di ascolto torna com'era" "1" "$(grep -c '"playlist","preview","cmd:stop"' "$WEB/run/wget.post")"
touch "$WEB/run/prova-dop.avviata"
rm -f "$WEB/run/wget.post"
dop_action prova_dop_esito si > /dev/null
expect "esito positivo: DSD tramite DoP, coda tornata com'era" "imposta DSD dop|1" "$(cat "$WEB/run/config.call" 2>/dev/null)|$(grep -c '"playlist","preview","cmd:stop"' "$WEB/run/wget.post")"
# DAC a 16 bit (o uscita forzata a 16 bit): i marcatori DoP non ci stanno.
cp "$WEB/proc/asound/card1/stream0" "$WEB/stream0.bak"
printf 'Playback:\n  Interface 1\n    Format: S16_LE\n    Rates: 44100, 48000, 176400\n' > "$WEB/proc/asound/card1/stream0"
case "$(page audio)" in *"Prova non disponibile"*"non dichiara 176,4 kHz a 24 o 32 bit"*) ok "audio: prova DoP bloccata con il DAC a 16 bit" ;; *) ko "audio prova DoP 16 bit" "prova non disponibile" "-" ;; esac
cp "$WEB/stream0.bak" "$WEB/proc/asound/card1/stream0"
case "$(page audio 'FORMATO_USCITA=16')" in *"Prova non disponibile"*"forzata a 16 bit"*) ok "audio: prova DoP bloccata con l'uscita forzata a 16 bit" ;; *) ko "audio prova DoP FORMATO_USCITA" "prova non disponibile" "-" ;; esac
printf 'VOLUME=software\n' > "$WEB/s.txt"
run "$WEB" "config_build $WEB/s.txt"
rm -f "$WEB/run/prova-dop.call"
dop_action prova_dop > /dev/null
expect "prova DoP rifiutata con il volume software" "no" "$([ -e "$WEB/run/prova-dop.call" ] && echo si || echo no)"
mkdac "$WEB" si
case "$(page audio)" in *"<h2>Prova DoP</h2>"*) ko "audio: nessuna prova con DSD nativo" "nessuna prova" "prova presente" ;; *) ok "audio: nessuna prova con DSD nativo" ;; esac
rm -f "$WEB/s.txt" "$WEB/run/config.call" "$WEB/run/prova-dop.avviata" "$WEB/run/prova-dop.call"
rm -rf "$WEB/prova-dop"

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
dspf() { # funzione...
	SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_AWK=$MATHAWK \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_ASOUND=$DSPE/asound.conf \
		SWEETSPOT_CAMILLADSP=$DSPE/camilladsp-assente SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-dsp; $1"
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
expect "CamillaDSP: coda del brano di due blocchi per i filtri di REW" "extra_samples: 8192" "$(printf '%s\n' "$yml" | grep -o 'extra_samples: [0-9]*')"
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
expect "correzione: volume principale a 0 dB per ogni processo" "0.0 0|1" \
	"$(cat "$DSPE/run/camilladsp.volume")|$(grep -c "vol_file \"$DSPE/run/camilladsp.volume\"" "$DSPE/asound.conf")"
expect "volume a 64 bit: CamillaDSP serve anche senza correzione" "0|1" "$(dsp 'VOLUME=dsp' attiva; echo $?)|$(dsp 'VOLUME=dsp' correzione; echo $?)"
expect "volume a 64 bit: solo nella modalita' completa" "1" "$(dsp "$(printf 'VOLUME=dsp\nMODALITA=player')" attiva; echo $?)"
rm -f "$DSPE/run/camilladsp.volume"
mv "$DSPE/run/correzione/sinistro.txt" "$DSPE/sinistro.bak"
dsp 'VOLUME=dsp' prepara 1 > /dev/null
yml=$(cat "$DSPE/run/camilladsp.yml")
expect "volume a 64 bit, DAC a 16 bit: nessun filtro, guadagno 0, dither a 16 bit, mai sopra 0 dB" "0|0.0|bits: 16|volume_limit: 0.0" \
	"$(printf '%s\n' "$yml" | grep -c 'type: Biquad')|$(printf '%s\n' "$yml" | sed -n 's/^      gain: //p' | head -n 1)|$(printf '%s\n' "$yml" | grep -o 'bits: 16')|$(printf '%s\n' "$yml" | grep -o 'volume_limit: 0.0')"
expect "volume a 64 bit: primo avvio a -30 dB" "-30.0 0" "$(cat "$DSPE/run/camilladsp.volume")"
printf 'Playback:\n  Interface 1\n    Format: S32_LE\n    Rates: 44100 48000 96000\n' > "$DSPE/proc/asound/card1/stream0"
echo "-17.4 1" > "$DSPE/run/camilladsp.volume"
dsp 'VOLUME=dsp' prepara 1 > /dev/null
expect "volume a 64 bit, DAC a 32 bit: dither a 24 bit" "S32_LE|bits: 24|dither 3" \
	"$(grep -o 'format: S32_LE' "$DSPE/run/camilladsp.yml" | head -n 1 | cut -d' ' -f2)|$(grep -o 'bits: 24' "$DSPE/run/camilladsp.yml")|dither $(grep -c 'dither' "$DSPE/run/camilladsp.yml")"
expect "volume a 64 bit: il volume gia' scelto resta" "-17.4 1" "$(cat "$DSPE/run/camilladsp.volume")"
if command -v camilladsp > /dev/null; then
	if camilladsp -c "$DSPE/run/camilladsp.yml" > /dev/null 2>&1; then ok "configurazione del volume accettata da CamillaDSP"; else ko "camilladsp -c volume" "valida" "rifiutata"; fi
fi
expect "file del volume: valori non validi rifiutati" "1|-17.4 1" "$(dsp '' stato 'abc'; echo $?)|$(cat "$DSPE/run/camilladsp.volume")"
mv "$DSPE/sinistro.bak" "$DSPE/run/correzione/sinistro.txt"
dsp 'CORREZIONE=si' prepara 1 > /dev/null
expect "tornando al volume fisso il guadagno riparte da 0 dB" "0.0 0" "$(cat "$DSPE/run/camilladsp.volume")"
VB=$DSPE/volbin
mkdir -p "$VB"
printf '#!/bin/sh\nprintf "%%s\\n" "$2" >> "%s"\necho "{}"\n' "$DSPE/run/camilla.call" > "$VB/sweetspot-camilla"
chmod +x "$VB/sweetspot-camilla"
vol() {
	SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_ASOUND=$DSPE/asound.conf \
		$TEST_SH -c "PATH=$VB:$OVERLAY/usr/bin:\$PATH; . $OVERLAY/usr/bin/sweetspot-volume" sh "$@"
}
volfn() { # funzione
	SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_ASOUND=$DSPE/asound.conf SWEETSPOT_TEST=1 \
		SWEETSPOT_WGET=$VB/wget SWEETSPOT_VOLUME_ATTESA=10 \
		$TEST_SH -c "PATH=$VB:$OVERLAY/usr/bin:\$PATH; . $OVERLAY/usr/bin/sweetspot-volume; $1"
}
# La scala di Lyrion per Squeezelite (SqueezePlay): 74 dB in due tratti,
# cosi' il cursore suona come con il volume software e sulle zone.
expect "scala del volume: quella di Lyrion (100 = 0 dB, 50 = -24,7, 25 = -37, 1 = -72,5)" "0.0|-24.7|-37.0|-72.5|-74.0" \
	"$(vol db 100)|$(vol db 50)|$(vol db 25)|$(vol db 1)|$(vol db 0)"
rm -f "$DSPE/run/camilla.call"
vol applica 50 0
expect "volume 50: file per i prossimi processi e CamillaDSP dal vivo" '-24.7 0|{"SetVolume":-24.7}|{"SetMute":false}|50 -24.7 0' \
	"$(cat "$DSPE/run/camilladsp.volume")|$(tr '\n' '|' < "$DSPE/run/camilla.call")$(cat "$DSPE/run/volume.dsp")"
vol applica 100 0
expect "volume 100: 0 dB, e resta anche per il prossimo CamillaDSP" "0.0 0|0.0 0" \
	"$(cat "$DSPE/run/camilladsp.volume")|$(dsp 'VOLUME=dsp' prepara 1 > /dev/null; cat "$DSPE/run/camilladsp.volume")"
vol applica -20 0
expect "volume negativo di Lyrion: sordina" "-44.4 1" "$(cat "$DSPE/run/camilladsp.volume")"
vol applica 0 0
expect "volume 0: sordina" "-74.0 1" "$(cat "$DSPE/run/camilladsp.volume")"
vol applica abc 0; rc=$?
expect "volume non numerico: nessun cambio" "1|-74.0 1" "$rc|$(cat "$DSPE/run/camilladsp.volume")"
# Primo allineamento: si riprova finche' Lyrion conosce il player.
printf '#!/bin/sh\ncase "$*" in *mixer*volume*) n=$(cat "%s" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "%s"; [ $n -ge 3 ] && echo "{\\"result\\":{\\"_volume\\":70}}" ;; *mixer*muting*) echo "{\\"result\\":{\\"_muting\\":0}}" ;; esac\nexit 0\n' "$DSPE/run/wget.n" "$DSPE/run/wget.n" > "$VB/wget"
chmod +x "$VB/wget"
rm -f "$DSPE/run/wget.n"
expect "primo allineamento: riprova finche' il player non e' in Lyrion" "0|3|70 -14.8 0" \
	"$(volfn 'sleep() { :; }; sync_first 00:11:22:33:44:55' 2>/dev/null; echo $?)|$(cat "$DSPE/run/wget.n")|$(cat "$DSPE/run/volume.dsp")"
mkdir -p "$DSPE/chiavetta/sweetspot-dati"
cp "$DSPE/rew.txt" "$DSPE/nuovo.txt"
SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/nuovo.txt" "" ; rc=$?
expect "filtri salvati sulla chiavetta, cartella propria" "0|$(wc -c < "$DSPE/rew.txt" | tr -d ' ')|no" \
	"$rc|$(wc -c < "$DSPE/chiavetta/correzione-ambientale/sinistro.txt" | tr -d ' ')|$([ -f "$DSPE/chiavetta/correzione-ambientale/destro.txt" ] && echo si || echo no)"
SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/run/correzione/sinistro.txt" ""
expect "salvare sopra lo stesso file non lo svuota" "$(wc -c < "$DSPE/rew.txt" | tr -d ' ')" "$(wc -c < "$DSPE/run/correzione/sinistro.txt" | tr -d ' ')"
if command -v python3 > /dev/null; then
	# Impulso FIR: WAV float a 32 bit con 512 campioni (frequenza, canali).
	mkwav() { python3 -c "
import struct, sys
rate, ch = int(sys.argv[1]), int(sys.argv[2])
data = b''.join(struct.pack('<f', 0.5 if i < ch else 0.0) for i in range(512 * ch))
sys.stdout.buffer.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 3, ch, rate, rate * 4 * ch, 4 * ch, 32) + b'data' + struct.pack('<I', len(data)) + data)" "$1" "$2"; }
	printf 'Playback:\n  Interface 1\n    Format: S32_LE\n    Rates: 44100 48000 96000\n' > "$DSPE/proc/asound/card1/stream0"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-sinistro.wav"
	expect "FIR: frequenza, canali, destro e margine" "96000 1 sinistro 3" "$(dsp 'CORREZIONE=si' fir)"
	dsp 'CORREZIONE=si' prepara 1 > /dev/null
	yml=$(cat "$DSPE/run/camilladsp.yml")
	expect "FIR: CamillaDSP a 96 kHz con il ricampionatore sincrono" "samplerate: 96000|type: Synchronous" \
		"$(printf '%s\n' "$yml" | grep -o 'samplerate: 96000')|$(printf '%s\n' "$yml" | grep -o 'type: Synchronous')"
	expect "FIR: due convoluzioni dal file del sinistro, canale 0, dopo i filtri di REW" \
		"2|2|- fir_sinistro|- fir_destro|-7.5" \
		"$(printf '%s\n' "$yml" | grep -c "filename: \"$DSPE/run/correzione/fir-sinistro.wav\"")|$(printf '%s\n' "$yml" | grep -c 'channel: 0')|$(printf '%s\n' "$yml" | grep -o -- '- fir_sinistro')|$(printf '%s\n' "$yml" | grep -o -- '- fir_destro')|$(printf '%s\n' "$yml" | sed -n 's/^      gain: //p' | head -n 1)"
	# Coda del brano: con i FIR CamillaDSP legge, dopo la fine dello stream,
	# tanti campioni di silenzio quanti i tap (512) piu' due blocchi.
	expect "FIR: coda del brano non tagliata (extra_samples = tap + 2 blocchi)" "512|extra_samples: 8704" \
		"$(dspf fir_taps)|$(printf '%s\n' "$yml" | grep -o 'extra_samples: [0-9]*')"
	if command -v camilladsp > /dev/null; then
		if camilladsp -c "$DSPE/run/camilladsp.yml" > /dev/null 2>&1; then ok "configurazione FIR accettata da CamillaDSP"; else ko "camilladsp -c FIR" "valida" "rifiutata"; fi
	fi
	dsp 'CORREZIONE=confronto' prepara 1 > /dev/null
	expect "FIR nel confronto: stessa frequenza e attenuazione, senza convoluzione" "samplerate: 96000|0|-7.5" \
		"$(grep -o 'samplerate: 96000' "$DSPE/run/camilladsp.yml")|$(grep -c -- '- fir_' "$DSPE/run/camilladsp.yml")|$(sed -n 's/^      gain: //p' "$DSPE/run/camilladsp.yml" | head -n 1)"
	mkwav 96000 2 > "$DSPE/run/correzione/fir-sinistro.wav"
	dsp 'CORREZIONE=si' prepara 1 > /dev/null
	expect "FIR stereo unico: il destro legge il canale 1" "channel: 0|channel: 1" \
		"$(grep -o 'channel: [01]' "$DSPE/run/camilladsp.yml" | tr '\n' '|' | sed 's/|$//')"
	mkwav 48000 1 > "$DSPE/run/correzione/fir-destro.wav"
	expect "FIR con frequenze diverse sui due canali: rifiutati" "1" "$(dsp 'CORREZIONE=si' fir > /dev/null; echo $?)"
	rm -f "$DSPE/run/correzione/fir-destro.wav"
	mkwav 96000 1 | head -c 1068 > "$DSPE/run/correzione/fir-destro.wav"
	expect "FIR: la coda e' quella del canale piu' lungo (512 a sinistra, 256 a destra)" "512|256" "$(dspf fir_taps)|$(dspf "wav_frames $DSPE/run/correzione/fir-destro.wav")"
	rm -f "$DSPE/run/correzione/fir-destro.wav"
	mkwav 192000 1 > "$DSPE/run/correzione/fir-sinistro.wav"
	expect "FIR a una frequenza che il DAC non accetta: correzione non applicata" "1" "$(dsp 'CORREZIONE=si' prepara 1 > /dev/null; echo $?)"
	echo "non sono un wav" > "$DSPE/run/correzione/fir-sinistro.wav"
	expect "FIR non valido: ignorato" "1" "$(dsp 'CORREZIONE=si' fir > /dev/null; echo $?)"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-sinistro.wav"
	mv "$DSPE/run/correzione/sinistro.txt" "$DSPE/sinistro-rew.bak"
	expect "solo FIR, senza filtri di REW: correzione attiva" "0" "$(dsp 'CORREZIONE=si' correzione; echo $?)"
	mv "$DSPE/sinistro-rew.bak" "$DSPE/run/correzione/sinistro.txt"
	cp "$DSPE/run/correzione/fir-sinistro.wav" "$DSPE/chiavetta/correzione-ambientale/"
	SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/rew.txt" "" > /dev/null
	expect "salvare i filtri di REW non cancella i FIR sulla chiavetta" "si" \
		"$([ -s "$DSPE/chiavetta/correzione-ambientale/fir-sinistro.wav" ] && echo si || echo no)"
	rm -f "$DSPE/run/correzione/fir-sinistro.wav" "$DSPE/run/correzione/fir-destro.wav"
fi
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
# Con la password delle pagine l'httpd risponde 401 a chi non si presenta:
# la conferma usa l'utente sweetspot con la chiave di questo avvio.
printf '#!/bin/sh\nfor a; do case "$a" in http://sweetspot:0123456789abcdef0123456789abcdef@127.0.0.1/cgi-bin/vivo) exit 0 ;; esac; done\nexit 1\n' > "$UPD/bin/wget-401"
chmod +x "$UPD/bin/wget-401"
setenv prova= tentato=b
UPD_WGET=$UPD/bin/wget-401 upd conferma
expect "con la password e senza chiave la conferma non passa (401)" "b" "$(genv tentato)"
echo 0123456789abcdef0123456789abcdef > "$UPD/run/vivo.chiave"
UPD_WGET=$UPD/bin/wget-401 upd conferma
expect "con la password la conferma passa con la chiave della pagina vivo" "b|" "$(genv slot)|$(genv tentato)"
rm -f "$UPD/run/vivo.chiave"
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

echo "Precarico in RAM"
PRE=$WORK/precarico
mkdir -p "$PRE/proc" "$PRE/run" "$PRE/musica/Album è"
printf 'MemTotal:        8388608 kB\nMemAvailable:    4194304 kB\n' > "$PRE/proc/meminfo"
head -c 3000 /dev/zero > "$PRE/musica/Album è/a.flac"
head -c 2000 /dev/zero > "$PRE/musica/Album è/b c.flac"
head -c 5000 /dev/zero > "$PRE/musica/Album è/grande.dsf"
head -c 1000 /dev/zero > "$PRE/musica/Album è/d.flac"
prefn() {
	SWEETSPOT_PROCFS=$PRE/proc SWEETSPOT_RUN=$PRE/run SWEETSPOT_LOG=$PRE/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-precarico; $1"
}
U=file://$PRE/musica/Album%20%C3%A8
expect "URL di Lyrion: spazi e lettere accentate" "$PRE/musica/Album è/b c.flac" "$(prefn "url_path '$U/b%20c.flac'")"
expect "streaming escluso dal precarico" "no" "$(prefn "url_path 'http://radio.example/stream' && echo si || echo no")"
# I buffer di Squeezelite (8 GB: 1 GB + 2 GB, player_buffers) si riempiono
# a poco a poco: senza il player in esecuzione contano per intero.
expect "buffer del player da riempire: contano per intero senza il player" "3048576" "$(prefn player_reserve_kb)"
expect "budget automatico: meta' della memoria libera, tolti i buffer del player" "572864" "$(prefn preload_budget_kb)"
mkdir -p "$PRE/proc/4321"
printf 'VmRSS:\t 1048576 kB\n' > "$PRE/proc/4321/status"
echo 4321 > "$PRE/run/squeezelite.pid"
expect "buffer del player in parte gia' occupati: conta solo il resto" "2000000|1097152" "$(prefn player_reserve_kb)|$(prefn preload_budget_kb)"
rm -f "$PRE/run/squeezelite.pid"
echo PRECARICO_MB=100 > "$PRE/run/sweetspot.conf"
expect "budget indicato in MB" "102400" "$(prefn preload_budget_kb)"
echo PRECARICO_MB=99999 > "$PRE/run/sweetspot.conf"
expect "budget mai oltre la memoria libera meno i buffer del player e 256 MB" "883584" "$(prefn preload_budget_kb)"
printf 'PRECARICO_FILE_MAX_MB=1 2\n' > "$PRE/run/sweetspot.conf"
expect "limite dei file non numerico: predefinito, senza errori" "1048576" "$(prefn file_max_kb 2>&1)"
rm -f "$PRE/run/sweetspot.conf"
sleep 30 &
echo $! > "$PRE/run/precarico.tieni.pid"
printf 'SI 1000 /musica/a.flac\nSTREAM http://radio.example/stream\n' > "$PRE/run/precarico.piano"
expect "budget stabile: la memoria gia' bloccata conta come libera" "573364" "$(prefn preload_budget_kb)"
kill "$(cat "$PRE/run/precarico.tieni.pid")"
rm -f "$PRE/run/precarico.tieni.pid" "$PRE/run/precarico.piano"
printf '%s\n' "$U/a.flac" "http://radio.example/stream" "$U/grande.dsf" "$U/b%20c.flac" "$U/manca.flac" "$U/d.flac" > "$PRE/coda"
expect "piano: in coda fino al budget, poi si ferma" \
	"SI 3 $PRE/musica/Album è/a.flac|STREAM http://radio.example/stream|GRANDE 5 $PRE/musica/Album è/grande.dsf|OLTRE 2 $PRE/musica/Album è/b c.flac|MANCA $PRE/musica/Album è/manca.flac|OLTRE 1 $PRE/musica/Album è/d.flac" \
	"$(prefn "preload_plan 4 4 < '$PRE/coda'" | tr '\n' '|' | sed 's/|$//')"
printf '%s\n' "$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.elenco"
expect "brano finito: il resto della coda e' gia' in RAM" "si" \
	"$(prefn "plan_held 'SI 2 $PRE/musica/Album è/b c.flac
STREAM http://radio.example/stream' && echo si || echo no")"
expect "nuovo brano in coda: precarico da rifare" "no" \
	"$(prefn "plan_held 'SI 1 $PRE/musica/Album è/d.flac' && echo si || echo no")"
expect "brano escluso: nuovo verdetto" "no" \
	"$(prefn "plan_held 'SI 2 $PRE/musica/Album è/b c.flac
OLTRE 1 $PRE/musica/Album è/d.flac' && echo si || echo no")"
expect "coda di soli streaming: niente da tenere, nessuna esclusione" "si|no" \
	"$(prefn "plan_held 'STREAM http://radio.example/stream' && echo si || echo no")|$(prefn "plan_held 'STREAM http://radio.example/stream
MANCA /x.flac' && echo si || echo no")"
# Standby dei dischi: stato vero da hdparm -C, un disco svegliato da altro
# esce dall'elenco e si riprova non prima di un minuto.
mkdir -p "$PRE/bin" "$PRE/sys/block/sdb/queue" "$PRE/sys/block/sdc/queue"
echo 1 > "$PRE/sys/block/sdb/queue/rotational"; echo 1 > "$PRE/sys/block/sdc/queue/rotational"
cat > "$PRE/bin/hdparm" <<'FINTO'
#!/bin/sh
echo "$*" >> "$HDPARM_LOG"
case "$1" in
	-C) if grep -q "^${2#/dev/}$" "$HDPARM_SLEEPING" 2>/dev/null; then echo " drive state is:  standby"; else echo " drive state is:  active/idle"; fi ;;
	-y) echo "${2#/dev/}" >> "$HDPARM_SLEEPING" ;;
esac
FINTO
chmod +x "$PRE/bin/hdparm"
prestandby() {
	HDPARM_LOG=$PRE/run/hdparm.log HDPARM_SLEEPING=$PRE/run/dormienti SWEETSPOT_HDPARM=$PRE/bin/hdparm SWEETSPOT_SYSFS=$PRE/sys \
		prefn "file_disk() { case \"\$1\" in *a.flac) echo sdb ;; *) echo sdc ;; esac; }; standby_disks"
}
printf 'SI 3 %s\nSI 2 %s\n' "$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.piano"
rm -f "$PRE/run/hdparm.log" "$PRE/run/dormienti" "$PRE/run/precarico.standby" "$PRE/run/precarico.standby.t"
prestandby
expect "standby: i dischi della coda fermati e annotati" "sdb sdc|2" "$(cat "$PRE/run/precarico.standby")|$(grep -c -- '^-y' "$PRE/run/hdparm.log")"
echo sdb > "$PRE/run/dormienti"
rm -f "$PRE/run/hdparm.log"
prestandby
expect "standby: disco svegliato da altro: fuori dall'elenco, nessun nuovo -y prima di un minuto" "sdb|0|1" \
	"$(cat "$PRE/run/precarico.standby")|$(grep -c -- '^-y' "$PRE/run/hdparm.log")|$(grep -c 'disco sdc svegliato da altro' "$PRE/log")"
echo 0 > "$PRE/run/precarico.standby.t"
rm -f "$PRE/run/hdparm.log"
prestandby
expect "standby: passato un minuto si riprova" "sdb sdc|1" "$(cat "$PRE/run/precarico.standby")|$(grep -c -- '^-y /dev/sdc' "$PRE/run/hdparm.log")"
rm -f "$PRE/run/precarico.piano" "$PRE/run/precarico.standby" "$PRE/run/precarico.standby.t" "$PRE/run/dormienti" "$PRE/run/hdparm.log"
printf 'SI 3 %s\nSI 2 %s\nSTREAM http://radio.example/stream\n' "$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.piano"
printf 'stato\tpronto\nfile\t3000\tok\t%s\nfile\t2000\terrore: Cannot allocate memory\t%s\nfile\t9\tok\t/vecchio.flac\n' \
	"$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.stato"
if command -v jq >/dev/null; then
	prefn "write_summary parziale"
	expect "riepilogo: solo i brani del piano, errori e streaming" "parziale 3 1 1 1 0" \
		"$(jq -r '"\(.stato) \(.brani) \(.caricati) \(.errori) \(.streaming) \(.oltre)"' "$PRE/run/precarico.json")"
else
	echo "  (jq non installato: riepilogo non provato)"
fi

echo "CamillaDSP in real-time"
DSP=$WORK/dsp
mkdir -p "$DSP/run" "$DSP/proc/4242/task/4242" "$DSP/proc/4242/task/4243"
# /proc/PID/stat: dopo "(comm) " il 38esimo campo e' la priorita', il 39esimo la politica.
dspstat() { printf '%s (camilladsp) S%s %s %s 0\n' "$1" "$(printf ' 0%.0s' $(seq 2 37))" "$2" "$3"; }
dspstat 4242 0 0 > "$DSP/proc/4242/task/4242/stat"
dspstat 4243 70 1 > "$DSP/proc/4242/task/4243/stat"
# Funzioni al posto dei comandi: BusyBox preferisce le sue applet ai file nel PATH.
DSPSTUB="pidof() { [ -n \"\$DSP_PID\" ] && echo \"\$DSP_PID\"; }
chrt() { echo \"\$*\" >> '$DSP/run/chrt.call'; }
taskset() { echo \"\$*\" >> '$DSP/run/taskset.call'; }"
DSP_PID=4242
export DSP_PID
dspfn() { # PIN funzione
	SWEETSPOT_SYSFS=$DSP/sys SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c "$DSPSTUB
. $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player; PIN=$1; LAYOUT_AUDIO=3; $2"
}
calls() { cat "$DSP/run/$1.call" 2>/dev/null | tr '\n' '|' | sed 's/|$//'; }
dspfn 1 pin_dsp
expect "senza correzione CamillaDSP non si tocca" "" "$(calls chrt)$(calls taskset)"
touch "$DSP/run/correzione.attiva"
dspfn 1 pin_dsp
expect "CamillaDSP: SCHED_FIFO 70 sui thread non ancora real-time" "-f -p 70 4242" "$(calls chrt)"
expect "CamillaDSP: tutti i thread sul core della riproduzione" "-p -c 3 4242|-p -c 3 4243" "$(calls taskset)"
rm -f "$DSP/run/chrt.call" "$DSP/run/taskset.call"
dspfn 0 pin_dsp
expect "core non isolati: real-time senza spostare i thread" "-f -p 70 4242|" "$(calls chrt)|$(calls taskset)"
expect "registro: una riga per processo CamillaDSP" "1" "$(grep -c 'CamillaDSP 4242, thread audio in real-time' "$DSP/log")"
# CamillaDSP con la nostra patch (thread "Processing"): solo i thread audio
# sul core della riproduzione in real-time; principale, segnali e
# websocket sui core di sistema con la priorita' normale. Un thread gia' a
# posto (core e politica) non si tocca.
for t in 4242 4243 4244 4245 4246; do mkdir -p "$DSP/proc/4242/task/$t"; done
echo camilladsp > "$DSP/proc/4242/task/4242/comm"
echo Processing > "$DSP/proc/4242/task/4243/comm"
echo FileCapture > "$DSP/proc/4242/task/4244/comm"
echo AlsaPlayback > "$DSP/proc/4242/task/4245/comm"
echo camilladsp > "$DSP/proc/4242/task/4246/comm"
dspstat 4242 80 1 > "$DSP/proc/4242/task/4242/stat"; printf 'Cpus_allowed_list:\t3\n' > "$DSP/proc/4242/task/4242/status"
dspstat 4243 70 1 > "$DSP/proc/4242/task/4243/stat"; printf 'Cpus_allowed_list:\t3\n' > "$DSP/proc/4242/task/4243/status"
dspstat 4244 80 1 > "$DSP/proc/4242/task/4244/stat"; printf 'Cpus_allowed_list:\t3\n' > "$DSP/proc/4242/task/4244/status"
dspstat 4245 80 1 > "$DSP/proc/4242/task/4245/stat"; printf 'Cpus_allowed_list:\t0,1\n' > "$DSP/proc/4242/task/4245/status"
dspstat 4246 0 0 > "$DSP/proc/4242/task/4246/stat"; printf 'Cpus_allowed_list:\t0,1\n' > "$DSP/proc/4242/task/4246/status"
rm -f "$DSP/run/chrt.call" "$DSP/run/taskset.call"
dspfn 1 "HK=0,1; pin_dsp"
expect "thread audio: in real-time sul core audio, solo chi non lo e' gia'" \
	"-f -p 70 4244|-f -p 70 4245|-p -c 3 4245" \
	"$(grep -- '424[345]' "$DSP/run/chrt.call" | tr '\n' '|' | sed 's/|$//')|$(grep -- '424[345]' "$DSP/run/taskset.call" | tr '\n' '|' | sed 's/|$//')"
expect "thread non audio: sui core di sistema con la priorita' normale, solo chi non lo e' gia'" \
	"-o -p 0 4242|-p -c 0,1 4242" \
	"$(grep -- '424[26]' "$DSP/run/chrt.call" | tr '\n' '|' | sed 's/|$//')|$(grep -- '424[26]' "$DSP/run/taskset.call" | tr '\n' '|' | sed 's/|$//')"
rm -f "$DSP/run/chrt.call" "$DSP/run/taskset.call"
echo PRIORITA_DSP=99 > "$DSP/run/sweetspot.conf"
expect "priorita' DSP limitata a 98" "98" "$(dspfn 1 dsp_priority)"
echo PRIORITA_DSP=alta > "$DSP/run/sweetspot.conf"
expect "priorita' DSP non numerica: 70" "70" "$(dspfn 1 dsp_priority)"
rm -f "$DSP/run/sweetspot.conf"
dspcheck() {
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH -c "$DSPSTUB
set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" | grep '^[A-Z]*|CamillaDSP in real-time|'
}
printf 'Cpus_allowed_list:\t3\n' > "$DSP/proc/4242/status"
for f in mounts meminfo cpuinfo cmdline; do [ -e "$WEB/proc/$f" ] && cp "$WEB/proc/$f" "$DSP/proc/$f"; done
grep -q '^MemTotal:' "$DSP/proc/meminfo" 2>/dev/null || printf 'MemTotal:       16303112 kB\n' >> "$DSP/proc/meminfo"
[ -e "$DSP/proc/mounts" ] || : > "$DSP/proc/mounts"
expect "verifica: un thread non audio ancora in real-time e' un avviso" \
	"ATTENZIONE|CamillaDSP in real-time|3 thread audio a priorita' 70 80, ma 1 thread non audio ancora in real-time: si sistemano entro pochi secondi" "$(dspcheck)"
dspstat 4242 0 0 > "$DSP/proc/4242/task/4242/stat"
dspstat 4244 70 1 > "$DSP/proc/4242/task/4244/stat"
dspstat 4245 70 1 > "$DSP/proc/4242/task/4245/stat"; printf 'Cpus_allowed_list:\t3\n' > "$DSP/proc/4242/task/4245/status"
expect "verifica: thread audio in real-time sul core audio, gli altri sui core di sistema" \
	"OK|CamillaDSP in real-time|3 thread audio a priorita' 70 sul core 3, gli altri sui core di sistema" "$(dspcheck)"
dspstat 4244 0 0 > "$DSP/proc/4242/task/4244/stat"
expect "verifica: un thread audio non real-time e' un avviso" \
	"ATTENZIONE|CamillaDSP in real-time|2 di 3 thread audio in real-time: la correzione puo' interrompersi sotto carico" "$(dspcheck)"
# CamillaDSP senza la patch (nessun thread "Processing"): tutti i thread contano.
rm -rf "$DSP/proc/4242/task/4243" "$DSP/proc/4242/task/4244" "$DSP/proc/4242/task/4245" "$DSP/proc/4242/task/4246"
mkdir -p "$DSP/proc/4242/task/4243"
dspstat 4243 70 1 > "$DSP/proc/4242/task/4243/stat"
rm -f "$DSP/proc/4242/task/4242/comm"
expect "verifica senza la patch: un thread non real-time e' un avviso" \
	"ATTENZIONE|CamillaDSP in real-time|1 di 2 thread audio in real-time: la correzione puo' interrompersi sotto carico" "$(dspcheck)"
dspstat 4242 70 1 > "$DSP/proc/4242/task/4242/stat"
expect "verifica senza la patch: tutti i thread real-time sul core audio" "OK|CamillaDSP in real-time|2 thread audio a priorita' 70 sul core 3" "$(dspcheck)"
expect "verifica: CamillaDSP parte con il primo brano" \
	"INFO|CamillaDSP in real-time|non in esecuzione: parte con il primo brano" "$(DSP_PID= dspcheck)"

echo "Altri DAC (zone)"
# DAC principale (scheda 1), un secondo DAC (2) e un microfono USB (3, solo ingresso).
mkdir -p "$DSP/proc/asound/card1" "$DSP/proc/asound/card2" "$DSP/proc/asound/card3"
echo R26 > "$DSP/proc/asound/card1/id"; echo 292b:0a26 > "$DSP/proc/asound/card1/usbid"
echo Zona > "$DSP/proc/asound/card2/id"; echo 1234:5678 > "$DSP/proc/asound/card2/usbid"
echo UMIK > "$DSP/proc/asound/card3/id"; echo 2752:0007 > "$DSP/proc/asound/card3/usbid"
printf '01-00: USB Audio : USB Audio : playback 1\n02-00: USB Audio : USB Audio : playback 1\n03-00: USB Audio : USB Audio : capture 1\n' > "$DSP/proc/asound/pcm"
printf ' 1 [R26            ]: USB-Audio - R26\n 2 [Zona           ]: USB-Audio - Zona DAC\n 3 [UMIK           ]: USB-Audio - UMIK-1\n' > "$DSP/proc/asound/cards"
rm -f "$DSP/run/taskset.call"; rm -rf "$DSP/run/zone"
echo ALTRI_DAC=no > "$DSP/run/sweetspot.conf"
dspfn 1 "HK=0; zones_sync 1"
expect "zone spente di serie: nessun altro player" "" "$(calls taskset)"
echo ALTRI_DAC=si > "$DSP/run/sweetspot.conf"
dspfn 1 "HK=0; zones_sync 1"
zcall=$(calls taskset)
case "$zcall" in "-c 0 squeezelite -o hw:CARD=Zona,DEV=0 "*"-n Sweetspot - Zona DAC -M Sweetspot -m 02:"*"-p 75 "*"-s 127.0.0.1"*) ok "zona: Squeezelite sul secondo DAC, sui core di sistema" ;; *) ko "zona avviata" "squeezelite su Zona" "$zcall" ;; esac
case "$zcall" in *UMIK*|*R26*) ko "zona: niente microfono ne' DAC principale" "solo Zona" "$zcall" ;; *) ok "zona: niente microfono ne' DAC principale" ;; esac
expect "zona: registrata per il controllo" "Zona" "$(cut -d' ' -f2 "$DSP/run/zone/2")"
expect "zona: MAC stabile e locale" "1|02" \
	"$([ "$(dspfn 1 'zone_mac 2')" = "$(dspfn 1 'zone_mac 2')" ] && echo 1)|$(dspfn 1 'zone_mac 2' | cut -c1-2)"
sleep 300 & zpid=$!
echo "$zpid Zona" > "$DSP/run/zone/2"
expect "stato: zona attiva" "OK|Altri DAC (zone)|un player in Lyrion per Zona; si raggruppano da Lyrion" \
	"$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH -c "$DSPSTUB
set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" 2>/dev/null | grep '^[A-Z]*|Altri DAC')"
rm -rf "$DSP/proc/asound/card2"
dspfn 1 "HK=0; zones_sync 1"
expect "DAC della zona staccato: player fermato" "no|no" \
	"$([ -f "$DSP/run/zone/2" ] && echo si || echo no)|$(kill -0 "$zpid" 2>/dev/null && echo si || echo no)"
# DAC principale staccato con una zona attiva: il player principale lo
# aspetta, non passa alla zona (che continua), e al ritorno riprende lui.
mkdir -p "$DSP/proc/asound/card2"; echo Zona > "$DSP/proc/asound/card2/id"; echo 1234:5678 > "$DSP/proc/asound/card2/usbid"
rm -f "$DSP/run/dac.principale"
expect "DAC=auto senza zone: il primo DAC USB" "1" "$(dspfn 1 'dac_find')"
dspfn 1 'remember_main_dac 1'
expect "DAC principale annotato: identificativo USB e numero di serie" "292b:0a26 " "$(cat "$DSP/run/dac.principale")"
sleep 300 & zpid=$!
echo "$zpid Zona" > "$DSP/run/zone/2"
expect "con il DAC principale la zona non e' mai il principale" "1" "$(dspfn 1 'dac_find')"
mv "$DSP/proc/asound/card1" "$DSP/proc/asound/card1.via"
expect "DAC principale staccato: il player lo aspetta, non passa alla zona" "" "$(dspfn 1 'dac_find')"
dspfn 1 "HK=0; zones_sync ''"
expect "senza DAC principale la zona continua" "si|Zona" "$(kill -0 "$zpid" 2>/dev/null && echo si || echo no)|$(cut -d' ' -f2 "$DSP/run/zone/2")"
mv "$DSP/proc/asound/card1.via" "$DSP/proc/asound/card1"
rm -f "$DSP/run/taskset.call"
dspfn 1 "HK=0; zones_sync ''"
expect "il DAC principale tornato non diventa una zona" "no|" "$([ -f "$DSP/run/zone/1" ] && echo si || echo no)|$(calls taskset)"
expect "DAC principale tornato: riprende lui" "1" "$(dspfn 1 'dac_find')"
# Con ALTRI_DAC=no il DAC principale resta il primo trovato, come prima.
echo ALTRI_DAC=no > "$DSP/run/sweetspot.conf"
mv "$DSP/proc/asound/card1" "$DSP/proc/asound/card1.via"
expect "senza zone, DAC staccato: si passa all'altro DAC" "2" "$(dspfn 1 'dac_find')"
mv "$DSP/proc/asound/card1.via" "$DSP/proc/asound/card1"
echo ALTRI_DAC=si > "$DSP/run/sweetspot.conf"
# Due DAC uguali: il numero di serie USB li distingue (identita' e MAC).
mkdir -p "$DSP/proc/asound/card4" "$DSP/sys/class/sound/card1" "$DSP/sys/class/sound/card4" \
	"$DSP/sys/devices/usb1/1-2/1-2:1.0" "$DSP/sys/devices/usb1/1-3/1-3:1.0"
echo R26_1 > "$DSP/proc/asound/card4/id"; echo 292b:0a26 > "$DSP/proc/asound/card4/usbid"
printf '01-00: USB Audio : USB Audio : playback 1\n02-00: USB Audio : USB Audio : playback 1\n03-00: USB Audio : USB Audio : capture 1\n04-00: USB Audio : USB Audio : playback 1\n' > "$DSP/proc/asound/pcm"
printf ' 1 [R26            ]: USB-Audio - R26\n 2 [Zona           ]: USB-Audio - Zona DAC\n 3 [UMIK           ]: USB-Audio - UMIK-1\n 4 [R26_1          ]: USB-Audio - R26\n' > "$DSP/proc/asound/cards"
ln -sfn "../../../devices/usb1/1-2/1-2:1.0" "$DSP/sys/class/sound/card1/device"
ln -sfn "../../../devices/usb1/1-3/1-3:1.0" "$DSP/sys/class/sound/card4/device"
echo AAA111 > "$DSP/sys/devices/usb1/1-2/serial"; echo BBB222 > "$DSP/sys/devices/usb1/1-3/serial"
dspfn 1 'remember_main_dac 1'
expect "due DAC uguali: il principale e' quello con il suo numero di serie" "292b:0a26 AAA111|2 4" \
	"$(cat "$DSP/run/dac.principale")|$(dspfn 1 'other_dacs 1' | tr '\n' ' ' | sed 's/ $//')"
expect "due DAC uguali: MAC diversi per le zone" "diversi" "$([ "$(dspfn 1 'zone_mac 1')" != "$(dspfn 1 'zone_mac 4')" ] && echo diversi)"
kill "$zpid" 2>/dev/null
rm -rf "$DSP/proc/asound/card1" "$DSP/proc/asound/card2" "$DSP/proc/asound/card3" "$DSP/proc/asound/card4" "$DSP/proc/asound/pcm" "$DSP/proc/asound/cards" "$DSP/run/zone" "$DSP/sys" "$DSP/run/dac.principale"
rm -f "$DSP/run/sweetspot.conf"

echo "Contatori live della sessione"
irqs() { # conteggi dei core 2 e 3: IRQ16 IRQ29 LOC
	printf '           CPU0       CPU1       CPU2       CPU3\n'
	printf '  0:         10          0          0          0   IO-APIC   2-edge      timer\n'
	printf ' 16:        100          0 %10s %10s   IO-APIC  16-fasteoi   ehci_hcd:usb1\n' "$1" "$1"
	printf ' 29:          0          0 %10s %10s   PCI-MSI 327680-edge      xhci_hcd\n' "$2" "$2"
	printf 'NMI:          0          0          0          0   Non-maskable interrupts\n'
	printf 'LOC:       1000        900 %10s %10s   Local timer interrupts\n' "$3" "$3"
	printf 'ERR:          0\n'
}
irqs 0 7000 700 > "$DSP/proc/interrupts"
expect "interruzioni: colonna del core, nome del driver" \
	"0 0 timer|16 0 ehci_hcd:usb1|29 7000 xhci_hcd|NMI 0 |LOC 700 " \
	"$(dspfn 1 'irq_cpu_counts 3' | tr '\n' '|' | sed 's/|$//')"
printf '[12:00:00] _output_frames:123 XRUN\n' > "$DSP/squeezelite.log"
dspfn 1 "SQLOG=$DSP/squeezelite.log; session_start"
expect "sessione: posizione nel registro di Squeezelite" "35|3" \
	"$(sed -n 's/^sqlog=//p' "$DSP/run/sessione")|$(sed -n 's/^core=//p' "$DSP/run/sessione")"
expect "sessione: interruzioni del core all'inizio" "29 7000 xhci_hcd" "$(grep '^29 ' "$DSP/run/sessione.irq")"
mkdir -p "$DSP/bin"
printf '#!/bin/sh\n[ -s "%s" ] || exit 1\nprintf '"'"'{"GetClippedSamples":{"result":"Ok","value":%%s}}\\n'"'"' "$(cat "%s")"\n' \
	"$DSP/run/camilla.valore" "$DSP/run/camilla.valore" > "$DSP/bin/sweetspot-camilla"
chmod +x "$DSP/bin/sweetspot-camilla"
clip() { echo "$1" > "$DSP/run/camilla.valore"; dspfn 1 "PATH=$DSP/bin:\$PATH; dsp_clip_poll"; cat "$DSP/run/dsp.clip" 2>/dev/null; }
expect "clipping: primo valore del processo" "4242 10 10" "$(clip 10)"
expect "clipping: cresce con il processo" "4242 25 25" "$(clip 25)"
expect "clipping: nuovo processo, si somma da zero" "5000 3 28" "$(DSP_PID=5000 clip 3)"
expect "clipping: contatore ripartito nello stesso processo" "5000 1 29" "$(DSP_PID=5000 clip 1)"
: > "$DSP/run/camilla.valore"
expect "clipping: CamillaDSP che non risponde non cambia il totale" "5000 1 29" "$(DSP_PID=5000 clip '')"
livecheck() { # voce
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$DSP/squeezelite.log \
		$TEST_SH -c "$DSPSTUB
set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" | grep "^[A-Z]*|$1|"
}
expect "stato: campioni tagliati nella sessione" \
	"ATTENZIONE|Clipping di CamillaDSP|29 campioni tagliati nella sessione: l'attenuazione automatica non basta, riduci in REW i filtri che alzano il livello" \
	"$(livecheck 'Clipping di CamillaDSP')"
echo "5000 0 0" > "$DSP/run/dsp.clip"
expect "stato: nessun campione tagliato" "OK|Clipping di CamillaDSP|nessun campione tagliato nella sessione" "$(livecheck 'Clipping di CamillaDSP')"
# Sessione iniziata due minuti fa; nel registro un XRUN prima e uno dopo.
sed -i "s/^inizio=.*/inizio=$(( $(date +%s) - 150 ))/" "$DSP/run/sessione"
expect "stato: XRUN prima della sessione esclusi" "OK|XRUN nella sessione|nessuno in 2 minuti" "$(livecheck 'XRUN nella sessione')"
expect "stato: lo storico diventa informazione" "INFO|XRUN ALSA registrati|1 nel registro storico; non misura il jitter del clock" "$(livecheck 'XRUN ALSA registrati')"
printf '[12:05:00] _output_frames:123 XRUN\n[12:05:01] output_thread:123 XRUN recover failed: Broken pipe\n' >> "$DSP/squeezelite.log"
expect "stato: XRUN della sessione" "ATTENZIONE|XRUN nella sessione|1 in 2 minuti (recuperi falliti: 1)" "$(livecheck 'XRUN nella sessione')"
printf 'XRUN\n' > "$DSP/squeezelite.log"
expect "stato: registro ricominciato, conta tutto" "ATTENZIONE|XRUN nella sessione|1 in 2 minuti (recuperi falliti: 0)" "$(livecheck 'XRUN nella sessione')"
expect "stato: nessuna interruzione di dispositivi" "OK|Interruzioni sul core audio|nessuna da dispositivi in 2 minuti sul core 3" \
	"$(livecheck 'Interruzioni sul core audio')"
irqs 2 7600 12700 > "$DSP/proc/interrupts"
# Di nuovo due minuti e mezzo: le verifiche precedenti richiedono tempo.
sed -i "s/^inizio=.*/inizio=$(( $(date +%s) - 150 ))/" "$DSP/run/sessione"
# Nel /sys finto il core 3 riceve anche le interruzioni USB: e' voluto.
expect "stato: interruzioni USB sul core condiviso" \
	"INFO|Interruzioni sul core audio|IRQ 16 (ehci_hcd:usb1) 2, IRQ 29 (xhci_hcd) 600 in 2 minuti (un solo core: USB e riproduzione lo condividono)" \
	"$(livecheck 'Interruzioni sul core audio')"
expect "stato: interruzioni di sistema al secondo" "INFO|Interruzioni di sistema sul core audio|100 al secondo (timer e chiamate fra core)" \
	"$(livecheck 'Interruzioni di sistema sul core audio')"
irqs 0 7000 700 > "$DSP/proc/interrupts"
dspfn 1 "SQLOG=$DSP/squeezelite.log; LAYOUT_AUDIO=2; session_start"
sed -i "s/^inizio=.*/inizio=$(( $(date +%s) - 150 ))/" "$DSP/run/sessione"
irqs 2 7600 12700 > "$DSP/proc/interrupts"
expect "stato: interruzioni di dispositivi sul core isolato" \
	"ATTENZIONE|Interruzioni sul core audio|IRQ 16 (ehci_hcd:usb1) 2, IRQ 29 (xhci_hcd) 600 in 2 minuti sul core 2, che dovrebbe restare libero" \
	"$(livecheck 'Interruzioni sul core audio')"
expect "stato: latenza non misurata per scelta" \
	"INFO|Latenza durante l'ascolto|non misurata: LATENZA_ASCOLTO=si la misura, sweetspot-latenza a riproduzione ferma" \
	"$(livecheck "Latenza durante l'ascolto")"
mkdir -p "$DSP/proc/asound/card0/pcm0p/sub0"
printf 'state: RUNNING\n' > "$DSP/proc/asound/card0/pcm0p/sub0/status"
# Tre finestre di misura, poi il player "sparisce" e la sorveglianza si ferma.
LATSTUB="cyclictest() { n=\$(( \$(cat '$DSP/run/finestre' 2>/dev/null || echo 0) + 1 )); echo \$n > '$DSP/run/finestre'
	case \$n in 1) m=50 ;; 2) m=120 ;; *) m=30 ;; esac
	echo \"T: 0 (  1) P:85 I:10000 C:   3000 Min:      2 Act:    5 Avg:    4 Max:     \$m\"; }
kill() { [ \"\$(cat '$DSP/run/finestre' 2>/dev/null)\" != 3 ]; }"
SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	$TEST_SH -c "$LATSTUB
set -- --ascolto 3; . $OVERLAY/usr/bin/sweetspot-latenza"
expect "latenza in ascolto: massima, finestre, ultima" "120 3 30" "$(cat "$DSP/run/latenza.ascolto")"
expect "stato: latenza durante l'ascolto" "OK|Latenza durante l'ascolto|massima 120 us in 3 finestre di 30 s (ultima 30 us)" \
	"$(livecheck "Latenza durante l'ascolto")"
echo "400 4 400" > "$DSP/run/latenza.ascolto"
expect "stato: latenza alta durante l'ascolto" \
	"ATTENZIONE|Latenza durante l'ascolto|massima 400 us in 4 finestre di 30 s (ultima 400 us): prova il profilo 'prestazioni' e le impostazioni del BIOS" \
	"$(livecheck "Latenza durante l'ascolto")"

echo "Silenzio elettrico"
Q=$WORK/quiet
qreset() {
	rm -rf "$Q"
	mkdir -p "$Q/run" "$Q/proc" "$Q/sys/devices/system/cpu" "$Q/sys/devices/virtual/workqueue" \
		"$Q/sys/bus/workqueue/devices/writeback" "$Q/sys/bus/usb/devices/usb1"
	echo "BOOT_IMAGE=/bzImage quiet" > "$Q/proc/cmdline"
	printf 'MemTotal:       16303112 kB\nMemAvailable:   15000000 kB\n' > "$Q/proc/meminfo"
	: > "$Q/proc/mounts"
	echo 0-3 > "$Q/sys/devices/system/cpu/online"
	echo 2-3 > "$Q/sys/devices/system/cpu/isolated"
	echo f > "$Q/sys/devices/virtual/workqueue/cpumask"
	echo f > "$Q/sys/bus/workqueue/devices/writeback/cpumask"
	for l in input3::capslock tpacpi::power phy0-led; do
		mkdir -p "$Q/sys/class/leds/$l"
		echo 1 > "$Q/sys/class/leds/$l/brightness"
		echo "none [default-on]" > "$Q/sys/class/leds/$l/trigger"
	done
	# webcam, DAC, Bluetooth, webcam con microfono, periferica senza interfacce
	for d in "1-1 Webcam 0e 0e" "1-2 DAC 01 01" "1-3 Bluetooth e0 e0" "1-4 Camera 0e 01" "1-5 Vuota"; do
		set -- $d
		mkdir -p "$Q/sys/bus/usb/devices/$1/power"
		echo 1 > "$Q/sys/bus/usb/devices/$1/authorized"
		echo on > "$Q/sys/bus/usb/devices/$1/power/control"
		echo "$2" > "$Q/sys/bus/usb/devices/$1/product"
		dev=$1; shift 2; n=0
		for c in "$@"; do
			mkdir -p "$Q/sys/bus/usb/devices/$dev:1.$n"
			echo "$c" > "$Q/sys/bus/usb/devices/$dev:1.$n/bInterfaceClass"
			n=$((n + 1))
		done
		printf ' %s\n' "$n" > "$Q/sys/bus/usb/devices/$dev/bNumInterfaces"
	done
	# PCI: video integrato (console), GPU discreta dietro un ponte, audio
	# integrato, controller USB, rete con cavo, Wi-Fi e rete senza cavo
	# ciascuna dietro il proprio ponte.
	mkdir -p "$Q/sys/bus/pci/devices"
	for p in "00:01.0 0x060400" "00:01.0/0000:01:00.0 0x030200" "00:02.0 0x030000 vga" "00:14.0 0x0c0330" \
		"00:1b.0 0x040300" "00:1c.0 0x060400" "00:1c.0/0000:02:00.0 0x020000 enp2s0 1" \
		"00:1c.1 0x060400" "00:1c.1/0000:03:00.0 0x028000" "00:1c.2 0x060400" "00:1c.2/0000:04:00.0 0x020000 enp4s0 0"; do
		set -- $p
		d=$Q/sys/devices/pci0000:00/0000:$1
		mkdir -p "$d/power"
		echo "$2" > "$d/class"
		echo on > "$d/power/control"
		echo active > "$d/power/runtime_status"
		[ "${3:-}" = vga ] && echo 1 > "$d/boot_vga"
		if [ -n "${4:-}" ]; then
			# Interfaccia gia' su (flags con IFF_UP), con o senza cavo.
			mkdir -p "$d/net/$3" "$Q/sys/class/net"
			echo "$4" > "$d/net/$3/carrier"
			echo 0x1003 > "$d/net/$3/flags"
			echo 1 > "$d/net/$3/type"
			mkdir -p "$d/net/$3/device"
			ln -sfn "$d/net/$3" "$Q/sys/class/net/$3"
		fi
		ln -s "$d" "$Q/sys/bus/pci/devices/${d##*/}"
	done
}
pcistate() { for b in 00:01.0 00:01.0/0000:01:00.0 00:02.0 00:14.0 00:1b.0 00:1c.0 00:1c.0/0000:02:00.0 00:1c.1 00:1c.1/0000:03:00.0 00:1c.2 00:1c.2/0000:04:00.0; do
	printf '%s ' "$(cat "$Q/sys/devices/pci0000:00/0000:$b/power/control")"; done; }
quiet() { # [comando]
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SILENZIO_ATTESA=0 \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-silenzio" "${1:-applica}"
}
usbstate() { for d in 1-1 1-2 1-3 1-4 1-5; do printf '%s ' "$(cat "$Q/sys/bus/usb/devices/$d/authorized")$(cat "$Q/sys/bus/usb/devices/$d/power/control")"; done; }
qreset
quiet
expect "LED: spenti senza trigger, la tastiera resta" "1 0 0|none none" \
	"$(cat "$Q/sys/class/leds/input3::capslock/brightness" "$Q/sys/class/leds/tpacpi::power/brightness" "$Q/sys/class/leds/phy0-led/brightness" | tr '\n' ' ' | sed 's/ $//')|$(cat "$Q/sys/class/leds/tpacpi::power/trigger" "$Q/sys/class/leds/phy0-led/trigger" | tr '\n' ' ' | sed 's/ $//')"
expect "USB: webcam e Bluetooth scollegate, DAC e periferiche miste intatte" "0auto 1on 0auto 1on 1on " "$(usbstate)"
expect "workqueue solo sui core di sistema" "3 3" \
	"$(cat "$Q/sys/devices/virtual/workqueue/cpumask" "$Q/sys/bus/workqueue/devices/writeback/cpumask" | tr '\n' ' ' | sed 's/ $//')"
expect "registro: periferiche scollegate per nome" "2" "$(grep -c 'silenzio: USB 1-[13] (\(Webcam\|Bluetooth\)) scollegata' "$Q/log")"
expect "PCI: a riposo GPU discreta, audio integrato, Wi-Fi e i loro ponti; console, USB e schede di rete (ancora da decidere) intatte" \
	"auto auto on on auto on on auto auto on on " "$(pcistate)"
# Le schede di rete si decidono a rete su (S40sweetspot-net): solo quelle
# attive e senza cavo; una scheda ancora giu' non si tocca.
echo 0x1002 > "$Q/sys/devices/pci0000:00/0000:00:1c.2/0000:04:00.0/net/enp4s0/flags"
quiet rete
expect "rete: scheda senza cavo ma non ancora attivata: lasciata stare" "on on " \
	"$(cat "$Q/sys/devices/pci0000:00/0000:00:1c.2/power/control") $(cat "$Q/sys/devices/pci0000:00/0000:00:1c.2/0000:04:00.0/power/control") "
echo 0x1003 > "$Q/sys/devices/pci0000:00/0000:00:1c.2/0000:04:00.0/net/enp4s0/flags"
quiet rete
expect "rete: a riposo la scheda attiva senza cavo e il suo ponte, la scheda con il cavo resta" \
	"auto auto on on auto on on auto auto auto auto " "$(pcistate)"
expect "PCI: elenco per la pagina Stato" \
	"0000:00:1b.0|audio integrato 0000:01:00.0|scheda video secondaria 0000:03:00.0|Wi-Fi 0000:04:00.0|scheda di rete senza cavo" \
	"$(tr '\n' ' ' < "$Q/run/silenzio.pci" | sed 's/ $//')"
# Periferiche collegate dopo l'avvio (regola udev, un evento per interfaccia).
usbplug() { # periferica prodotto classi...
	local dev=$1 n=0
	mkdir -p "$Q/sys/bus/usb/devices/$dev/power"
	echo 1 > "$Q/sys/bus/usb/devices/$dev/authorized"
	echo on > "$Q/sys/bus/usb/devices/$dev/power/control"
	echo "$2" > "$Q/sys/bus/usb/devices/$dev/product"
	shift 2
	for c in "$@"; do
		mkdir -p "$Q/sys/bus/usb/devices/$dev:1.$n"
		echo "$c" > "$Q/sys/bus/usb/devices/$dev:1.$n/bInterfaceClass"
		n=$((n + 1))
	done
	printf ' %s\n' "$n" > "$Q/sys/bus/usb/devices/$dev/bNumInterfaces"
}
plugevent() {
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-silenzio" usb "/devices/pci0000:00/0000:00:14.0/usb1/$1/$1:1.0"
}
usbplug 1-7 Webcam 0e
usbplug 1-8 "Webcam con microfono" 0e 01
plugevent 1-7; plugevent 1-8
expect "USB collegate dopo: webcam scollegata, webcam con microfono intatta" "0auto 1on" \
	"$(cat "$Q/sys/bus/usb/devices/1-7/authorized")$(cat "$Q/sys/bus/usb/devices/1-7/power/control") $(cat "$Q/sys/bus/usb/devices/1-8/authorized")$(cat "$Q/sys/bus/usb/devices/1-8/power/control")"
qcheck() { # voce
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$Q/squeezelite.log \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati 2>/dev/null | grep "^[A-Z]*|$1|"
}
expect "stato: LED spenti" "OK|LED|spenti (tranne quelli della tastiera)" "$(qcheck LED)"
expect "stato: USB scollegate, anche quelle collegate dopo" "OK|USB inutilizzate|scollegate dai driver: Webcam, Bluetooth, Webcam" "$(qcheck 'USB inutilizzate')"
expect "stato: workqueue sui core di sistema" "OK|Lavoro differito del kernel|workqueue solo sui core di sistema 0,1" \
	"$(qcheck 'Lavoro differito del kernel')"
mkdir -p "$Q/sys/class/drm/card0-HDMI-A-1" "$Q/sys/class/backlight/intel_backlight"
echo connected > "$Q/sys/class/drm/card0-HDMI-A-1/status"
echo On > "$Q/sys/class/drm/card0-HDMI-A-1/dpms"
echo 4 > "$Q/sys/class/backlight/intel_backlight/bl_power"
expect "stato: schermo e retroilluminazione" \
	"INFO|Schermo|HDMI-A-1 On, retroilluminazione spenta; si spegne dopo 2 minuti senza tasti (0 = mai)" "$(qcheck Schermo)"
echo suspended > "$Q/sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/power/runtime_status"
expect "stato: PCI con lo stato reale" \
	"INFO|PCI a riposo|audio integrato 0000:00:1b.0 attivo (active), scheda video secondaria 0000:01:00.0 a riposo, Wi-Fi 0000:03:00.0 attivo (active), scheda di rete senza cavo 0000:04:00.0 attivo (active); un dispositivo senza driver o che non lo supporta resta attivo" \
	"$(qcheck 'PCI a riposo')"
for b in 00:1b.0 00:1c.1/0000:03:00.0 00:1c.2/0000:04:00.0; do echo suspended > "$Q/sys/devices/pci0000:00/0000:$b/power/runtime_status"; done
expect "stato: tutti i PCI a riposo" \
	"OK|PCI a riposo|audio integrato 0000:00:1b.0 a riposo, scheda video secondaria 0000:01:00.0 a riposo, Wi-Fi 0000:03:00.0 a riposo, scheda di rete senza cavo 0000:04:00.0 a riposo" \
	"$(qcheck 'PCI a riposo')"
qreset
expect "stato: workqueue anche sui core isolati" "ATTENZIONE|Lavoro differito del kernel|workqueue anche sui core isolati (maschera f)" \
	"$(qcheck 'Lavoro differito del kernel')"
expect "stato: LED accesi elencati" "INFO|LED|accesi: phy0-led tpacpi::power" "$(qcheck LED)"
echo PERIFERICHE_INUTILIZZATE=accese > "$Q/run/sweetspot.conf"
quiet; quiet rete
expect "PERIFERICHE_INUTILIZZATE=accese: periferiche lasciate stare" "1on 1on 1on 1on 1on |on on on on on on on on on on on " "$(usbstate)|$(pcistate)"
qreset
echo OTTIMIZZAZIONI=no > "$Q/run/sweetspot.conf"
quiet; quiet rete
expect "ottimizzazioni spente: niente silenzio" "1on 1on 1on 1on 1on |on on on on on on on on on on on |1|f" \
	"$(usbstate)|$(pcistate)|$(cat "$Q/sys/class/leds/phy0-led/brightness")|$(cat "$Q/sys/devices/virtual/workqueue/cpumask")"
usbplug 1-7 Webcam 0e
plugevent 1-7
expect "ottimizzazioni spente: USB collegate dopo lasciate stare" "1on" \
	"$(cat "$Q/sys/bus/usb/devices/1-7/authorized")$(cat "$Q/sys/bus/usb/devices/1-7/power/control")"
qreset
echo USCITA_INTEGRATA=si > "$Q/run/sweetspot.conf"
echo WIFI_NOME=casa >> "$Q/run/sweetspot.conf"
quiet
expect "audio integrato scelto e Wi-Fi configurato: restano attivi" "on on" \
	"$(cat "$Q/sys/devices/pci0000:00/0000:00:1b.0/power/control") $(cat "$Q/sys/devices/pci0000:00/0000:00:1c.1/0000:03:00.0/power/control")"

echo "Watchdog e prova di durata"
qreset
expect "stato: watchdog non attivo" "ATTENZIONE|Watchdog|non attivo: un blocco totale richiede di spegnere a mano" "$(qcheck Watchdog)"
mkdir -p "$Q/sys/class/watchdog/watchdog0"
echo active > "$Q/sys/class/watchdog/watchdog0/state"
echo "iTCO_wdt" > "$Q/sys/class/watchdog/watchdog0/identity"
echo 60 > "$Q/sys/class/watchdog/watchdog0/timeout"
qwd() {
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$Q/squeezelite.log \
		$TEST_SH -c "pidof() { echo 99; }
set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" 2>/dev/null | grep '^[A-Z]*|Watchdog|'
}
expect "stato: watchdog attivo e alimentato" "OK|Watchdog|iTCO_wdt: riavvio dopo 60 secondi di blocco totale" "$(qwd)"
echo WATCHDOG=no > "$Q/run/sweetspot.conf"
expect "stato: watchdog spento per scelta" "INFO|Watchdog|spento (WATCHDOG=no): un blocco totale richiede di spegnere a mano" "$(qwd)"
# I moduli del watchdog hardware (iTCO_wdt, sp5100_tco) restano in
# blacklist solo con WATCHDOG=no: con il watchdog acceso li carica S21.
blacklist() { # impostazioni
	printf '%s\n' "$1" > "$Q/run/sweetspot.conf"
	mkdir -p "$Q/modprobe.d"
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_MODPROBE_D=$Q/modprobe.d SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/etc/init.d/S03sweetspot-early; write_blacklist"
	grep -c 'blacklist \(iTCO_wdt\|sp5100_tco\)' "$Q/modprobe.d/sweetspot-run.conf"
}
expect "watchdog acceso: i moduli del chipset non sono in blacklist" "0|1" "$(blacklist '')|$(grep -c 'blacklist pcspkr' "$Q/modprobe.d/sweetspot-run.conf")"
expect "watchdog spento: i moduli del chipset restano in blacklist" "2" "$(blacklist 'WATCHDOG=no')"
# S21: tempo limitato al massimo del dispositivo (Raspberry Pi: 15 s),
# riavvio precedente del watchdog segnalato.
echo 15 > "$Q/sys/class/watchdog/watchdog0/max_timeout"
echo 32 > "$Q/sys/class/watchdog/watchdog0/bootstatus"
rm -f "$Q/run/sweetspot.conf" "$Q/run/taskset.call"
SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_WATCHDOG_DEV=/dev/null \
	$TEST_SH -c "modprobe() { echo \"\$*\" >> '$Q/run/modprobe.call'; }; udevadm() { :; }; taskset() { echo \"\$*\" >> '$Q/run/taskset.call'; }
set -- start; . $OVERLAY/etc/init.d/S21sweetspot-watchdog" > /dev/null 2>&1
expect "S21: tempo del watchdog limitato al massimo del dispositivo" "-c 0 chrt -f 5 watchdog -T 15 -t 5 /dev/null" "$(cat "$Q/run/taskset.call")"
expect "S21: riavvio precedente del watchdog annotato" "32|1" "$(cat "$Q/run/watchdog.riavvio")|$(grep -c 'riavvio del watchdog (bootstatus 32)' "$Q/log")"
rm -f "$Q/sys/class/watchdog/watchdog0/max_timeout" "$Q/sys/class/watchdog/watchdog0/bootstatus" "$Q/run/watchdog.riavvio" "$Q/run/taskset.call" "$Q/run/modprobe.call"
echo VOLUME=dsp > "$Q/run/sweetspot.conf"
echo dsp > "$Q/run/volume.modo"
echo "50 -30.0 0" > "$Q/run/volume.dsp"
expect "stato: volume a 64 bit in uso" \
	"OK|Volume|a 64 bit in CamillaDSP con dither all'uscita (anche al 100%), Squeezelite lascia i campioni invariati (ora 50, -30.0 dB); non e' bit-perfect, ma senza troncamenti" \
	"$(qcheck Volume)"
echo riserva > "$Q/run/volume.modo"
expect "stato: volume a 64 bit non disponibile, riserva software" \
	"ATTENZIONE|Volume|a 64 bit non disponibile (CamillaDSP non avviato o modalita' player): in uso il volume software, senza dither" \
	"$(qcheck Volume)"
rm -f "$Q/run/sweetspot.conf" "$Q/run/volume.modo" "$Q/run/volume.dsp"
mkdir -p "$Q/proc/asound/card1/pcm0p/sub0" "$Q/chiavetta"
printf 'state: RUNNING\n' > "$Q/proc/asound/card1/pcm0p/sub0/status"
echo 777 > "$Q/run/squeezelite.pid"
printf 'avvio\n' > "$Q/squeezelite.log"
durata() {
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$Q/squeezelite.log \
		SWEETSPOT_STICK_DIR=$Q/chiavetta SWEETSPOT_DURATA_SECONDI=2 \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-durata" 0 1 > /dev/null 2>&1
}
durata && rc=0 || rc=$?
expect "durata: ascolto continuo riuscito" "0|Prova di durata: RIUSCITA" "$rc|$(head -n 1 "$Q/run/durata.txt")"
expect "durata: esito copiato sulla chiavetta" "Prova di durata: RIUSCITA" "$(head -n 1 "$Q/chiavetta/durata.txt" 2>/dev/null)"
expect "durata: una riga per misura con intestazione" "ora,in_riproduzione,pid_player,xrun,memoria_kb,temperatura" "$(head -n 1 "$Q/run/durata.csv")"
printf 'state: XRUN\n' > "$Q/proc/asound/card1/pcm0p/sub0/status"
durata && rc=0 || rc=$?
expect "durata: uscita ferma, prova non riuscita" "1|Prova di durata: NON RIUSCITA|uscita in riproduzione: 0% delle misure (minimo 95%)" \
	"$rc|$(head -n 1 "$Q/run/durata.txt")|$(grep '^uscita' "$Q/run/durata.txt")"

echo "Modalita' ascolto"
expect "stato: ascolto puro in attesa della musica" \
	"OK|Ascolto|ascolto puro (coda in RAM, dischi fermi, lavori di fondo sospesi): si attiva quando la musica suona" "$(qcheck Ascolto)"
printf 'state: RUNNING\n' > "$Q/proc/asound/card1/pcm0p/sub0/status"
printf -- '-123\n-456\n' > "$Q/run/ascolto.fermi"
expect "stato: lavori sospesi durante la musica" \
	"OK|Ascolto|ascolto puro (coda in RAM, dischi fermi, lavori di fondo sospesi): ora 2 lavori sospesi" "$(qcheck Ascolto)"
echo PRECARICO=no > "$Q/run/sweetspot.conf"
expect "stato: solo lavori sospesi" "OK|Ascolto|lavori di fondo sospesi durante la musica: ora 2 lavori sospesi" "$(qcheck Ascolto)"
echo MODALITA_ASCOLTO=no > "$Q/run/sweetspot.conf"
expect "stato: modalita' ascolto spenta" \
	"INFO|Ascolto|modalità spenta: lettura della libreria, copie e ripping continuano anche durante la musica" "$(qcheck Ascolto)"
rm -f "$Q/run/sweetspot.conf" "$Q/run/ascolto.fermi"

echo "Prova dell'ascolto puro: letture dal disco e rete durante l'ascolto"
# Disco sdb con la musica (partizione sdb1 montata da sweetspot-dischi), una
# scheda di rete e lo.
mkdir -p "$Q/sys/devices/virtual/block/sdb/queue" "$Q/sys/devices/virtual/block/sdb/sdb1" "$Q/sys/class/block" "$Q/sys/block/sdb" "$Q/proc/net"
echo 1000000 > "$Q/sys/devices/virtual/block/sdb/size"
ln -sfn "../../devices/virtual/block/sdb/sdb1" "$Q/sys/class/block/sdb1"
printf 'Musica|sdb1|ext4|1G|ro|/media/Musica|\n' > "$Q/run/dischi.list"
iostat() { # settori_letti byte_rx byte_tx
	printf '100 0 %s 0 0 0 0 0 0 0 0\n' "$1" > "$Q/sys/block/sdb/stat"
	printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0\n  eth0: %s 10 0 0 0 0 0 0 %s 10 0 0 0 0 0 0\n' "$2" "$3" > "$Q/proc/net/dev"
}
ascfn() { # funzione
	SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-ascolto; $1"
}
iostat 20480 1000 2000
expect "contatori: disco con la musica (intero) e rete senza lo" "disco sdb 20480|rete 3000" "$(ascfn io_counters | tr '\n' '|' | sed 's/|$//')"
ascfn io_start
expect "inizio dell'ascolto annotato" "1|disco sdb 20480|rete 3000" \
	"$(grep -c '^inizio [0-9]' "$Q/run/ascolto.io")|$(grep '^disco' "$Q/run/ascolto.io")|$(grep '^rete' "$Q/run/ascolto.io")"
# L'ascolto e' iniziato un minuto fa.
sed -i "s/^inizio .*/inizio $(( $(date +%s) - 60 ))/" "$Q/run/ascolto.io"
expect "stato: nessuna lettura e solo controllo durante l'ascolto in corso" \
	"OK|Letture dal disco durante l'ascolto|nessuna durante l'ascolto in corso (1 min) da sdb: la musica suona dalla RAM|OK|Rete durante l'ascolto|0 KB durante l'ascolto in corso (1 min): solo il controllo (browser, app)" \
	"$(qcheck 'Letture dal disco durante l.ascolto')|$(qcheck 'Rete durante l.ascolto')"
iostat $((20480 + 4096)) 1000 $((2000 + 30 * 1024))
expect "stato: 2 MB letti dal disco e 30 KB di rete" \
	"INFO|Letture dal disco durante l'ascolto|2 MB durante l'ascolto in corso (1 min) da sdb (precarico in corso, file oltre il budget o fuori dal precarico)|OK|Rete durante l'ascolto|30 KB durante l'ascolto in corso (1 min): solo il controllo (browser, app)" \
	"$(qcheck 'Letture dal disco durante l.ascolto')|$(qcheck 'Rete durante l.ascolto')"
iostat $((20480 + 4096)) $((1000 + 5 * 1048576)) $((2000 + 30 * 1024))
case "$(qcheck 'Rete durante l.ascolto')" in "INFO|Rete durante l'ascolto|5150 KB durante l'ascolto in corso (1 min) ("*" KB/s): streaming, cartelle di rete o precarico dalla rete") ok "stato: rete usata durante l'ascolto segnalata" ;; *) ko "stato rete ascolto" "INFO 5150 KB" "$(qcheck 'Rete durante l.ascolto')" ;; esac
ascfn io_stop
iostat $((20480 + 999999)) $((1000 + 9 * 1048576)) 2000
expect "fine dell'ascolto: i contatori di arrivo restano, quelli dopo non contano" \
	"1|fine_disco sdb 24576|INFO|Letture dal disco durante l'ascolto|2 MB nell'ultimo ascolto (1 min) da sdb (precarico in corso, file oltre il budget o fuori dal precarico)" \
	"$(grep -c '^fine [0-9]' "$Q/run/ascolto.io")|$(grep '^fine_disco' "$Q/run/ascolto.io")|$(qcheck 'Letture dal disco durante l.ascolto')"
ascfn io_stop
expect "seconda fine: non si scrive due volte" "1" "$(grep -c '^fine [0-9]' "$Q/run/ascolto.io")"
rm -f "$Q/run/ascolto.io" "$Q/run/dischi.list" "$Q/sys/block/sdb/stat"
expect "senza ascolto registrato: nessuna voce" "" "$(qcheck 'Letture dal disco durante l.ascolto')$(qcheck 'Rete durante l.ascolto')"

echo "Rapporto e matrice di compatibilita'"
rm -rf "$Q/sys/class/net"
mkdir -p "$Q/sys/class/dmi/id" "$Q/repbin" "$Q/sys/class/net/eth0/device" "$Q/drivers/r8169"
echo ASUSTeK > "$Q/sys/class/dmi/id/sys_vendor"
echo N550JV > "$Q/sys/class/dmi/id/product_name"
echo 1 > "$Q/sys/class/net/eth0/carrier"
ln -sfn "$Q/drivers/r8169" "$Q/sys/class/net/eth0/device/driver"
printf '#!/bin/sh\nprintf "OK|Rete|indirizzo 192.168.1.20\\nINFO|Interfaccia|http://salotto.local/\\nOK|XRUN nella sessione|nessuno in 5 minuti\\nATTENZIONE|Turbo|attivo, vedi http://192.168.1.20/\\n"\n' > "$Q/repbin/sweetspot-check"
chmod +x "$Q/repbin/sweetspot-check"
rap=$(SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
	$TEST_SH -c "PATH=$Q/repbin:\$PATH; . $OVERLAY/usr/bin/sweetspot-rapporto" 2>/dev/null)
expect "rapporto: JSON con computer e rete" "1|ASUSTeK|N550JV|r8169 ethernet true" \
	"$(printf '%s' "$rap" | jq -r '[.formato, .computer.produttore, .computer.modello, (.rete[0] | "\(.driver) \(.tipo) \(.collegata)")] | join("|")' 2>/dev/null)"
expect "rapporto: senza indirizzi ne' voci di rete" "XRUN nella sessione|Turbo|attivo, vedi [indirizzo]" \
	"$(printf '%s' "$rap" | jq -r '[.verifiche[].voce] + [.verifiche[-1].dettaglio] | join("|")' 2>/dev/null)"
expect "rapporto: nessun 192.168 nel testo" "0" "$(printf '%s' "$rap" | grep -c '192\.168')"
if command -v python3 > /dev/null; then
	mkdir -p "$Q/matrice"
	printf '%s\n' "$rap" > "$Q/matrice/prova.json"
	python3 "$ROOT/tools/matrice-compatibilita.py" --rapporti "$Q/matrice" --pagina "$Q/matrice.md"
	expect "matrice: una riga dal rapporto, avvisi contati" "1|1" \
		"$(grep -c '^| .*ASUSTeK N550JV' "$Q/matrice.md")|$(grep '^| .*ASUSTeK' "$Q/matrice.md" | awk -F'|' '{gsub(/ /, "", $8); print $8}')"
	expect "matrice: docs/compatibilita.md aggiornata" "0" \
		"$(python3 "$ROOT/tools/matrice-compatibilita.py" --verifica > /dev/null 2>&1; echo $?)"
fi

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
python3 "$ROOT/tests/precarica.py" || exit 1
python3 "$ROOT/tests/prova-dop.py" || exit 1
python3 "$ROOT/tests/release-gates.py"
