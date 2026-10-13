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
expect "BusyBox con httpd -u" "1" "$(grep -c '^CONFIG_FEATURE_HTTPD_SETUID=y' "$ROOT/board/sweetspot/common/busybox.fragment")"
expect "helper setuid installato (4755)" "1" "$(grep -c 'sweetspot-priv f 4755 0 0' "$ROOT/package/sweetspot-tools/sweetspot-tools.mk")"

echo "Le pagine non chiamano piu' direttamente le operazioni di root"
# Ogni chiamata a uno script privilegiato, nelle pagine, passa da priv.
direct=$(grep -nE '(^|[^a-z-])sweetspot-(config|lms|rete|dischi|nas|copia|cd|spazio|aggiorna|installa|dsp|accesso|check|hotspot)( |$|\))' \
	"$OVERLAY"/usr/share/sweetspot/www/cgi-bin/* | grep -v 'priv sweetspot-' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v '[<>]' || true)
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
	for s in config lms rete dischi nas copia cd spazio aggiorna installa dsp accesso check rapporto hotspot; do
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
		expect "config chiave minuscola non ammessa" "NIENTE(126)" "$(priv sweetspot-config imposta volume fisso)"
		expect "config valore vuoto ammesso" "sweetspot-config|imposta|DNS|" "$(priv sweetspot-config imposta DNS '')"
		expect "config condivisione 3 con utente e password" "sweetspot-config|imposta|CONDIVISIONE_3_UTENTE|u|CONDIVISIONE_3_PASSWORD|p" \
			"$(priv sweetspot-config imposta CONDIVISIONE_3_UTENTE u CONDIVISIONE_3_PASSWORD p)"
		expect "config condivisione 0 rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta CONDIVISIONE_0 x)"
		expect "config condivisione 10 rifiutata" "NIENTE(126)" "$(priv sweetspot-config imposta CONDIVISIONE_10 x)"
		expect "config chiave fuori elenco (LYRION_PASSWORD)" "NIENTE(126)" "$(priv sweetspot-config imposta LYRION_PASSWORD x)"
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
		expect "installa avvia ammesso" "sweetspot-installa|avvia|sda|si" "$(priv sweetspot-installa avvia sda si)"
		expect "hotspot richiesta ammessa" "sweetspot-hotspot|richiesta" "$(priv sweetspot-hotspot richiesta)"
		expect "hotspot scansiona ammessa" "sweetspot-hotspot|scansiona" "$(priv sweetspot-hotspot scansiona)"
		expect "hotspot sorveglia non ammessa" "NIENTE(126)" "$(priv sweetspot-hotspot sorveglia)"
		expect "carattere di controllo rifiutato" "NIENTE(126)" "$(priv sweetspot-copia avvia "$(printf 'a\001b')")"
		expect "argomento troppo lungo rifiutato" "NIENTE(126)" "$(priv sweetspot-copia avvia "$(head -c 2000 /dev/zero | tr '\0' a)")"
		expect "nessun argomento" "NIENTE(126)" "$(priv)"
		expect "azione interna sconosciuta" "NIENTE(126)" "$(priv @shell)"
		expect "sweetspot-rapporto senza argomenti" "sweetspot-rapporto" "$(priv sweetspot-rapporto)"
		expect "sweetspot-rapporto con argomenti" "NIENTE(126)" "$(priv sweetspot-rapporto salva)"
		# Lyrion: solo i comandi usati dalle pagine.
		expect "lms plugin installa" "sweetspot-lms|plugin|installa|Qobuz" "$(priv sweetspot-lms plugin installa Qobuz)"
		expect "lms plugin con nome strano" "NIENTE(126)" "$(priv sweetspot-lms plugin installa '../x')"
		expect "lms plugin sconosciuto" "NIENTE(126)" "$(priv sweetspot-lms plugin cancella Qobuz)"
		expect "lms json stato del server" "sweetspot-lms|json||serverstatus|0|0" "$(priv sweetspot-lms json '' serverstatus 0 0)"
		expect "lms json nome del player" "sweetspot-lms|json|aa:bb:cc:dd:ee:ff|name|Salotto" "$(priv sweetspot-lms json aa:bb:cc:dd:ee:ff name Salotto)"
		expect "lms json brano in ascolto" "sweetspot-lms|json|aa:bb|status|-|1|tags:aloITr" "$(priv sweetspot-lms json aa:bb status - 1 tags:aloITr)"
		expect "lms json anteprima" "sweetspot-lms|json|aa:bb|playlist|preview|url:file:///tmp/p.wav|title:Prova DoP" \
			"$(priv sweetspot-lms json aa:bb playlist preview url:file:///tmp/p.wav 'title:Prova DoP')"
		expect "lms json altro comando (pref)" "NIENTE(126)" "$(priv sweetspot-lms json '' pref authorize 0)"
		expect "lms json restartserver" "NIENTE(126)" "$(priv sweetspot-lms json '' restartserver)"
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
		# L'ambiente non passa agli script.
		printf '#!/bin/sh\nenv > "%s/env"\n' "$WORK" > "$B/sweetspot-check"
		SWEETSPOT_PATH=/evil LD_PRELOAD=/x IFS=x "$WORK/priv" sweetspot-check --dati > /dev/null 2>&1
		expect "ambiente ripulito" "PATH=/usr/sbin:/usr/bin:/sbin:/bin" "$(grep -E '^(PATH|SWEETSPOT_PATH|LD_PRELOAD|IFS)=' "$WORK/env" | head -n 1)"
		expect "nessuna variabile ereditata" "0" "$(grep -cE '^(SWEETSPOT_PATH|LD_PRELOAD|IFS)=' "$WORK/env")"
	fi
fi

echo "Azioni delle pagine con l'helper"
A=$WORK/azioni
mkdir -p "$A/run/web/correzione"
printf 'tokenfinto\n' > "$A/run/web.token"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/priv.log"\ncase "$1" in sweetspot-aggiorna) echo "versione=9" ;; esac\nexit 0\n' "$A" > "$A/priv"
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
# Una richiesta senza gettone non arriva all'helper.
: > "$A/priv.log"
printf 't=sbagliato&a=riavvia' | SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$A/run" SWEETSPOT_LOG="$A/log" \
	REQUEST_METHOD=POST CONTENT_LENGTH=21 sh "$OVERLAY/usr/share/sweetspot/www/cgi-bin/azione" > /dev/null
expect "senza gettone nessuna operazione privilegiata" "0" "$(wc -c < "$A/priv.log" | tr -d ' ')"
# Con l'helper le pagine leggono la copia senza password.
printf 'PASSWORD_WEB=*\nNOME_PLAYER=Visibile\n' > "$A/run/sweetspot.web"
printf 'PASSWORD_WEB=$1$vero$hash\nNOME_PLAYER=Visibile\n' > "$A/run/sweetspot.conf"
expect "le pagine non vedono l'impronta" "*" "$(SWEETSPOT_PRIV="$A/priv" SWEETSPOT_RUN="$A/run" sh -c ". $OVERLAY/usr/lib/sweetspot/web.sh; conf PASSWORD_WEB")"
expect "senza helper (test) vale la configurazione completa" '$1$vero$hash' "$(SWEETSPOT_PRIV=/nonexistent SWEETSPOT_RUN="$A/run" sh -c ". $OVERLAY/usr/lib/sweetspot/web.sh; conf PASSWORD_WEB")"

echo
echo "Privilegi - superati: $PASS  Falliti: $FAIL"
[ "$FAIL" -eq 0 ]
