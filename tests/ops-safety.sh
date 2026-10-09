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
	SWEETSPOT_TEST=1 SWEETSPOT_PATH=$BASE_PATH SWEETSPOT_STICK_DIR=$D/stick SWEETSPOT_LMS_DATA=$2 \
		SWEETSPOT_RUN=$D/run SWEETSPOT_LOG=$D/log $TEST_SH -c '. "$1"; do_restore "$2"' sh \
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

printf '\nOperazioni: %s passati, %s falliti\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
