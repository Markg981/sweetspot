#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pannello web senza root: elenco chiuso dell'helper privilegiato
# (sweetspot-priv), configurazione senza password per le pagine, file
# dell'accesso, utente "web" e argomenti dell'httpd.
# L'helper si compila in versione di prova (niente setuid, script finti in
# una cartella temporanea): serve un compilatore C; senza, quei controlli
# sono saltati e lo si dice.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
SRC=$ROOT/package/sweetspot-tools/src/sweetspot-priv.c
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

echo "Utente web e httpd senza privilegi"
expect "utente web nella tabella degli utenti" "1" "$(grep -c '^web -1 web -1 ' "$ROOT/board/sweetspot/users.txt")"
expect "httpd con -u web:web" "1" "$(grep -c -- '^HTTPD_ARGS=.*-u web:web' "$OVERLAY/etc/default/httpd")"
expect "httpd riscritto da S03 con -u web:web" "1" "$(grep -c -- "-u web:web" "$OVERLAY/etc/init.d/S03sweetspot-early")"
for d in x86_64 rpi; do
	expect "script di avvio dell'httpd installato ($d)" "1" "$(grep -c '^BR2_PACKAGE_BUSYBOX_HTTPD=y' "$ROOT/configs/sweetspot_${d}_defconfig")"
done
expect "BusyBox con httpd -u" "1" "$(grep -c '^CONFIG_FEATURE_HTTPD_SETUID=y' "$ROOT/board/sweetspot/common/busybox.fragment")"
expect "helper setuid installato (4755)" "1" "$(grep -c 'sweetspot-priv f 4755 0 0' "$ROOT/package/sweetspot-tools/sweetspot-tools.mk")"

echo "Le pagine non chiamano piu' direttamente le operazioni di root"
# Ogni chiamata a uno script privilegiato, nelle pagine, passa da priv.
direct=$(grep -nE '(^|[^a-z-])sweetspot-(config|lms|rete|dischi|nas|copia|cd|spazio|aggiorna|installa|dsp|accesso|check|hotspot)( |$|\))' \
	"$OVERLAY"/usr/share/sweetspot/www/cgi-bin/* | grep -v 'priv sweetspot-' | grep -v 'priv_confirm "[^"]*" "[^"]*" sweetspot-' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v '[<>]' || true)
expect "nessuna chiamata diretta" "" "$direct"
expect "azione non scrive piu' in \$RUN" "0" "$(grep -c '>> *"\$RUN/\|: > *"\$RUN/\|touch "\$RUN/\|mkdir -p "\$RUN' "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione")"

echo "Configurazione per le pagine senza password"
CFG=$WORK/cfg
mkdir -p "$CFG/run"
printf 'PASSWORD_WEB=$1$abcd$efgh\nWIFI_PASSWORD=segretissima\nSSH_PASSWORD=altro\nLYRION_PASSWORD=lyr\nNOME_PLAYER=Salotto\nSSH_PASSWORD_VUOTA=\n' > "$CFG/s.txt"
SWEETSPOT_RUN=$CFG/run SWEETSPOT_DEFAULTS=/nonexistent SWEETSPOT_LOG=$CFG/log sh -c ". $OVERLAY/usr/lib/sweetspot/common.sh; config_build $CFG/s.txt"
web=$(cat "$CFG/run/sweetspot.web")
case "$web" in *segretissima*|*altro*|*lyr*|*abcd*) FAIL=$((FAIL + 1)); echo "  NO  le password compaiono nella copia delle pagine" ;; *) ok "nessuna password nella copia delle pagine" ;; esac
expect "password presente = valore *" "PASSWORD_WEB=*|WIFI_PASSWORD=*" "$(grep '^PASSWORD_WEB=\|^WIFI_PASSWORD=' "$CFG/run/sweetspot.web" | tr '\n' '|' | sed 's/|$//')"
expect "password vuota resta vuota" "SSH_PASSWORD_VUOTA=" "$(grep '^SSH_PASSWORD_VUOTA' "$CFG/run/sweetspot.web")"
expect "le altre voci restano" "NOME_PLAYER=Salotto" "$(grep '^NOME_PLAYER' "$CFG/run/sweetspot.web")"
expect "configurazione completa solo di root (0600)" "600" "$(stat -c %a "$CFG/run/sweetspot.conf" 2>/dev/null || stat -f %Lp "$CFG/run/sweetspot.conf")"
expect "la configurazione completa ha ancora le password" "1" "$(grep -c '^WIFI_PASSWORD=segretissima' "$CFG/run/sweetspot.conf")"

echo "Helper privilegiato: elenco chiuso"
CC=$(command -v cc || command -v gcc || command -v clang || true)
if [ -z "$CC" ]; then
	echo "  (nessun compilatore C: controlli dell'helper saltati)"
else
	B=$WORK/bin
	W=$WORK/web
	mkdir -p "$B" "$W"
	for s in config lms mediaserver rete dischi nas copia cd spazio aggiorna installa dsp accesso check rapporto hotspot https diario bluetooth; do
		printf '#!/bin/sh\nprintf "%%s" "sweetspot-%s" > "%s/chiamata"\nfor a in "$@"; do printf "|%%s" "$a" >> "%s/chiamata"; done\nprintf "\\n" >> "%s/chiamata"\n' "$s" "$WORK" "$WORK" "$WORK" > "$B/sweetspot-$s"
		chmod +x "$B/sweetspot-$s"
	done
	if ! $CC -Wall -Wextra -Werror -O2 -DSWEETSPOT_PRIV_PROVA -DPROVA_BIN="\"$B/\"" -DPROVA_WEB="\"$W/\"" \
		-o "$WORK/priv" "$SRC" 2> "$WORK/cc.err"; then
		FAIL=$((FAIL + 1)); printf '  NO  compilazione dell helper: %s\n' "$(cat "$WORK/cc.err")"
	else
		ok "l'helper si compila senza avvisi"
		# priv ARGOMENTI...: stampa la chiamata fatta allo script finto, "NIENTE" se rifiutata.
		priv() {
			rm -f "$WORK/chiamata"
			"$WORK/priv" "$@" > /dev/null 2>&1
			rc=$?
			if [ -f "$WORK/chiamata" ]; then cat "$WORK/chiamata"; else echo "NIENTE($rc)"; fi
		}
		expect "config imposta ammesso" "sweetspot-config|imposta|VOLUME|fisso|DSD|dop" "$(priv sweetspot-config imposta VOLUME fisso DSD dop)"
		for m in 0 0.0 -0 -3 -1.5 -12 -23.9 -24 -24.0; do
			expect "config margine DSD $m ammesso" "sweetspot-config|imposta|DSD_PCM_MARGINE_DB|$m" "$(priv sweetspot-config imposta DSD_PCM_MARGINE_DB "$m")"
		done
		for m in 1 +1 3 -24.1 -25 -100 -3.55 -3. .5 -.5 -3x 1e1 "-3 " "- 3" abc "-3;reboot" '$(id)' --3 0x1; do
			expect "config margine DSD '$m' rifiutato" "NIENTE(126)" "$(priv sweetspot-config imposta DSD_PCM_MARGINE_DB "$m")"
		done
		expect "config chiave minuscola non ammessa" "NIENTE(126)" "$(priv sweetspot-config imposta volume fisso)"
		expect "config valore vuoto ammesso" "sweetspot-config|imposta|DNS|" "$(priv sweetspot-config imposta DNS '')"
		expect "config condivisione 3 con utente e password" "sweetspot-config|imposta|CONDIVISIONE_3_UTENTE|u|CONDIVISIONE_3_PASSWORD|p" \
			"$(priv sweetspot-config imposta CONDIVISIONE_3_UTENTE u CONDIVISIONE_3_PASSWORD p)"
		expect "config condivisione 3 con SMB1" "sweetspot-config|imposta|CONDIVISIONE_3_SMB1|si" \
			"$(priv sweetspot-config imposta CONDIVISIONE_3_SMB1 si)"
		expect "config condivisione 0 rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta CONDIVISIONE_0 x)"
		expect "config condivisione 10 rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta CONDIVISIONE_10 x)"
		expect "config chiave fuori elenco (LYRION_MEM_MB)" "NIENTE(126)" "$(priv sweetspot-config imposta LYRION_MEM_MB 512)"
		expect "config chiave fuori elenco (STICK_LABEL)" "NIENTE(126)" "$(priv sweetspot-config imposta SWEETSPOT_PATH /tmp)"
		expect "config coppia incompleta" "NIENTE(126)" "$(priv sweetspot-config imposta VOLUME)"
		expect "config valore con a capo" "NIENTE(126)" "$(priv sweetspot-config imposta VOLUME "fisso
SSH=si")"
		expect "config rimuovi ammesso" "sweetspot-config|rimuovi|IP_FISSO|GATEWAY" "$(priv sweetspot-config rimuovi IP_FISSO GATEWAY)"
		expect "config rimuovi senza chiavi" "NIENTE(126)" "$(priv sweetspot-config rimuovi)"
		expect "config leggi non ammesso" "NIENTE(126)" "$(priv sweetspot-config leggi WIFI_PASSWORD)"
		expect "script fuori elenco" "NIENTE(126)" "$(priv sweetspot-player restart)"
		expect "script con percorso" "NIENTE(126)" "$(priv ../../bin/sh -c id)"
		expect "script con percorso assoluto" "NIENTE(126)" "$(priv /bin/sh -c id)"
		expect "sottocomando fuori elenco" "NIENTE(126)" "$(priv sweetspot-aggiorna _lavoro)"
		expect "sottocomando ammesso" "sweetspot-aggiorna|stato" "$(priv sweetspot-aggiorna stato)"
		expect "argomenti in piu' rifiutati" "NIENTE(126)" "$(priv sweetspot-aggiorna stato extra)"
		expect "argomenti mancanti rifiutati" "NIENTE(126)" "$(priv sweetspot-dischi smonta)"
		expect "rete: solo condivisioni 1-9" "sweetspot-rete|prova|4" "$(priv sweetspot-rete prova 4)"
		expect "rete: 0 rifiutato" "NIENTE(126)" "$(priv sweetspot-rete prova 0)"
		expect "rete: 10 rifiutato" "NIENTE(126)" "$(priv sweetspot-rete prova 10)"
		expect "rete: testo rifiutato" "NIENTE(126)" "$(priv sweetspot-rete smonta-una '1;id')"
		expect "installa avvia senza conferma forte: rifiutato" "NIENTE(126)" "$(priv sweetspot-installa avvia sda si 465)"
		expect "installa dischi ammesso" "sweetspot-installa|dischi" "$(priv sweetspot-installa dischi)"
		expect "installa accanto (elenco) ammesso" "sweetspot-installa|accanto" "$(priv sweetspot-installa accanto)"
		expect "installa affianca senza conferma forte: rifiutato" "NIENTE(126)" "$(priv sweetspot-installa affianca nvme0n1 476)"
		expect "hotspot richiesta ammessa" "sweetspot-hotspot|richiesta" "$(priv sweetspot-hotspot richiesta)"
		expect "hotspot scansiona ammessa" "sweetspot-hotspot|scansiona" "$(priv sweetspot-hotspot scansiona)"
		expect "hotspot collega ammessa" "sweetspot-hotspot|collega" "$(priv sweetspot-hotspot collega)"
		expect "hotspot prova non ammessa" "NIENTE(126)" "$(priv sweetspot-hotspot prova wlan0)"
		expect "hotspot sorveglia non ammessa" "NIENTE(126)" "$(priv sweetspot-hotspot sorveglia)"
		expect "carattere di controllo rifiutato" "NIENTE(126)" "$(priv sweetspot-copia avvia "$(printf 'a\001b')")"
		expect "argomento troppo lungo rifiutato" "NIENTE(126)" "$(priv sweetspot-copia avvia "$(head -c 2000 /dev/zero | tr '\0' a)")"
		expect "nessun argomento" "NIENTE(126)" "$(priv)"
		expect "azione interna sconosciuta" "NIENTE(126)" "$(priv @shell)"
		expect "sweetspot-rapporto senza argomenti" "sweetspot-rapporto" "$(priv sweetspot-rapporto)"
		expect "sweetspot-rapporto con argomenti" "NIENTE(126)" "$(priv sweetspot-rapporto salva)"
		expect "diario bundle ammesso" "sweetspot-diario|bundle" "$(priv sweetspot-diario bundle)"
		expect "diario: altri sottocomandi rifiutati" "NIENTE(126)|NIENTE(126)" "$(priv sweetspot-diario salva)|$(priv sweetspot-diario bundle x)"
		# Lyrion: solo i comandi usati dalle pagine.
		expect "lms plugin installa" "sweetspot-lms|plugin|installa|Qobuz" "$(priv sweetspot-lms plugin installa Qobuz)"
		expect "lms plugin con nome strano" "NIENTE(126)" "$(priv sweetspot-lms plugin installa '../x')"
		expect "lms plugin sconosciuto" "NIENTE(126)" "$(priv sweetspot-lms plugin cancella Qobuz)"
		expect "lms operazione: installa plugin" "sweetspot-lms|operazione|avvia|plugin-installa|Qobuz" "$(priv sweetspot-lms operazione avvia plugin-installa Qobuz)"
		expect "lms operazione: aggiorna la libreria" "sweetspot-lms|operazione|avvia|aggiorna" "$(priv sweetspot-lms operazione avvia aggiorna)"
		expect "lms operazione: nome strano" "NIENTE(126)" "$(priv sweetspot-lms operazione avvia plugin-installa '../x')"
		expect "lms operazione: plugin senza nome" "NIENTE(126)" "$(priv sweetspot-lms operazione avvia plugin-rimuovi)"
		expect "lms operazione: tipo sconosciuto" "NIENTE(126)" "$(priv sweetspot-lms operazione avvia riavvia)"
		expect "lms operazione: solo avvia (esegui riservato)" "NIENTE(126)" "$(priv sweetspot-lms operazione esegui x aggiorna)"
		expect "lms json stato del server" "sweetspot-lms|json||serverstatus|0|0" "$(priv sweetspot-lms json '' serverstatus 0 0)"
		expect "lms json nome del player" "sweetspot-lms|json|aa:bb:cc:dd:ee:ff|name|Salotto" "$(priv sweetspot-lms json aa:bb:cc:dd:ee:ff name Salotto)"
		expect "lms json brano in ascolto" "sweetspot-lms|json|aa:bb|status|-|1|tags:aloITr" "$(priv sweetspot-lms json aa:bb status - 1 tags:aloITr)"
		expect "lms json anteprima" "sweetspot-lms|json|aa:bb|playlist|preview|url:file:///tmp/p.wav|title:Prova DoP" \
			"$(priv sweetspot-lms json aa:bb playlist preview url:file:///tmp/p.wav 'title:Prova DoP')"
		expect "lms json altro comando (pref)" "NIENTE(126)" "$(priv sweetspot-lms json '' pref authorize 0)"
		expect "studio album" "sweetspot-lms|json||albums|0|50|tags:ljaS|search:Blu" "$(priv sweetspot-lms json '' albums 0 50 tags:ljaS 'search:Blu')"
		expect "studio ricerca con spazi e Unicode (un solo argomento)" "sweetspot-lms|json||artists|0|50|search:Pink Floyd è" "$(priv sweetspot-lms json '' artists 0 50 'search:Pink Floyd è')"
		expect "studio ricerca spezzata in due argomenti rifiutata" "NIENTE(126)" "$(priv sweetspot-lms json '' albums 0 50 search:Pink Floyd)"
		expect "studio volume" "sweetspot-lms|json|aa:bb|mixer|volume|40" "$(priv sweetspot-lms json aa:bb mixer volume 40)"
		expect "studio volume oltre 100" "NIENTE(126)" "$(priv sweetspot-lms json aa:bb mixer volume 400)"
		expect "studio seek" "sweetspot-lms|json|aa:bb|time|95" "$(priv sweetspot-lms json aa:bb time 95)"
		expect "studio carica album" "sweetspot-lms|json|aa:bb|playlistcontrol|cmd:load|album_id:7" "$(priv sweetspot-lms json aa:bb playlistcontrol cmd:load album_id:7)"
		expect "studio carica cartella" "sweetspot-lms|json|aa:bb|playlistcontrol|cmd:load|folder_id:12" "$(priv sweetspot-lms json aa:bb playlistcontrol cmd:load folder_id:12)"
		expect "studio sfoglia cartella" "sweetspot-lms|json||musicfolder|0|200|folder_id:12" "$(priv sweetspot-lms json '' musicfolder 0 200 folder_id:12)"
		expect "studio sfoglia cartella per percorso" "NIENTE(126)" "$(priv sweetspot-lms json '' musicfolder 0 200 url:file:///etc)"
		expect "studio carica con comando libero" "NIENTE(126)" "$(priv sweetspot-lms json aa:bb playlistcontrol cmd:load url:file:///x)"
		expect "studio elenco senza numeri" "NIENTE(126)" "$(priv sweetspot-lms json '' albums a b)"
		expect "studio elenco troppo grande" "NIENTE(126)" "$(priv sweetspot-lms json '' albums 0 5000)"
		expect "studio opzione ignota" "NIENTE(126)" "$(priv sweetspot-lms json '' albums 0 10 'x:1')"
		expect "studio zona" "sweetspot-lms|json|aa:bb|sync|11:22" "$(priv sweetspot-lms json aa:bb sync 11:22)"
		expect "studio pausa" "sweetspot-lms|json|aa:bb|pause|1" "$(priv sweetspot-lms json aa:bb pause 1)"
		expect "studio senza player" "NIENTE(126)" "$(priv sweetspot-lms json '' play)"
		expect "studio pref ancora negata" "NIENTE(126)" "$(priv sweetspot-lms json aa:bb pref authorize 0)"
		expect "lms json restartserver" "NIENTE(126)" "$(priv sweetspot-lms json '' restartserver)"
		expect "studio copertina" "sweetspot-lms|cover|ab12|200" "$(priv sweetspot-lms cover ab12 200)"
		expect "studio copertina: dimensione libera" "NIENTE(126)" "$(priv sweetspot-lms cover ab12 5000)"
		expect "studio copertina: id con percorso" "NIENTE(126)" "$(priv sweetspot-lms cover ../x 200)"
		expect "lms json anteprima fuori da file://" "NIENTE(126)" "$(priv sweetspot-lms json aa:bb playlist preview url:http://x/y.wav 'title:Prova DoP')"
		expect "lms json anteprima con .." "NIENTE(126)" "$(priv sweetspot-lms json aa:bb playlist preview url:file:///tmp/../etc/passwd 'title:Prova DoP')"
		# File delle pagine: solo sotto la cartella delle pagine, mai collegamenti.
		printf 'x\n' > "$W/a.txt"
		got=$(priv sweetspot-dsp leggi "$W/a.txt")
		case "$got" in "sweetspot-dsp|leggi|/proc/self/fd/"*) ok "dsp leggi: file delle pagine passato come descrittore aperto" ;; *) FAIL=$((FAIL + 1)); echo "  NO  dsp leggi file delle pagine: [$got]" ;; esac
		expect "dsp leggi: file fuori dalla cartella" "NIENTE(126)" "$(priv sweetspot-dsp leggi /etc/passwd)"
		expect "dsp leggi: .." "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/../chiamata")"
		expect "dsp leggi: file mancante" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/manca.txt")"
		if ln -s /etc/hostname "$W/link.txt" 2> /dev/null && [ -L "$W/link.txt" ]; then
			expect "dsp leggi: collegamento simbolico rifiutato" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/link.txt")"
		fi
		ln "$W/a.txt" "$W/b.txt" 2> /dev/null && expect "dsp leggi: file con piu' nomi rifiutato" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/a.txt")"
		# Collegamento simbolico a una CARTELLA sotto la base: O_NOFOLLOW non basta.
		mkdir -p "$WORK/fuori" && printf 'segreto\n' > "$WORK/fuori/shadow"
		if ln -s "$WORK/fuori" "$W/dir" 2> /dev/null && [ -L "$W/dir" ]; then
			expect "dsp leggi: collegamento a cartella rifiutato" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/dir/shadow")"
		fi
		mkdir -p "$W/sotto" && printf 'x\n' > "$W/sotto/f.txt"
		got=$(priv sweetspot-dsp leggi "$W/sotto/f.txt")
		case "$got" in "sweetspot-dsp|leggi|/proc/self/fd/"*) ok "dsp leggi: file in sottocartella vera ammesso" ;; *) FAIL=$((FAIL + 1)); echo "  NO  dsp leggi sottocartella: [$got]" ;; esac
		expect "dsp leggi: componenti vuoti rifiutati" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/sotto//f.txt")"
		expect "dsp leggi: la sola base rifiutata" "NIENTE(126)" "$(priv sweetspot-dsp leggi "$W/")"
		# File di un altro proprietario sotto BASE_WEB (qui "web" e' un altro uid).
		rm -f "$WORK/chiamata"
		SWEETSPOT_PROVA_UID=$(($(id -u) + 1)) "$WORK/priv" sweetspot-dsp leggi "$W/a.txt" > /dev/null 2>&1
		expect "dsp leggi: file non di web sotto BASE_WEB rifiutato" "no" "$([ -f "$WORK/chiamata" ] && echo si || echo no)"
		# Opzioni: testo o parola che inizia con '-' non va agli script di root.
		expect "copia avvia: '-x' rifiutato" "NIENTE(126)" "$(priv sweetspot-copia avvia -x)"
		expect "bluetooth rimuovi: '-x' rifiutato" "NIENTE(126)" "$(priv sweetspot-bluetooth rimuovi -x)"
		expect "config imposta: valore con '-' iniziale ammesso" "sweetspot-config|imposta|NOME_PLAYER|-x" "$(priv sweetspot-config imposta NOME_PLAYER -x)"
		# Gli script che accettano un '-' iniziale non lo trattano da opzione.
		expect "accesso hash: '-n' arriva come argomento" "sweetspot-accesso|hash|-n" "$(priv sweetspot-accesso hash -n)"
		expect "cd copia: nomi con '-' iniziale ammessi" "sweetspot-cd|copia|-e|--help|-n" "$(priv sweetspot-cd copia -e --help -n)"
		expect "accesso: mkpasswd con -- davanti alla password" "1" "$(grep -c 'mkpasswd -m "\$1" -S "\$salt" -- "\$4"' "$OVERLAY/usr/bin/sweetspot-accesso")"
		expect "config: i valori passano da ENVIRON, non da opzioni" "0" "$(grep -c 'awk -v VAL\|echo "\$VAL"' "$OVERLAY/usr/bin/sweetspot-config")"
		# @log: riga troppo lunga rifiutata.
		"$WORK/priv" @log "$(printf '%0600d' 0)" > /dev/null 2>&1
		expect "@log troppo lungo rifiutato" "126" "$?"
		# L'ambiente non passa agli script.
		printf '#!/bin/sh\nenv > "%s/env"\n' "$WORK" > "$B/sweetspot-check"
		SWEETSPOT_PATH=/evil LD_PRELOAD=/x IFS=x "$WORK/priv" sweetspot-check --dati > /dev/null 2>&1
		expect "ambiente ripulito" "PATH=/usr/sbin:/usr/bin:/sbin:/bin" "$(grep -E '^(PATH|SWEETSPOT_PATH|LD_PRELOAD|IFS)=' "$WORK/env" | head -n 1)"
		expect "nessuna variabile ereditata" "0" "$(grep -cE '^(SWEETSPOT_PATH|LD_PRELOAD|IFS)=' "$WORK/env")"

		# Chiavi che aprono root: mai con l'elenco normale, solo con @conferma
		# (gettone monouso + password del pannello, verificata da root).
		echo "Helper privilegiato: chiavi che aprono root"
		printf '#!/bin/sh\nif [ "$1" = verifica ]; then read -r pw; [ "$pw" = segreta ] || exit 1; exit 0; fi\nprintf "sweetspot-accesso" > "%s/chiamata"\nfor a in "$@"; do printf "|%%s" "$a" >> "%s/chiamata"; done\n' "$WORK" "$WORK" > "$B/sweetspot-accesso"
		chmod +x "$B/sweetspot-accesso"
		# sconf PASSWORD ARGOMENTI...: come "priv" ma con la password sull'ingresso standard.
		sconf() {
			local pw=$1
			shift
			rm -f "$WORK/chiamata"
			printf '%s\n' "$pw" | "$WORK/priv" "$@" > /dev/null 2>&1
			rc=$?
			if [ -f "$WORK/chiamata" ]; then cat "$WORK/chiamata"; else echo "NIENTE($rc)"; fi
		}
		for k in SSH SSH_PASSWORD SSH_UTENTE; do
			expect "config $k senza conferma: rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta "$k" si)"
		done
		expect "config SSH insieme a chiavi normali: tutto rifiutato" "NIENTE(126)" "$(priv sweetspot-config imposta VOLUME fisso SSH si)"
		expect "config SSH_PASSWORD in coda: rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta NOME_PLAYER x SSH_PASSWORD segreta)"
		# La password del pannello e i pacchetti da disco: una sessione rubata non basta.
		expect "config PASSWORD_WEB senza conferma: rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta PASSWORD_WEB '$1$x$y')"
		expect "config PASSWORD_WEB in coda: rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta NOME_PLAYER x PASSWORD_WEB '$1$x$y')"
		expect "config rimuovi PASSWORD_WEB senza conferma: rifiutata" "NIENTE(126)" "$(priv sweetspot-config rimuovi PASSWORD_WEB)"
		expect "aggiorna file senza conferma: rifiutato" "NIENTE(126)" "$(priv sweetspot-aggiorna file /media/USB/pacchetto.tar)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "gettone: 32 cifre esadecimali" "1" "$(printf '%s' "$tok" | grep -cE '^[0-9a-f]{32}$')"
		expect "gettone: file nella cartella di root" "si" "$([ -f "$W/conferma/$tok" ] && echo si || echo no)"
		expect "conferma con la password giusta" "sweetspot-config|imposta|SSH|si|SSH_PASSWORD|nuova" \
			"$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH si SSH_PASSWORD nuovapassword1)"
		expect "il gettone e' monouso" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH si)"
		expect "gettone consumato: il file non c'e' piu'" "no" "$([ -f "$W/conferma/$tok" ] && echo si || echo no)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "password sbagliata: rifiutata" "NIENTE(126)" "$(sconf sbagliata @conferma "$tok" sweetspot-config imposta SSH si)"
		expect "password sbagliata: il gettone e' bruciato" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH si)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "password vuota: rifiutata" "NIENTE(126)" "$(sconf '' @conferma "$tok" sweetspot-config imposta SSH si)"
		expect "gettone inventato: rifiutato" "NIENTE(126)" "$(sconf segreta @conferma 00000000000000000000000000000000 sweetspot-config imposta SSH si)"
		expect "gettone con percorso: rifiutato" "NIENTE(126)" "$(sconf segreta @conferma ../../../etc/passwd sweetspot-config imposta SSH si)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "installazione con conferma e dimensione" "sweetspot-installa|avvia|sda|si|465" \
			"$(sconf segreta @conferma "$tok" sweetspot-installa avvia sda si 465)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "installazione con conferma ma senza dimensione: rifiutata" "NIENTE(126)" \
			"$(sconf segreta @conferma "$tok" sweetspot-installa avvia sda si)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "installazione con password sbagliata: rifiutata" "NIENTE(126)" \
			"$(sconf sbagliata @conferma "$tok" sweetspot-installa avvia sda si 465)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "installazione accanto con conferma e dimensione" "sweetspot-installa|affianca|nvme0n1|476" \
			"$(sconf segreta @conferma "$tok" sweetspot-installa affianca nvme0n1 476)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "installazione accanto senza dimensione: rifiutata" "NIENTE(126)" \
			"$(sconf segreta @conferma "$tok" sweetspot-installa affianca nvme0n1)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma non sblocca script fuori elenco" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-player restart)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma non sblocca chiavi fuori elenco" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-config imposta LYRION_MEM_MB 512)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma vale anche l'utente di assistenza" "sweetspot-config|imposta|SSH_UTENTE|assistenza" \
			"$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH_UTENTE assistenza)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma vale la password delle pagine" 'sweetspot-config|imposta|PASSWORD_WEB|$1$x$y' \
			"$(sconf segreta @conferma "$tok" sweetspot-config imposta PASSWORD_WEB '$1$x$y')"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma vale il pacchetto dal disco" "sweetspot-aggiorna|file|/media/USB/pacchetto.tar" \
			"$(sconf segreta @conferma "$tok" sweetspot-aggiorna file /media/USB/pacchetto.tar)"
		expect "file-downgrade senza conferma: rifiutato" "NIENTE(126)" "$(priv sweetspot-aggiorna file-downgrade /media/USB/pacchetto.tar)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma vale il downgrade dal disco" "sweetspot-aggiorna|file-downgrade|/media/USB/pacchetto.tar" \
			"$(sconf segreta @conferma "$tok" sweetspot-aggiorna file-downgrade /media/USB/pacchetto.tar)"
		tok=$("$WORK/priv" @conferma-nuova)
		expect "la conferma non basta con l'a capo nel valore" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH_PASSWORD "a
SSH=si")"
		# Gettone scaduto: il file piu' vecchio di 10 minuti non vale.
		tok=$("$WORK/priv" @conferma-nuova)
		touch -d '20 minutes ago' "$W/conferma/$tok" 2> /dev/null && \
			expect "gettone scaduto: rifiutato" "NIENTE(126)" "$(sconf segreta @conferma "$tok" sweetspot-config imposta SSH si)"
		# Troppi gettoni: il piu' vecchio cede il posto, la cartella non cresce.
		for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "$WORK/priv" @conferma-nuova > /dev/null; done
		expect "al massimo 16 gettoni validi" "si" "$([ "$(ls "$W/conferma" | wc -l | tr -d ' ')" -le 16 ] && echo si || echo no)"

		# Valori controllati chiave per chiave: niente injection nei posti dove finiscono.
		echo "Helper privilegiato: valori delle chiavi"
		expect "SCHEDA_I2S: overlay ammesso" "sweetspot-config|imposta|SCHEDA_I2S|hifiberry-dacplus" "$(priv sweetspot-config imposta SCHEDA_I2S hifiberry-dacplus)"
		expect "SCHEDA_I2S: parametri del kernel rifiutati" "NIENTE(126)" "$(priv sweetspot-config imposta SCHEDA_I2S 'x init=/bin/sh')"
		expect "SCHEDA_I2S: virgola e parametri dell'overlay rifiutati" "NIENTE(126)" "$(priv sweetspot-config imposta SCHEDA_I2S 'x,y=1')"
		expect "IP_FISSO: indirizzo con maschera" "sweetspot-config|imposta|IP_FISSO|192.168.1.50/24" "$(priv sweetspot-config imposta IP_FISSO 192.168.1.50/24)"
		expect "IP_FISSO: comando rifiutato" "NIENTE(126)" "$(priv sweetspot-config imposta IP_FISSO '1.2.3.4; reboot')"
		expect "GATEWAY: sostituzione di comando rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta GATEWAY '$(id)')"
		expect "DNS: solo indirizzo" "NIENTE(126)" "$(priv sweetspot-config imposta DNS 'x
nameserver 6.6.6.6')"
		expect "SERVER: nome o indirizzo" "sweetspot-config|imposta|SERVER|lyrion.local" "$(priv sweetspot-config imposta SERVER lyrion.local)"
		expect "SERVER: opzioni del player rifiutate" "NIENTE(126)" "$(priv sweetspot-config imposta SERVER '1.2.3.4 -o /dev/null')"
		expect "NOME_RETE: lettere minuscole, cifre, trattini" "NIENTE(126)" "$(priv sweetspot-config imposta NOME_RETE 'Casa Mia')"
		expect "FREQUENZA_MAX: solo cifre" "NIENTE(126)" "$(priv sweetspot-config imposta FREQUENZA_MAX '192000;id')"
		expect "FREQUENZA_MAX: cifre" "sweetspot-config|imposta|FREQUENZA_MAX|192000" "$(priv sweetspot-config imposta FREQUENZA_MAX 192000)"
		expect "VOLUME: una parola" "NIENTE(126)" "$(priv sweetspot-config imposta VOLUME 'fisso x')"
		expect "ARCHIVIO: identita' del disco" "sweetspot-config|imposta|ARCHIVIO|UUID=1234-ABCD" "$(priv sweetspot-config imposta ARCHIVIO UUID=1234-ABCD)"
		expect "ARCHIVIO: percorso rifiutato" "NIENTE(126)" "$(priv sweetspot-config imposta ARCHIVIO /dev/sda1)"
		expect "ESCLUDI_DISCHI: elenco di nomi" "sweetspot-config|imposta|ESCLUDI_DISCHI|sda,Dati 2" "$(priv sweetspot-config imposta ESCLUDI_DISCHI 'sda,Dati 2')"
		expect "ESCLUDI_DISCHI: caratteri di shell rifiutati" "NIENTE(126)" "$(priv sweetspot-config imposta ESCLUDI_DISCHI 'sda;id')"
		expect "CONDIVISIONE_n_SMB1: solo si/no" "NIENTE(126)|NIENTE(126)" "$(priv sweetspot-config imposta CONDIVISIONE_3_SMB1 'si;id')|$(priv sweetspot-config imposta CONDIVISIONE_3_SMB1 forse)"
		expect "HTTPS: ammesso dalle pagine" "sweetspot-config|imposta|HTTPS|si|HTTPS_REINDIRIZZA|no" "$(priv sweetspot-config imposta HTTPS si HTTPS_REINDIRIZZA no)"
		expect "RENDERER_UPNP: ammesso dalle pagine (si/no)" "sweetspot-config|imposta|RENDERER_UPNP|si|sweetspot-config|imposta|RENDERER_UPNP|no" \
			"$(priv sweetspot-config imposta RENDERER_UPNP si)|$(priv sweetspot-config imposta RENDERER_UPNP no)"
		expect "RENDERER_UPNP: solo si/no" "NIENTE(126)|NIENTE(126)" "$(priv sweetspot-config imposta RENDERER_UPNP 'si;id')|$(priv sweetspot-config imposta RENDERER_UPNP forse)"
		expect "RENDERER_UPNP: non e' una chiave protetta (si cambia senza conferma forte)" "sweetspot-config|imposta|RENDERER_UPNP|si|OTTIMIZZAZIONI|si" \
			"$(priv sweetspot-config imposta RENDERER_UPNP si OTTIMIZZAZIONI si)"
		expect "CACHE_COPERTINE: chiavi ammesse dalle pagine" "sweetspot-config|imposta|CACHE_COPERTINE|disco|CACHE_COPERTINE_DISCO|SSD veloce|CACHE_COPERTINE_MB|2048" \
			"$(priv sweetspot-config imposta CACHE_COPERTINE disco CACHE_COPERTINE_DISCO 'SSD veloce' CACHE_COPERTINE_MB 2048)"
		expect "CACHE_COPERTINE: valori con metacaratteri rifiutati" "NIENTE(126)|NIENTE(126)" "$(priv sweetspot-config imposta CACHE_COPERTINE 'ram;id')|$(priv sweetspot-config imposta CACHE_COPERTINE_MB '1;id')"
		expect "SERVER_UPNP: ammesso dalle pagine (si/no)" "sweetspot-config|imposta|SERVER_UPNP|si|sweetspot-config|imposta|SERVER_UPNP|no" 			"$(priv sweetspot-config imposta SERVER_UPNP si)|$(priv sweetspot-config imposta SERVER_UPNP no)"
		expect "SERVER_UPNP: solo si/no" "NIENTE(126)|NIENTE(126)" "$(priv sweetspot-config imposta SERVER_UPNP 'si;id')|$(priv sweetspot-config imposta SERVER_UPNP forse)"
		expect "sweetspot-mediaserver: solo riavvia, senza argomenti" "sweetspot-mediaserver|riavvia|NIENTE(126)|NIENTE(126)" 			"$(priv sweetspot-mediaserver riavvia)|$(priv sweetspot-mediaserver riavvia altro)|$(priv sweetspot-mediaserver conf /etc)"
		expect "sweetspot-https applica ammesso" "sweetspot-https|applica" "$(priv sweetspot-https applica)"
		expect "sweetspot-https httpd non ammesso" "NIENTE(126)" "$(priv sweetspot-https httpd)"
		expect "BLUETOOTH: solo si/no" "sweetspot-config|imposta|BLUETOOTH|si NIENTE(126) NIENTE(126)" "$(priv sweetspot-config imposta BLUETOOTH si) $(priv sweetspot-config imposta BLUETOOTH 'si;id') $(priv sweetspot-config imposta BLUETOOTH forse)"
		expect "BLUETOOTH_NOME: nome semplice" "sweetspot-config|imposta|BLUETOOTH_NOME|Cucina 2" "$(priv sweetspot-config imposta BLUETOOTH_NOME 'Cucina 2')"
		expect "BLUETOOTH_NOME: caratteri di shell e virgolette rifiutati" "NIENTE(126) NIENTE(126) NIENTE(126) NIENTE(126)" "$(priv sweetspot-config imposta BLUETOOTH_NOME 'a;id') $(priv sweetspot-config imposta BLUETOOTH_NOME 'a$(id)') $(priv sweetspot-config imposta BLUETOOTH_NOME 'a"b') $(priv sweetspot-config imposta BLUETOOTH_NOME 'a`id`')"
		expect "BLUETOOTH_NOME: oltre 40 caratteri rifiutato" "NIENTE(126)" "$(priv sweetspot-config imposta BLUETOOTH_NOME "$(printf 'a%.0s' $(seq 1 41))")"
		expect "BLUETOOTH e BLUETOOTH_NOME non sono chiavi protette" "0" "$(grep -c '"BLUETOOTH[A-Z_]*", .[bm]., 1' "$ROOT/package/sweetspot-tools/src/sweetspot-priv.c")"
		expect "sweetspot-bluetooth: sottocomandi ammessi" "sweetspot-bluetooth|abbina|5 sweetspot-bluetooth|applica sweetspot-bluetooth|chiudi sweetspot-bluetooth|elenco sweetspot-bluetooth|rimuovi|AA:BB:CC:DD:EE:01" "$(priv sweetspot-bluetooth abbina 5) $(priv sweetspot-bluetooth applica) $(priv sweetspot-bluetooth chiudi) $(priv sweetspot-bluetooth elenco) $(priv sweetspot-bluetooth rimuovi AA:BB:CC:DD:EE:01)"
		expect "LYRION_PASSWORD: da 10 a 64 caratteri, anche simboli" "sweetspot-config|imposta|LYRION_PASSWORD|Pass:w0rd!#&*|LYRION_UTENTE|sweetspot" \
			"$(priv sweetspot-config imposta LYRION_PASSWORD 'Pass:w0rd!#&*' LYRION_UTENTE sweetspot)"
		expect "LYRION_PASSWORD: corta, lunga, spazio, %, accenti rifiutati" "NIENTE(126) NIENTE(126) NIENTE(126) NIENTE(126) NIENTE(126)" \
			"$(priv sweetspot-config imposta LYRION_PASSWORD corta123) $(priv sweetspot-config imposta LYRION_PASSWORD "$(printf 'a%.0s' $(seq 1 65))") $(priv sweetspot-config imposta LYRION_PASSWORD 'con spazio1') $(priv sweetspot-config imposta LYRION_PASSWORD 'cento%percento') $(priv sweetspot-config imposta LYRION_PASSWORD 'perché12345')"
		expect "LYRION_UTENTE: una parola" "NIENTE(126)" "$(priv sweetspot-config imposta LYRION_UTENTE 'a;id')"
		expect "sweetspot-lms applica: senza argomenti" "sweetspot-lms|applica|NIENTE(126)" "$(priv sweetspot-lms applica)|$(priv sweetspot-lms applica 123)"
		expect "sweetspot-bluetooth: finestra fuori misura, MAC con shell e comandi interni rifiutati" "NIENTE(126) NIENTE(126) NIENTE(126) NIENTE(126) NIENTE(126)" "$(priv sweetspot-bluetooth abbina 99) $(priv sweetspot-bluetooth rimuovi 'AA;id') $(priv sweetspot-bluetooth finestra 5) $(priv sweetspot-bluetooth sorveglia) $(priv sweetspot-bluetooth avvia)"
	fi
fi

echo "Azioni delle pagine con l'helper"
A=$WORK/azioni
mkdir -p "$A/run/web/correzione"
printf 'tokenfinto\n' > "$A/run/web.token"
cat > "$A/priv" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$A/priv.log"
case "\$1 \$2" in
	"sweetspot-dsp leggi") echo "PK 100 -3 Q 2" ;;
	"sweetspot-dsp salva") exit "\${DSP_SAVE_RC:-0}" ;;
	"sweetspot-aggiorna"*) echo "versione=9" ;;
	"sweetspot-accesso hash") echo '\$1\$nuovo\$hash' ;;
esac
exit 0
EOF
chmod +x "$A/priv"
act() { # corpo senza gettone
	local body="t=tokenfinto&$1"
	printf '%s' "$body" | SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$A/run" SWEETSPOT_LOG="$A/log" \
		SWEETSPOT_DEFAULTS="$OVERLAY/etc/sweetspot/defaults.conf" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
		sh "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione"
}
# Le pagine usano "httpd -d" di BusyBox per decodificare i moduli: senza
# BusyBox (sviluppo su altro sistema) un sostituto minimo.
BB=$(command -v busybox || true)
mkdir -p "$A/bin"
if [ -n "$BB" ]; then
	ln -sf "$BB" "$A/bin/httpd"
else
	printf '#!/bin/bash\n[ "$1" = -d ] || exit 1\nv=$(printf "%%s" "$2" | sed "s/+/ /g; s/%%\\(..\\)/\\\\\\\\x\\1/g")\nprintf "%%b" "$v"\n' > "$A/bin/httpd"
	chmod +x "$A/bin/httpd"
fi
PATH=$A/bin:$PATH
export PATH
: > "$A/priv.log"
act "a=riavvia" > /dev/null
expect "riavvia: lo fa root, in sottofondo" "@riavvia" "$(cat "$A/priv.log")"
: > "$A/priv.log"
act "a=spegni" > /dev/null
expect "spegni: lo fa root, in sottofondo" "@spegni" "$(cat "$A/priv.log")"
: > "$A/priv.log"
act "a=ripristina&conferma=si" > /dev/null
expect "ripristino: config e accesso passano dall'helper" "sweetspot-config ripristina|sweetspot-accesso applica|@riavvia" "$(tr '\n' '|' < "$A/priv.log" | sed 's/|$//')"
: > "$A/priv.log"
act "a=aggiungi_condivisione&server=192.168.1.5&cartella=Musica&utente=&password=" > /dev/null
expect "condivisione: provata dall'helper" "1" "$(grep -c '^sweetspot-rete prova 1$' "$A/priv.log")"
: > "$A/priv.log"
act "a=audio&volume=fisso&dsd=auto&altri_dac=no&dac=auto&ricampionamento=no&filtro=lineare&frequenza_max=0&buffer=400&periodi=4&pausa_frequenza=0&pausa_dsd=500" > /dev/null
expect "audio: salva con l'helper e riavvia il player" "1|1" "$(grep -c '^sweetspot-config imposta VOLUME fisso DSD auto' "$A/priv.log")|$(grep -c '^@player$' "$A/priv.log")"
: > "$A/priv.log"
act "a=correzione_salva&modo=si&sinistro=Filter+1%3A+ON+PK+Fc+100+Hz+Gain+-3+dB+Q+2&destro=" > /dev/null
expect "correzione: le bozze stanno nella cartella delle pagine" "si" "$(grep -q "^sweetspot-dsp leggi $A/run/web/correzione/nuovo-sinistro.txt" "$A/priv.log" && echo si || echo no)"
expect "correzione: nessun file nuovo nella cartella di root" "0" "$(ls "$A/run/correzione" 2> /dev/null | wc -l | tr -d ' ')"
: > "$A/priv.log"
out=$(DSP_SAVE_RC=1 act "a=correzione_salva&modo=si&sinistro=Filter+1%3A+ON+PK+Fc+100+Hz+Gain+-3+dB+Q+2&destro=")
expect "filtri non salvati: nessuna modifica della modalita" "0" "$(grep -c '^sweetspot-config imposta CORREZIONE' "$A/priv.log")"
expect "filtri non salvati: il player non si riavvia" "0" "$(grep -c '^@player$' "$A/priv.log")"
expect "filtri non salvati: errore esplicito nella risposta" "1" \
	"$(httpd -d "$(printf '%s' "$out" | sed -n 's/^Location:.*msg=//p' | tr -d '\r')" | grep -c 'Filtri non salvati')"
# Una richiesta senza gettone non arriva all'helper.
: > "$A/priv.log"
printf 't=sbagliato&a=riavvia' | SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$A/run" SWEETSPOT_LOG="$A/log" \
	REQUEST_METHOD=POST CONTENT_LENGTH=21 sh "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione" > /dev/null
expect "senza gettone nessuna operazione privilegiata" "0" "$(wc -c < "$A/priv.log" | tr -d ' ')"
# SSH e la sua password aprono root: la sola sessione non basta.
SISTEMA="a=sistema&nome=Salotto&modalita=completa&profilo=bilanciato&ascolto=si&ottimizzazioni=si"
rm -f "$A/run/sweetspot.conf"
printf 'NOME_PLAYER=Prova\n' > "$A/run/sweetspot.web"
: > "$A/priv.log"
out=$(act "$SISTEMA&ssh=si&ssh_password=nuovapassword1" | tr -d '\r')
expect "SSH senza password del pannello: non si cambia" "0" "$(grep -c 'SSH' "$A/priv.log")"
msg=$(httpd -d "$(printf '%s\n' "$out" | grep '^Location: ' | sed 's/^.*msg=//')")
case "$msg" in *"imposta prima una password"*) ok "SSH senza password del pannello: il messaggio dice cosa fare" ;; *) expect "messaggio" "imposta prima una password" "$msg" ;; esac
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Prova\n' > "$A/run/sweetspot.web"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=nuovapassword1" > /dev/null
expect "SSH con password del pannello ma senza conferma: non si cambia" "0" "$(grep -c 'SSH' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=nuovapassword1&ct=gettone1&conferma_password=segreta" > /dev/null
expect "SSH con conferma: passa dalla conferma forte dell'helper" "1" "$(grep -c '^@conferma gettone1 sweetspot-config imposta SSH si SSH_UTENTE assistenza SSH_PASSWORD nuovapassword1$' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=corta8ch&ct=gcorta&conferma_password=segreta" > /dev/null
expect "password SSH di 8 caratteri dal web: rifiutata" "0" "$(grep -c "SSH_PASSWORD" "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=123456789012&ct=glunga&conferma_password=segreta" > /dev/null
expect "password SSH di 12 caratteri dal web: accettata" "1" "$(grep -c "SSH_PASSWORD 123456789012" "$A/priv.log")"
expect "SSH: le impostazioni normali non portano le chiavi di root" "0" "$(grep '^sweetspot-config imposta NOME_PLAYER' "$A/priv.log" | grep -c 'SSH')"
expect "le altre impostazioni si salvano comunque" "1" "$(grep -c '^sweetspot-config imposta NOME_PLAYER Salotto' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=no&ssh_password=" > /dev/null
expect "senza cambiare SSH non serve alcuna conferma" "0" "$(grep -c '@conferma\|SSH' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=no&ssh_password=&ssh_utente=assistenza&ct=g2&conferma_password=segreta" > /dev/null
expect "cambio dell'utente SSH: conferma forte" "1" "$(grep -c '^@conferma g2 sweetspot-config imposta SSH no SSH_UTENTE assistenza$' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_utente=root%0aSSH%3dsi&ct=g3&conferma_password=segreta" > /dev/null
expect "utente SSH inventato: ignorato, resta assistenza" "1" "$(grep -c '^@conferma g3 sweetspot-config imposta SSH si SSH_UTENTE assistenza$' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=a%0aSSH%3dsi&ct=g4&conferma_password=segreta" > /dev/null
expect "password SSH con a capo: non arriva all'helper" "0" "$(grep -c 'SSH' "$A/priv.log")"
# La password delle pagine: senza la vecchia una sessione rubata non la cambia.
: > "$A/priv.log"
act "$SISTEMA&ssh=no&ssh_password=&web_password=nuovissima123" > /dev/null
expect "cambio password delle pagine senza la vecchia: rifiutato" "0" "$(grep -c 'PASSWORD_WEB' "$A/priv.log")"
: > "$A/priv.log"
act "$SISTEMA&ssh=no&ssh_password=&web_password=nuovissima123&ct=g5&conferma_password=segreta" > /dev/null
expect "cambio password delle pagine con la vecchia: conferma forte" "1" "$(grep -c '^@conferma g5 sweetspot-config imposta PASSWORD_WEB \$1\$nuovo\$hash$' "$A/priv.log")"
expect "la password delle pagine non va con le impostazioni normali" "0" "$(grep '^sweetspot-config imposta NOME_PLAYER' "$A/priv.log" | grep -c 'PASSWORD_WEB')"
: > "$A/priv.log"
act "$SISTEMA&ssh=si&ssh_password=nuovapassword1&web_password=nuovissima123&ct=g6&conferma_password=segreta" > /dev/null
expect "SSH e password delle pagine insieme: una sola conferma" "1|1" "$(grep -c '@conferma' "$A/priv.log")|$(grep -c '^@conferma g6 sweetspot-config imposta SSH si SSH_UTENTE assistenza SSH_PASSWORD nuovapassword1 PASSWORD_WEB \$1\$nuovo\$hash$' "$A/priv.log")"
# Un pacchetto dal disco, anche firmato ma vecchio, sostituisce il sistema.
: > "$A/priv.log"
act "a=aggiorna_file&file=%2Fmedia%2FUSB%2Fpacchetto.tar" > /dev/null
expect "pacchetto dal disco senza conferma: non parte" "0" "$(grep -c 'sweetspot-aggiorna' "$A/priv.log")"
: > "$A/priv.log"
act "a=aggiorna_file&file=%2Fmedia%2FUSB%2Fpacchetto.tar&ct=g7&conferma_password=segreta" > /dev/null
expect "pacchetto dal disco con conferma: conferma forte" "1" "$(grep -c '^@conferma g7 sweetspot-aggiorna file /media/USB/pacchetto.tar$' "$A/priv.log")"
# Installazione: cancella un disco, la sola sessione e la casella non bastano.
: > "$A/priv.log"
act "a=installa&disco=sda&conferma=si&dimensione=465" > /dev/null
expect "installazione senza password del pannello riscritta: niente" "0" "$(grep -c 'installa' "$A/priv.log")"
: > "$A/priv.log"
act "a=installa&disco=sda&conferma=si&ct=g5&conferma_password=segreta" > /dev/null
expect "installazione senza dimensione scritta: niente" "0" "$(grep -c 'installa' "$A/priv.log")"
: > "$A/priv.log"
act "a=installa&disco=sda&conferma=si&archivio=si&dimensione=465&ct=g6&conferma_password=segreta" > /dev/null
expect "installazione: passa dalla conferma forte con la dimensione" "1" "$(grep -c '^@conferma g6 sweetspot-installa avvia sda si 465$' "$A/priv.log")"
# Accanto al sistema esistente: stessa conferma forte.
: > "$A/priv.log"
act "a=affianca&disco=nvme0n1&dimensione=476" > /dev/null
expect "installazione accanto senza casella ne' password: niente" "0" "$(grep -c 'installa' "$A/priv.log")"
: > "$A/priv.log"
act "a=affianca&disco=nvme0n1&conferma=si&ct=g5&conferma_password=segreta" > /dev/null
expect "installazione accanto senza dimensione scritta: niente" "0" "$(grep -c 'installa' "$A/priv.log")"
: > "$A/priv.log"
act "a=affianca&disco=nvme0n1&conferma=si&dimensione=476&ct=g6&conferma_password=segreta" > /dev/null
expect "installazione accanto: passa dalla conferma forte" "1" "$(grep -c '^@conferma g6 sweetspot-installa affianca nvme0n1 476$' "$A/priv.log")"

# Con l'helper le pagine leggono la copia senza password.
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Visibile\n' > "$A/run/sweetspot.web"
printf 'PASSWORD_WEB=$1$vero$hash\nNOME_PLAYER=Visibile\n' > "$A/run/sweetspot.conf"
expect "le pagine non vedono l'impronta" "*" "$(SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$A/run" sh -c ". $OVERLAY/usr/lib/sweetspot/web.sh; conf PASSWORD_WEB")"
expect "senza helper (test) vale la configurazione completa" '$1$vero$hash' "$(SWEETSPOT_PRIV=/nonexistent SWEETSPOT_RUN="$A/run" sh -c ". $OVERLAY/usr/lib/sweetspot/web.sh; conf PASSWORD_WEB")"

echo
echo "Privilegi - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
