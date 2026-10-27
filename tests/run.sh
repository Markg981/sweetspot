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
trap 'kill ${UPD_SUP:-} 2>/dev/null; rm -rf "$WORK"' EXIT
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

# Sezioni saltate perche' manca uno strumento. In locale sono ammesse ma
# elencate; in CI (CI=true o SWEETSPOT_CI_STRICT=1) sono un errore.
SALTATE=""
salta() {
	SALTATE="$SALTATE $1"
	echo "  (strumento \"$1\" non installato: sezione saltata)"
}
verifica_salti() {
	[ -n "$SALTATE" ] || return 0
	echo "=================================================================="
	echo "ATTENZIONE: sezioni saltate per strumenti mancanti:$SALTATE"
	echo "La suite NON ha verificato tutto: installali per una prova completa."
	echo "=================================================================="
	case "${SWEETSPOT_CI_STRICT:-${CI:-}}" in
	1 | true)
		echo "NO  in modalita' rigorosa (CI) i salti sono un errore"
		exit 1
		;;
	esac
}
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

# Un'impronta scritta male in un .hash ferma la build dopo mezz'ora: qui si
# vede subito (lunghezza per algoritmo, solo cifre esadecimali minuscole).
echo "Impronte dei pacchetti"
expect "file .hash: impronte ben formate" "" "$(awk '
	$1 == "sha256" { n = 64 } $1 == "sha512" { n = 128 } $1 == "sha1" { n = 40 } $1 == "md5" { n = 32 }
	$1 ~ /^(sha256|sha512|sha1|md5)$/ && (length($2) != n || $2 !~ /^[0-9a-f]+$/) { printf "%s: %s %s ", FILENAME, $1, $3 }
' "$ROOT"/package/*/*.hash)"

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
expect "buffer 16 GB (senza MemAvailable: totale meno 768 MB)" "65536:131072" "$(run "$N550" player_buffers)"
expect "buffer 2 GB senza MemAvailable: minimi" "32768:65536" "$(run "$DUAL" player_buffers)"
expect "buffer 1 GB: minimi" "32768:65536" "$(run "$ONE" player_buffers)"
# Buffer dal carico reale: MemAvailable, autonomia in secondi, riserva per modalita'.
BUF=$WORK/buffer
mkdir -p "$BUF/proc" "$BUF/run" "$BUF/sys"
bufmem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$BUF/proc/meminfo"; }
bufmem 2097152 1572864
expect "buffer 2 GiB, Lyrion locale: tetti pieni (64 MB stream, 128 MB output)" "65536:131072" "$(run "$BUF" player_buffers)"
bufmem 4194304 3670016
expect "buffer 4 GiB: tetti pieni" "65536:131072" "$(run "$BUF" player_buffers)"
bufmem 8388608 7864320
expect "buffer 8 GiB: come 4 GiB, non crescono con la memoria (non piu' 3 GiB)" "65536:131072" "$(run "$BUF" player_buffers)"
bufmem 8388608 600000
expect "buffer 8 GiB ma disponibile bassa: minimi" "32768:65536" "$(run "$BUF" player_buffers)"
bufmem 8388608 9999999
expect "MemAvailable oltre il totale: si usa il totale" "65536:131072" "$(run "$BUF" player_buffers)"
bufmem 2097152 1572864
printf 'MODALITA=player\n' > "$BUF/run/sweetspot.conf"
expect "buffer 2 GiB, solo player: tetti pieni" "65536:131072" "$(run "$BUF" player_buffers)"
printf 'MODALITA=completa\nCORREZIONE=si\n' > "$BUF/run/sweetspot.conf"
expect "buffer 2 GiB con Lyrion e DSP: riserva maggiore" "40960:81920" "$(run "$BUF" player_buffers)"
# Budget RAM unico: le quote (sistema, servizi, ALSA, stream, output, precarico).
quote() { run "$BUF" ram_quote | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $1, $2 }'; }
rm -f "$BUF/run/sweetspot.conf"
bufmem 2097152 1572864
expect "quote 2 GiB con Lyrion locale: il precarico prende il resto" \
	"totale=2097152 disponibile=1572864 capitale=1572864 sistema=262144 servizi=786432 alsa=16384 stream=65536 output=131072 precarico=311296" "$(quote)"
printf 'MODALITA=completa\nCORREZIONE=si\n' > "$BUF/run/sweetspot.conf"
expect "quote 2 GiB con Lyrion e DSP: buffer limitati, precarico del resto" \
	"totale=2097152 disponibile=1572864 capitale=1572864 sistema=262144 servizi=1048576 alsa=16384 stream=40960 output=81920 precarico=122880" "$(quote)"
rm -f "$BUF/run/sweetspot.conf"
bufmem 8388608 7864320
expect "quote 8 GiB: i buffer del player non salgono a 3 GiB, il resto va al precarico" \
	"totale=8388608 disponibile=7864320 capitale=7864320 sistema=262144 servizi=786432 alsa=16384 stream=65536 output=131072 precarico=6602752" "$(quote)"
# 300 MiB disponibili: meno della riserva, nessun precarico (prima ne bloccava 150).
bufmem 2097152 307200
expect "quote con 300 MiB disponibili: buffer al minimo, precarico zero" \
	"totale=2097152 disponibile=307200 capitale=307200 sistema=262144 servizi=786432 alsa=16384 stream=32768 output=65536 precarico=0" "$(quote)"
# Qualunque sia la memoria disponibile, con un precarico non vuoto resta
# almeno la riserva (sistema+servizi+ALSA) fuori da buffer e precarico.
ok=si
for a in 1200000 1500000 2000000 3000000 5000000 8000000; do
	bufmem 8388608 $a
	q=$(run "$BUF" ram_quote | awk '{ v[$1] = $2 } END { print v["capitale"] - v["sistema"] - v["servizi"] - v["alsa"] - v["stream"] - v["output"] - v["precarico"] }')
	[ "$q" -ge 0 ] || ok="no ($a: $q)"
done
expect "quote: mai oltre il capitale (sistema+servizi+ALSA restano liberi)" "si" "$ok"
rm -f "$BUF/run/sweetspot.conf" "$BUF/log"
bufmem 2097152 1572864
run "$BUF" 'PLAYER_BUFFERS_LOG=1 player_buffers' > /dev/null
expect "buffer registrati nel log con il motivo" "1" "$(grep -c 'player: buffer stream 65536 KB, output 131072 KB.*precarico 311296 KB.*Lyrion locale.*tetti pieni' "$BUF/log")"
run "$BUF" player_buffers > /dev/null
expect "senza PLAYER_BUFFERS_LOG il log non cresce" "1" "$(wc -l < "$BUF/log" | tr -d ' ')"

echo "Protezione dall'OOM killer"
OOM=$WORK/oom
mkdir -p "$OOM/proc/100" "$OOM/proc/200" "$OOM/proc/300"
for p in 100 200 300; do echo 0 > "$OOM/proc/$p/oom_score_adj"; done
printf 'perl\0/usr/lib/lyrion/scanner.pl\0--rescan\0' > "$OOM/proc/200/cmdline"
printf 'perl\0/usr/lib/lyrion/slimserver.pl\0' > "$OOM/proc/300/cmdline"
printf 'squeezelite\0' > "$OOM/proc/100/cmdline"
run "$OOM" oom_adj -1000 100 999
expect "player mai ucciso (-1000)" "-1000" "$(cat "$OOM/proc/100/oom_score_adj")"
expect "pid inesistente ignorato" "0" "$(run "$OOM" 'oom_adj 500 999; echo $?')"
run "$OOM" oom_adj_cmd 500 scanner.pl
expect "scanner tra i primi a cadere (+500)" "500" "$(cat "$OOM/proc/200/oom_score_adj")"
expect "server Lyrion non toccato dallo scanner" "0" "$(cat "$OOM/proc/300/oom_score_adj")"
grep -q 'oom_adj -1000 "\$PID"' "$OVERLAY/usr/bin/sweetspot-player" && ok "player: squeezelite a -1000" || ko "player: squeezelite a -1000" "presente" "assente"
grep -q '\[ -z "\$rs" \] && \[ -z "\$dsp" \] && printf .%s\\n. -H' "$OVERLAY/usr/bin/sweetspot-player" && ok "player: Originale senza ripiego su plughw: (-H)" || ko "player: Originale -H" "presente" "assente"
grep -q 'oom_adj -1000 "\$p"' "$OVERLAY/usr/bin/sweetspot-player" && ok "player: CamillaDSP a -1000" || ko "player: CamillaDSP a -1000" "presente" "assente"
grep -q 'oom_adj -100 ' "$OVERLAY/usr/bin/sweetspot-lms" && ok "lms: Lyrion leggermente protetto" || ko "lms: Lyrion leggermente protetto" "presente" "assente"
grep -q 'oom_adj_cmd 500 scanner.pl' "$OVERLAY/usr/bin/sweetspot-stato" && ok "stato: scanner a +500 (evento rescan)" || ko "stato: scanner a +500" "presente" "assente"
grep -q 'oom_score_adj' "$OVERLAY/usr/bin/sweetspot-copia" && ok "copia: lavoro sospendibile a +500" || ko "copia: lavoro sospendibile a +500" "presente" "assente"
grep -q 'oom_adj 500' "$OVERLAY/usr/bin/sweetspot-cd" && ok "ripping: lavoro sospendibile a +500" || ko "ripping: lavoro sospendibile a +500" "presente" "assente"
grep -q 'oom_adj 500' "$OVERLAY/usr/bin/sweetspot-precarico" && ok "precarico a +500" || ko "precarico a +500" "presente" "assente"

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
# Round-trip: quello che si scrive e' quello che si rilegge (anche con " #",
# virgolette e spazi ai bordi); se non e' rappresentabile viene rifiutato.
for v in 'Sala #2' '"Sala"' "'Sala'" ' Sala ' 'a\b$HOME' '"a" b' "l'ora #1"; do
	cfgset imposta NOME_PLAYER "$v" >/dev/null
	expect "round-trip del valore [$v]" "$v" "$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; conf NOME_PLAYER")"
done
cfgset imposta NOME_PLAYER Sala >/dev/null
expect "valore con entrambe le virgolette e spazio ai bordi rifiutato" "1" "$(cfgset imposta NOME_PLAYER " \"a'b ")"
expect "rifiutato: valore invariato" "Sala" "$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; conf NOME_PLAYER")"
printf 'NOME_PLAYER="Sala" # nota\nDSD=auto # x\n' > "$CFG/v.txt"
expect "compatibilita': virgolette seguite da commento come prima" "NOME_PLAYER=Sala|DSD=auto" \
	"$(SWEETSPOT_RUN=$CFG/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_normalize $CFG/v.txt" | tr '\n' '|' | sed 's/|$//')"

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
		LMS_CACHE_TTL=0 SWEETSPOT_WGET=$WEB/bin/wget REQUEST_METHOD=GET QUERY_STRING="" HTTP_HOST=sweetspot.local \
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

# Demone dello stato: cache, pagina e endpoint JSON.
echo "Stato in cache (demone, pagina, JSON)"
ST=$WORK/stato
mkdir -p "$ST/bin" "$ST/run" "$ST/proc/net" "$ST/proc/asound"
printf 'OK|Prova "uno"|tutto \\ bene\nATTENZIONE|Due|da guardare\n' > "$ST/righe"
printf '#!/bin/sh\ncat "%s/righe"\n' "$ST" > "$ST/bin/sweetspot-check"
chmod +x "$ST/bin/sweetspot-check"
printf 'h\nh\n  eth0: 1000 1 0 0 0 0 0 0 1000 1 0 0 0 0 0 0\n' > "$ST/proc/net/dev"
stato_env() { env SWEETSPOT_RUN=$ST/run SWEETSPOT_PROCFS=$ST/proc SWEETSPOT_LOG=$ST/log SWEETSPOT_PATH="$ST/bin:$SWEETSPOT_PATH" \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf PATH="$ST/bin:$PATH" "$@"; }
stato_cgi() { stato_env REQUEST_METHOD=GET QUERY_STRING="" HTTP_HOST=sweetspot.local $TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/$1" 2>&1; }
out=$(stato_cgi stato)
case "$out" in *"Stato non ancora disponibile"*) ok "stato: senza cache avvisa e non blocca" ;; *) ko "stato senza cache" "avviso" "$out" ;; esac
case "$(stato_cgi stato.json)" in "Status: 503"*) ok "stato.json: senza cache risponde 503" ;; *) ko "stato.json senza cache" "503" "-" ;; esac
stato_env $TEST_SH "$OVERLAY/usr/bin/sweetspot-stato" aggiorna
printf 'h\nh\n  eth0: 9000000 1 0 0 0 0 0 0 9000000 1 0 0 0 0 0 0\n' > "$ST/proc/net/dev"
sleep 1
stato_env $TEST_SH "$OVERLAY/usr/bin/sweetspot-stato" aggiorna
expect "demone: file di cache scritti, nessun residuo temporaneo" "4|0" "$(ls "$ST/run"/stato.* | grep -vc nuovo)|$(ls "$ST/run" | grep -c nuovo)"
expect "demone: cache leggibile da tutti (la legge lms)" "644|644" "$(stat -c %a "$ST/run/stato.json")|$(stat -c %a "$ST/run/stato.dati")"
case "$(cat "$ST/run/stato.dati")" in *"Due|da guardare"*"INFO|Traffico di rete ora|"*) ok "demone: righe del check e del traffico" ;; *) ko "demone righe" "righe + traffico" "$(cat "$ST/run/stato.dati")" ;; esac
case "$(cat "$ST/run/stato.json")" in '{"ts":'*'"voci":[{"esito":"OK","voce":"Prova \"uno\"","dettaglio":"tutto \\ bene"}'*']}') ok "demone: JSON con escape corretto" ;; *) ko "demone JSON" "JSON valido" "$(cat "$ST/run/stato.json")" ;; esac
out=$(stato_cgi stato)
case "$out" in *"Due"*"da guardare"*"Traffico di rete ora"*) ok "stato: la pagina rende la cache" ;; *) ko "stato da cache" "righe in cache" "$out" ;; esac
case "$out" in *"Dati non aggiornati"*) ko "stato: cache fresca" "nessun avviso" "avviso" ;; *) ok "stato: cache fresca senza avviso" ;; esac
printf '1000 10\n' > "$ST/run/stato.ts"
case "$(stato_cgi stato)" in *"Dati non aggiornati"*) ok "stato: cache vecchia mostra l'avviso" ;; *) ko "stato cache vecchia" "avviso" "-" ;; esac
out=$(stato_cgi stato.json)
case "$out" in "Content-Type: application/json"*'{"ts":'*) ok "stato.json: restituisce la cache" ;; *) ko "stato.json con cache" "JSON" "$out" ;; esac

# Liveness applicativa: Lyrion che non risponde e player che non suona.
echo "Liveness applicativa (Lyrion e player)"
LV=$WORK/liveness
mkdir -p "$LV/bin" "$LV/run" "$LV/proc/net" "$LV/proc/asound/card1/pcm0p/sub0"
cp "$ST/proc/net/dev" "$LV/proc/net/dev"
printf '#!/bin/sh\nexit 0\n' > "$LV/bin/sweetspot-check"
# wget finto che non risponde (JSON-RPC appeso) o risponde con il modo scelto;
# jq finto (accetta la risposta e restituisce il contenuto di "modo").
printf '#!/bin/sh\nexit 1\n' > "$LV/bin/wget-muto"
printf '#!/bin/sh\necho "{\\"result\\":{\\"_mode\\":\\"$(cat "%s/modo")\\"}}"\n' "$LV" > "$LV/bin/wget-ok"
printf '#!/bin/sh\nin=$(cat)\n[ -n "$in" ] || exit 1\ncase "$*" in *-e*) exit 0 ;; esac\ncat "%s/modo"\n' "$LV" > "$LV/bin/jq"
chmod +x "$LV/bin"/*
lv_env() { # wget
	local w=$1
	shift
	env SWEETSPOT_RUN=$LV/run SWEETSPOT_PROCFS=$LV/proc SWEETSPOT_LOG=$LV/log SWEETSPOT_WGET=$LV/bin/$w \
		SWEETSPOT_PATH="$LV/bin:$SWEETSPOT_PATH" SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf PATH="$LV/bin:$PATH" "$@"
}
lv_round() { lv_env "$1" $TEST_SH "$OVERLAY/usr/bin/sweetspot-stato" aggiorna; }
printf 'LIVENESS_LYRION_FALLIMENTI=3\nLIVENESS_BACKOFF_MIN=3600\nLIVENESS_LYRION_AVVIO=180\nLIVENESS_PLAYER_SECONDI=20\n' > "$LV/run/sweetspot.conf"
# Lyrion vivo (processo) ma JSON-RPC muto, avviato da molto tempo.
sleep 7200 &
LV_LMS_PID=$!
echo "$LV_LMS_PID" > "$LV/run/lms.pid"
touch -d '2000-01-01' "$LV/run/lms.pid"
lv_round wget-muto
lv_round wget-muto
expect "liveness: 2 fallimenti non riavviano Lyrion" "yes|2" "$(kill -0 $LV_LMS_PID 2>/dev/null && echo yes)|$(cut -d' ' -f1 "$LV/run/liveness.lyrion")"
lv_round wget-muto
sleep 1
expect "liveness: al terzo fallimento Lyrion e' fermato" "no" "$(kill -0 $LV_LMS_PID 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/log")" in *"liveness: Lyrion in stallo dopo 3 fallimenti, riavvio"*) ok "liveness: riavvio di Lyrion registrato nel log" ;; *) ko "liveness log" "evento di riavvio" "$(cat "$LV/log" 2>&1)" ;; esac
case "$(cat "$LV/run/stato.dati")" in *"ERRORE|Lyrion risponde|no: serverstatus senza risposta"*"riavviato"*) ok "liveness: la pagina Stato mostra il riavvio" ;; *) ko "liveness stato" "riga ERRORE" "$(cat "$LV/run/stato.dati")" ;; esac
case "$(cat "$LV/run/stato.json")" in *'"liveness":{"attiva":true,"lyrion":{"stato":"riavviato","fallimenti":3,"riavvii":1}'*) ok "liveness: stato.json espone Lyrion riavviato" ;; *) ko "liveness json" "lyrion riavviato" "$(cat "$LV/run/stato.json")" ;; esac
# Backoff: il nuovo Lyrion (appeso) non viene riavviato di nuovo subito.
sleep 7200 &
LV_LMS_PID=$!
echo "$LV_LMS_PID" > "$LV/run/lms.pid"
touch -d '2000-01-01' "$LV/run/lms.pid"
lv_round wget-muto; lv_round wget-muto; lv_round wget-muto; lv_round wget-muto
expect "liveness: il backoff impedisce un secondo riavvio ravvicinato" "yes" "$(kill -0 $LV_LMS_PID 2>/dev/null && echo yes || echo no)"
# Lyrion appena avviato: i fallimenti non contano.
rm -f "$LV/run/liveness.lyrion"
touch "$LV/run/lms.pid"
lv_round wget-muto; lv_round wget-muto; lv_round wget-muto
expect "liveness: Lyrion in avvio non viene riavviato" "yes" "$(kill -0 $LV_LMS_PID 2>/dev/null && echo yes || echo no)"
kill $LV_LMS_PID 2>/dev/null
rm -f "$LV/run/lms.pid" "$LV/run/liveness.lyrion"
# Player: Lyrion dice play ma il PCM e' fermo (file status finto).
sleep 7200 &
LV_SQ_PID=$!
echo "$LV_SQ_PID" > "$LV/run/squeezelite.pid"
echo 02:53:57:45:45:54 > "$LV/run/player.mac"
echo play > "$LV/modo"
printf 'state: SETUP\n' > "$LV/proc/asound/card1/pcm0p/sub0/status"
lv_round wget-ok
expect "liveness: play senza PCM RUNNING, sotto soglia, il player resta" "yes" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
echo "100000 0 0 0" > "$LV/run/liveness.player"
lv_round wget-ok
sleep 1
expect "liveness: play senza PCM RUNNING oltre la soglia, squeezelite fermato" "no" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.dati")" in *"ERRORE|Player|bloccato: Lyrion dice play"*) ok "liveness: stato player bloccato nella pagina" ;; *) ko "liveness player" "bloccato" "$(cat "$LV/run/stato.dati")" ;; esac
case "$(cat "$LV/run/stato.json")" in *'"player":{"stato":"bloccato","riavvii":1}'*) ok "liveness: stato.json espone player bloccato" ;; *) ko "liveness json player" "bloccato" "$(cat "$LV/run/stato.json")" ;; esac
case "$(cat "$LV/log")" in *"liveness: player bloccato"*"riavvio squeezelite"*) ok "liveness: riavvio del player registrato nel log" ;; *) ko "liveness log player" "evento" "$(cat "$LV/log")" ;; esac
# Avvio lento (stream remoto): PCM non RUNNING da oltre la soglia ma il processo
# lavora (CPU che avanza): niente kill. Con la CPU ferma fra due campioni, kill.
sleep 7200 &
LV_SQ_PID=$!
echo "$LV_SQ_PID" > "$LV/run/squeezelite.pid"
mkdir -p "$LV/proc/$LV_SQ_PID"
lvcpu() { echo "$LV_SQ_PID (squeezelite) S 1 1 1 0 0 0 0 0 0 0 $1 0 0" > "$LV/proc/$LV_SQ_PID/stat"; }
echo play > "$LV/modo"
printf 'state: SETUP\n' > "$LV/proc/asound/card1/pcm0p/sub0/status"
lvcpu 100
echo "100000 0 0 0 100" > "$LV/run/liveness.player"
lvcpu 200
lv_round wget-ok
sleep 1
expect "liveness: avvio lento, PCM non RUNNING ma la CPU avanza, il player resta" "yes" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
lv_round wget-ok
sleep 1
expect "liveness: avvio lento, CPU ferma ma soglia ripartita, il player resta" "yes" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
echo "100000 0 0 0 200" > "$LV/run/liveness.player"
lv_round wget-ok
sleep 1
expect "liveness: PCM non RUNNING oltre la soglia e CPU ferma, squeezelite fermato" "no" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
# PCM RUNNING: tutto bene; "pause" o "stop": nessun intervento.
sleep 7200 &
LV_SQ_PID=$!
echo "$LV_SQ_PID" > "$LV/run/squeezelite.pid"
printf 'state: RUNNING\n' > "$LV/proc/asound/card1/pcm0p/sub0/status"
echo "100000 0 0 0" > "$LV/run/liveness.player"
lv_round wget-ok
expect "liveness: PCM RUNNING, nessun riavvio" "yes" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
printf 'state: SETUP\n' > "$LV/proc/asound/card1/pcm0p/sub0/status"
echo pause > "$LV/modo"
echo "100000 0 0 0" > "$LV/run/liveness.player"
lv_round wget-ok
expect "liveness: Lyrion in pausa e PCM fermo, nessun riavvio" "yes" "$(kill -0 $LV_SQ_PID 2>/dev/null && echo yes || echo no)"
kill $LV_SQ_PID 2>/dev/null
# Controlli funzionali: player connesso e tempo che avanza, zone, CamillaDSP,
# limite di riavvii per finestra e contatori per componente.
echo "Controlli funzionali (player, zone, CamillaDSP, limite di riavvii)"
FB=$LV/fbin
mkdir -p "$FB" "$LV/run/zone" "$LV/run/zone.mac"
rm -f "$LV/run"/liveness.* "$LV/run/correzione.attiva"
printf '#!/bin/sh\necho "{\\"result\\":{}}"\n' > "$FB/wget"
# jq finto: risponde secondo il campo chiesto (connected, mode, time).
printf '#!/bin/sh\nin=$(cat)\n[ -n "$in" ] || exit 1\ncase "$*" in *-e*) exit 0 ;; *_connected*) cat "%s/conn" ;; *_mode*) cat "%s/modo" ;; *_time*) cat "%s/tempo" ;; esac\n' "$LV" "$LV" "$LV" > "$FB/jq"
printf '#!/bin/sh\nif [ -s "%s/cam.pid" ]; then cat "%s/cam.pid"; else exit 1; fi\n' "$LV" "$LV" > "$FB/pidof"
printf '#!/bin/sh\n[ "$(cat "%s/cam.ok" 2>/dev/null)" = si ] && echo "{\\"GetState\\":{\\"result\\":\\"Ok\\",\\"value\\":\\"Running\\"}}" || exit 1\n' "$LV" > "$FB/sweetspot-camilla"
chmod +x "$FB"/*
printf 'LIVENESS_PLAYER_SECONDI=100000\nLIVENESS_FUNZ_FALLIMENTI=3\nLIVENESS_RIAVVII_MAX=2\nLIVENESS_RIAVVII_FINESTRA=1800\nLIVENESS_BACKOFF_MIN=3600\n' > "$LV/run/sweetspot.conf"
lv_fn() { # wget
	local w=${1:-$FB/wget}
	env SWEETSPOT_RUN=$LV/run SWEETSPOT_PROCFS=$LV/proc SWEETSPOT_LOG=$LV/log SWEETSPOT_WGET=$w SWEETSPOT_PIDOF=$FB/pidof \
		SWEETSPOT_PATH="$FB:$LV/bin:$SWEETSPOT_PATH" SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf PATH="$FB:$LV/bin:$PATH" \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-stato" funzionale
}
# PCM e processo finti: status ALSA con hw_ptr e /proc/<pid>/stat con i tick di CPU.
pcm() { printf 'state: %s\nowner_pid   : 1\n-----\nhw_ptr      : %s\nappl_ptr    : %s\n' "$1" "${2:-0}" "${2:-0}" > "$LV/proc/asound/card1/pcm0p/sub0/status"; }
cpu() { mkdir -p "$LV/proc/$1"; echo "$1 (squeezelite) S 1 1 1 0 0 0 0 0 0 0 $2 0 0" > "$LV/proc/$1/stat"; }
pcm RUNNING 1000
echo 02:53:57:45:45:54 > "$LV/run/player.mac"
rm -f "$LV/log"
# Player connesso, in pausa: nessun intervento.
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
echo 1 > "$LV/conn"; echo pause > "$LV/modo"; echo 10 > "$LV/tempo"
lv_fn; lv_fn; lv_fn; lv_fn
expect "funzionale: player connesso, nessun riavvio" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.json")" in *'"funzionali":[{"componente":"principale","stato":"ok","riavvii":0,"riavvii_finestra":0,"limite":false}]'*) ok "funzionale: stato.json espone il player ok con il contatore" ;; *) ko "funzionale json ok" "principale ok" "$(cat "$LV/run/stato.json")" ;; esac
# In play con il PCM fermo (XRUN) e il processo bloccato (tick di CPU invariati):
# primo campione, poi tre controlli falliti e riavvio. Il "time ?" di Lyrion
# continua ad avanzare (lo estrapola): non deve nascondere il blocco.
echo play > "$LV/modo"
pcm XRUN 1000; cpu "$LF_SQ" 500
for t in 11 12 13; do echo "$t" > "$LV/tempo"; lv_fn; done   # campione, fermo (1), fermo (2)
expect "funzionale: PCM fermo e processo bloccato sotto soglia, il player resta" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
echo 14 > "$LV/tempo"; lv_fn          # fermo (3)
sleep 1
expect "funzionale: PCM fermo e processo bloccato oltre soglia, squeezelite fermato anche se time ? avanza" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/log")" in *"liveness: Player principale bloccato (in play ma PCM XRUN e processo player fermo"*"riavvio 1)"*) ok "funzionale: riavvio per PCM fermo nel log" ;; *) ko "funzionale log pcm" "riavvio" "$(cat "$LV/log")" ;; esac
case "$(cat "$LV/run/stato.json")" in *'"componente":"principale","stato":"riavviato","riavvii":1,'*) ok "funzionale: contatore dei riavvii nel json" ;; *) ko "funzionale json riavvio" "riavvii 1" "$(cat "$LV/run/stato.json")" ;; esac
case "$(cat "$LV/run/stato.dati")" in *"ERRORE|Player principale risponde|"*) ok "funzionale: la pagina Stato mostra l'errore" ;; *) ko "funzionale stato.dati" "ERRORE" "$(cat "$LV/run/stato.dati")" ;; esac
# PCM RUNNING con hw_ptr che avanza: sano.
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
rm -f "$LV"/run/liveness.c.* "$LV"/run/liveness.t.*
for t in 1 2 3 4 5; do pcm RUNNING "$((t * 1000))"; lv_fn; done
expect "funzionale: PCM che avanza, nessun riavvio" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
# PCM RUNNING ma hw_ptr fermo: il DAC non consuma, riavvio al terzo controllo fermo.
rm -f "$LV"/run/liveness.c.* "$LV"/run/liveness.t.*
pcm RUNNING 9000
lv_fn; lv_fn; lv_fn
expect "funzionale: hw_ptr fermo sotto soglia, il player resta" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
lv_fn
sleep 1
expect "funzionale: hw_ptr fermo oltre soglia, squeezelite fermato" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
# Ribuffering (rete lenta): Lyrion in play, PCM non RUNNING ma il processo lavora
# (tick di CPU che crescono): stato "attesa", nessun riavvio ne' fallimento.
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
rm -f "$LV"/run/liveness.c.* "$LV"/run/liveness.t.*
pcm PREPARED 0
for t in 1 2 3 4; do cpu "$LF_SQ" "$((600 + t * 7))"; lv_fn; done
sleep 1
expect "funzionale: ribuffering, il player non viene riavviato" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.json")" in *'"componente":"principale","stato":"attesa","riavvii":0,'*'"limite":false'*) ok "funzionale: stato attesa nel json, senza riavvii" ;; *) ko "funzionale json attesa" "attesa" "$(cat "$LV/run/stato.json")" ;; esac
case "$(cat "$LV/run/stato.dati")" in *"INFO|Player principale risponde|in attesa di dati"*) ok "funzionale: la pagina Stato mostra l'attesa di dati" ;; *) ko "funzionale stato.dati attesa" "INFO in attesa" "$(cat "$LV/run/stato.dati")" ;; esac
# Il buffer si riempie: il PCM riparte e l'attesa e' finita.
pcm RUNNING 100; cpu "$LF_SQ" 700; lv_fn
pcm RUNNING 5100; cpu "$LF_SQ" 710; lv_fn
case "$(cat "$LV/run/stato.json")" in *'"componente":"principale","stato":"ok",'*) ok "funzionale: dopo il ribuffering torna ok" ;; *) ko "funzionale json ripresa" "ok" "$(cat "$LV/run/stato.json")" ;; esac
# L'attesa non e' infinita: oltre LIVENESS_FUNZ_ATTESA controlli conta come fallimento.
rm -f "$LV"/run/liveness.c.* "$LV"/run/liveness.t.*
pcm PREPARED 0
for t in 1 2 3 4 5 6 7 8 9 10; do cpu "$LF_SQ" "$((800 + t))"; lv_fn; done
sleep 1
expect "funzionale: attesa oltre il limite di controlli, squeezelite fermato" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
rm -f "$LV"/run/liveness.c.* "$LV"/run/liveness.t.*
pcm RUNNING 1
for t in 1 2 3 4 5; do pcm RUNNING "$((t * 100))"; lv_fn; done
# Player non connesso a Lyrion: 3 controlli, poi riavvio; Lyrion muto: nessun giudizio.
echo 0 > "$LV/conn"
lv_fn "$LV/bin/wget-muto"; lv_fn "$LV/bin/wget-muto"; lv_fn "$LV/bin/wget-muto"; lv_fn "$LV/bin/wget-muto"
expect "funzionale: con Lyrion muto il player non viene giudicato" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
lv_fn; lv_fn
expect "funzionale: player non connesso sotto soglia, resta" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
lv_fn
sleep 1
expect "funzionale: player non connesso oltre soglia, fermato" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
# Limite: ormai 2 riavvii nella finestra (MAX=2) con il secondo qui sopra e il
# primo di prima azzerato dal rm: ne servono 2 per arrivare al limite.
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
lv_fn; lv_fn; lv_fn
sleep 1
expect "funzionale: secondo riavvio consentito (MAX=2)" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
sleep 7200 &
LF_SQ=$!
echo "$LF_SQ" > "$LV/run/squeezelite.pid"
lv_fn; lv_fn; lv_fn
expect "funzionale: limite di riavvii raggiunto, il player non viene piu' fermato" "yes" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.json")" in *'"componente":"principale","stato":"limite","riavvii":2,'*'"limite":true'*) ok "funzionale: stato limite e contatore 2 nel json" ;; *) ko "funzionale json limite" "limite 2" "$(cat "$LV/run/stato.json")" ;; esac
case "$(cat "$LV/log")" in *"non riavvio (limite)"*) ok "funzionale: il limite e' nel log" ;; *) ko "funzionale log limite" "limite" "$(cat "$LV/log")" ;; esac
# Finestra scaduta: i vecchi riavvii non contano piu'.
echo "3 2 1 2" > "$LV/run/liveness.c.principale"
lv_fn
sleep 1
expect "funzionale: fuori finestra il riavvio e' di nuovo consentito" "no" "$(kill -0 $LF_SQ 2>/dev/null && echo yes || echo no)"
# Zona: connessa a Lyrion tramite il suo MAC.
sleep 7200 &
LF_Z=$!
echo "$LF_Z DACZ" > "$LV/run/zone/2"
echo 02:aa:bb:cc:dd:ee > "$LV/run/zone.mac/2"
rm -f "$LV/run/squeezelite.pid" "$LV"/run/liveness.c.*
lv_fn; lv_fn
expect "funzionale: zona non connessa sotto soglia, resta" "yes" "$(kill -0 $LF_Z 2>/dev/null && echo yes || echo no)"
lv_fn
sleep 1
expect "funzionale: zona non connessa oltre soglia, fermata" "no" "$(kill -0 $LF_Z 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/liveness.c.zona-DACZ")" in "0 1 "*) ok "funzionale: contatore della zona" ;; *) ko "funzionale contatore zona" "0 1 ..." "$(cat "$LV/run/liveness.c.zona-DACZ" 2>&1)" ;; esac
rm -rf "$LV/run/zone" "$LV/run/zone.mac"
# CamillaDSP: websocket che non risponde.
sleep 7200 &
LF_C=$!
echo "$LF_C" > "$LV/cam.pid"
touch "$LV/run/correzione.attiva"
echo si > "$LV/cam.ok"
lv_fn; lv_fn; lv_fn
expect "funzionale: CamillaDSP che risponde, nessun riavvio" "yes" "$(kill -0 $LF_C 2>/dev/null && echo yes || echo no)"
echo no > "$LV/cam.ok"
lv_fn; lv_fn
expect "funzionale: websocket muto sotto soglia, CamillaDSP resta" "yes" "$(kill -0 $LF_C 2>/dev/null && echo yes || echo no)"
lv_fn
sleep 1
expect "funzionale: websocket muto oltre soglia, CamillaDSP fermato" "no" "$(kill -0 $LF_C 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.json")" in *'"componente":"camilladsp","stato":"riavviato","riavvii":1,'*) ok "funzionale: contatore di CamillaDSP nel json" ;; *) ko "funzionale json camilla" "camilladsp riavviato" "$(cat "$LV/run/stato.json")" ;; esac
rm -f "$LV/cam.pid" "$LV/run/correzione.attiva" "$LV/run/squeezelite.pid"
# Lyrion: lo stesso limite vale anche per il suo riavvio.
printf 'LIVENESS_LYRION_FALLIMENTI=3\nLIVENESS_BACKOFF_MIN=3600\nLIVENESS_LYRION_AVVIO=180\nLIVENESS_RIAVVII_MAX=1\nLIVENESS_RIAVVII_FINESTRA=1800\n' > "$LV/run/sweetspot.conf"
sleep 7200 &
LF_L=$!
echo "$LF_L" > "$LV/run/lms.pid"
touch -d '2000-01-01' "$LV/run/lms.pid"
rm -f "$LV/run/liveness.lyrion" "$LV/run/liveness.funz"
echo "2 0 0 0 0" > "$LV/run/liveness.lyrion"
echo "0 1 $(date +%s)" > "$LV/run/liveness.c.lyrion"
lv_round wget-muto
sleep 1
expect "limite: Lyrion in stallo ma gia' un riavvio nella finestra, non riavviato" "yes" "$(kill -0 $LF_L 2>/dev/null && echo yes || echo no)"
case "$(cat "$LV/run/stato.json")" in *'"lyrion":{"stato":"limite"'*) ok "limite: stato.json espone Lyrion in limite" ;; *) ko "limite json lyrion" "limite" "$(cat "$LV/run/stato.json")" ;; esac
kill $LF_L 2>/dev/null
rm -f "$LV/run/lms.pid" "$LV/run/liveness.lyrion" "$LV"/run/liveness.c.* "$LV"/run/liveness.t.* "$LV/run/liveness.funz"
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nsubformat: STD\nchannels: 2\nrate: 192000 (192000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
case "$(page audio)" in *"Non bit-perfect"*"96000 Hz"*) ok "audio: frequenza cambiata segnalata" ;; *) ko "audio ricampionato" "Non bit-perfect" "-" ;; esac
printf 'access: MMAP_INTERLEAVED\nformat: S32_LE\nchannels: 2\nrate: 96000 (96000/1)\n' > "$WEB/proc/asound/card1/pcm0p/sub0/hw_params"
out=$(page audio 'VOLUME=software')
case "$out" in *"Non bit-perfect"*"abbassato dal software e non è bit-perfect (arrotonda con dither TPDF)"*) ok "audio: volume software segnalato" ;; *) ko "audio volume software" "Non bit-perfect, dither TPDF" "-" ;; esac
case "$out" in *'<option value="software" selected'*'Volume software: Squeezelite abbassa i campioni e li arrotonda con dither TPDF'*) ok "audio: volume software spiegato sotto la scelta" ;; *) ko "audio nota volume software" "nota con dither TPDF" "-" ;; esac
case "$(page audio 'VOLUME=fisso')" in *'Volume software: Squeezelite'*) ko "audio: nessuna nota con il volume fisso" "nessuna nota" "nota presente" ;; *) ok "audio: nessuna nota con il volume fisso" ;; esac
# Catena del segnale: verdetto puro e pagina
expect "catena: tutti invariati = bit-perfect" "bit-perfect" "$($TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; chain_verdict inv inv inv")"
expect "catena: uno che modifica = modificato" "modificato" "$($TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; chain_verdict inv mod nv inv")"
expect "catena: uno non verificabile = non-verificabile" "non-verificabile" "$($TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; chain_verdict inv nv inv")"
expect "catena: nessuno stadio = non-verificabile" "non-verificabile" "$($TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; chain_verdict")"
rm -f "$WEB/run/frequenza.max"
case "$(page audio)" in *"2. Lyrion - non verificabile"*"Verdetto: non verificabile"*) ok "catena: senza frequenza massima non c'è verdetto bit-perfect" ;; *) ko "catena senza frequenza.max" "Verdetto: non verificabile" "-" ;; esac
echo 192000 > "$WEB/run/frequenza.max"
out=$(page audio)
case "$out" in *"6. DAC - invariato"*"Verdetto: bit-perfect"*) ok "catena: tutti gli stadi invariati, verdetto bit-perfect" ;; *) ko "catena bit-perfect" "Verdetto: bit-perfect" "$out" ;; esac
case "$out" in *"Alta precisione, non bit-perfect"*) ko "catena: nessuna nota alta precisione se bit-perfect" "assente" "presente" ;; *) ok "catena: nessuna nota alta precisione se bit-perfect" ;; esac
out=$(page audio 'VOLUME=software')
case "$out" in *"4. Guadagno - modifica i campioni"*"Verdetto: non bit-perfect"*"Alta precisione, non bit-perfect"*"float64, headroom, dither"*) ok "catena: volume digitale modifica i campioni, alta precisione distinta dal bit-perfect" ;; *) ko "catena volume software" "Guadagno modifica + nota alta precisione" "$out" ;; esac
echo 48000 > "$WEB/run/frequenza.max"
case "$(page audio)" in *"2. Lyrion - modifica i campioni"*"sox"*"Verdetto: non bit-perfect"*) ok "catena: sox lato Lyrion segnalato" ;; *) ko "catena sox" "Lyrion modifica" "-" ;; esac
rm -f "$WEB/run/frequenza.max"
volcheck() { # impostazioni
	printf '%s\n' "$1" > "$WEB/s.txt"
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" 2>/dev/null | grep '^[A-Z]*|Volume|'
}
expect "stato: volume software e' un avviso" \
	"ATTENZIONE|Volume|dal software: sotto il 100% non e' bit-perfect; Squeezelite arrotonda con dither TPDF a 16 e 24 bit senza troncare, ma il volume fisso o del DAC resta preferibile" \
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
printf '%s\n' "$*" >> "$SWEETSPOT_RUN/config.log"
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
printf '#!/bin/sh
printf "%%s\n" "$*" >> "$SWEETSPOT_RUN/mediaserver.call"
' > "$WEB/actionbin/sweetspot-mediaserver"
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

# Renderer UPnP/DLNA in entrata: spento di serie, acceso dal pannello.
upnp_action() { # valore-del-campo [impostazione-precedente]
	local body
	printf '%s\n' "${2:-}" > "$WEB/run/sweetspot.conf"
	body="t=$(cat "$WEB/run/web.token")&a=sistema&nome=Sweetspot&modalita=completa&profilo=bilanciato&ascolto=si&ssh=no&ottimizzazioni=si${1:+&renderer_upnp=$1}"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run \
		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione" > /dev/null
	grep -o 'RENDERER_UPNP [a-z]*' "$WEB/run/config.call"
	rm -f "$WEB/run/sweetspot.conf"
}
expect "renderer UPnP: acceso dal pannello" "RENDERER_UPNP si" "$(upnp_action si)"
expect "renderer UPnP: spento dal pannello" "RENDERER_UPNP no" "$(upnp_action no RENDERER_UPNP=si)"
expect "renderer UPnP: valore sconosciuto = resta com'e'" "RENDERER_UPNP si" "$(upnp_action xyz RENDERER_UPNP=si)"
expect "renderer UPnP: campo assente = resta com'e'" "RENDERER_UPNP si" "$(upnp_action '' RENDERER_UPNP=si)"
expect "renderer UPnP: di serie spento" "no" "$(grep '^RENDERER_UPNP=' "$OVERLAY/etc/sweetspot/defaults.conf" | cut -d= -f2)"
expect "renderer UPnP: spento anche nel modello di sweetspot.txt" "RENDERER_UPNP=no" "$(grep '^RENDERER_UPNP=' "$ROOT/board/sweetspot/stick/sweetspot.txt")"
expect "renderer UPnP: chiave ammessa all'helper privilegiato" "1" "$(grep -c '"RENDERER_UPNP"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
case "$(page sistema)" in *'name="renderer_upnp"'*'<option value="no" selected'*) ok "sistema: renderer UPnP spento di serie" ;; *) ko "sistema renderer" "no selezionato" "-" ;; esac
# La pagina Sistema (con il selettore del renderer) esce con le intestazioni di sicurezza di web.sh.
sistema_out=$(page sistema)
expect "sistema: intestazioni di sicurezza anche con il selettore del renderer" "DENY|nosniff" \
	"$(printf '%s' "$sistema_out" | sed -n 's/^X-Frame-Options: *//p' | tr -d '\r')|$(printf '%s' "$sistema_out" | sed -n 's/^X-Content-Type-Options: *//p' | tr -d '\r')"
case "$(page sistema RENDERER_UPNP=si)" in *'name="renderer_upnp"'*'<option value="si" selected'*) ok "sistema: renderer UPnP acceso" ;; *) ko "sistema renderer acceso" "si selezionato" "-" ;; esac

# Media server UPnP/DLNA: spento di serie, acceso dal pannello, riavviato solo se cambia.
dlna_action() { # valore-del-campo [impostazione-precedente] [nome]
	local body
	printf '%s
' "${2:-}" > "$WEB/run/sweetspot.conf"
	rm -f "$WEB/run/mediaserver.call"
	body="t=$(cat "$WEB/run/web.token")&a=sistema&nome=${3:-Sweetspot}&modalita=completa&profilo=bilanciato&ascolto=si&ssh=no&ottimizzazioni=si${1:+&server_upnp=$1}"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run 		SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf 		SWEETSPOT_PATH="$WEB/actionbin:$SWEETSPOT_PATH" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} 		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione" > /dev/null
	printf '%s|%s' "$(grep -o 'SERVER_UPNP [a-z]*' "$WEB/run/config.call")" "$(cat "$WEB/run/mediaserver.call" 2>/dev/null)"
	rm -f "$WEB/run/sweetspot.conf" "$WEB/run/mediaserver.call"
}
expect "media server: acceso dal pannello, riavviato" "SERVER_UPNP si|riavvia" "$(dlna_action si)"
expect "media server: spento dal pannello, riavviato" "SERVER_UPNP no|riavvia" "$(dlna_action no SERVER_UPNP=si)"
expect "media server: valore sconosciuto = resta com'e', niente riavvio" "SERVER_UPNP si|" "$(dlna_action xyz SERVER_UPNP=si)"
expect "media server: campo assente = resta com'e'" "SERVER_UPNP no|" "$(dlna_action '')"
expect "media server: nome nuovo con il server acceso, riavviato" "SERVER_UPNP si|riavvia" "$(dlna_action si SERVER_UPNP=si Salotto)"
expect "media server: nome nuovo con il server spento, niente riavvio" "SERVER_UPNP no|" "$(dlna_action no '' Salotto)"
expect "media server: di serie spento" "no" "$(grep '^SERVER_UPNP=' "$OVERLAY/etc/sweetspot/defaults.conf" | cut -d= -f2)"
expect "media server: spento anche nel modello di sweetspot.txt" "SERVER_UPNP=no" "$(grep '^SERVER_UPNP=' "$ROOT/board/sweetspot/stick/sweetspot.txt")"
expect "media server: chiave e comando ammessi all'helper privilegiato" "1|1" 	"$(grep -c '"SERVER_UPNP"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")|$(grep -c '"sweetspot-mediaserver", "riavvia"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
case "$(page sistema)" in *'name="server_upnp"'*'<option value="no" selected'*) ok "sistema: media server spento di serie" ;; *) ko "sistema media server" "no selezionato" "-" ;; esac
case "$(page sistema SERVER_UPNP=si)" in *'name="server_upnp"'*'<option value="si" selected'*) ok "sistema: media server acceso" ;; *) ko "sistema media server acceso" "si selezionato" "-" ;; esac


echo "Password delle pagine e impostazioni iniziali"
acc() { # impostazioni
	printf '%s\n' "$1" > "$WEB/s.txt"
	SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c "killall() { :; }; . $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; set -- applica; . $OVERLAY/usr/bin/sweetspot-accesso"
	cat "$WEB/run/httpd.conf"
}
expect "pagine aperte senza password" "" "$(acc '')"
# Con la password l'httpd non fa piu' autenticazione Basic: restano la regola
# di vivo e l'accesso con sessione (tests/accesso.sh).
expect "con la password nessuna regola Basic generale e nessuna impronta nel file" "0" "$(acc 'PASSWORD_WEB=$1$abcd$efgh' | grep -c '^/:\|abcd')"
expect "file dell'accesso leggibile solo da root" "600" "$(stat -c %a "$WEB/run/httpd.conf")"
# La pagina vivo resta raggiungibile dall'aggiornamento: utente sweetspot
# con la chiave casuale dell'avvio, regola prima di quella generale.
vivo_key=$(cat "$WEB/run/vivo.chiave")
expect "chiave della pagina vivo: 32 cifre esadecimali, solo root" "32|600" "${#vivo_key}|$(stat -c %a "$WEB/run/vivo.chiave")"
case "$vivo_key" in *[!0-9a-f]*) ko "chiave della pagina vivo" "esadecimale" "$vivo_key" ;; *) ok "chiave della pagina vivo esadecimale" ;; esac
expect "regola della pagina vivo con la chiave, prima di quella generale" "/cgi-bin/vivo:sweetspot:$vivo_key" "$(head -n 1 "$WEB/run/httpd.conf")"
expect "httpd.conf con la sola regola di vivo" "1" "$(grep -c . "$WEB/run/httpd.conf")"
expect "a ogni applicazione una chiave nuova" "diversa" "$(acc 'PASSWORD_WEB=segreta' > /dev/null; [ "$(cat "$WEB/run/vivo.chiave")" != "$vivo_key" ] && echo diversa)"
acc '' > /dev/null
expect "senza password niente chiave della pagina vivo" "no" "$([ -f "$WEB/run/vivo.chiave" ] && echo si || echo no)"

echo "Controllo dell'header Host (DNS rebinding)"
# Come una richiesta web (GATEWAY_INTERFACE impostata): la pagina vivo e'
# la CGI piu' semplice. $2 = Host ("-" = assente), $3 = indirizzo del client.
mkdir -p "$WEB/hbin"
printf '#!/bin/sh\nprintf "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0\\n2: eth0    inet6 fe80::1234:abcd/64 scope link\\n"\n' > "$WEB/hbin/ip"
chmod +x "$WEB/hbin/ip"
hostcall() { # impostazioni host client
	printf '%s\n' "$1" > "$WEB/s.txt"
	if [ "$2" = "-" ]; then unset HTTP_HOST; else export HTTP_HOST=$2; fi
	# La configurazione si costruisce prima: il controllo scatta quando la
	# richiesta (GATEWAY_INTERFACE) arriva, a configurazione gia' pronta.
	REMOTE_ADDR=${3:-192.168.1.9} \
		SWEETSPOT_RUN=$WEB/run SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$WEB/hbin:$SWEETSPOT_PATH" SWEETSPOT_IP="$WEB/hbin/ip" \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; GATEWAY_INTERFACE=CGI/1.1; export GATEWAY_INTERFACE; . $OVERLAY/usr/share/sweetspot/www/cgi-bin/vivo" 2>&1
	unset HTTP_HOST
}
hostcode() { case "$(hostcall "$@")" in *"403 Forbidden"*) echo 403 ;; *"ok "*) echo ok ;; *) echo altro ;; esac; }
for h in sweetspot.local sweetspot.local:80 SweetSpot.LOCAL localhost 127.0.0.1:80 192.168.1.50 192.168.1.50:80 '[fe80::1234:abcd]:80' '[fe80::1234:abcd]'; do
	expect "Host $h accettato" ok "$(hostcode '' "$h")"
done
for h in evil.example.com evil.example.com:80 192.168.1.51 sweetspot.local.evil.com 10.0.0.1; do
	expect "Host $h rifiutato con 403" 403 "$(hostcode '' "$h")"
done
expect "NOME_RETE personalizzato: salotto.local accettato" ok "$(hostcode 'NOME_RETE=salotto' salotto.local)"
expect "NOME_RETE personalizzato: nome breve accettato" ok "$(hostcode 'NOME_RETE=salotto' salotto:80)"
expect "NOME_RETE personalizzato: un altro nome non vale" 403 "$(hostcode 'NOME_RETE=salotto' cucina.local)"
expect "Host assente dal computer stesso accettato" ok "$(hostcode '' - 127.0.0.1)"
expect "Host assente dalla rete rifiutato" 403 "$(hostcode '' - 192.168.1.9)"
out=$(hostcall '' evil.example.com)
case "$out" in *"Status: 403"*"Content-Type: text/plain"*) ok "403 prima di qualunque altro output" ;; *) ko "403 senza altro output" "solo la risposta 403" "$out" ;; esac
expect "fuori da una richiesta web nessun controllo" "ok" "$(HTTP_HOST=evil SWEETSPOT_RUN=$WEB/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; echo ok")"

echo "Protezione CSRF di Lyrion"
lmsprefs() { # contenuto iniziale di server.prefs ("-" = file assente)
	rm -rf "$WEB/lmsdata"; mkdir -p "$WEB/lmsdata/prefs"
	[ "$1" = "-" ] || printf '%s\n' "$1" > "$WEB/lmsdata/prefs/server.prefs"
	SWEETSPOT_TEST=1 SWEETSPOT_LMS_DATA=$WEB/lmsdata SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-lms; [ -s \$PREFS/server.prefs ] || first_prefs > \$PREFS/server.prefs; ensure_csrf" > /dev/null 2>&1
	grep '^csrfProtectionLevel' "$WEB/lmsdata/prefs/server.prefs" | tr '\n' '|'
}
expect "CSRF Lyrion: primo avvio a livello 1" "csrfProtectionLevel: 1|" "$(lmsprefs -)"
expect "CSRF Lyrion: assente nelle preferenze esistenti -> 1" "csrfProtectionLevel: 1|" "$(lmsprefs 'language: IT')"
expect "CSRF Lyrion: livello 0 riportato a 1" "csrfProtectionLevel: 1|" "$(lmsprefs 'csrfProtectionLevel: 0')"
expect "CSRF Lyrion: livello 2 scelto dall'utente resta" "csrfProtectionLevel: 2|" "$(lmsprefs 'csrfProtectionLevel: 2')"
printf '#!/bin/sh\n[ "$1" = hash ] && echo "\\$1\\$prova\\$impronta"\n[ "$1" = verifica ] && { read -r pw; [ "$pw" = vecchia-password ] || exit 1; }\nexit 0\n' > "$WEB/actionbin/sweetspot-accesso"
chmod +x "$WEB/actionbin/sweetspot-accesso"
web_action() { # corpo senza gettone
	local body tk
	# Il gettone come lo calcola la pagina: con PASSWORD_WEB dipende dalla sessione.
	tk=$(SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c '. "$SWEETSPOT_LIB/web.sh"; token')
	body="t=$tk&$1"
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
# Margine DSD -> PCM: salvato (anche con la virgola), mancante = quello in uso, non valido rifiutato.
AUDIO_BASE="a=audio&volume=fisso&dsd=auto&altri_dac=no&dac=auto&ricampionamento=no&filtro=lineare&frequenza_max=0&buffer=400&periodi=4&pausa_frequenza=0&pausa_dsd=500"
rm -f "$WEB/run/config.call"
web_action "$AUDIO_BASE&dsd_margine=-1,5" > /dev/null
case "$(cat "$WEB/run/config.call")" in *"DSD_PCM_MARGINE_DB -1.5 "*) ok "audio: margine DSD salvato (virgola accettata)" ;; *) ko "audio margine DSD salvato" "DSD_PCM_MARGINE_DB -1.5" "$(cat "$WEB/run/config.call")" ;; esac
rm -f "$WEB/run/config.call"
web_action "$AUDIO_BASE" > /dev/null
case "$(cat "$WEB/run/config.call")" in *"DSD_PCM_MARGINE_DB -3 "*) ok "audio: margine DSD mancante, resta quello in uso" ;; *) ko "audio margine DSD mancante" "DSD_PCM_MARGINE_DB -3" "$(cat "$WEB/run/config.call")" ;; esac
for v in 2 1 -25 -3.55 abc; do
	rm -f "$WEB/run/config.call"
	out=$(web_action "$AUDIO_BASE&dsd_margine=$v")
	case "$out" in *"Location: /cgi-bin/audio?msg="*) ;; *) ko "audio margine DSD $v" "torna a audio" "$out" ;; esac
	expect "audio: margine DSD $v rifiutato, niente salvato" "no" "$([ -f "$WEB/run/config.call" ] && echo si || echo no)"
done
rm -f "$WEB/run/config.call"
rm -f "$WEB/run/config.call"
# La password delle pagine si cambia solo con quella attuale: una sessione
# rubata non basta a prendere il pannello per sempre.
cp "$WEB/run/sweetspot.conf" "$WORK/sweetspot.conf.prima" 2> /dev/null || : > "$WORK/sweetspot.conf.prima"
printf 'PASSWORD_WEB=$1$vecchia$impronta\n' >> "$WEB/run/sweetspot.conf"
SISTEMA_WEB="a=sistema&nome=Sweetspot&modalita=completa&profilo=bilanciato&ascolto=si&ssh=no&ottimizzazioni=si&web_password=segreta-lunga-1"
rm -f "$WEB/run/config.log"
out=$(web_action "$SISTEMA_WEB")
expect "sistema: senza la vecchia password non si cambia" '0' "$(cat "$WEB/run/config.log" 2> /dev/null | grep -c PASSWORD_WEB)"
case "$out" in *"Location: /cgi-bin/sistema?msg="*) ok "sistema: senza la vecchia password torna alla pagina" ;; *) ko "sistema senza vecchia password" "torna a sistema" "$out" ;; esac
rm -f "$WEB/run/config.log"
web_action "$SISTEMA_WEB&ct=prova&conferma_password=sbagliata" > /dev/null
expect "sistema: con la vecchia password sbagliata non si cambia" '0' "$(cat "$WEB/run/config.log" 2> /dev/null | grep -c PASSWORD_WEB)"
rm -f "$WEB/run/config.log"
web_action "$SISTEMA_WEB&ct=prova&conferma_password=vecchia-password" > /dev/null
expect "sistema: si salva l'impronta, non la password" '1|0' \
	"$(grep -c 'PASSWORD_WEB $1$prova$impronta' "$WEB/run/config.log")|$(grep -c segreta-lunga "$WEB/run/config.log")"
cp "$WORK/sweetspot.conf.prima" "$WEB/run/sweetspot.conf"
rm -f "$WEB/run/config.log"
out=$(web_action "a=ripristina")
case "$out" in *"Location: /cgi-bin/sistema"*) ok "ripristino: senza conferma non parte" ;; *) ko "ripristino senza conferma" "torna a sistema" "$out" ;; esac
expect "ripristino: nessuna modifica senza conferma" "0" "$(grep -c ripristina "$WEB/run/config.call")"
printf 'PASSWORD_WEB=$1$vecchia$impronta\n' >> "$WEB/run/sweetspot.conf"
web_action "a=ripristina&conferma=si" > /dev/null
expect "ripristino: senza password nessuna modifica" "0" "$(grep -c ripristina "$WEB/run/config.call")"
web_action "a=ripristina&conferma=si&ct=prova&conferma_password=sbagliata" > /dev/null
expect "ripristino: con la password sbagliata nessuna modifica" "0" "$(grep -c ripristina "$WEB/run/config.call")"
web_action "a=ripristina&conferma=si&ct=prova&conferma_password=vecchia-password" > /dev/null
expect "ripristino confermato" "ripristina" "$(tail -n 1 "$WEB/run/config.call")"
cp "$WORK/sweetspot.conf.prima" "$WEB/run/sweetspot.conf"
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
case "$out" in *"Automatico: il DAC non dichiara il DSD nativo, quindi Squeezelite converte i file DSD in PCM alla frequenza più alta che il DAC accetta, senza provare il DoP"*) ok "audio: DSD automatico senza nativo spiegato" ;; *) ko "audio DSD automatico" "conversione di Squeezelite, senza DoP" "-" ;; esac
case "$out" in *"<h2>Prova DoP</h2>"*"Avvia la prova (6 secondi)"*) ok "audio: prova DoP proposta" ;; *) ko "audio prova DoP" "pulsante della prova" "-" ;; esac
case "$out" in *"Com&#39;è andata?"*) ko "audio: esito chiesto solo dopo la prova" "nessun esito" "esito presente" ;; *) ok "audio: esito chiesto solo dopo la prova" ;; esac
case "$(page audio 'VOLUME=software')" in *"Prova non disponibile"*"il volume software altera i campioni"*) ok "audio: prova DoP bloccata dal volume software" ;; *) ko "audio prova DoP volume" "prova non disponibile" "-" ;; esac
case "$(page audio 'DSD=dop')" in *"Tramite DoP, come scelto"*) ok "audio: DoP scelto segnalato" ;; *) ko "audio DoP scelto" "Tramite DoP" "-" ;; esac
# Margine del DSD convertito in PCM (DSD_PCM_MARGINE_DB): -3 di serie, da -24 a 0.
case "$out" in *"-3 dB nella conversione del DSD in PCM"*'name="dsd_margine"'*'value="-3"'*) ok "audio: margine DSD -3 dB di serie, in campo e in riga" ;; *) ko "audio margine DSD" "-3 dB di serie" "-" ;; esac
case "$(page audio 'DSD_PCM_MARGINE_DB=-6')" in *"-6 dB nella conversione del DSD in PCM"*'name="dsd_margine"'*'value="-6"'*) ok "audio: margine DSD scelto mostrato" ;; *) ko "audio margine DSD scelto" "-6 dB" "-" ;; esac
case "$(page audio 'DSD_PCM_MARGINE_DB=5')" in *"-3 dB nella conversione del DSD in PCM"*'value="-3"'*) ok "audio: margine DSD positivo ignorato" ;; *) ko "audio margine DSD positivo" "-3 dB" "-" ;; esac
for v in 0 0.0 -0.5 -3 -12 -23.9 -24; do
	printf 'DSD_PCM_MARGINE_DB=%s\n' "$v" > "$WEB/s.txt"
	expect "margine DSD $v valido" "$v" "$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; dsd_margine_db")"
done
for v in 1 3 -24.1 -25 -3.55 abc -3x -; do
	printf 'DSD_PCM_MARGINE_DB=%s\n' "$v" > "$WEB/s.txt"
	expect "margine DSD $v non valido: predefinito" "-3" "$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WEB/s.txt; dsd_margine_db")"
done
printf '' > "$WEB/s.txt"
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
expect "prova DoP: esito atteso dopo l'avvio" "si" "$([ -f "$WEB/run/web/prova-dop.avviata" ] && echo si || echo no)"
expect "prova DoP: la coda di ascolto e' messa da parte (preview), non cancellata" "1|0" \
	"$(grep -c "\"playlist\",\"preview\",\"url:file://$WEB/prova-dop/prova-dop.wav\",\"title:Prova DoP\"" "$WEB/run/wget.post")|$(grep -c '"playlist","play"' "$WEB/run/wget.post")"
case "$out" in *"%50%72%6f%76%61%20%44%6f%50%20%61%76%76%69%61%74%61"*) ok "prova DoP: pagina con le istruzioni" ;; *) ko "prova DoP messaggio" "Prova DoP avviata" "$(printf '%s' "$out" | head -c 200)" ;; esac
case "$(page audio)" in *"usa DoP"*"lascia la conversione"*) ok "audio: dopo la prova si sceglie l'esito" ;; *) ko "audio esito prova DoP" "due pulsanti" "-" ;; esac
rm -f "$WEB/run/config.call" "$WEB/run/wget.post"
dop_action prova_dop_esito no > /dev/null
expect "esito negativo: nessuna impostazione cambiata" "no|no" \
	"$([ -e "$WEB/run/config.call" ] && echo si || echo no)|$([ -f "$WEB/run/web/prova-dop.avviata" ] && echo si || echo no)"
expect "esito: la coda di ascolto torna com'era" "1" "$(grep -c '"playlist","preview","cmd:stop"' "$WEB/run/wget.post")"
touch "$WEB/run/web/prova-dop.avviata"
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
rm -f "$WEB/s.txt" "$WEB/run/config.call" "$WEB/run/web/prova-dop.avviata" "$WEB/run/prova-dop.call"
rm -rf "$WEB/prova-dop"

echo "Diagnostica del percorso"
printf 'buffering\n' > "$WEB/squeezelite.log"
: > "$WEB/proc/mounts"
diag=$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati)
case "$diag" in *"XRUN ALSA registrati|0"*) ok "diagnostica: conta gli XRUN senza certificare la continuita'" ;; *) ko "diagnostica XRUN" "XRUN ALSA registrati|0" "-" ;; esac
case "$diag" in *"nessuna dall'accensione"*) ko "diagnostica: nessuna continuita' inventata" "nessuna certificazione" "certificazione presente" ;; *) ok "diagnostica: nessuna continuita' inventata" ;; esac

# Stallo da frequenza (-H) e ricampionamento "solo se serve" (flag E).
diag_freq() { SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log $TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati; }
grep -q "printf '%s\\\\n' -R vLE" "$OVERLAY/usr/bin/sweetspot-player" && ok "player: ricampiona solo se il DAC non supporta la frequenza (-R vLE)" || ko "player: -R vLE" "presente" "assente"
grep -q '^FREQUENZA_NON_SUPPORTATA=ricampiona' "$OVERLAY/etc/sweetspot/defaults.conf" && ok "default: FREQUENZA_NON_SUPPORTATA=ricampiona" || ko "default FREQUENZA_NON_SUPPORTATA" "ricampiona" "assente"
printf '[12:00:00] output:1 device hw:X refuses 88200 Hz and strict hw mode (-H) forbids the plughw: fallback: not resampling, output stopped: Invalid argument\n[12:00:05] output:1 device hw:X refuses 88200 Hz and strict hw mode (-H) forbids the plughw: fallback: not resampling, output stopped: Invalid argument\n' > "$WEB/squeezelite.log"
diag=$(diag_freq)
case "$diag" in *"ATTENZIONE|Frequenza|bloccato: frequenza 88200 Hz non accettata dal DAC"*) ok "stato: stallo da frequenza rifiutata segnalato" ;; *) ko "stato: stallo da frequenza" "bloccato: frequenza 88200 Hz" "-" ;; esac
printf '[12:00:00] output:1 device hw:X refuses 88200 Hz and strict hw mode (-H) forbids the plughw: fallback\n' > "$WEB/squeezelite.log"
diag=$(diag_freq)
case "$diag" in *"|Frequenza|"*) ko "stato: un solo rifiuto non e' uno stallo" "nessuna voce" "voce presente" ;; *) ok "stato: un solo rifiuto non e' uno stallo" ;; esac
printf '[12:00:00] process:1 resampling from 88200 -> 96000\n' > "$WEB/squeezelite.log"
diag=$(diag_freq)
case "$diag" in *"ATTENZIONE|Frequenza|ricampionata (88200 -> 96000 Hz)"*) ok "stato: avviso di ricampionamento" ;; *) ko "stato: avviso di ricampionamento" "ricampionata (88200 -> 96000 Hz)" "-" ;; esac
case "$diag" in *"abbassa il segnale di 1 dB"*) ok "stato: il ricampionamento dichiara i -1 dB" ;; *) ko "stato: -1 dB" "1 dB" "-" ;; esac
# Il registro di una zona (squeezelite-<id>.log) si legge come quello principale.
rm -f "$WEB/squeezelite.log"
printf '[12:00:00] process:1 resampling from 88200 -> 96000\n' > "$WEB/squeezelite-Zona.log"
diag=$(diag_freq)
case "$diag" in *"ATTENZIONE|Frequenza (zona Zona)|ricampionata (88200 -> 96000 Hz)"*) ok "stato: ricampionamento di una zona dal suo registro" ;; *) ko "stato: registro della zona" "Frequenza (zona Zona)" "$diag" ;; esac
rm -f "$WEB/squeezelite-Zona.log"
# Uscita forzata a 16 bit: riduzione con dither TPDF dichiarata.
printf 'FORMATO_USCITA=16\n' > "$WEB/run/sweetspot.conf"
diag=$(diag_freq)
case "$diag" in *"INFO|Uscita a 16 bit|"*"dither TPDF"*) ok "stato: uscita a 16 bit con dither TPDF dichiarata" ;; *) ko "stato: uscita a 16 bit" "voce Uscita a 16 bit" "$diag" ;; esac
rm -f "$WEB/run/sweetspot.conf"
# Volume del DAC senza controllo, e ripiego sul volume software.
printf 'VOLUME=dac\n' > "$WEB/run/sweetspot.conf"
printf 'fisso\n' > "$WEB/run/volume.effettivo"
diag=$(diag_freq)
case "$diag" in *"ATTENZIONE|Volume|richiesto del DAC, ma il DAC non ha un controllo del volume"*) ok "stato: VOLUME=dac senza controllo riportato come fisso" ;; *) ko "stato: dac senza controllo" "volume fisso" "$diag" ;; esac
printf 'hardware\n' > "$WEB/run/volume.effettivo"
printf '[12:00:00] output:1 Initialization of mixer failed, reverting to software volume\n' > "$WEB/squeezelite.log"
diag=$(diag_freq)
case "$diag" in *"ATTENZIONE|Volume|richiesto del DAC, ma il controllo hardware non risponde"*) ok "stato: ripiego sul volume software non piu' detto hardware" ;; *) ko "stato: ripiego del volume" "volume software" "$diag" ;; esac
rm -f "$WEB/run/sweetspot.conf" "$WEB/run/volume.effettivo" "$WEB/squeezelite.log"
# Lyrion ricampiona con sox i brani sopra la massima del player (HELO MaxSampleRate).
echo '# [sox] -r commento' > "$WEB/convert.conf"
printf 'flc pcm * *\n\t[flac] -dcs -- $FILE$ | [sox] -q -t wav - -t raw -r $RATE$ -\n' >> "$WEB/convert.conf"
diag=$(SWEETSPOT_LMS_CONVERT=$WEB/convert.conf diag_freq)
case "$diag" in *"INFO|Lyrion e sox|"*) ok "stato: regole sox di convert.conf dichiarate" ;; *) ko "stato: convert.conf" "voce Lyrion e sox" "$diag" ;; esac
! grep -q 'playerpref maxSampleRate' "$OVERLAY/usr/bin/sweetspot-player" && grep -q 'frequenza.max' "$OVERLAY/usr/bin/sweetspot-player" && ok "player: niente maxSampleRate (non e' una preferenza di Lyrion), massima annotata per Stato" || ko "player: frequenza massima" "frequenza.max senza playerpref" "-"
grep -q 'tags:T' "$OVERLAY/usr/bin/sweetspot-check" && ok "stato: Lyrion ricampiona se il brano supera la massima del player" || ko "stato: brano oltre la massima" "confronto con la frequenza del brano" "assente"
grep -q 'echo pcm > "\$RUN/dsd.volume"' "$OVERLAY/usr/bin/sweetspot-player" && ok "player: con il volume software il DSD si converte in PCM" || ko "player: DSD con volume software" "presente" "assente"

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
case "$diag" in *"INFO|Margine DSD → PCM|-3 dB (DSD_PCM_MARGINE_DB)"*) ok "stato: margine DSD → PCM mostrato" ;; *) ko "stato margine DSD" "Margine DSD → PCM|-3 dB" "$(printf '%s' "$diag" | head -n 8)" ;; esac
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
diag=$(diag_freq)
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
diag=$(diag_freq)
case "$diag" in *'XRUN ALSA registrati|1 nel registro'*) ok "XRUN: recupero fallito non raddoppia evento" ;; *) ko "XRUN doppio conto" "1" "-" ;; esac
case "$diag" in *'ATTENZIONE|Recuperi XRUN falliti|1 nel registro'*) ok "XRUN: recupero fallito contato a parte" ;; *) ko "XRUN recupero" "1" "-" ;; esac
printf '[12:00:00] output_thread:123 XRUN recover failed: Broken pipe\n' > "$WEB/squeezelite.log"
diag=$(diag_freq)
case "$diag" in *'XRUN ALSA registrati|0 nel registro'*) ok "XRUN: solo recupero non inventa evento" ;; *) ko "XRUN solo recupero evento" "0" "-" ;; esac
case "$diag" in *'ATTENZIONE|Recuperi XRUN falliti|1 nel registro'*) ok "XRUN: solo recupero richiede attenzione" ;; *) ko "XRUN solo recupero attenzione" "ATTENZIONE 1" "-" ;; esac
printf 'NOTXRUN\nDescrizione XRUN\nXRUN nei commenti\n[12:00:00] other:1 descriptive XRUN\n' > "$WEB/squeezelite.log"
case "$(check_page_diag)" in *'XRUN ALSA registrati|0 nel registro'*) ok "XRUN: sottostringhe incidentali ignorate" ;; *) ko "XRUN incidentale" "0" "-" ;; esac
rm -f "$WEB/squeezelite.log"
diag=$(diag_freq)
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
else
	salta "camilladsp"
fi
expect "correzione: volume principale a 0 dB per ogni processo" "0.0 0|1" \
	"$(cat "$DSPE/run/camilladsp.volume")|$(grep -c "vol_file \"$DSPE/run/camilladsp.volume\"" "$DSPE/asound.conf")"
expect "volume a 64 bit: CamillaDSP serve anche senza correzione" "0|1" "$(dsp 'VOLUME=dsp' attiva; echo $?)|$(dsp 'VOLUME=dsp' correzione; echo $?)"
expect "volume a 64 bit in modalita' player senza SERVER: non disponibile" "1" "$(dsp "$(printf 'VOLUME=dsp\nMODALITA=player')" attiva; echo $?)"
expect "volume a 64 bit in modalita' player con SERVER: disponibile" "0|0" \
	"$(dsp "$(printf 'VOLUME=dsp\nMODALITA=player\nSERVER=192.168.1.5')" attiva; echo $?)|$(dsp "$(printf 'VOLUME=dsp\nMODALITA=player\nSERVER=192.168.1.5')" volume; echo $?)"
expect "volume a 64 bit in modalita' player: il sorvegliante legge il Lyrion indicato" "192.168.1.5|127.0.0.1" \
	"$(printf 'MODALITA=player\nSERVER=192.168.1.5:3483\n' > "$DSPE/s.txt"; SWEETSPOT_RUN=$DSPE/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LOG=$DSPE/log SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $DSPE/s.txt; . $OVERLAY/usr/bin/sweetspot-volume; echo \$LMS_HOST")|$(printf 'MODALITA=completa\nSERVER=192.168.1.5\n' > "$DSPE/s.txt"; SWEETSPOT_RUN=$DSPE/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LOG=$DSPE/log SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $DSPE/s.txt; . $OVERLAY/usr/bin/sweetspot-volume; echo \$LMS_HOST")"
lmshost() { printf 'MODALITA=player\nSERVER=%s\n' "$1" > "$DSPE/s.txt"; SWEETSPOT_RUN=$DSPE/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LOG=$DSPE/log SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $DSPE/s.txt; . $OVERLAY/usr/bin/sweetspot-volume; echo \$LMS_HOST"; }
expect "volume: SERVER IPv6 con porta, IPv6 senza porta, host:porta, host" "fe80::1|fe80::1|lyrion.lan|10.0.0.2" 	"$(lmshost '[fe80::1]:3483')|$(lmshost 'fe80::1')|$(lmshost 'lyrion.lan:3483')|$(lmshost '10.0.0.2')"
rm -f "$DSPE/run/camilladsp.volume"
mv "$DSPE/run/correzione/sinistro.txt" "$DSPE/sinistro.bak"
dsp 'VOLUME=dsp' prepara 1 > /dev/null
yml=$(cat "$DSPE/run/camilladsp.yml")
expect "volume a 64 bit, DAC a 16 bit: nessun filtro, guadagno 0, dither a 16 bit, mai sopra 0 dB" "0|0.0|bits: 16|volume_limit: 0.0" \
	"$(printf '%s\n' "$yml" | grep -c 'type: Biquad')|$(printf '%s\n' "$yml" | sed -n 's/^      gain: //p' | head -n 1)|$(printf '%s\n' "$yml" | grep -o 'bits: 16')|$(printf '%s\n' "$yml" | grep -o 'volume_limit: 0.0')"
expect "volume a 64 bit: primo avvio a -30 dB in sordina (silenzio, non volume udibile)" "-30.0 1" "$(cat "$DSPE/run/camilladsp.volume")"
# file del volume assente o non valido: CamillaDSP parte in sordina (-m)
rm -f "$DSPE/run/camilladsp.volume"
expect "avvio senza file del volume: sordina (-m)" "-g-30.0 -m" "$(dsp 'VOLUME=dsp' avvio | sed -n 's/.*\(-g[^ ]* -m\).*/\1/p')"
echo "spazzatura" > "$DSPE/run/camilladsp.volume"
expect "avvio con file del volume non valido: sordina (-m)" "-g-30.0 -m" "$(dsp 'VOLUME=dsp' avvio | sed -n 's/.*\(-g[^ ]* -m\).*/\1/p')"
echo "-30.0 1" > "$DSPE/run/camilladsp.volume"
printf 'Playback:\n  Interface 1\n    Format: S32_LE\n    Rates: 44100 48000 96000\n' > "$DSPE/proc/asound/card1/stream0"
echo "-17.4 1" > "$DSPE/run/camilladsp.volume"
dsp 'VOLUME=dsp' prepara 1 > /dev/null
expect "volume a 64 bit, DAC a 32 bit: dither a 24 bit" "S32_LE|bits: 24|dither 3" \
	"$(grep -o 'format: S32_LE' "$DSPE/run/camilladsp.yml" | head -n 1 | cut -d' ' -f2)|$(grep -o 'bits: 24' "$DSPE/run/camilladsp.yml")|dither $(grep -c 'dither' "$DSPE/run/camilladsp.yml")"
expect "volume a 64 bit: il volume gia' scelto resta" "-17.4 1" "$(cat "$DSPE/run/camilladsp.volume")"
if command -v camilladsp > /dev/null; then
	if camilladsp -c "$DSPE/run/camilladsp.yml" > /dev/null 2>&1; then ok "configurazione del volume accettata da CamillaDSP"; else ko "camilladsp -c volume" "valida" "rifiutata"; fi
else
	salta "camilladsp"
fi
expect "file del volume: valori non validi rifiutati" "1|-17.4 1" "$(dsp '' stato 'abc'; echo $?)|$(cat "$DSPE/run/camilladsp.volume")"
mv "$DSPE/sinistro.bak" "$DSPE/run/correzione/sinistro.txt"
dsp 'CORREZIONE=si' prepara 1 > /dev/null
expect "tornando al volume fisso il guadagno riparte da 0 dB" "0.0 0" "$(cat "$DSPE/run/camilladsp.volume")"
VB=$DSPE/volbin
mkdir -p "$VB"
cp "$ROOT/tests/fixtures/camilla-finta.sh" "$VB/sweetspot-camilla"
chmod +x "$VB/sweetspot-camilla"
vol() {
	SWEETSPOT_VOLUME_PAUSA=0 SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_ASOUND=$DSPE/asound.conf \
		$TEST_SH -c "PATH=$VB:$OVERLAY/usr/bin:\$PATH; . $OVERLAY/usr/bin/sweetspot-volume" sh "$@"
}
volfn() { # funzione
	SWEETSPOT_VOLUME_PAUSA=0 SWEETSPOT_RUN=$DSPE/run SWEETSPOT_PROCFS=$DSPE/proc SWEETSPOT_LOG=$DSPE/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
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
# Esito dei comandi a CamillaDSP: stato richiesto e stato applicato separati.
vol applica 50 0
expect "volume 50 riuscito: richiesto e applicato coincidono" "50 -24.7 0|50 -24.7 0" \
	"$(cat "$DSPE/run/volume.dsp")|$(cat "$DSPE/run/volume.applicato")"
rm -f "$DSPE/run/camilla.call"
echo 2 > "$DSPE/run/camilla.fail"
vol applica 60 0; rc=$?
expect "errore IPC sotto il limite: ritenta e va a buon fine" "0|3|60 -19.7 0|-19.7" \
	"$rc|$(grep -c SetVolume "$DSPE/run/camilla.call")|$(cat "$DSPE/run/volume.applicato")|$(cat "$DSPE/run/camilla.vol")"
echo 99 > "$DSPE/run/camilla.fail"
rm -f "$DSPE/run/camilla.call"
vol applica 80 0; rc=$?
expect "CamillaDSP non risponde: tentativi limitati, esito errore, richiesto != applicato" "1|3|80 -9.9 0|errore|-19.7" \
	"$rc|$(grep -c SetVolume "$DSPE/run/camilla.call")|$(cat "$DSPE/run/volume.dsp")|$(cat "$DSPE/run/volume.applicato")|$(cat "$DSPE/run/camilla.vol")"
# Riavvio del DSP: riparte da un altro volume, il controllo periodico lo riallinea.
echo 0 > "$DSPE/run/camilla.fail"
echo "-74.0" > "$DSPE/run/camilla.vol"; echo true > "$DSPE/run/camilla.mute"
volfn 'dsp_resync'
expect "riavvio di CamillaDSP: il volume richiesto viene riapplicato" "-9.9|false|80 -9.9 0" \
	"$(cat "$DSPE/run/camilla.vol")|$(cat "$DSPE/run/camilla.mute")|$(cat "$DSPE/run/volume.applicato")"
rm -f "$DSPE/run/camilla.call"
volfn 'dsp_resync'
expect "gia' allineato: nessun comando di scrittura" "0" "$(grep -c Set "$DSPE/run/camilla.call")"
# Istanza di sessione riavviata dal player: risincronizza riapplica sempre il
# volume richiesto e volume.applicato torna quello confermato.
echo errore > "$DSPE/run/volume.applicato"
vol risincronizza
expect "riavvio dell'istanza di sessione: volume.applicato riallineato" "80 -9.9 0" "$(cat "$DSPE/run/volume.applicato")"
expect "player: dopo il riavvio dell'istanza chiama sweetspot-volume risincronizza" "1" "$(grep -c 'sweetspot-volume risincronizza' "$OVERLAY/usr/bin/sweetspot-player")"
echo 99 > "$DSPE/run/camilla.fail"; echo "-74.0" > "$DSPE/run/camilla.vol"
volfn 'dsp_resync'; echo 0 > "$DSPE/run/camilla.fail"
expect "DSP irraggiungibile durante il riavvio: nessun errore, nessuna modifica" "-74.0" "$(cat "$DSPE/run/camilla.vol")"
vol applica 100 0
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
	else
		salta "camilladsp"
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
	expect "FIR corrotto accanto a filtri REW buoni: problema esplicito, correzione non attiva" \
		"fir-sinistro.wav non e' un WAV valido (mono o stereo, almeno 8000 Hz)|1" \
		"$(dsp 'CORREZIONE=si' problema)|$(dsp 'CORREZIONE=si' correzione > /dev/null; echo $?)"
	: > "$DSPE/run/correzione/fir-sinistro.wav"
	expect "FIR vuoto: problema" "fir-sinistro.wav vuoto" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-destro.wav"
	rm -f "$DSPE/run/correzione/fir-sinistro.wav"
	expect "FIR solo destro: problema" "c'e' fir-destro.wav ma manca fir-sinistro.wav" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-sinistro.wav"
	mkwav 48000 1 > "$DSPE/run/correzione/fir-destro.wav"
	expect "FIR con frequenze diverse: problema" "i FIR hanno frequenze diverse (sinistro 96000 Hz, destro 48000 Hz)" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 96000 2 > "$DSPE/run/correzione/fir-destro.wav"
	expect "FIR con canali diversi: problema" "i FIR hanno canali diversi (sinistro 1, destro 2)" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-destro.wav"
	expect "FIR coerenti con filtri REW: nessun problema" "" "$(dsp 'CORREZIONE=si' problema)"
	rm -f "$DSPE/run/correzione/fir-destro.wav"
	mkwav 96000 1 > "$DSPE/run/correzione/fir-sinistro.wav"
	mv "$DSPE/run/correzione/sinistro.txt" "$DSPE/sinistro-rew.bak"
	expect "solo FIR, senza filtri di REW: correzione attiva" "0" "$(dsp 'CORREZIONE=si' correzione; echo $?)"
	mv "$DSPE/sinistro-rew.bak" "$DSPE/run/correzione/sinistro.txt"
	cp "$DSPE/run/correzione/fir-sinistro.wav" "$DSPE/chiavetta/correzione-ambientale/"
	SWEETSPOT_STICK_DIR=$DSPE/chiavetta dsp '' salva "$DSPE/rew.txt" "" > /dev/null
	expect "salvare i filtri di REW non cancella i FIR sulla chiavetta" "si" \
		"$([ -s "$DSPE/chiavetta/correzione-ambientale/fir-sinistro.wav" ] && echo si || echo no)"
	rm -f "$DSPE/run/correzione/fir-sinistro.wav" "$DSPE/run/correzione/fir-destro.wav"

	# FIR per frequenza: un file per ogni frequenza di campionamento (nome con
	# la frequenza), CamillaDSP resta alla frequenza del brano.
	FR=$DSPE/run/correzione
	plan() { sed 's/ *$//' "$DSPE/run/correzione.frequenze" | tr '\n' '|' | sed 's/|$//'; }
	mkwav 44100 1 > "$FR/fir-44100.wav"
	mkwav 96000 2 > "$FR/fir-96000.wav"
	expect "FIR per frequenza: elenco delle frequenze" "44100|96000" "$(dsp 'CORREZIONE=si' fir-frequenze | tr '\n' '|' | sed 's/|$//')"
	expect "FIR per frequenza: nessun problema" "" "$(dsp 'CORREZIONE=si' problema)"
	expect "FIR per frequenza: primo FIR" "44100 1 sinistro 3" "$(dsp 'CORREZIONE=si' fir)"
	dsp 'CORREZIONE=si' prepara 1 > /dev/null
	expect "FIR per frequenza, politica blocca: 48 kHz non offerto" "44100 fir 44100|48000 escluso -|96000 fir 96000" "$(plan)"
	expect "FIR per frequenza: squeezelite vede solo le frequenze con FIR" "rates = [ 44100 96000 ]" "$(grep -o 'rates = \[.*\]' "$DSPE/asound.conf")"
	expect "FIR per frequenza: una configurazione per frequenza" "samplerate: 44100|samplerate: 96000|0" \
		"$(grep -o 'samplerate: [0-9]*' "$DSPE/run/camilladsp-44100.yml")|$(grep -o 'samplerate: [0-9]*' "$DSPE/run/camilladsp-96000.yml")|$(ls "$DSPE"/run/camilladsp-48000.yml 2> /dev/null | wc -l | tr -d ' ')"
	expect "FIR per frequenza: ognuna col suo file e il suo canale" "fir-44100.wav 0 0|fir-96000.wav 0 1" \
		"$(grep -o 'fir-[0-9]*.wav' "$DSPE/run/camilladsp-44100.yml" | head -n 1) $(grep -o 'channel: [01]' "$DSPE/run/camilladsp-44100.yml" | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//')|$(grep -o 'fir-[0-9]*.wav' "$DSPE/run/camilladsp-96000.yml" | head -n 1) $(grep -o 'channel: [01]' "$DSPE/run/camilladsp-96000.yml" | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//')"
	expect "FIR per frequenza: nessun ricampionamento (niente capture_samplerate)" "0|0" \
		"$(grep -c capture_samplerate "$DSPE/run/camilladsp-44100.yml")|$(grep -c capture_samplerate "$DSPE/run/camilladsp-96000.yml")"
	expect "FIR per frequenza: configurazione di partenza = prima frequenza offerta" "samplerate: 44100" "$(grep -o 'samplerate: [0-9]*' "$DSPE/run/camilladsp.yml")"
	expect "FIR per frequenza: coda col FIR di quella frequenza" "extra_samples: 8704" "$(grep -o 'extra_samples: [0-9]*' "$DSPE/run/camilladsp-96000.yml")"
	expect "FIR per frequenza: avviso visibile con la politica blocca" \
		"nessun FIR a 48000 Hz: i brani a queste frequenze non vengono riprodotti (CORREZIONE_SE_ASSENTE=blocca)" "$(cat "$DSPE/run/correzione.avviso")"
	expect "il plugin lavora sulla pipe e sul websocket, una configurazione per frequenza" \
		"fifo \"$DSPE/run/camilladsp.fifo\"|ws_port 1234|config_rate_prefix \"$DSPE/run/camilladsp-\"" \
		"$(grep -o 'fifo ".*"' "$DSPE/asound.conf")|$(grep -o 'ws_port [0-9]*' "$DSPE/asound.conf")|$(grep -o 'config_rate_prefix ".*"' "$DSPE/asound.conf")"
	expect "avvio unico di CamillaDSP: argomenti con registro, websocket locale, volume e prima configurazione" \
		"-l warn -o /var/log/camilladsp.log -p 1234 -a 127.0.0.1 -g0.0 $DSPE/run/camilladsp-44100.yml" "$(dsp 'CORREZIONE=si' avvio)"
	dsp 'CORREZIONE=si' stato -12.5 muto
	expect "avvio unico: volume e sordina di partenza dal file" "-l warn -o /var/log/camilladsp.log -p 1234 -a 127.0.0.1 -g-12.5 -m $DSPE/run/camilladsp-44100.yml" "$(dsp 'CORREZIONE=si' avvio)"
	dsp 'CORREZIONE=si' stato 0.0
	dsp "$(printf 'CORREZIONE=si\nCORREZIONE_SE_ASSENTE=diretto')" prepara 1 > /dev/null
	expect "FIR per frequenza, politica diretto: 48 kHz senza FIR" "44100 fir 44100|48000 senza -|96000 fir 96000" "$(plan)"
	expect "FIR per frequenza, diretto: tutte le frequenze offerte" "rates = [ 44100 48000 96000 ]" "$(grep -o 'rates = \[.*\]' "$DSPE/asound.conf")"
	expect "FIR per frequenza, diretto: 48 kHz senza convoluzione e senza margine dei FIR" "samplerate: 48000|0|-4.5" \
		"$(grep -o 'samplerate: [0-9]*' "$DSPE/run/camilladsp-48000.yml")|$(grep -c 'type: Conv' "$DSPE/run/camilladsp-48000.yml")|$(sed -n 's/^      gain: //p' "$DSPE/run/camilladsp-48000.yml" | head -n 1)"
	expect "FIR per frequenza, diretto: avviso" "nessun FIR a 48000 Hz: suonano senza FIR (CORREZIONE_SE_ASSENTE=diretto)" "$(cat "$DSPE/run/correzione.avviso")"
	dsp "$(printf 'CORREZIONE=si\nFIR_RICAMPIONA=si')" prepara 1 > /dev/null
	expect "FIR per frequenza, ricampionamento scelto: 48 kHz al FIR della stessa famiglia" "44100 fir 44100|48000 ricampiona 96000|96000 fir 96000" "$(plan)"
	expect "FIR ricampionato: CamillaDSP a 96 kHz, ingresso a 48 kHz" "samplerate: 96000|capture_samplerate: 48000|type: Synchronous" \
		"$(grep -o 'samplerate: 96000' "$DSPE/run/camilladsp-48000.yml")|$(grep -o 'capture_samplerate: 48000' "$DSPE/run/camilladsp-48000.yml")|$(grep -o 'type: Synchronous' "$DSPE/run/camilladsp-48000.yml")"
	expect "FIR ricampionato: avviso" "nessun FIR, brani ricampionati alla frequenza del FIR piu' vicino (FIR_RICAMPIONA=si): 48000>96000" "$(cat "$DSPE/run/correzione.avviso")"
	mkwav 48000 1 > "$FR/fir-48000.wav"
	dsp 'CORREZIONE=si' prepara 1 > /dev/null
	expect "frequenze con FIR tutte coperte: nessun avviso" "no|44100 fir 44100|48000 fir 48000|96000 fir 96000" "$([ -s "$DSPE/run/correzione.avviso" ] && echo si || echo no)|$(plan)"
	rm -f "$FR/fir-48000.wav"
	# Sinistro e destro per frequenza.
	rm -f "$FR/fir-44100.wav" "$FR/fir-96000.wav"
	mkwav 44100 1 > "$FR/fir-sinistro-44100.wav"
	mkwav 44100 1 > "$FR/fir-destro-44100.wav"
	mkwav 48000 1 > "$FR/fir-sinistro-48000.wav"
	expect "FIR per canale e frequenza: nessun problema" "" "$(dsp 'CORREZIONE=si' problema)"
	dsp 'CORREZIONE=si' prepara 1 > /dev/null
	expect "FIR per canale e frequenza: il destro ha il suo file a 44,1 kHz, usa il sinistro a 48 kHz" "1|1|2" \
		"$(grep -c "fir-destro-44100.wav" "$DSPE/run/camilladsp-44100.yml")|$(grep -c "fir-sinistro-44100.wav" "$DSPE/run/camilladsp-44100.yml")|$(grep -c "fir-sinistro-48000.wav" "$DSPE/run/camilladsp-48000.yml")"
	# Validazione per frequenza.
	rm -f "$FR"/fir-*.wav
	mkwav 48000 1 > "$FR/fir-44100.wav"
	expect "FIR: la frequenza del file deve essere quella del nome" "fir-44100.wav ha frequenza 48000 Hz, non 44100 Hz come nel nome" "$(dsp 'CORREZIONE=si' problema)"
	expect "FIR con frequenza sbagliata nel nome: non usati" "1" "$(dsp 'CORREZIONE=si' fir-frequenze > /dev/null; echo $?)"
	rm -f "$FR"/fir-*.wav
	mkwav 44100 1 > "$FR/fir-44100x.wav"
	expect "FIR: la frequenza nel nome e' un numero" "fir-44100x.wav: la frequenza nel nome deve essere un numero (per esempio fir-44100.wav)" "$(dsp 'CORREZIONE=si' problema)"
	rm -f "$FR"/fir-*.wav
	mkwav 48000 1 > "$FR/fir-destro-48000.wav"
	expect "FIR: solo il destro a una frequenza" "a 48000 Hz c'e' il FIR del destro ma manca quello del sinistro (fir-sinistro-48000.wav o fir-48000.wav)" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 48000 1 > "$FR/fir-sinistro-48000.wav"
	mkwav 48000 2 > "$FR/fir-destro-48000.wav"
	expect "FIR: canali diversi alla stessa frequenza" "i FIR a 48000 Hz hanno canali diversi (sinistro 1, destro 2)" "$(dsp 'CORREZIONE=si' problema)"
	mkwav 48000 1 > "$FR/fir-destro-48000.wav"
	mkwav 44100 1 > "$FR/fir-44100.wav"
	: > "$FR/fir-96000.wav"
	expect "FIR: un file vuoto a una frequenza" "fir-96000.wav vuoto" "$(dsp 'CORREZIONE=si' problema)"
	rm -f "$FR"/fir-*.wav
	mkwav 192000 1 > "$FR/fir-192000.wav"
	expect "FIR solo a frequenze che il DAC non accetta: correzione non applicata" "1" "$(dsp 'CORREZIONE=si' prepara 1 > /dev/null; echo $?)"
	expect "FIR solo a frequenze che il DAC non accetta: il motivo le elenca" "il DAC non accetta nessuna delle frequenze dei filtri FIR (192000 Hz)" "$(cat "$DSPE/run/correzione.motivo")"
	rm -f "$FR"/fir-*.wav
	rm -f "$DSPE"/run/camilladsp-[0-9]*.yml "$DSPE/run/correzione.motivo" "$DSPE/run/correzione.avviso" "$DSPE/run/correzione.frequenze"
else
	salta "python3"
fi
# Correzione chiesta con file mancanti, illeggibili o malformati: il problema
# e' esplicito (con blocca il player non suona, vedi correzione_non_applicabile).
R=$DSPE/run/correzione
cp "$R/sinistro.txt" "$DSPE/sinistro-valido.bak"
expect "nessun problema con la correzione spenta" "" "$(dsp '' problema)"
expect "nessun problema con filtri validi" "" "$(dsp 'CORREZIONE=si' problema)"
mv "$R/sinistro.txt" "$DSPE/sinistro-spostato.bak"
expect "filtri mancanti con correzione chiesta" "nessun filtro trovato (servono sinistro.txt o fir-sinistro.wav)|0|1" \
	"$(dsp 'CORREZIONE=si' problema)|$(dsp 'CORREZIONE=si' richiesta; echo $?)|$(dsp 'CORREZIONE=si' correzione > /dev/null; echo $?)"
expect "filtri mancanti con correzione spenta: nessun problema" "" "$(dsp 'CORREZIONE=no' problema)"
: > "$R/sinistro.txt"
expect "filtri vuoti con correzione chiesta" "nessun filtro trovato (servono sinistro.txt o fir-sinistro.wav)" "$(dsp 'CORREZIONE=confronto' problema)"
echo "testo a caso" > "$R/sinistro.txt"
expect "filtri senza righe di REW: malformati" "sinistro.txt non e' un'esportazione di REW (nessuna riga \"Filter N:\")" "$(dsp 'CORREZIONE=si' problema)"
cp "$DSPE/rew-errori.txt" "$R/sinistro.txt"
expect "filtri con righe sbagliate: riga indicata" "riga 3" "$(dsp 'CORREZIONE=si' problema | grep -o 'riga [0-9]*')"
cp "$DSPE/sinistro-valido.bak" "$R/sinistro.txt"
echo "Filter  1: ON  XYZ  Fc 50 Hz" > "$R/destro.txt"
expect "destro malformato con sinistro valido: problema sul destro" "destro.txt non valido:" "$(dsp 'CORREZIONE=si' problema | cut -c1-22)"
rm -f "$R/sinistro.txt"
expect "solo destro.txt: problema" "c'e' destro.txt ma manca sinistro.txt" "$(dsp 'CORREZIONE=si' problema)"
rm -f "$R/destro.txt"
cp "$DSPE/sinistro-valido.bak" "$R/sinistro.txt"
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
# Titolo CJK lungo (3 byte a carattere): il nome resta entro 255 byte con ".flac" e prefisso e non spezza i caratteri
cjk=$(i=0; while [ $i -lt 150 ]; do printf '音楽'; i=$((i + 1)); done)
exp=$(i=0; while [ $i -lt 33 ]; do printf '音楽'; i=$((i + 1)); done)
expect "nomi di file: CJK tagliato a 198 byte senza spezzare caratteri" "$exp" "$(cdrun "file_name '$cjk'")"
expect "nomi di file: corto invariato" "音楽" "$(cdrun "file_name '音楽'")"
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

echo "Standby dei dischi interni"
SB=$WORK/standby
mkdir -p "$SB/run" "$SB/bin"
for d in sda sdb sdc sdd; do
	mkdir -p "$SB/sys/block/$d/queue" "$SB/sys/block/$d/${d}1" "$SB/sys/block/$d/dev"
	echo 0 > "$SB/sys/block/$d/removable"
	echo 1 > "$SB/sys/block/$d/queue/rotational"
done
echo 0 > "$SB/sys/block/sdd/queue/rotational"
# sda: musica; sdb: archivio; sdc: nessuna musica; sdd: SSD
printf 'Musica|/dev/sda1|ext4|500|1|ro|UUID=a\nArchivio|/dev/sdb1|ext4|900|1|rw|UUID=b\n' > "$SB/run/dischi.list"
printf '#!/bin/sh\necho "$@" >> "$HDPARM_LOG"\n' > "$SB/bin/hdparm"
chmod +x "$SB/bin/hdparm"
SWEETSPOT_TEST=1 SWEETSPOT_SYSFS=$SB/sys SWEETSPOT_RUN=$SB/run SWEETSPOT_LOG=$SB/log SWEETSPOT_HDPARM=$SB/bin/hdparm HDPARM_LOG=$SB/hdparm.log \
	$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-dischi; do_standby"
expect "standby: dischi con musica e archivio solo timeout lungo" "-S 241 /dev/sda|-S 241 /dev/sdb" "$(grep -E '/dev/sd[ab]$' "$SB/hdparm.log" | sort -u | tr '\n' '|' | sed 's/|$//')"
expect "standby: disco senza musica fermato subito" "-S 12 /dev/sdc|-y /dev/sdc" "$(grep '/dev/sdc$' "$SB/hdparm.log" | tr '\n' '|' | sed 's/|$//')"
expect "standby: nessun -y sui dischi con musica" "0" "$(grep -c -- '^-y /dev/sd[ab]$' "$SB/hdparm.log")"
expect "standby: SSD ignorato" "0" "$(grep -c '/dev/sdd' "$SB/hdparm.log")"
expect "standby: non piu' in S20 (gira prima del montaggio)" "0" "$(grep -c 'hdparm' "$OVERLAY/etc/init.d/S20sweetspot-tune")"

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
# wget finto: risponde anche alle richieste JSON di Lyrion; jq finto (in
# testa al PATH) accetta la risposta e restituisce una versione.
printf '#!/bin/sh\ncase "$*" in *jsonrpc*) echo "{\\"result\\":{\\"_version\\":\\"9\\"}}" ;; esac\nexit 0\n' > "$UPD/bin/wget-ok"
printf '#!/bin/sh\ncase "$*" in *jsonrpc*) exit 1 ;; esac\nexit 0\n' > "$UPD/bin/wget-nolms"
mkdir -p "$UPD/jq" "$UPD/musica" "$UPD/lmsdati"
printf '#!/bin/sh\nin=$(cat)\n[ -n "$in" ] || exit 1\ncase "$*" in *-e*) exit 0 ;; esac\necho 9\n' > "$UPD/jq/jq"
chmod +x "$UPD/jq/jq"
echo "MODALITA=completa" > "$UPD/run/sweetspot.conf"
sleep 7200 &
UPD_SUP=$!
echo "$UPD_SUP" > "$UPD/run/supervisore.pid"
printf '#!/bin/sh\nexit 1\n' > "$UPD/bin/wget-ko"
# Rete: una scheda via cavo collegata, con l'indirizzo dato da ip finto.
mkdir -p "$UPD/sys/class/net/eth0/device"
echo 1 > "$UPD/sys/class/net/eth0/type"
echo 1 > "$UPD/sys/class/net/eth0/carrier"
printf '#!/bin/sh\necho "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0"\n' > "$UPD/bin/ip-ok"
printf '#!/bin/sh\nexit 0\n' > "$UPD/bin/ip-nessuno"
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
		SWEETSPOT_IP=${UPD_IP:-$UPD/bin/ip-ok} SWEETSPOT_CONFERMA_ATTESA_RETE=2 \
		SWEETSPOT_CONFERMA_ATTESA_LMS=2 SWEETSPOT_MUSICA=$UPD/musica SWEETSPOT_LMS_DATA=$UPD/lmsdati SWEETSPOT_PATH=${UPD_PATH:-$UPD/jq:$SWEETSPOT_PATH} \
		SWEETSPOT_CHIAVE_FIRMA=${UPD_PUB:-$UPD/nessuna-chiave.pub} SWEETSPOT_TEST=cli SWEETSPOT_ALLOW_UNSIGNED=1 \
		SWEETSPOT_SPAZIO_LIBERO=${UPD_LIBERO:-} SWEETSPOT_RIPROVA_ATTESA=0 \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-aggiorna" "$@"
}
genv() { $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; grubenv_get \"\$1\" \"\$2\"" sh "$UPD/stick/boot/grub/grubenv" "$1"; }
setenv() { $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; f=\$1; shift; grubenv_set \"\$f\" \"\$@\"" sh "$UPD/stick/boot/grub/grubenv" "$@"; }
setenv slot=a
expect "ambiente di GRUB di 1024 byte" "1024" "$(wc -c < "$UPD/stick/boot/grub/grubenv" | tr -d ' ')"
if command -v grub-editenv > /dev/null; then
	expect "ambiente leggibile da GRUB" "slot=a" "$(grub-editenv "$UPD/stick/boot/grub/grubenv" list)"
else
	salta "grub-editenv"
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
# Un altro aggiornamento mentre B e' in prova renderebbe B predefinita
# senza conferma e cancellerebbe A: si rifiuta e A resta.
printf 'versione=v9.9.9\nurl=https://example.com/upd.tar\ndimensione=1\n' > "$UPD/run/aggiornamento/disponibile"
expect "in prova: scarica rifiutato" "la versione in uso e' ancora in prova" "$(upd scarica | cut -d: -f1)"
rm -f "$UPD/run/aggiornamento/disponibile"
expect "in prova: pacchetto dal disco rifiutato" "la versione in uso e' ancora in prova" \
	"$(upd file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar" | cut -d: -f1)"
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "in prova: anche il lavoro si ferma" "errore|la versione in uso e' ancora in prova" "$(cut -d: -f1 "$UPD/run/aggiornamento/stato")"
expect "in prova: copia A intatta e non predefinita" "A-kernel|a|b" "$(cat "$UPD/stick/bzImage")|$(genv slot)|$(genv tentato)"
UPD_WGET=$UPD/bin/wget-ko upd conferma
expect "senza risposta dalla rete non si conferma" "a|b" "$(genv slot)|$(genv tentato)"
upd conferma
expect "la nuova versione si conferma" "b|" "$(genv slot)|$(genv tentato)"
expect "aggiornamento riuscito segnalato" "riuscita=1" "$(upd stato | grep '^riuscita=')"
expect "menu di avvio aggiornato dopo la conferma" "menu nuovo" "$(cat "$UPD/stick/boot/grub/grub.cfg")"
# GRUB per BIOS: un file al posto del disco; dd che fallisce al secondo
# stadio (rimesso com'era) o al primo (anche il secondo ripristinato).
GB=$UPD/grubbios
mkdir -p "$GB/bin" "$GB/run/aggiornamento"
head -c 1100 /dev/zero | tr '\0' 'N' > "$GB/avvio-grub.img"
head -c 512 /dev/zero | tr '\0' 'B' > "$GB/avvio-boot.img"
printf '#!/bin/sh\ncase "$*" in *"$DD_FALLISCI"*) [ -n "$DD_FALLISCI" ] && exit 1 ;; esac\nexec dd "$@"\n' > "$GB/bin/dd"
chmod +x "$GB/bin/dd"
grubbios() { # fallimento: stringa che fa fallire un dd
	head -c 4096 /dev/zero | tr '\0' 'V' > "$GB/disco"
	cp "$GB/disco" "$GB/disco.prima"
	SWEETSPOT_RUN=$GB/run SWEETSPOT_LOG=$GB/log SWEETSPOT_AVVIO=$GB SWEETSPOT_TEST=1 DD_FALLISCI=$1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-aggiorna; AVVIO=$GB; DIR=$GB/run/aggiornamento
		cp $GB/avvio-grub.img $GB/grub.img; cp $GB/avvio-boot.img $GB/boot.img
		dd() { $GB/bin/dd \"\$@\"; }
		dd if=$GB/disco bs=512 skip=1 count=3 2>/dev/null | head -c 1100 > \$DIR/grub.ora
		dd if=$GB/disco bs=440 count=1 2>/dev/null > \$DIR/mbr.ora
		head -c 440 $GB/boot.img > \$DIR/mbr.nuovo
		blockdev() { :; }
		scrivi_grub_bios $GB/disco 3; echo \$?"
}
expect "GRUB per BIOS scritto e riletto" "0|1" "$(grubbios '' | tail -1)|$(cmp -s "$GB/disco" "$GB/disco.prima" && echo 0 || echo 1)"
expect "GRUB per BIOS: primo stadio nuovo" "BBB" "$(dd if="$GB/disco" bs=1 count=3 2>/dev/null)"
expect "GRUB per BIOS: dd del secondo stadio fallito, disco com'era" "1|0" "$(grubbios 'grub.img' | tail -1)|$(cmp -s "$GB/disco" "$GB/disco.prima" && echo 0 || echo 1)"
expect "GRUB per BIOS: dd del primo stadio fallito, disco com'era" "1|0" "$(grubbios 'mbr.nuovo' | tail -1)|$(cmp -s "$GB/disco" "$GB/disco.prima" && echo 0 || echo 1)"
# Con la password delle pagine l'httpd risponde 401 a chi non si presenta:
# la conferma usa l'utente sweetspot con la chiave di questo avvio.
printf '#!/bin/sh\nfor a; do case "$a" in *jsonrpc*) echo "{\\"result\\":{\\"_version\\":\\"9\\"}}"; exit 0 ;; http://sweetspot:0123456789abcdef0123456789abcdef@127.0.0.1/cgi-bin/vivo) exit 0 ;; esac; done\nexit 1\n' > "$UPD/bin/wget-401"
chmod +x "$UPD/bin/wget-401"
setenv prova= tentato=b
UPD_WGET=$UPD/bin/wget-401 upd conferma
expect "con la password e senza chiave la conferma non passa (401)" "b" "$(genv tentato)"
echo 0123456789abcdef0123456789abcdef > "$UPD/run/vivo.chiave"
UPD_WGET=$UPD/bin/wget-401 upd conferma
expect "con la password la conferma passa con la chiave della pagina vivo" "b|" "$(genv slot)|$(genv tentato)"
rm -f "$UPD/run/vivo.chiave"
# Controlli ulteriori della conferma: ognuno registra quale e' fallito
conferma_ko() { # nome comando-che-rompe comando-che-ripara [wget]
	setenv prova= tentato=b
	rm -f "$UPD/stick/boot/conferma-fallita"
	eval "$2"
	UPD_WGET=${4:-$UPD/bin/wget-ok} upd conferma
	expect "$1: non si conferma" "b" "$(genv tentato)"
	expect "$1: controllo registrato sulla chiavetta" "$1" "$(cut -d'|' -f1 "$UPD/stick/boot/conferma-fallita")"
	eval "$3"
}
conferma_ko lyrion : : "$UPD/bin/wget-nolms"
conferma_ko supervisore 'rm -f "$UPD/run/supervisore.pid"' 'echo $UPD_SUP > "$UPD/run/supervisore.pid"'
conferma_ko libreria 'rmdir "$UPD/lmsdati"' 'mkdir "$UPD/lmsdati"'
conferma_ko impostazioni 'mv "$UPD/run/sweetspot.conf" "$UPD/run/sc"' 'mv "$UPD/run/sc" "$UPD/run/sweetspot.conf"'
# Rete rotta: la pagina locale risponde, ma il lettore non si raggiunge
conferma_ko rete 'echo 0 > "$UPD/sys/class/net/eth0/carrier"' 'echo 1 > "$UPD/sys/class/net/eth0/carrier"'
conferma_ko rete 'export UPD_IP=$UPD/bin/ip-nessuno' 'unset UPD_IP'
conferma_ko rete 'rmdir "$UPD/sys/class/net/eth0/device"' 'mkdir "$UPD/sys/class/net/eth0/device"'
# Con l'hotspot di configurazione acceso il lettore si raggiunge
echo 0 > "$UPD/sys/class/net/eth0/carrier"
echo wlan0 > "$UPD/run/hotspot.attivo"
setenv prova= tentato=b
UPD_IP=$UPD/bin/ip-nessuno upd conferma
expect "rete: con l'hotspot acceso si conferma" "b|" "$(genv slot)|$(genv tentato)"
rm -f "$UPD/run/hotspot.attivo"
# Wi-Fi: il collegamento non conta, basta l'indirizzo
mkdir "$UPD/sys/class/net/eth0/wireless"
setenv prova= tentato=b
upd conferma
expect "rete: Wi-Fi con indirizzo, si conferma" "b|" "$(genv slot)|$(genv tentato)"
rmdir "$UPD/sys/class/net/eth0/wireless"
echo 1 > "$UPD/sys/class/net/eth0/carrier"
rm -f "$UPD/stick/boot/conferma-fallita"
# Modalita' player: Lyrion non e' di questa macchina e non conta
echo "MODALITA=player" > "$UPD/run/sweetspot.conf"
rmdir "$UPD/lmsdati"
setenv prova= tentato=b
UPD_WGET=$UPD/bin/wget-nolms upd conferma
expect "modalita' player: senza Lyrion locale la conferma passa" "b|" "$(genv slot)|$(genv tentato)"
echo "MODALITA=completa" > "$UPD/run/sweetspot.conf"; mkdir "$UPD/lmsdati"
# Senza DAC (player in attesa del DAC) la nuova versione e' valida
echo "in attesa del DAC" > "$UPD/run/player.stato"
setenv prova= tentato=b
upd conferma
expect "in attesa del DAC non e' un guasto: si conferma" "b|" "$(genv slot)|$(genv tentato)"
rm -f "$UPD/run/player.stato" "$UPD/stick/boot/conferma-fallita"
# Secondo aggiornamento (va nella copia A), che non parte: si torna a B
rm -f "$UPD/run/aggiornamento/riuscita"
mkpkg v1.2.0 x86_64
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "secondo aggiornamento nella copia A" "kernel v1.2.0|a" "$(cat "$UPD/stick/bzImage")|$(genv prova)"
setenv prova= tentato=a
upd conferma
expect "versione non partita: si resta su B" "b|" "$(genv slot)|$(genv tentato)"
expect "versione non partita segnalata" "fallita=v1.2.0" "$(upd stato | grep '^fallita=')"
# La versione che torna mostra il controllo fallito lasciato dalla nuova
echo "lyrion|Lyrion non risponde" > "$UPD/stick/boot/conferma-fallita"
setenv prova= tentato=a
upd conferma
expect "motivo del ritorno nello stato" "fallita_controllo=lyrion|Lyrion non risponde" "$(upd stato | grep '^fallita_controllo=')"
expect "motivo ritirato dalla chiavetta" "no" "$([ -f "$UPD/stick/boot/conferma-fallita" ] && echo si || echo no)"
# Pacchetti sbagliati
mkpkg v1.3.0 x86_64 rovina
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "pacchetto rovinato rifiutato" "errore" "$(cut -d'|' -f1 "$UPD/run/aggiornamento/stato")"
expect "nessuna prova dopo un pacchetto rovinato" "" "$(genv prova)"
expect "pacchetto rovinato: la copia precedente resta" "kernel v1.2.0|rootfs v1.2.0|v1.2.0" \
	"$(cat "$UPD/stick/bzImage")|$(cat "$UPD/stick/rootfs.cpio.zst")|$(cat "$UPD/stick/boot/versioni/a")"
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
echo "$*" > "$0.args"
cat <<'JSON'
{"tag_name":"v2.0.0","published_at":"2026-11-01T10:00:00Z","body":"Novità: <b>prova</b>",
 "assets":[{"name":"sweetspot.img.xz","browser_download_url":"https://example.com/img","size":1},
           {"name":"sweetspot-x86_64-aggiornamento.tar","browser_download_url":"https://example.com/upd.tar","size":104857600}]}
JSON
EOF2
chmod +x "$UPD/bin/curl"
expect "ricerca su GitHub" "versione=v2.0.0 url=https://example.com/upd.tar dimensione=104857600 data=2026-11-01" \
	"$(UPD_PATH="$UPD/bin:$SWEETSPOT_PATH" upd cerca | tr '\n' ' ' | sed 's/ $//')"
expect "ricerca: solo https e dimensione massima" "si|si|si" \
	"$(grep -q -- '--proto =https' "$UPD/bin/curl.args" && echo si || echo no)|$(grep -q -- '--proto-redir =https' "$UPD/bin/curl.args" && echo si || echo no)|$(grep -q -- '--max-filesize' "$UPD/bin/curl.args" && echo si || echo no)"
# Scaricamento che si interrompe a meta' (curl scrive una parte e fallisce):
# la copia precedente (v1.3.0 nella copia A) resta intatta e avviabile.
mkdir -p "$UPD/curl-meta"
cat > "$UPD/curl-meta/curl" <<'EOF2'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && printf 'meta' > "$2"; shift; done
exit 18
EOF2
chmod +x "$UPD/curl-meta/curl"
UPD_LIBERO=999999999 UPD_PATH="$UPD/curl-meta:$SWEETSPOT_PATH" upd _lavoro url https://example.com/upd.tar
expect "scaricamento interrotto segnalato" "errore" "$(cut -d'|' -f1 "$UPD/run/aggiornamento/stato")"
expect "scaricamento interrotto: la copia precedente resta" "kernel v1.3.0|rootfs v1.3.0|v1.3.0" \
	"$(cat "$UPD/stick/bzImage")|$(cat "$UPD/stick/rootfs.cpio.zst")|$(cat "$UPD/stick/boot/versioni/a")"
expect "scaricamento interrotto: niente file temporanei" "no|no" \
	"$([ -e "$UPD/stick/aggiornamento.tar.tmp" ] && echo si || echo no)|$([ -e "$UPD/stick/aggiornamento.tmp" ] && echo si || echo no)"
upd altra
expect "scaricamento interrotto: si puo' ancora tornare alla copia precedente" "a" "$(genv prova)"
setenv prova=
# Poco spazio: prima di cancellare la copia precedente si avvisa, e la si
# cancella solo con "libera"; senza copia da cancellare e' un errore.
head -c 1048576 /dev/zero >> "$UPD/stick/rootfs.cpio.zst"
mkpkg v1.4.0 x86_64
UPD_LIBERO=100 upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "poco spazio: avviso prima di cancellare" "spazio" "$(cut -d'|' -f1 "$UPD/run/aggiornamento/stato")"
expect "poco spazio: la copia precedente resta" "kernel v1.3.0|v1.3.0" "$(cat "$UPD/stick/bzImage")|$(cat "$UPD/stick/boot/versioni/a")"
expect "poco spazio: lavoro=spazio nello stato" "lavoro=spazio" "$(upd stato | grep '^lavoro=' | cut -d'|' -f1)"
upd libera
expect "libera: copia precedente cancellata" "no|no|no" \
	"$([ -f "$UPD/stick/bzImage" ] && echo si || echo no)|$([ -f "$UPD/stick/rootfs.cpio.zst" ] && echo si || echo no)|$([ -f "$UPD/stick/boot/versioni/a" ] && echo si || echo no)"
expect "libera: resta la copia in uso" "b|" "$(genv slot)|$(genv prova)"
UPD_LIBERO=1 upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "spazio insufficiente senza copia da cancellare" "errore" "$(cut -d'|' -f1 "$UPD/run/aggiornamento/stato")"
upd _lavoro file "$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar"
expect "dopo libera l'aggiornamento si installa" "pronto|v1.4.0|kernel v1.4.0|a" \
	"$(cat "$UPD/run/aggiornamento/stato")|$(cat "$UPD/stick/bzImage")|$(genv prova)"

echo "Aggiornamenti: niente downgrade senza conferma"
vcmp() { $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-aggiorna; version_cmp \"\$1\" \"\$2\"" sh "$1" "$2"; }
expect "confronto: minore" "-1" "$(SWEETSPOT_TEST=1 vcmp v1.2.9 v1.10.0)"
expect "confronto: maggiore" "1" "$(SWEETSPOT_TEST=1 vcmp v1.10.0 v1.2.9)"
expect "confronto: uguale (anche -dirty)" "0" "$(SWEETSPOT_TEST=1 vcmp v1.2.0-dirty v1.2.0)"
expect "confronto: commit dopo il tag e' piu' recente" "1" "$(SWEETSPOT_TEST=1 vcmp v1.2.0-3-gabc1234 v1.2.0)"
expect "confronto: versione di sviluppo non confrontabile" "?" "$(SWEETSPOT_TEST=1 vcmp sviluppo v1.2.0)"
expect "confronto: quarto componente maggiore" "1" "$(SWEETSPOT_TEST=1 vcmp v1.2.3.4 v1.2.3.1)"
expect "confronto: quarto componente minore" "-1" "$(SWEETSPOT_TEST=1 vcmp v1.2.3.1 v1.2.3.4)"
expect "confronto: quarto componente uguale" "0" "$(SWEETSPOT_TEST=1 vcmp v1.2.3.4 v1.2.3.4)"
expect "confronto: rc non confrontabile" "?" "$(SWEETSPOT_TEST=1 vcmp v1.0.0-rc1 v1.2.0)"
expect "confronto: hash non confrontabile" "?" "$(SWEETSPOT_TEST=1 vcmp 79ba3e4 v1.2.0)"
echo "v3.0.0 (2026-10-01)" > "$UPD/version"
PKG=$UPD/media/USB/sweetspot-x86_64-aggiornamento.tar
mkpkg v2.0.0 x86_64
upd _lavoro file "$PKG"
expect "versione minore: rifiutata" "errore|il pacchetto (v2.0.0) e' piu' vecchio della versione in uso (v3.0.0)" \
	"$(cut -d: -f1 "$UPD/run/aggiornamento/stato")"
expect "versione minore: la copia non e' toccata" "kernel v1.4.0" "$(cat "$UPD/stick/bzImage")"
upd _lavoro file "$PKG" downgrade
expect "versione minore con conferma esplicita: accettata" "pronto|v2.0.0" "$(cat "$UPD/run/aggiornamento/stato")"
mkpkg v3.0.0 x86_64
upd _lavoro file "$PKG"
expect "stessa versione: reinstallazione ammessa" "pronto|v3.0.0" "$(cat "$UPD/run/aggiornamento/stato")"
mkpkg v3.1.0 x86_64
upd _lavoro file "$PKG"
expect "versione maggiore: accettata" "pronto|v3.1.0" "$(cat "$UPD/run/aggiornamento/stato")"
mkpkg v1.0.0-rc1 x86_64
upd _lavoro file "$PKG"
expect "versione rc non confrontabile: rifiutata come downgrade" "errore|il pacchetto (v1.0.0-rc1) e' piu' vecchio della versione in uso (v3.0.0)" \
	"$(cut -d: -f1 "$UPD/run/aggiornamento/stato")"
upd _lavoro file "$PKG" downgrade
expect "versione rc con conferma esplicita: accettata" "pronto|v1.0.0-rc1" "$(cat "$UPD/run/aggiornamento/stato")"
echo "v1.0.0 (2026-10-01)" > "$UPD/version"

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
else
	salta "minisign"
fi

echo "Riavvii del watchdog: al secondo di seguito parte l'altra copia"
# In uso la copia A (predefinita), la B installata.
echo "BOOT_IMAGE=/bzImage sweetspot.slot=a sweetspot.part=ABCD-1234" > "$UPD/proc/cmdline"
setenv slot=a prova= tentato= riavvii= riavvii_copia=
echo "kernel vB" > "$UPD/stick/b/bzImage"; echo "rootfs vB" > "$UPD/stick/b/rootfs.cpio.zst"; echo v9.9.9 > "$UPD/stick/boot/versioni/b"
rm -f "$UPD/run/aggiornamento/watchdog.riavvii" "$UPD/run/aggiornamento/watchdog.ritorno"
upd watchdog
expect "primo riavvio del watchdog: contato, copia invariata" "1|a|a|1|no" \
	"$(genv riavvii)|$(genv riavvii_copia)|$(genv slot)|$(upd stato | sed -n 's/^watchdog_riavvii=//p')|$([ -f "$UPD/run/aggiornamento/watchdog.ritorno" ] && echo si || echo no)"
upd stabile
expect "dieci minuti di funzionamento: conteggio azzerato" "||no" "$(genv riavvii)|$(genv riavvii_copia)|$([ -f "$UPD/run/aggiornamento/watchdog.riavvii" ] && echo si || echo no)"
upd watchdog; upd watchdog
expect "secondo riavvio di seguito: dal prossimo avvio parte la copia B" "b||b|watchdog_ritorno=b" \
	"$(genv slot)|$(genv riavvii)|$(cat "$UPD/run/aggiornamento/watchdog.ritorno")|$(upd stato | grep '^watchdog_ritorno=')"
wdcheck() {
	SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$WEB/proc SWEETSPOT_RUN=$WEB/run SWEETSPOT_LOG=$WEB/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_SQLOG=$WEB/squeezelite.log $TEST_SH "$OVERLAY/usr/bin/sweetspot-check" --dati 2>/dev/null | grep '^[A-Z]*|Riavvii del watchdog|'
}
mkdir -p "$WEB/run/aggiornamento"
cp "$UPD/run/aggiornamento/watchdog.ritorno" "$WEB/run/aggiornamento/"
expect "stato: ritorno all'altra copia segnalato" \
	"ATTENZIONE|Riavvii del watchdog|due di seguito con questa copia: dal prossimo avvio parte la copia b (Sistema > aggiornamenti per cambiare)" "$(wdcheck)"
rm -f "$WEB/run/aggiornamento/watchdog.ritorno"
echo 1 > "$WEB/run/aggiornamento/watchdog.riavvii"
expect "stato: primo riavvio del watchdog segnalato" \
	"ATTENZIONE|Riavvii del watchdog|l'ultimo avvio e' finito con un blocco totale; al secondo di seguito parte l'altra copia" "$(wdcheck)"
rm -f "$WEB/run/aggiornamento/watchdog.riavvii"
expect "stato: senza riavvii del watchdog nessuna voce" "" "$(wdcheck)"
# Riavvii con copie diverse non sono consecutivi; senza l'altra copia non si cambia.
rm -f "$UPD/run/aggiornamento/watchdog.ritorno" "$UPD/run/aggiornamento/watchdog.riavvii"
setenv slot=a riavvii=1 riavvii_copia=b
upd watchdog
expect "riavvio precedente con l'altra copia: si ricomincia da uno" "1|a|a" "$(genv riavvii)|$(genv riavvii_copia)|$(genv slot)"
rm -f "$UPD/stick/b/rootfs.cpio.zst"
upd watchdog
expect "senza l'altra copia installata: conteggio ma nessun cambio" "2|a|no" "$(genv riavvii)|$(genv slot)|$([ -f "$UPD/run/aggiornamento/watchdog.ritorno" ] && echo si || echo no)"
setenv slot=a prova= tentato= riavvii= riavvii_copia=
rm -f "$UPD/run/aggiornamento/watchdog.riavvii" "$UPD/run/aggiornamento/watchdog.ritorno"

# Copia interrotta da un taglio di corrente: file presenti ma senza il marcatore
# boot/versioni/<copia> (scritto per ultimo) non e' valida ne' per "altra" ne' per il watchdog.
echo "Copia a meta': senza marcatore non e' valida"
echo "kernel vB" > "$UPD/stick/b/bzImage"; echo "rootfs vB" > "$UPD/stick/b/rootfs.cpio.zst"; rm -f "$UPD/stick/boot/versioni/b"
setenv slot=a prova= tentato= riavvii=1 riavvii_copia=a
upd watchdog
expect "senza marcatore: il watchdog non passa alla copia B" "a|no" "$(genv slot)|$([ -f "$UPD/run/aggiornamento/watchdog.ritorno" ] && echo si || echo no)"
expect "senza marcatore: 'altra' rifiutata" "non c'e' un'altra versione installata|" "$(upd altra 2>&1)|$(genv prova)"
echo v9.9.9 > "$UPD/stick/boot/versioni/b"
upd altra
expect "con il marcatore: 'altra' ammessa" "b" "$(genv prova)"
setenv slot=a prova= tentato= riavvii= riavvii_copia=
rm -f "$UPD/run/aggiornamento/watchdog.riavvii" "$UPD/run/aggiornamento/watchdog.ritorno"

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
pi "rpi_boot_config $PI/stick/config.txt a"
expect "config.txt dal modello, copia A" "os_prefix=a/|include sweetspot-scheda.txt" \
	"$(grep -E '^(os_prefix|include)' "$PI/stick/config.txt" | tr '\n' '|' | sed 's/|$//')"
# Scrittura sicura dei file critici della FAT: sync prima del mv, sync dopo, nessun .bak.
echo "vecchio" > "$PI/stick/config.txt"
echo "segreto" > "$PI/stick/config.txt.bak"
ordine=$(pi "sync() { printf 'sync '; }; mv() { printf 'mv '; command mv \"\$@\"; }; rpi_boot_config $PI/stick/config.txt b")
expect "fat_sostituisci: sync, mv, sync; contenuto nuovo; .bak vecchio eliminato" "sync mv sync |os_prefix=b/|no" \
	"$ordine|$(grep '^os_prefix' "$PI/stick/config.txt")|$([ -e "$PI/stick/config.txt.bak" ] && echo si || echo no)"
pi "rpi_boot_config $PI/stick/config.txt a"
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
	mkdir -p "$PI/run" "$UPD/musica" "$UPD/lmsdati"
	mkdir -p "$PI/sys/class/net/eth0/device"
	echo 1 > "$PI/sys/class/net/eth0/type"
	echo 1 > "$PI/sys/class/net/eth0/carrier"
	[ -s "$PI/run/sweetspot.conf" ] || echo "MODALITA=completa" > "$PI/run/sweetspot.conf"
	echo "$UPD_SUP" > "$PI/run/supervisore.pid"
	SWEETSPOT_CONFERMA_ATTESA_LMS=2 SWEETSPOT_MUSICA=$UPD/musica SWEETSPOT_LMS_DATA=$UPD/lmsdati \
		SWEETSPOT_IP=$UPD/bin/ip-ok SWEETSPOT_CONFERMA_ATTESA_RETE=2 SWEETSPOT_SYSFS=$PI/sys SWEETSPOT_PROCFS=$PI/proc SWEETSPOT_RUN=$PI/run SWEETSPOT_LOG=$PI/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_STICK_DIR=$PI/stick \
		SWEETSPOT_MEDIA=$PI/media SWEETSPOT_VERSION_FILE=$PI/version SWEETSPOT_AVVIO=$PI/avvio \
		SWEETSPOT_WGET=$UPD/bin/wget-ok SWEETSPOT_CONFERMA_ATTESA=2 SWEETSPOT_RCK=$PI/bin/rcK SWEETSPOT_REBOOT=$PI/bin/reboot \
		SWEETSPOT_CHIAVE_FIRMA=${PI_PUB:-$PI/nessuna-chiave} SWEETSPOT_TEST=cli SWEETSPOT_ALLOW_UNSIGNED=1 \
		SWEETSPOT_PATH="$PI/bin:$UPD/jq:$SWEETSPOT_PATH" $TEST_SH "$OVERLAY/usr/bin/$s" "$@"
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
# Riconciliazione di config.txt e sweetspot-avvio.env (C18): vale config.txt
pi "grubenv_set $PI/stick/sweetspot-avvio.env slot=a prova= tentato="
pi "rpi_boot_config $PI/stick/config.txt b"
pi "rpi_riconcilia"
expect "stato incoerente: avvio.env allineato a config.txt" "b" "$(penv slot)"
pi "grubenv_set $PI/stick/sweetspot-avvio.env slot=b"
pi "rpi_boot_config $PI/stick/config.txt a"
pi "rpi_riconcilia"
expect "stato incoerente al contrario: vale ancora config.txt" "a" "$(penv slot)"
pi "rpi_boot_config $PI/stick/config.txt b"
pi "grubenv_set $PI/stick/sweetspot-avvio.env slot=b"
pi "rpi_riconcilia"
expect "file concordi: nulla cambia" "b|os_prefix=b/" "$(penv slot)|$(grep '^os_prefix' "$PI/stick/config.txt")"
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
else
	salta "minisign"
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
# Chiavetta di avvio: sdc (mai proposta per l'installazione)
mkdir -p "$INS/sys/block/sdc/queue" "$INS/sys/block/sdc/sdc1" "$INS/sys/class/block" "$INS/dev" "$INS/bin" "$INS/chiavetta"
echo 15728640 > "$INS/sys/block/sdc/size"
echo 1 > "$INS/sys/block/sdc/sdc1/partition"
ln -s ../../block/sdc/sdc1 "$INS/sys/class/block/sdc1"
echo "BOOT_IMAGE=/bzImage" > "$INS/proc/cmdline"
: > "$INS/proc/mounts"
printf '#!/bin/sh\n[ "$1" = salva ] && exit "${INS_SALVA_RC:-0}"\nexit 0\n' > "$INS/bin/sweetspot-dati"
printf '#!/bin/sh\nexit 0\n' > "$INS/bin/sweetspot-dischi"
chmod +x "$INS/bin"/*
echo kernel > "$INS/chiavetta/bzImage"
echo sistema > "$INS/chiavetta/rootfs.cpio.zst"
ins() {
	SWEETSPOT_SYSFS=$INS/sys SWEETSPOT_PROCFS=$INS/proc SWEETSPOT_RUN=$INS/run SWEETSPOT_LOG=$INS/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_DEV=$INS/dev SWEETSPOT_AVVIO=$INS/avvio \
		SWEETSPOT_STICK_DEV=${INS_STICK-$INS/dev/sdc1} SWEETSPOT_STICK_DIR=$INS/chiavetta \
		SWEETSPOT_PATH="$INS/bin:$SWEETSPOT_PATH" INS_SALVA_RC=${INS_SALVA_RC:-0} SWEETSPOT_TEST=1 $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-installa; $1"
}
expect "dischi adatti" "sda|465|Samsung SSD 860|interno|partizione sda1 (sconosciuta, 465 GB)|si sdb|7|Disco sdb|USB||no" \
	"$(ins do_disks | tr '\n' ' ' | sed 's/ $//')"
expect "senza chiavetta di avvio nessun disco proposto" "" "$(INS_STICK='' ins do_disks)"
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
else
	salta "sfdisk"
fi
expect "disco non adatto rifiutato" "disco non adatto" "$(ins 'do_start sdz si 465')"
expect "chiavetta di avvio non proponibile" "disco non adatto" "$(ins 'do_start sdc si 7')"
expect "senza chiavetta di avvio non si installa" "chiavetta di avvio non trovata" "$(INS_STICK='' ins 'do_start sda si 465')"
expect "dimensione sbagliata rifiutata" "la dimensione scritta non è quella del disco (465 GB)" "$(ins 'do_start sda si 400')"
expect "dimensione mancante rifiutata" "la dimensione scritta non è quella del disco (465 GB)" "$(ins 'do_start sda si')"
# Lavoro di installazione: ogni controllo ferma tutto prima di scrivere sul disco.
mkdir -p "$INS/sys/block/sdd/queue"
echo 10240 > "$INS/sys/block/sdd/size"
insjob() { # stato finale e primi byte del disco (intatto: aaaa)
	rm -rf "$INS/run/installa"
	head -c 5242880 /dev/zero | tr '\0' '\252' > "$INS/dev/sdd"
	ins "install_job $1 no" > /dev/null 2>&1
	printf '%s|%s' "$(cut -d'|' -f4 "$INS/run/installa/stato")" "$(od -An -tx1 -N2 "$INS/dev/sdd" | tr -d ' ')"
}
expect "chiavetta sparita: installazione fermata, disco intatto" "chiavetta di avvio non trovata: niente è stato cancellato|aaaa" \
	"$(INS_STICK='' insjob sdd)"
mkdir -p "$INS/sys/block/sdd/sdd1" && echo 1 > "$INS/sys/block/sdd/sdd1/partition"
ln -sf ../../block/sdd/sdd1 "$INS/sys/class/block/sdd1"
expect "disco scelto uguale alla chiavetta: fermata" "il disco scelto è la chiavetta di avvio|aaaa" \
	"$(INS_STICK=$INS/dev/sdd1 insjob sdd)"
rm -rf "$INS/sys/block/sdd/sdd1" "$INS/sys/class/block/sdd1"
expect "salvataggio fallito: installazione fermata, disco intatto" "salvataggio della libreria non riuscito: niente è stato cancellato|aaaa" \
	"$(INS_SALVA_RC=1 insjob sdd)"
expect "spazio insufficiente: fermata prima della tabella" "spazio insufficiente per il sistema e la libreria: niente è stato cancellato|aaaa" \
	"$(insjob sdd)"

echo "Installazione accanto al sistema esistente (GPT, UEFI)"
expect "accanto: senza UEFI nessun disco proposto" "" "$(ins do_side_disks)"
expect "accanto: senza UEFI non si installa" "serve l'avvio UEFI: avvia la chiavetta in modalità UEFI" "$(ins 'do_side sda 465')"
mkdir -p "$INS/sys/firmware/efi/efivars"
printf '#!/bin/sh\necho "$*" > %s/efibootmgr.args\nexit "${INS_EFI_RC:-0}"\n' "$INS" > "$INS/bin/efibootmgr"
chmod +x "$INS/bin/efibootmgr"
expect "accanto: un disco MBR non e' proposto" "" "$(ins do_side_disks)"
expect "accanto: disco MBR rifiutato" "disco non adatto" "$(ins 'do_side sda 465')"
printf 'efivarfs /sys/firmware/efi/efivars efivarfs rw 0 0\n' > "$INS/proc/mounts"
expect "accanto: voce UEFI per il caricatore a 64 bit" "-q -c -d $INS/dev/nvme0n1 -p 4 -L Sweetspot -l \EFI\BOOT\BOOTX64.EFI" \
	"$(ins 'efi_entry nvme0n1 4' && cat "$INS/efibootmgr.args")"
echo 32 > "$INS/sys/firmware/efi/fw_platform_size"
expect "accanto: firmware UEFI a 32 bit" "-q -c -d $INS/dev/nvme0n1 -p 4 -L Sweetspot -l \EFI\BOOT\BOOTIA32.EFI" \
	"$(ins 'efi_entry nvme0n1 4' && cat "$INS/efibootmgr.args")"
rm -f "$INS/sys/firmware/efi/fw_platform_size"
expect "accanto: voce UEFI non creata" "1" "$(INS_EFI_RC=1 ins 'efi_entry nvme0n1 4'; echo $?)"
: > "$INS/proc/mounts"
if command -v sgdisk > /dev/null; then
	# SSD con Windows: partizione EFI, MSR, Windows da 2 GB e il resto libero.
	gptdisk() { # nome GiB [ultima partizione piena]
		mkdir -p "$INS/sys/block/$1/queue"
		echo $(($2 * 2097152)) > "$INS/sys/block/$1/size"
		echo 512 > "$INS/sys/block/$1/queue/logical_block_size"
		rm -f "$INS/dev/$1"
		truncate -s "$2G" "$INS/dev/$1"
		sgdisk -n 1:2048:+260M -t 1:EF00 -n 2:0:+16M -t 2:0C01 -n "3:0:${3:-+2G}" -t 3:0700 -c 3:Windows "$INS/dev/$1" > /dev/null
	}
	gptsum() { od -An -tx1 -N 17408 "$INS/dev/$1" | md5sum | cut -c1-32; }
	gptdisk nvme0n1 8
	gptdisk sde 6 0
	expect "accanto: solo il disco GPT con spazio libero" "nvme0n1|8|Disco nvme0n1|NVMe||5" "$(ins do_side_disks)"
	expect "accanto: blocco libero piu' grande" "4761600 16777182" "$(ins "gpt_free $INS/dev/nvme0n1")"
	expect "accanto: primo numero libero" "4" "$(ins "gpt_slot $INS/dev/nvme0n1")"
	expect "accanto: disco senza spazio libero rifiutato" "disco non adatto" "$(ins 'do_side sde 6')"
	expect "accanto: dimensione sbagliata rifiutata" "la dimensione scritta non è quella del disco (8 GB)" "$(ins 'do_side nvme0n1 465')"
	expect "accanto: chiavetta di avvio rifiutata" "disco non adatto" "$(ins 'do_side sdc 7')"
	sidejob() { # disco [comandi prima] -> messaggio finale|tabella intatta (si/no)
		local before
		before=$(gptsum "$1")
		rm -rf "$INS/run/installa"
		ins "${2:-:}; side_job $1" > /dev/null 2>&1
		printf '%s|%s' "$(cut -d'|' -f4 "$INS/run/installa/stato")" "$([ "$(gptsum "$1")" = "$before" ] && echo si || echo no)"
	}
	expect "accanto: chiavetta sparita, niente cambiato" "chiavetta di avvio non trovata: niente è stato cambiato|si" "$(INS_STICK='' sidejob nvme0n1)"
	expect "accanto: disco pieno, niente cambiato" "spazio libero insufficiente (servono 4 GB): niente è stato cambiato|si" "$(sidejob sde)"
	expect "accanto: disco MBR, niente cambiato" "il disco non ha una tabella GPT integra: niente è stato cambiato|si" "$(sidejob sdd)"
	expect "accanto: salvataggio fallito, niente cambiato" "salvataggio della libreria non riuscito: niente è stato cambiato|si" \
		"$(INS_SALVA_RC=1 sidejob nvme0n1)"
	# La partizione nuova non compare: la tabella torna quella di prima.
	expect "accanto: errore dopo la tabella, tabella ripristinata" \
		"il disco non mostra la nuova partizione: la tabella delle partizioni è tornata com'era|si" \
		"$(sidejob nvme0n1 'wait_dev() { return 1; }')"
	expect "accanto: copia della tabella conservata" "si" "$([ -s "$INS/run/installa/gpt-nvme0n1.bak" ] && echo si || echo no)"
	# La partizione che si aggiungerebbe: 4 GiB nello spazio libero, tipo dati di base.
	ins "sgdisk -n 4:4761600:$((4761600 + 8388608 - 1)) -t 4:\$SIDE_TYPE -c 4:\$SIDE_NAME $INS/dev/nvme0n1" > /dev/null
	expect "accanto: tabella risultante integra" "si" "$(ins "gpt_ok $INS/dev/nvme0n1" && echo si || echo no)"
	expect "accanto: nuova partizione" "4 4761600 13150207 Sweetspot" \
		"$(sgdisk -p "$INS/dev/nvme0n1" | awk '$1 == 4 { print $1, $2, $3, $7 }')"
	rm -f "$INS/dev/nvme0n1" "$INS/dev/sde"
	rm -rf "$INS/sys/block/nvme0n1" "$INS/sys/block/sde"
else
	echo "  (sgdisk non presente: prove con tabelle GPT saltate)"
fi
rm -rf "$INS/sys/firmware"

echo "Archivio nello spazio libero del disco di avvio"
SP=$WORK/spazio
SPD=$SP/sys/devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0
mkdir -p "$SPD/queue" "$SPD/mmcblk0p1" "$SP/sys/class/block" "$SP/sys/block" "$SP/dev" "$SP/run" "$SP/proc" "$SP/bin" "$SP/chiavetta"
echo "console=tty1 sweetspot.slot=a" > "$SP/proc/cmdline"
echo 512 > "$SPD/queue/logical_block_size"
ln -s ../devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0 "$SP/sys/block/mmcblk0"
ln -s ../../devices/platform/emmc2/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0/mmcblk0p1 "$SP/sys/class/block/mmcblk0p1"
sp() { # comando (funzioni di sweetspot-spazio)
	SWEETSPOT_SYSFS=$SP/sys SWEETSPOT_PROCFS=$SP/proc SWEETSPOT_RUN=$SP/run SWEETSPOT_LOG=$SP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_DEV=$SP/dev \
		SWEETSPOT_STICK_DEV=$SP/dev/mmcblk0p1 SWEETSPOT_STICK_DIR=$SP/chiavetta SWEETSPOT_TEST=1 SWEETSPOT_PATH="$SP/bin:$SWEETSPOT_PATH" \
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
printf '#!/bin/sh\necho "$*" > %s/partizione.args\n: > %s/dev/mmcblk0p2\nmkdir -p %s/sys/class/block/mmcblk0p2\necho $3 > %s/sys/class/block/mmcblk0p2/start\necho $4 > %s/sys/class/block/mmcblk0p2/size\n' "$SP" "$SP" "$SP" "$SP" "$SP" > "$SP/bin/sweetspot-partizione"
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
else
	salta "sfdisk"
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
	SWEETSPOT_MOUNT=${CC_MOUNT:-false} SWEETSPOT_LMS_DATA=$CC/lms SWEETSPOT_RUN=$CC/run SWEETSPOT_LOG=$CC/log SWEETSPOT_PATH="$CC/bin:$SWEETSPOT_PATH" \
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
# Tmpfs a parte con size= per le cache in RAM (mount finto che registra le opzioni).
printf '#!/bin/sh\necho "$@" > "%s/mount.args"\n' "$CC" > "$CC/bin/finto-mount"
chmod +x "$CC/bin/finto-mount"
rm -f "$CC/lms/cache/artwork.db" "$CC/lms/cache/imgproxy.db"
mkdir -p "$CC/proc"
printf 'MemTotal:        8388608 kB\n' > "$CC/proc/meminfo"
CC_MOUNT=$CC/bin/finto-mount SWEETSPOT_PROCFS=$CC/proc lmsfn link_caches
expect "senza archivio: tmpfs delle copertine con size= (4% di 8 GB, tetto 256 MB)" "-t tmpfs -o size=256m,mode=0755,nosuid,nodev tmpfs $CC/lms/artwork-ram" "$(cat "$CC/mount.args")"
expect "senza archivio: cache collegate al tmpfs a tetto" "$CC/lms/artwork-ram/artwork.db" "$(readlink "$CC/lms/cache/artwork.db")"
printf 'MemTotal: 262144 kB\n' > "$CC/proc/meminfo"
art_small=$(SWEETSPOT_PROCFS=$CC/proc lmsfn art_ram_mb)
printf 'MemTotal: 33554432 kB\n' > "$CC/proc/meminfo"
expect "tetto dell'artwork: minimo 32 MB, mai oltre 256" "32|256" "$art_small|$(SWEETSPOT_PROCFS=$CC/proc lmsfn art_ram_mb)"
# Cache delle copertine selezionabile: ram / archivio / disco, migrazione, tetto, ripiego.
printf '#!/bin/sh\n[ "$1" = archivio ] && echo "%s"\n' "$CC/archivio" > "$CC/bin/sweetspot-dischi"
mkdir -p "$CC/media/SSD"
cc_stato() { cut -d'|' -f1,5 "$CC/run/lms.artwork.stato"; }
rm -f "$CC/lms/cache/artwork.db" "$CC/lms/cache/imgproxy.db" "$CC/archivio/.sweetspot-cache"/*
echo dati-ssd > "$CC/lms/cache/artwork.db"
printf 'CACHE_COPERTINE=disco\nCACHE_COPERTINE_DISCO=SSD\n' > "$CC/run/sweetspot.conf"
SWEETSPOT_MEDIA=$CC/media lmsfn link_caches
expect "cache su un altro disco: collegamento verso l'SSD" "$CC/media/SSD/.sweetspot-cache/artwork.db" "$(readlink "$CC/lms/cache/artwork.db")"
expect "migrazione dalla RAM all'SSD: contenuto conservato, stato su disco" "dati-ssd|disco|" "$(cat "$CC/media/SSD/.sweetspot-cache/artwork.db")|$(cc_stato)"
expect "diagnostica: posizione, tetto e usati" "posizione=disco cartella=$CC/media/SSD/.sweetspot-cache tetto_mb=1024 usati_mb=0" "$(SWEETSPOT_MEDIA=$CC/media lmsfn do_artwork)"
# Cambio di posizione dall'SSD all'archivio.
printf 'CACHE_COPERTINE=archivio\n' > "$CC/run/sweetspot.conf"
SWEETSPOT_MEDIA=$CC/media lmsfn link_caches
expect "migrazione SSD -> archivio" "dati-ssd|$CC/archivio/.sweetspot-cache/artwork.db|no" \
	"$(cat "$CC/archivio/.sweetspot-cache/artwork.db")|$(readlink "$CC/lms/cache/artwork.db")|$([ -e "$CC/media/SSD/.sweetspot-cache/artwork.db" ] && echo si || echo no)"
# Disco che manca: ripiego in RAM dichiarato.
printf 'CACHE_COPERTINE=disco\nCACHE_COPERTINE_DISCO=Assente\n' > "$CC/run/sweetspot.conf"
CC_MOUNT=$CC/bin/finto-mount SWEETSPOT_PROCFS=$CC/proc SWEETSPOT_MEDIA=$CC/media lmsfn link_caches
expect "disco assente: ripiego in RAM dichiarato" "ram|disco \"Assente\" non collegato" "$(cc_stato)"
expect "ripiego: cache nel tmpfs a tetto" "$CC/lms/artwork-ram/artwork.db" "$(readlink "$CC/lms/cache/artwork.db")"
expect "ripiego: la cache dell'archivio e' passata in RAM" "dati-ssd" "$(cat "$CC/lms/artwork-ram/artwork.db")"
# Scelta esplicita della RAM, anche con l'archivio presente.
printf 'CACHE_COPERTINE=ram\n' > "$CC/run/sweetspot.conf"
CC_MOUNT=$CC/bin/finto-mount SWEETSPOT_PROCFS=$CC/proc lmsfn link_caches
expect "CACHE_COPERTINE=ram con archivio: resta in RAM, tetto visibile" "ram|scelta dell'utente|256" "$(cc_stato)|$(cut -d'|' -f3 "$CC/run/lms.artwork.stato")"
# Tetto sul disco: una cache oltre il tetto non si migra (si ricostruisce).
printf 'CACHE_COPERTINE=archivio\nCACHE_COPERTINE_MB=1\n' > "$CC/run/sweetspot.conf"
head -c 2097152 /dev/zero > "$CC/lms/artwork-ram/artwork.db"
CC_MOUNT=$CC/bin/finto-mount SWEETSPOT_PROCFS=$CC/proc lmsfn link_caches
expect "cache oltre il tetto: non migrata" "no" "$([ -s "$CC/archivio/.sweetspot-cache/artwork.db" ] && echo si || echo no)"
# Disco non scrivibile (nome con barra rifiutato).
printf 'CACHE_COPERTINE=disco\nCACHE_COPERTINE_DISCO=../x\n' > "$CC/run/sweetspot.conf"
CC_MOUNT=$CC/bin/finto-mount SWEETSPOT_PROCFS=$CC/proc lmsfn link_caches
expect "nome del disco con percorso: rifiutato, ripiego" "ram|disco per le copertine non indicato" "$(cc_stato)"
# Fault injection: la copia verso il nuovo disco fallisce (cp finto), le cache
# e il WAL devono restare dove stanno, con lo stato che lo dichiara.
rm -f "$CC/run/sweetspot.conf" "$CC/lms/cache"/* "$CC/archivio/.sweetspot-cache"/*
echo prezioso > "$CC/lms/cache/artwork.db"; echo wal-prezioso > "$CC/lms/cache/artwork.db-wal"
lmsfn 'cp() { return 1; }; link_caches'
expect "copia fallita: cache e WAL restano dove sono" "prezioso|wal-prezioso|no" \
	"$(cat "$CC/lms/cache/artwork.db")|$(cat "$CC/lms/cache/artwork.db-wal")|$([ -L "$CC/lms/cache/artwork.db" ] && echo si || echo no)"
expect "copia fallita: nessun file provvisorio in destinazione" "0" "$(ls -A "$CC/archivio/.sweetspot-cache" | grep -c artwork)"
case "$(cc_stato)" in *"migrazione non riuscita"*) ok "copia fallita: lo stato lo dichiara" ;; *) ko "stato dopo migrazione fallita" "migrazione non riuscita" "$(cc_stato)" ;; esac
lmsfn link_caches
expect "dopo il guasto la migrazione riesce, WAL compreso" "prezioso|wal-prezioso|si" \
	"$(cat "$CC/archivio/.sweetspot-cache/artwork.db")|$(cat "$CC/archivio/.sweetspot-cache/artwork.db-wal")|$([ -L "$CC/lms/cache/artwork.db" ] && echo si || echo no)"
rm -f "$CC/run/sweetspot.conf"
rm -f "$CC/run/sweetspot.conf"
# Il tetto della cache in RAM rientra nella quota servizi del budget RAM unificato.
mkdir -p "$CC/q/run" "$CC/q/proc"
printf 'MemTotal: 8388608 kB\nMemAvailable: 4194304 kB\n' > "$CC/q/proc/meminfo"
q0=$(run "$CC/q" "ram_quote" | awk '$1 == "servizi" {print $2}')
echo 'ram|/x|100|5|' > "$CC/q/run/lms.artwork.stato"
q1=$(run "$CC/q" "ram_quote" | awk '$1 == "servizi" {print $2}')
expect "budget RAM: i 100 MB di cache copertine in RAM contano nei servizi" "102400" "$((q1 - q0))"
echo 'disco|/x|100|5|' > "$CC/q/run/lms.artwork.stato"
expect "budget RAM: cache su disco, nessun costo" "$q0" "$(run "$CC/q" "ram_quote" | awk '$1 == "servizi" {print $2}')"
# Tetti di memoria cgroup di Lyrion e dello scanner (cgroup finto nei file).
CGT=$CC/cgroup
mkdir -p "$CGT"
echo "cpu io memory" > "$CGT/cgroup.controllers"
: > "$CGT/cgroup.subtree_control"
printf 'MemTotal:        8388608 kB\n' > "$CC/proc/meminfo"
SWEETSPOT_CGROUP=$CGT SWEETSPOT_PROCFS=$CC/proc lmsfn lms_cgroups
expect "cgroup di Lyrion: memory.max 70% della RAM, high all'85%" "6012954150|5111010985" \
	"$(cat "$CGT/sweetspot-lyrion/memory.max")|$(cat "$CGT/sweetspot-lyrion/memory.high")"
expect "cgroup dello scanner: memory.max 40% della RAM" "3435973800" "$(cat "$CGT/sweetspot-scanner/memory.max")"
echo "LYRION_MEM_MB=1000" > "$CC/run/sweetspot.conf"
SWEETSPOT_CGROUP=$CGT SWEETSPOT_PROCFS=$CC/proc lmsfn lms_cgroups
expect "LYRION_MEM_MB indicato in MB" "1048576000" "$(cat "$CGT/sweetspot-lyrion/memory.max")"
rm -f "$CC/run/sweetspot.conf"

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
# Budget unico (common.sh): sistema 256 MB, servizi 768 MB (Lyrion locale), ALSA
# 16 MB, buffer del player 192 MB; il resto e' del precarico, sempre con la
# riserva per il sistema anche in auto.
expect "budget automatico: la quota di precarico, con la riserva del sistema" "2932736" "$(prefn preload_budget_kb)"
mkdir -p "$PRE/proc/4321"
printf 'VmRSS:\t 1048576 kB\n' > "$PRE/proc/4321/status"
echo 4321 > "$PRE/run/squeezelite.pid"
expect "buffer del player gia' occupati: contano nel capitale, non due volte" "3129344" "$(prefn preload_budget_kb)"
rm -f "$PRE/run/squeezelite.pid"
echo PRECARICO_MB=100 > "$PRE/run/sweetspot.conf"
expect "budget indicato in MB" "102400" "$(prefn preload_budget_kb)"
echo PRECARICO_MB=99999 > "$PRE/run/sweetspot.conf"
expect "budget mai oltre la quota (riserva di sistema compresa)" "2932736" "$(prefn preload_budget_kb)"
printf 'PRECARICO_FILE_MAX_MB=1 2\n' > "$PRE/run/sweetspot.conf"
expect "limite dei file non numerico: predefinito, senza errori" "1048576" "$(prefn file_max_kb 2>&1)"
rm -f "$PRE/run/sweetspot.conf"
# 300 MiB disponibili: prima il ramo auto ne bloccava 150 senza riserva.
printf 'MemTotal:        8388608 kB\nMemAvailable:     307200 kB\n' > "$PRE/proc/meminfo"
expect "300 MiB disponibili: niente precarico, la riserva resta al sistema" "0" "$(prefn preload_budget_kb)"
printf 'MODALITA=player\n' > "$PRE/run/sweetspot.conf"
printf 'MemTotal:        8388608 kB\nMemAvailable:    1048576 kB\n' > "$PRE/proc/meminfo"
expect "1 GiB disponibili, solo player: dopo il precarico restano almeno 256 MB" "si" \
	"$(prefn 'ram_quote_calc; [ $((RAM_AVAIL - RAM_PRECARICO - RAM_STREAM - RAM_OUTPUT)) -ge 262144 ] && echo si || echo no')"
rm -f "$PRE/run/sweetspot.conf"
printf 'MemTotal:        8388608 kB\nMemAvailable:    4194304 kB\n' > "$PRE/proc/meminfo"
sleep 30 &
echo $! > "$PRE/run/precarico.tieni.pid"
printf 'SI 1000 /musica/a.flac\nSTREAM http://radio.example/stream\n' > "$PRE/run/precarico.piano"
printf 'stato\tpronto\nfile\t1024000\tok\t/musica/a.flac\n' > "$PRE/run/precarico.stato"
expect "budget stabile: la memoria gia' bloccata conta come libera" "2933736" "$(prefn preload_budget_kb)"
kill "$(cat "$PRE/run/precarico.tieni.pid")"
rm -f "$PRE/run/precarico.tieni.pid" "$PRE/run/precarico.piano" "$PRE/run/precarico.stato"
# Pressione di memoria (PSI) e rilascio progressivo dei brani piu' lontani.
mkdir -p "$PRE/proc/pressure"
printf 'some avg10=25.00 avg60=3.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$PRE/proc/pressure/memory"
expect "PSI 25%: pressione alta" "si" "$(prefn 'psi_alta && echo si || echo no')"
printf 'some avg10=2.00 avg60=3.00 avg300=1.00 total=1\n' > "$PRE/proc/pressure/memory"
expect "PSI 2%: pressione normale" "no" "$(prefn 'psi_alta && echo si || echo no')"
rm -f "$PRE/proc/pressure/memory"
expect "senza /proc/pressure/memory: nessuna pressione" "no" "$(prefn 'psi_alta && echo si || echo no')"
sh -c 'trap : USR1; while :; do sleep 1; done' &
echo $! > "$PRE/run/precarico.tieni.pid"
printf 'SI 1000 %s\nSI 2000 %s\nSTREAM http://radio.example/stream\n' "$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.piano"
printf 'stato\tpronto\nfile\t1024000\tok\t%s\nfile\t2048000\tok\t%s\n' \
	"$PRE/musica/Album è/a.flac" "$PRE/musica/Album è/b c.flac" > "$PRE/run/precarico.stato"
expect "memoria sufficiente: nessun rilascio" "1" "$(prefn 'shed_farthest; echo $?')"
printf 'MemTotal:        8388608 kB\nMemAvailable:    1100000 kB\n' > "$PRE/proc/meminfo"
prefn shed_farthest
expect "memoria sotto la riserva: via il brano piu' lontano, il piu' vicino resta" \
	"SI 1000 $PRE/musica/Album è/a.flac|OLTRE 2000 $PRE/musica/Album è/b c.flac|STREAM http://radio.example/stream|$PRE/musica/Album è/a.flac" \
	"$(tr '\n' '|' < "$PRE/run/precarico.piano")$(cat "$PRE/run/precarico.elenco")"
prefn shed_farthest
expect "ancora sotto la riserva: rilascia anche l'ultimo, poi non c'e' altro" "OLTRE 1000|1" \
	"$(sed -n 1p "$PRE/run/precarico.piano" | cut -d' ' -f1,2)|$(prefn 'shed_farthest; echo $?')"
kill "$(cat "$PRE/run/precarico.tieni.pid")" 2>/dev/null
rm -f "$PRE/run/precarico.tieni.pid" "$PRE/run/precarico.piano" "$PRE/run/precarico.elenco" "$PRE/run/precarico.stato"
printf 'MemTotal:        8388608 kB\nMemAvailable:    4194304 kB\n' > "$PRE/proc/meminfo"
# Brani CUE (URL#inizio-fine): il file e' quello intero, caricato una volta sola.
expect "URL di un brano CUE: il frammento si scarta" "$PRE/musica/Album è/a.flac" "$(prefn "url_path '$U/a.flac#12.5-100.25'")"
expect "nome con # (%23): resta nel percorso" "$PRE/musica/Album è/x#y.flac" "$(prefn "url_path '$U/x%23y.flac#1-2'")"
printf '%s\n' "$U/a.flac#0-60" "$U/a.flac#60-120" "$U/d.flac" "$U/a.flac#120-180" > "$PRE/coda-cue"
expect "piano: i brani dello stesso file CUE contano una volta" \
	"SI 3 $PRE/musica/Album è/a.flac|SI 1 $PRE/musica/Album è/d.flac" \
	"$(prefn "preload_plan 100 100 < '$PRE/coda-cue'" | tr '\n' '|' | sed 's/|$//')"
# Coda oltre 1000 brani: letta a pagine da 500, dal brano in corso alla fine.
echo AA:BB > "$PRE/run/player.mac"
cat > "$PRE/fake-lms.sh" <<'FAKE'
lms_json() {
	awk -v start="$3" -v count="$4" -v tot=1200 'BEGIN {
		if (count == 1) { printf "{\"result\":{\"mode\":\"play\",\"playlist_cur_index\":\"3\",\"playlist_tracks\":%d}}\n", tot; exit }
		printf "{\"result\":{\"mode\":\"play\",\"playlist_loop\":["
		for (i = start; i < start + count && i < tot; i++) printf "%s{\"url\":\"file:///m/t%d.flac\"}", (i > start ? "," : ""), i
		print "]}}" }'
}
FAKE
prefn ". '$PRE/fake-lms.sh'; queue_urls" > "$PRE/coda-lunga"
expect "coda di 1200 brani: tutti dal brano in corso (3) alla fine" "1197|file:///m/t3.flac|file:///m/t1199.flac" \
	"$(wc -l < "$PRE/coda-lunga" | tr -d ' ')|$(head -n 1 "$PRE/coda-lunga")|$(tail -n 1 "$PRE/coda-lunga")"
rm -f "$PRE/run/player.mac"
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
	salta "jq"
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
# Per ruolo: riproduzione 70 (PRIORITA_DSP), elaborazione 69, cattura 68.
expect "thread audio: in real-time per ruolo sul core audio, solo chi non lo e' gia'" \
	"-f -p 69 4243|-f -p 68 4244|-f -p 70 4245|-p -c 3 4245" \
	"$(grep -- '424[345]' "$DSP/run/chrt.call" | tr '\n' '|' | sed 's/|$//')|$(grep -- '424[345]' "$DSP/run/taskset.call" | tr '\n' '|' | sed 's/|$//')"
expect "thread non audio: sui core di sistema con la priorita' normale, solo chi non lo e' gia'" \
	"-o -p 0 4242|-p -c 0,1 4242" \
	"$(grep -- '424[26]' "$DSP/run/chrt.call" | tr '\n' '|' | sed 's/|$//')|$(grep -- '424[26]' "$DSP/run/taskset.call" | tr '\n' '|' | sed 's/|$//')"
rm -f "$DSP/run/chrt.call" "$DSP/run/taskset.call"
expect "priorita' per ruolo: riproduzione >= elaborazione >= cattura" "70 69 68|70 70" \
	"$(dspfn 1 'echo "$(dsp_thread_priority AlsaPlayback 1) $(dsp_thread_priority Processing 1) $(dsp_thread_priority FileCapture 1)"')|$(dspfn 1 'echo "$(dsp_thread_priority AlsaPlaybackInner 1) $(dsp_thread_priority Processing 0)"')"
echo PRIORITA_DSP=2 > "$DSP/run/sweetspot.conf"
expect "priorita' per ruolo: mai sotto 1" "2 1 1" "$(dspfn 1 'echo "$(dsp_thread_priority AlsaPlayback 1) $(dsp_thread_priority Processing 1) $(dsp_thread_priority FileCapture 1)"')"
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
expect "verifica: CamillaDSP assente, lo riavvia il player" \
	"INFO|CamillaDSP in real-time|non in esecuzione: il player la riavvia" "$(DSP_PID= dspcheck)"

echo "CamillaDSP: una sola istanza per sessione"
mkdir -p "$DSP/bin-sessione"
printf '#!/bin/sh\nexec sleep 30\n' > "$DSP/camilladsp-finto"
printf '#!/bin/sh\necho "-l warn"\n' > "$DSP/bin-sessione/sweetspot-dsp"
printf '#!/bin/sh\nexit 0\n' > "$DSP/bin-sessione/sweetspot-camilla"
chmod +x "$DSP/camilladsp-finto" "$DSP/bin-sessione/sweetspot-dsp" "$DSP/bin-sessione/sweetspot-camilla"
cat > "$DSP/sessione.sh" <<'SESSIONE'
# Funzioni al posto dei comandi (BusyBox preferisce le sue applet).
taskset() { shift 2; "$@"; }
PATH=$DSP_T/bin-sessione:$PATH
DSP_FIFO=$DSP_T/run/dsp.fifo
CAMILLADSP=$DSP_T/camilladsp-finto
HK=0
start_dsp || echo avvio-fallito
a=$DSPPROC
[ -p "$DSP_FIFO" ] && echo fifo
dsp_alive && echo vivo
b=$a
# Un cambio di frequenza non passa di qui: l'istanza resta la stessa finche'
# il supervisore non la ferma o non muore.
# correzione.attiva esiste gia' (creato dai test di pin_dsp) e deve restare.
touch "$RUN/correzione.attiva"
dsp_session_check
[ "$DSPPROC" = "$a" ] && echo stesso-pid
# Morte improvvisa: il supervisore la riavvia.
kill "$a"; wait "$a" 2>/dev/null
DSP_RIPROVA=0
dsp_session_check
dsp_alive && echo riavviato
[ "$DSPPROC" != "$a" ] && echo pid-nuovo
b=$DSPPROC
stop_dsp
[ -e "$DSP_FIFO" ] || echo fifo-rimossa
kill -0 "$b" 2>/dev/null || echo fermo
SESSIONE
export DSP_T=$DSP
expect "sessione: avvio unico dal supervisore, riavvio solo se muore, arresto pulito" \
	"fifo|vivo|stesso-pid|riavviato|pid-nuovo|fifo-rimossa|fermo" \
	"$(dspfn 1 ". $DSP/sessione.sh" 2>&1 | tr '\n' '|' | sed 's/|$//')"
rm -f "$DSP/run/dsp.fifo"
echo "Supervisore: Squeezelite bloccato sulla FIFO di CamillaDSP fermo"
# CamillaDSP in SIGSTOP non legge piu': la FIFO si riempie e la scrittura
# resta bloccata; il Squeezelite finto ignora SIGTERM come quello appeso.
cat > "$DSP/blocco.sh" <<'BLOCCO'
rm -f "$DSP_T/run/blocco.fifo"
mkfifo "$DSP_T/run/blocco.fifo"
sh -c 'exec cat > /dev/null' <> "$DSP_T/run/blocco.fifo" &
lettore=$!
kill -STOP "$lettore"
sh -c 'trap "" TERM; exec cat /dev/zero > "$0"' "$DSP_T/run/blocco.fifo" &
PID=$!
sleep 1
kill -0 "$PID" 2>/dev/null && echo bloccato
PLAYER_ATTESA=2
t0=$(date +%s)
stop_player "$PID"
[ $(( $(date +%s) - t0 )) -le 4 ] && echo entro-il-limite
kill -0 "$PID" 2>/dev/null || echo fermo
kill -9 "$lettore" 2>/dev/null; wait "$lettore" 2>/dev/null
rm -f "$DSP_T/run/blocco.fifo"
BLOCCO
expect "supervisore: lo stop del player non resta appeso al wait (kill -9 dopo PLAYER_ATTESA)" \
	"bloccato|entro-il-limite|fermo" \
	"$(dspfn 1 ". $DSP/blocco.sh" 2>&1 | tr '\n' '|' | sed 's/|$//')"
expect "supervisore: nessun wait senza limite su Squeezelite" "0|1" \
	"$(grep -c 'wait "\$PID"' "$OVERLAY/usr/bin/sweetspot-player")|$(grep -c 'stop_player "\$PID"' "$OVERLAY/usr/bin/sweetspot-player")"
expect "CamillaDSP non e' piu' avviato dal plugin con un fork dal thread real-time" "1|1" \
	"$(grep -c '^start_dsp()' "$OVERLAY/usr/bin/sweetspot-player")|$(grep -c 'taskset -c "\$HK" "\$CAMILLADSP"' "$OVERLAY/usr/bin/sweetspot-player")"
expect "init: ferma anche l'istanza di CamillaDSP" "1" "$(grep -c 'killall camilladsp' "$OVERLAY/etc/init.d/S60sweetspot-player")"

echo "Misura della latenza in ascolto sotto il player"
LATFN=$(sed -n '/^listen_priority()/,/^}/p' "$OVERLAY/usr/bin/sweetspot-latenza")
latprio() { $TEST_SH -c "conf() { echo '$1'; }; $LATFN; listen_priority"; }
expect "cyclictest in ascolto: un gradino sotto il player (80 -> 79)" "79" "$(latprio 80)"
expect "cyclictest in ascolto: segue PRIORITA_AUDIO, mai sotto 2" "89|2" "$(latprio 90)|$(latprio 1)"
expect "cyclictest in ascolto: valore non numerico, 79" "79" "$(latprio alta)"
expect "cyclictest in ascolto: sopra CamillaDSP (70) e sotto il player (80)" "1" "$([ "$(latprio 80)" -gt 70 ] && [ "$(latprio 80)" -lt 80 ] && echo 1 || echo 0)"
expect "cyclictest in ascolto non e' piu' a 85" "0" "$(grep -c -e '-p 85 -i 10000' "$OVERLAY/usr/bin/sweetspot-latenza")"

echo "CamillaDSP di sessione: analisi dell'audio registrato nella prova ALSA"
if command -v python3 > /dev/null; then
	cat > "$WORK/analisi.py" <<'PY'
import importlib.util, sys, tempfile, wave, os
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)
d = tempfile.mkdtemp()
res = []
for rate in (44100, 96000):
    f = os.path.join(d, "t.wav")
    cs.tono(f, rate)
    with wave.open(f) as w:
        raw = w.readframes(rate * 3)
    # Silenzio iniziale (blocco dopo il cambio di configurazione) + tono: valido.
    res.append(cs.analizza(b"\0" * 8 * 5000 + raw, rate)["status"])
    # Stesso audio letto a un'altra frequenza (cambio non avvenuto): rifiutato.
    res.append(cs.analizza(raw, 96000 if rate == 44100 else 44100)["status"])
    # Buco nell'audio: rifiutato.
    buco = bytearray(raw)
    buco[8 * rate:8 * rate + 1600] = b"\0" * 1600
    res.append(cs.analizza(bytes(buco), rate)["status"])
# Nessun segnale: rifiutato.
res.append(cs.analizza(b"\0" * 8 * 44100, 44100)["status"])
print("|".join(res))
PY
	expect "prova ALSA CamillaDSP: tono corretto accettato, frequenza sbagliata, buchi e silenzio rifiutati" \
		"pass|fail|fail|pass|fail|fail|fail" "$(python3 "$WORK/analisi.py" "$ROOT/tests/camilladsp-sessione.py")"
else
	salta "python3"
fi
expect "la prova ALSA in QEMU include il caso CamillaDSP di sessione (stesso PID, 44,1 -> 96 kHz)" "1|1" \
	"$(grep -c 'camilladsp-sessione.py' "$ROOT/tests/prova-alsa-qemu.sh")|$(grep -c 'RATES = (44100, 96000)' "$ROOT/tests/camilladsp-sessione.py")"
expect "pacchetto alsa-cdsp: il conteggio dei frame riparte con una FIFO nuova, timeout websocket brevi" "1|1|1" 	"$(grep -c 'session_frames = 0;' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")|$(grep -c 'ps.st_ino != st.st_ino' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")|$(grep -c 'ws_timeout_ms > 0 ? pcm->ws_timeout_ms : 500' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")"
expect "pacchetto alsa-cdsp: patch della modalita' sessione (pipe, websocket, coda)" "1|1|1" \
	"$(grep -c 'strcmp(id, "fifo")' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")|$(grep -c 'snprintf(cmd, sizeof(cmd), "{.*SetConfigFilePath' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")|$(grep -c 'static void end_session' "$ROOT/package/alsa-cdsp/0002-session-mode.patch")"
expect "plugin in modalita' sessione: nessun fork, nessun waitpid" "0" \
	"$(awk '/^\+static int start_session/,/^\+}/' "$ROOT/package/alsa-cdsp/0002-session-mode.patch" | grep -c 'fork()\|waitpid\|execv')"

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
case "$zcall" in *" -H"*) ok "zona: niente ripiego su plughw: (-H)" ;; *) ko "zona: -H" "presente" "$zcall" ;; esac
case "$zcall" in *"-d decode=info"*) ok "zona: -d decode=info (avviso di ricampionamento nel suo registro)" ;; *) ko "zona: decode=info" "presente" "$zcall" ;; esac
case "$zcall" in *" -D "*) ko "zona: niente DSD nativo (volume software di Lyrion)" "nessun -D" "$zcall" ;; *) ok "zona: niente DSD nativo (volume software di Lyrion)" ;; esac
case "$zcall" in *UMIK*|*R26*) ko "zona: niente microfono ne' DAC principale" "solo Zona" "$zcall" ;; *) ok "zona: niente microfono ne' DAC principale" ;; esac
expect "zona: registrata per il controllo" "Zona" "$(cut -d' ' -f2 "$DSP/run/zone/2")"
expect "zona: MAC stabile e locale" "1|02" \
	"$([ "$(dspfn 1 'zone_mac 2')" = "$(dspfn 1 'zone_mac 2')" ] && echo 1)|$(dspfn 1 'zone_mac 2' | cut -c1-2)"
# Parita' con il DAC principale: le zone usano gli stessi argomenti comuni
# (common_args), con registro e priorita' propri.
case "$zcall" in *"-b "*":"*" -C 30 "*"-d output=info"*"-f /var/log/squeezelite-Zona.log"*) ok "zona: buffer di ingresso/uscita, -C e registro come il principale" ;; *) ko "zona: argomenti comuni" "-b ... -C 30 ... -f squeezelite-Zona.log" "$zcall" ;; esac
case "$zcall" in *" -r :400 "*) ok "zona: frequenza massima e pausa fra frequenze come il principale" ;; *) ko "zona: -r" "-r :400" "$zcall" ;; esac
case "$zcall" in *"-R vLE"*) ok "zona: ricampiona solo se il DAC non regge la frequenza (come il principale)" ;; *) ko "zona: -R vLE" "presente" "$zcall" ;; esac
case "$zcall" in *"-a 400:4:"*) ok "zona: buffer e periodi ALSA come il principale" ;; *) ko "zona: -a" "-a 400:4:" "$zcall" ;; esac
expect "zona: gli argomenti comuni coincidono con quelli del principale" \
	"$(dspfn 1 'common_args 1 /a 80 400 "" | grep -v "^80$" | grep -v "^/a$"')" \
	"$(dspfn 1 'common_args 2 /b 75 400 "" | grep -v "^75$" | grep -v "^/b$"')"
printf 'ALTRI_DAC=si\nFREQUENZA_MAX=96000\n' > "$DSP/run/sweetspot.conf"
expect "FREQUENZA_MAX vale anche per le zone" "-r|96000:400" "$(dspfn 1 'common_args 2 /b 75 400 "" | grep -A1 "^-r$" | tr "\n" "|" | sed "s/|$//"')"
echo ALTRI_DAC=si > "$DSP/run/sweetspot.conf"
expect "buffer delle zone: il budget si divide fra loro" "yes" \
	"$([ "$(dspfn 1 'PLAYER_BUFFERS_DIV=4 player_buffers | cut -d: -f1')" -le "$(dspfn 1 'player_buffers | cut -d: -f1')" ] && echo yes)"
# Capacita' per zona e diagnostica: dove la parita' non c'e', lo dice il file.
expect "capacita' della zona: DSD in PCM, volume software, niente correzione" "zona|pcm|software|no|no" \
	"$(for k in tipo dsd volume correzione volume_64bit; do sed -n "s/^$k=//p" "$DSP/run/capacita/zona-Zona"; done | tr '\n' '|' | sed 's/|$//')"
expect "capacita' della zona: MAC e priorita' coincidono con il player" "$(dspfn 1 'zone_mac 2')|75" \
	"$(sed -n 's/^mac=//p' "$DSP/run/capacita/zona-Zona")|$(sed -n 's/^priorita=//p' "$DSP/run/capacita/zona-Zona")"
case "$(cat "$DSP/run/capacita/zona-Zona.args" 2>/dev/null)" in "-o hw:CARD=Zona,DEV=0 "*"-H "*) ok "zona: argomenti di Squeezelite salvati per la diagnostica" ;; *) ko "zona: argomenti salvati" "-o hw:CARD=Zona,DEV=0 ... -H" "$(cat "$DSP/run/capacita/zona-Zona.args" 2>/dev/null)" ;; esac
# Supervisione: una zona che cade subito si riavvia con ritardo crescente.
dspfn 1 'mkdir -p $ZONE_RIAVVIO; echo "$(date +%s) 0" > $ZONE_RIAVVIO/9.avvio; zone_note_exit 9'
expect "zona caduta subito: ritardo di 2 s prima del riavvio" "2" "$(cat "$DSP/run/zone-riavvio/9.ritardo")"
echo 99999999999 > "$DSP/run/zone-riavvio/9.fino"
expect "zona: finche' dura il ritardo non si riavvia" "attesa" "$(dspfn 1 'zone_ready 9 && echo pronta || echo attesa')"
echo 1 > "$DSP/run/zone-riavvio/9.fino"
expect "zona: passato il ritardo si riavvia" "pronta" "$(dspfn 1 'zone_ready 9 && echo pronta || echo attesa')"
dspfn 1 'echo "$(( $(date +%s) - 100 )) 8" > $ZONE_RIAVVIO/9.avvio; zone_note_exit 9'
expect "zona stabile prima di cadere: nessun ritardo" "0" "$(cat "$DSP/run/zone-riavvio/9.ritardo")"
expect "zona caduta: il riavvio e' contato fra quelli del player (restart_conta)" "si" "$([ "$(cat "$DSP/run/restart.player" 2>/dev/null || echo 0)" -ge 1 ] && echo si)"
# Il registro della zona (squeezelite-ID.log) ha il tetto di log_quota (#100).
# Sincronizzazione multiroom: gruppo ricordato e ripristinato dopo il riavvio.
LMSSTUB='mode() { echo completa; }
lms_get() { case "$3" in connected) echo 1 ;; sync) cat $RUN/lms.sync ;; esac; }
lms_json() { echo "$*" >> $RUN/lms.call; }
mkdir -p $SYNC_DIR; k=$(mac_key 02:aa)'
rm -f "$DSP/run/lms.call"; rm -rf "$DSP/run/sync"
echo "02:aa,02:bb,02:cc" > "$DSP/run/lms.sync"
dspfn 1 "$LMSSTUB; sync_poll 02:aa"
expect "sincronizzazione: a regime ricorda il gruppo (senza se stesso)" "02:bb 02:cc " "$(cat "$DSP/run/sync/02_aa.gruppo")"
echo "-" > "$DSP/run/lms.sync"
dspfn 1 "$LMSSTUB; : > \$SYNC_DIR/\$k.pendente; sync_poll 02:aa; sync_poll 02:aa"
expect "sincronizzazione: dopo il riavvio aspetta qualche secondo prima di intervenire" "" "$(cat "$DSP/run/lms.call" 2>/dev/null)"
echo 1 > "$DSP/run/sync/02_aa.visto"
dspfn 1 "$LMSSTUB; sync_poll 02:aa"
expect "sincronizzazione: la zona torna nel gruppo ricordato" "02:aa sync 02:bb|no" \
	"$(tr '\n' '|' < "$DSP/run/lms.call" | sed 's/|$//')|$([ -f "$DSP/run/sync/02_aa.pendente" ] && echo si || echo no)"
rm -f "$DSP/run/lms.call"
dspfn 1 "$LMSSTUB; : > \$SYNC_DIR/\$k.pendente; echo 1 > \$SYNC_DIR/\$k.visto"
echo "02:bb" > "$DSP/run/lms.sync"
dspfn 1 "$LMSSTUB; sync_poll 02:aa"
expect "sincronizzazione: se Lyrion ha gia' ripristinato il gruppo non si interviene" "" "$(cat "$DSP/run/lms.call" 2>/dev/null)"
echo "-" > "$DSP/run/lms.sync"
rm -f "$DSP/run/sync/02_aa.t"
dspfn 1 "$LMSSTUB; sync_poll 02:aa"
expect "sincronizzazione: un gruppo sciolto da Lyrion si dimentica" "no" "$([ -f "$DSP/run/sync/02_aa.gruppo" ] && echo si || echo no)"
sleep 300 & zpid=$!
echo "$zpid Zona" > "$DSP/run/zone/2"
expect "stato: zona con le capacita'" "INFO|Capacita' zona Zona|DSD: convertito in PCM (volume software di Lyrion); volume: software di Lyrion, mixer del DAC a 0 dB; correzione ambientale e volume a 64 bit: solo sul DAC principale; frequenza massima annunciata:  Hz; priorita' real-time 75 sui core di sistema 0; buffer ALSA 400 ms" \
	"$(SWEETSPOT_SYSFS=$WEB/sys SWEETSPOT_PROCFS=$DSP/proc SWEETSPOT_RUN=$DSP/run SWEETSPOT_LOG=$DSP/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_SQLOG=$WEB/squeezelite.log \
		$TEST_SH -c "$DSPSTUB
set -- --dati; . $OVERLAY/usr/bin/sweetspot-check" 2>/dev/null | grep "^[A-Z]*|Capacita' zona")"
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
# Ricollegamento rapido: stesso indice e stesso id ALSA, ma il kernel assegna
# un nuovo devnum al dispositivo USB; l'istanza del DAC cambia.
echo 1 > "$DSP/sys/devices/usb1/1-2/busnum"; echo 5 > "$DSP/sys/devices/usb1/1-2/devnum"
expect "istanza del DAC USB: id, busnum e devnum" "R26 1:5" "$(dspfn 1 'dac_instance 1')"
echo 6 > "$DSP/sys/devices/usb1/1-2/devnum"
expect "ricollegamento rapido (stesso id): l'istanza cambia" "R26 1:6" "$(dspfn 1 'dac_instance 1')"
expect "l'identita' del DAC principale non cambia col devnum" "292b:0a26 AAA111" "$(dspfn 1 'dac_identity 1')"
mkdir -p "$DSP/proc/asound/card5"; echo I2S > "$DSP/proc/asound/card5/id"
expect "scheda senza USB (I2S): l'istanza e' il solo id" "I2S" "$(dspfn 1 'dac_instance 5')"
rm -rf "$DSP/proc/asound/card5"

echo "Supervisore: backoff dei riavvii"
expect "backoff: primo errore subito dopo l'avvio" "2" "$(dspfn 1 'backoff_next 0 1')"
expect "backoff: raddoppia fino a 60 s" "4|8|16|32|60|60" \
	"$(dspfn 1 'backoff_next 2 1; backoff_next 4 1; backoff_next 8 1; backoff_next 16 1; backoff_next 32 1; backoff_next 60 1' | tr '\n' '|' | sed 's/|$//')"
expect "backoff: azzerato dopo un funzionamento stabile" "0" "$(dspfn 1 'backoff_next 60 30')"
echo "Supervisore: sorveglianza dei processi ausiliari"
expect "ausiliari: follower del volume morto, riavviato" "riavvio|1" 	"$(dspfn 1 'start_volume_watch() { echo riavvio; VOLPID=""; }; LATPID=""; VOLPID=999999; WATCH_N=0; watch_check; echo $WATCH_N' | tr '
' '|' | sed 's/|$//')"
expect "ausiliari: l'evento e' nel log" "1" "$(grep -c "follower del volume" "$DSP/log")"
expect "ausiliari: oltre il limite non riavvia e rinuncia" "5|" 	"$(dspfn 1 'start_latency_watch() { echo X; }; VOLPID=""; LATPID=999999; WATCH_N=5; watch_check; echo "$WATCH_N|$LATPID"' | tr '
' '|' | sed 's/|$//')"

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
# Rotazione del registro di Squeezelite (copytruncate) senza perdere eventi.
rm -f "$DSP/run/xrun.totale" "$DSP/run/sessione.xrun"
printf '[12:00:00] _output_frames:1 XRUN\n' > "$DSP/squeezelite.log"
dspfn 1 "SQLOG=$DSP/squeezelite.log; session_start"
printf '[12:00:01] _output_frames:2 XRUN\n[12:00:02] _output_frames:3 XRUN\n[12:00:03] _output_frames:4 XRUN recover failed: -32\n' >> "$DSP/squeezelite.log"
awk 'BEGIN { for (i = 0; i < 30; i++) printf "[12:01:00] stream:%d riga di riempimento per superare la soglia di un kilobyte\n", i }' >> "$DSP/squeezelite.log"
echo "LOG_SQUEEZELITE_KB=1" > "$DSP/run/sweetspot.conf"
dspfn 1 "SQLOG=$DSP/squeezelite.log; sqlog_rotate \$SQLOG"
expect "rotazione: registro troncato in place" "0" "$(wc -c < "$DSP/squeezelite.log" | tr -d ' ')"
expect "rotazione: totale salvato (eventi recuperi)" "3 1" "$(cat "$DSP/run/xrun.totale")"
expect "rotazione: contatori della sessione" "2 1" "$(cat "$DSP/run/sessione.xrun")"
expect "rotazione: posizione della sessione azzerata" "0" "$(sed -n 's/^sqlog=//p' "$DSP/run/sessione")"
printf '[12:02:00] _output_frames:5 XRUN\n' >> "$DSP/squeezelite.log"
dspfn 1 "SQLOG=$DSP/squeezelite.log; sqlog_rotate \$SQLOG"
expect "rotazione: sotto soglia non ruota" "1" "$(wc -l < "$DSP/squeezelite.log" | tr -d ' ')"
expect "rotazione: storico = contatori + registro" "4 1" "$(dspfn 1 "xrun_total $DSP/squeezelite.log")"
# Ripristina lo stato che i test seguenti si aspettano.
rm -f "$DSP/run/sweetspot.conf" "$DSP/run/xrun.totale" "$DSP/run/sessione.xrun"
printf '[12:00:00] _output_frames:123 XRUN\n' > "$DSP/squeezelite.log"
dspfn 1 "SQLOG=$DSP/squeezelite.log; session_start"
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
# Stato del percorso trasformativo (dsp.stato) e politica se manca la correzione.
mkdir -p "$DSP/bin2"
cat > "$DSP/bin2/sweetspot-camilla" <<'EOS'
#!/bin/sh
case "$2" in
GetState) echo '{"GetState":{"result":"Ok","value":"Running"}}' ;;
GetCaptureSignalPeak) echo "{\"GetCaptureSignalPeak\":{\"result\":\"Ok\",\"value\":[$(cat "$SWEETSPOT_RUN/picco.in")]}}" ;;
GetPlaybackSignalPeak) echo "{\"GetPlaybackSignalPeak\":{\"result\":\"Ok\",\"value\":[$(cat "$SWEETSPOT_RUN/picco.out")]}}" ;;
esac
EOS
chmod +x "$DSP/bin2/sweetspot-camilla"
stato() { dspfn 1 "PATH=$DSP/bin2:\$PATH; dsp_stato_poll"; sed -n "s/^$1=//p" "$DSP/run/dsp.stato"; }
echo "-20.5,-18.0" > "$DSP/run/picco.in"; echo "-6.0,-9.5" > "$DSP/run/picco.out"
echo "5000 0 29" > "$DSP/run/dsp.clip"
rm -f "$DSP/run/dsp.stato"
expect "stato DSP: processo CamillaDSP in esecuzione" "camilladsp Running" "$(stato percorso) $(stato stato)"
expect "stato DSP: picchi per canale" "-20.5,-18.0 -6.0,-9.5" "$(stato picco_ingresso) $(stato picco_uscita)"
echo "-30.0,-3.0" > "$DSP/run/picco.in"
expect "stato DSP: picco massimo della sessione per canale" "-20.5,-3.0" "$(stato picco_ingresso)"
expect "stato DSP: campioni tagliati" "29" "$(stato campioni_tagliati)"
rm -f "$DSP/run/correzione.attiva"; echo "configurazione dei filtri non valida" > "$DSP/run/correzione.errore"
expect "politica: predefinita blocca, stato bloccato" "blocca bloccato" "$(dspfn 1 dsp_politica) $(stato percorso)"
echo "CORREZIONE_SE_ASSENTE=diretto" > "$DSP/run/sweetspot.conf"
expect "politica diretto: stato visibile come senza correzione" "diretto diretto-senza-correzione assente" "$(dspfn 1 dsp_politica) $(stato percorso) $(stato stato)"
rm -f "$DSP/run/correzione.errore" "$DSP/run/sweetspot.conf" "$DSP/run/dsp.stato"
touch "$DSP/run/correzione.attiva"
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
# Underrun di CamillaDSP: si leggono dal suo registro dall'inizio della sessione.
printf 'warn: vecchio buffer underrun di una sessione precedente\n' > "$DSP/camilladsp.log"
dspfn 1 "DSPLOG=$DSP/camilladsp.log; SQLOG=$DSP/squeezelite.log; session_start"
expect "underrun DSP: la sessione parte da zero, il registro vecchio non conta" "0" "$(cut -d' ' -f2 "$DSP/run/dsp.underrun")"
printf '2026-10-14 12:00:00 WARN [camilladsp] PB: Prepare playback after buffer underrun\nINFO altro messaggio\n' >> "$DSP/camilladsp.log"
dspfn 1 "DSPLOG=$DSP/camilladsp.log; dsp_underrun_poll"
expect "underrun DSP: contati dal registro" "1" "$(cut -d' ' -f2 "$DSP/run/dsp.underrun")"
dspfn 1 "DSPLOG=$DSP/camilladsp.log; dsp_underrun_poll"
expect "underrun DSP: un secondo giro non conta due volte" "1" "$(cut -d' ' -f2 "$DSP/run/dsp.underrun")"
printf 'Buffer UNDERRUN\nPB: Prepare playback after buffer underrun\n' >> "$DSP/camilladsp.log"
dspfn 1 "DSPLOG=$DSP/camilladsp.log; dsp_underrun_poll"
expect "underrun DSP: si sommano a quelli gia' contati" "3" "$(cut -d' ' -f2 "$DSP/run/dsp.underrun")"
printf 'riparte da capo con un underrun\n' > "$DSP/camilladsp.log"
dspfn 1 "DSPLOG=$DSP/camilladsp.log; dsp_underrun_poll"
expect "underrun DSP: registro ricominciato da capo, si somma" "4" "$(cut -d' ' -f2 "$DSP/run/dsp.underrun")"
dspfn 1 "PATH=$DSP/bin2:\$PATH; DSPLOG=$DSP/camilladsp.log; dsp_stato_poll"
expect "stato DSP: underrun nel riepilogo" "4" "$(sed -n 's/^underrun=//p' "$DSP/run/dsp.stato")"
expect "stato: underrun di CamillaDSP nella sessione" \
	"ATTENZIONE|Underrun di CamillaDSP|4 nella sessione (camilladsp.log): il buffer di uscita si e' svuotato, prova ad alzare BUFFER_ALSA_MS o il profilo 'prestazioni'" \
	"$(livecheck 'Underrun di CamillaDSP')"
expect "stato: picchi di CamillaDSP" "INFO|Picco di CamillaDSP|ingresso -30.0,-3.0 dBFS, uscita -6.0,-9.5 dBFS (massimo della sessione, sinistro e destro)" \
	"$(livecheck 'Picco di CamillaDSP')"
echo "1000 0" > "$DSP/run/dsp.underrun"
expect "stato: nessun underrun" "OK|Underrun di CamillaDSP|nessuno nella sessione" "$(livecheck 'Underrun di CamillaDSP')"
rm -f "$DSP/run/dsp.underrun" "$DSP/run/dsp.stato"
# Correzione non applicabile: con blocca il player non parte, con diretto suona
# ma l'avviso resta visibile (errore in Stato e percorso diretto-senza-correzione).
rm -f "$DSP/run/correzione.attiva"
expect "correzione non applicabile, blocca: run_player si ferma" "1" "$(dspfn 1 "correzione_non_applicabile 'sinistro.txt illeggibile' >/dev/null; echo \$?")"
expect "correzione non applicabile, blocca: errore e percorso in Stato" "sinistro.txt illeggibile|bloccato" "$(cat "$DSP/run/correzione.errore")|$(sed -n 's/^percorso=//p' "$DSP/run/dsp.stato")"
echo "CORREZIONE_SE_ASSENTE=diretto" > "$DSP/run/sweetspot.conf"
expect "correzione non applicabile, diretto: suona con l'avviso" "0" "$(dspfn 1 "correzione_non_applicabile 'FIR rotto' >/dev/null; echo \$?")"
expect "correzione non applicabile, diretto: errore e percorso in Stato" "FIR rotto|diretto-senza-correzione" "$(cat "$DSP/run/correzione.errore")|$(sed -n 's/^percorso=//p' "$DSP/run/dsp.stato")"
rm -f "$DSP/run/correzione.errore" "$DSP/run/sweetspot.conf" "$DSP/run/dsp.stato"
touch "$DSP/run/correzione.attiva"
# Sessione iniziata due minuti fa; nel registro un XRUN prima e uno dopo.
sed -i "s/^inizio=.*/inizio=$(( $(date +%s) - 150 ))/" "$DSP/run/sessione"
expect "stato: XRUN prima della sessione esclusi" "OK|XRUN nella sessione|nessuno in 2 minuti" "$(livecheck 'XRUN nella sessione')"
expect "stato: lo storico diventa informazione" "INFO|XRUN ALSA registrati|1 nel registro storico; non misura il jitter del clock" "$(livecheck 'XRUN ALSA registrati')"
printf '[12:05:00] _output_frames:123 XRUN\n[12:05:01] output_thread:123 XRUN recover failed: Broken pipe\n' >> "$DSP/squeezelite.log"
expect "stato: XRUN della sessione" "ATTENZIONE|XRUN nella sessione|1 in 2 minuti (recuperi falliti: 1)" "$(livecheck 'XRUN nella sessione')"
printf 'XRUN\n' > "$DSP/squeezelite.log"
expect "stato: registro ricominciato, conta tutto" "ATTENZIONE|XRUN nella sessione|1 in 2 minuti (recuperi falliti: 0)" "$(livecheck 'XRUN nella sessione')"
printf 'MODALITA=completa\n' > "$DSP/run/sweetspot.conf"
expect "stato: renderer UPnP spento di serie" "INFO|Renderer UPnP/DLNA|spento (RENDERER_UPNP=no): acceso dalla pagina Sistema compare in BubbleUPnP, JPlay, mconnect" "$(livecheck 'Renderer UPnP/DLNA')"
printf 'RENDERER_UPNP=si\n' > "$DSP/run/sweetspot.conf"
expect "stato: renderer UPnP acceso ma il demone non risponde" "ATTENZIONE|Renderer UPnP/DLNA|stato non disponibile: il demone non risponde" "$(livecheck 'Renderer UPnP/DLNA')"
printf '{"stato":"attivo","nome":"Salotto","porta":49494,"abbonati":2,"dettaglio":""}\n' > "$DSP/run/renderer.json"
expect "stato: renderer UPnP attivo" "OK|Renderer UPnP/DLNA|acceso come \"Salotto\" (porta 49494, 2 app collegate): l'audio passa da Lyrion e dal player" "$(livecheck 'Renderer UPnP/DLNA')"
printf '{"stato":"attesa","nome":"Salotto","porta":49494,"abbonati":0,"dettaglio":"Lyrion non risponde"}\n' > "$DSP/run/renderer.json"
expect "stato: renderer UPnP in attesa di Lyrion" "ATTENZIONE|Renderer UPnP/DLNA|acceso ma non utilizzabile: Lyrion non risponde" "$(livecheck 'Renderer UPnP/DLNA')"
printf '{"stato":"errore","nome":"Salotto","porta":49494,"dettaglio":"porta 49494 occupata"}\n' > "$DSP/run/renderer.json"
expect "stato: renderer UPnP con la porta occupata" "ATTENZIONE|Renderer UPnP/DLNA|non parte: porta 49494 occupata" "$(livecheck 'Renderer UPnP/DLNA')"
printf 'RENDERER_UPNP=si\nMODALITA=player\n' > "$DSP/run/sweetspot.conf"
expect "stato: renderer UPnP in modalita' solo player" "ATTENZIONE|Renderer UPnP/DLNA|serve Lyrion su questo Sweetspot: non funziona in modalità solo player" "$(livecheck 'Renderer UPnP/DLNA')"
rm -f "$DSP/run/sweetspot.conf" "$DSP/run/renderer.json"
printf 'MODALITA=completa
' > "$DSP/run/sweetspot.conf"
expect "stato: media server spento di serie" "INFO|Media server UPnP/DLNA|spento (SERVER_UPNP=no): acceso dalla pagina Sistema, streamer e DAC di rete leggono la libreria" "$(livecheck 'Media server UPnP/DLNA')"
printf 'SERVER_UPNP=si
' > "$DSP/run/sweetspot.conf"
expect "stato: media server acceso ma non in esecuzione" "ATTENZIONE|Media server UPnP/DLNA|acceso nelle impostazioni ma non in esecuzione: spegnilo e riaccendilo dalla pagina Sistema" "$(livecheck 'Media server UPnP/DLNA')"
printf '%s
' "$$" > "$DSP/run/mediaserver.pid"
expect "stato: media server in esecuzione" "OK|Media server UPnP/DLNA|acceso (porta 8200): DSF e DFF partono senza conversioni" "$(livecheck 'Media server UPnP/DLNA')"
printf 'SERVER_UPNP=si
MODALITA=player
' > "$DSP/run/sweetspot.conf"
expect "stato: media server in modalita' solo player" "ATTENZIONE|Media server UPnP/DLNA|serve la libreria su questo Sweetspot: non funziona in modalità solo player" "$(livecheck 'Media server UPnP/DLNA')"
rm -f "$DSP/run/sweetspot.conf" "$DSP/run/mediaserver.pid"
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
	SWEETSPOT_NOW=${QNOW:-} SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
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
# Wi-Fi: senza WIFI_NOME i moduli servono all'hotspot di primo accesso,
# fuori solo con HOTSPOT=no.
wifi_bl() { blacklist "$1" >/dev/null; grep -c 'blacklist iwlwifi' "$Q/modprobe.d/sweetspot-run.conf"; }
expect "wifi: moduli caricabili per l'hotspot, in blacklist solo senza rete e senza hotspot" "0|0|1" \
	"$(wifi_bl '')|$(wifi_bl 'WIFI_NOME=casa
HOTSPOT=no')|$(wifi_bl 'HOTSPOT=no')"
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
	"ATTENZIONE|Volume|a 64 bit non disponibile (CamillaDSP non avviato o modalita' player): in uso il volume software, con dither TPDF di Squeezelite" \
	"$(qcheck Volume)"
echo dsp > "$Q/run/volume.modo"
echo "70 -11.1 0" > "$Q/run/volume.dsp"
echo "errore" > "$Q/run/volume.applicato"
expect "stato: volume richiesto non confermato da CamillaDSP" \
	"ATTENZIONE|Volume|a 64 bit: richiesto 70 (-11.1 dB), ma CamillaDSP non ha confermato il comando: il guadagno effettivo puo' essere diverso; si risincronizza da solo" \
	"$(qcheck Volume)"
echo "50 -24.7 0" > "$Q/run/volume.applicato"
expect "stato: volume richiesto diverso dall'applicato" \
	"ATTENZIONE|Volume|a 64 bit: richiesto 70 (-11.1 dB), applicato 50 (-24.7 dB); si risincronizza da solo" \
	"$(qcheck Volume)"
echo "70 -11.1 0" > "$Q/run/volume.applicato"
expect "stato: richiesto e applicato uguali, nessun avviso" "OK" "$(qcheck Volume | cut -d'|' -f1)"
rm -f "$Q/run/sweetspot.conf" "$Q/run/volume.modo" "$Q/run/volume.dsp" "$Q/run/volume.applicato"
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

echo "Modalita' ascolto: ripresa all'avvio e rallentamento con cgroup v2"
ASC=$WORK/ascolto
mkdir -p "$ASC/run/sospendibili" "$ASC/cg"
# ascrun CGROUP_DIR COMANDI: kill e ionice finti scrivono in $ASC/calls, ps e
# pgrep restituiscono processi finti (job con gruppo 700 = PID 701 e 702,
# scanner = PID 800).
ascrun() {
	SWEETSPOT_TEST=1 SWEETSPOT_RUN=$ASC/run SWEETSPOT_LOG=$ASC/log SWEETSPOT_PROCFS=$ASC/proc SWEETSPOT_CGROUP=$1 $TEST_SH -c "
		. $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-ascolto
		kill() { echo \"kill \$*\" >> $ASC/calls; }
		ionice() { echo \"ionice \$*\" >> $ASC/calls; }
		group_pids() { [ \"\$1\" = 700 ] && printf '701\n702\n'; }
		scanner_pids() { echo 800; }
		$2"
}
# a) all'avvio i processi elencati in ascolto.fermi ripartono (SIGCONT) prima
# che l'elenco venga svuotato.
printf -- '-700\n800\n' > "$ASC/run/ascolto.fermi"
rm -f "$ASC/calls"
ascrun "$ASC/nessuno" "start_clean"
expect "ascolto: all'avvio i sospesi ricevono SIGCONT" "kill -CONT -- -700|kill -CONT -- 800" "$(tr '\n' '|' < "$ASC/calls" | sed 's/|$//')"
expect "ascolto: all'avvio l'elenco dei sospesi e' vuoto" "0" "$(grep -c . "$ASC/run/ascolto.fermi")"
# a2) identita' dei processi: PID + starttime (campo 22 di /proc/PID/stat, con
# il nome fra parentesi che puo' avere spazi). Un PID riusato da un altro
# processo non riceve segnali; il gruppo il cui capogruppo e' sparito si'.
mkdir -p "$ASC/proc/850" "$ASC/proc/860" "$ASC/proc/800"
procstat() { echo "$1 ($2) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 $3 0 0" > "$ASC/proc/$1/stat"; }
procstat 850 "sh (x) y" 5000
procstat 860 "altro" 7000
printf -- '850 5000\n860 6000\n-870 4000\n' > "$ASC/run/ascolto.fermi"
rm -f "$ASC/calls"
ascrun "$ASC/nessuno" "start_clean"
expect "ascolto: PID riusato niente SIGCONT, gruppo senza capogruppo si'" "kill -CONT -- 850|kill -CONT -- -870" "$(tr '\n' '|' < "$ASC/calls" | sed 's/|$//')"
procstat 800 "scanner.pl" 4242
rm -f "$ASC/calls" "$ASC/run/ascolto.fermi"
ascrun "$ASC/nessuno" "throttle 800 scanner 800"
expect "ascolto: SIGSTOP annota PID e starttime" "800 4242" "$(cat "$ASC/run/ascolto.fermi")"
rm -f "$ASC/proc/800/stat" "$ASC/run/ascolto.fermi"
# b) senza cgroup v2 si ripiega su SIGSTOP (comportamento di prima).
echo 700 > "$ASC/run/sospendibili/copia"
rm -f "$ASC/calls"
ascrun "$ASC/nessuno" "pause_work"
expect "ascolto: senza cgroup si ripiega su SIGSTOP" "kill -STOP -- -700|kill -STOP -- 800" "$(tr '\n' '|' < "$ASC/calls" | sed 's/|$//')"
expect "ascolto: senza cgroup i sospesi sono annotati" "-700 800" "$(tr '\n' ' ' < "$ASC/run/ascolto.fermi" | sed 's/ $//')"
ascrun "$ASC/nessuno" "pause_work; resume_work"
# c) con cgroup v2 (cpu disponibile) niente SIGSTOP: limiti e ionice idle.
: > "$ASC/run/ascolto.fermi"
printf 'cpu io memory\n' > "$ASC/cg/cgroup.controllers"
: > "$ASC/cg/cgroup.subtree_control"
rm -f "$ASC/calls"
ascrun "$ASC/cg" "pause_work"
expect "ascolto: cgroup, limite di CPU" "5000 100000" "$(cat "$ASC/cg/sweetspot-ascolto/cpu.max")"
expect "ascolto: cgroup, peso minimo" "1" "$(cat "$ASC/cg/sweetspot-ascolto/cpu.weight")"
expect "ascolto: cgroup, controller cpu attivato" "+cpu" "$(cat "$ASC/cg/cgroup.subtree_control")"
expect "ascolto: cgroup, processi del job e scanner spostati" "701 702 800" "$(tr '\n' ' ' < "$ASC/cg/sweetspot-ascolto/cgroup.procs" | sed 's/ $//')"
expect "ascolto: cgroup, ionice idle e nessun SIGSTOP" "ionice -c 3 -p 701|ionice -c 3 -p 702|ionice -c 3 -p 800" "$(tr '\n' '|' < "$ASC/calls" | sed 's/|$//')"
expect "ascolto: cgroup, nessun sospeso e due lenti" "0|2" "$(grep -c . "$ASC/run/ascolto.fermi")|$(grep -c . "$ASC/run/ascolto.lenti")"
expect "ascolto: stato conta i lavori rallentati" "OK|Ascolto|ascolto puro (coda in RAM, dischi fermi, lavori di fondo sospesi): ora 2 lavori sospesi" \
	"$(printf 'state: RUNNING\n' > "$Q/proc/asound/card1/pcm0p/sub0/status"; cp "$ASC/run/ascolto.lenti" "$Q/run/ascolto.lenti"; qcheck Ascolto; rm -f "$Q/run/ascolto.lenti")"
# d) a fine ascolto i processi tornano nel gruppo radice, ionice normale.
rm -f "$ASC/calls"
ascrun "$ASC/cg" "resume_work"
expect "ascolto: cgroup, a fine ascolto tornano nel gruppo radice" "701 702 800" "$(tr '\n' ' ' < "$ASC/cg/cgroup.procs" | sed 's/ $//')"
expect "ascolto: cgroup, ionice di nuovo normale" "ionice -c 2 -n 4 -p 701|ionice -c 2 -n 4 -p 702|ionice -c 2 -n 4 -p 800" "$(tr '\n' '|' < "$ASC/calls" | sed 's/|$//')"
expect "ascolto: cgroup, elenco dei rallentati svuotato" "0" "$(grep -c . "$ASC/run/ascolto.lenti")"
# e) composizione: lo scanner sta in sweetspot-scanner (tetti di memoria e I/O):
# l'ascolto non lo sposta, limita la CPU di quel gruppo e poi ripristina.
rm -rf "$ASC/cg2"; mkdir -p "$ASC/cg2/sweetspot-scanner" "$ASC/proc/800"
printf 'cpu io memory\n' > "$ASC/cg2/cgroup.controllers"; : > "$ASC/cg2/cgroup.subtree_control"
printf 'max 100000\n' > "$ASC/cg2/sweetspot-scanner/cpu.max"; echo 100 > "$ASC/cg2/sweetspot-scanner/cpu.weight"
echo 3435973800 > "$ASC/cg2/sweetspot-scanner/memory.max"; echo 800 > "$ASC/cg2/sweetspot-scanner/cgroup.procs"
echo '0::/sweetspot-scanner' > "$ASC/proc/800/cgroup"
rm -f "$ASC/calls" "$ASC/run/ascolto.lenti"; rm -rf "$ASC/run/sospendibili"/*
ascrun "$ASC/cg2" "pause_work"
expect "ascolto: scanner con tetti propri, CPU limitata sul posto" "5000 100000|1|3435973800|800" \
	"$(cat "$ASC/cg2/sweetspot-scanner/cpu.max")|$(cat "$ASC/cg2/sweetspot-scanner/cpu.weight")|$(cat "$ASC/cg2/sweetspot-scanner/memory.max")|$(tr '\n' ' ' < "$ASC/cg2/sweetspot-scanner/cgroup.procs" | sed 's/ $//')"
expect "ascolto: scanner non spostato nel gruppo dell'ascolto" "no" "$([ -s "$ASC/cg2/sweetspot-ascolto/cgroup.procs" ] && echo si || echo no)"
ascrun "$ASC/cg2" "pause_work"
ascrun "$ASC/cg2" "resume_work"
expect "ascolto: a fine ascolto CPU e peso originali" "max 100000|100|3435973800" \
	"$(cat "$ASC/cg2/sweetspot-scanner/cpu.max")|$(cat "$ASC/cg2/sweetspot-scanner/cpu.weight")|$(cat "$ASC/cg2/sweetspot-scanner/memory.max")"
rm -f "$ASC/proc/800/cgroup"
# f) I2: lo scanner e' ancora nel gruppo del server (sweetspot-lyrion): va
# assegnato al gruppo dedicato PRIMA di limitare; il server non va toccato.
rm -rf "$ASC/cg3"; mkdir -p "$ASC/cg3/sweetspot-lyrion" "$ASC/cg3/sweetspot-scanner"
# il kernel crea i file di controllo con la cartella: qui li simula il test
printf 'max 100000\n' > "$ASC/cg3/sweetspot-scanner/cpu.max"; echo 100 > "$ASC/cg3/sweetspot-scanner/cpu.weight"
printf 'cpu io memory\n' > "$ASC/cg3/cgroup.controllers"; : > "$ASC/cg3/cgroup.subtree_control"
printf 'max 100000\n' > "$ASC/cg3/sweetspot-lyrion/cpu.max"; echo 100 > "$ASC/cg3/sweetspot-lyrion/cpu.weight"
echo 800 > "$ASC/cg3/sweetspot-lyrion/cgroup.procs"; echo '0::/sweetspot-lyrion' > "$ASC/proc/800/cgroup"
rm -f "$ASC/calls" "$ASC/run/ascolto.lenti" "$ASC/run/ascolto.cgsalvati"
ascrun "$ASC/cg3" "pause_work"
expect "ascolto: scanner ancora nel gruppo server, il server non e' limitato" "max 100000|100" \
	"$(cat "$ASC/cg3/sweetspot-lyrion/cpu.max")|$(cat "$ASC/cg3/sweetspot-lyrion/cpu.weight")"
expect "ascolto: scanner spostato nel gruppo dedicato prima del limite" "800|5000 100000" \
	"$(tr '\n' ' ' < "$ASC/cg3/sweetspot-scanner/cgroup.procs" | sed 's/ $//')|$(cat "$ASC/cg3/sweetspot-scanner/cpu.max" 2>/dev/null)"
rm -f "$ASC/proc/800/cgroup"

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
	SWEETSPOT_NOW=${QNOW:-} SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-ascolto; $1"
}
iostat 20480 1000 2000
expect "contatori: disco con la musica (intero) e rete senza lo" "disco sdb 20480|rete 3000" "$(ascfn io_counters | tr '\n' '|' | sed 's/|$//')"
ascfn io_start
expect "inizio dell'ascolto annotato" "1|disco sdb 20480|rete 3000" \
	"$(grep -c '^inizio [0-9]' "$Q/run/ascolto.io")|$(grep '^disco' "$Q/run/ascolto.io")|$(grep '^rete' "$Q/run/ascolto.io")"
# L'ascolto e' iniziato un minuto fa. Orologio fisso (SWEETSPOT_NOW): la
# durata non dipende dal tempo reale impiegato dal test.
QNOW=1700000060
sed -i "s/^inizio .*/inizio $(( QNOW - 60 ))/" "$Q/run/ascolto.io"
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
mod=$(printf '%s' "$rap" | SWEETSPOT_TEST=1 SWEETSPOT_SYSFS=$Q/sys SWEETSPOT_PROCFS=$Q/proc SWEETSPOT_RUN=$Q/run SWEETSPOT_LOG=$Q/log 	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot 	$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-rapporto; modello_md" 2>/dev/null)
expect "rapporto: modello con piattaforma e avvisi precompilati" "1|1|1|1" 	"$(printf '%s' "$mod" | grep -c '^## Rapporto di compatibilita')|$(printf '%s' "$mod" | grep -c 'Piattaforma: ASUSTeK N550JV')|$(printf '%s' "$mod" | grep -c 'Avvisi della pagina Stato: 1')|$(printf '%s' "$mod" | grep -c '^Esito complessivo: non provato')"
expect "rapporto: modello, sei prove di formato da compilare" "6" "$(printf '%s' "$mod" | grep -c '| non provato |')"
expect "rapporto: nessun 192.168 nel testo" "0" "$(printf '%s' "$rap" | grep -c '192\.168')"
if command -v python3 > /dev/null; then
	mkdir -p "$Q/matrice"
	printf '%s\n' "$rap" > "$Q/matrice/prova.json"
	python3 "$ROOT/tools/matrice-compatibilita.py" --rapporti "$Q/matrice" --pagina "$Q/matrice.md"
	expect "matrice: una riga dal rapporto, avvisi contati" "1|1" \
		"$(grep -c '^| .*ASUSTeK N550JV' "$Q/matrice.md")|$(grep '^| .*ASUSTeK' "$Q/matrice.md" | awk -F'|' '{gsub(/ /, "", $8); print $8}')"
	expect "matrice: docs/compatibilita.md aggiornata" "0" \
		"$(python3 "$ROOT/tools/matrice-compatibilita.py" --verifica > /dev/null 2>&1; echo $?)"
else
	salta "python3"
fi

echo "Hotspot di configurazione Wi-Fi (primo avvio)"
HS=$WORK/hotspot
mkdir -p "$HS/bin"
# Comandi finti: registrano le chiamate in $HS/calls; 'ip' mostra un indirizzo
# sul Wi-Fi solo se esiste $HS/ipok; 'sleep' conta i giri e li lascia
# comandare a $HS/onsleep (cosi' i test non aspettano e hanno una fine).
cat > "$HS/bin/iw" <<'EOF'
#!/bin/sh
echo "iw $*" >> "$HS_DIR/calls"
case "$*" in
	"phy phy0 info") printf 'Wiphy phy0\n\tSupported interface modes:\n\t\t * IBSS\n\t\t * managed\n%s\n\t\t * monitor\n' "$(cat "$HS_DIR/apmode" 2>/dev/null)" ;;
	"dev wlan0 scan") printf 'BSS aa:bb:cc:00:00:01(on wlan0)\n\tsignal: -40.00 dBm\n\tSSID: Casa Rossi\nBSS aa:bb:cc:00:00:02(on wlan0)\n\tsignal: -80.00 dBm\n\tSSID: Vicino\nBSS aa:bb:cc:00:00:03(on wlan0)\n\tsignal: -60.00 dBm\n\tSSID: \n' ;;
esac
EOF
cat > "$HS/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$HS_DIR/calls"
case "$*" in
	*show*wlan0*) [ -f "$HS_DIR/ipok" ] && echo "3: wlan0    inet 192.168.1.9/24 scope global wlan0" ;;
esac
exit 0
EOF
for c in hostapd udhcpd dnsd killall flock; do
	printf '#!/bin/sh\necho "%s $*" >> "$HS_DIR/calls"\nexit 0\n' "$c" > "$HS/bin/$c"
done
# qrencode finto: registra il testo del codice e scrive un SVG (o il blocco UTF8).
cat > "$HS/bin/qrencode" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 1 ]; do
	case "$1" in -o) out=$2; shift ;; esac
	shift
done
printf '%s\n' "$1" >> "$HS_DIR/qrtesti"
if [ -n "$out" ]; then echo '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$out"; else echo "[QR]"; fi
EOF
cat > "$HS/bin/sleep" <<'EOF'
#!/bin/sh
n=$(cat "$HS_DIR/n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$HS_DIR/n"
[ -f "$HS_DIR/onsleep" ] && . "$HS_DIR/onsleep"
exit 0
EOF
cat > "$HS/net-init" <<'EOF'
#!/bin/sh
echo "S40 $*" >> "$HS_DIR/calls"
EOF
chmod +x "$HS/bin/"* "$HS/net-init"

# hs_env APMODE: computer finto con cavo scollegato e Wi-Fi spento (rfkill).
hs_env() {
	rm -rf "$HS/log" "$HS/sys" "$HS/run" "$HS/calls" "$HS/n" "$HS/onsleep" "$HS/ipok" "$HS/console" "$HS/stick" "$HS/qrtesti" "$HS/pw.visto"
	mkdir -p "$HS/stick" "$HS/run" "$HS/sys/class/net/eth0/device" "$HS/sys/class/net/wlan0/device" \
		"$HS/sys/class/net/wlan0/wireless" "$HS/sys/class/rfkill/rfkill0" "$HS/sys/class/phy"
	echo 1 > "$HS/sys/class/net/eth0/type"; echo 0 > "$HS/sys/class/net/eth0/carrier"
	echo 1 > "$HS/sys/class/net/wlan0/type"
	echo "aa:bb:cc:dd:5e:6f" > "$HS/sys/class/net/wlan0/address"
	mkdir -p "$HS/sys/class/net/wlan0/phy80211"; echo phy0 > "$HS/sys/class/net/wlan0/phy80211/name"
	echo wlan > "$HS/sys/class/rfkill/rfkill0/type"; echo 1 > "$HS/sys/class/rfkill/rfkill0/soft"
	if [ "$1" = ap ]; then echo "$(printf '\t\t * AP')" > "$HS/apmode"; else : > "$HS/apmode"; fi
	: > "$HS/calls"; : > "$HS/console"
	cp "$OVERLAY/etc/sweetspot/defaults.conf" "$HS/run/sweetspot.conf"
}
# hs_run [ATTESA]: esegue sorveglia con i comandi finti.
hs_run() {
	printf 'HOTSPOT_ATTESA=%s\n' "${1:-0}" >> "$HS/run/sweetspot.conf"
	HS_DIR=$HS SWEETSPOT_SYSFS=$HS/sys SWEETSPOT_PROCFS=$HS/proc SWEETSPOT_RUN=$HS/run \
		SWEETSPOT_LOG=$HS/log SWEETSPOT_PATH="$HS/bin:$SWEETSPOT_PATH" \
		SWEETSPOT_IW=$HS/bin/iw SWEETSPOT_IP=$HS/bin/ip SWEETSPOT_HOSTAPD=$HS/bin/hostapd \
		SWEETSPOT_UDHCPD=$HS/bin/udhcpd SWEETSPOT_DNSD=$HS/bin/dnsd SWEETSPOT_SLEEP=$HS/bin/sleep SWEETSPOT_NET_INIT=$HS/net-init \
		SWEETSPOT_CONSOLE=$HS/console SWEETSPOT_TTY=$HS/console \
		SWEETSPOT_STICK_DIR=$HS/stick SWEETSPOT_QRENCODE=$HS/bin/qrencode \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-hotspot" "${2:-sorveglia}" > /dev/null 2>&1
}
hs_calls() { grep -c "^$1" "$HS/calls"; }

# 1. Senza rete e con un adattatore AP: l'hotspot si accende, poi arriva il cavo.
hs_env ap
echo '[ "$n" -ge 3 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
hs_run
expect "hotspot: senza rete si accende su wlan0 con nome dal MAC" "1|1" \
	"$(grep -c 'hotspot: acceso su wlan0, rete Sweetspot-5E6F' "$HS/log")|$(hs_calls hostapd)"
expect "hotspot: indirizzo 192.168.4.1 sulla scheda, DHCP e DNS avviati" "1|1|1" \
	"$(hs_calls 'ip addr add 192.168.4.1/24 dev wlan0')|$(hs_calls udhcpd)|$(hs_calls dnsd)"
pw=$(sed -n 's/^Password: //p' "$HS/console" | head -n 1)
expect "hotspot: password sullo schermo (16 caratteri, 80 bit), non nel registro" "1|0" \
	"$(grep -c '^Password: [a-z2-9]\{4\}\(-[a-z2-9]\{4\}\)\{3\}$' "$HS/console")|$(grep -c "$pw" "$HS/log")"
expect "hotspot: elenco reti ordinato per segnale, senza nomi vuoti" "100|Casa Rossi,Vicino" \
	"$(head -n 1 "$HS/run/wifi-scan.list" | cut -d'|' -f1)|$(cut -d'|' -f2 "$HS/run/wifi-scan.list" | tr '\n' ',' | sed 's/,$//')"
expect "hotspot: arrivato il cavo si spegne e le radio tornano spente" "1|0|1" \
	"$(grep -c 'hotspot: arrivato il cavo' "$HS/log")|$([ -e "$HS/run/hotspot.attivo" ] && echo 1 || echo 0)|$(cat "$HS/sys/class/rfkill/rfkill0/soft")"

# 2. Password scelta dall'utente in sweetspot.txt.
hs_env ap
echo 'HOTSPOT_PASSWORD=la-mia-password' >> "$HS/run/sweetspot.conf"
echo '[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
echo 'cp "$HS_DIR/run/hotspot.password" "$HS_DIR/pw.visto" 2>/dev/null' >> "$HS/onsleep"
hs_run
expect "hotspot: HOTSPOT_PASSWORD scelta dall'utente" "1" "$(grep -c '^Password: la-mia-password$' "$HS/console")"
expect "hotspot: password per la schermata grafica finche' e' acceso, poi tolta" "la-mia-password|0" \
	"$(cat "$HS/pw.visto" 2>/dev/null)|$([ -e "$HS/run/hotspot.password" ] && echo 1 || echo 0)"

# 2b. Senza schermo: nome, password e codice QR sulla partizione di avvio; la
# password resta la stessa alle accensioni successive.
hs_env ap
echo '[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
hs_run
pw1=$(sed -n 's/^Password: //p' "$HS/stick/sweetspot-hotspot.txt" | head -n 1)
expect "hotspot: nome e password scritti sulla partizione di avvio" "1|1" \
	"$(grep -c '^Rete Wi-Fi: Sweetspot-5E6F$' "$HS/stick/sweetspot-hotspot.txt")|$(printf '%s' "$pw1" | grep -c '^[a-z2-9]\{4\}\(-[a-z2-9]\{4\}\)\{3\}$')"
expect "hotspot: codice QR WIFI: sulla partizione di avvio (SVG) e sullo schermo" "1|1|1" \
	"$(sort -u "$HS/qrtesti" | grep -c "^WIFI:T:WPA;S:Sweetspot-5E6F;P:$pw1;;\$")|$(grep -c '<svg' "$HS/stick/sweetspot-hotspot.svg")|$(grep -c '^\[QR\]$' "$HS/console")"
rm -f "$HS/run/hotspot.attivo"
echo 0 > "$HS/sys/class/net/eth0/carrier"; : > "$HS/console"; rm -f "$HS/n"
hs_run
expect "hotspot: password stabile tra un'accensione e l'altra" "1" "$(grep -c "^Password: $pw1\$" "$HS/console")"
# Caratteri speciali nel QR: \ ; , : " protetti con la barra.
hs_env ap
printf '%s\n' 'HOTSPOT_PASSWORD=a;b:c,d\e12' >> "$HS/run/sweetspot.conf"
echo '[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
hs_run
expect "hotspot: QR con i caratteri speciali protetti" 'WIFI:T:WPA;S:Sweetspot-5E6F;P:a\;b\:c\,d\\e12;;' "$(head -n 1 "$HS/qrtesti")"

# 3. Cavo collegato: l'hotspot non si accende mai.
hs_env ap
echo 1 > "$HS/sys/class/net/eth0/carrier"
hs_run
expect "hotspot: con il cavo collegato non parte e la radio resta spenta" "0|0|1" \
	"$(hs_calls hostapd)|$(hs_calls iw)|$(cat "$HS/sys/class/rfkill/rfkill0/soft")"

# 4. Wi-Fi gia' collegato (indirizzo sulla scheda): niente hotspot.
hs_env ap
touch "$HS/ipok"
hs_run
expect "hotspot: Wi-Fi collegato, nessun hotspot" "0" "$(hs_calls hostapd)"

# 5. HOTSPOT=no.
hs_env ap
echo 'HOTSPOT=no' >> "$HS/run/sweetspot.conf"
hs_run
expect "hotspot: HOTSPOT=no non fa niente" "0|1" "$(hs_calls hostapd)|$(cat "$HS/sys/class/rfkill/rfkill0/soft")"

# 6. Adattatore senza modalita' AP.
hs_env noap
hs_run
expect "hotspot: adattatore senza AP, niente hotspot" "0|1" \
	"$(hs_calls hostapd)|$(grep -c 'nessun adattatore Wi-Fi capace' "$HS/log")"

# 7. Attesa: la connessione arriva prima del tempo, l'hotspot non parte.
hs_env ap
echo '[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
hs_run 60
expect "hotspot: la rete arriva durante l'attesa, nessun hotspot" "0|2" "$(hs_calls hostapd)|$(cat "$HS/n")"

# 8. Rete scelta dalla pagina ma sbagliata: l'hotspot riparte; poi quella giusta.
hs_env ap
echo 'WIFI_NOME=Casa' >> "$HS/run/sweetspot.conf"
cat > "$HS/onsleep" <<'EOF'
[ "$n" -eq 1 ] && : > "$HS_DIR/run/hotspot.richiesta"
[ "$n" -ge 12 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"
EOF
hs_run
expect "hotspot: rete salvata che non risponde, l'hotspot riparte (2 accensioni)" "1|2|1" \
	"$(grep -c 'la rete Wi-Fi non risponde' "$HS/log")|$(hs_calls hostapd)|$(hs_calls 'S40 wifi wlan0')"
hs_env ap
echo 'WIFI_NOME=Casa' >> "$HS/run/sweetspot.conf"
cat > "$HS/onsleep" <<'EOF'
[ "$n" -eq 1 ] && : > "$HS_DIR/run/hotspot.richiesta"
[ "$n" -eq 3 ] && : > "$HS_DIR/ipok"
EOF
hs_run
expect "hotspot: rete scelta che risponde, hotspot spento e sorveglianza finita" "1|1|0" \
	"$(grep -c 'collegato alla rete Wi-Fi' "$HS/log")|$(hs_calls hostapd)|$([ -e "$HS/run/hotspot.attivo" ] && echo 1 || echo 0)"

# 9. Richiesta dalla pagina (via sweetspot-priv): solo con l'hotspot acceso.
hs_env ap
rm -f "$HS/run/hotspot.attivo" "$HS/run/hotspot.richiesta"
if hs_run 0 richiesta; then rc=0; else rc=1; fi
expect "hotspot: richiesta rifiutata con l'hotspot spento" "1|0" "$rc|$([ -e "$HS/run/hotspot.richiesta" ] && echo 1 || echo 0)"
echo wlan0 > "$HS/run/hotspot.attivo"
if hs_run 0 richiesta; then rc=0; else rc=1; fi
expect "hotspot: richiesta registrata con l'hotspot acceso" "0|1" "$rc|$([ -e "$HS/run/hotspot.richiesta" ] && echo 1 || echo 0)"

# 9b. Ricerca delle reti dalla pagina con l'hotspot spento: anche con una
# scheda senza modalita' AP; senza WIFI_NOME la radio torna spenta.
hs_env noap
if hs_run 0 scansiona; then rc=0; else rc=1; fi
expect "hotspot: scansiona senza hotspot, elenco scritto e radio di nuovo spenta" "0|Casa Rossi,Vicino|1|1" \
	"$rc|$(cut -d'|' -f2 "$HS/run/wifi-scan.list" | tr '\n' ',' | sed 's/,$//')|$(hs_calls 'ip link set wlan0 up')|$(cat "$HS/sys/class/rfkill/rfkill0/soft")"
hs_env noap
echo 'WIFI_NOME=Casa' >> "$HS/run/sweetspot.conf"
hs_run 0 scansiona
expect "hotspot: scansiona con WIFI_NOME, la radio resta accesa" "0" "$(cat "$HS/sys/class/rfkill/rfkill0/soft")"
hs_env noap
rm -rf "$HS/sys/class/net/wlan0"
if hs_run 0 scansiona; then rc=0; else rc=1; fi
expect "hotspot: scansiona senza scheda Wi-Fi fallisce" "1" "$rc"

# 9c. Collegamento subito alla rete scelta dalla pagina (hotspot spento).
hs_collega() { SWEETSPOT_TEST=1 hs_run 0 collega; }
hs_env noap
if hs_collega; then rc=0; else rc=1; fi
expect "hotspot: collega senza WIFI_NOME rifiutato" "1|0" "$rc|$(hs_calls 'S40')"
hs_env ap
printf 'WIFI_NOME=Casa\n' >> "$HS/run/sweetspot.conf"
echo wlan0 > "$HS/run/hotspot.attivo"
if hs_collega; then rc=0; else rc=1; fi
expect "hotspot: collega con l'hotspot acceso rifiutato (si usa richiesta)" "1|0" "$rc|$(hs_calls 'S40')"
hs_env noap
printf 'WIFI_NOME=Casa\nHOTSPOT_PROVA=4\n' >> "$HS/run/sweetspot.conf"
echo '[ "$n" -eq 2 ] && : > "$HS_DIR/ipok"' > "$HS/onsleep"
if hs_collega; then rc=0; else rc=1; fi
expect "hotspot: collega chiude il vecchio collegamento e collega la scheda" "0|1|1|1" \
	"$rc|$(hs_calls 'ip addr flush dev wlan0')|$(hs_calls 'S40 wifi wlan0')|$(grep -c 'collegato alla rete Wi-Fi scelta' "$HS/log")"
hs_env ap
printf 'WIFI_NOME=Casa\nHOTSPOT_PROVA=4\n' >> "$HS/run/sweetspot.conf"
echo '[ "$n" -ge 6 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
hs_collega
expect "hotspot: rete scelta che non risponde, senza cavo si accende l'hotspot" "1|1" \
	"$(grep -c 'la rete Wi-Fi scelta non risponde' "$HS/log")|$(hs_calls hostapd)"

# 9d. Pagina Rete: con una scheda Wi-Fi l'elenco delle reti e il collegamento.
hs_page() {
	mkdir -p "$HS/proc/sys/kernel"; echo sweetspot > "$HS/proc/sys/kernel/hostname"
	SWEETSPOT_SYSFS=$HS/sys SWEETSPOT_PROCFS=$HS/proc SWEETSPOT_RUN=$HS/run SWEETSPOT_LOG=$HS/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$HS/bin:$SWEETSPOT_PATH" \
		REQUEST_METHOD=GET QUERY_STRING="" HTTP_HOST=sweetspot.local \
		$TEST_SH "$OVERLAY/usr/share/sweetspot/www/cgi-bin/rete" 2>&1
}
hs_env noap
printf '100|Casa Rossi\n20|Vicino\n' > "$HS/run/wifi-scan.list"
echo 'WIFI_NOME=Casa Rossi' >> "$HS/run/sweetspot.conf"
out=$(hs_page)
# La rete salvata compare nel menu e nei suggerimenti del campo di Impostazioni.
expect "pagina rete: reti vicine, la salvata scelta, collega e cerca" "1|2|1|1" \
	"$(printf '%s' "$out" | grep -c 'Reti Wi-Fi vicine')|$(printf '%s' "$out" | grep -c '<option value="Casa Rossi" selected>Casa Rossi (100%) - salvata</option>')|$(printf '%s' "$out" | grep -c 'value="wifi_connetti"')|$(printf '%s' "$out" | grep -c 'value="wifi_scansiona"')"
rm -rf "$HS/sys/class/net/wlan0"
expect "pagina rete: senza scheda Wi-Fi niente elenco" "0" "$(hs_page | grep -c 'value="wifi_connetti"')"

# S40: la scheda Wi-Fi configurata si collega con il nuovo comando 'wifi'.
expect "S40sweetspot-net: comando wifi e avvio della sorveglianza" "1|1" \
	"$(grep -c 'wifi) *$' "$OVERLAY/etc/init.d/S40sweetspot-net")|$(grep -c 'sweetspot-hotspot sorveglia' "$OVERLAY/etc/init.d/S40sweetspot-net")"
expect "defaults.conf: HOTSPOT acceso di serie" "si" "$(sed -n 's/^HOTSPOT=//p' "$OVERLAY/etc/sweetspot/defaults.conf")"
for cfg in sweetspot_x86_64 sweetspot_rpi; do
	expect "$cfg: hostapd e iw nel defconfig" "2" "$(grep -c '^BR2_PACKAGE_\(HOSTAPD\|IW\)=y$' "$ROOT/configs/${cfg}_defconfig")"
done
# 10. Attesa per la schermata: quando si accende l'hotspot o finisce la prova,
# in secondi di /proc/uptime; tolta quando la sorveglianza finisce.
hs_env ap
mkdir -p "$HS/proc"; echo "100.42 5.00" > "$HS/proc/uptime"
cat > "$HS/onsleep" <<'EOF'
[ "$n" -eq 1 ] && cp "$HS_DIR/run/hotspot.attesa" "$HS_DIR/attesa.visto"
[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"
EOF
hs_run 60
expect "hotspot: attesa per la schermata (avvio), tolta alla fine" "160 avvio|0" \
	"$(cat "$HS/attesa.visto" 2>/dev/null)|$([ -e "$HS/run/hotspot.attesa" ] && echo 1 || echo 0)"
hs_env ap
mkdir -p "$HS/proc"; echo "100.42 5.00" > "$HS/proc/uptime"
echo 'WIFI_NOME=Casa' >> "$HS/run/sweetspot.conf"
cat > "$HS/onsleep" <<'EOF'
[ "$n" -eq 1 ] && cp "$HS_DIR/run/hotspot.attesa" "$HS_DIR/attesa.avvio" 2>/dev/null
[ "$n" -eq 1 ] && : > "$HS_DIR/run/hotspot.richiesta"
[ "$n" -eq 3 ] && cp "$HS_DIR/run/hotspot.attesa" "$HS_DIR/attesa.visto" && : > "$HS_DIR/ipok"
EOF
hs_run
expect "hotspot: attesa della prova della rete scelta, nessuna con l'hotspot acceso" "140 prova|no|0" \
	"$(cat "$HS/attesa.visto" 2>/dev/null)|$([ -e "$HS/attesa.avvio" ] && echo si || echo no)|$([ -e "$HS/run/hotspot.attesa" ] && echo 1 || echo 0)"

# 11. Con la schermata grafica l'annuncio non scrive sul monitor (tty1, console
# su ttyN); con la console sulla seriale li' resta.
hs_ann() { # console attiva
	hs_env ap
	: > "$HS/run/schermo.grafico"
	mkdir -p "$HS/sys/class/tty/console"; echo "$1" > "$HS/sys/class/tty/console/active"
	echo '[ "$n" -ge 2 ] && echo 1 > "$HS_DIR/sys/class/net/eth0/carrier"' > "$HS/onsleep"
	hs_run
	grep -c '^Password: ' "$HS/console"
}
expect "hotspot: schermata grafica, niente testo sul monitor; seriale si'" "0|1" \
	"$(hs_ann tty0)|$(hs_ann ttyS0)"

# Schermata (sweetspot-display): in attesa dell'hotspot il tempo che manca sta
# nel titolo, visibile anche con il codice di primo accesso.
SD=$WORK/schermo
mkdir -p "$SD/run" "$SD/proc/sys/kernel" "$SD/sys/class/net/wlan0/wireless"
echo sweetspot > "$SD/proc/sys/kernel/hostname"
echo "100.42 5.00" > "$SD/proc/uptime"
cp "$OVERLAY/etc/sweetspot/defaults.conf" "$SD/run/sweetspot.conf"
sd_testi() { # chiave [IP]
	SWEETSPOT_TEST=1 SWEETSPOT_RUN=$SD/run SWEETSPOT_PROCFS=$SD/proc SWEETSPOT_SYSFS=$SD/sys SWEETSPOT_LOG=$SD/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-display; testi '${2:-}'" 2>/dev/null | sed -n "s/^$1=//p"
}
echo "160 avvio" > "$SD/run/hotspot.attesa"
expect "schermata: hotspot in arrivo, secondi arrotondati a 10" "SENZA CAVO ARRIVA LA RETE WI-FI SWEETSPOT|Wi-Fi tra circa 60 secondi" \
	"$(sd_testi occhiello)|$(sd_testi titolo)"
echo "95 avvio" > "$SD/run/hotspot.attesa"
expect "schermata: tempo scaduto, tra pochi secondi" "Wi-Fi tra pochi secondi" "$(sd_testi titolo)"
touch "$SD/run/primo-accesso.attivo"; echo ABCD-EFGH-IJKL > "$SD/run/primo-accesso.codice"
expect "schermata: con il codice la nota porta al Wi-Fi e a 192.168.4.1" "1" "$(sd_testi codice_nota | grep -c '192.168.4.1')"
echo "130 prova" > "$SD/run/hotspot.attesa"
expect "schermata: prova della rete scelta" "PROVO LA RETE WI-FI SCELTA|Risposta tra circa 30 secondi" \
	"$(sd_testi occhiello)|$(sd_testi titolo)"
rm -f "$SD/run/hotspot.attesa"
expect "schermata: senza attesa resta 'Rete non collegata'" "Rete non collegata" "$(sd_testi titolo)"
echo "160 avvio" > "$SD/run/hotspot.attesa"
expect "schermata: con l'indirizzo l'attesa non conta" "sweetspot.local" "$(sd_testi titolo 192.168.1.20)"

expect "BusyBox: udhcpd e dnsd" "2" "$(grep -c '^CONFIG_\(UDHCPD\|DNSD\)=y$' "$ROOT/board/sweetspot/common/busybox.fragment")"

echo "Codifica UTF-8 delle pagine e portale dell'hotspot"
bad=""
for f in "$OVERLAY"/usr/share/sweetspot/www/cgi-bin/* "$OVERLAY"/usr/share/sweetspot/www/*.html "$OVERLAY"/usr/share/sweetspot/www/*.css \
	"$OVERLAY"/usr/lib/sweetspot/*.sh "$OVERLAY"/usr/bin/sweetspot-*; do
	[ -f "$f" ] || continue
	python3 -c 'import sys; sys.exit(0 if (lambda b: (b.decode("utf-8"), b[:3] != b"\xef\xbb\xbf")[1])(open(sys.argv[1], "rb").read()) else 1)' "$f" 2>/dev/null || bad="$bad ${f##*/}"
done
expect "pagine e script: tutti in UTF-8 valido, senza BOM" "" "$bad"
expect "pagine: Content-Type con charset=utf-8 e meta charset" "1|1" \
	"$(grep -c "Content-Type: text/html; charset=utf-8" "$OVERLAY/usr/lib/sweetspot/web.sh")|$(grep -c '<meta charset="utf-8">' "$OVERLAY/usr/lib/sweetspot/web.sh")"
for f in hotspot-detect.html canonical.html index.html; do
	expect "$f: meta charset utf-8" "1" "$(grep -c '<meta charset="utf-8">' "$OVERLAY/usr/share/sweetspot/www/$f")"
done
for f in hotspot-detect.html canonical.html; do
	expect "portale $f: porta alla pagina Rete dell'hotspot" "1" "$(grep -c 'url=http://192.168.4.1/cgi-bin/rete' "$OVERLAY/usr/share/sweetspot/www/$f")"
done
expect "defconfig: qrencode e avahi (QR e sweetspot.local)" "4" \
	"$(cat "$ROOT"/configs/*_defconfig | grep -c '^BR2_PACKAGE_\(LIBQRENCODE_TOOLS\|AVAHI_DAEMON\)=y$')"

echo "Condivisioni di rete: ritentativi"
RT=$WORK/rete
mkdir -p "$RT/bin" "$RT/busy" "$RT/run" "$RT/proc" "$RT/media" "$RT/musica"
: > "$RT/proc/mounts"
printf 'CONDIVISIONE_1=//192.168.1.10/Musica\nCONDIVISIONE_2=//192.168.1.10/Altra\n' > "$RT/run/sweetspot.conf"
# NAS finto: la condivisione 1 risponde dal settimo tentativo di mount in poi
# (due giri da tre versioni di protocollo), la 2 ha sempre la password sbagliata.
cat > "$RT/bin/mount.cifs" <<MOUNT
#!/bin/sh
n=\$(cat "$RT/n" 2>/dev/null || echo 0)
case "\$2" in *rete-2) echo "mount error(13): Permission denied" >&2; exit 32 ;; esac
echo \$((n + 1)) > "$RT/n"
[ "\$n" -lt 6 ] && { echo "mount error(112): Host is down" >&2; exit 32; }
exit 0
MOUNT
printf '#!/bin/sh\necho "$*" >> "%s/rescan"\n' "$RT" > "$RT/bin/lms"
printf '#!/bin/sh\nexit 0\n' > "$RT/bin/modprobe"
printf '#!/bin/sh\nexit 0\n' > "$RT/bin/flock"
printf '#!/bin/sh\nexit 1\n' > "$RT/busy/flock"
chmod +x "$RT"/bin/* "$RT"/busy/*
rete_env() { # cartella-comandi comando...
	local d=$1
	shift
	env SWEETSPOT_RUN=$RT/run SWEETSPOT_PROCFS=$RT/proc SWEETSPOT_LOG=$RT/log SWEETSPOT_PATH="$d:$RT/bin:$SWEETSPOT_PATH" \
		SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_MEDIA=$RT/media SWEETSPOT_MUSICA=$RT/musica SWEETSPOT_LMS=$RT/bin/lms \
		SWEETSPOT_RETE_MIN=0 SWEETSPOT_RETE_MAX=0 "$@"
}
printf '1|//192.168.1.10/Musica|ERRORE|server non raggiungibile\n2|//192.168.1.10/Altra|ERRORE|accesso negato: controlla utente e password\n' > "$RT/run/rete.list"
rete_env "$RT/busy" $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" ritenta > /dev/null 2>&1
expect "ritenta: con un ciclo gia' attivo non parte un doppione" "no" "$([ -f "$RT/n" ] && echo si || echo no)"
rete_env "$RT/bin" $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" ritenta > /dev/null 2>&1
expect "ritenta: la condivisione che torna viene montata" "1|//192.168.1.10/Musica|OK|montata" "$(grep '^1|' "$RT/run/rete.list")"
expect "ritenta: l'errore dell'altra resta visibile" "2|//192.168.1.10/Altra|ERRORE|accesso negato: controlla utente e password" "$(grep '^2|' "$RT/run/rete.list")"
expect "ritenta: dopo il successo chiede la scansione a Lyrion" "si" "$([ -f "$RT/rescan" ] && echo si || echo no)"
expect "ritenta: rescan solo della sorgente tornata, mai wipe" "aggiorna $RT/musica/Rete - Musica" "$(cat "$RT/rescan" 2>/dev/null)"
expect "ritenta: stato per sorgente (montata / errore + ultimo errore)" "1|montata|||0
2|errore|accesso negato: controlla utente e password||0" "$(cat "$RT/run/rete.stato" 2>/dev/null)"
RD=". $OVERLAY/usr/bin/sweetspot-rete; RETRY_MIN=30; RETRY_MAX=600"
expect "ritenta: predefiniti 10 s con tetto a 5 min" "10 20 40 80 160 300 300" \
	"$(SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$RT/run $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-rete; for t in 1 2 3 4 5 6 7; do printf '%s ' \$(retry_delay \$t); done" | tr -s ' ' | awk '{ $1=$1; print }')"

# NAS assente: stato "attesa" con prossimo tentativo; un evento di rete (sveglia)
# anticipa il giro senza aspettare i 100 s, poi il ciclo si ferma (niente polling).
rm -f "$RT/n" "$RT/rescan" "$RT/ok" "$RT/run/rete.attesa" "$RT/musica"/*
cat > "$RT/bin/mount.nfs" <<MOUNT
#!/bin/sh
[ -f "$RT/ok" ] && exit 0
echo "mount.nfs: Connection timed out" >&2
exit 32
MOUNT
chmod +x "$RT/bin/mount.nfs"
printf 'CONDIVISIONE_1=nfs://192.168.1.20/musica\n' > "$RT/run/sweetspot.conf"
printf '1|nfs://192.168.1.20/musica|ERRORE|server non raggiungibile\n' > "$RT/run/rete.list"
rete_env "$RT/bin" env SWEETSPOT_RETE_MIN=100 SWEETSPOT_RETE_MAX=100 $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" ritenta > /dev/null 2>&1 &
RPID=$!
i=0
while [ $i -lt 50 ] && ! grep -q '|attesa|' "$RT/run/rete.stato" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
expect "attesa: stato con ultimo errore e prossimo tentativo" "1|attesa|1|si" \
	"$(awk -F'|' '{ print $1 "|" $2 "|" $5 "|" ($4 > 0 ? "si" : "no") }' "$RT/run/rete.stato" 2>/dev/null)"
expect "attesa: ultimo errore riportato" "1|attesa|server non raggiungibile" "$(awk -F'|' '{ print $1 "|" $2 "|" $3 }' "$RT/run/rete.stato" 2>/dev/null)"
: > "$RT/ok"
sleep 0.3
rete_env "$RT/bin" env SWEETSPOT_SELF=/nonesiste $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" sveglia > /dev/null 2>&1
i=0
while [ $i -lt 60 ] && kill -0 $RPID 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
expect "sveglia: il ciclo anticipa il tentativo e si ferma una volta montata" "terminato|1|montata" \
	"$(kill -0 $RPID 2>/dev/null && echo attivo || echo terminato)|$(cut -d'|' -f1 "$RT/run/rete.stato")|$(cut -d'|' -f2 "$RT/run/rete.stato")"
kill $RPID 2>/dev/null
wait $RPID 2>/dev/null
expect "sveglia: nessun file di attesa residuo" "no" "$([ -f "$RT/run/rete.attesa" ] && echo si || echo no)"
expect "sveglia: rescan della sola sorgente rientrata" "aggiorna $RT/musica/Rete - musica" "$(cat "$RT/rescan" 2>/dev/null)"

# Montaggio stale: stat che non risponde -> smontato (lazy) e rimesso in attesa.
printf '#!/bin/sh\nexit 1\n' > "$RT/bin/stat"
printf '#!/bin/sh\necho "$*" >> "%s/umount.log"\n' "$RT" > "$RT/bin/umount"
chmod +x "$RT/bin/stat" "$RT/bin/umount"
printf '1|nfs://192.168.1.20/musica|OK|montata\n' > "$RT/run/rete.list"
rm -f "$RT/ok" "$RT/umount.log"
expect "stale: il montaggio che non risponde viene contato" "1" "$(rete_env "$RT/bin" env SWEETSPOT_STAT=$RT/bin/stat SWEETSPOT_UMOUNT=$RT/bin/umount $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" controlla 2>/dev/null)"
expect "stale: smontato in lazy" "-l $RT/media/rete-1" "$(cat "$RT/umount.log" 2>/dev/null)"
expect "stale: segnato in errore da rimontare" "1|errore|errore: montaggio non risponde (stale), da rimontare||0" "$(cat "$RT/run/rete.stato" 2>/dev/null)"
HOOK=$OVERLAY/usr/share/udhcpc/default.script.d/50sweetspot-rete
expect "sveglia: hook DHCP nella cartella di default.script (\$0.d), eseguibile" "si|no" \
	"$([ -x "$HOOK" ] && echo si || echo no)|$([ -e "$OVERLAY/etc/udhcpc.d/50sweetspot-rete" ] && echo si || echo no)"
rm -f "$RT/bin/stat" "$RT/bin/umount"
rm -f "$RT/musica"/* 2>/dev/null
expect "ritenta: intervalli crescenti con tetto" "30 60 120 240 480 600 600" \
	"$(SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$RT/run $TEST_SH -c "$RD; for t in 1 2 3 4 5 6 7; do printf '%s ' \$(retry_delay \$t); done" | tr -s ' ' | awk '{ $1=$1; print }')"
expect "ritenta: percorso non valido non si ritenta" "no" "$(SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$RT/run $TEST_SH -c "$RD; retryable 'percorso non valido: x' && echo si || echo no")"

echo "Renderer UPnP/DLNA"
RPL=$OVERLAY/usr/lib/sweetspot/renderer.pl
INIT=$OVERLAY/etc/init.d/S70sweetspot-renderer
expect "renderer: l'audio passa da Lyrion (playlist play), non apre il DAC" "1|0" \
	"$(grep -c "'playlist', 'play'" "$RPL")|$(grep -c 'hw:\|/dev/snd\|aplay' "$RPL")"
expect "renderer: avviato dall'init, in coda a Lyrion e al supervisore" "si|si" \
	"$([ -x "$INIT" ] && echo si || echo no)|$(grep -q 'renderer.pl' "$INIT" && echo si || echo no)"
expect "renderer: l'init gira sui core di sistema con nice" "1" "$(grep -c 'taskset.*nice -n' "$INIT")"
if command -v perl >/dev/null; then
	if out=$(perl -c "$RPL" 2>&1); then ok "renderer: perl -c"; else ko "renderer perl -c" "Syntax OK" "$out"; fi
	if command -v python3 >/dev/null; then
		if out=$(python3 "$ROOT/tests/renderer-upnp.py" 2>&1); then
			ok "renderer: SSDP, descrittore, SOAP, eventi, comandi a Lyrion"
		else
			ko "renderer UPnP" "tutte le prove superate" "$(printf '%s' "$out" | grep -v '^  ok' | tail -n 15)"
		fi
	else
		salta "python3"
	fi
else
	salta "perl"
fi
echo "SSH: dropbear sicuro"
SSHT=$WEB/ssh
rm -rf "$SSHT"; mkdir -p "$SSHT/bin" "$SSHT/stick" "$SSHT/run"
printf '#!/bin/sh\necho "$*" > "%s/args"\n' "$SSHT" > "$SSHT/bin/dropbear"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done\necho nuova > "$f"\n' > "$SSHT/bin/dropbearkey"
printf '#!/bin/sh\ncat > /dev/null\n' > "$SSHT/bin/chpasswd"
printf '#!/bin/sh\nshift 5\necho "$*" > "%s/args"\n' "$SSHT" > "$SSHT/bin/tcpsvd"
chmod +x "$SSHT/bin/"*
ssh_avvia() { # utente
	printf 'SSH=si\nSSH_PASSWORD=%s\nSSH_UTENTE=%s\n' "${2:-segretissima1}" "$1" > "$SSHT/run/sweetspot.conf"
	rm -f "$SSHT/args" "$SSHT/log"
	SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$SSHT/run SWEETSPOT_STICK_DIR=$SSHT/stick \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH=$SSHT/bin SWEETSPOT_SSH_KEYDIR=$SSHT/keys \
		SWEETSPOT_SSH_HOME=$SSHT/home SWEETSPOT_SSH_PORT=2222 SWEETSPOT_LOG=$SSHT/log \
		$TEST_SH "$OVERLAY/etc/init.d/S45sweetspot-ssh" start > /dev/null 2>&1
	# tcpsvd parte in secondo piano: si attende che scriva gli argomenti.
	i=0; while [ ! -e "$SSHT/args" ] && ! grep -q 'troppo corta' "$SSHT/log" 2> /dev/null && [ $i -lt 20 ]; do sleep 0.2; i=$((i + 1)); done
}
ssh_avvia root corta8ch
expect "ssh: password di 8 caratteri rifiutata, dropbear non parte" "no|1" 	"$([ -e "$SSHT/args" ] && echo si || echo no)|$(grep -c 'password troppo corta' "$SSHT/log")"
ssh_avvia root 123456789012
expect "ssh: password di 12 caratteri accettata" "si" "$([ -e "$SSHT/args" ] && echo si || echo no)"
printf 'SSH=si
SSH_PASSWORD=segretissima1
' > "$SSHT/run/sweetspot.conf"; rm -f "$SSHT/args"
SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$SSHT/run SWEETSPOT_STICK_DIR=$SSHT/stick 	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH=$SSHT/bin SWEETSPOT_SSH_KEYDIR=$SSHT/keys 	SWEETSPOT_SSH_HOME=$SSHT/home SWEETSPOT_LOG=$SSHT/log $TEST_SH "$OVERLAY/etc/init.d/S45sweetspot-ssh" start > /dev/null 2>&1
sleep 1
expect "ssh: utente predefinito assistenza (con -w, root escluso)" "si|assistenza" 	"$(grep -q -e ' -w' "$SSHT/args" && echo si || echo no)|$(grep -h '^SSH_UTENTE=' "$OVERLAY/etc/sweetspot/defaults.conf" | cut -d= -f2)"
ssh_avvia root
expect "ssh: senza chiavi resta la password, con limite ai tentativi" "1|1|0" \
	"$(grep -c -e '-T 3' "$SSHT/args")|$(grep -c -e '-r .*dropbear_ed25519_host_key' "$SSHT/args")|$(grep -c -e ' -s' "$SSHT/args")"
expect "ssh: chiave dell'host salvata sulla chiavetta" "nuova" "$(cat "$SSHT/stick/sweetspot-ssh-host-key" 2>/dev/null)"
rm -rf "$SSHT/keys"; echo vecchia > "$SSHT/stick/sweetspot-ssh-host-key"
ssh_avvia root
expect "ssh: chiave dell'host gia' presente riusata, non rigenerata" "vecchia" "$(cat "$SSHT/keys/dropbear_ed25519_host_key")"
echo 'ssh-ed25519 AAAA prova' > "$SSHT/stick/authorized_keys"
ssh_avvia root
expect "ssh: con chiavi password spente (-s) e per root (-g)" "1|1|ssh-ed25519 AAAA prova" \
	"$(grep -c -e ' -s' "$SSHT/args")|$(grep -c -e ' -g' "$SSHT/args")|$(cat "$SSHT/home/.ssh/authorized_keys")"
ssh_avvia assistenza
expect "ssh: utente assistenza con chiavi, root disattivato (-w), niente -g" "1|1|0" \
	"$(grep -c -e ' -s' "$SSHT/args")|$(grep -c -e ' -w' "$SSHT/args")|$(grep -c -e ' -g' "$SSHT/args")"
printf '#!/bin/sh
echo "Bad password attempt for x" >&2
' > "$SSHT/bin/dropbear"; chmod +x "$SSHT/bin/dropbear"
rm -rf "$SSHT/st"
for i in 1 2 3 4 5 6; do
	TCPREMOTEIP=10.0.0.9 SWEETSPOT_SSH_STATE=$SSHT/st SWEETSPOT_SSH_ATTESA=0 PATH=$SSHT/bin:$PATH 		$TEST_SH "$OVERLAY/usr/bin/sweetspot-ssh-conn" > /dev/null 2>&1
done
expect "ssh: errori contati per indirizzo, dopo 5 scatta il ritardo" "6" "$(cat "$SSHT/st/10.0.0.9")"
echo "Media server UPnP/DLNA"
MSD=$WEB/mediaserver
mkdir -p "$MSD/run"
printf 'NOME_PLAYER=Salotto;rm
' > "$MSD/run/sweetspot.conf"
msconf=$(SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$MSD/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf 	$TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-mediaserver; dlna_conf /musica")
expect "media server: tutta la libreria, anche dietro i collegamenti" "1|1|1" 	"$(printf '%s
' "$msconf" | grep -c '^media_dir=A,/musica$')|$(printf '%s
' "$msconf" | grep -c '^wide_links=yes$')|$(printf '%s
' "$msconf" | grep -c '^inotify=yes$')"
msif() {
	printf 'DLNA_INTERFACCE=%s
' "$1" > "$MSD/run/sweetspot.conf"
	SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$MSD/run SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf $TEST_SH -c ". $OVERLAY/usr/bin/sweetspot-mediaserver; dlna_conf /musica" | grep -c '^network_interface='
}
expect "media server: interfacce solo se valide, vuote = tutte" "1|0|0|0|0" 	"$(msif eth0,wlan0.1)|$(msif '')|$(msif 'eth0;rm')|$(msif 'eth0,,wlan0')|$(msif ',eth0')"
expect "media server: senza privilegi, nome del player ripulito" "1|1" 	"$(printf '%s
' "$msconf" | grep -c '^user=dlna$')|$(printf '%s
' "$msconf" | grep -c '^friendly_name=Salotto_rm (libreria)$')"
INIT=$OVERLAY/etc/init.d/S71sweetspot-mediaserver
expect "media server: avviato dall'init, sui core di sistema con nice" "si|1|1" 	"$([ -x "$INIT" ] && grep -q 'sweetspot-mediaserver avvia' "$INIT" && echo si || echo no)|$(grep -c 'taskset.*nice -n 19' "$OVERLAY/usr/bin/sweetspot-mediaserver")|$(grep -c '^dlna ' "$ROOT/board/sweetspot/users.txt")"
expect "media server: MiniDLNA in entrambe le immagini, l'init di Buildroot tolto" "1|1|1" 	"$(grep -c '^BR2_PACKAGE_MINIDLNA=y' "$ROOT/configs/sweetspot_x86_64_defconfig")|$(grep -c '^BR2_PACKAGE_MINIDLNA=y' "$ROOT/configs/sweetspot_rpi_defconfig")|$(grep -c 'S60minidlnad' "$ROOT/board/sweetspot/post-build.sh")"
expect "media server: mai sospeso dalla modalita' ascolto" "0" "$(grep -c 'sospendibili' "$OVERLAY/usr/bin/sweetspot-mediaserver")"
rm -rf "$MSD"
echo "Cartelle di rete: SMB 2.1 o piu', hard, NFS"
RV=$WORK/retever
mkdir -p "$RV/bin" "$RV/run" "$RV/proc" "$RV/media" "$RV/musica"
: > "$RV/proc/mounts"
printf 'CONDIVISIONE_1=//192.168.1.10/Musica\nCONDIVISIONE_2=//192.168.1.11/Vecchio\nCONDIVISIONE_2_SMB1=si\nCONDIVISIONE_3=nfs://192.168.1.12/export/musica\n' > "$RV/run/sweetspot.conf"
# NAS finto che rifiuta tutto e registra le opzioni di ogni tentativo.
printf '#!/bin/sh\necho "$@" >> "%s/cifs.log"\necho "mount error(112): Host is down" >&2\nexit 32\n' "$RV" > "$RV/bin/mount.cifs"
printf '#!/bin/sh\necho "$@" >> "%s/nfs.log"\ncase "$*" in *vers=4*) echo "mount.nfs: Connection refused" >&2; exit 32 ;; esac\nexit 0\n' "$RV" > "$RV/bin/mount.nfs"
printf '#!/bin/sh\nexit 0\n' > "$RV/bin/modprobe"
chmod +x "$RV"/bin/*
rv_env() {
	env SWEETSPOT_RUN=$RV/run SWEETSPOT_PROCFS=$RV/proc SWEETSPOT_LOG=$RV/log SWEETSPOT_PATH="$RV/bin:$SWEETSPOT_PATH" \
		SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_MEDIA=$RV/media SWEETSPOT_MUSICA=$RV/musica "$@"
}
rv_env $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" prova 1 > /dev/null 2>&1
expect "SMB: tre tentativi (default, 3.0, 2.1) senza SMB1" "3|0" "$(grep -c . "$RV/cifs.log")|$(grep -c 'vers=1' "$RV/cifs.log")"
expect "SMB: mai un tentativo sotto la 2.1" "0" "$(grep -c 'vers=2.0' "$RV/cifs.log")"
expect "SMB: montaggio hard, mai soft" "3|0" "$(grep -c 'hard' "$RV/cifs.log")|$(grep -c 'soft' "$RV/cifs.log")"
rm -f "$RV/cifs.log"
rv_env $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" prova 2 > /dev/null 2>&1
expect "SMB1 solo se richiesto per quella cartella" "4|1" "$(grep -c . "$RV/cifs.log")|$(grep -c 'vers=1.0' "$RV/cifs.log")"
res=$(rv_env $TEST_SH "$OVERLAY/usr/bin/sweetspot-rete" prova 3)
expect "NFS: montata con il client del kernel" "OK" "$res"
expect "NFS: prima la v4, poi la v3 senza lock" "2|1" "$(grep -c . "$RV/nfs.log")|$(grep -c 'vers=3,nolock' "$RV/nfs.log")"
expect "NFS: hard con timeo e retrans, in sola lettura" "2" "$(grep -c '192.168.1.12:/export/musica .*ro,hard,timeo=[0-9]*,retrans=[0-9]*' "$RV/nfs.log")"
expect "NFS: collegamento nella libreria" "si" "$([ -L "$RV/musica/Rete - musica" ] && echo si || echo no)"
nf() { SWEETSPOT_TEST=1 SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_RUN=$RV/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; $1"; }
expect "NFS: nfs://server/export" "nas.local:/export/musica" "$(nf "normalize_nfs 'nfs://nas.local/export/musica/'")"
expect "NFS: forma server:/export" "10.0.0.1:/m" "$(nf "normalize_nfs 'nfs:10.0.0.1:/m'")"
expect "NFS: senza cartella non valido" "no" "$(nf "normalize_nfs 'nfs://nas' > /dev/null && echo si || echo no")"
expect "NFS: server con caratteri strani non valido" "no" "$(nf "normalize_nfs 'nfs://a b/x' > /dev/null && echo si || echo no")"
expect "NFS: una voce SMB non e' NFS" "no" "$(nf "is_nfs //nas/Musica && echo si || echo no")"
for cfg in sweetspot_x86_64 sweetspot_rpi; do
	expect "$cfg: nfs-utils nel defconfig" "1" "$(grep -c '^BR2_PACKAGE_NFS_UTILS=y$' "$ROOT/configs/${cfg}_defconfig")"
done
expect "kernel: client NFS v3 e v4" "3" "$(grep -c '^CONFIG_NFS_\(FS\|V3\|V4\)=m$' "$ROOT/board/sweetspot/common/linux.fragment")"
expect "pannello Musica: avviso su SMB1 e scelta NFS" "si|si" "$(grep -q 'INSICURO' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/musica" && echo si || echo no)|$(grep -q 'value="nfs"' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/musica" && echo si || echo no)"

echo "Cartella Musica in rete: utente senza privilegi e file interni"
c=$(arun "ksmbd_conf /media/Musica")
case "$c" in *"read only = yes"*"guest ok = yes"*) ok "senza password: ospite in sola lettura" ;; *) ko "senza password: ospite in sola lettura" "read only = yes" "$c" ;; esac
c=$(arun "ksmbd_conf /media/Musica" "ARCHIVIO_PASSWORD=segreta")
case "$c" in *"read only = no"*"guest ok = no"*) ok "con la password: scrittura autenticata" ;; *) ko "con la password: scrittura autenticata" "read only = no" "$c" ;; esac
case "$c" in *"force user = nas"*"force group = nas"*) ok "utente non root" ;; *) ko "utente non root" "force user = nas" "$c" ;; esac
case "$c" in *root*) ko "nessun root nella condivisione" "assente" "presente" ;; *) ok "nessun root nella condivisione" ;; esac
case "$c" in *"veto files"*artwork.db*imgproxy.db*) ok "file interni (artwork.db) nascosti" ;; *) ko "file interni (artwork.db) nascosti" "veto files" "$c" ;; esac
expect "utente nas nella tabella degli utenti" "1" "$(grep -c '^nas -1 nas -1 ' "$ROOT/board/sweetspot/users.txt")"

echo "Integrita' dei sorgenti (hash fissati)"
if out=$(sh "$ROOT/scripts/inventario.sh" verifica 2>&1); then
	ok "ogni pacchetto proprio ha sha256 e nessuna esclusione"
else
	ko "hash dei pacchetti" "tutti presenti" "$out"
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
	salta "shellcheck"
fi

echo
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
verifica_salti
sh "$ROOT/tests/audio-quality.sh" || exit 1
sh "$ROOT/tests/alsa-misura.sh" || exit 1
sh "$ROOT/tests/privilegi.sh" || exit 1
sh "$ROOT/tests/renderer-limiti.sh" || exit 1
sh "$ROOT/tests/bluetooth.sh" || exit 1
sh "$ROOT/tests/accesso.sh" || exit 1
sh "$ROOT/tests/primo-accesso.sh" || exit 1
sh "$ROOT/tests/lyrion-auth.sh" || exit 1
sh "$ROOT/tests/ops-safety.sh" || exit 1
sh "$ROOT/tests/admin-operazioni.sh" || exit 1
sh "$ROOT/tests/energia.sh" || exit 1

# --- C17: follower del volume unico e niente picco al passaggio da fisso ---
VF=$WORK/volfollower
mkdir -p "$VF/run"
sleep 60 & VF_PID=$!
echo "$VF_PID" > "$VF/run/volume-follower.pid"
SWEETSPOT_VOLUME_ATTESA_FOLLOWER=0 SWEETSPOT_VOLUME_PIDFILE=$VF/run/volume-follower.pid SWEETSPOT_RUN=$VF/run SWEETSPOT_LOG=$VF/log \
	SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-volume" segui 00:11:22:33:44:55 > /dev/null 2>&1
expect "volume: con un follower vivo, un secondo segui non parte e lascia il pidfile" "$VF_PID" "$(cat "$VF/run/volume-follower.pid")"
SWEETSPOT_VOLUME_PIDFILE=$VF/run/volume-follower.pid SWEETSPOT_RUN=$VF/run SWEETSPOT_LOG=$VF/log \
	SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-volume" ferma > /dev/null 2>&1
sleep 1
kill -0 "$VF_PID" 2>/dev/null && VF_VIVO=si || VF_VIVO=no
expect "volume: ferma termina il follower e rimuove il pidfile" "no|assente" "$VF_VIVO|$([ -e "$VF/run/volume-follower.pid" ] && echo presente || echo assente)"
grep -q 'sweetspot-volume ferma' "$OVERLAY/etc/init.d/S60sweetspot-player" && ok "S60: lo stop ferma il follower del volume" || ko "S60 stop follower" "presente" "assente"

# Passaggio a caldo da fisso a software/dsp: Lyrion (a 100 in fisso) va al valore sicuro.
vsw() { # modalita' volume_iniziale prefs_fisso
	rm -f "$VF/mix" "$VF/log"
	printf '%s\n' "$2" > "$VF/vol"
	if [ "$3" = 1 ]; then : > "$VF/run/volume.fisso"; else rm -f "$VF/run/volume.fisso"; fi
	SWEETSPOT_RUN=$VF/run SWEETSPOT_LOG=$VF/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player
		PLAYER_MAC=aa:bb; PREFS_SET=0; LMS_HOST=127.0.0.1
		mode() { echo completa; }; volume_modalita() { echo $1; }; volume_effettivo() { echo x; }
		lms_get() { case \"\$3\" in connected) echo 1 ;; mixer) cat $VF/vol ;; playerpref) echo 1 ;; esac; }
		lms_json() { [ \"\$2\" = mixer ] && echo \"\$4\" > $VF/mix; return 0; }
		prefs_divergenti() { :; }; prefs_stato() { :; }
		apply_player_prefs" > /dev/null 2>&1
	cat "$VF/mix" 2>/dev/null || echo nessuno
}
expect "player: da fisso a software con Lyrion a 100 il volume scende al valore sicuro" "25" "$(vsw software 100 1)"
expect "player: da fisso a dsp con Lyrion a 100 il volume scende al valore sicuro" "25" "$(vsw dsp 100 1)"
expect "player: dopo il passaggio il volume e' sotto la soglia (<= 25)" "si" "$([ "$(vsw software 100 1)" -le 25 ] && echo si || echo no)"
expect "player: volume gia' sotto la soglia non viene toccato" "nessuno" "$(vsw software 10 1)"
# Supervisore riavviato fra fisso e software: ogni invocazione e' un processo
# nuovo, il marcatore in $RUN e' l'unica memoria. Il fisso lo lascia (digital=0).
rm -f "$VF/run/volume.fisso"
SWEETSPOT_RUN=$VF/run SWEETSPOT_LOG=$VF/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
	$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player
	PLAYER_MAC=aa:bb; PREFS_SET=0; LMS_HOST=127.0.0.1
	mode() { echo completa; }; volume_modalita() { echo fisso; }; volume_effettivo() { echo x; }
	lms_get() { case \"\$3\" in connected) echo 1 ;; mixer) echo 100 ;; playerpref) echo 0 ;; esac; }
	lms_json() { return 0; }; prefs_divergenti() { :; }; prefs_stato() { :; }
	apply_player_prefs" > /dev/null 2>&1
expect "player: il fisso applicato lascia il marcatore in RUN" "si" "$([ -f "$VF/run/volume.fisso" ] && echo si || echo no)"
rm -f "$VF/mix"; echo 100 > "$VF/vol"
SWEETSPOT_RUN=$VF/run SWEETSPOT_LOG=$VF/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_TEST=1 \
	$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-player
	PLAYER_MAC=aa:bb; PREFS_SET=0; LMS_HOST=127.0.0.1
	mode() { echo completa; }; volume_modalita() { echo software; }; volume_effettivo() { echo x; }
	lms_get() { case \"\$3\" in connected) echo 1 ;; mixer) cat $VF/vol ;; playerpref) echo 1 ;; esac; }
	lms_json() { [ \"\$2\" = mixer ] && echo \"\$4\" > $VF/mix; return 0; }
	prefs_divergenti() { :; }; prefs_stato() { :; }
	apply_player_prefs" > /dev/null 2>&1
expect "player: supervisore riavviato fra fisso e software, volume <= soglia" "25" "$(cat "$VF/mix" 2>/dev/null)"
expect "player: dopo la riduzione il marcatore e' rimosso" "no" "$([ -f "$VF/run/volume.fisso" ] && echo si || echo no)"
expect "player: avvio diretto in software (non da fisso) non tocca il volume" "nessuno" "$(vsw software 100 0)"

sh "$ROOT/tests/demone-eventi.sh" || exit 1
sh "$ROOT/tests/profili-cpu.sh" || exit 1
sh "$ROOT/tests/diario.sh" || exit 1
sh "$ROOT/tests/quota-log.sh" || exit 1
sh "$ROOT/tests/readme-allineato.sh" || exit 1
sh "$ROOT/tests/modello-minaccia.sh" || exit 1
sh "$ROOT/tests/nomi-riservati.sh" || exit 1
python3 "$ROOT/tests/audio-verification.py" || exit 1
python3 "$ROOT/tests/prova-audio-tests.py" || exit 1
python3 "$ROOT/tests/squeezelite-dff-padding.py" || exit 1
python3 "$ROOT/tests/squeezelite-strict-hw.py" || exit 1
python3 "$ROOT/tests/squeezelite-dsd-decimation.py" || exit 1
python3 "$ROOT/tests/player-avvio.py" || exit 1
python3 "$ROOT/tests/squeezelite-dither.py" || exit 1
python3 "$ROOT/tests/squeezelite-mixer-dsd.py" || exit 1
python3 "$ROOT/tests/precarica.py" || exit 1
echo "Wi-Fi: nomi e password particolari, dalla scansione a wpa.conf"
WS=$WORK/wifissid
mkdir -p "$WS/bin" "$WS/run"
# iw finto: come il vero, scrive UTF-8/emoji come \xNN e il backslash raddoppiato.
cat > "$WS/bin/iw" <<'EOF'
#!/bin/sh
printf 'BSS aa:bb:cc:00:00:01(on wlan0)\n\tsignal: -40.00 dBm\n\tSSID: Casa #2\nBSS aa:bb:cc:00:00:02(on wlan0)\n\tsignal: -50.00 dBm\n\tSSID: Caff\\xc3\\xa8 \\xf0\\x9f\\x8e\\xb5\nBSS aa:bb:cc:00:00:03(on wlan0)\n\tsignal: -60.00 dBm\n\tSSID: "Q" a\\\\b\n'
EOF
chmod +x "$WS/bin/iw"
printf '1\n' > /dev/null
echo wlan0 > "$WS/run/hotspot.attivo"
SWEETSPOT_IW=$WS/bin/iw SWEETSPOT_RUN=$WS/run SWEETSPOT_LOG=$WS/log SWEETSPOT_TEST=1 \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf $TEST_SH "$OVERLAY/usr/bin/sweetspot-hotspot" scansiona
expect "wifi scan: nomi decodificati" 'Caffè 🎵|Casa #2|"Q" a\b' \
	"$(cut -d'|' -f2- "$WS/run/wifi-scan.list" | tr '\n' '|' | sed 's/|$//')"
# wifi_conf, estratta da S40sweetspot-net, per ogni nome (prelevato dalla lista).
sed -n '/^wifi_conf() {/,/^}/p' "$OVERLAY/etc/init.d/S40sweetspot-net" > "$WS/wifi_conf.sh"
wifi_prova() { # nome password -> wpa.conf
	printf 'WIFI_NOME=%s\nWIFI_PASSWORD=%s\n' "$1" "$2" > "$WS/s.txt"
	SWEETSPOT_RUN=$WS/run SWEETSPOT_LOG=$WS/log SWEETSPOT_DEFAULTS=$WS/nessuno \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $WS/s.txt; . $WS/wifi_conf.sh; wifi_conf; cat \$RUN/wpa.conf"
}
hexs() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
while IFS= read -r nome; do
	w=$(wifi_prova "$nome" "pw")
	expect "wifi wpa.conf: ssid in esadecimale ($nome)" "ssid=$(hexs "$nome")" "$(printf '%s\n' "$w" | grep -o 'ssid=.*')"
done <<'EOF'
Casa #2
"Casa"
a\b"c
Caffè 🎵
EOF
w=$(wifi_prova 'Casa' 'pa#ss "x" \y')
expect "wifi wpa.conf: password cruda, senza escape ne' commento" 'psk="pa#ss "x" \y"' "$(printf '%s\n' "$w" | grep -o 'psk=.*')"
w=$(wifi_prova 'Casa' '')
expect "wifi wpa.conf: rete aperta" "key_mgmt=NONE" "$(printf '%s\n' "$w" | grep -o 'key_mgmt=.*')"
k=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
expect "wifi wpa.conf: chiave di 64 cifre senza virgolette" "psk=$k" "$(wifi_prova 'Casa' "$k" | grep -o 'psk=.*')"
printf '# commento\nWIFI_NOME = Casa #2 \nHOTSPOT=si # nota\n' > "$WS/n.txt"
expect "config_normalize: # solo a inizio riga per il nome Wi-Fi" "WIFI_NOME=Casa #2|HOTSPOT=si" \
	"$(SWEETSPOT_RUN=$WS/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_normalize $WS/n.txt" | tr '\n' '|' | sed 's/|$//')"
printf '\357\273\277X=1\r\nY=2\r\n' > "$WS/n.txt"
expect "config_normalize: BOM UTF-8 e CRLF non fanno perdere la prima riga" "X=1|Y=2" \
	"$(SWEETSPOT_RUN=$WS/run $TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_normalize $WS/n.txt" | tr '\n' '|' | sed 's/|$//')"

python3 "$ROOT/tests/dsp-salvataggio.py" || exit 1
python3 "$ROOT/tests/cd-salvataggio.py" || exit 1
python3 "$ROOT/tests/reference-studio.py" || exit 1
if command -v node > /dev/null 2>&1; then
	node "$ROOT/tests/studio-js.js" || exit 1
else
	salta "node"
fi
verifica_salti
# --- sweetspot-dati: ripristino fallito blocca il salvataggio (C15) ---
RF=$WORK/ripfall
mkdir -p "$RF/run" "$RF/lms/prefs" "$RF/stick/sweetspot-dati"
echo "buona" > "$RF/stick/sweetspot-dati/lyrion.tar"   # non e' un tar: ripristino fallisce
echo x > "$RF/lms/prefs/p"
rfdati() {
	SWEETSPOT_TEST=1 SWEETSPOT_RUN=$RF/run SWEETSPOT_LOG=$RF/log SWEETSPOT_LMS_DATA=$RF/lms SWEETSPOT_STICK_DIR=$RF/stick \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-dati
		stick_mount() { return 0; }; stick_umount() { :; }; space_ok() { return 0; }
		$1"
}
rfdati 'do_restore "$STICK_MNT/sweetspot-dati"'; rc=$?
expect "dati: ripristino fallito, esito non zero" 1 "$rc"
expect "dati: ripristino fallito lascia il marcatore" si "$([ -f "$RF/run/dati.ripristino-fallito" ] && echo si || echo no)"
rfdati 'do_save'; rc=$?
expect "dati: salvataggio rifiutato dopo ripristino fallito" 1 "$rc"
expect "dati: la generazione precedente resta intatta" buona "$(cat "$RF/stick/sweetspot-dati/lyrion.tar")"
expect "dati: il rifiuto e' nel registro" 1 "$(grep -c 'salvataggio rifiutato' "$RF/log")"
rm -rf "$RF/stick/sweetspot-dati"; mkdir -p "$RF/s2"; tar -cf "$RF/s2/lyrion.tar" -C "$RF/lms" prefs
rfdati "do_restore $RF/s2"; rc=$?
expect "dati: un ripristino riuscito toglie il blocco" "0 no" "$rc $([ -f "$RF/run/dati.ripristino-fallito" ] && echo si || echo no)"
# Chiavetta non letta all'avvio, poi compare: Lyrion ha un database nuovo e
# vuoto che non deve sostituire la generazione salvata.
RT=$WORK/riptardi
mkdir -p "$RT/run" "$RT/lms/prefs" "$RT/stick/sweetspot-dati"
echo "buona" > "$RT/stick/sweetspot-dati/lyrion.tar"
echo nuovo > "$RT/lms/prefs/p"
rtdati() { # esito-di-stick_mount comandi
	SWEETSPOT_TEST=1 SWEETSPOT_RUN=$RT/run SWEETSPOT_LOG=$RT/log SWEETSPOT_LMS_DATA=$RT/lms SWEETSPOT_STICK_DIR=$RT/stick \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-dati
		stick_mount() { return $1; }; stick_umount() { :; }; space_ok() { return 0; }
		$2"
}
SWEETSPOT_TEST= SWEETSPOT_RUN=$RT/run SWEETSPOT_LOG=$RT/log SWEETSPOT_LMS_DATA=$RT/lms \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-dati" assente
expect "dati: chiavetta assente all'avvio lascia il marcatore" si "$([ -f "$RT/run/dati.non-ripristinato" ] && echo si || echo no)"
rtdati 1 'do_save'; rc=$?
expect "dati: chiavetta ancora assente, salvataggio rifiutato" "1 si" "$rc $([ -f "$RT/run/dati.non-ripristinato" ] && echo si || echo no)"
rtdati 0 'do_save'; rc=$?
expect "dati: chiavetta comparsa con dati, salvataggio rifiutato" 1 "$rc"
expect "dati: chiavetta comparsa con dati, la generazione resta intatta" buona "$(cat "$RT/stick/sweetspot-dati/lyrion.tar")"
expect "dati: chiavetta comparsa con dati diventa ripristino fallito" "si no" \
	"$([ -f "$RT/run/dati.ripristino-fallito" ] && echo si || echo no) $([ -f "$RT/run/dati.non-ripristinato" ] && echo si || echo no)"
rtdati 0 'do_checkpoint'; rc=$?
expect "dati: chiavetta comparsa con dati, checkpoint rifiutato" 1 "$rc"
rm -rf "$RT/run"/* "$RT/stick/sweetspot-dati"
date +%s > "$RT/run/dati.non-ripristinato"
rtdati 0 'do_save'; rc=$?
expect "dati: chiavetta comparsa senza dati, il primo salvataggio procede" "0 no" \
	"$rc $([ -f "$RT/run/dati.non-ripristinato" ] && echo si || echo no)"
expect "dati: chiavetta comparsa senza dati, generazione scritta" si "$([ -f "$RT/stick/sweetspot-dati/lyrion.tar" ] && echo si || echo no)"

# --- Firewall dell'hotspot -----------------------------------------------------
FWR=$OVERLAY/etc/sweetspot/firewall.nft
for porta in 53 67 80 443; do
	atteso=1
	[ "$porta" = 53 ] && atteso=2 # UDP e TCP
	expect "firewall: la porta $porta e' ammessa" "$atteso" "$(grep -cE "dport \{[^}]*\b$porta\b.*accept" "$FWR")"
done
expect "firewall: solo la scheda dell'AP, il resto accept" "1|1" \
	"$(grep -c 'iifname != \$AP_IF accept' "$FWR")|$(grep -c 'policy accept' "$FWR")"
expect "firewall: Lyrion, SMB e DLNA non sono aperti" 0 "$(grep -cE '\b(9000|3483|445|8200)\b' "$FWR")"
if command -v nft > /dev/null 2>&1; then
	{ echo 'define AP_IF = "wlan0"'; cat "$FWR"; } > "$WORK/fw.nft"
	nft -c -f "$WORK/fw.nft" > /dev/null 2>&1
	expect "firewall: nft -c accetta le regole" 0 "$?"
else
	salta nft
fi
# Se nft fallisce il firewall lascia tutto aperto e lo scrive nel registro.
FWE=$WORK/fw; mkdir -p "$FWE/run"
printf '#!/bin/sh\nexit 1\n' > "$FWE/nft"; chmod +x "$FWE/nft"
SWEETSPOT_NFT=$FWE/nft SWEETSPOT_RUN=$FWE/run SWEETSPOT_LOG=$FWE/log \
	$TEST_SH "$OVERLAY/usr/bin/sweetspot-firewall" applica wlan0
rc=$?
expect "firewall: caricamento fallito, esito 0 e errore nel registro" "0|1" \
	"$rc|$(grep -c 'firewall: regole non caricate' "$FWE/log")"

# --- alsa-cdsp: frame intero nella FIFO dopo un timeout (M18) ---
if command -v gcc > /dev/null 2>&1; then
	expect "alsa-cdsp: dopo un timeout nella FIFO solo frame interi" "0" "$(sh "$ROOT/tests/alsa-cdsp-frame.sh" > "$WORK/frame.out" 2>&1; echo $?)"
else
	salta "gcc"
fi

echo "Archivio nello spazio libero: creazione ripresa dopo un taglio di corrente"
SR=$WORK/spazio
mkdir -p "$SR/bin" "$SR/dev" "$SR/run" "$SR/stick" "$SR/sys/block/sdx/queue" "$SR/sys/class/block/sdx2"
echo 512 > "$SR/sys/block/sdx/queue/logical_block_size"
echo 25165824 > "$SR/sys/block/sdx/size"
for c in sync flock blockdev sweetspot-config sweetspot-nas sweetspot-lms sweetspot-partizione; do
	printf '#!/bin/sh\nexit 0\n' > "$SR/bin/$c"
done
printf '#!/bin/sh\necho /media/archivio-finto\n' > "$SR/bin/sweetspot-dischi"
# mkfs finto: scrive il file system in un file accanto alla partizione.
printf '#!/bin/sh\necho "$*" >> "%s/mkfs.log"\n[ ! -f "%s/taglio" ] || exit 1\nfor a; do :; done\necho ext4 > "$a.fs"\n' "$SR" "$SR" > "$SR/bin/mkfs.ext4"
printf '#!/bin/sh\nfor a; do :; done\n[ -f "$a.fs" ] && echo ext4\nexit 0\n' > "$SR/bin/blkid"
# dd finto: l'azzeramento del primo MiB (a un offset di GB) non serve nel test.
printf '#!/bin/sh\ncase "$1" in if=/dev/zero) case "$*" in *seek=2*) exit 0 ;; esac ;; esac\nexec %s "$@"\n' "$(command -v dd)" > "$SR/bin/dd"
chmod +x "$SR/bin/"*
spazio_disco() { # disco finto con la sola partizione FAT32 da 1 GiB
	: > "$SR/dev/sdx2"
	rm -f "$SR/dev/sdx2.fs" "$SR/stick/sweetspot-spazio.corso" "$SR/mkfs.log" "$SR/taglio"
	dd if=/dev/zero of="$SR/dev/sdx" bs=512 count=1 2>/dev/null
	# In una subshell: common.sh cambia PATH e il resto dei test non deve vederlo.
	(. "$OVERLAY/usr/lib/sweetspot/common.sh"; mbr_entry 0 12 2048 2097152) | dd of="$SR/dev/sdx" bs=1 seek=446 conv=notrunc 2>/dev/null
	printf '\125\252' | dd of="$SR/dev/sdx" bs=1 seek=510 conv=notrunc 2>/dev/null
}
spazio() { # comandi eseguiti dopo aver incluso lo script
	SWEETSPOT_TEST=1 SWEETSPOT_PATH="$SR/bin:$SWEETSPOT_PATH" SWEETSPOT_SYSFS=$SR/sys SWEETSPOT_RUN=$SR/run \
		SWEETSPOT_LOG=$SR/log SWEETSPOT_DEV=$SR/dev SWEETSPOT_STICK_DIR=$SR/stick SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		$TEST_SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-spazio; stick_disk() { echo sdx; }; $1" 2>&1
}
spazio_disco
set -- $(spazio 'examine >/dev/null; echo $S_START $S_SIZE')
SR_START=$1 SR_SIZE=$2
echo "$SR_START" > "$SR/sys/class/block/sdx2/start"
echo "$SR_SIZE" > "$SR/sys/class/block/sdx2/size"
# Taglio dopo la tabella: il file system non viene scritto.
: > "$SR/taglio"
spazio 'job' > /dev/null
expect "spazio: dopo il taglio resta il marcatore" "$SR_START $SR_SIZE" "$(cat "$SR/stick/sweetspot-spazio.corso" 2>/dev/null)"
expect "spazio: dopo il taglio la tabella ha la seconda voce" "131 $SR_START $SR_SIZE" "$(spazio 'mbr_read $DEV/sdx | sed -n 2p')"
expect "spazio: dopo il taglio l'esame riconosce la ripresa" "si|1" "$(spazio 'examine >/dev/null && echo "si|$S_RESUME"')"
rm -f "$SR/taglio"
spazio 'job' > /dev/null
expect "spazio: la ripresa formatta" "2" "$(wc -l < "$SR/mkfs.log" | tr -d ' ')"
expect "spazio: la ripresa toglie il marcatore" no "$([ -e "$SR/stick/sweetspot-spazio.corso" ] && echo si || echo no)"
expect "spazio: la ripresa finisce" "finita" "$(cut -d'|' -f1 "$SR/run/spazio/stato")"
# Voce presente senza marcatore, o diversa dal piano: nessuna formattazione.
spazio_disco
mbr_entry 0 131 "$SR_START" "$SR_SIZE" | dd of="$SR/dev/sdx" bs=1 seek=462 conv=notrunc 2>/dev/null
expect "spazio: voce presente senza marcatore rifiutata" "no" "$(spazio 'examine | cut -d"|" -f3')"
spazio 'job' > /dev/null
expect "spazio: voce senza marcatore, nessun mkfs" no "$([ -e "$SR/mkfs.log" ] && echo si || echo no)"
echo "$SR_START $SR_SIZE" > "$SR/stick/sweetspot-spazio.corso"
mbr_entry 0 131 "$SR_START" $((SR_SIZE - 2048)) | dd of="$SR/dev/sdx" bs=1 seek=462 conv=notrunc 2>/dev/null
spazio 'job' > /dev/null
expect "spazio: voce con dimensione diversa, nessun mkfs" no "$([ -e "$SR/mkfs.log" ] && echo si || echo no)"
# Il nodo del kernel ha un inizio diverso: la tabella e' nostra, ma non si formatta.
spazio_disco
echo $((SR_START + 2048)) > "$SR/sys/class/block/sdx2/start"
spazio 'job' > /dev/null
expect "spazio: nodo con inizio diverso, nessun mkfs" no "$([ -e "$SR/mkfs.log" ] && echo si || echo no)"
expect "spazio: nodo con inizio diverso, errore" errore "$(cut -d'|' -f1 "$SR/run/spazio/stato")"

python3 "$ROOT/tests/qualifica-corpus.py" || exit 1
python3 "$ROOT/tests/prova-dop.py" || exit 1
python3 "$ROOT/tests/triage-cve.py" || exit 1
python3 "$ROOT/tests/release-gates.py"
rc=$?
# Riepilogo finale: include anche i salti successivi all'ultimo controllo.
verifica_salti
exit $rc
