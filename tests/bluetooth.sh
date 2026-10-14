#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Bluetooth come sorgente (A2DP sink): configurazione, abbinamento, elenco e
# rimozione dei dispositivi, passaggio esclusivo del DAC, core isolato,
# pagina e azioni del pannello, pacchetti nel build.
# I programmi (bluetoothctl, dbus-send, taskset...) sono finti: la prova vera
# senza hardware e' in tests/prova-robustezza-qemu.sh.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
CGI=$OVERLAY/usr/share/sweetspot/www/cgi-bin
BT_SCRIPT=$OVERLAY/usr/bin/sweetspot-bluetooth
WORK=$(mktemp -d)
trap 'kill $(cat "$WORK"/*/sleeper.pid "$WORK"/t/run/*.pid 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT
export SWEETSPOT_LIB="$OVERLAY/usr/lib/sweetspot"
FAIL=0
PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s\n      atteso: [%s]\n      ottenuto: [%s]\n' "$1" "$2" "$3"; fi
}
SH=sh
BB=$(command -v busybox || true)
[ -n "$BB" ] && SH="$BB sh"

echo "Bluetooth: configurazione e pacchetti"
expect "defaults.conf: Bluetooth spento di serie" "no" "$(sed -n 's/^BLUETOOTH=//p' "$OVERLAY/etc/sweetspot/defaults.conf")"
expect "defaults.conf: nome vuoto (usa il nome del player)" "1" "$(grep -c '^BLUETOOTH_NOME=$' "$OVERLAY/etc/sweetspot/defaults.conf")"
for cfg in sweetspot_x86_64 sweetspot_rpi; do
	expect "$cfg: bluez5_utils, bluez-alsa e bluealsa-aplay nel defconfig" "4" \
		"$(grep -c '^BR2_PACKAGE_\(BLUEZ5_UTILS\|BLUEZ_ALSA\|BLUEZ_ALSA_APLAY\|DBUS\)=y$' "$ROOT/configs/${cfg}_defconfig")"
	expect "$cfg: niente fdk-aac (licenza non libera)" "0" "$(grep -c 'FDK_AAC\|BLUEZ_ALSA_ENABLE_AAC' "$ROOT/configs/${cfg}_defconfig")"
done
expect "rpi: firmware Bluetooth del Pi" "1" "$(grep -c '^BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI_BT=y$' "$ROOT/configs/sweetspot_rpi_defconfig")"
expect "rpi: il Bluetooth non e' disabilitato nel firmware" "0" "$(grep -c '^dtoverlay=disable-bt' "$ROOT/board/sweetspot/rpi/config.txt")"
FRAG=$ROOT/board/sweetspot/common/linux.fragment
expect "kernel: Bluetooth, btusb e hci_uart come moduli" "3" "$(grep -c '^CONFIG_\(BT\|BT_HCIBTUSB\|BT_HCIUART\)=m$' "$FRAG")"
expect "kernel: Pi senza BT disattivato" "0" "$(grep -c 'CONFIG_BT is not set' "$ROOT/board/sweetspot/rpi/linux.fragment")"
expect "kernel: cifratura AF_ALG per l'abbinamento" "3" "$(grep -c '^CONFIG_CRYPTO_USER_API_\(HASH\|SKCIPHER\|AEAD\)=y$' "$FRAG")"
expect "build: post-build.sh verifica i pacchetti Bluetooth" "1" "$(grep -c 'manca \$f' "$ROOT/board/sweetspot/post-build.sh")"
expect "build: D-Bus non parte da solo all'avvio" "1" "$(grep -c 'S30dbus.*init.d/dbus' "$ROOT/board/sweetspot/post-build.sh")"
expect "init: S58sweetspot-bluetooth chiama il servizio" "1" "$(grep -c 'sweetspot-bluetooth avvia' "$OVERLAY/etc/init.d/S58sweetspot-bluetooth")"
expect "priv: abbina, chiudi, elenco, rimuovi, applica" "5" "$(grep -c '"sweetspot-bluetooth", "' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
expect "priv: chiavi BLUETOOTH e BLUETOOTH_NOME modificabili" "1" "$(grep -c '"BLUETOOTH", "BLUETOOTH_NOME"' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
expect "pannello: voce Bluetooth nel menu" "2" "$(grep -c 'bluetooth:Bluetooth' "$OVERLAY/usr/lib/sweetspot/web.sh")"

# --- Ambiente finto -------------------------------------------------------------
T=$WORK/t
mkdir -p "$T/bin" "$T/run" "$T/sys/class/bluetooth" "$T/proc/irq/45" "$T/proc/irq/30" "$T/lib"
export BTLOG=$T/chiamate.log
for p in start-stop-daemon killall modprobe dbus-uuidgen dbus-daemon; do
	printf '#!/bin/sh\necho "%s $*" >> "$BTLOG"\nexit 0\n' "$p" > "$T/bin/$p"
done
# taskset annota i core e lancia il comando; bluetoothd e bluealsa restano in vita.
cat > "$T/bin/taskset" <<'EOF'
#!/bin/sh
echo "taskset $*" >> "$BTLOG"
shift 2
exec "$@"
EOF
printf '#!/bin/sh\nexec sleep 300\n' > "$T/bin/bluetoothd"
cp "$T/bin/bluetoothd" "$T/bin/bluealsa"
printf '#!/bin/sh\necho 1\nexit 0\n' > "$T/bin/pidof"
cat > "$T/bin/bluetoothctl" <<'EOF'
#!/bin/sh
echo "bluetoothctl $*" >> "$BTLOG"
case "$1 $2" in
	"devices Paired") cat "$BTDIR/paired" 2>/dev/null ;;
	"devices Connected") cat "$BTDIR/connected" 2>/dev/null ;;
esac
case "$1" in
	list) [ -e "$BTDIR/adattatore" ] && echo "Controller 00:11:22:33:44:55 Sweetspot [default]" ;;
	show) cat "$BTDIR/show" 2>/dev/null ;;
esac
exit 0
EOF
cat > "$T/bin/dbus-send" <<'EOF'
#!/bin/sh
case "$*" in
	*Introspect*) echo '   <node name="fd3"/>' ;;
	*Properties.Get*) echo "   variant       string \"$(cat "$BTDIR/trasporto" 2>/dev/null)\"" ;;
esac
exit 0
EOF
chmod +x "$T/bin/"*
export BTDIR=$T/dati
mkdir -p "$BTDIR"
printf 'Device AA:BB:CC:DD:EE:01 Telefono di Anna\nDevice AA:BB:CC:DD:EE:02 Pixel\n' > "$BTDIR/paired"
printf 'Device AA:BB:CC:DD:EE:02 Pixel\n' > "$BTDIR/connected"
: > "$BTDIR/adattatore"

# Con BusyBox le applet (taskset, killall, modprobe, start-stop-daemon, pidof)
# passano davanti al PATH: funzioni che richiamano i programmi finti.
# (Senza BusyBox la shell di sistema non accetta il trattino nei nomi di
# funzione, ma li' le applet non ci sono e basta il PATH.)
: > "$T/shim.sh"
if [ -n "$BB" ]; then
	for p in taskset start-stop-daemon killall modprobe pidof bluetoothctl dbus-send dbus-uuidgen dbus-daemon bluealsa-aplay; do
		printf '%s() { "%s/bin/%s" "$@"; }\n' "$p" "$T" "$p"
	done > "$T/shim.sh"
fi

# Configurazione della prova: predefiniti + righe date (l'ultima vince, come
# config_build, senza lanciare un processo per ogni riga).
mkconf() { # righe
	{ grep '^[A-Z_0-9]*=' "$OVERLAY/etc/sweetspot/defaults.conf"; printf '%s\n' "$1"; } > "$T/run/sweetspot.conf"
}

# bt CONF-RIGHE COMANDO...: esegue il comando dopo aver caricato lo script.
bt() {
	local conf=$1
	shift
	mkconf "$conf"
	SWEETSPOT_TEST=1 SWEETSPOT_SYSFS=$T/sys SWEETSPOT_PROCFS=$T/proc SWEETSPOT_RUN=$T/run \
		SWEETSPOT_LOG=$T/log SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		SWEETSPOT_PATH="$T/bin" SWEETSPOT_BT_LIB=$T/lib SWEETSPOT_BT_SONDA=0 \
		$SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $BT_SCRIPT; . $T/shim.sh; $*"
}

echo "Bluetooth: bluetoothd e nome"
expect "main.conf: solo Bluetooth classico" "1" "$(bt 'NOME_PLAYER=Salotto' main_conf | grep -c '^ControllerMode=bredr$')"
expect "main.conf: nome del player" "Name=Salotto" "$(bt 'NOME_PLAYER=Salotto' main_conf | grep '^Name=')"
expect "main.conf: nome Bluetooth proprio" "Name=Cucina" "$(bt 'NOME_PLAYER=Salotto
BLUETOOTH_NOME=Cucina' main_conf | grep '^Name=')"
expect "main.conf: nome ripulito dai caratteri strani" "Name=Sala_" "$(bt 'BLUETOOTH_NOME=Sala$' main_conf | grep '^Name=')"
expect "main.conf: mai rilevabile di serie" "1" "$(bt '' main_conf | grep -c '^DiscoverableTimeout=0$')"

echo "Bluetooth: spento di serie"
: > "$BTLOG"
bt '' start >/dev/null 2>&1
expect "spento: nessun servizio avviato" "0" "$(grep -c 'taskset\|modprobe\|dbus' "$BTLOG")"
expect "spento: stato" "spento" "$(cat "$T/run/bluetooth.stato")"
expect "spento: stato testuale" "spento" "$(bt '' cmd_stato)"
: > "$BTLOG"
bt 'BLUETOOTH=si' 'start_services' >/dev/null 2>&1
expect "acceso: bluetoothd e bluealsa avviati con taskset sui core di sistema" "2" "$(grep -c '^taskset -c ' "$BTLOG")"
expect "acceso: moduli caricati" "1" "$(grep -c '^modprobe btusb' "$BTLOG")"
expect "acceso: bluealsa solo come sink A2DP" "1" "$(grep -c 'bluealsa -p a2dp-sink' "$BTLOG")"
expect "acceso: bluetoothd con il main.conf generato" "1" "$(grep -c 'bluetoothd -f .*/bluetooth/main.conf' "$BTLOG")"

echo "Bluetooth: abbinamento e dispositivi"
expect "elenco: MAC, nome, collegato" "AA:BB:CC:DD:EE:01|Telefono di Anna|no
AA:BB:CC:DD:EE:02|Pixel|si" "$(bt '' cmd_elenco)"
: > "$BTLOG"
expect "rimuovi: MAC non valido rifiutato" "1" "$(bt '' 'cmd_rimuovi "AA:BB;reboot" >/dev/null 2>&1; echo $?')"
expect "rimuovi: nessun comando per un MAC non valido" "0" "$(grep -c 'remove' "$BTLOG")"
bt '' 'cmd_rimuovi AA:BB:CC:DD:EE:01' >/dev/null 2>&1
expect "rimuovi: MAC valido" "1" "$(grep -c '^bluetoothctl remove AA:BB:CC:DD:EE:01$' "$BTLOG")"
expect "abbina: rifiutato con il Bluetooth spento" "1" "$(bt '' 'cmd_abbina 2 >/dev/null 2>&1; echo $?')"
sleep 300 > /dev/null 2>&1 &
echo $! > "$T/sleeper.pid"
echo $! > "$T/run/bluetooth.pid"
expect "abbina: aperto con il servizio attivo" "0" "$(bt 'BLUETOOTH=si' 'cmd_abbina 5 >/dev/null 2>&1; echo $?')"
fine=$(cat "$T/run/bluetooth.abbina")
now=$(date +%s)
expect "abbina: finestra di 5 minuti" "si" "$([ $((fine - now)) -ge 295 ] && [ $((fine - now)) -le 300 ] && echo si || echo no)"
bt 'BLUETOOTH=si' 'cmd_abbina 99 >/dev/null 2>&1'
fine=$(cat "$T/run/bluetooth.abbina")
expect "abbina: minuti fuori misura tornano a 2" "si" "$([ $((fine - $(date +%s))) -le 120 ] && echo si || echo no)"
expect "abbina: stato 'abbinamento aperto'" "abbinamento aperto" "$(bt 'BLUETOOTH=si' stato_testo)"
bt 'BLUETOOTH=si' 'cmd_chiudi'
expect "chiudi: finestra chiusa" "no" "$([ -e "$T/run/bluetooth.abbina" ] && echo si || echo no)"
expect "stato: collegato" "collegato: Pixel" "$(bt 'BLUETOOTH=si' stato_testo)"
rm -f "$BTDIR/adattatore"
expect "stato: nessun adattatore" "nessun adattatore Bluetooth" "$(bt 'BLUETOOTH=si' stato_testo)"
: > "$BTDIR/adattatore"

echo "Bluetooth: passaggio esclusivo del DAC"
echo active > "$BTDIR/trasporto"
expect "trasmissione attiva riconosciuta" "0" "$(bt '' 'stream_active; echo $?')"
echo pending > "$BTDIR/trasporto"
expect "trasmissione in avvio riconosciuta" "0" "$(bt '' 'stream_active; echo $?')"
echo idle > "$BTDIR/trasporto"
expect "trasporto fermo: nessuna trasmissione" "1" "$(bt '' 'stream_active; echo $?')"
: > "$BTDIR/connected"
echo active > "$BTDIR/trasporto"
expect "nessun telefono collegato: nessuna trasmissione" "1" "$(bt '' 'stream_active; echo $?')"
printf 'Device AA:BB:CC:DD:EE:02 Pixel\n' > "$BTDIR/connected"

# bluealsa-aplay finto: resta in vita finche' non lo si ferma.
cat > "$T/bin/bluealsa-aplay" <<'EOF'
#!/bin/sh
echo "bluealsa-aplay $*" >> "$BTLOG"
case "$2" in plughw:*) ;; *) [ -e "$BTDIR/hw-rifiutato" ] && exit 1 ;; esac
exec sleep 300
EOF
chmod +x "$T/bin/bluealsa-aplay"
: > "$BTLOG"
bt '' 'dac_find() { echo 1; }; dac_playback_dev() { echo 0; }; handoff_start; echo $? > '"$T"'/rc; handoff_end' >/dev/null 2>&1
expect "passaggio: il player si ferma prima del DAC" "1" "$(grep -c '^start-stop-daemon -K .*supervisore.pid' "$BTLOG")"
expect "passaggio: Squeezelite fermato" "1" "$(grep -c '^killall squeezelite' "$BTLOG")"
expect "passaggio: uscita hw: diretta sul DAC" "1" "$(grep -c '^bluealsa-aplay -D hw:1,0 00:00:00:00:00:00$' "$BTLOG")"
expect "passaggio: bluealsa-aplay sui core di sistema" "1" "$(grep -c '^taskset -c [0-9,]* bluealsa-aplay' "$BTLOG")"
expect "passaggio: esito ok" "0" "$(cat "$T/rc")"
expect "fine: il player riparte" "1" "$(grep -c '^start-stop-daemon -S .*sweetspot-player' "$BTLOG")"
expect "fine: segnale di passaggio rimosso" "no" "$([ -e "$T/run/bluetooth.attivo" ] && echo si || echo no)"
expect "segnale dac.bluetooth: creato col passaggio, rimosso alla fine" "si|no" \
	"$(bt '' 'dac_find() { echo 1; }; dac_playback_dev() { echo 0; }; handoff_start >/dev/null 2>&1; [ -e $RUN/dac.bluetooth ] && a=si || a=no; handoff_end >/dev/null 2>&1; [ -e $RUN/dac.bluetooth ] && b=si || b=no; echo "$a|$b"')"
echo 1 > "$T/run/dac.bluetooth"
bt '' 'rm -f $BT_DAC'
bt 'BLUETOOTH=si' 'start >/dev/null 2>&1'
expect "segnale dac.bluetooth orfano ripulito all'avvio" "no" "$([ -e "$T/run/dac.bluetooth" ] && echo si || echo no)"
expect "supervisore: attende finche' il DAC e' del Bluetooth" "1" "$(grep -c 'dac.bluetooth' "$OVERLAY/usr/bin/sweetspot-player")"
expect "liveness: DAC del Bluetooth non e' un blocco ne' un errore" "1" "$(grep -c 'DAC in uso dal Bluetooth' "$OVERLAY/usr/bin/sweetspot-stato")"
: > "$BTLOG"
: > "$BTDIR/hw-rifiutato"
bt '' 'dac_find() { echo 1; }; dac_playback_dev() { echo 0; }; handoff_start; handoff_end' >/dev/null 2>&1
expect "passaggio: ripiego su plughw: se hw: rifiuta il formato" "1" "$(grep -c '^bluealsa-aplay -D plughw:1,0' "$BTLOG")"
rm -f "$BTDIR/hw-rifiutato"
: > "$BTLOG"
expect "passaggio: senza DAC il player non si tocca" "1" "$(bt '' 'dac_find() { return 1; }; handoff_start >/dev/null 2>&1; echo $?')"
expect "passaggio: senza DAC nessun arresto" "0" "$(grep -c 'killall\|start-stop-daemon' "$BTLOG")"

echo "Bluetooth: core isolato e interruzioni"
printf '  45:  100  0  GICv2  uart-pl011\n  30:  900  0  PCI-MSI  xhci_hcd\n' > "$T/proc/interrupts"
echo 3 > "$T/proc/irq/45/smp_affinity_list"
echo 3 > "$T/proc/irq/30/smp_affinity_list"
bt '' 'hk_list() { echo 0,1; }; bt_irq_housekeeping'
expect "interruzioni: UART del Bluetooth sui core di sistema" "0,1" "$(cat "$T/proc/irq/45/smp_affinity_list")"
expect "interruzioni: quelle USB (DAC) non si toccano" "3" "$(cat "$T/proc/irq/30/smp_affinity_list")"
kill $(cat "$T/run/bluetoothd.pid" "$T/run/bluealsa.pid" 2>/dev/null) 2>/dev/null
rm -f "$T/run/bluetoothd.pid" "$T/run/bluealsa.pid"
: > "$BTLOG"
bt 'BLUETOOTH=si' 'hk_list() { echo 0,1; }; start_services' >/dev/null 2>&1
expect "core: ogni processo ha taskset sui soli core di sistema" "2" "$(grep -c '^taskset -c 0,1 ' "$BTLOG")"
expect "core: nessun riferimento al core isolato" "0" "$(grep -c 'ISOLATED\|isolated' "$BT_SCRIPT")"
expect "core: lo script non tocca le interruzioni USB" "0" "$(grep -Ec 'xhci|ehci' "$BT_SCRIPT")"

echo "Bluetooth: pannello"
cat > "$T/bin/sweetspot-bluetooth" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BTLOG"
[ "$1" = elenco ] && printf 'AA:BB:CC:DD:EE:01|Telefono di Anna|si\nAA:BB:CC:DD:EE:02|Pixel|no\n'
[ "$1" = abbina ] && [ "${BT_ABBINA_RC:-0}" != 0 ] && exit 1
exit 0
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$BTLOG"\nexit 0\n' > "$T/bin/sweetspot-config"
chmod +x "$T/bin/sweetspot-bluetooth" "$T/bin/sweetspot-config"
printf 'tokenfinto\n' > "$T/run/web.token"
pagina() { # righe-conf
	mkconf "$1"
	SWEETSPOT_SYSFS=$T/sys SWEETSPOT_PROCFS=$T/proc SWEETSPOT_RUN=$T/run SWEETSPOT_LOG=$T/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$T/bin" \
		REQUEST_METHOD=GET QUERY_STRING="" HTTP_HOST=sweetspot.local \
		$SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $CGI/bluetooth" 2>&1
}
azione() { # corpo
	local body="t=tokenfinto&$1"
	printf '%s' "$body" | SWEETSPOT_SYSFS=$T/sys SWEETSPOT_PROCFS=$T/proc SWEETSPOT_RUN=$T/run SWEETSPOT_LOG=$T/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$T/bin" \
		REQUEST_METHOD=POST CONTENT_LENGTH=${#body} $SH "$CGI/azione" 2>&1
}
out=$(pagina '')
case "$out" in *"Bluetooth spento"*) ok "pagina: spento di serie" ;; *) expect "pagina spenta" "Bluetooth spento" "$out" ;; esac
case "$out" in *'name="bt_minuti"'*) expect "pagina spenta: nessun abbinamento" "assente" "presente" ;; *) ok "pagina spenta: nessun abbinamento" ;; esac
echo "pronto, in attesa del telefono" > "$T/run/bluetooth.stato"
out=$(pagina 'BLUETOOTH=si')
case "$out" in *"pronto, in attesa del telefono"*) ok "pagina: stato del servizio" ;; *) expect "pagina stato" "pronto" "$out" ;; esac
case "$out" in *'name="bt_minuti"'*'value="bluetooth_abbina"'*|*'value="bluetooth_abbina"'*'name="bt_minuti"'*) ok "pagina: finestra di abbinamento" ;; *) expect "pagina abbinamento" "modulo" "$out" ;; esac
case "$out" in *"Telefono di Anna"*"AA:BB:CC:DD:EE:02"*) ok "pagina: dispositivi abbinati" ;; *) expect "pagina elenco" "elenco" "$out" ;; esac
expect "pagina: un pulsante Rimuovi per dispositivo" "2" "$(printf '%s' "$out" | grep -c 'value="bluetooth_rimuovi"')"
expect "pagina: link nel menu" "1" "$(printf '%s' "$out" | grep -c 'href="/cgi-bin/bluetooth"')"
if [ -n "$BB" ]; then
ln -sf "$BB" "$T/bin/httpd"
: > "$BTLOG"
azione 'a=bluetooth_imposta&bt_attivo=si&bt_nome=Cucina' > /dev/null
expect "azione: salva e applica" "imposta BLUETOOTH si
imposta BLUETOOTH_NOME Cucina
applica" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_imposta&bt_attivo=forse&bt_nome=' > /dev/null
expect "azione: valore non valido = spento, nome azzerato" "imposta BLUETOOTH no
rimuovi BLUETOOTH_NOME
applica" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_abbina&bt_minuti=5' > /dev/null
expect "azione: apre l'abbinamento" "abbina 5" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_abbina&bt_minuti=500' > /dev/null
expect "azione: minuti fuori misura tornano a 2" "abbina 2" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_rimuovi&bt_mac=AA:BB:CC:DD:EE:01' > /dev/null
expect "azione: rimuove un dispositivo" "rimuovi AA:BB:CC:DD:EE:01" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_chiudi' > /dev/null
expect "azione: chiude l'abbinamento" "chiudi" "$(cat "$BTLOG")"
: > "$BTLOG"
azione 'a=bluetooth_imposta&bt_attivo=si&t=sbagliato' > /dev/null
expect "azione: senza il gettone giusto non fa nulla" "0" "$(grep -c . "$BTLOG")"
else
	echo "  (busybox non trovato: azioni del pannello saltate, servono httpd -d)"
fi

echo "Bluetooth: pagina Stato"
# Solo la funzione check_bluetooth di sweetspot-check, con emit finta: il
# controllo completo ha bisogno di un /proc e un /sys interi (vedi run.sh).
{
	echo 'emit() { printf "%s|%s|%s\n" "$1" "$2" "$3"; }'
	sed -n '/^check_bluetooth() {/,/^}/p' "$OVERLAY/usr/bin/sweetspot-check"
	echo 'check_bluetooth'
} > "$T/cb.sh"
statoverifica() { # righe-conf
	mkconf "$1"
	SWEETSPOT_SYSFS=$T/sys SWEETSPOT_PROCFS=$T/proc SWEETSPOT_RUN=$T/run SWEETSPOT_LOG=$T/log \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf SWEETSPOT_PATH="$T/bin" \
		$SH -c ". $OVERLAY/usr/lib/sweetspot/common.sh; . $T/cb.sh" 2>&1
}
expect "stato: la funzione e' in sweetspot-check e viene chiamata" "2" "$(grep -c '^\(check_bluetooth() {\|check_bluetooth\)$' "$OVERLAY/usr/bin/sweetspot-check")"
expect "stato: spento" "INFO|Bluetooth|spento (si attiva dalla pagina Bluetooth)" "$(statoverifica '')"
echo "abbinamento aperto" > "$T/run/bluetooth.stato"
expect "stato: abbinamento aperto" "OK|Bluetooth|abbinamento aperto" "$(statoverifica 'BLUETOOTH=si')"
echo "in ascolto: Pixel" > "$T/run/bluetooth.stato"
expect "stato: in ascolto" "OK|Bluetooth|in ascolto: Pixel (il DAC e' del telefono, il player riprende alla fine)" "$(statoverifica 'BLUETOOTH=si')"
echo "nessun adattatore Bluetooth" > "$T/run/bluetooth.stato"
expect "stato: senza adattatore" "ATTENZIONE|Bluetooth|nessun adattatore Bluetooth" "$(statoverifica 'BLUETOOTH=si')"

echo
echo "Bluetooth - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
