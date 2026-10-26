#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Regressioni operative: pacchetti, generazioni persistenti e dischi omonimi.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'if [ -n "${WALPID:-}" ]; then kill "$WALPID" 2>/dev/null; wait "$WALPID" 2>/dev/null; fi; chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
FAIL=0
PASS=0
BB=$(command -v busybox || true)
if [ -n "$BB" ]; then
	mkdir -p "$WORK/busybox"
	for a in $("$BB" --list); do ln -sf "$BB" "$WORK/busybox/$a"; done
	TEST_SH="$BB sh"
	BASE_PATH=$WORK/busybox
else
	TEST_SH='sh'
	BASE_PATH=/usr/bin
fi
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot"
SQLITE3=$(command -v sqlite3) || { echo 'Prerequisito mancante: sqlite3 è necessario per le regressioni del backup reale.' >&2; exit 1; }
expect() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

U=$WORK/upd
mkdir -p "$U/pkg" "$U/run" "$U/proc" "$U/stick/boot/grub" "$U/stick/boot/versioni"
echo 'sweetspot.slot=a' > "$U/proc/cmdline"
echo x86_64 > "$U/scheda"
echo A-kernel > "$U/stick/bzImage"
echo A-rootfs > "$U/stick/rootfs.cpio.zst"
mkpkg() {
	rm -rf "$U/pkg"; mkdir -p "$U/pkg"
	echo B-kernel > "$U/pkg/bzImage"
	echo B-rootfs > "$U/pkg/rootfs.cpio.zst"
	echo v2 > "$U/pkg/versione"
	echo x86_64 > "$U/pkg/architettura"
	(cd "$U/pkg" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
}
pack() { tar -C "$U/pkg" -cf "$U/update.tar" .; }
upd() {
	SWEETSPOT_TEST=${CLI_TEST:-cli} SWEETSPOT_ALLOW_UNSIGNED=${ALLOW_UNSIGNED:-1} SWEETSPOT_CHIAVE_FIRMA=${UPDATE_PUB:-$U/missing.pub} \
		SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_ARCH=${UPDATE_ARCH:-x86_64} SWEETSPOT_SCHEDA_FILE=$U/scheda SWEETSPOT_STICK_DIR=$U/stick \
		SWEETSPOT_AVVIO=$U/avvio \
		SWEETSPOT_RUN=$U/run SWEETSPOT_PROCFS=$U/proc SWEETSPOT_LOG=$U/log \
		$TEST_SH "$OVERLAY/usr/bin/sweetspot-aggiorna" _lavoro file "$U/update.tar" >/dev/null 2>&1
}
upd_state() { cut -d'|' -f1 "$U/run/aggiornamento/stato"; }
upd_probe() { # mutazione dopo l'ispezione, oppure copia locale fallita
	SWEETSPOT_TEST=1 SWEETSPOT_ALLOW_UNSIGNED=1 SWEETSPOT_CHIAVE_FIRMA=$U/missing.pub \
		SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_ARCH=x86_64 SWEETSPOT_SCHEDA_FILE=$U/scheda SWEETSPOT_STICK_DIR=$U/stick \
		SWEETSPOT_RUN=$U/run SWEETSPOT_PROCFS=$U/proc SWEETSPOT_LOG=$U/log \
		$TEST_SH -c '. "$1"; sourcepkg=$2; replacement=$3; probe=$4
			tar() {
				command tar "$@"; result=$?
				if [ "$probe" = mutate ] && [ "$1" = -tvf ]; then command cp "$replacement" "$sourcepkg"; fi
				return "$result"
			}
			cp() {
				if [ "$probe" = copy ]; then case "$2" in */aggiornamento.tar.tmp) echo partial > "$2"; return 1 ;; esac; fi
				command cp "$@"
			}
			install_job file "$sourcepkg"' sh "$OVERLAY/usr/bin/sweetspot-aggiorna" "$U/update.tar" "$U/replacement.tar" "$1" >/dev/null 2>&1
}
echo 'Sicurezza dei pacchetti'
mkpkg; pack; ALLOW_UNSIGNED=0 upd
expect 'chiave assente: aggiornamento rifiutato' errore "$(upd_state)"
expect 'chiave assente: copia attuale conservata' A-kernel "$(cat "$U/stick/bzImage")"
mkpkg; pack; CLI_TEST=0 ALLOW_UNSIGNED=1 upd
expect 'eccezione unsigned fuori dai test: ignorata' errore "$(upd_state)"
mkpkg; pack; upd
expect 'fixture esplicita: aggiornamento valido' pronto "$(upd_state)"
mkpkg; echo extra > "$U/pkg/extra"; pack; upd
expect 'file non coperto dal manifesto: rifiutato' errore "$(upd_state)"
mkpkg; echo extra > "$U/pkg/extra"
(cd "$U/pkg" && sha256sum extra >> SHA256SUMS)
pack; upd
expect 'file firmabile fuori dalla lista ammessa: rifiutato' errore "$(upd_state)"
mkpkg; ln -s "$WORK/outside" "$U/pkg/extra"; pack; upd
expect 'collegamento simbolico nel tar: rifiutato' errore "$(upd_state)"
mkpkg; ln "$U/pkg/bzImage" "$U/pkg/extra"; pack; upd
expect 'collegamento fisico nel tar: rifiutato' errore "$(upd_state)"
mkpkg
printf '%064d  ../outside\n' 0 >> "$U/pkg/SHA256SUMS"
pack; upd
expect 'percorso esterno nel manifesto: rifiutato' errore "$(upd_state)"
mkpkg
tar -C "$U/pkg" -cf "$U/update.tar" .
tar -C "$U/pkg" -rf "$U/update.tar" bzImage
upd
expect 'membro duplicato nel tar: rifiutato' errore "$(upd_state)"
if command -v minisign > /dev/null; then
	minisign -G -W -p "$U/key.pub" -s "$U/key.sec" >/dev/null 2>&1
	mkpkg
	minisign -S -s "$U/key.sec" -m "$U/pkg/SHA256SUMS" -x "$U/pkg/SHA256SUMS.minisig" -t 'Sweetspot v2 x86_64' >/dev/null 2>&1
	pack; UPDATE_PUB=$U/key.pub CLI_TEST=0 ALLOW_UNSIGNED=0 upd
	expect 'pacchetto firmato: installato senza eccezioni test' pronto "$(upd_state)"
else
	echo '  SKIP firma reale: minisign assente'
fi
mkpkg; pack
echo mutated-kernel > "$U/pkg/bzImage"
(cd "$U/pkg" && sha256sum bzImage rootfs.cpio.zst versione architettura > SHA256SUMS)
tar -C "$U/pkg" -cf "$U/replacement.tar" .
upd_probe mutate
expect 'sorgente locale modificata dopo ispezione: fixture mutata' mutated-kernel "$(tar -xOf "$U/update.tar" ./bzImage)"
expect 'sorgente locale modificata dopo ispezione: byte validati installati' B-kernel "$(cat "$U/stick/b/bzImage" 2>/dev/null)"
mkpkg; pack
if upd_probe copy; then rc=0; else rc=1; fi
expect 'copia locale fallita: errore propagato' 1 "$rc"
expect 'copia locale fallita: aggiornamento rifiutato' errore "$(upd_state)"
expect 'copia locale fallita: copia in uso conservata' A-kernel "$(cat "$U/stick/bzImage")"
expect 'copia locale fallita: file temporaneo rimosso' no "$([ -e "$U/stick/aggiornamento.tar.tmp" ] && echo si || echo no)"
rm -rf "$U/pkg"; mkdir -p "$U/pkg/overlays" "$U/avvio"
cp "$ROOT/board/sweetspot/rpi/config.txt" "$U/avvio/config.txt"
echo rpi > "$U/scheda"
echo B-kernel > "$U/pkg/Image.gz"
echo B-rootfs > "$U/pkg/rootfs.cpio.zst"
echo v2 > "$U/pkg/versione"
echo rpi > "$U/pkg/architettura"
echo dtb > "$U/pkg/bcm2711-rpi-4-b.dtb"
echo overlay > "$U/pkg/overlays/hifiberry-dacplus.dtbo"
echo mapping > "$U/pkg/overlays/overlay_map.dtb"
echo info > "$U/pkg/overlays/README"
(cd "$U/pkg" && sha256sum Image.gz rootfs.cpio.zst versione architettura bcm2711-rpi-4-b.dtb overlays/* > SHA256SUMS)
pack; UPDATE_ARCH=rpi upd
expect 'pacchetto Pi con dtb e overlay: installato' pronto "$(upd_state)"
expect 'pacchetto Pi: mappa overlay conservata' mapping "$(cat "$U/stick/b/overlays/overlay_map.dtb" 2>/dev/null)"
echo extra > "$U/pkg/bcm2712-rpi-5-b.dtb"
pack; UPDATE_ARCH=rpi upd
expect 'dtb aggiunto e non firmato nel manifesto: rifiutato' errore "$(upd_state)"

D=$WORK/dati
mkdir -p "$D/run" "$D/lms/prefs" "$D/lms/cache" "$D/stick/sweetspot-dati" "$D/bin"
echo current > "$D/lms/prefs/server.prefs"
echo last-valid > "$D/stick/sweetspot-dati/library.db"
dati() {
	SWEETSPOT_TEST=1 SWEETSPOT_PATH="$D/bin:$BASE_PATH" SWEETSPOT_STICK_DIR=$D/stick \
		SWEETSPOT_LMS_DATA=$D/lms SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log \
		$TEST_SH -c '. "$1"
			failure=$2
			cp() { if [ "$failure" = copy ]; then for a in "$@"; do case "$a" in *.nuovo/*) return 1 ;; esac; done; fi; command cp "$@"; }
			tar() { [ "$failure" = tar ] && [ "$1" = -cf ] && return 1; command tar "$@"; }
			mv() { [ "$failure" = rename ] && case "$1" in *.nuovo) return 1 ;; esac; command mv "$@"; }
			do_save' sh "${DATI_SCRIPT:-$OVERLAY/usr/bin/sweetspot-dati}" "${SAVE_FAILURE:-}" >/dev/null 2>&1
}
echo 'Generazioni persistenti'
cat > "$D/bin/sqlite3" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$D/bin/sqlite3"
echo live-WAL-main > "$D/lms/cache/library.db"
if dati; then rc=0; else rc=1; fi
expect 'backup SQLite fallito: errore propagato' 1 "$rc"
expect 'backup SQLite fallito: ultima copia conservata' last-valid "$(cat "$D/stick/sweetspot-dati/library.db" 2>/dev/null)"
rm -f "$D/lms/cache/library.db" "$D/bin/sqlite3"
mkdir -p "$D/stick/sweetspot-dati"
echo last-valid > "$D/stick/sweetspot-dati/library.db"
if SAVE_FAILURE=copy dati; then rc=0; else rc=1; fi
expect 'copia su chiavetta fallita: errore propagato' 1 "$rc"
expect 'copia su chiavetta fallita: ultima copia conservata' last-valid "$(cat "$D/stick/sweetspot-dati/library.db" 2>/dev/null)"
mkdir -p "$D/stick/sweetspot-dati"
echo last-valid > "$D/stick/sweetspot-dati/library.db"
if SAVE_FAILURE=tar dati; then rc=0; else rc=1; fi
expect 'archivio impostazioni fallito: errore propagato' 1 "$rc"
expect 'archivio impostazioni fallito: ultima copia conservata' last-valid "$(cat "$D/stick/sweetspot-dati/library.db" 2>/dev/null)"
rm -rf "$D/stick/sweetspot-dati" "$D/stick/sweetspot-dati.vecchio"
mkdir -p "$D/stick/sweetspot-dati.vecchio"
(cd "$D/lms" && tar -cf "$D/stick/sweetspot-dati.vecchio/lyrion.tar" prefs)
echo changed > "$D/lms/prefs/server.prefs"
SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_STICK_DIR=$D/stick SWEETSPOT_LMS_DATA=$D/lms \
	SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log $TEST_SH -c '. "$1"; do_restore "$STICK_MNT/sweetspot-dati"' sh \
	"$OVERLAY/usr/bin/sweetspot-dati" >/dev/null 2>&1
expect 'generazione vecchia dopo interruzione: ripristinata' current "$(cat "$D/lms/prefs/server.prefs")"
python3 - "$D/lms/cache/library.db" "$D/wal-ready" "$D/wal-stop" <<'PY' &
import pathlib
import sqlite3
import sys
import time

db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("CREATE TABLE songs(id INTEGER)")
db.execute("INSERT INTO songs VALUES(7)")
db.commit()
pathlib.Path(sys.argv[2]).write_text("ready")
while not pathlib.Path(sys.argv[3]).exists():
    time.sleep(0.01)
db.close()
PY
WALPID=$!
attempt=0
while [ ! -f "$D/wal-ready" ] && [ "$attempt" -lt 200 ]; do sleep 0.01; attempt=$((attempt + 1)); done
expect 'fixture WAL: transazione commessa ancora nel sidecar live' si "$([ -s "$D/lms/cache/library.db-wal" ] && echo si || echo no)"
expect 'fixture WAL: file principale non contiene ancora la tabella' 0 "$("$SQLITE3" -readonly "file:$D/lms/cache/library.db?immutable=1" "SELECT count(*) FROM sqlite_master WHERE name='songs';" 2>/dev/null)"
if dati; then rc=0; else rc=1; fi
expect 'backup SQLite reale: salvataggio riuscito' 0 "$rc"
expect 'backup SQLite reale: contenuto coerente' 7 "$("$SQLITE3" "$D/stick/sweetspot-dati/library.db" 'SELECT id FROM songs;')"
expect 'backup SQLite reale: integrità verificata' ok "$("$SQLITE3" "$D/stick/sweetspot-dati/library.db" 'PRAGMA quick_check;')"
: > "$D/wal-stop"
wait "$WALPID"
WALPID=
restore_probe() { # sorgente destinazione RAM
	# Run a parte: un ripristino fallito lascia il marcatore che blocca i salvataggi.
	mkdir -p "$D/run-ripr"
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_STICK_DIR=$D/stick SWEETSPOT_LMS_DATA=$2 \
		SWEETSPOT_RUN=$D/run-riprSWEETSPOT_LOG=$D/log $TEST_SH -c '. "$1"; do_restore "$2"' sh \
		"$OVERLAY/usr/bin/sweetspot-dati" "$1" >/dev/null 2>&1
}
# chmod non dimostra la sola lettura se il processo ha CAP_DAC_OVERRIDE.
if [ "$(id -u)" = 0 ]; then echo 'Prerequisito mancante: le regressioni RO devono essere eseguite senza privilegi root.' >&2; exit 1; fi
expect 'fixture RO: backup SQLite conserva header WAL' 0202 "$(od -An -t x1 -j18 -N2 "$D/stick/sweetspot-dati/library.db" | tr -d ' \n')"
chmod -R a-w "$D/stick/sweetspot-dati"
if restore_probe "$D/stick/sweetspot-dati" "$D/ro-restored"; then rc=0; else rc=1; fi
expect 'backup WAL su chiavetta RO: ripristino corrente riuscito' 0 "$rc"
expect 'backup WAL su chiavetta RO: contenuto ripristinato' 7 "$("$SQLITE3" "$D/ro-restored/cache/library.db" 'SELECT id FROM songs;' 2>/dev/null)"
expect 'backup WAL su chiavetta RO: nessun sidecar creato' no "$([ -e "$D/stick/sweetspot-dati/library.db-wal" ] || [ -e "$D/stick/sweetspot-dati/library.db-shm" ] && echo si || echo no)"
special="$D/snapshot ?#%"
cp -R "$D/stick/sweetspot-dati" "$special.vecchio"
if restore_probe "$special" "$D/ro-old-restored"; then rc=0; else rc=1; fi
expect 'backup WAL RO vecchio: percorso URI speciale ripristinato' 0 "$rc"
expect 'backup WAL RO vecchio: contenuto ripristinato' 7 "$("$SQLITE3" "$D/ro-old-restored/cache/library.db" 'SELECT id FROM songs;' 2>/dev/null)"
chmod -R u+w "$D/stick/sweetspot-dati" "$special.vecchio"
rm -rf "$special.vecchio"
echo corrupt > "$D/stick/sweetspot-dati/library.db"
if restore_probe "$D/stick/sweetspot-dati" "$D/corrupt-restored"; then rc=0; else rc=1; fi
expect 'backup SQLite corrotto: ripristino rifiutato' 1 "$rc"
expect 'backup SQLite corrotto: nessuna libreria installata' no "$([ -f "$D/corrupt-restored/cache/library.db" ] && echo si || echo no)"
rm -rf "$D/stick/sweetspot-dati.vecchio"
mkdir -p "$D/stick/sweetspot-dati" "$D/stick/sweetspot-dati.vecchio"
(cd "$D/lms" && tar -cf "$D/stick/sweetspot-dati.vecchio/lyrion.tar" prefs)
echo truncated > "$D/stick/sweetspot-dati/lyrion.tar"
if SAVE_FAILURE=rename dati; then rc=0; else rc=1; fi
expect 'rinomina fallita: errore propagato' 1 "$rc"
expect 'generazione corrente corrotta: vecchia valida conservata' current "$(tar -xOf "$D/stick/sweetspot-dati/lyrion.tar" prefs/server.prefs 2>/dev/null)"
echo 'Blocco del salvataggio'
lock_probe() { # comandi dopo il caricamento di sweetspot-dati
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_STICK_DIR=$D/stick SWEETSPOT_LMS_DATA=$D/lms \
		SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log SWEETSPOT_DATI_ATTESA=1 \
		$TEST_SH -c '. "$1"; '"$1" sh "$OVERLAY/usr/bin/sweetspot-dati" 2>/dev/null
}
held='if flock -n "$RUN/dati.lock" true; then echo sciolto; else echo tenuto; fi'
expect 'salvataggio riuscito: blocco sciolto al ritorno, processo ancora vivo' 0-sciolto \
	"$(lock_probe 'do_save >/dev/null 2>&1; printf "%s-" $?; '"$held")"
expect 'salvataggio fallito: blocco sciolto al ritorno' 1-sciolto \
	"$(lock_probe 'save_generation() { return 1; }; do_save >/dev/null 2>&1; printf "%s-" $?; '"$held")"
: > "$D/log"
expect 'blocco tenuto da altri: attesa limitata, salvataggio rimandato' 1 \
	"$(lock_probe 'exec 7> "$RUN/dati.lock"; flock 7; (do_save >/dev/null 2>&1); echo $?')"
expect 'blocco tenuto da altri: attesa registrata nel log' si "$(grep -q 'non termina da 1s' "$D/log" && echo si || echo no)"
expect 'modifica durante la copia: impronta precedente, nuovo salvataggio richiesto' diversa \
	"$(lock_probe 'tar() { command tar "$@"; r=$?; [ "$1" = -cf ] && echo later >> "$LMS_DATA/prefs/server.prefs"; return $r; }
		do_save >/dev/null 2>&1; [ "$(cat "$STAMP")" = "$(fingerprint)" ] && echo uguale || echo diversa')"
expect 'nessuna modifica durante la copia: impronta allineata' uguale \
	"$(lock_probe 'do_save >/dev/null 2>&1; [ "$(cat "$STAMP")" = "$(fingerprint)" ] && echo uguale || echo diversa')"
rm -f "$D/run/dati.sporco"
expect 'modifica durante una copia lenta del database: resta da salvare' si-diversa \
	"$(lock_probe 'db_copy() { sleep 1; echo concorrente >> "$LMS_DATA/prefs/server.prefs"; command sqlite3 "$1" ".backup '"'"'$2'"'"'"; }
		do_save >/dev/null 2>&1; [ -s "$DIRTY_SINCE" ] && printf si- || printf no-
		[ "$(cat "$STAMP")" = "$(fingerprint)" ] && echo uguale || echo diversa')"
expect 'dopo la modifica concorrente il salvataggio successivo allinea e azzera' uguale-no \
	"$(lock_probe 'do_save >/dev/null 2>&1; [ "$(cat "$STAMP")" = "$(fingerprint)" ] && printf uguale- || printf diversa-
		[ -e "$DIRTY_SINCE" ] && echo si || echo no')"

echo 'Eta massima dei dati non persistiti'
cp "$D/run/sweetspot.conf" "$D/conf.salvata" 2>/dev/null
echo 'DATI_ETA_MAX_MIN=10' > "$D/run/sweetspot.conf"
expect 'eta massima letta da configurazione (minuti -> secondi)' 600 "$(lock_probe 'eta_max_s')"
rm -f "$D/run/dati.sporco"
expect 'nessuna modifica in sospeso: eta non superata' no "$(lock_probe 'dirty_too_old && echo si || echo no')"
echo $(( $(date +%s) - 300 )) > "$D/run/dati.sporco"
expect 'dati non salvati da 5 minuti: sotto il limite' no "$(lock_probe 'dirty_too_old && echo si || echo no')"
echo $(( $(date +%s) - 700 )) > "$D/run/dati.sporco"
expect 'dati non salvati da oltre il limite: si salva comunque' si "$(lock_probe 'dirty_too_old && echo si || echo no')"
echo 'DATI_ETA_MAX_MIN=0' > "$D/run/sweetspot.conf"
expect 'limite 0: nessun salvataggio forzato' no "$(lock_probe 'dirty_too_old && echo si || echo no')"
echo 'DATI_ETA_MAX_MIN=10' > "$D/run/sweetspot.conf"
expect 'salvataggio forzato a bassa priorita: riuscito' 0 "$(lock_probe 'bg_self() { echo bassa > "$RUN/bassa"; }; do_save_low >/dev/null 2>&1; echo $?')"
expect 'salvataggio forzato: eseguito a bassa priorita e dati azzerati' bassa-no \
	"$(printf '%s-' "$(cat "$D/run/bassa" 2>/dev/null)"; [ -e "$D/run/dati.sporco" ] && echo si || echo no)"
if [ -f "$D/conf.salvata" ]; then cp "$D/conf.salvata" "$D/run/sweetspot.conf"; else rm -f "$D/run/sweetspot.conf"; fi
rm -f "$D/run/bassa" "$D/run/dati.sporco"

echo 'Checkpoint e spazio sulla chiavetta'
# dprobe MARGINE_KB RITENTA_S COMANDI: comandi dopo il caricamento di sweetspot-dati.
dprobe() {
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_STICK_DIR=$D/stick SWEETSPOT_LMS_DATA=$D/lms \
		SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log SWEETSPOT_CGROUP=$D/nessun-cgroup \
		SWEETSPOT_DATI_MARGINE_KB=$1 SWEETSPOT_DATI_RITENTA=$2 \
		$TEST_SH -c '. "$1"; '"$3" sh "$OVERLAY/usr/bin/sweetspot-dati" 2>/dev/null
}
rm -rf "$D/stick/sweetspot-dati" "$D/stick/sweetspot-dati.vecchio" "$D/run/dati.spazio" "$D/run/dati.checkpoint"
rm -f "$D/lms/cache/library.db" "$D/lms/cache/library.db-wal" "$D/lms/cache/library.db-shm"
"$SQLITE3" "$D/lms/cache/library.db" 'CREATE TABLE songs(id INTEGER); INSERT INTO songs VALUES(1);' > /dev/null
expect 'chiavetta piena: salvataggio rifiutato' 1 "$(dprobe 999999999 1800 'do_save >/dev/null 2>&1; echo $?')"
expect 'chiavetta piena: nessuna generazione scritta' no "$([ -e "$D/stick/sweetspot-dati" ] && echo si || echo no)"
expect 'chiavetta piena: avviso per Stato (liberi e necessari)' si "$(grep -Eq '^[0-9]+ [0-9]+ [0-9]+$' "$D/run/dati.spazio" && echo si || echo no)"
expect 'chiavetta piena: non si riprova ogni minuto' attesa "$(dprobe 999999999 1800 'space_wait && echo attesa || echo subito')"
expect 'chiavetta piena: dopo il tempo di attesa si riprova' subito "$(dprobe 999999999 0 'space_wait && echo attesa || echo subito')"
expect 'checkpoint a chiavetta piena: rifiutato' 1 "$(dprobe 999999999 1800 'do_checkpoint; echo $?')"
expect 'spazio tornato: salvataggio riuscito' 0 "$(dprobe 8192 1800 'do_save >/dev/null 2>&1; echo $?')"
expect 'spazio tornato: avviso rimosso' no "$([ -e "$D/run/dati.spazio" ] && echo si || echo no)"
"$SQLITE3" "$D/lms/cache/library.db" 'INSERT INTO songs VALUES(2);' > /dev/null
expect 'checkpoint durante ascolto: riuscito' 0 "$(dprobe 8192 1800 'do_checkpoint; echo $?')"
expect 'checkpoint: database della chiavetta aggiornato' 2 "$("$SQLITE3" "$D/stick/sweetspot-dati/library.db" 'SELECT count(*) FROM songs;')"
expect 'checkpoint: nessun file temporaneo rimasto' no "$(ls "$D/stick/sweetspot-dati" | grep -q '\.nuovo$' && echo si || echo no)"
expect 'checkpoint: lyrion.tar della generazione intatto' si "$([ -s "$D/stick/sweetspot-dati/lyrion.tar" ] && echo si || echo no)"
expect 'checkpoint: cadenza rispettata' 1 "$(dprobe 8192 1800 'checkpoint_due && echo 0 || echo 1')"
rm -rf "$D/stick/sweetspot-dati"
mkdir -p "$D/stick/sweetspot-dati.vecchio"
expect 'checkpoint con sola generazione vecchia: non la nasconde' 1 "$(dprobe 8192 1800 'do_checkpoint; echo $?')"
rm -rf "$D/stick/sweetspot-dati.vecchio"

# Il riavvio del solo player non salva il database; lo spegnimento si'.
mkdir -p "$D/bin2"
for c in start-stop-daemon killall; do printf '#!/bin/sh\nexit 0\n' > "$D/bin2/$c"; chmod +x "$D/bin2/$c"; done
printf '#!/bin/sh\necho "$1" >> "%s/salvataggi"\n' "$D" > "$D/bin2/dati-finto"
chmod +x "$D/bin2/dati-finto"
echo 'MODALITA=completa' > "$D/run/sweetspot.conf"
: > "$D/salvataggi"
player_init() {
	SWEETSPOT_PATH="$D/bin2:$BASE_PATH" SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log SWEETSPOT_DATI=$D/bin2/dati-finto \
		$TEST_SH "$OVERLAY/etc/init.d/S60sweetspot-player" "$1" > /dev/null 2>&1
}
player_init restart
expect 'riavvio del player: nessun backup del database' 0 "$(wc -l < "$D/salvataggi" | tr -d ' ')"
player_init stop
expect 'spegnimento: salvataggio su chiavetta' salva "$(cat "$D/salvataggi")"

K=$WORK/dischi
mkdir -p "$K/sys/class/block/sda1" "$K/sys/class/block/sdb1" "$K/run" "$K/proc" "$K/media" "$K/musica"
echo 20971520 > "$K/sys/class/block/sda1/size"
echo 20971520 > "$K/sys/class/block/sdb1/size"
: > "$K/proc/mounts"
printf '/dev/sda1: LABEL="Music" UUID="aaa" TYPE="ext4"\n/dev/sdb1: LABEL="Music" UUID="bbb" TYPE="ext4"\n' > "$K/blkid"
dischi() {
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_MEDIA=$K/media SWEETSPOT_MUSICA=$K/musica \
		SWEETSPOT_SYSFS=$K/sys SWEETSPOT_PROCFS=$K/proc SWEETSPOT_RUN=$K/run SWEETSPOT_LOG=$K/log \
		$TEST_SH -c '. "$1"; fixture=$2; blkid() { cat "$fixture"; }; mount() { return 0; }; modprobe() { return 0; }; blockdev() { return 0; }; do_mount' \
		sh "$OVERLAY/usr/bin/sweetspot-dischi" "$K/blkid" >/dev/null 2>&1
}
echo 'Identità dei dischi'
echo ARCHIVIO=Music > "$K/run/sweetspot.conf"
dischi
expect 'etichette duplicate: nessun archivio scrivibile' 'ro ro' "$(cut -d'|' -f6 "$K/run/dischi.list" | tr '\n' ' ' | sed 's/ $//')"
expect 'catalogo: nomi corrispondenti ai montaggi' 'Music|Music 2' "$(cut -d'|' -f1 "$K/run/dischi.list" | tr '\n' '|' | sed 's/|$//')"
rm -rf "${K:?}/media" "$K/musica"; mkdir -p "$K/media" "$K/musica"
rm -f "$K/run/dischi.list" "$K/run/archivio"
echo ARCHIVIO=UUID=bbb > "$K/run/sweetspot.conf"
dischi
expect 'UUID scelto: un solo disco scrivibile' 'ro rw' "$(cut -d'|' -f6 "$K/run/dischi.list" | tr '\n' ' ' | sed 's/ $//')"
expect 'catalogo: identità stabile da scegliere' 'UUID=aaa|UUID=bbb' "$(cut -d'|' -f7 "$K/run/dischi.list" | tr '\n' '|' | sed 's/|$//')"
expect 'archivio: percorso effettivo del secondo disco' "$K/media/Music 2" "$(cat "$K/run/archivio" 2>/dev/null)"
rm -rf "${K:?}/media" "$K/musica"; mkdir -p "$K/media" "$K/musica"
rm -f "$K/run/dischi.list" "$K/run/archivio"
printf '/dev/sda1: LABEL="Music" UUID="clone" PARTUUID="111" TYPE="ext4"\n/dev/sdb1: LABEL="Music" UUID="clone" PARTUUID="222" TYPE="ext4"\n' > "$K/blkid"
echo ARCHIVIO=PARTUUID=222 > "$K/run/sweetspot.conf"
dischi
expect 'UUID clonati: selezione distinta tramite PARTUUID' 'PARTUUID=111|PARTUUID=222' "$(cut -d'|' -f7 "$K/run/dischi.list" | tr '\n' '|' | sed 's/|$//')"
expect 'PARTUUID scelto: un solo disco scrivibile' 'ro rw' "$(cut -d'|' -f6 "$K/run/dischi.list" | tr '\n' ' ' | sed 's/ $//')"

# Montaggio della chiavetta: il conteggio si rilascia su ogni uscita di
# install_job, anche annullando l'aggiornamento (SIGTERM).
R=$WORK/rilascio
mkdir -p "$R"
rilascio() { # modalita: normale|annulla
	: > "$R/rilasci"
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_RUN=$R/run SWEETSPOT_LOG=$R/log SWEETSPOT_PROCFS=$U/proc \
		$TEST_SH -c '. "$1"; mode=$2; r=$3
			stick_mount() { return 0; }
			stick_umount() { echo x >> "$r/rilasci"; }
			prepare_slot() { echo "$r/slot"; }
			extract_package() { [ "$mode" = annulla ] && { : > "$r/avviato"; sleep 30 & wait $!; }; return 1; }
			install_job file "$r/x.tar"' sh "$OVERLAY/usr/bin/sweetspot-aggiorna" "$1" "$R" >/dev/null 2>&1 &
	pid=$!
	if [ "$1" = annulla ]; then
		i=0; while [ ! -e "$R/avviato" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
		kill -TERM "$pid" 2>/dev/null
	fi
	wait "$pid" 2>/dev/null
	rm -f "$R/avviato"
	wc -l < "$R/rilasci" | tr -d ' '
}
expect 'chiavetta: uscita normale, un solo rilascio' 1 "$(rilascio normale)"
expect 'chiavetta: aggiornamento annullato, un solo rilascio' 1 "$(rilascio annulla)"

# Conferma fallita: riavvio automatico (si torna alla copia precedente).
C=$WORK/conferma
mkdir -p "$C/run" "$C/proc" "$C/stick/boot/grub"
echo 'sweetspot.slot=b' > "$C/proc/cmdline"
confermaprova() { # tentato
	rm -f "$C/riavvio"
	printf '#!/bin/sh\necho si > %s/riavvio\n' "$C" > "$C/reboot"; chmod +x "$C/reboot"
	$TEST_SH -c '. "$1"; grubenv_set "$3/boot/grub/grubenv" slot=a "tentato=$2"' sh "$OVERLAY/usr/lib/sweetspot/common.sh" "$1" "$C/stick" >/dev/null 2>&1
	SWEETSPOT_TEST=cli SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_RUN=$C/run SWEETSPOT_LOG=$C/log SWEETSPOT_PROCFS=$C/proc \
		SWEETSPOT_STICK_DIR=$C/stick SWEETSPOT_AVVIO=$C/avvio SWEETSPOT_CONFERMA_ATTESA=0 SWEETSPOT_CONFERMA_ATTESA_LMS=0 \
		SWEETSPOT_REBOOT=$C/reboot $TEST_SH "$OVERLAY/usr/bin/sweetspot-aggiorna" conferma >/dev/null 2>&1
	[ -f "$C/riavvio" ] && echo si || echo no
}
expect 'conferma fallita: riavvio automatico' si "$(confermaprova b)"
expect 'conferma riuscita o nessuna prova: nessun riavvio' no "$(confermaprova "")"

# C12: la chiavetta resta in sola lettura dopo il rimontaggio, o la scrittura
# dell'ambiente di avvio fallisce: l'errore arriva a chi chiama.
W=$WORK/stickrw
mkdir -p "$W/run/chiavetta" "$W/proc"
stickrw() { # opzioni-in-mounts esito-del-remount
	printf '/dev/sda1 %s/run/chiavetta vfat %s 0 0\n' "$W" "$1" > "$W/proc/mounts"
	SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_RUN=$W/run SWEETSPOT_PROCFS=$W/proc SWEETSPOT_LOG=$W/log \
		$TEST_SH -c '. "$1"; RC=$2; mount() { return $RC; }; stick_mount rw >/dev/null 2>&1; echo $?' \
		sh "$OVERLAY/usr/lib/sweetspot/common.sh" "$2" 2>/dev/null
}
expect 'stick_mount rw: rimontata scrivibile, successo' 0 "$(stickrw rw,noatime 0)"
expect 'stick_mount rw: remount che fallisce, errore' 1 "$(stickrw ro,noatime 1)"
expect 'stick_mount rw: remount "riuscito" ma ancora ro, errore' 1 "$(stickrw ro,noatime 0)"

grubfail() { # comando
	rm -f "$C/riavvio"
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_RUN=$C/run SWEETSPOT_LOG=$C/log SWEETSPOT_PROCFS=$C/proc \
		SWEETSPOT_STICK_DIR=$C/stick \
		$TEST_SH -c '. "$1"
			stick_mount() { return $STICKRC; }; stick_umount() { :; }
			grubenv_set() { return 1; }; healthy() { return 0; }; refresh_boot() { :; }
			boot_env() { echo "$SWEETSPOT_STICK_DIR/boot/grub/grubenv"; }
			other_slot() { echo b; }; kernel_file() { echo k; }
			mkdir -p "$SWEETSPOT_STICK_DIR/boot/b"; : > "$SWEETSPOT_STICK_DIR/boot/b/k"
			slot_dir() { echo "$SWEETSPOT_STICK_DIR/boot/b"; }
			: > "$SWEETSPOT_STICK_DIR/boot/b/rootfs.cpio.zst"
			DIR=$SWEETSPOT_RUN/agg
			do_$2 >/dev/null 2>&1; echo $?' sh "$OVERLAY/usr/bin/sweetspot-aggiorna" "$1"
}
STICKRC=0
export STICKRC
printf 'sweetspot.slot=a\n' > "$C/proc/cmdline"
rm -f "$C/stick/boot/grub/grubenv"
$TEST_SH -c '. "$1"; grubenv_set "$2/boot/grub/grubenv" slot=a tentato=a' sh "$OVERLAY/usr/lib/sweetspot/common.sh" "$C/stick" >/dev/null 2>&1
expect 'do_other: grubenv_set fallito, errore' 1 "$(grubfail other)"
expect 'do_default: grubenv_set fallito, errore' 1 "$(grubfail default)"
expect 'do_confirm: grubenv_set fallito, errore' 1 "$(grubfail confirm)"
STICKRC=1
expect 'do_confirm: chiavetta non scrivibile, errore' 1 "$(grubfail confirm)"
unset STICKRC

printf '\nOperazioni: %s passati, %s falliti\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
