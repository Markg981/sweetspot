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
# SWEETSPOT_STICK_DIR: nei test una cartella fa da chiavetta.
STICK_MNT=${SWEETSPOT_STICK_DIR:-$RUN/chiavetta}

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

# Modalita' di funzionamento:
#   completa  Lyrion Music Server (libreria, plugin, interfaccia web) e
#             player sulla stessa macchina, come Daphile (predefinita)
#   player    solo player, per un Lyrion Music Server su un altro computer
mode() {
	case "$(lower "$(conf MODALITA completa)")" in
		player|solo-player|soloplayer|squeezelite|lyrion|lms) echo player ;;
		*) echo completa ;;
	esac
}

# shellcheck disable=SC2034
MUSIC_DIR=${SWEETSPOT_MUSICA:-/musica}
# shellcheck disable=SC2034
MEDIA_DIR=${SWEETSPOT_MEDIA:-/media}
# shellcheck disable=SC2034
DATA_DIR_NAME=sweetspot-dati
# shellcheck disable=SC2034
LMS_DATA=${SWEETSPOT_LMS_DATA:-/var/lib/lms}
LMS_HOST=${SWEETSPOT_LMS_HOST:-127.0.0.1}
LMS_HTTP_PORT=${SWEETSPOT_LMS_HTTP_PORT:-9000}

# Nome di cartella leggibile e sicuro: lettere, cifre, spazi e . _ -
safe_name() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9 ._-' '_' | sed 's/^[ ._-]*//; s/[ ]*$//' | cut -c1-40
}

# Percorso di una cartella di rete nella forma //server/cartella/sotto.
# Accetta anche \\server\cartella (Windows) e smb://server/cartella.
normalize_unc() {
	local p
	p=$(printf '%s' "$1" | tr '\\' '/' | sed 's#^smb:##; s#^/*#//#; s#/*$##; s#\([^/]\)//*#\1/#g')
	case "$p" in
		//?*/?*) printf '%s' "$p" ;;
		*) return 1 ;;
	esac
}

# Il valore e' accettabile in sweetspot.txt? (niente a capo e niente
# caratteri di controllo)
valid_value() {
	[ "$(printf '%s' "$1" | tr -d '[:cntrl:]')" = "$1" ]
}

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
# Lo stream contiene il file compresso (il brano intero, se ci sta), l'output
# i campioni gia' decodificati: con un output grande la decodifica finisce
# molto prima dell'ascolto e durante la riproduzione la CPU resta ferma.
# Si lasciano 768 MB al sistema e a Lyrion; squeezelite accetta al massimo
# ~2 GB per buffer.
player_buffers() {
	local kb avail s o
	kb=$(mem_total_kb)
	avail=$((kb - 786432))
	s=$((avail / 6))
	o=$((avail / 3))
	[ "$s" -lt 32768 ] && s=32768
	[ "$o" -lt 65536 ] && o=65536
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

# --- Lyrion Music Server ------------------------------------------------------------

# Le richieste a Lyrion passano dal JSON-RPC sulla porta web: ogni richiesta
# ha la sua risposta, anche per i comandi che richiedono tempo (installazione
# di un plugin), e jq legge i risultati senza ambiguita'.

# Stringa JSON (i valori arrivano gia' privi di caratteri di controllo).
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# lms_json PLAYER PAROLA...: invia un comando a Lyrion (PLAYER vuoto per i
# comandi del server) e stampa la risposta JSON. Fallisce se non risponde.
lms_json() {
	local player=$1 args="" w out
	shift
	for w in "$@"; do args="$args${args:+,}$(json_str "$w")"; done
	out=$("${SWEETSPOT_WGET:-wget}" -q -T "${LMS_TIMEOUT:-20}" -O - --header 'Content-Type: application/json' \
		--post-data "{\"id\":1,\"method\":\"slim.request\",\"params\":[$(json_str "$player"),[$args]]}" \
		"http://$LMS_HOST:$LMS_HTTP_PORT/jsonrpc.js" 2>/dev/null) || return 1
	[ -n "$out" ] || return 1
	printf '%s\n' "$out"
}

# lms_get FILTRO PLAYER PAROLA...: valore del risultato scelto con un filtro
# jq relativo a .result (es. '._version'), vuoto se manca.
lms_get() {
	local filter=$1
	shift
	lms_json "$@" | jq -r ".result | ($filter) // empty" 2>/dev/null
}

# Lyrion risponde?
lms_ready() { [ -n "$(LMS_TIMEOUT=5 lms_get '._version' '' version '?')" ]; }

# Lyrion sta leggendo la libreria?
lms_scanning() { [ "$(lms_get '.rescan' '' rescan '?')" = 1 ]; }

# Il DAC sta suonando? (stato del flusso ALSA, vale per qualunque player)
dac_playing() { grep -qs '^state: RUNNING' "$PROC"/asound/card*/pcm*p/sub*/status; }

# Formato che arriva davvero al DAC adesso: "FORMATO FREQUENZA CANALI"
# (es. "S32_LE 96000 2"), niente se l'uscita e' chiusa.
dac_hw_now() {
	local f
	for f in "$PROC"/asound/card"$1"/pcm*p/sub*/hw_params; do
		[ -f "$f" ] || continue
		grep -q '^format:' "$f" || continue
		awk '/^format:/ {f=$2} /^rate:/ {r=$2} /^channels:/ {c=$2} END {print f, r, c}' "$f"
		return 0
	done
	return 1
}

# Bit utili di un formato ALSA (contenitore): S16_LE 16, S24_3LE 24, S32_LE 32.
alsa_bits() {
	case "$1" in
		S16*|U16*) echo 16 ;;
		S24*|U24*) echo 24 ;;
		S32*|U32*|FLOAT*) echo 32 ;;
		DSD*) echo 1 ;;
		*) echo 0 ;;
	esac
}

# Brano in riproduzione sul player indicato (MAC), in JSON: tipo, frequenza,
# bit, titolo, artista e album, piu' lo stato del player (mode).
lms_now_playing() {
	lms_json "$1" status - 1 'tags:aloITr' |
		jq -c '.result | {mode, rate: (.playlist_loop[0].samplerate // ""), bits: (.playlist_loop[0].samplesize // ""), type: (.playlist_loop[0].type // ""), title: (.playlist_loop[0].title // ""), artist: (.playlist_loop[0].artist // ""), album: (.playlist_loop[0].album // ""), bitrate: (.playlist_loop[0].bitrate // "")}' 2>/dev/null
}

# --- Chiavetta (o partizione di sistema sul disco interno) --------------------------

# La partizione da cui GRUB ha avviato Sweetspot (sweetspot.part=UUID sulla
# riga di comando): con la chiavetta ancora inserita dopo l'installazione
# sul disco interno ci sono due partizioni SWEETSPOT, e conta quella giusta.
stick_device() {
	local id
	id=$(cmdline_value sweetspot.part)
	if [ -n "$id" ]; then
		findfs "UUID=$id" 2>/dev/null && return 0
	fi
	findfs "LABEL=$STICK_LABEL" 2>/dev/null
}

# Disco che contiene la partizione di sistema (es. sdb per sdb1).
stick_disk() {
	local dev
	dev=$(stick_device) || return 1
	[ -n "$dev" ] || return 1
	part_disk "${dev##*/}"
}

part_disk() { # sdb1 -> sdb, nvme0n1p1 -> nvme0n1
	local p
	p=$(readlink -f "$SYS/class/block/$1/.." 2>/dev/null) || return 1
	[ -f "$p/size" ] && [ -d "$p/queue" ] || return 1
	echo "${p##*/}"
}

# Montaggio condiviso: chi monta la chiavetta (impostazioni, salvataggio
# dei dati, aggiornamenti) la smonta solo se nessun altro la sta usando.
# Il primo che chiede la scrittura la rimonta scrivibile. Il blocco usa il
# descrittore 6: 8 e 9 sono dei blocchi di sweetspot-dati, sweetspot-config
# e dei dischi, e riaprirli li scioglierebbe.
STICK_USERS=$RUN/chiavetta.utenti

stick_mount() { # [ro|rw]
	local dev mode=${1:-ro} n rc=0
	[ -n "${SWEETSPOT_STICK_DIR:-}" ] && { [ -d "$STICK_MNT" ]; return; }
	mkdir -p "$RUN"
	exec 6> "$RUN/chiavetta.lock"
	flock 6
	n=$(cat "$STICK_USERS" 2>/dev/null)
	if grep -q " $STICK_MNT " "$PROC/mounts" 2>/dev/null; then
		[ "$mode" = rw ] && mount -o remount,rw "$STICK_MNT" 2>/dev/null
	else
		n=0
		dev=$(stick_device)
		if [ -n "$dev" ]; then
			mkdir -p "$STICK_MNT"
			mount -t vfat -o "$mode,noatime,codepage=437,iocharset=iso8859-1" "$dev" "$STICK_MNT" 2>/dev/null || rc=1
		else
			rc=1
		fi
	fi
	[ $rc -eq 0 ] && echo $((${n:-0} + 1)) > "$STICK_USERS"
	flock -u 6
	exec 6>&-
	return $rc
}

stick_umount() {
	local n
	[ -n "${SWEETSPOT_STICK_DIR:-}" ] && return 0
	exec 6> "$RUN/chiavetta.lock"
	flock 6
	n=$(($(cat "$STICK_USERS" 2>/dev/null || echo 1) - 1))
	sync
	if [ $n -le 0 ]; then
		umount "$STICK_MNT" 2>/dev/null
		rm -f "$STICK_USERS"
	else
		echo $n > "$STICK_USERS"
	fi
	flock -u 6
	exec 6>&-
}

# --- Due copie del sistema (aggiornamenti con ritorno automatico) ----------------
#
# Sulla partizione SWEETSPOT ci sono due copie del sistema: la copia A nella
# cartella principale (bzImage, rootfs.cpio.zst), la copia B nella cartella
# b. Un aggiornamento si scrive sempre nella copia che non e' in uso; GRUB la
# prova una volta sola (variabile "prova" in boot/grub/grubenv) e, se il
# nuovo sistema non arriva a confermarsi, all'accensione successiva riparte
# la copia di prima.

GRUBENV_HEAD='# GRUB Environment Block'

running_slot() {
	case "$(cmdline_value sweetspot.slot)" in b) echo b ;; *) echo a ;; esac
}

other_slot() { if [ "$1" = b ]; then echo a; else echo b; fi; }

slot_dir() { # radice copia
	if [ "$2" = b ]; then echo "$1/b"; else echo "$1"; fi
}

grubenv_get() { # file chiave
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# grubenv_set FILE CHIAVE=VALORE... (valore vuoto = toglie la chiave).
# Il file resta di 1024 byte e si riscrive al suo posto, come fa GRUB.
grubenv_set() {
	local f=$1 kv body size
	shift
	body=$(sed -n '/^[A-Za-z_][A-Za-z0-9_]*=/p' "$f" 2>/dev/null)
	for kv; do
		body=$(printf '%s\n' "$body" | grep -v "^${kv%%=*}=")
		[ -n "${kv#*=}" ] && body=$(printf '%s\n%s' "$body" "$kv")
	done
	body=$(printf '%s\n' "$GRUBENV_HEAD" "$body" | grep -v '^$')
	size=$(printf '%s\n' "$body" | wc -c)
	[ "$size" -le 1024 ] || return 1
	{
		printf '%s\n' "$body"
		head -c $((1024 - size)) /dev/zero | tr '\0' '#'
	} > "$f.nuovo" || return 1
	if [ -f "$f" ] && [ "$(wc -c < "$f")" = 1024 ]; then
		dd if="$f.nuovo" of="$f" bs=1024 count=1 conv=notrunc,fsync 2>/dev/null || return 1
		rm -f "$f.nuovo"
	else
		mv "$f.nuovo" "$f" || return 1
	fi
	sync
}

# --- Riga di comando del kernel ---------------------------------------------------

cmdline_has() { grep -q "\(^\|[[:space:]]\)$1\([[:space:]=]\|$\)" "$PROC/cmdline" 2>/dev/null; }

cmdline_value() {
	tr ' ' '\n' < "$PROC/cmdline" 2>/dev/null | sed -n "s/^$1=//p" | tail -n 1
}

safe_mode() { cmdline_has sweetspot.sicuro || ! is_yes "$(conf OTTIMIZZAZIONI si)"; }
