#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prove del demone a eventi (sweetspot-stato sorveglia).
# Il demone gira davvero, con una CLI di Lyrion, udevadm e inotifyd finti che
# scrivono gli eventi da FIFO. I fork si contano dal contatore dei PID del
# kernel (/proc/stat): a riposo il demone non deve farne piu' del rumore di
# fondo del computer, misurato prima di avviarlo; ogni evento ha il suo effetto.
# Serve BusyBox (come sul player); senza, la prova viene saltata.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
BB=$(command -v busybox || true)
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  NO  %s\n      atteso: [%s]\n      ottenuto: [%s]\n' "$1" "$2" "$3"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }

echo "Demone a eventi (CLI di Lyrion, udev, inotify, richieste, liveness)"
if [ -z "$BB" ]; then
	echo "  busybox non trovato: prova saltata"
	exit 0
fi

WORK=$(mktemp -d)
DPID=''
WD=''
cleanup() {
	trap '' EXIT TERM
	if [ "$FAIL" -ne 0 ] && [ -s "$E/nc.err" ]; then
		echo "  CLI finta (nc.err):"
		head -n 10 "$E/nc.err" | sed 's/^/    | /'
	fi
	if [ "$FAIL" -ne 0 ] && [ -s "$E/run/stato.debug" ]; then
		echo "  eventi ricevuti dal demone (momento in s dall'avvio, riga):"
		grep -v 'version 9.1.1' "$E/run/stato.debug" | tail -n 60 | cut -c1-110 | sed 's/^/    | /'
	fi
	if [ "$FAIL" -ne 0 ] && [ -s "$E/log" ]; then
		echo "  registro del demone (ultime righe):"
		tail -n 15 "$E/log" | sed 's/^/    | /'
	fi
	if [ "$FAIL" -ne 0 ] && [ -s "$E/demone.out" ]; then
		echo "  uscita (stderr) del demone:"
		head -n 40 "$E/demone.out" | sed 's/^/    | /'
	fi
	kill "$WD" 2>/dev/null
	[ -z "$DPID" ] || kill "$DPID" 2>/dev/null
	kill $(cat "$WORK/pids" 2>/dev/null) 2>/dev/null
	# Gli ascoltatori finti (cat sulle FIFO) non devono restare in giro.
	pkill -f "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT
# Tetto globale alla sezione: se qualcosa si pianta fallisce con un messaggio.
trap 'echo "  NO  la prova del demone ha superato i 300 s"; FAIL=$((FAIL + 1)); exit 1' TERM
( sleep 300; kill -TERM $$ 2>/dev/null ) > /dev/null 2>&1 &
WD=$!

E=$WORK/e
mkdir -p "$E/bin" "$E/run" "$E/proc/net" "$E/proc/asound/card1/pcm0p/sub0" "$E/real"
# Gli strumenti finti hanno nomi propri (nc-finto...): BusyBox preferisce i
# suoi applet a quelli nel PATH, e il demone li prende da SWEETSPOT_NC & co.
for f in cli udev ino; do mkfifo "$E/$f.in"; done
printf '#!%s sh\nwhile :; do %s cat "%s/udev.in"; done\n' "$BB" "$BB" "$E" > "$E/real/udevadm-finto"
printf '#!%s sh\nwhile :; do %s cat "%s/ino.in"; done\n' "$BB" "$BB" "$E" > "$E/real/inotifyd-finto"
cat > "$E/real/nc-finto" <<EOF
#!$BB sh
# CLI finta: gli eventi arrivano dalla FIFO, "version ?" riceve risposta
# (salvo il file muto) e i comandi ricevuti restano in cli.cmd.
exec 2>>"$E/nc.err"
echo "nc \$*" >> "$E/nc.err"
( while :; do $BB cat "$E/cli.in"; done ) &
FEED=\$!
trap 'kill \$FEED 2>/dev/null' EXIT TERM
while read -r c; do
	echo "\$c" >> "$E/cli.cmd"
	case "\$c" in
		"version ?") [ -e "$E/muto" ] || echo "version 9.1.1" ;;
	esac
done
EOF
cat > "$E/real/sweetspot-check" <<EOF
#!$BB sh
echo giro >> "$E/giri"
echo "OK|Prova|tutto bene"
EOF
# wget finto (JSON-RPC): con il file rpc-muto non risponde; altrimenti
# restituisce il modo scritto in "modo". jq finto come in tests/run.sh.
cat > "$E/real/wget-finto" <<EOF
#!$BB sh
[ -e "$E/rpc-muto" ] && exit 1
echo "{\"result\":{\"_mode\":\"\$($BB cat "$E/modo")\"}}"
EOF
printf '#!%s sh\nin=$(%s cat)\n[ -n "$in" ] || exit 1\ncase "$*" in *-e*) exit 0 ;; esac\n%s cat "%s/modo"\n' "$BB" "$BB" "$BB" "$E" > "$E/real/jq"
# Precarico finto: annota i passi (step) chiesti dal demone.
cat > "$E/precarico-finto" <<EOF
step() { echo passo >> "$E/passi"; }
holder_running() { return 1; }
release() { :; }
write_summary() { :; }
EOF
chmod +x "$E/real"/*
cp "$E/real"/* "$E/bin/"

mkdir -p "$E/proc/net"
printf 'h\nh\n  eth0: 1000 1 0 0 0 0 0 0 1000 1 0 0 0 0 0 0\n' > "$E/proc/net/dev"
printf 'LIVENESS_LYRION_PING=5\nLIVENESS_LYRION_TIMEOUT=2\nLIVENESS_LYRION_FALLIMENTI=1\nLIVENESS_PLAYER_SECONDI=4\nLIVENESS_LYRION_AVVIO=180\n' > "$E/run/sweetspot.conf"
echo stop > "$E/modo"
MAC=02:53:57:45:45:54
ENC=02%3A53%3A57%3A45%3A45%3A54
echo "$MAC" > "$E/run/player.mac"
sleep 7200 &
LMS=$!
sleep 7200 &
SQ=$!
echo "$LMS $SQ" > "$WORK/pids"
echo "$LMS" > "$E/run/lms.pid"
touch -d '2000-01-01' "$E/run/lms.pid"
echo "$SQ" > "$E/run/squeezelite.pid"
printf 'state: SETUP\n' > "$E/proc/asound/card1/pcm0p/sub0/status"
# Processi finti per l'OOM killer: lo scanner e' figlio di Lyrion.
mkdir -p "$E/proc/4243" "$E/proc/4244"
printf '4243 (perl) S %s 1 1 0\n' "$LMS" > "$E/proc/4243/stat"
printf 'perl\000/opt/lms/scanner.pl\000' > "$E/proc/4243/cmdline"
echo -100 > "$E/proc/4243/oom_score_adj"
printf '4244 (altro) S 1 1 1 0\n' > "$E/proc/4244/stat"
printf 'perl\000scanner.pl\000' > "$E/proc/4244/cmdline"
echo -100 > "$E/proc/4244/oom_score_adj"

denv() {
	env SWEETSPOT_RUN="$E/run" SWEETSPOT_PROCFS="$E/proc" SWEETSPOT_LOG="$E/log" SWEETSPOT_WGET="$E/bin/wget-finto" \
		SWEETSPOT_PATH="$E/bin:$(dirname "$BB")" SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" \
		SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot" SWEETSPOT_PRECARICO="$E/precarico-finto" \
		SWEETSPOT_LMS= SWEETSPOT_NC=nc-finto SWEETSPOT_UDEVADM=udevadm-finto SWEETSPOT_INOTIFYD=inotifyd-finto SWEETSPOT_STATO_DEBUG=1 SWEETSPOT_STATO_MIN=1 SWEETSPOT_STATO_SCAN=0 PATH="$E/bin:$PATH" "$@"
}
# Aspetta che una condizione (comando) diventi vera, al massimo $1 secondi.
attendi() {
	local t=$1 i=0
	shift
	while [ "$i" -lt "$t" ]; do
		"$@" && return 0
		sleep 1
		i=$((i + 1))
	done
	"$@"
}
# Scrive una riga in una FIFO degli eventi senza mai bloccarsi (se il demone
# o l'ascoltatore finto non c'e', la scrittura si abbandona dopo 3 s).
invia() { # fifo riga
	timeout 3 sh -c 'printf "%s\n" "$2" > "$1"' sh "$1" "$2" 2>/dev/null
	return 0
}
giri() { [ -f "$E/giri" ] && wc -l < "$E/giri" | tr -d ' ' || echo 0; }
passi() { [ -f "$E/passi" ] && wc -l < "$E/passi" | tr -d ' ' || echo 0; }
# Processi creati dall'avvio ("processes" di /proc/stat): ogni fork lo alza.
esegui() {
	local k v n=0
	while read -r k v _; do [ "$k" = processes ] && n=$v; done < /proc/stat
	echo "$n"
}
# Differenza con il rumore di fondo (la stessa finestra senza demone, misurata
# prima di avviarlo): processi lanciati dal solo demone, con 3 di tolleranza.
rumore() { # secondi
	local a b
	a=$(esegui); sleep "$1"; b=$(esegui)
	echo $((b - a))
}
# Aspetta che il demone si sia assestato dopo un evento (giro del check,
# passi, riarmi): due finestre di 2 s di fila sotto il rumore, al massimo 30 s.
assesta() {
	local quieto=0 i A B
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
		A=$(esegui); sleep 2; B=$(esegui)
		if [ $((B - A)) -le $((NOISE / 4 + 3)) ]; then quieto=$((quieto + 1)); else quieto=0; fi
		[ "$quieto" -ge 2 ] && return 0
	done
}
# Una finestra di 8 s: i processi nati devono essere al piu' il rumore + 3.
# Se no, classifica "padre > comando: N" dei 10 s successivi.
finestra() { # descrizione
	local P D
	P=$(esegui)
	sleep 8
	D=$(esegui)
	expect "$1" "si" "$([ $((D - P)) -le $((NOISE + 6)) ] && echo si || echo "no: $((D - P)) contro rumore $NOISE")"
	if [ $((D - P)) -gt $((NOISE + 6)) ]; then
		sh "$ROOT/tests/forks-riposo.sh" --dettaglio 10 2>&1 | sed 's/^/    | /'
	fi
}
giri_sono() { [ "$(giri)" -ge "$1" ]; }
# Il check si conta all'inizio del giro ma stato.ts si scrive alla fine: prima di
# toccare stato.ts bisogna che ogni giro iniziato sia anche concluso.
giri_conclusi() { [ -f "$E/run/stato.debug" ] && grep -c 'giro concluso' "$E/run/stato.debug" || echo 0; }
giri_chiusi() { [ "$(giri_conclusi)" -ge "$(giri)" ]; }
passi_sono() { [ "$(passi)" -ge "$1" ]; }

NOISE=$(rumore 8)
echo "  (rumore di fondo del computer: $NOISE processi in 8 s)"
# Il pid scritto e' quello del demone (exec), non della subshell di denv.
denv "$BB" sh -c 'echo $$ > "$1"; shift; exec "$@"' sh "$E/dpid" "$BB" sh "$OVERLAY/usr/bin/sweetspot-stato" sorveglia > "$E/demone.out" 2>&1 &
attendi 10 test -s "$E/dpid"
DPID=$(cat "$E/dpid" 2>/dev/null)
attendi 20 test -s "$E/run/stato.json"
if [ ! -s "$E/run/stato.json" ]; then
	echo "  il demone non ha scritto la cache; uscita del demone:"
	sed 's/^/    | /' "$E/demone.out" | head -n 30
	kill -0 "$DPID" 2>/dev/null && echo "    (il processo e' ancora vivo)" || echo "    (il processo e' terminato)"
fi
expect "demone: primo giro all'avvio, cache scritta" "1" "$(giri)"
expect "demone: FIFO delle richieste scrivibile da tutti, quelle interne no" "622|600" "$(stat -c %a "$E/run/stato.richiesta")|$(stat -c %a "$E/run/stato.cli")"
expect "demone: cache del DAC attiva" "si" "$([ -f "$E/run/dac.cache.attiva" ] && echo si || echo no)"
attendi 10 grep -q "version ?" "$E/cli.cmd" 2>/dev/null
case "$(cat "$E/cli.cmd" 2>/dev/null)" in
	*"subscribe playlist,mixer,prefset,client,rescan"*) ok "CLI: iscrizione a playlist, mixer, prefset, client, rescan" ;;
	*) ko "CLI iscrizione" "subscribe playlist,mixer,prefset,client,rescan" "$(cat "$E/cli.cmd" 2>/dev/null)" ;;
esac
attendi 10 passi_sono 1
if [ "$(passi)" -ge 1 ]; then ok "precarico: un passo all'avvio"; else ko "precarico: un passo all'avvio" ">= 1" "$(passi)"; fi

# A riposo il demone non lancia alcun processo, nemmeno durante un ping.
# Prima si aspetta che l'avvio si sia assestato (al massimo 20 s).
assesta
finestra "riposo: nessun processo lanciato dal demone in 8 s (ping CLI compreso)"
case "$(grep -c 'version ?' "$E/cli.cmd")" in 1|0) ko "riposo: ping CLI" "almeno 2 version ?" "$(grep -c 'version ?' "$E/cli.cmd")" ;; *) ok "riposo: il ping di liveness passa dalla CLI" ;; esac
expect "riposo: nessun giro del check" "1" "$(giri)"

# Eventi che non devono muovere nulla: volume e preferenze qualunque.
P0=$(passi)
invia "$E/cli.in" "$ENC mixer volume 40"
invia "$E/cli.in" "prefset server currentVersion 9.1.1"
sleep 3
expect "CLI: mixer e prefset qualunque non fanno giri ne' passi" "1|$P0" "$(giri)|$(passi)"

# Eventi playlist -> precarico.
invia "$E/cli.in" "$ENC playlist newsong Titolo 3"
attendi 10 passi_sono $((P0 + 1))
expect "CLI: evento playlist, un passo del precarico" "$((P0 + 1))" "$(passi)"
invia "$E/cli.in" "02%3A00%3A00%3A00%3A00%3A99 playlist newsong Altro 1"
sleep 3
expect "CLI: playlist di un altro player ignorata" "$((P0 + 1))" "$(passi)"

# udev.
mkdir -p "$E/run/dac.cache"
echo x > "$E/run/dac.cache/hw.1"
invia "$E/udev.in" 'UDEV  [12.345] add      /devices/pci0000:00/0000:00:14.0/usb1/1-1/sound/card1 (sound)'
attendi 10 giri_sono 2
expect "udev: evento sound, nuovo giro" "2" "$(giri)"
expect "udev: evento sound, cache del DAC svuotata" "no" "$([ -e "$E/run/dac.cache" ] && echo si || echo no)"
invia "$E/udev.in" 'UDEV  [13.000] add      /devices/virtual/net/tap0 (net)'
attendi 10 giri_sono 3
expect "udev: evento net, nuovo giro" "3" "$(giri)"
invia "$E/udev.in" 'UDEV  [14.000] change   /devices/pci0000:00/block/sda (block)'
attendi 10 giri_sono 4
expect "udev: evento block, nuovo giro" "4" "$(giri)"

# inotify sulla configurazione.
printf '%s\nLIVENESS=si\n' "$(cat "$E/run/sweetspot.conf")" > "$E/run/sweetspot.conf.n" && mv "$E/run/sweetspot.conf.n" "$E/run/sweetspot.conf"
invia "$E/ino.in" "$(printf 'y\t%s/sweetspot.conf\n' "$E/run")"
attendi 10 giri_sono 5
expect "inotify: configurazione cambiata, nuovo giro" "5" "$(giri)"
invia "$E/ino.in" "$(printf 'w\t%s/qualcosa.altro\n' "$E/run")"
sleep 3
expect "inotify: file non osservato ignorato" "5" "$(giri)"

# Richiesta di chi legge la cache (pagina Stato, stato.json, plugin).
attendi 20 giri_chiusi
echo "1000 20" > "$E/run/stato.ts"
denv "$BB" sh -c '. "$SWEETSPOT_LIB/common.sh"; stato_richiedi' > /dev/null 2>&1
read -r nuovo _ < "$E/run/stato.ts"
if [ "$nuovo" -gt 1000 ]; then ok "richiesta: stato_richiedi ottiene un giro nuovo e aspetta il file"; else ko "richiesta" "ts aggiornato" "$nuovo"; fi
expect "richiesta: un giro in piu'" "6" "$(giri)"
denv "$BB" sh -c '. "$SWEETSPOT_LIB/common.sh"; stato_richiedi' > /dev/null 2>&1
expect "richiesta: cache fresca, nessun giro" "6" "$(giri)"

# Scansione: lo scanner (figlio di Lyrion) passa a +500, gli altri no.
invia "$E/cli.in" "rescan starting"
attendi 10 grep -qx 500 "$E/proc/4243/oom_score_adj"
expect "rescan: scanner di Lyrion a +500 nell'OOM killer" "500|-100" "$(cat "$E/proc/4243/oom_score_adj")|$(cat "$E/proc/4244/oom_score_adj")"
invia "$E/cli.in" "rescan done"

# Liveness del player: play ma il PCM non e' RUNNING.
PRIMA=$(esegui)
echo play > "$E/modo"
invia "$E/cli.in" "$ENC playlist play"
T0=$(date +%s)
attendi 30 sh -c "! kill -0 $SQ 2>/dev/null"
T1=$(date +%s)
expect "player: play senza PCM RUNNING, squeezelite fermato" "no" "$(kill -0 "$SQ" 2>/dev/null && echo si || echo no)"
if [ $((T1 - T0)) -le 12 ]; then ok "player: bloccato rilevato in $((T1 - T0)) s (soglia 4 s)"; else ko "player: tempo di rilevazione" "<= 12 s" "$((T1 - T0)) s"; fi
case "$(cat "$E/log" 2>/dev/null)" in *"liveness: player bloccato"*"riavvio squeezelite"*) ok "player: riavvio registrato nel log" ;; *) ko "player: log" "evento" "$(cat "$E/log" 2>/dev/null)" ;; esac

# PCM RUNNING mentre Lyrion e' in play: nessun processo, nessun intervento.
sleep 7200 &
SQ=$!
echo "$LMS $SQ" > "$WORK/pids"
echo "$SQ" > "$E/run/squeezelite.pid"
printf 'state: RUNNING\n' > "$E/proc/asound/card1/pcm0p/sub0/status"
invia "$E/ino.in" "$(printf 'y\t%s/squeezelite.pid\n' "$E/run")"
assesta
finestra "player: PCM RUNNING, nessun fork del demone in 8 s"
expect "player: PCM RUNNING, squeezelite resta" "si" "$(kill -0 "$SQ" 2>/dev/null && echo si || echo no)"

# Liveness di Lyrion: la CLI non risponde e il JSON-RPC nemmeno.
touch "$E/muto" "$E/rpc-muto"
attendi 40 sh -c "! kill -0 $LMS 2>/dev/null"
expect "Lyrion: nessuna risposta alla CLI ne' al JSON-RPC, riavvio" "no" "$(kill -0 "$LMS" 2>/dev/null && echo si || echo no)"
case "$(cat "$E/log" 2>/dev/null)" in *"liveness: Lyrion in stallo"*) ok "Lyrion: riavvio registrato nel log" ;; *) ko "Lyrion log" "evento" "$(cat "$E/log" 2>/dev/null)" ;; esac
rm -f "$E/muto" "$E/rpc-muto"

# Fine: il demone esce su TERM, ripulisce FIFO e cache attiva.
kill "$DPID"
attendi 10 sh -c "! kill -0 $DPID 2>/dev/null"
expect "demone: TERM, esce" "no" "$(kill -0 "$DPID" 2>/dev/null && echo si || echo no)"
DPID=''
expect "demone: FIFO e cache attiva rimosse" "no" "$([ -e "$E/run/stato.richiesta" ] || [ -e "$E/run/dac.cache.attiva" ] && echo si || echo no)"

# Controlli sul sorgente: niente piu' poller.
if grep -q '^oom_watch()' "$OVERLAY/usr/bin/sweetspot-lms"; then
	ko "sweetspot-lms: niente oom_watch" "assente" "presente"
else ok "sweetspot-lms: niente oom_watch (lo scanner lo gestisce il demone a eventi)"; fi
if grep -Eq '^[[:space:]]*sleep ' "$OVERLAY/usr/bin/sweetspot-stato" "$OVERLAY/usr/bin/sweetspot-precarico"; then
	ko "stato/precarico: nessun sleep di polling" "nessuno" "$(grep -En '^[[:space:]]*sleep ' "$OVERLAY/usr/bin/sweetspot-stato" "$OVERLAY/usr/bin/sweetspot-precarico")"
else ok "stato/precarico: nessun sleep di polling"; fi
if grep -q 'grep' "$OVERLAY/usr/lib/sweetspot/common.sh" && sed -n '/^dac_playing()/,/^}/p' "$OVERLAY/usr/lib/sweetspot/common.sh" | grep -q 'grep'; then
	ko "dac_playing senza grep" "solo shell" "usa grep"
else ok "dac_playing: solo comandi interni della shell"; fi

echo "Prove: $PASS riuscite, $FAIL fallite"
[ "$FAIL" -eq 0 ]
