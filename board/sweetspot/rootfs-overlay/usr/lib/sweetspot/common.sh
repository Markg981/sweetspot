# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - funzioni comuni per gli script di sistema.
# Compatibile con la shell di BusyBox (ash). Si include con:
#   . /usr/lib/sweetspot/common.sh
#
# SWEETSPOT_SYSFS e SWEETSPOT_PROCFS permettono ai test di usare
# un /sys e un /proc finti.

PATH=${SWEETSPOT_PATH:-/usr/sbin:/usr/bin:/sbin:/bin}:$PATH
export PATH

SYS=${SWEETSPOT_SYSFS:-/sys}
PROC=${SWEETSPOT_PROCFS:-/proc}
RUN=${SWEETSPOT_RUN:-/run/sweetspot}
CONF=$RUN/sweetspot.conf
DEFAULTS=${SWEETSPOT_DEFAULTS:-/etc/sweetspot/defaults.conf}
LOGFILE=${SWEETSPOT_LOG:-/var/log/sweetspot.log}
STICK_LABEL=SWEETSPOT
STICK_MNT=$RUN/chiavetta

log() {
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

# --- Configurazione ----------------------------------------------------------

# Legge un file di impostazioni scritto dall'utente (anche con il Blocco
# note di Windows) e stampa righe CHIAVE=valore pulite. Non esegue mai il
# contenuto del file.
config_normalize() {
	tr -d '\r' < "$1" | while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
		case "$line" in
			''|'#'*|';'*) continue ;;
			*=*) ;;
			*) continue ;;
		esac
		key=$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//' | tr 'a-z' 'A-Z')
		case "$key" in
			*[!A-Z0-9_]*|'') continue ;;
		esac
		val=${line#*=}
		case "$key" in
			*PASSWORD) ;;
			*) val=$(printf '%s' "$val" | sed 's/[[:space:]]#.*$//') ;;
		esac
		val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		case "$val" in
			\"*\") val=${val#\"}; val=${val%\"} ;;
			\'*\') val=${val#\'}; val=${val%\'} ;;
		esac
		printf '%s=%s\n' "$key" "$val"
	done
}

# Unisce le impostazioni predefinite con quelle della chiavetta.
config_build() {
	mkdir -p "$RUN"
	{
		[ -f "$DEFAULTS" ] && config_normalize "$DEFAULTS"
		[ -n "$1" ] && [ -f "$1" ] && config_normalize "$1"
	} > "$CONF.tmp"
	mv "$CONF.tmp" "$CONF"
}

# conf CHIAVE [predefinito]: l'ultima riga vince.
conf() {
	local v=""
	[ -f "$CONF" ] && v=$(grep "^$1=" "$CONF" | tail -n 1 | cut -d= -f2-)
	if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# put VALORE FILE: scrive in un file di /sys o /proc solo se esiste, in
# silenzio (non tutti i computer hanno tutte le voci).
put() {
	[ -e "$2" ] || return 1
	{ printf '%s\n' "$1" > "$2"; } 2>/dev/null
}

is_yes() {
	case "$(lower "$1")" in
		si|sì|s|yes|y|1|true|on|vero|attivo) return 0 ;;
	esac
	return 1
}

# --- Liste di CPU -------------------------------------------------------------

# "0-3,6" -> "0 1 2 3 6"
expand_list() {
	local part a b out=""
	for part in $(printf '%s' "$1" | tr ',' ' '); do
		case "$part" in
			*-*) a=${part%-*}; b=${part#*-}
			     while [ "$a" -le "$b" ]; do out="$out $a"; a=$((a + 1)); done ;;
			'') ;;
			*) out="$out $part" ;;
		esac
	done
	printf '%s' "${out# }"
}

# "0 1 2" -> "0,1,2"
join_list() { printf '%s' "$*" | tr -s ' ' | sed 's/^ //; s/ $//; s/ /,/g'; }

# Elementi di $1 presenti anche in $2 (liste separate da spazi).
intersect() {
	local x y out=""
	for x in $1; do
		for y in $2; do [ "$x" = "$y" ] && out="$out $x"; done
	done
	printf '%s' "${out# }"
}

# Elementi di $1 assenti in $2.
subtract() {
	local x y found out=""
	for x in $1; do
		found=0
		for y in $2; do [ "$x" = "$y" ] && found=1; done
		[ $found -eq 0 ] && out="$out $x"
	done
	printf '%s' "${out# }"
}

count_words() { set -- $1; echo $#; }

last_word() { set -- $1; eval "printf '%s' \"\${$#}\""; }

# --- Topologia della CPU ------------------------------------------------------

cpu_online() {
	if [ -f "$SYS/devices/system/cpu/online" ]; then
		expand_list "$(cat "$SYS/devices/system/cpu/online")"
	else
		echo 0
	fi
}

# Un solo thread per core fisico: il primo della coppia Hyper-Threading.
cpu_primary_threads() {
	local c sib first out=""
	for c in $(cpu_online); do
		sib="$SYS/devices/system/cpu/cpu$c/topology/thread_siblings_list"
		if [ -f "$sib" ]; then
			first=$(expand_list "$(cat "$sib")")
			first=${first%% *}
			[ "$first" = "$c" ] && out="$out $c"
		else
			out="$out $c"
		fi
	done
	printf '%s' "${out# }"
}

# Restituisce "on", "off", "forceoff", "notsupported" o "notimplemented".
cpu_smt_state() {
	if [ -f "$SYS/devices/system/cpu/smt/control" ]; then
		cat "$SYS/devices/system/cpu/smt/control"
	else
		echo notimplemented
	fi
}

# Core veloci (P-core) sulle CPU ibride Intel; altrimenti tutti i core.
cpu_fast_cores() {
	local prim
	prim=$(cpu_primary_threads)
	if [ -f "$SYS/devices/cpu_core/cpus" ]; then
		intersect "$prim" "$(expand_list "$(cat "$SYS/devices/cpu_core/cpus")")"
	else
		printf '%s' "$prim"
	fi
}

cpu_is_hybrid() { [ -f "$SYS/devices/cpu_core/cpus" ] && [ -f "$SYS/devices/cpu_atom/cpus" ]; }

# Calcola la disposizione dei core e imposta:
#   LAYOUT_AUDIO   core della riproduzione
#   LAYOUT_IRQ     core delle interruzioni USB del DAC
#   LAYOUT_ISO     core isolati (lista separata da spazi, vuota se nessuno)
#   LAYOUT_HK      core di sistema
#   LAYOUT_NOSMT   1 se va disattivato l'Hyper-Threading
#   LAYOUT_CORES   numero di core fisici usati
# shellcheck disable=SC2034
cpu_layout() {
	local prim fast fastnz primnz n smt
	prim=$(cpu_primary_threads)
	fast=$(cpu_fast_cores)
	n=$(count_words "$prim")
	smt=$(cpu_smt_state)
	LAYOUT_NOSMT=0
	case "$smt" in
		on|off|forceoff) [ "$n" -ge 2 ] && LAYOUT_NOSMT=1 ;;
	esac
	LAYOUT_CORES=$n
	LAYOUT_ISO=""
	# Il core 0 resta sempre al sistema: il kernel lo usa per il proprio
	# lavoro e non puo' essere isolato.
	primnz=$(subtract "$prim" 0)
	fastnz=$(subtract "$fast" 0)
	[ -n "$fastnz" ] || fastnz=$primnz
	if [ "$n" -ge 4 ]; then
		# Due core dedicati, scelti tra quelli veloci: il penultimo per la
		# riproduzione, l'ultimo per le interruzioni del controller USB.
		if [ "$(count_words "$fastnz")" -ge 2 ]; then
			LAYOUT_IRQ=$(last_word "$fastnz")
			LAYOUT_AUDIO=$(last_word "$(subtract "$fastnz" "$LAYOUT_IRQ")")
		else
			LAYOUT_AUDIO=$(last_word "$fastnz")
			LAYOUT_IRQ=$(last_word "$(subtract "$primnz" "$LAYOUT_AUDIO")")
		fi
		LAYOUT_ISO="$LAYOUT_AUDIO $LAYOUT_IRQ"
	elif [ "$n" -ge 2 ]; then
		# Due o tre core: riproduzione isolata, interruzioni con il sistema.
		LAYOUT_AUDIO=$(last_word "$fastnz")
		LAYOUT_IRQ=$(printf '%s' "$prim" | cut -d' ' -f1)
		LAYOUT_ISO=$LAYOUT_AUDIO
	else
		# Un solo core: niente isolamento, solo priorita' real-time.
		LAYOUT_AUDIO=$(printf '%s' "$prim" | cut -d' ' -f1)
		LAYOUT_IRQ=$LAYOUT_AUDIO
	fi
	LAYOUT_HK=$(subtract "$prim" "$LAYOUT_ISO")
}

cpu_has_flag() { grep -q "^flags.*[[:space:]]$1\([[:space:]]\|$\)" "$PROC/cpuinfo" 2>/dev/null; }

cpu_model() {
	sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$PROC/cpuinfo" 2>/dev/null | head -n 1
}

# --- Memoria ------------------------------------------------------------------

mem_total_kb() { sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo"; }

# Classe della macchina: leggera, essenziale, standard, completa.
machine_class() {
	local mb
	mb=$(( $(mem_total_kb) / 1024 ))
	if [ "$mb" -lt 1536 ]; then echo leggera
	elif [ "$mb" -lt 3584 ]; then echo essenziale
	elif [ "$mb" -lt 12288 ]; then echo standard
	else echo completa
	fi
}

# Buffer di squeezelite in KB: "stream:output".
# Lo stream contiene il file compresso, l'output i campioni pronti.
# Squeezelite accetta al massimo ~2 GB per buffer.
player_buffers() {
	local kb s o
	kb=$(mem_total_kb)
	s=$((kb / 8))
	o=$((kb / 4))
	[ "$s" -gt 1048576 ] && s=1048576
	[ "$o" -gt 2000000 ] && o=2000000
	[ "$(uname -m 2>/dev/null)" = "i686" ] && [ "$o" -gt 524288 ] && o=524288
	echo "$s:$o"
}

# --- DAC -------------------------------------------------------------------

# Trova la scheda audio del DAC. Stampa l'indice ALSA o niente.
# DAC=auto sceglie il primo dispositivo USB Audio; altrimenti accetta il
# nome ALSA (es. R26), l'identificativo USB (es. 292b:0a26) o parte del nome.
dac_find() {
	local want d idx id usbid name
	want=$(lower "$(conf DAC auto)")
	for d in "$PROC"/asound/card[0-9]*; do
		[ -d "$d" ] || continue
		idx=${d##*card}
		[ -f "$d/usbid" ] || continue
		id=$(cat "$d/id" 2>/dev/null)
		usbid=$(lower "$(cat "$d/usbid" 2>/dev/null)")
		name=$(lower "$(sed -n "s/^ *$idx \[[^]]*\]: *//p" "$PROC/asound/cards" 2>/dev/null)")
		case "$want" in
			auto|'') echo "$idx"; return 0 ;;
		esac
		if [ "$want" = "$(lower "$id")" ] || [ "$want" = "$usbid" ]; then
			echo "$idx"; return 0
		fi
		case "$name" in *"$want"*) echo "$idx"; return 0 ;; esac
	done
	return 1
}

dac_id() { cat "$PROC/asound/card$1/id" 2>/dev/null; }
dac_usbid() { lower "$(cat "$PROC/asound/card$1/usbid" 2>/dev/null)"; }
dac_name() {
	sed -n "s/^ *$1 \[[^]]*\]: [^ ]* - //p" "$PROC/asound/cards" 2>/dev/null | head -n 1
}

# Formati dichiarati dal DAC, es. "S32_LE DSD_U32_BE".
dac_formats() {
	cat "$PROC"/asound/card"$1"/stream* 2>/dev/null |
		sed -n 's/^[[:space:]]*Format:[[:space:]]*//p' | tr ', ' '\n\n' | grep . | sort -u | tr '\n' ' ' |
		sed 's/ $//'
}

dac_rates() {
	cat "$PROC"/asound/card"$1"/stream* 2>/dev/null |
		sed -n 's/^[[:space:]]*Rates:[[:space:]]*//p' | tr ', ' '\n\n' | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' ' |
		sed 's/ $//'
}

# Formato squeezelite per il DSD nativo (u32be, u32le, u16be, u16le, u8) o niente.
dac_native_dsd() {
	local f
	f=$(dac_formats "$1")
	case " $f " in
		*" DSD_U32_BE "*) echo u32be ;;
		*" DSD_U32_LE "*) echo u32le ;;
		*" DSD_U16_BE "*) echo u16be ;;
		*" DSD_U16_LE "*) echo u16le ;;
		*" DSD_U8 "*) echo u8 ;;
	esac
}

# Indirizzo PCI del controller USB a cui e' collegato il DAC.
dac_controller() {
	local p
	p=$(readlink -f "$SYS/class/sound/card$1/device" 2>/dev/null) || return 1
	printf '%s\n' "$p" | tr '/' '\n' |
		grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$' | tail -n 1
}

# Interruzioni del controller PCI indicato.
pci_irqs() {
	local d="$SYS/bus/pci/devices/$1"
	if [ -d "$d/msi_irqs" ] && [ -n "$(ls "$d/msi_irqs" 2>/dev/null)" ]; then
		ls "$d/msi_irqs" | sort -n | tr '\n' ' ' | sed 's/ $//'
	elif [ -f "$d/irq" ]; then
		cat "$d/irq"
	fi
}

# Dispositivo USB del DAC in /sys (per autosuspend e diagnostica).
dac_usb_device() {
	local p
	p=$(readlink -f "$SYS/class/sound/card$1/device" 2>/dev/null) || return 1
	# .../usb1/1-2/1-2:1.0 -> .../usb1/1-2
	printf '%s' "${p%/*}"
}

# --- Rete ----------------------------------------------------------------------

net_ipv4() {
	ip -4 -o addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1
}

# Indirizzo del server Lyrion a cui e' collegato il player (porta 3483).
lms_server_ip() {
	local line rem hex
	[ -f "$PROC/net/tcp" ] || return 0
	while read -r line; do
		set -- $line
		rem=$3
		[ "$4" = "01" ] || continue
		case "$rem" in
			*:0D9B)
				hex=${rem%:*}
				# /proc/net/tcp scrive l'indirizzo IPv4 in esadecimale, byte invertiti.
				printf '%d.%d.%d.%d\n' \
					"0x$(echo "$hex" | cut -c7-8)" "0x$(echo "$hex" | cut -c5-6)" \
					"0x$(echo "$hex" | cut -c3-4)" "0x$(echo "$hex" | cut -c1-2)"
				return 0 ;;
		esac
	done < "$PROC/net/tcp"
}

# --- Chiavetta ------------------------------------------------------------------

stick_device() { findfs "LABEL=$STICK_LABEL" 2>/dev/null; }

stick_mount() {
	local dev mode=${1:-ro}
	dev=$(stick_device) || return 1
	[ -n "$dev" ] || return 1
	mkdir -p "$STICK_MNT"
	mount -t vfat -o "$mode,noatime,codepage=437,iocharset=iso8859-1" "$dev" "$STICK_MNT" 2>/dev/null
}

stick_umount() {
	sync
	umount "$STICK_MNT" 2>/dev/null
}

# --- Riga di comando del kernel ---------------------------------------------------

cmdline_has() { grep -q "\(^\|[[:space:]]\)$1\([[:space:]=]\|$\)" "$PROC/cmdline" 2>/dev/null; }

cmdline_value() {
	tr ' ' '\n' < "$PROC/cmdline" 2>/dev/null | sed -n "s/^$1=//p" | tail -n 1
}

safe_mode() { cmdline_has sweetspot.sicuro || ! is_yes "$(conf OTTIMIZZAZIONI si)"; }
