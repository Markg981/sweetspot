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
# Copia di CONF senza le password (valore "*"): e' quella che leggono le
# pagine web, che girano come utente "web" e non devono vedere i segreti.
CONF_WEB=$RUN/sweetspot.web
DEFAULTS=${SWEETSPOT_DEFAULTS:-/etc/sweetspot/defaults.conf}
LOGFILE=${SWEETSPOT_LOG:-/var/log/sweetspot.log}
# awk con le funzioni matematiche (curve dei filtri); nei test quello del sistema.
# shellcheck disable=SC2034
AWK=${SWEETSPOT_AWK:-awk}
STICK_LABEL=SWEETSPOT
# Server websocket di CamillaDSP, solo locale: ne leggiamo i contatori.
# shellcheck disable=SC2034
DSP_PORTA=${SWEETSPOT_DSP_PORTA:-1234}
# Pipe da cui CamillaDSP legge i campioni (stdin): vi scrive il plugin cdsp.
# shellcheck disable=SC2034
DSP_FIFO=${SWEETSPOT_DSP_FIFO:-$RUN/camilladsp.fifo}
# SWEETSPOT_STICK_DIR: nei test una cartella fa da chiavetta.
STICK_MNT=${SWEETSPOT_STICK_DIR:-$RUN/chiavetta}

log() {
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
	evento_da_log "$*"
}

# --- Timeline degli eventi ---------------------------------------------------
# Una riga per fatto: DATA|SORGENTE|EVENTO|DETTAGLI, in RAM. La copia sulla
# chiavetta la fa sweetspot-diario (a intervalli lunghi e sugli eventi
# critici), che sorveglia anche XRUN e cambi di frequenza.
TIMELINE=${SWEETSPOT_TIMELINE:-$RUN/timeline.log}
# Presente = c'e' un evento critico da portare sulla chiavetta.
DIARIO_FLAG=$RUN/diario.urgente

evento() { # sorgente evento [dettagli]
	local det
	[ -n "${SWEETSPOT_EVENTO_MUTO:-}" ] && return 0
	det=$(printf '%s' "${3:-}" | tr '\n\r|' '   ')
	mkdir -p "$(dirname "$TIMELINE")" 2>/dev/null
	printf '%s|%s|%s|%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$det" >> "$TIMELINE" 2>/dev/null
	case "$2" in
		spegnimento|riavvio*|aggiornamento*|rollback*|errore*|panic*) : > "$DIARIO_FLAG" 2>/dev/null ;;
	esac
	case "$2" in riavvio-*) restart_conta "$1" ;; esac
	return 0
}

# Restart per componente: un contatore in RAM per sorgente (lyrion, player,
# liveness...), che non si perde quando la timeline viene troncata dalla quota.
restart_conta() { # sorgente
	local f n
	case "$1" in ''|*[!a-z0-9_-]*) return 0 ;; esac
	f=$RUN/restart.$1
	n=$(cat "$f" 2>/dev/null)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	echo $((n + 1)) > "$f" 2>/dev/null
	return 0
}

# Le righe del registro che sono anche fatti della timeline (aggiornamenti,
# rollback, riavvii della liveness e del sistema): un solo punto, cosi' gli
# script che le scrivono non cambiano.
evento_da_log() {
	local msg=${1#*: }
	case "$1" in
		aggiornamento:*)
			case "$1" in
				*"alla precedente"*|*"parte la copia"*|*"riavvii consecutivi"*) evento aggiorna rollback "$msg" ;;
				*) evento aggiorna aggiornamento "$msg" ;;
			esac ;;
		liveness:*)
			case "$1" in
				*"riavvio squeezelite"*) evento liveness riavvio-player "$msg" ;;
				*"Lyrion in stallo"*|*"kill -9"*) evento liveness riavvio-lyrion "$msg" ;;
				*) evento liveness avviso "$msg" ;;
			esac ;;
		lyrion:*)
			case "$1" in
				*"fermo"*) evento lyrion riavvio-lyrion "$msg" ;;
				*"riavvio richiesto"*) evento lyrion riavvio-richiesto "$msg" ;;
				*"avvio sui core"*) evento lyrion avvio "$msg" ;;
			esac ;;
		player:*)
			case "$1" in
				*"riavvio del player"*|*"terminato subito"*) evento player riavvio-player "$msg" ;;
				*) evento player stato "$msg" ;;
			esac ;;
		riavvio:*) evento sistema riavvio "$msg" ;;
		watchdog:*) evento watchdog avviso "$msg" ;;
	esac
	return 0
}

# --- Configurazione ----------------------------------------------------------

# Legge un file di impostazioni scritto dall'utente (anche con il Blocco
# note di Windows) e stampa righe CHIAVE=valore pulite. Non esegue mai il
# contenuto del file.
config_normalize() {
	# Il Blocco note puo' salvare con il BOM UTF-8 (EF BB BF): senza toglierlo
	# la prima chiave non sarebbe valida e la riga andrebbe persa. Il BOM e'
	# costruito con printf: il sed di BusyBox non garantisce \xHH.
	bom=$(printf '\357\273\277')
	tr -d '\r' < "$1" | while IFS= read -r line || [ -n "$line" ]; do
		line=${line#"$bom"}
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
		# Nome e password del Wi-Fi sono testo libero: '#' e virgolette fanno
		# parte del valore (per loro i commenti esistono solo a inizio riga).
		libero=
		case "$key" in
			WIFI_NOME|*PASSWORD) libero=1 ;;
			*) val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
				# Valore tutto fra virgolette (senza altre dello stesso tipo
				# dentro): e' letterale, anche con " #" o spazi ai bordi.
				# E' la forma che scrive sweetspot-config.
				case "$val" in
					\"?*\"|\'?*\')
						q=${val%"${val#?}"}
						inner=${val#?}; inner=${inner%?}
						case "$inner" in
							*"$q"*) ;;
							*) printf '%s=%s\n' "$key" "$inner"; continue ;;
						esac ;;
				esac
				val=$(printf '%s' "$val" | sed 's/[[:space:]]#.*$//') ;;
		esac
		val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$libero" ] || case "$val" in
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
	chmod 600 "$CONF.tmp"
	mv "$CONF.tmp" "$CONF"
	# Le pagine sanno solo SE una password e' impostata, non il suo valore.
	sed 's/^\([A-Z0-9_]*PASSWORD[A-Z0-9_]*\)=..*$/\1=*/' "$CONF" > "$CONF_WEB.tmp"
	chmod 644 "$CONF_WEB.tmp"
	mv "$CONF_WEB.tmp" "$CONF_WEB"
	# Il renderer UPnP gira senza root: gli basta un estratto di poche chiavi.
	mkdir -p "$RUN/renderer"
	grep -E '^(RENDERER_UPNP|MODALITA|NOME_PLAYER|LYRION_UTENTE|LYRION_PASSWORD)=' "$CONF" > "$RUN/renderer/renderer.conf.tmp"
	chmod 600 "$RUN/renderer/renderer.conf.tmp"
	chown renderer:renderer "$RUN/renderer" "$RUN/renderer/renderer.conf.tmp" 2>/dev/null
	mv "$RUN/renderer/renderer.conf.tmp" "$RUN/renderer/renderer.conf"
}

# conf CHIAVE [predefinito]: l'ultima riga vince.
# Solo comandi interni della shell (prima grep, tail e cut: quattro processi
# a ogni lettura, centinaia al minuto nei cicli dei servizi).
conf() {
	local v="" l
	if [ -f "$CONF" ]; then
		while IFS= read -r l || [ -n "$l" ]; do
			case "$l" in "$1="*) v=${l#*=} ;; esac
		done < "$CONF"
	fi
	if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# conf senza sottoshell: il valore resta in CONFV. Per i cicli dei servizi:
# "$(conf ...)" costa un fork a ogni chiamata.
confv() { # chiave [predefinito]
	local l
	CONFV=""
	if [ -f "$CONF" ]; then
		while IFS= read -r l || [ -n "$l" ]; do
			case "$l" in "$1="*) CONFV=${l#*=} ;; esac
		done < "$CONF"
	fi
	[ -n "$CONFV" ] || CONFV=$2
	return 0
}

# Attesa senza fork. nap_init apre (una volta, nel servizio) una FIFO che
# nessuno scrive sul descrittore 4; nap legge con timeout. Era "sleep": un
# processo nuovo a ogni giro di ogni ciclo, la meta' dei fork a riposo.
# Senza FIFO ripiega su sleep. Solo secondi interi. La shell di BusyBox esce
# con 1 sia allo scadere sia a un segnale con trap (che cosi' sveglia il
# ciclo): nessun ripiego su sleep dopo la read, raddoppierebbe l'attesa.
# shellcheck disable=SC3045
nap() { # secondi
	if [ "${NAP_OK:-0}" = 1 ]; then
		read -r -t "$1" _ <&4
		return 0
	else
		sleep "$1"
	fi
}
nap_init() {
	local f="${RUN:-/run/sweetspot}/nap.$$"
	NAP_OK=0
	mkdir -p "$RUN" 2>/dev/null
	mkfifo -m 600 "$f" 2>/dev/null || return 0
	exec 4<>"$f"
	NAP_OK=1
	rm -f "$f"
	return 0
}

# Profilo energetico: "fisso" (predefinito: SMT spento, stati C limitati,
# frequenza fissa) o "conservativo" (SMT attivo, stati C liberi, governor
# schedutil/ondemand). Vedi docs/profilo-energetico.md.
energia() {
	case "$(lower "$(conf ENERGIA fisso)")" in
		conservativo) echo conservativo ;;
		*) echo fisso ;;
	esac
}

# tr solo se c'e' una maiuscola (di norma i valori sono gia' minuscoli).
lower() {
	case "$1" in
		*[A-Z]*) printf '%s' "$1" | tr 'A-Z' 'a-z' ;;
		*) printf '%s' "$1" ;;
	esac
}

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

# La voce e' una cartella NFS (nfs://server/cartella)?
is_nfs() {
	case "$1" in nfs:*|NFS:*) return 0 ;; esac
	return 1
}

# Da nfs://server/export/sotto a "server:/export/sotto" (come vuole mount.nfs).
normalize_nfs() {
	local p srv dir
	p=$(printf '%s' "$1" | tr '\\' '/' | sed 's#^[nN][fF][sS]:##; s#^/*##; s#/*$##; s#//*#/#g')
	srv=${p%%[/:]*}
	dir=${p#"$srv"}
	dir=$(printf '%s' "$dir" | sed 's#^:##; s#^/*#/#')
	case "$srv" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	case "$dir" in ""|/) return 1 ;; esac
	printf '%s:%s' "$srv" "$dir"
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
	case "$1" in
		si|sì|s|yes|y|1|true|on|vero|attivo) return 0 ;;
		*[A-Z]*)
			case "$(lower "$1")" in
				si|sì|s|yes|y|1|true|on|vero|attivo) return 0 ;;
			esac ;;
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

# Interruzioni ricevute da un core da /proc/interrupts, una per riga:
# "ETICHETTA CONTEGGIO NOME" (per i dispositivi il nome e' il driver,
# per le interruzioni di sistema come LOC il nome e' vuoto).
irq_cpu_counts() { # core
	awk -v c="CPU$1" '
		NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) col = i + 1; n = NF; next }
		col && $1 ~ /:$/ && NF > n && $col ~ /^[0-9]+$/ {
			l = $1; sub(/:$/, "", l)
			name = (l ~ /^[0-9]+$/) ? $NF : ""
			print l, $col, name
		}
	' "$PROC/interrupts" 2>/dev/null
}

cpu_has_flag() { grep -q "^flags.*[[:space:]]$1\([[:space:]]\|$\)" "$PROC/cpuinfo" 2>/dev/null; }

cpu_model() {
	local m
	m=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$PROC/cpuinfo" 2>/dev/null | head -n 1)
	# ARM (Raspberry Pi): il modello sta nell'albero dei dispositivi.
	[ -n "$m" ] || m=$(tr -d '\000' < "$PROC/device-tree/model" 2>/dev/null)
	printf '%s' "$m"
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

# Protezione dall'OOM killer: oom_adj VALORE PID... scrive oom_score_adj
# (-1000 = mai ucciso, +1000 = il primo). Senza swap, sotto pressione di
# memoria il kernel uccide chi ha il punteggio piu' alto: il player deve
# essere l'ultimo, scanner e lavori sospendibili i primi. Scrive solo se il
# valore cambia; ignora in silenzio i processi gia' terminati.
oom_adj() {
	local v=$1 p
	shift
	for p in "$@"; do
		[ "$(cat "$PROC/$p/oom_score_adj" 2>/dev/null)" = "$v" ] && continue
		put "$v" "$PROC/$p/oom_score_adj"
	done
	return 0
}

# oom_adj_cmd VALORE TESTO [PADRE]: come oom_adj, per i processi la cui riga
# di comando contiene TESTO (es. scanner.pl di Lyrion, figlio del server).
# Con PADRE si guardano solo i suoi figli: il padre di ogni processo si legge
# da /proc/PID/stat con la shell, senza lanciare un comando per processo.
oom_adj_cmd() {
	local v=$1 pat=$2 parent=${3:-} d p st
	for d in "$PROC"/[0-9]*; do
		p=${d##*/}
		if [ -n "$parent" ]; then
			read -r st < "$d/stat" 2>/dev/null || continue
			st=${st##*) }   # dopo "(nome) "
			st=${st#* }     # dopo lo stato: resta "ppid ..."
			[ "${st%% *}" = "$parent" ] || continue
		fi
		[ -r "$d/cmdline" ] || continue
		case "$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)" in
			*"$pat"*) oom_adj "$v" "$p" ;;
		esac
	done
	return 0
}

# --- cgroup v2 di servizio (memoria, I/O, CPU) --------------------------------
# Lavori di fondo (checkpoint della libreria, Lyrion, scanner) in gruppi con
# limiti propri: non tolgono memoria, I/O o CPU al player. Senza cgroup v2
# (kernel senza, nessun permesso) restano nice/ionice/taskset.
CGROOT=${SWEETSPOT_CGROUP:-/sys/fs/cgroup}

# cg_make NOME [FILE=VALORE...]: crea il gruppo e scrive i limiti. Fallisce
# se cgroup v2 non c'e'; un limite che il kernel rifiuta non e' un errore.
cg_make() {
	local d=$CGROOT/$1 c kv
	shift
	[ -f "$CGROOT/cgroup.controllers" ] || return 1
	for c in cpu io memory; do
		grep -qw "$c" "$CGROOT/cgroup.controllers" 2>/dev/null || continue
		grep -qw "$c" "$CGROOT/cgroup.subtree_control" 2>/dev/null ||
			echo "+$c" >> "$CGROOT/cgroup.subtree_control" 2>/dev/null
	done
	mkdir -p "$d" 2>/dev/null || return 1
	for kv in "$@"; do
		echo "${kv#*=}" > "$d/${kv%%=*}" 2>/dev/null
	done
	return 0
}

# cg_add NOME PID...: sposta i processi nel gruppo (figli futuri compresi).
cg_add() {
	local n=$1 p
	shift
	[ -d "$CGROOT/$n" ] || return 1
	for p in "$@"; do echo "$p" >> "$CGROOT/$n/cgroup.procs" 2>/dev/null; done
	return 0
}

# Memoria totale in KB.
mem_total_kb() { sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo" 2>/dev/null; }

# mem_limit_bytes CHIAVE PERCENTUALE: limite in byte. CHIAVE (MB, solo cifre,
# "auto" o vuoto) viene dalla configurazione; auto e' la PERCENTUALE della
# memoria totale. 0 = nessun limite.
mem_limit_bytes() {
	local mb tot
	mb=$(conf "$1" auto)
	case "$mb" in
		''|auto|*[!0-9]*)
			tot=$(mem_total_kb); [ -n "$tot" ] || tot=0
			echo $((tot * 1024 / 100 * $2)) ;;
		*) echo $((mb * 1048576)) ;;
	esac
}

# bg_self NOME: il processo corrente (una subshell: ( bg_self x; ... )) e i
# suoi figli lavorano a bassa priorita': gruppo NOME con io.weight minimo,
# classe I/O idle, nice 19, solo sui core di sistema (mai quello audio).
bg_self() {
	local hk me
	# $$ e' la shell principale anche dentro una subshell: il PID della
	# subshell si legge da /proc/self (letto dalla subshell stessa).
	read -r me _ < /proc/self/stat 2> /dev/null
	case "$me" in ''|*[!0-9]*) return 0 ;; esac
	cg_make "$1" "io.weight=default 1" "cpu.weight=10" && cg_add "$1" "$me"
	command -v ionice > /dev/null 2>&1 && ionice -c 3 -p "$me" 2> /dev/null
	command -v renice > /dev/null 2>&1 && renice -n 19 -p "$me" > /dev/null 2>&1
	cpu_layout
	hk=$(join_list "$LAYOUT_HK")
	[ -n "$hk" ] || hk=$(join_list "$(cpu_online)")
	[ -n "$hk" ] && command -v taskset > /dev/null 2>&1 && taskset -p -c "$hk" "$me" > /dev/null 2>&1
	return 0
}

# Budget RAM unico (KB). Un solo posto decide come si divide la memoria fra
# chi la usa, cosi' il player e il precarico leggono le stesse quote:
#   sistema   256 MB sempre liberi per il resto del sistema (mai toccati);
#   servizi   Lyrion/catalogo/immagini/snapshot e processi di contorno: 256 MB
#             di base, +512 MB con Lyrion locale, +256 MB con la correzione DSP;
#   alsa      buffer del driver ALSA e del DAC (16 MB);
#   stream    buffer di rete di Squeezelite (il file compresso), 60 s del caso
#             peggiore (384 kHz / 32 bit / 2 canali = 3000 KB/s) ma al massimo
#             64 MB;
#   output    campioni decodificati in anticipo, 120 s ma al massimo 128 MB;
#   precarico quello che resta, per la coda in RAM (sweetspot-precarico).
# Il capitale e' la memoria DISPONIBILE (MemAvailable, non il totale) piu' cio'
# che il player (VmRSS di Squeezelite, fino ai suoi tetti) e il precarico
# (file bloccati) occupano gia': cosi' le quote non si riducono perche' le
# hanno riempite loro. Stream e output non superano meta' di quello che resta
# dopo sistema, servizi e ALSA, in proporzione 1:2; minimi 32 MB e 64 MB
# (squeezelite accetta al massimo ~2 GB per buffer).
# ram_quote_calc imposta RAM_POOL, RAM_SISTEMA, RAM_SERVIZI, RAM_ALSA,
# RAM_STREAM, RAM_OUTPUT, RAM_PRECARICO (KB), RAM_AVAIL, RAM_TOTAL, RAM_RISERVA
# e RAM_MOTIVO. Senza stampare: le funzioni che la usano non aprono sottoshell.
RAM_SISTEMA_KB=262144
RAM_ALSA_KB=16384
RAM_STREAM_MAX_KB=65536
RAM_OUTPUT_MAX_KB=131072

# KB dei file caricati con successo dal demone, non di quelli pianificati.
precarico_tenuto_kb() {
	local pid
	pid=$(cat "$RUN/precarico.tieni.pid" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -f "$RUN/precarico.stato" ] || { echo 0; return; }
	awk -F '\t' '$1 == "file" && $3 == "ok" { t += $2 } END { printf "%.0f\n", int((t + 1023) / 1024) }' \
		"$RUN/precarico.stato"
}

ram_quote_calc() {
	local avail held rss=0 pid cap smax omax rest budget
	RAM_TOTAL=$(mem_total_kb)
	avail=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo")
	# Senza MemAvailable (kernel vecchi): il totale meno 768 MB.
	[ -n "$avail" ] || avail=$((RAM_TOTAL - 786432))
	[ "$avail" -gt "$RAM_TOTAL" ] && avail=$RAM_TOTAL
	[ "$avail" -gt 0 ] || avail=0
	RAM_AVAIL=$avail
	held=$(precarico_tenuto_kb)
	pid=$(cat "$RUN/squeezelite.pid" 2>/dev/null)
	[ -n "$pid" ] && rss=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/$pid/status" 2>/dev/null)
	[ -n "$rss" ] || rss=0
	cap=$((RAM_STREAM_MAX_KB + RAM_OUTPUT_MAX_KB))
	[ "$rss" -gt "$cap" ] && rss=$cap
	RAM_POOL=$((avail + held + rss))
	RAM_SISTEMA=$RAM_SISTEMA_KB
	RAM_ALSA=$RAM_ALSA_KB
	RAM_SERVIZI=262144
	RAM_MOTIVO="servizi base"
	if [ "$(mode)" = completa ]; then
		RAM_SERVIZI=$((RAM_SERVIZI + 524288)); RAM_MOTIVO="$RAM_MOTIVO+Lyrion locale"
	fi
	if [ "$(lower "$(conf CORREZIONE no)")" != no ]; then
		RAM_SERVIZI=$((RAM_SERVIZI + 262144)); RAM_MOTIVO="$RAM_MOTIVO+DSP"
	fi
	# Cache delle copertine in RAM (tmpfs a tetto, lo scrive sweetspot-lms): il
	# suo tetto e' RAM che non va al precarico.
	local apos acap
	apos=; acap=
	[ -f "$RUN/lms.artwork.stato" ] && IFS='|' read -r apos _ acap _ < "$RUN/lms.artwork.stato"
	case "$acap" in ''|*[!0-9]*) acap=0 ;; esac
	if [ "$apos" = ram ] && [ "$acap" -gt 0 ]; then
		RAM_SERVIZI=$((RAM_SERVIZI + acap * 1024)); RAM_MOTIVO="$RAM_MOTIVO+copertine in RAM ${acap} MB"
	fi
	RAM_RISERVA=$((RAM_SISTEMA + RAM_SERVIZI + RAM_ALSA))
	rest=$((RAM_POOL - RAM_RISERVA))
	[ "$rest" -gt 0 ] || rest=0
	# PLAYER_BUFFERS_DIV: le zone (altri DAC) si dividono il budget fra loro,
	# cosi' piu' player non superano insieme quello di uno.
	budget=$((rest / 2 / ${PLAYER_BUFFERS_DIV:-1}))
	smax=$RAM_STREAM_MAX_KB
	omax=$RAM_OUTPUT_MAX_KB
	if [ "$budget" -lt $((smax + omax)) ]; then
		# Stesse proporzioni (1:2) dentro il budget.
		RAM_STREAM=$((budget / 3))
		RAM_OUTPUT=$((budget * 2 / 3))
		RAM_MOTIVO="$RAM_MOTIVO, limitati dalla memoria disponibile"
	else
		RAM_STREAM=$smax
		RAM_OUTPUT=$omax
		RAM_MOTIVO="$RAM_MOTIVO, tetti pieni (stream $((smax / 1024)) MB, output $((omax / 1024)) MB)"
	fi
	[ "$RAM_STREAM" -lt 32768 ] && RAM_STREAM=32768 && RAM_MOTIVO="$RAM_MOTIVO, stream al minimo"
	[ "$RAM_OUTPUT" -lt 65536 ] && RAM_OUTPUT=65536 && RAM_MOTIVO="$RAM_MOTIVO, output al minimo"
	RAM_PRECARICO=$((rest - RAM_STREAM - RAM_OUTPUT))
	[ "$RAM_PRECARICO" -gt 0 ] || RAM_PRECARICO=0
}

# Le quote, una per riga "nome KB" (per la diagnostica e i test).
ram_quote() {
	ram_quote_calc
	printf '%s %s\n' totale "$RAM_TOTAL" disponibile "$RAM_AVAIL" capitale "$RAM_POOL" \
		sistema "$RAM_SISTEMA" servizi "$RAM_SERVIZI" alsa "$RAM_ALSA" \
		stream "$RAM_STREAM" output "$RAM_OUTPUT" precarico "$RAM_PRECARICO"
}

# Le quote in MB come oggetto JSON (pagina Stato, diagnostica).
ram_quote_json() {
	ram_quote_calc
	printf '{"totale":%d,"disponibile":%d,"sistema":%d,"servizi":%d,"alsa":%d,"stream":%d,"output":%d,"precarico":%d}\n' \
		$((RAM_TOTAL / 1024)) $((RAM_AVAIL / 1024)) $((RAM_SISTEMA / 1024)) $((RAM_SERVIZI / 1024)) \
		$((RAM_ALSA / 1024)) $((RAM_STREAM / 1024)) $((RAM_OUTPUT / 1024)) $((RAM_PRECARICO / 1024))
}

# Buffer di squeezelite in KB: "stream:output", dalle quote di ram_quote_calc.
# Con PLAYER_BUFFERS_LOG=1 scrive nel log i valori e il motivo (lo fa il
# player all'avvio, non chi li interroga soltanto).
player_buffers() {
	ram_quote_calc
	[ -n "${PLAYER_BUFFERS_LOG:-}" ] && log "player: buffer stream ${RAM_STREAM} KB, output ${RAM_OUTPUT} KB (memoria disponibile ${RAM_AVAIL} KB di ${RAM_TOTAL} KB, riserva ${RAM_RISERVA} KB, precarico ${RAM_PRECARICO} KB: $RAM_MOTIVO)"
	echo "$RAM_STREAM:$RAM_OUTPUT"
}

# --- DAC -------------------------------------------------------------------

# Trova la scheda audio del DAC. Stampa l'indice ALSA o niente.
# DAC=auto sceglie il primo dispositivo USB Audio con playback; altrimenti accetta il
# nome ALSA (es. R26), l'identificativo USB (es. 292b:0a26) o parte del nome.
# Scheda DAC I2S del Raspberry Pi (SCHEDA_I2S = nome dell'overlay): con
# DAC=auto si usa lei, cioe' la prima scheda audio non USB che non sia
# l'uscita HDMI o il jack del Pi.
i2s_card() {
	local d id
	[ -n "$(conf SCHEDA_I2S)" ] || return 1
	for d in "$PROC"/asound/card[0-9]*; do
		[ -d "$d" ] || continue
		[ -f "$d/usbid" ] && continue
		id=$(cat "$d/id" 2>/dev/null)
		case "$id" in vc4hdmi*|Headphones|HDMI*|b1|b2|Loopback|Dummy) continue ;; esac
		[ -n "$(dac_playback_dev "${d##*card}")" ] || continue
		echo "${d##*card}"
		return 0
	done
	return 1
}

# Con gli altri DAC come zone (ALTRI_DAC=si) e DAC=auto, il DAC principale
# e' quello scelto la prima volta in questo avvio (sweetspot-player lo
# annota in $RUN/dac.principale): se viene staccato il player aspetta lui,
# non passa a un DAC di zona. Una scheda gia' zona non e' mai il principale.
# La scheda USB (indice ALSA) e' quella voluta come DAC principale?
# DAC esplicito: per nome ALSA, identificativo USB o parte del nome.
# DAC=auto: qualunque, oppure solo quella annotata in $RUN/dac.principale
# (identificativo USB e numero di serie).
dac_wanted() { # indice
	local want d idx=$1 id usbid name main
	want=$(lower "$(conf DAC auto)")
	d=$PROC/asound/card$idx
	id=$(cat "$d/id" 2>/dev/null)
	usbid=$(lower "$(cat "$d/usbid" 2>/dev/null)")
	case "$want" in
		auto|'')
			main=""
			is_yes "$(conf ALTRI_DAC no)" && main=$(cat "$RUN/dac.principale" 2>/dev/null)
			[ -z "$main" ] || [ "$main" = "$(dac_identity "$idx")" ] ;;
		*)
			[ "$want" = "$(lower "$id")" ] && return 0
			[ "$want" = "$usbid" ] && return 0
			name=$(lower "$(sed -n "s/^ *$idx \[[^]]*\]: *//p" "$PROC/asound/cards" 2>/dev/null)")
			case "$name" in *"$want"*) return 0 ;; esac
			return 1 ;;
	esac
}

# Scheda gia' in uso come zona (ALTRI_DAC=si, sweetspot-player).
dac_is_zone() { # indice
	is_yes "$(conf ALTRI_DAC no)" || return 1
	[ "$(cut -d' ' -f2 "$RUN/zone/$1" 2>/dev/null)" = "$(cat "$PROC/asound/card$1/id" 2>/dev/null)" ]
}

dac_find() {
	local want d idx
	want=$(lower "$(conf DAC auto)")
	case "$want" in auto|'') i2s_card && return 0 ;; esac
	for d in "$PROC"/asound/card[0-9]*; do
		[ -d "$d" ] || continue
		idx=${d##*card}
		[ -f "$d/usbid" ] || continue
		[ -n "$(dac_playback_dev "$idx")" ] || continue
		dac_is_zone "$idx" && continue
		dac_wanted "$idx" || continue
		echo "$idx"; return 0
	done
	return 1
}

# Numero di serie USB del DAC (vuoto se non lo dichiara): distingue due DAC
# dello stesso modello.
dac_usb_serial() {
	local p
	p=$(dac_usb_device "$1") || return 1
	cat "$p/serial" 2>/dev/null
}

# Identita' del DAC che non dipende dalla porta ne' dall'ordine di
# collegamento: identificativo USB e numero di serie (se c'e').
dac_identity() { # indice
	printf '%s %s' "$(dac_usbid "$1")" "$(dac_usb_serial "$1")"
}

# Istanza del DAC: cambia anche se la scheda ricompare con lo stesso indice e
# lo stesso id (ricollegamento rapido, reset USB). Per USB si aggiungono
# busnum e devnum del dispositivo, che il kernel riassegna a ogni enumerazione;
# per le schede senza USB (I2S) resta il solo id ALSA.
dac_instance() { # indice
	local p
	printf '%s' "$(dac_id "$1")"
	p=$(dac_usb_device "$1") || return 0
	[ -f "$p/devnum" ] || return 0
	printf ' %s:%s' "$(cat "$p/busnum" 2>/dev/null)" "$(cat "$p/devnum" 2>/dev/null)"
}

dac_id() { cat "$PROC/asound/card$1/id" 2>/dev/null; }
dac_usbid() { lower "$(cat "$PROC/asound/card$1/usbid" 2>/dev/null)"; }
dac_name() {
	sed -n "s/^ *$1 \[[^]]*\]: [^ ]* - //p" "$PROC/asound/cards" 2>/dev/null | head -n 1
}

# Primo PCM di playback della scheda (un microfono USB puo' avere solo capture).
# /proc/asound/pcm e pcmNp sono autorevoli; streamN e' il PCM N USB.
dac_playback_dev() {
	local card=$1 d p out streams=0
	d=$PROC/asound/card$card
	if [ -r "$PROC/asound/pcm" ]; then
		out=$(awk -F '[-:]' -v card="$card" '$1 + 0 == card && /playback [1-9]/ { print $2 + 0 }' "$PROC/asound/pcm" | sort -n | head -n 1)
		[ -n "$out" ] || return 1
		echo "$out"; return 0
	fi
	out=$(
		for p in "$d"/pcm[0-9]*p; do
			[ -d "$p" ] || continue
			p=${p##*/pcm}; echo "${p%p}"
		done | sort -n | head -n 1
	)
	if [ -n "$out" ]; then echo "$out"; return 0; fi
	for p in "$d"/pcm[0-9]*c; do [ ! -d "$p" ] || return 1; done
	# Compatibilita' con kernel/fixture che espongono solo i descrittori USB.
	for p in "$d"/stream[0-9]*; do
		[ -r "$p" ] || continue
		streams=1
		if grep -q '^Playback:' "$p"; then echo "${p##*stream}"; return 0; fi
	done
	# Le schede I2S senza inventario PCM non hanno descrittori USB.
	[ "$streams" = 0 ] && [ ! -f "$d/usbid" ] || return 1
	echo 0
}

# Legge solo il Playback dello stream associato al PCM selezionato. Il
# numero di canali facoltativo conserva solo gli altsetting compatibili;
# i descrittori senza Channels restano leggibili (kernel/fixture precedenti).
dac_playback_stream() { # scheda [canali]
	local dev
	dev=$(dac_playback_dev "$1") || return 1
	[ -r "$PROC/asound/card$1/stream$dev" ] || return 1
	awk -v want="${2:-}" '
		function flush() {
			if (block!="" && (want=="" || channels=="" || channels+0==want+0)) printf "%s", block
			block=""; channels=""
		}
		/^Playback:/ { playback=1; next }
		/^Capture:/ { flush(); playback=0; next }
		playback {
			if (/^[[:space:]]*Format:/) flush()
			if (/^[[:space:]]*Format:/ || block!="") block=block $0 "\n"
			if (/^[[:space:]]*Channels:/) { sub(/^[[:space:]]*Channels:[[:space:]]*/, ""); channels=$1 }
		}
		END { flush() }' "$PROC/asound/card$1/stream$dev"
}

# Senza stream USB (es. I2S), ALSA dichiara i formati prima di configurare
# il PCM. /dev/null non contiene campioni da riprodurre. L'apertura puo'
# fallire se il dispositivo e' occupato: in quel caso non si inventano capacita'.
dac_hw_params() { dac_cached hw "$1" dac_hw_params_live "$1"; }

# Le capacita' del DAC cambiano solo con l'hardware, ma ogni prova apre il PCM
# (hw:): con un DAC I2S la serie costa una ventina di aperture a ogni giro.
# Mentre il demone dello stato e' attivo (esiste dac.cache.attiva) gli esiti
# riusciti restano in $RUN/dac.cache finche' udev non segnala un evento
# "sound" (il demone svuota la cache). Senza demone niente cache.
# La chiave contiene l'identita' della scheda (id e usbid da /proc/asound),
# non solo il numero: un altro DAC nello stesso posto non riusa i dati.
#   dac_cached TIPO SCHEDA COMANDO...
dac_cached() {
	local kind=$1 card=$2 f out id='' usb=''
	shift 2
	if [ ! -f "$RUN/dac.cache.attiva" ]; then "$@"; return; fi
	read -r id < "$PROC/asound/card$card/id" 2>/dev/null
	read -r usb < "$PROC/asound/card$card/usbid" 2>/dev/null
	f=$RUN/dac.cache/$kind.$card.$id.$usb
	if [ -s "$f" ]; then cat "$f"; return 0; fi
	out=$("$@") || return 1
	[ -n "$out" ] || return 0
	# Un'apertura fallita (dispositivo occupato, o in uso: ascolto in corso)
	# non si ricorda.
	case "$kind" in hw) case "$out" in *FORMAT:*) ;; *) printf '%s\n' "$out"; return 0 ;; esac ;; esac
	if dac_playing; then printf '%s\n' "$out"; return 0; fi
	mkdir -p "$RUN/dac.cache" 2>/dev/null &&
		printf '%s\n' "$out" > "$f.nuovo" 2>/dev/null && mv "$f.nuovo" "$f"
	printf '%s\n' "$out"
}
dac_cache_purge() { rm -rf "$RUN/dac.cache"; }

dac_hw_params_live() {
	local dev id
	dev=$(dac_playback_dev "$1") || return 1
	id=$(dac_id "$1")
	LC_ALL=C "${SWEETSPOT_APLAY:-aplay}" --dump-hw-params -D "hw:CARD=$id,DEV=$dev" \
		-t raw -c 2 -f S16_LE -r 44100 /dev/null 2>&1
}

# Formati del playback selezionato, es. "S32_LE DSD_U32_BE".
dac_formats() { # scheda [canali]
	local stream
	if stream=$(dac_playback_stream "$1" "${2:-}"); then
		printf '%s\n' "$stream" | sed -n 's/^[[:space:]]*Format:[[:space:]]*//p'
	else
		dac_hw_params "$1" | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1
	fi | tr ', ' '\n\n' | grep . | sort -u | tr '\n' ' ' |
		sed 's/ $//'
}

dac_rates() { # scheda [formato ALSA] [canali]
	local stream f fmt=${2:-} id dev rate out actual
	if stream=$(dac_playback_stream "$1" "${3:-}"); then
		printf '%s\n' "$stream" | awk -v fmt="$fmt" '
			BEGIN { n=split("8000 11025 16000 22050 32000 44100 48000 88200 96000 176400 192000 352800 384000 705600 768000", standard) }
			/^[[:space:]]*Format:/ {
				sub(/^[[:space:]]*Format:[[:space:]]*/, "")
				match_format=(fmt=="" || index(" " $0 " ", " " fmt " ")>0)
			}
			/^[[:space:]]*Rates:/ && match_format {
				sub(/^[[:space:]]*Rates:[[:space:]]*/, "")
				if(/continuous/) {
					split($0, limits, /[^0-9]+/)
					for(i=1;i<=n;i++) if(standard[i]>=limits[1] && standard[i]<=limits[2]) print standard[i]
				} else {
					gsub(/,/, " "); for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i
				}
			}' | sort -n -u | tr '\n' ' ' | sed 's/ $//'
		return 0
	fi
	if [ -z "$fmt" ]; then
		f=" $(dac_formats "$1" "${3:-}") "
		case "$f" in
			*" S32_LE "*) fmt=S32_LE ;;
			*" S24_3LE "*) fmt=S24_3LE ;;
			*" S24_LE "*) fmt=S24_LE ;;
			*" S16_LE "*) fmt=S16_LE ;;
			*) return 1 ;;
		esac
	fi
	dac_cached "rates-$fmt" "$1" dac_rates_probe "$1" "$fmt"
}

dac_rates_probe() { # scheda formato
	local id dev rate out actual fmt=$2
	id=$(dac_id "$1")
	dev=$(dac_playback_dev "$1") || return 1
	# Un intervallo RATE non prova che ogni frequenza sia supportata. Prova
	# le frequenze standard sul medesimo formato e richiedi il valore esatto,
	# anche quando ALSA propone una frequenza vicina. Sempre senza campioni.
	for rate in 8000 11025 16000 22050 32000 44100 48000 88200 96000 176400 192000 352800 384000 705600 768000; do
		out=$(LC_ALL=C "${SWEETSPOT_APLAY:-aplay}" -v -D "hw:CARD=$id,DEV=$dev" \
			-t raw -c 2 -f "$fmt" -r "$rate" /dev/null 2>&1) || continue
		actual=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*rate[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
		[ "$actual" != "$rate" ] || printf '%s\n' "$rate"
	done | tr '\n' ' ' | sed 's/ $//'
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

# Margine (dB) con cui Squeezelite converte il DSD in PCM a 32 bit, chiave
# DSD_PCM_MARGINE_DB: da -24 a 0, un decimale al massimo, predefinito -3. I
# DSD "over" superano 0 dBFS fino a +3 dB (il 50% di modulazione oltre lo
# standard) e senza margine la conversione li taglierebbe; 0 = nessun margine.
dsd_margine_valido() {
	case "$1" in
		0|0.0|-0|-0.0|-[0-9]|-[0-9].[0-9]|-1[0-9]|-1[0-9].[0-9]|-2[0-3]|-2[0-3].[0-9]|-24|-24.0) return 0 ;;
	esac
	return 1
}
dsd_margine_db() {
	local v
	v=$(conf DSD_PCM_MARGINE_DB -3)
	if dsd_margine_valido "$v"; then printf '%s\n' "$v"; else echo -3; fi
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

# Come net_ipv4, con un solo processo (ip) e nessuna sottoshell aggiuntiva
# per sed e head: l'indirizzo resta in IPV4.
# shellcheck disable=SC2034  # IPV4 la legge chi chiama
net_ipv4_v() {
	local out l
	IPV4=""
	out=$(ip -4 -o addr show scope global 2>/dev/null)
	while IFS= read -r l; do
		case "$l" in *" inet "*) l=${l#* inet }; IPV4=${l%%[/ ]*}; return 0 ;; esac
	done <<EOF
$out
EOF
	return 0
}

# Indirizzo del server Lyrion a cui e' collegato il player (porta 3483).
lms_server_ip() {
	local line rem hex b1 b2 b3 b4
	[ -f "$PROC/net/tcp" ] || return 0
	while read -r line; do
		set -- $line
		rem=$3
		[ "$4" = "01" ] || continue
		case "$rem" in
			*:0D9B)
				hex=${rem%:*}
				# /proc/net/tcp scrive l'indirizzo IPv4 in esadecimale, byte invertiti.
				# Byte a byte con la sola shell (era echo|cut: 8 processi).
				b1=${hex#??????}; b2=${hex#????}; b2=${b2%??}
				b3=${hex#??}; b3=${b3%????}; b4=${hex%??????}
				printf '%d.%d.%d.%d\n' "0x$b1" "0x$b2" "0x$b3" "0x$b4"
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

# Come json_str senza processi: il testo con barra e virgolette protette (senza
# le virgolette esterne) resta in JQV. Una richiesta a Lyrion ne fa una decina.
# shellcheck disable=SC2034
json_q_v() {
	local s=$1 o='' r c
	while :; do
		case "$s" in *[\\\"]*) ;; *) break ;; esac
		r=${s%%[\\\"]*}
		o="$o$r"
		s=${s#"$r"}
		c=${s%"${s#?}"}
		s=${s#?}
		o="$o\\$c"
	done
	JQV="$o$s"
}

# lms_json PLAYER PAROLA...: invia un comando a Lyrion (PLAYER vuoto per i
# comandi del server) e stampa la risposta JSON. Fallisce se non risponde.
# Lyrion protetto da utente e password (Impostazioni > Avanzate > Sicurezza
# di Lyrion): LYRION_UTENTE e LYRION_PASSWORD in sweetspot.txt valgono per
# le richieste JSON di Sweetspot (Basic) e per la CLI (login). Senza, le
# richieste restano come prima.
lms_user() { conf LYRION_UTENTE; }
# Intestazione Basic in LMS_AUTH (vuota senza utente). Le credenziali si
# leggono con confv (nessun processo) e l'intestazione si ricalcola (base64)
# solo se cambiano: con Lyrion protetto ogni richiesta la usa, e i giri a
# riposo del player ne fanno molte. Chiamata fuori da $(...), cosi' la
# memoria resta nella shell che fa le richieste.
LMS_AUTH=''
LMS_AUTH_PER=''
LMS_AUTH_VAL=''
lms_auth_prepara() {
	local u
	confv LYRION_UTENTE
	u=$CONFV
	LMS_AUTH=''
	[ -n "$u" ] || return 0
	confv LYRION_PASSWORD
	if [ "$u:$CONFV" != "$LMS_AUTH_PER" ]; then
		LMS_AUTH_VAL="Authorization: Basic $(printf '%s:%s' "$u" "$CONFV" | base64 | tr -d '\n')"
		LMS_AUTH_PER="$u:$CONFV"
	fi
	LMS_AUTH=$LMS_AUTH_VAL
}
lms_auth_header() {
	lms_auth_prepara
	[ -z "$LMS_AUTH" ] || printf '%s' "$LMS_AUTH"
}

lms_json() { lms_json_locale "$@"; }

# Le pagine web (utente "web") la ridefiniscono in web.sh: non conoscono la
# password di Lyrion, quindi passano dall'helper privilegiato.
lms_json_locale() {
	local player=$1 tmo
	shift
	if lms_lettura "$@"; then
		tmo=${LMS_TIMEOUT:-${LMS_TIMEOUT_LETTURA:-5}}
		# Per le pagine web (LMS_WEB=1) le letture amministrative si
		# condividono per pochi secondi, senza duplicare quella in volo.
		if [ "${LMS_WEB:-0}" = 1 ] && [ "${LMS_CACHE_TTL:-3}" -gt 0 ] 2>/dev/null; then
			lms_json_cache "$tmo" "$player" "$@"
			return
		fi
	else
		tmo=${LMS_TIMEOUT:-${LMS_TIMEOUT_SCRITTURA:-10}}
		# Una scrittura cambia lo stato di Lyrion: le letture in cache non valgono piu'.
		rm -f "$RUN/lms-cache"/* 2>/dev/null
	fi
	lms_json_diretto "$tmo" "$player" "$@"
}

# Esiti distinti di lms_json (codice di uscita), per dire all'utente cosa non va
# invece di un generico "si sta avviando". Il nome e' lo stesso che finisce nello
# stato delle operazioni (campo "errore") e quindi nell'API.
#   2 non_in_esecuzione   il servizio di Lyrion non c'e'
#   3 in_avvio            il processo c'e' ma non accetta ancora connessioni
#   4 timeout             connesso ma non risponde entro il tempo previsto
#   5 applicativo         risposta vuota, non JSON o con errore RPC
#   6 occupato            troppe richieste a Lyrion in corso
lms_errore_nome() {
	case "$1" in
		2) echo non_in_esecuzione ;;
		3) echo in_avvio ;;
		4) echo timeout ;;
		5) echo applicativo ;;
		6) echo occupato ;;
		*) echo sconosciuto ;;
	esac
}
lms_errore_testo() {
	case "$1" in
		2) echo "Lyrion non è in esecuzione." ;;
		3) echo "Lyrion si sta avviando." ;;
		4) echo "Lyrion non risponde (tempo scaduto)." ;;
		5) echo "Lyrion ha risposto con un errore." ;;
		6) echo "Troppe richieste a Lyrion in corso: riprova tra poco." ;;
		*) echo "Errore sconosciuto nella richiesta a Lyrion." ;;
	esac
}

# La richiesta non cambia nulla in Lyrion? (letture: stato, versione, "?")
lms_lettura() {
	local cmd=${1:-} ultimo=""
	for ultimo in "$@"; do :; done
	case "$cmd" in
		serverstatus|status|version|players|player|syncgroups|albums|artists|genres|titles|playlists) return 0 ;;
		sweetspot) case "${2:-}" in stato|plugin-stato) return 0 ;; esac ;;
	esac
	[ "$ultimo" = '?' ]
}

# Il servizio di Lyrion e' vivo? (lo supervisiona sweetspot-lms servizio)
lms_in_esecuzione() {
	local pid
	pid=$(cat "$RUN/lms.pid" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Limite alle richieste contemporanee verso Lyrion (solo pagine web): ogni
# richiesta prende un posto (cartella creata in modo atomico con il suo pid) e
# lo rilascia a fine lavoro; i posti di processi morti si recuperano. Se non ce
# n'e' uno libero entro LMS_ATTESA_POSTO secondi la richiesta cade subito con
# l'errore "occupato" invece di accodare un altro processo bloccato.
lms_posto_prendi() {
	local fine i d p max=${LMS_MAX_CONCORRENTI:-4}
	fine=$(( $(date +%s) + ${LMS_ATTESA_POSTO:-3} ))
	mkdir -p "$RUN/lms-posti" 2>/dev/null
	while :; do
		i=1
		while [ "$i" -le "$max" ]; do
			d=$RUN/lms-posti/$i
			if mkdir "$d" 2>/dev/null; then
				echo $$ > "$d/pid"
				echo "$i"
				return 0
			fi
			p=$(cat "$d/pid" 2>/dev/null)
			if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
				rm -rf "$d"
				continue
			fi
			i=$((i + 1))
		done
		[ "$(date +%s)" -lt "$fine" ] || return 1
		sleep 0.2
	done
}

# lms_json_diretto TIMEOUT PLAYER PAROLA...: la richiesta vera, senza cache.
lms_json_diretto() {
	local tmo=$1 player=$2 args="" w out auth rc posto="" t0 t1 errf werr
	shift 2
	for w in "$@"; do json_q_v "$w"; args="$args${args:+,}\"$JQV\""; done
	json_q_v "$player"
	# Intestazione Basic gia' pronta se le credenziali non sono cambiate:
	# nessun processo per richiesta.
	lms_auth_prepara
	auth=$LMS_AUTH
	if [ "${LMS_WEB:-0}" = 1 ]; then
		posto=$(lms_posto_prendi) || return 6
	fi
	# Secondi dall'avvio (solo per misurare la durata), senza date.
	read -r t0 _ < /proc/uptime; t0=${t0%%.*}
	errf=${TMPDIR:-/tmp}/sweetspot-wget.$$
	out=$("${SWEETSPOT_WGET:-wget}" -q -T "$tmo" -O - --header 'Content-Type: application/json' \
		${auth:+--header "$auth"} \
		--post-data "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$JQV\",[$args]]}" \
		"http://$LMS_HOST:$LMS_HTTP_PORT/jsonrpc.js" 2>"$errf")
	rc=$?
	read -r t1 _ < /proc/uptime; t1=${t1%%.*}
	[ -z "$posto" ] || rm -rf "$RUN/lms-posti/$posto"
	if [ "$rc" -ne 0 ]; then
		werr=$(cat "$errf" 2>/dev/null)
		rm -f "$errf"
		# wget ha un solo codice d'uscita: i motivi si deducono dal tempo
		# impiegato (tempo scaduto), dal servizio (fermo) e dal messaggio.
		[ $((t1 - t0)) -ge "$tmo" ] && return 4
		lms_in_esecuzione || return 2
		# Connessione accettata ma nessuna risposta valida: Lyrion chiude la
		# connessione senza rispondere quando il comando fallisce (per esempio
		# una ricerca), o risponde con un errore HTTP. Non e' "in avvio".
		case "$werr" in
			*'error getting response'*|*'server returned error'*)
				log "lyrion: richiesta $1 fallita (${werr#wget: })"
				return 5 ;;
		esac
		return 3
	fi
	rm -f "$errf"
	[ -n "$out" ] || return 5
	# HTTP 200 puo' contenere un errore RPC o una pagina del proxy. Accetta
	# una sola risposta JSON con il risultato di Lyrion, senza errore.
	printf '%s\n' "$out" | jq -e -s 'length == 1 and
		(.[0] | type == "object" and .error == null and (.result | type == "object"))' > /dev/null 2>&1 || return 5
	printf '%s\n' "$out"
}

# lms_json_cache TIMEOUT PLAYER PAROLA...: lettura con cache condivisa fra le
# richieste (file in $RUN/lms-cache: riga "momento codice", poi la risposta).
# Chi arriva mentre un'altra richiesta uguale e' in volo (cartella .lock con il
# pid) aspetta il suo risultato; anche un errore resta in cache LMS_CACHE_TTL
# secondi, cosi' con Lyrion fermo o lento non si accumulano processi.
lms_json_cache() {
	local tmo=$1 f st rc now fine p out ttl=${LMS_CACHE_TTL:-3}
	f=$RUN/lms-cache/$(printf '%s\n' "$@" | cksum | cut -d' ' -f1)
	mkdir -p "$RUN/lms-cache" 2>/dev/null
	# Quanto puo' durare chi ha il lock: attesa di un posto piu' timeout.
	fine=$(( $(date +%s) + tmo + ${LMS_ATTESA_POSTO:-3} + 1 ))
	while :; do
		if [ -s "$f" ] && read -r st rc < "$f"; then
			now=$(date +%s)
			if [ $((now - st)) -le "$ttl" ]; then
				tail -n +2 "$f"
				return "$rc"
			fi
		fi
		if mkdir "$f.lock" 2>/dev/null; then
			echo $$ > "$f.lock/pid"
			out=$(lms_json_diretto "$@")
			rc=$?
			{ date +%s | tr '\n' ' '; echo "$rc"; printf '%s\n' "$out"; } > "$f.$$" && mv "$f.$$" "$f"
			rm -rf "$f.lock"
			[ "$rc" -ne 0 ] || printf '%s\n' "$out"
			return "$rc"
		fi
		p=$(cat "$f.lock/pid" 2>/dev/null)
		if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
			rm -rf "$f.lock"
			continue
		fi
		# Attesa esaurita: richiesta propria, senza cache.
		[ "$(date +%s)" -lt "$fine" ] || { lms_json_diretto "$@"; return; }
		sleep 0.2
	done
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

# Modalita' ascolto scelta nella pagina Sistema: puro (lavori sospesi,
# coda in RAM, dischi fermi), si (solo lavori sospesi) o no. Il precarico
# esiste solo nella modalita' completa (Lyrion su Sweetspot).
listening_choice() {
	if ! is_yes "$(conf MODALITA_ASCOLTO si)"; then
		echo no
	elif [ "$(mode)" = completa ] && is_yes "$(conf PRECARICO si)"; then
		echo puro
	else
		echo si
	fi
}

# Modalita' effettiva del volume: hardware, fisso o digitale. La calcola il
# player all'avvio (VOLUME=dac senza mixer nel DAC diventa fisso) e la scrive
# in volume.effettivo; senza il file si ricava da VOLUME.
volume_effettivo() {
	local v
	v=$(cat "$RUN/volume.effettivo" 2>/dev/null)
	case "$v" in hardware|fisso|digitale) echo "$v"; return 0 ;; esac
	case "$(lower "$(conf VOLUME fisso)")" in
		dac) echo hardware ;;
		software|dsp) echo digitale ;;
		*) echo fisso ;;
	esac
}

# Modalita' effettiva del volume, UNICA fonte per gli argomenti di Squeezelite,
# le preferenze di Lyrion e la diagnostica (Stato, Audio, sweetspot-check).
# Stampa "modo|motivo": modo fisso, dac, software o dsp; il motivo e' vuoto
# se e' quella chiesta, altrimenti dice perche' si e' ripiegato.
#   fisso    campioni invariati: Squeezelite con -F, mixer del DAC a 0 dB
#   dac      mixer hardware del DAC (-V controllo)
#   software volume di Squeezelite (dither TPDF)
#   dsp      volume a 64 bit in CamillaDSP, Squeezelite con -F
# $1: controllo di volume del DAC (vuoto se manca). volume.modo (dsp o
# riserva) lo scrive il player prima, quando sa se CamillaDSP c'e'.
volume_modo_calcola() { # controllo
	local mot
	case "$(lower "$(conf VOLUME fisso)")" in
		dac)
			if [ -n "$1" ]; then echo "dac|"
			else echo "fisso|il DAC non ha un controllo del volume"; fi ;;
		software) echo "software|" ;;
		dsp)
			if [ "$(cat "$RUN/volume.modo" 2>/dev/null)" = dsp ]; then echo "dsp|"
			else
				# Il motivo preciso lo scrive il player in volume.motivo (modalita'
				# player senza SERVER, CamillaDSP non preparato...).
				mot=$(head -n 1 "$RUN/volume.motivo" 2>/dev/null)
				echo "software|${mot:-volume a 64 bit non disponibile (CamillaDSP assente o non avviato)}"
			fi ;;
		*) echo "fisso|" ;;
	esac
}

# Argomenti di Squeezelite per la modalita' $1 (controllo del DAC in $2),
# uno per riga.
volume_args() { # modo controllo
	case "$1" in
		fisso|dsp) printf '%s\n' -F ;;
		dac) printf '%s\n' -V "$2" ;;
	esac
}

# Preferenze di Lyrion per la modalita' $1: valore di digitalVolumeControl e
# volume da imporre ("-" se nessuno).
volume_prefs() { # modo
	case "$1" in
		fisso) echo "0 100" ;;
		*) echo "1 -" ;;
	esac
}

# Scrive lo stato letto da Stato e Audio. volume.modalita e volume.motivo
# sono la modalita' effettiva; volume.effettivo il vocabolario storico
# (hardware, fisso, digitale). volume.locale dice se il guadagno locale e'
# garantito da Squeezelite/DAC stessi, verificandolo sugli argomenti reali
# ($RUN/player.args): "verificato" o "non verificato". Con Lyrion remoto le
# trasformazioni lato server (sox, ReplayGain, volume digitale di Lyrion)
# non sono verificabili da qui: lo dice volume.server.
volume_stato_scrivi() { # modo motivo
	local modo=$1 motivo=$2 args loc=verificato srv
	args=" $(cat "$RUN/player.args" 2>/dev/null)"
	case "$modo" in
		fisso|dsp) case "$args" in *" -F "*) ;; *) loc="non verificato" ;; esac ;;
		dac) case "$args" in *" -V "*) ;; *) loc="non verificato" ;; esac ;;
		software) case "$args" in *" -F "*|*" -V "*) loc="non verificato" ;; esac ;;
	esac
	if [ "$(mode)" = completa ]; then srv="locale"; else srv="non verificabile"; fi
	echo "$modo" > "$RUN/volume.modalita"
	printf '%s\n' "$motivo" > "$RUN/volume.motivo"
	echo "$loc" > "$RUN/volume.locale"
	echo "$srv" > "$RUN/volume.server"
	case "$modo" in
		dac) echo hardware > "$RUN/volume.effettivo" ;;
		fisso) echo fisso > "$RUN/volume.effettivo" ;;
		*) echo digitale > "$RUN/volume.effettivo" ;;
	esac
}

# Modalita' effettiva (fisso, dac, software, dsp) per la diagnostica.
volume_modalita() {
	local v
	v=$(cat "$RUN/volume.modalita" 2>/dev/null)
	case "$v" in fisso|dac|software|dsp) echo "$v"; return 0 ;; esac
	case "$(volume_effettivo)" in
		hardware) echo dac ;;
		fisso) echo fisso ;;
		*) if [ "$(cat "$RUN/volume.modo" 2>/dev/null)" = dsp ]; then echo dsp; else echo software; fi ;;
	esac
}

# Frase per Stato e Audio: modalita', motivo del ripiego, cosa e' verificato
# (guadagno locale) e cosa no (lato server con Lyrion remoto).
volume_descrizione() {
	local m mot loc srv out
	m=$(volume_modalita); mot=$(cat "$RUN/volume.motivo" 2>/dev/null)
	loc=$(cat "$RUN/volume.locale" 2>/dev/null); srv=$(cat "$RUN/volume.server" 2>/dev/null)
	out="$m"
	[ -n "$mot" ] && out="$out (ripiego: $mot)"
	[ -n "$loc" ] && out="$out; guadagno locale $loc"
	[ "$srv" = "non verificabile" ] && out="$out; trasformazioni lato server non verificabili"
	printf '%s' "$out"
}

# CamillaDSP e' nel percorso con i filtri della stanza, non solo per il
# volume a 64 bit (lo decide il player, vedi sweetspot-player).
correction_running() {
	[ -f "$RUN/correzione.filtri" ] && return 0
	[ -f "$RUN/correzione.attiva" ] && [ "$(cat "$RUN/volume.modo" 2>/dev/null)" != dsp ]
}

# Il DAC sta suonando? (stato del flusso ALSA, vale per qualunque player)
# Solo comandi interni della shell (nessun fork): il demone dello stato lo
# chiede ogni pochi secondi mentre Lyrion dice "play".
dac_playing() {
	local f l
	for f in "$PROC"/asound/card*/pcm*p/sub*/status; do
		[ -r "$f" ] || continue
		while IFS= read -r l; do
			case "$l" in "state: RUNNING"*) return 0 ;; esac
		done < "$f"
	done
	return 1
}

# Lo stato si calcola quando succede qualcosa o quando qualcuno lo chiede:
# chi lo legge (pagina Stato, stato.json) chiama stato_richiedi, che chiede al
# demone un giro nuovo se la cache e' piu' vecchia di ETA secondi (10, o 40
# durante l'ascolto: il controllo completo non e' leggero) e aspetta fino a 12
# s il file aggiornato. La richiesta e' una riga nella FIFO stato.richiesta
# (scrivibile da tutti: puo' solo chiedere un giro, che il demone limita);
# senza demone, o con la FIFO senza lettore, si serve la cache com'e'.
stato_richiedi() { # [eta]
	local ts t2 i max=${1:-10}
	[ -p "$RUN/stato.richiesta" ] || return 0
	dac_playing && [ "$max" -lt 40 ] && max=40
	ts=0
	read -r ts _ < "$RUN/stato.ts" 2>/dev/null
	case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
	[ $(( $(date +%s) - ts )) -gt "$max" ] || return 0
	timeout 2 sh -c 'echo r > "$1"' sh "$RUN/stato.richiesta" 2>/dev/null || return 0
	i=0
	while [ $i -lt 24 ]; do
		usleep 500000
		t2=0
		read -r t2 _ < "$RUN/stato.ts" 2>/dev/null
		case "$t2" in ''|*[!0-9]*) t2=0 ;; esac
		[ "$t2" -gt "$ts" ] && return 0
		i=$((i + 1))
	done
	return 0
}
# Il DAC e' del Bluetooth (sweetspot-bluetooth)? Il segnale $RUN/dac.bluetooth
# contiene il PID di chi tiene il DAC: se non esiste piu' il segnale e' orfano,
# si rimuove (con una riga nel registro) e il DAC torna al player.
bt_dac_busy() {
	local f=$RUN/dac.bluetooth pid
	[ -e "$f" ] || return 1
	pid=$(cat "$f" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) ;; *) [ -d "$PROC/$pid" ] && return 0 ;; esac
	rm -f "$f"
	log "bluetooth: segnale dac.bluetooth orfano (processo $pid assente), il DAC torna al player"
	return 1
}


# Osservazione /proc del solo PCM scelto dal player, non certificazione del DAC.
# DEV|SUB|STATE|FORMAT|RATE|CHANNELS|BUFFER_SIZE|PERIOD_SIZE
# Parametri e stato vengono letti dallo stesso substream; piu' substream
# aperti non provano quale appartenga al player e sono AMBIGUOUS.
dac_pcm_snapshot() {
	local dev sub=- p n selected='' closed='' unreadable='' count=0 state params
	dev=$(dac_playback_dev "$1") || dev='-'
	case "$dev" in ''|*[!0-9]*) printf '%s\n' '-|-|UNAVAILABLE|||||'; return 0 ;; esac
	for p in "$PROC/asound/card$1/pcm${dev}p"/sub*; do
		[ -d "$p" ] || continue
		n=${p##*/sub}
		case "$n" in ''|*[!0-9]*) continue ;; esac
		if [ ! -r "$p/hw_params" ]; then
			unreadable=$n
		elif [ "$(cat "$p/hw_params" 2>/dev/null)" = closed ]; then
			[ -n "$closed" ] || closed=$n
		else
			count=$((count + 1)); selected=$p; sub=$n
		fi
	done
	if [ "$count" -gt 1 ]; then
		printf '%s|-|AMBIGUOUS|||||\n' "$dev"; return 0
	fi
	if [ -n "$unreadable" ]; then
		printf '%s|%s|UNAVAILABLE|||||\n' "$dev" "$unreadable"; return 0
	fi
	if [ "$count" -eq 0 ]; then
		if [ -n "$closed" ]; then state=CLOSED; sub=$closed; else state=UNAVAILABLE; fi
		printf '%s|%s|%s|||||\n' "$dev" "$sub" "$state"; return 0
	fi
	# Numeric validation is lexical then bounded in awk, never shell arithmetic.
	# hw_params rates may include the kernel's rational annotation (96000/1).
	params=$(awk '
		function positive(v) { return v ~ /^[0-9]+$/ && length(v)<=10 && v+0>0 && v+0<=4294967295 }
		/^format:/ { nf++; f=$2; if(NF!=2) bad=1 }
		/^rate:/ {
			nr++; r=$2
			if(NF==3 && $3 ~ /^\([0-9]+\/[0-9]+\)$/) {
				annotation=$3; gsub(/[()]/,"",annotation); split(annotation,ratio,"/")
				if(!positive(ratio[1]) || !positive(ratio[2])) bad=1
			} else if(NF!=2) bad=1
		}
		/^channels:/ { nc++; c=$2; if(NF!=2) bad=1 }
		/^buffer_size:/ { nb++; b=$2; if(NF!=2 || !positive(b)) bad=1 }
		/^period_size:/ { np++; p=$2; if(NF!=2 || !positive(p)) bad=1 }
		END {
			formats=" S8 U8 S16_LE S16_BE U16_LE U16_BE S24_LE S24_BE U24_LE U24_BE S32_LE S32_BE U32_LE U32_BE FLOAT_LE FLOAT_BE FLOAT64_LE FLOAT64_BE IEC958_SUBFRAME_LE IEC958_SUBFRAME_BE MU_LAW A_LAW IMA_ADPCM MPEG GSM S20_LE S20_BE U20_LE U20_BE SPECIAL S24_3LE S24_3BE U24_3LE U24_3BE S20_3LE S20_3BE U20_3LE U20_3BE S18_3LE S18_3BE U18_3LE U18_3BE G723_24 G723_24_1B G723_40 G723_40_1B DSD_U8 DSD_U16_LE DSD_U32_LE DSD_U16_BE DSD_U32_BE "
			if(bad || nf!=1 || nr!=1 || nc!=1 || nb>1 || np>1 ||
				f !~ /^[A-Z0-9_]+$/ || !index(formats," " f " ") || !positive(r) || !positive(c)) exit 1
			printf "%s|%s|%s|%s|%s", f,r,c,b,p
		}' "$selected/hw_params" 2>/dev/null) || params=''
	state=$(awk '/^state:/ { n++; s=$2; if(NF!=2) bad=1 }
		END { if(n==1 && !bad) print s }' "$selected/status" 2>/dev/null)
	case "$state" in
		OPEN|SETUP|PREPARED|RUNNING|PAUSED|DRAINING|XRUN|SUSPENDED|DISCONNECTED) ;;
		*) state=UNVERIFIED ;;
	esac
	if [ -z "$params" ]; then state=UNVERIFIED; params='||||'; fi
	printf '%s|%s|%s|%s\n' "$dev" "$sub" "$state" "$params"
}

# Parametri hardware aperti osservati: "FORMATO FREQUENZA CANALI".
# Compatibilita': questi parametri non sono un verdetto di riproduzione.
dac_hw_now() {
	local snapshot _dev _sub state fmt rate channels _buffer _period
	snapshot=$(dac_pcm_snapshot "$1")
	IFS='|' read -r _dev _sub state fmt rate channels _buffer _period <<EOF
$snapshot
EOF
	case "$state" in CLOSED|UNAVAILABLE|AMBIGUOUS) return 1 ;; esac
	[ -n "$fmt" ] && [ -n "$rate" ] && [ -n "$channels" ] || return 1
	printf '%s %s %s\n' "$fmt" "$rate" "$channels"
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

# Verdetto della catena del segnale. Ogni stadio e' "inv" (invariato e
# verificato), "mod" (modifica i campioni) o "nv" (non verificabile).
# "bit-perfect" solo se tutti gli stadi sono inv; basta uno stadio che
# modifica per dire "modificato"; altrimenti "non-verificabile".
# Senza stadi il verdetto e' non-verificabile.
chain_verdict() {
	local s any_mod=0 any_nv=0 n=0
	for s in "$@"; do
		n=$((n + 1))
		case "$s" in
			inv) ;;
			mod) any_mod=1 ;;
			*) any_nv=1 ;;
		esac
	done
	if [ "$n" = 0 ]; then echo non-verificabile
	elif [ "$any_mod" = 1 ]; then echo modificato
	elif [ "$any_nv" = 1 ]; then echo non-verificabile
	else echo bit-perfect
	fi
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
	# (SWEETSPOT_STICK_DEV: partizione finta per i test.)
	[ -n "${SWEETSPOT_STICK_DEV:-}" ] && { echo "$SWEETSPOT_STICK_DEV"; return 0; }
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

part_name() { # disco numero -> sda1, nvme0n1p1, mmcblk0p1
	case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "$1$2" ;; esac
}

part_disk() { # sdb1 -> sdb, nvme0n1p1 -> nvme0n1
	local p
	p=$(readlink -f "$SYS/class/block/$1/.." 2>/dev/null) || return 1
	[ -f "$p/size" ] && [ -d "$p/queue" ] || return 1
	echo "${p##*/}"
}

# Dischi (interi) che contengono la musica montata da sweetspot-dischi.
music_disks() {
	local dev disk
	[ -f "$RUN/dischi.list" ] || return 0
	cut -d'|' -f2 "$RUN/dischi.list" | while IFS= read -r dev; do
		[ -n "$dev" ] || continue
		disk=$(part_disk "$dev") || disk=$dev
		echo "$disk"
	done | sort -u
}

# La prova dell'ascolto puro: "disco NOME SETTORI_LETTI" per ogni disco con
# la musica e "rete BYTE" (ricevuti + trasmessi, senza lo). Li annota
# sweetspot-ascolto all'inizio di ogni ascolto, li confronta sweetspot-check.
io_counters() {
	local disk
	for disk in $(music_disks); do
		[ -f "$SYS/block/$disk/stat" ] || continue
		echo "disco $disk $(awk '{ print $3 }' "$SYS/block/$disk/stat")"
	done
	echo "rete $(awk 'NR > 2 && $1 !~ /^lo:/ { sub(/^[^:]*:/, ""); t += $1 + $9 } END { print t + 0 }' "$PROC/net/dev")"
}

# Montaggio condiviso: chi monta la chiavetta (impostazioni, salvataggio
# dei dati, aggiornamenti) la smonta solo se nessun altro la sta usando.
# Il primo che chiede la scrittura la rimonta scrivibile. Il blocco usa il
# descrittore 6: 8 e 9 sono dei blocchi di sweetspot-dati, sweetspot-config
# e dei dischi, e riaprirli li scioglierebbe.
# Gli utilizzatori sono i PID, uno per riga: un processo morto (SIGKILL,
# OOM) senza stick_umount non tiene piu' la chiavetta occupata.
STICK_USERS=$RUN/chiavetta.utenti
# Da quando la chiavetta e' scrivibile senza utilizzatori vivi (stick_guardia)
STICK_ORFANA=$RUN/chiavetta.orfana

# La chiavetta e' montata scrivibile? (opzioni di montaggio in /proc/mounts)
stick_is_rw() {
	awk -v m="$STICK_MNT" '$2 == m { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "rw") ok = 1 } END { exit !ok }' "$PROC/mounts" 2>/dev/null
}

# Toglie dall'elenco i PID che non esistono piu' (con il blocco preso).
stick_users_prune() {
	local p keep=''
	[ -f "$STICK_USERS" ] || return 0
	while read -r p; do
		[ -n "$p" ] && [ -d "$PROC/$p" ] && keep="$keep$p
"
	done < "$STICK_USERS"
	printf '%s' "$keep" > "$STICK_USERS"
}

stick_mount() { # [ro|rw]
	local dev mode=${1:-ro} rc=0
	[ -n "${SWEETSPOT_STICK_DIR:-}" ] && { [ -d "$STICK_MNT" ]; return; }
	mkdir -p "$RUN"
	exec 6> "$RUN/chiavetta.lock"
	flock 6
	if grep -q " $STICK_MNT " "$PROC/mounts" 2>/dev/null; then
		stick_users_prune
		if [ "$mode" = rw ]; then
			# Il rimontaggio puo' riuscire a parole e lasciare la chiavetta in
			# sola lettura (errori del filesystem): si controlla lo stato vero.
			if mount -o remount,rw "$STICK_MNT" 2>/dev/null && stick_is_rw; then
				evento chiavetta rimontata "rw"
			else
				rc=1
			fi
		fi
	else
		rm -f "$STICK_USERS"
		dev=$(stick_device)
		if [ -n "$dev" ]; then
			mkdir -p "$STICK_MNT"
			if mount -t vfat -o "$mode,noatime,nosuid,nodev,noexec,codepage=437,iocharset=iso8859-1" "$dev" "$STICK_MNT" 2>/dev/null; then
				evento chiavetta montata "$mode"
			else
				rc=1
			fi
		else
			rc=1
		fi
	fi
	[ $rc -eq 0 ] && echo $$ >> "$STICK_USERS"
	flock -u 6
	exec 6>&-
	return $rc
}

stick_umount() {
	[ -n "${SWEETSPOT_STICK_DIR:-}" ] && return 0
	exec 6> "$RUN/chiavetta.lock"
	flock 6
	# Toglie una sola voce di questo processo (le chiamate possono annidarsi).
	if [ -f "$STICK_USERS" ]; then
		awk -v p=$$ '$1 == p && !d { d = 1; next } { print }' "$STICK_USERS" > "$STICK_USERS.nuovo" &&
			mv "$STICK_USERS.nuovo" "$STICK_USERS"
	fi
	stick_users_prune
	sync
	if [ ! -s "$STICK_USERS" ]; then
		if umount "$STICK_MNT" 2>/dev/null; then
			evento chiavetta smontata
			rm -f "$STICK_USERS"
		elif mount -o remount,ro "$STICK_MNT" 2>/dev/null; then
			# Occupata (un terminale aperto nella cartella...): almeno in sola
			# lettura, cosi' un taglio di corrente non lascia la FAT sporca.
			evento chiavetta rimontata "ro (smontaggio non riuscito)"
		fi
	fi
	flock -u 6
	exec 6>&-
}

# Controllo periodico (lo chiama il demone sweetspot-stato): la chiavetta
# scrivibile senza utilizzatori vivi da almeno $1 minuti (predefinito 5) si
# riporta in sola lettura. Succede dopo un SIGKILL o un OOM di chi l'aveva
# montata. Il blocco e' in una subshell: nel demone il descrittore 6 e' suo.
stick_guardia() {
	[ -n "${SWEETSPOT_STICK_DIR:-}" ] && return 0
	[ -d "$RUN" ] || return 0
	(
		local now u
		exec 6> "$RUN/chiavetta.lock"
		flock 6
		if ! grep -q " $STICK_MNT " "$PROC/mounts" 2>/dev/null || ! stick_is_rw; then
			rm -f "$STICK_ORFANA"
			exit 0
		fi
		stick_users_prune
		if [ -s "$STICK_USERS" ]; then
			rm -f "$STICK_ORFANA"
			exit 0
		fi
		read -r u _ < "$PROC/uptime" 2>/dev/null
		now=${u%%.*}
		if [ ! -f "$STICK_ORFANA" ]; then
			echo "${now:-0}" > "$STICK_ORFANA"
			exit 0
		fi
		read -r u < "$STICK_ORFANA"
		[ $((${now:-0} - ${u:-0})) -ge $((${1:-5} * 60)) ] || exit 0
		sync
		if mount -o remount,ro "$STICK_MNT" 2>/dev/null; then
			evento chiavetta rimontata "ro (nessun utilizzatore)"
			rm -f "$STICK_ORFANA"
		fi
	)
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

# Scheda per cui e' compilato il sistema: x86_64 (PC, avvio con GRUB) o rpi
# (Raspberry Pi 4 e 5, avvio con il firmware del Pi).
board() {
	local b
	b=$(cat "${SWEETSPOT_SCHEDA_FILE:-/etc/sweetspot-scheda}" 2>/dev/null)
	printf '%s' "${b:-x86_64}"
}

boot_type() { case "$(board)" in rpi*) echo rpi ;; *) echo grub ;; esac; }

# Cartella di una copia del sistema. GRUB: A nella cartella principale, B in
# b. Raspberry Pi: a e b (os_prefix in config.txt), ognuna con kernel,
# albero dei dispositivi, overlay e riga di comando.
slot_dir() { # radice copia
	if [ "$(boot_type)" = rpi ]; then echo "$1/$2"
	elif [ "$2" = b ]; then echo "$1/b"
	else echo "$1"; fi
}

kernel_file() { if [ "$(boot_type)" = rpi ]; then echo Image.gz; else echo bzImage; fi; }

# Stato dell'avvio (slot, prova, tentato), nel formato di grubenv: con GRUB
# lo legge e lo aggiorna il menu di avvio; sul Raspberry Pi lo gestiscono gli
# script, e il firmware legge config.txt (copia in uso) e tryboot.txt (copia
# da provare una volta, con il riavvio "tryboot").
boot_env() {
	if [ "$(boot_type)" = rpi ]; then echo "$STICK_MNT/sweetspot-avvio.env"
	else echo "$STICK_MNT/boot/grub/grubenv"; fi
}

# Sostituisce un file critico della FAT con la versione nuova: sync del
# temporaneo prima del mv (senza, un taglio di corrente puo' lasciare il file
# vuoto), mv (un rename nella stessa cartella: o c'e' il vecchio o il nuovo) e
# sync finale. Niente copia .bak: nessuno la ripristinava e conservava i
# segreti (sweetspot.txt) in chiaro; quelle rimaste da versioni precedenti si
# eliminano alla prima sostituzione riuscita.
fat_sostituisci() { # temporaneo destinazione
	sync
	mv "$1" "$2" && sync && rm -f "$2.bak"
}

# Raspberry Pi: scrive config.txt o tryboot.txt dal modello con la copia
# indicata (os_prefix).
rpi_boot_config() { # file copia [modello]
	local tpl=${3:-${SWEETSPOT_AVVIO:-/usr/share/sweetspot/avvio}/config.txt}
	sed "s|@COPIA@|$2|g" "$tpl" > "$1.nuovo" && fat_sostituisci "$1.nuovo" "$1"
}

# Raspberry Pi: riga di comando del kernel di una copia (cmdline.txt).
rpi_cmdline() { # copia parametri_adattati
	printf 'console=tty1 quiet loglevel=3 usbcore.autosuspend=-1 audit=0 panic=10 sweetspot.slot=%s%s\n' "$1" "${2:+ $2}"
}

# Raspberry Pi: file incluso da config.txt con l'overlay della scheda DAC I2S.
rpi_scheda_txt() { # overlay
	echo "# Scheda DAC scelta nella pagina Audio (lo scrive Sweetspot)."
	if [ -n "$1" ]; then
		echo "dtparam=i2s=on"
		echo "dtoverlay=$1"
	fi
}

# Raspberry Pi: parametri adattati (autotune) nella riga di comando di una copia.
rpi_tune() { # copia
	sed -n 's/.*sweetspot\.slot=[ab] *//p' "$STICK_MNT/$1/cmdline.txt" 2>/dev/null | head -n 1
}

# Raspberry Pi: due file dicono quale copia e' in uso, config.txt (os_prefix,
# quello che il firmware usa davvero) e sweetspot-avvio.env (slot). Dopo un
# taglio di corrente fra le due scritture possono non concordare: vale
# config.txt (se illeggibile, la copia avviata) e si corregge l'altro file.
# Non agisce con un aggiornamento in prova (tentato/prova): li gestisce la conferma.
rpi_riconcilia() {
	local env real def
	[ "$(boot_type)" = rpi ] || return 0
	env=$(boot_env)
	[ -z "$(grubenv_get "$env" tentato)" ] && [ -z "$(grubenv_get "$env" prova)" ] || return 0
	real=$(sed -n 's|^os_prefix=\([ab]\)/*[[:space:]]*$|\1|p' "$STICK_MNT/config.txt" 2>/dev/null | head -n 1)
	def=$(grubenv_get "$env" slot)
	if [ -z "$real" ]; then
		real=$(running_slot)
		rpi_boot_config "$STICK_MNT/config.txt" "$real" || return 1
		log "avvio: config.txt illeggibile, riscritto con la copia $real"
	fi
	if [ "$def" != "$real" ]; then
		grubenv_set "$env" "slot=$real" || return 1
		log "avvio: sweetspot-avvio.env indicava la copia '${def:-nessuna}', riallineato a config.txt (copia $real)"
	fi
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

# --- Tabella delle partizioni MBR (installazione, archivio nello spazio libero)

# Formattazione dell'archivio musicale (ext4): niente spazio riservato, un
# inode ogni 512 KiB (bastano anche per molti file piccoli) e tabelle scritte
# subito, cosi' dopo la formattazione il kernel non lavora sul disco in
# sottofondo.
# shellcheck disable=SC2034 # usata da sweetspot-installa e sweetspot-spazio
MKFS_ARCHIVIO="-F -q -m 0 -i 524288 -E lazy_itable_init=0,lazy_journal_init=0"

oct() { printf '\\%03o' "$1"; }

le32() {
	local v=$1 i=0
	while [ $i -lt 4 ]; do
		oct $((v & 255))
		v=$((v >> 8))
		i=$((i + 1))
	done
}

# Cilindro/testina/settore per i BIOS piu' vecchi (geometria 255x63);
# oltre i 1024 cilindri il valore convenzionale 1023/254/63.
chs() {
	local lba=$1 c h s
	c=$((lba / (255 * 63)))
	h=$((lba / 63 % 255))
	s=$((lba % 63 + 1))
	if [ $c -gt 1023 ]; then c=1023; h=254; s=63; fi
	oct $h
	oct $((s | (c >> 2 & 192)))
	oct $((c & 255))
}

mbr_entry() { # avviabile tipo inizio settori
	if [ "$4" -eq 0 ]; then
		printf '%016d' 0 | tr 0 '\000'
		return
	fi
	printf "$(oct "$1")$(chs "$3")$(oct "$2")$(chs $(($3 + $4 - 1)))$(le32 "$3")$(le32 "$4")"
}

# Le quattro voci della tabella MBR di $1: righe "tipo inizio settori"
# (settori da 512 byte). Niente se manca la firma 55 AA.
mbr_read() { # dispositivo
	od -An -tu1 -v -j446 -N66 "$1" 2>/dev/null | tr -s ' \n' '  ' | awk '{
		if ($65 != 85 || $66 != 170) exit 1
		for (e = 0; e < 4; e++) {
			o = e * 16
			t = $(o + 5)
			st = $(o + 9) + $(o + 10) * 256 + $(o + 11) * 65536 + $(o + 12) * 16777216
			n = $(o + 13) + $(o + 14) * 256 + $(o + 15) * 65536 + $(o + 16) * 16777216
			printf "%d %.0f %.0f\n", t, st, n
		}
	}'
}

# --- Registro di Squeezelite: conteggi e rotazione ---------------------------

# XRUN e recuperi falliti nel registro di Squeezelite: "EVENTI RECUPERI".
# Il messaggio di output_alsa.c segue il prefisso del logger oppure e' nudo.
# Confrontare il messaggio intero evita sottostringhe e doppi conteggi.
xrun_counts() { # [file], altrimenti lo standard input
	awk '
		{ message=$0; sub(/^\[[^]]*\][[:space:]]+[[:alnum:]_]+:[0-9]+[[:space:]]+/, "", message) }
		message == "XRUN" { events++ }
		message ~ /^XRUN recover failed: / { recovery++ }
		END { printf "%d %d", events, recovery }
	' "$@"
}

# Somma due coppie "EVENTI RECUPERI".
xrun_sum() { # COPPIA COPPIA
	echo "$(( ${1% *} + ${2% *} )) $(( ${1#* } + ${2#* } ))"
}

# Contatori persistenti in $RUN: eventi gia' usciti dal registro per la
# rotazione. $RUN/xrun.totale vale da quando il sistema e' acceso,
# $RUN/sessione.xrun solo dall'inizio della sessione del player.
xrun_saved() { # FILE
	local v
	v=$(cat "$1" 2>/dev/null)
	case "$v" in
		*[!0-9\ ]*|'') echo "0 0" ;;
		*) echo "$v" ;;
	esac
}

# Rotazione per dimensione "copytruncate": Squeezelite tiene il file aperto
# (-f), quindi niente rename. Prima si copia, poi si tronca in place, poi si
# contano gli eventi della copia e si sommano ai contatori persistenti.
# Costo normale: la sola dimensione del file. Soglia in KB: LOG_SQUEEZELITE_KB.
sqlog_rotate() { # FILE
	local f=$1 size max copy off all part
	[ -f "$f" ] || return 0
	max=$(conf LOG_SQUEEZELITE_KB 1024)
	case "$max" in ''|*[!0-9]*|0) max=1024 ;; esac
	size=$(wc -c < "$f" | tr -d ' ')
	[ "${size:-0}" -ge $((max * 1024)) ] || return 0
	mkdir -p "$RUN"
	copy=$RUN/squeezelite.rotazione
	cp "$f" "$copy" 2>/dev/null || { rm -f "$copy"; return 1; }
	: > "$f"
	all=$(xrun_counts "$copy")
	xrun_sum "$(xrun_saved "$RUN/xrun.totale")" "$all" > "$RUN/xrun.totale"
	# Sessione in corso: conta solo cio' che sta dopo la posizione iniziale.
	if [ -s "$RUN/sessione" ]; then
		off=$(sed -n 's/^sqlog=//p' "$RUN/sessione")
		part=$(tail -c +"$((${off:-0} + 1))" "$copy" | xrun_counts)
		xrun_sum "$(xrun_saved "$RUN/sessione.xrun")" "$part" > "$RUN/sessione.xrun"
		sed 's/^sqlog=.*/sqlog=0/' "$RUN/sessione" > "$RUN/sessione.tmp" &&
			mv "$RUN/sessione.tmp" "$RUN/sessione"
	fi
	rm -f "$copy"
	log "registro di Squeezelite ruotato ($size byte): eventi XRUN $all salvati nei contatori"
}

# Storico completo: contatori persistenti piu' registro corrente.
xrun_total() { # FILE
	local cur
	cur=$(xrun_counts "$1" 2>/dev/null) || return 1
	xrun_sum "$(xrun_saved "$RUN/xrun.totale")" "$cur"
}

# --- Quota dei log in RAM -------------------------------------------------------
# Tutti i log vivono in RAM (/var/log, /run, /tmp): nessuno deve crescere senza
# limite. Ogni file ha un tetto (LOG_FILE_KB) e l'insieme una quota
# (LOG_QUOTA_KB): superata, si tronca il file meno recente. Si tronca in place
# (il processo che scrive tiene il file aperto) tenendo la coda.
LOGDIR=${SWEETSPOT_LOGDIR:-/var/log}
TMPDIR_LOG=${SWEETSPOT_TMPLOG:-/tmp}

# Un file per riga: registro di sistema, timeline, log di Squeezelite (anche
# delle zone), di CamillaDSP, di Lyrion (anche di avvio), file .log in RUN e /tmp.
log_ram_files() {
	local f
	for f in "$LOGFILE" "$LOGFILE.1" "$TIMELINE" "$LOGDIR"/*.log "$LOGDIR"/lms/*.log \
		"$RUN"/*.log "$TMPDIR_LOG"/sweetspot*.log; do
		[ -f "$f" ] && echo "$f"
	done | awk '!v[$0]++'
}

# Tiene gli ultimi KEEP byte di FILE, sullo stesso inode.
log_tronca() { # file keep
	local f=$1 tmp="$RUN/log.tronca.$$"
	mkdir -p "$RUN" 2>/dev/null
	if [ "$2" -le 0 ]; then : > "$f"; return 0; fi
	tail -c "$2" "$f" > "$tmp" 2>/dev/null && cat "$tmp" > "$f"
	rm -f "$tmp"
}

# Applica tetto per file e quota complessiva. Il registro principale di
# Squeezelite passa da sqlog_rotate (conserva i contatori XRUN).
log_quota() {
	local fkb qkb f files total sq i oldest
	confv LOG_FILE_KB 512; fkb=$CONFV; confv LOG_QUOTA_KB 4096; qkb=$CONFV
	case "$fkb" in ''|*[!0-9]*|0) fkb=512 ;; esac
	case "$qkb" in ''|*[!0-9]*|0) qkb=4096 ;; esac
	sq=${SQLOG:-$LOGDIR/squeezelite.log}
	files=$(log_ram_files)
	[ -n "$files" ] || return 0
	# Una sola lettura delle dimensioni (wc -c) per volta: pochi processi.
	for f in $(wc -c $files 2>/dev/null | awk -v max=$((fkb * 1024)) '$2 != "total" && $1 > max { print $2 }'); do
		[ "$f" = "$sq" ] && continue
		log_tronca "$f" $((fkb * 512))
	done
	i=0
	while [ $i -lt 30 ]; do
		i=$((i + 1))
		total=$(wc -c $files 2>/dev/null | awk '$2 != "total" { t += $1 } END { print t + 0 }')
		[ "$total" -gt $((qkb * 1024)) ] || return 0
		oldest=""
		# I percorsi sono nostri e senza spazi: ls -tr li ordina dal piu' vecchio.
		# shellcheck disable=SC2045
		for f in $(ls -tr $files 2>/dev/null); do
			[ "$f" = "$sq" ] && continue
			[ -s "$f" ] && { oldest=$f; break; }
		done
		[ -n "$oldest" ] || return 0
		log_tronca "$oldest" $(( $(wc -c < "$oldest") / 2 ))
	done
}

# Come log_quota, ma al massimo una volta ogni LOG_QUOTA_SECONDI (120).
log_quota_tick() {
	local now last=''
	# Secondi dall'avvio e lettura del segno con la sola shell: i cicli dei
	# servizi la chiamano ogni pochi secondi; la configurazione si legge solo
	# se e' passato un po' di tempo.
	read -r now _ < /proc/uptime
	now=${now%%.*}
	read -r last < "$RUN/log.quota.ts" 2>/dev/null
	case "$last" in ''|*[!0-9]*) last=0 ;; esac
	if [ "$now" -ge "$last" ]; then
		[ $((now - last)) -ge 5 ] || return 0
		confv LOG_QUOTA_SECONDI 120
		[ $((now - last)) -ge "${CONFV:-120}" ] || return 0
	fi
	echo "$now" > "$RUN/log.quota.ts" 2>/dev/null
	log_quota
}

# --- Controllo dell'header Host delle pagine web ------------------------------------
# Difesa dal DNS rebinding: una pagina esterna che fa risolvere il proprio
# nome all'indirizzo di Sweetspot arriverebbe con un Host diverso e potrebbe
# leggere il gettone anti-CSRF. Si accettano solo i nomi e gli indirizzi
# con cui l'utente raggiunge davvero il player.

# Host senza la porta, in minuscolo ("[fe80::1]:80" -> "fe80::1").
host_bare() {
	local h
	h=$(lower "$1")
	case "$h" in
		'['*) h=${h#\[}; h=${h%%\]*} ;;
		*:*:*) ;; # IPv6 senza parentesi: nessuna porta da togliere
		*) h=${h%%:*} ;;
	esac
	printf '%s' "$h"
}

# Indirizzi IPv4 e IPv6 assegnati al computer, uno per riga.
host_addresses() {
	local n dev fam addr rest
	${SWEETSPOT_IP:-ip} -o addr show 2>/dev/null | while read -r n dev fam addr rest; do
		case "$fam" in inet|inet6) printf '%s\n' "${addr%%/*}" ;; esac
	done
}

# host_allowed HOST [INDIRIZZO_CLIENT]: vero se HOST e' un nome o un
# indirizzo di questo player. Senza Host (HTTP/1.0) passa solo chi arriva
# dal computer stesso: un browser manda sempre l'Host, quindi il rebinding
# non puo' sfruttare l'assenza.
host_allowed() {
	local h net a
	h=$(host_bare "$1")
	if [ -z "$h" ]; then
		case "$2" in 127.*|::1) return 0 ;; esac
		return 1
	fi
	case "$h" in localhost|127.0.0.1|::1) return 0 ;; esac
	net=$(lower "$(conf NOME_RETE sweetspot)" | tr -c 'a-z0-9-' '-' | cut -c1-32)
	if [ -n "$net" ]; then
		case "$h" in "$net"|"$net.local") return 0 ;; esac
	fi
	a=$(lower "$(cat "$PROC/sys/kernel/hostname" 2>/dev/null)")
	if [ -n "$a" ]; then
		case "$h" in "$a"|"$a.local") return 0 ;; esac
	fi
	for a in $(host_addresses); do
		[ "$(lower "$a")" = "$h" ] && return 0
	done
	return 1
}

page_embeddable() {
	case "$1" in */audio|*/stato|*/accesso) return 0 ;; esac
	return 1
}

# Intestazioni di sicurezza di ogni risposta delle pagine. Nessuna pagina puo'
# essere incorporata in un'altra (clickjacking), tranne Audio, Stato e Accesso:
# l'interfaccia Material di Lyrion (porta 9000) le mostra in un riquadro, e
# li' frame-ancestors ammette solo la stessa origine e la porta 9000. Dove
# l'incorporamento e' consentito manca X-Frame-Options (non sa dire "porta
# 9000"; i browser con CSP lo ignorano comunque quando c'e' frame-ancestors).
sec_headers() {
	local anc="'none'" xfo="X-Frame-Options: DENY\r\n"
	if page_embeddable "${SCRIPT_NAME:-}"; then
		anc="'self' http://*:9000 https://*:9000"
		xfo=""
	fi
	printf "Content-Security-Policy: frame-ancestors %s; base-uri 'self'; form-action 'self'; object-src 'none'\r\n" "$anc"
	printf '%b' "$xfo"
	printf 'X-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\n'
}

# Chiamato all'inizio di ogni pagina (CGI): Host non riconosciuto -> 403 e
# nessuna azione. Fuori da una richiesta web (script di sistema, test) non fa nulla.
# L'ordine conta: questa funzione gira appena si carica common.sh, quando le
# pagine (utente "web") non hanno ancora scelto la configurazione leggibile
# (web.sh lo fa dopo). Con la configurazione completa, solo di root, NOME_RETE
# risulterebbe vuoto e ogni nome scelto dall'utente avrebbe avuto un 403.
host_guard() {
	[ -n "${GATEWAY_INTERFACE:-}" ] || return 0
	local CONF=$CONF
	[ -r "$CONF" ] || CONF=$CONF_WEB
	host_allowed "${HTTP_HOST:-}" "${REMOTE_ADDR:-}" && return 0
	printf 'Status: 403 Forbidden\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n'
	sec_headers
	printf '\r\nindirizzo non valido: usa http://%s.local/\n' "$(conf NOME_RETE sweetspot)"
	exit 0
}
host_guard
