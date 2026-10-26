#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Diario di bordo: timeline, registro persistente sulla chiavetta (poche
# scritture, rotazione), pstore, spegnimento ordinato, XRUN e frequenze, bundle
# diagnostico senza segreti e pagina scaricabile solo dopo l'accesso. La
# chiavetta e' una cartella (SWEETSPOT_STICK_DIR), /proc e /sys sono finti.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
CGI=$OVERLAY/usr/share/sweetspot/www/cgi-bin
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot"
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

BB=$(command -v busybox || true)
BASEPATH=/usr/bin:/bin
if [ -n "$BB" ]; then
	mkdir -p "$WORK/bb"
	for a in $("$BB" --list); do ln -sf "$BB" "$WORK/bb/$a"; done
	BASEPATH="$WORK/bb:$BASEPATH"
fi

E=$WORK/e
mkdir -p "$E/run/web" "$E/proc/asound/card1/pcm0p/sub0" "$E/sys" "$E/stick" "$E/bin"
echo "quiet loglevel=3" > "$E/proc/cmdline"
printf 'MemTotal: 1000 kB\n' > "$E/proc/meminfo"
echo "card 1: Fake DAC" > "$E/proc/asound/cards"
printf '#!/bin/sh\necho "[    1.0] kernel di prova password=hunter2"\n' > "$E/bin/dmesg"
printf '#!/bin/sh\necho "**** List of PLAYBACK Hardware Devices ****"\necho "card 1: Fake [Fake DAC]"\n' > "$E/bin/aplay"
printf '#!/bin/sh\necho "Squeezelite v2.0 prova"\n' > "$E/bin/squeezelite"
printf '#!/bin/sh\necho "CamillaDSP 3.0 prova"\n' > "$E/bin/camilladsp"
# flock: l'applet di BusyBox in CI; dove manca (prova locale) basta un finto.
command -v flock > /dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' > "$E/bin/flock"
chmod +x "$E/bin/"*
cp "$OVERLAY/etc/sweetspot/defaults.conf" "$E/run/sweetspot.conf"
printf 'DIARIO_KB=16\nPASSWORD_WEB=segreto-web-123\nWIFI_PASSWORD=segreto-wifi-456\nWIFI_NOME=CasaRossi\nSSH_PASSWORD=segreto-ssh-789\n' >> "$E/run/sweetspot.conf"
echo '{"ts":1,"voci":[{"voce":"Rete","dettaglio":"http://admin:segreto-url-000@host/"}]}' > "$E/run/stato.json"

# Esegue il codice in un ambiente finto, con la libreria caricata.
env_run() { # comando...
	env SWEETSPOT_RUN="$E/run" SWEETSPOT_LOG="$E/log" SWEETSPOT_PROCFS="$E/proc" SWEETSPOT_SYSFS="$E/sys" \
		SWEETSPOT_STICK_DIR="$E/stick" SWEETSPOT_PSTORE="$E/pstore" SWEETSPOT_SQLOG="$E/squeezelite.log" \
		SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" SWEETSPOT_PATH="$E/bin:$BASEPATH" "$@"
}
D() { env_run sh "$OVERLAY/usr/bin/sweetspot-diario" "$@"; }
lib() { env_run SWEETSPOT_TEST=1 sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $OVERLAY/usr/bin/sweetspot-diario; $1"; }
STICKLOG=$E/stick/diagnostica

echo "Struttura"
expect "kernel: pstore, console e ramoops" "4" "$(grep -c '^CONFIG_PSTORE=y\|^CONFIG_PSTORE_CONSOLE=y\|^CONFIG_PSTORE_RAM=y\|^CONFIG_PSTORE_DEFLATE_COMPRESS=y' "$ROOT/board/sweetspot/common/linux.fragment")"
expect "x86: efi-pstore" "1" "$(grep -c '^CONFIG_EFI_VARS_PSTORE=y' "$ROOT/board/sweetspot/x86/linux.fragment")"
expect "Raspberry Pi: memoria riservata per ramoops" "1" "$(grep -c '^dtoverlay=ramoops' "$ROOT/board/sweetspot/rpi/config.txt")"
expect "il bundle passa dall'helper privilegiato" "1" "$(grep -c '"sweetspot-diario", "bundle"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
expect "servizio di avvio e arresto" "1|1" "$(grep -c 'sweetspot-diario avvio' "$OVERLAY/etc/init.d/S04sweetspot-diario")|$(grep -c 'sweetspot-diario spegni' "$OVERLAY/etc/init.d/S04sweetspot-diario")"
expect "la pagina Sistema offre il download" "1" "$(grep -c 'href="/cgi-bin/diagnostica"' "$CGI/sistema")"

echo "Timeline"
lib 'evento lyrion avvio "sui core 0|1
due righe"; evento alsa xrun "3 nuovi"'
expect "una riga per evento: data, sorgente, evento, dettagli" "2|lyrion|avvio|sui core 0 1 due righe" \
	"$(wc -l < "$E/run/timeline.log" | tr -d ' ')|$(sed -n 1p "$E/run/timeline.log" | cut -d'|' -f2-4)"
expect "data ISO nella prima colonna" "1" "$(sed -n 1p "$E/run/timeline.log" | grep -c '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]\{8\}|')"
expect "eventi normali: nessuna richiesta di salvataggio" "no" "$([ -f "$E/run/diario.urgente" ] && echo si || echo no)"
lib 'evento sistema spegnimento x'
expect "evento critico: richiesta di salvataggio" "si" "$([ -f "$E/run/diario.urgente" ] && echo si || echo no)"
rm -f "$E/run/diario.urgente" "$E/run/timeline.log"
lib 'log "aggiornamento: versione 1.2 installata nella copia b"; log "aggiornamento: la nuova versione (copia b) non e'"'"' partita, si e'"'"' tornati alla precedente"
log "liveness: Lyrion in stallo dopo 3 fallimenti, riavvio (pid 5, riavvio 1)"; log "liveness: player bloccato da 30 s, riavvio squeezelite pid 7 (riavvio 1)"
log "lyrion: fermo (codice 1), riavvio"; log "player: riavvio del player"; log "player: attivo su Fake DAC"; log "dati: salvati sulla chiavetta"'
expect "log -> timeline: aggiornamento, rollback, liveness, lyrion e player" \
	"aggiorna|aggiornamento;aggiorna|rollback;liveness|riavvio-lyrion;liveness|riavvio-player;lyrion|riavvio-lyrion;player|riavvio-player;player|stato" \
	"$(cut -d'|' -f2,3 "$E/run/timeline.log" | tr '\n' ';' | sed 's/;$//')"
expect "righe non rilevanti restano fuori dalla timeline" "0" "$(grep -c 'dati' "$E/run/timeline.log")"
rm -f "$E/run/diario.urgente" "$E/run/timeline.log" "$E/log"

echo "Registro persistente"
echo "2026-01-01 00:00:01 prima riga" > "$E/log"
lib 'evento sistema avvio prova'
D salva
expect "primo salvataggio: registro e timeline sulla chiavetta" "1|1" "$(wc -l < "$STICKLOG/sweetspot.log" | tr -d ' ')|$(wc -l < "$STICKLOG/timeline.log" | tr -d ' ')"
expect "ultime righe del kernel salvate (segreti oscurati)" "1|0" "$(grep -c 'kernel di prova' "$STICKLOG/kernel.ultimo")|$(grep -c hunter2 "$STICKLOG/kernel.ultimo")"
expect "il montaggio del salvataggio non entra nella timeline" "0" "$(grep -c chiavetta "$E/run/timeline.log")"
touch "$WORK/riferimento"
sleep 1
D salva
expect "nulla di nuovo: nessuna scrittura" "" "$(find "$STICKLOG" -type f -newer "$WORK/riferimento")"
echo "2026-01-01 00:00:02 seconda riga" >> "$E/log"
D salva
expect "si aggiunge solo il nuovo, in coda" "prima riga|seconda riga|2" "$(sed -n 1p "$STICKLOG/sweetspot.log" | cut -d' ' -f3-4)|$(sed -n 2p "$STICKLOG/sweetspot.log" | cut -d' ' -f3-4)|$(wc -l < "$STICKLOG/sweetspot.log" | tr -d ' ')"
rm -rf "$E/stick/diagnostica"
mv "$E/stick" "$E/stick.assente"
echo "2026-01-01 00:00:03 terza riga" >> "$E/log"
D salva > /dev/null 2>&1
expect "chiavetta assente: il salvataggio non riesce" "1" "$?"
mv "$E/stick.assente" "$E/stick"
D salva
expect "chiavetta di ritorno: le righe arrivano" "1" "$(grep -c 'terza riga' "$STICKLOG/sweetspot.log")"

echo "Rotazione e dimensione limitata"
rm -rf "$E/stick/diagnostica" "$E/run/"diario.*.off "$E/log"
i=0
while [ $i -lt 13 ]; do
	awk -v n=$i 'BEGIN { for (k = 0; k < 40; k++) printf "2026-01-01 00:00:00 blocco %d riga %d %s\n", n, k, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' >> "$E/log"
	D salva
	i=$((i + 1))
done
expect "rotazione: file, .1 e .2 presenti" "si|si" "$([ -f "$STICKLOG/sweetspot.log.1" ] && echo si || echo no)|$([ -f "$STICKLOG/sweetspot.log.2" ] && echo si || echo no)"
expect "rotazione: mai una quarta generazione" "no" "$([ -e "$STICKLOG/sweetspot.log.3" ] && echo si || echo no)"
tot=$(cat "$STICKLOG"/sweetspot.log* | wc -c | tr -d ' ')
expect "dimensione totale limitata (3 x 16 KB + un blocco)" "si" "$([ "$tot" -le $((3 * 16 * 1024 + 8192)) ] && echo si || echo no)"
expect "l'ultimo blocco e' nel file corrente" "1" "$(grep -c 'blocco 12 riga 39' "$STICKLOG/sweetspot.log")"
rm -rf "$E/stick/diagnostica" "$E/run/"diario.*.off "$E/log" "$E/run/timeline.log"

echo "Avvio, spegnimento ordinato e pstore"
mkdir -p "$E/pstore"
echo "panic: oops" > "$E/pstore/dmesg-ramoops-0"
echo "console: ultime righe" > "$E/pstore/console-ramoops-0"
D avvio
d1=$(ls "$STICKLOG/pstore" 2>/dev/null | head -n 1)
expect "pstore copiato sulla chiavetta" "2|panic: oops" "$(ls "$STICKLOG/pstore/$d1" 2>/dev/null | wc -l | tr -d ' ')|$(cat "$STICKLOG/pstore/$d1/dmesg-ramoops-0" 2>/dev/null)"
expect "pstore svuotato dopo la copia" "0" "$(ls "$E/pstore" | wc -l | tr -d ' ')"
expect "avvio in timeline: spegnimento precedente non ordinato" "1|1" \
	"$(grep -c '|sistema|avvio|.*ordinato: no' "$STICKLOG/timeline.log")|$(grep -c '|kernel|pstore|2 file' "$STICKLOG/timeline.log")"
D spegni
expect "spegnimento: evento nel registro persistente e segno di arresto ordinato" "1|si" \
	"$(grep -c '|sistema|spegnimento|' "$STICKLOG/timeline.log")|$([ -f "$STICKLOG/pulito" ] && echo si || echo no)"
D avvio
expect "avvio dopo spegnimento ordinato: riconosciuto, segno tolto" "1|no" \
	"$(grep -c 'ordinato: si' "$STICKLOG/timeline.log")|$([ -f "$STICKLOG/pulito" ] && echo si || echo no)"
# Oltre il limite si tengono le raccolte piu' recenti.
for n in 01 02 03 04 05 06 07 08 09 10; do mkdir -p "$STICKLOG/pstore/2000010${n}-000000"; done
echo "x" > "$E/pstore/dmesg-ramoops-1"
D avvio
expect "al massimo 8 raccolte di crash dump" "8" "$(ls "$STICKLOG/pstore" | wc -l | tr -d ' ')"
expect "restano le piu' recenti" "si" "$([ -d "$STICKLOG/pstore/$d1" ] && echo si || echo no)"
rm -rf "$E/stick/diagnostica" "$E/run/"diario.*.off "$E/log" "$E/run/timeline.log"

echo "Segreti filtrati sulla chiavetta"
echo "2026-01-01 00:10:00 rete WIFI_PASSWORD=fintapw123 WIFI_PSK=fintapsk456 ssid=Casa" >> "$E/log"
echo "panic: cmdline psk=fintapsk789 password=fintapw000 root=/dev/sda1" > "$E/pstore/dmesg-ramoops-9"
D salva
D avvio
tutto=$(cat "$STICKLOG"/sweetspot.log* "$STICKLOG"/pstore/*/* 2>/dev/null)
expect "chiavetta: nessuna password o PSK" "0" "$(printf '%s
' "$tutto" | grep -c 'fintapw\|fintapsk')"
expect "chiavetta: il resto della riga resta leggibile" "1|1" "$(printf '%s
' "$tutto" | grep -c 'rete WIFI_PASSWORD=\*\*\* WIFI_PSK=\*\*\* ssid=Casa')|$(printf '%s
' "$tutto" | grep -c 'panic: cmdline psk=\*\*\* password=\*\*\* root=/dev/sda1')"
rm -rf "$STICKLOG" "$E/pstore"/*

echo "Con DIARIO=no non si scrive nulla"
echo "DIARIO=no" >> "$E/run/sweetspot.conf"
lib 'evento sistema avvio x'
D salva; D spegni; D avvio
expect "nessuna cartella sulla chiavetta" "no" "$([ -e "$STICKLOG" ] && echo si || echo no)"
grep -v '^DIARIO=no' "$E/run/sweetspot.conf" > "$E/run/c.tmp" && mv "$E/run/c.tmp" "$E/run/sweetspot.conf"
rm -f "$E/run/timeline.log"

echo "XRUN e cambi di frequenza"
: > "$E/squeezelite.log"
printf '[12:00:00.000] output_alsa:600 XRUN\n[12:00:01.000] output_alsa:600 XRUN\n[12:00:02.000] decode:12 altro\n' > "$E/squeezelite.log"
printf 'closed\n' > "$E/proc/asound/card1/pcm0p/sub0/hw_params"
lib 'osserva; osserva
printf "[12:00:03.000] output_alsa:600 XRUN\n" >> "$SWEETSPOT_SQLOG"
printf "format: S32_LE\nrate: 44100 (44100/1)\nchannels: 2\n" > "$SWEETSPOT_PROCFS/asound/card1/pcm0p/sub0/hw_params"
osserva
printf "format: S32_LE\nrate: 96000 (96000/1)\nchannels: 2\n" > "$SWEETSPOT_PROCFS/asound/card1/pcm0p/sub0/hw_params"
osserva; osserva'
expect "XRUN: un evento per ogni gruppo di nuovi XRUN (la base iniziale non conta)" "1|1 nuovi, recuperi falliti 0" \
	"$(grep -c '|alsa|xrun|' "$E/run/timeline.log")|$(sed -n 's/.*|alsa|xrun|//p' "$E/run/timeline.log")"
expect "frequenza: primo formato, poi il cambio con il valore precedente" "S32_LE 44100;S32_LE 96000 (prima S32_LE 44100)" \
	"$(sed -n 's/.*|alsa|frequenza|//p' "$E/run/timeline.log" | tr '\n' ';' | sed 's/;$//')"

echo "Bundle diagnostico"
mkdir -p "$E/pstore" "$E/stick/diagnostica/pstore/20260101-000000"
echo "dump salvato" > "$E/stick/diagnostica/pstore/20260101-000000/dmesg-ramoops-0"
echo "dump in memoria" > "$E/pstore/dmesg-ramoops-2"
echo "2026-01-01 00:00:09 wifi password=hunter2 token=abc123 key: k1" > "$E/log"
echo "[1.0] connessione http://utente:segreto-url-000@host/x Authorization: Basic QWxhZGRpbjpvcGVu" > "$E/squeezelite.log"
lib 'evento sistema avvio "token=zzz9"'
mkdir -p "$WORK/out"
D bundle > "$WORK/bundle.tar.gz"
expect "il bundle e' un tar.gz valido" "0" "$(tar -tzf "$WORK/bundle.tar.gz" > /dev/null 2>&1; echo $?)"
tar -xzf "$WORK/bundle.tar.gz" -C "$WORK/out"
B=$(ls -d "$WORK/out"/sweetspot-diagnostica-* 2>/dev/null | head -n 1)
for f in versioni.txt configurazione.txt log/sweetspot.log log/timeline.log log/sweetspot.persistente.log log/timeline.persistente.log \
	log/kernel.dmesg sistema/aplay-l.txt sistema/stato.json sistema/asound/cards pstore/20260101-000000/dmesg-ramoops-0 pstore/in-memoria/dmesg-ramoops-2; do
	expect "bundle contiene $f" "si" "$([ -s "$B/$f" ] && echo si || echo no)"
done
expect "versioni: squeezelite e camilladsp" "1|1" "$(grep -c 'squeezelite: Squeezelite v2.0' "$B/versioni.txt")|$(grep -c 'camilladsp: CamillaDSP 3.0' "$B/versioni.txt")"
expect "configurazione: valori normali conservati" "1" "$(grep -c '^WIFI_NOME=CasaRossi' "$B/configurazione.txt")"
secrets=$(grep -rl 'segreto-web-123\|segreto-wifi-456\|segreto-ssh-789\|segreto-url-000\|hunter2\|abc123\|QWxhZGRpbjpvcGVu\|zzz9' "$B" 2>/dev/null | wc -l | tr -d ' ')
expect "nessun segreto in nessun file del bundle" "0" "$secrets"
expect "le chiavi sensibili sono oscurate, non omesse" "PASSWORD_WEB=***|WIFI_PASSWORD=***" "$(grep '^PASSWORD_WEB=' "$B/configurazione.txt" | sort -u)|$(grep '^WIFI_PASSWORD=' "$B/configurazione.txt" | sort -u)"
expect "il bundle non tocca pstore in memoria" "1" "$(ls "$E/pstore" | grep -c dmesg-ramoops-2)"

echo "Pagina scaricabile solo con l'accesso"
cat > "$E/bin/sweetspot-priv" <<EOF
#!/bin/sh
exec env SWEETSPOT_PATH="$E/bin:$BASEPATH" "\$@"
EOF
printf '#!/bin/sh\nexec sh "%s/usr/bin/sweetspot-diario" "$@"\n' "$OVERLAY" > "$E/bin/sweetspot-diario"
chmod +x "$E/bin/sweetspot-priv" "$E/bin/sweetspot-diario"
cgi() { # PASSWORD_WEB [cookie]
	[ -n "$1" ] && printf 'PASSWORD_WEB=*\n' > "$E/run/sweetspot.web" || : > "$E/run/sweetspot.web"
	env_run SWEETSPOT_PRIV="$E/bin/sweetspot-priv" PATH="$E/bin:$BASEPATH" GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=127.0.0.1 REMOTE_ADDR=127.0.0.1 \
		HTTP_COOKIE="${2:-}" REQUEST_METHOD=GET SCRIPT_NAME=/cgi-bin/diagnostica QUERY_STRING="" sh "$CGI/diagnostica"
}
cgi si | tr -d '\r' | head -n 3 > "$WORK/auth.txt"
expect "con la password e senza sessione: rimanda all'accesso, nessun bundle" "Status: 303 See Other|Location: /cgi-bin/accesso" \
	"$(sed -n 1p "$WORK/auth.txt")|$(sed -n 2p "$WORK/auth.txt")"
cgi "" | tr -d '\r' | head -n 3 > "$WORK/primo.txt"
expect "senza password: rimanda al primo accesso, nessun bundle" "Status: 303 See Other|Location: /cgi-bin/primo-accesso" \
	"$(sed -n 1p "$WORK/primo.txt")|$(sed -n 2p "$WORK/primo.txt")"
# Sessione valida: un file con la scadenza, nome = ID del cookie.
SID=0123456789abcdef0123456789abcdef
mkdir -p "$E/run/web/sessioni"
echo $(($(date +%s) + 3600)) > "$E/run/web/sessioni/$SID"
cgi si "sweetspot_sid=$SID" > "$WORK/cgi.out"
expect "con la sessione: scarica un tar.gz con il nome e il tipo giusti" "1|1" \
	"$(head -c 400 "$WORK/cgi.out" | tr -d '\r' | grep -c '^Content-Disposition: attachment; filename="sweetspot-diagnostica-.*\.tar\.gz"')|$(head -c 400 "$WORK/cgi.out" | tr -d '\r' | grep -c '^Content-Type: application/gzip')"
# Il corpo comincia dopo la prima riga vuota (\r\n\r\n o \n\n), qualunque
# siano le intestazioni che la precedono.
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); i = [(d.find(s), len(s)) for s in (b"\r\n\r\n", b"\n\n") if d.find(s) >= 0]; p, n = min(i); open(sys.argv[2], "wb").write(d[p + n:])' "$WORK/cgi.out" "$WORK/cgi.body"
expect "il corpo della risposta e' il bundle" "0" "$(tar -tzf "$WORK/cgi.body" > /dev/null 2>&1; echo $?)"

echo
echo "Superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
