#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Richieste delle pagine amministrative a Lyrion: cache breve condivisa senza
# richieste duplicate in volo, timeout distinti per lettura e scrittura, errori
# distinti (non in esecuzione / in avvio / timeout / errore applicativo /
# occupato), limite alle richieste contemporanee e operazioni lunghe in
# background con stato consultabile. Lyrion e' uno stub di wget (lento, assente
# o con errori): serve jq, il resto e' shell POSIX (BusyBox quando c'e').
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
CGI=$OVERLAY/usr/share/sweetspot/www/cgi-bin
WORK=$(mktemp -d)
trap 'kill $(cat "$WORK"/*.pid 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

BB=$(command -v busybox || true)
if [ -n "$BB" ]; then
	mkdir -p "$WORK/bb"
	for a in $("$BB" --list); do ln -sf "$BB" "$WORK/bb/$a"; done
	export SWEETSPOT_PATH="$WORK/bb"
fi

RUNDIR=$WORK/run
STUB=$WORK/stub
mkdir -p "$RUNDIR" "$STUB"
: > "$STUB/chiamate"

# Stub di Lyrion: il comportamento si sceglie in $STUB/modo.
#   ok      risponde subito       lento   risponde dopo $STUB/ritardo s
#   assente connessione rifiutata  errore  risposta con errore RPC
#   muto    non risponde mai entro -T (esce con errore dopo -T secondi)
cat > "$STUB/wget" <<'EOF'
#!/bin/sh
T=0
while [ $# -gt 0 ]; do
	case "$1" in -T) T=$2; shift ;; --post-data) D=$2; shift ;; esac
	shift
done
echo "T=$T $D" >> "$STUBDIR/chiamate"
case "$(cat "$STUBDIR/modo")" in
	ok) echo '{"id":1,"result":{"_version":"9","errore":""}}' ;;
	lento) sleep "$(cat "$STUBDIR/ritardo")"; echo '{"id":1,"result":{"_version":"9"}}' ;;
	assente) exit 1 ;;
	errore) echo '{"id":1,"error":"boom"}' ;;
	muto) sleep "$T"; exit 1 ;;
esac
EOF
chmod +x "$STUB/wget"

export STUBDIR=$STUB SWEETSPOT_WGET=$STUB/wget SWEETSPOT_RUN=$RUNDIR SWEETSPOT_LOG=$WORK/log \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot
modo() { echo "$1" > "$STUB/modo"; }
chiamate() { grep -c . "$STUB/chiamate"; }
azzera() { : > "$STUB/chiamate"; rm -rf "$RUNDIR/lms-cache" "$RUNDIR/lms-posti" "$RUNDIR/lms.pid"; }

# Esegue una funzione di common.sh come pagina web (LMS_WEB=1): stampa l'esito.
web() {
	( LMS_WEB=1 sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; $*" )
}
rc_di() { "$@" > /dev/null 2>&1; echo $?; }

echo "Cache condivisa delle letture"
modo ok; azzera
web "lms_json '' serverstatus 0 0" > /dev/null
web "lms_json '' serverstatus 0 0" > /dev/null
expect "due letture uguali ravvicinate: una sola richiesta a Lyrion" 1 "$(chiamate)"
web "lms_json '' version '?'" > /dev/null
expect "una lettura diversa non usa la cache dell'altra" 2 "$(chiamate)"
azzera
LMS_CACHE_TTL=1 web "lms_json '' serverstatus 0 0" > /dev/null
sleep 3
LMS_CACHE_TTL=1 web "lms_json '' serverstatus 0 0" > /dev/null
expect "scaduta la cache la lettura si rifa" 2 "$(chiamate)"
azzera
web "lms_json '' serverstatus 0 0" > /dev/null
web "lms_json '' rescan" > /dev/null
web "lms_json '' serverstatus 0 0" > /dev/null
expect "una scrittura svuota la cache delle letture" 3 "$(chiamate)"
azzera
( LMS_CACHE_TTL=0 web "lms_json '' serverstatus 0 0"; LMS_CACHE_TTL=0 web "lms_json '' serverstatus 0 0" ) > /dev/null
expect "LMS_CACHE_TTL=0 disattiva la cache" 2 "$(chiamate)"
azzera
( . "$OVERLAY/usr/lib/sweetspot/common.sh"; lms_json '' serverstatus 0 0; lms_json '' serverstatus 0 0 ) > /dev/null 2>&1
expect "fuori dalle pagine web (demone) niente cache" 2 "$(chiamate)"

echo "Richieste identiche in volo"
modo lento; echo 4 > "$STUB/ritardo"; azzera
i=0
while [ $i -lt 5 ]; do
	LMS_CACHE_TTL=60 LMS_TIMEOUT_LETTURA=30 web "lms_json '' serverstatus 0 0" > "$WORK/par.$i" 2>&1 &
	i=$((i + 1))
done
wait
expect "5 letture uguali in parallelo: una sola richiesta" 1 "$(chiamate)"
expect "tutte hanno la risposta" 5 "$(cat "$WORK"/par.* | grep -c _version)"

echo "Timeout distinti"
modo ok; azzera
web "lms_json '' serverstatus 0 0" > /dev/null
web "lms_json '' rescan" > /dev/null
expect "lettura: timeout breve (5 s)" "T=5" "$(sed -n 1p "$STUB/chiamate" | cut -d' ' -f1)"
expect "scrittura: timeout piu' lungo (10 s)" "T=10" "$(sed -n 2p "$STUB/chiamate" | cut -d' ' -f1)"
azzera
LMS_TIMEOUT_LETTURA=2 LMS_TIMEOUT_SCRITTURA=7 web "lms_json '' version '?'; lms_json '' wipecache" > /dev/null
expect "i timeout si configurano" "T=2 T=7" "$(cut -d' ' -f1 "$STUB/chiamate" | tr '\n' ' ' | tr -s ' ' | awk '{$1=$1}1')"

echo "Errori distinti"
modo assente; azzera
expect "Lyrion non in esecuzione: codice 2" 2 "$(rc_di web "lms_json '' serverstatus 0 0")"
sleep 30 &
echo $! > "$WORK/lms.pid"
cp "$WORK/lms.pid" "$RUNDIR/lms.pid"
rm -rf "$RUNDIR/lms-cache"
expect "servizio vivo ma senza risposta: in avvio, codice 3" 3 "$(rc_di web "lms_json '' serverstatus 0 0")"
modo muto; rm -rf "$RUNDIR/lms-cache"
expect "nessuna risposta entro il tempo: timeout, codice 4" 4 "$(rc_di env LMS_TIMEOUT_LETTURA=1 sh -c "LMS_WEB=1; export LMS_WEB; . $OVERLAY/usr/lib/sweetspot/common.sh; lms_json '' serverstatus 0 0")"
modo errore; rm -rf "$RUNDIR/lms-cache"
expect "errore RPC: applicativo, codice 5" 5 "$(rc_di web "lms_json '' serverstatus 0 0")"
expect "nomi degli errori" "non_in_esecuzione in_avvio timeout applicativo occupato" \
	"$(web 'for c in 2 3 4 5 6; do lms_errore_nome $c; done' | tr '\n' ' ' | awk '{$1=$1}1')"
expect "testo dell'errore di timeout" "Lyrion non risponde (tempo scaduto)." "$(web 'lms_errore_testo 4')"
kill "$(cat "$WORK/lms.pid")" 2>/dev/null; rm -f "$RUNDIR/lms.pid" "$WORK/lms.pid"

echo "Limite alle richieste contemporanee"
modo lento; echo 3 > "$STUB/ritardo"; azzera
i=0
while [ $i -lt 4 ]; do
	( LMS_MAX_CONCORRENTI=2 LMS_ATTESA_POSTO=1 web "lms_json '' rescan" > /dev/null 2>&1; echo $? > "$WORK/lim.$i" ) &
	i=$((i + 1))
done
wait
expect "4 scritture con limite 2: due partono" 2 "$(chiamate)"
expect "le altre due cadono subito con 'occupato' (6)" 2 "$(cat "$WORK"/lim.* | grep -c '^6$')"
expect "i posti sono rilasciati a fine lavoro" 0 "$(ls "$RUNDIR/lms-posti" 2>/dev/null | wc -l | tr -d ' ')"
mkdir -p "$RUNDIR/lms-posti/1"; echo 999999 > "$RUNDIR/lms-posti/1/pid"
modo ok
expect "il posto di un processo morto si recupera" 0 "$(rc_di web "lms_json '' rescan")"

echo "Operazioni in background"
LMS="$OVERLAY/usr/bin/sweetspot-lms"
chmod +x "$LMS" 2>/dev/null
op() { sh "$LMS" operazione "$@"; }
attendi() { # ID: aspetta che l'operazione finisca (al massimo ~10 s)
	local n=0
	while [ $n -lt 50 ]; do
		[ "$(op stato "$1" | jq -r .stato)" != in_corso ] && return 0
		sleep 0.2
		n=$((n + 1))
	done
	return 1
}
modo ok; azzera; rm -rf "$RUNDIR/operazioni"
t0=$(date +%s)
id=$(op avvia plugin-installa Qobuz)
t1=$(date +%s)
expect "l'avvio restituisce un identificativo" 1 "$(printf '%s' "$id" | grep -cE '^[0-9]+-[0-9a-f]+$')"
attendi "$id"
expect "stato: riuscita" riuscita "$(op stato "$id" | jq -r .stato)"
expect "stato: versione, tipo e nome" "1 plugin-installa Qobuz" "$(op stato "$id" | jq -r '"\(.versione) \(.tipo) \(.nome)"')"
expect "stato: nessun errore" null "$(op stato "$id" | jq -r .errore)"
expect "stato: messaggio per l'utente" 1 "$(op stato "$id" | jq -r .messaggio | grep -c 'riavvia Lyrion')"
expect "stato: leggibile da tutti" 1 "$(ls -l "$RUNDIR/operazioni/$id.json" | cut -c8 | grep -c r)"
expect "la richiesta a Lyrion e' quella del plugin" 1 "$(grep -c 'plugin-installa' "$STUB/chiamate")"

modo lento; echo 8 > "$STUB/ritardo"
t0=$(date +%s)
id1=$(op avvia plugin-installa Radio)
t1=$(date +%s)
expect "l'avvio non aspetta il lavoro (Lyrion impiega 8 s)" 1 "$([ $((t1 - t0)) -lt 6 ] && echo 1 || echo 0)"
id2=$(op avvia plugin-installa Radio)
expect "la stessa operazione in corso non si duplica" "$id1" "$id2"
expect "in corso mentre lavora" in_corso "$(op stato "$id1" | jq -r .stato)"
attendi "$id1"
expect "finita dopo il ritardo" riuscita "$(op stato "$id1" | jq -r .stato)"

modo assente
id=$(op avvia aggiorna); attendi "$id"
expect "Lyrion assente: fallita" fallita "$(op stato "$id" | jq -r .stato)"
expect "Lyrion assente: errore distinto" non_in_esecuzione "$(op stato "$id" | jq -r .errore)"
expect "Lyrion assente: messaggio" "Lyrion non è in esecuzione." "$(op stato "$id" | jq -r .messaggio)"
modo errore
id=$(op avvia plugin-rimuovi Radio); attendi "$id"
expect "errore di Lyrion: fallita con errore applicativo" "fallita applicativo" "$(op stato "$id" | jq -r '"\(.stato) \(.errore)"')"
modo muto
id=$(LMS_TIMEOUT_OP=1 op avvia ricostruisci); attendi "$id"
expect "Lyrion muto: errore timeout" "fallita timeout" "$(op stato "$id" | jq -r '"\(.stato) \(.errore)"')"

expect "tipo sconosciuto rifiutato" 1 "$(rc_di op avvia riavvia)"
expect "nome non valido rifiutato" 1 "$(rc_di op avvia plugin-installa '../x')"
expect "plugin senza nome rifiutato" 1 "$(rc_di op avvia plugin-installa)"
expect "identificativo non valido nello stato" 1 "$(rc_di op stato '../x')"

# Un'operazione rimasta in_corso senza processo diventa fallita.
printf '{"versione":1,"id":"1-aa","tipo":"aggiorna","nome":"","stato":"in_corso","messaggio":"In corso.","errore":null,"avviata":1,"aggiornata":1}\n' > "$RUNDIR/operazioni/1-aa.json"
modo ok
id=$(op avvia aggiorna); attendi "$id"
expect "operazione orfana recuperata come fallita" "fallita operazione" "$(op stato 1-aa | jq -r '"\(.stato) \(.errore)"')"

echo "CGI operazione"
# httpd -d (decodifica dell'URL) c'e' solo in BusyBox: senza, un finto in coda al PATH.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/httpd" <<'EOF'
#!/bin/sh
[ "$1" = -d ] && printf '%s\n' "$2"
EOF
chmod +x "$WORK/fakebin/httpd"
cgi() { # QUERY (con & finale: query_param legge righe intere)
	PATH="$PATH:$WORK/fakebin" SWEETSPOT_RUN=$RUNDIR REQUEST_METHOD=GET QUERY_STRING="$1&" HTTP_HOST=sweetspot.local sh "$CGI/operazione"
}
modo ok
id=$(op avvia aggiorna); attendi "$id"
out=$(cgi "id=$id")
expect "CGI: 200 e JSON" 1 "$(printf '%s' "$out" | grep -c 'Status: 200')"
expect "CGI: corpo con lo stato" riuscita "$(printf '%s\n' "$out" | sed -n '/^{/p' | jq -r .stato)"
expect "CGI: identificativo sconosciuto, 404" 1 "$(cgi 'id=9-ff' | grep -c 'Status: 404')"
expect "CGI: identificativo non valido, 400" 1 "$(cgi 'id=../x' | grep -c 'Status: 400')"
expect "CGI: senza identificativo, 400" 1 "$(cgi '' | grep -c 'Status: 400')"

echo
echo "admin-operazioni: $PASS ok, $FAIL falliti"
[ "$FAIL" -eq 0 ]
