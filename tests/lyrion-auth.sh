#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Protezione di Lyrion: ensure_auth del vero sweetspot-lms su server.prefs.
# Non c'e' un Lyrion vero: si prova che le preferenze scritte siano quelle che
# Lyrion 9.1.1 legge (authorize, username, password = SHA-1 base64 senza
# riempimento, Slim::Web::HTTP::checkAuthorization) e che le credenziali
# preesistenti non vengano sovrascritte. Il rifiuto HTTP 401/CLI "login" e'
# comportamento del sorgente di Lyrion, non provato qui.
# shellcheck disable=SC2016
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY=$ROOT/board/sweetspot/rootfs-overlay
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok() { printf '  ok  %s\n' "$1"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"
	else FAIL=$((FAIL + 1)); printf '  NO  %s: atteso [%s], ottenuto [%s]\n' "$1" "$2" "$3"; fi
}

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/data/prefs"
cat > "$WORK/bin/sweetspot-config" <<EOF
#!/bin/sh
[ "\$1" = imposta ] || exit 1
shift
while [ \$# -ge 2 ]; do
	grep -v "^\$1=" "$WORK/run/sweetspot.conf" > "$WORK/run/c.nuovo" 2>/dev/null
	printf '%s=%s\n' "\$1" "\$2" >> "$WORK/run/c.nuovo"
	mv "$WORK/run/c.nuovo" "$WORK/run/sweetspot.conf"
	shift 2
done
EOF
chmod +x "$WORK/bin/sweetspot-config"
PREFS=$WORK/data/prefs

avvia() { # esegue ensure_auth come all'avvio
	PATH=$WORK/bin:$PATH SWEETSPOT_TEST=1 SWEETSPOT_LMS_DATA=$WORK/data SWEETSPOT_RUN=$WORK/run \
		SWEETSPOT_LOG=$WORK/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
		SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
		sh -c ". $OVERLAY/usr/bin/sweetspot-lms; ensure_auth"
}
pref() { grep "^$1:" "$PREFS/server.prefs" | tail -n 1 | cut -d: -f2- | tr -d ' '; }
cfg() { grep "^$1=" "$WORK/run/sweetspot.conf" 2>/dev/null | cut -d= -f2-; }
sha() { printf '%s' "$1" | perl -MDigest::SHA=sha1_base64 -e 'print sha1_base64(<STDIN>)'; }

echo "Lyrion aperto: migrazione con password generata"
printf 'language: IT\ncsrfProtectionLevel: 1\n' > "$PREFS/server.prefs"
: > "$WORK/run/sweetspot.conf"
avvia
expect "authorize attivo" 1 "$(pref authorize)"
expect "utente predefinito sweetspot" sweetspot "$(pref username)"
expect "utente salvato per Sweetspot" sweetspot "$(cfg LYRION_UTENTE)"
P=$(cfg LYRION_PASSWORD)
expect "password generata di 36 caratteri" 36 "${#P}"
expect "in Lyrion c'e' l'impronta, non la password" "$(sha "$P")" "$(pref password)"
expect "altre preferenze intatte" IT "$(pref language)"
expect "stato: generata" generata "$(cat "$WORK/run/lyrion-auth.stato")"

echo "Riavvio con credenziali persistite"
H=$(pref password)
avvia
expect "password invariata" "$P" "$(cfg LYRION_PASSWORD)"
expect "impronta invariata" "$H" "$(pref password)"
expect "authorize ancora attivo" 1 "$(pref authorize)"
expect "una sola riga password" 1 "$(grep -c '^password:' "$PREFS/server.prefs")"

echo "Password scelta in sweetspot.txt"
printf 'LYRION_UTENTE=marco\nLYRION_PASSWORD=nuova:pass\n' > "$WORK/run/sweetspot.conf"
avvia
expect "utente scelto" marco "$(pref username)"
expect "impronta della password scelta" "$(sha 'nuova:pass')" "$(pref password)"

echo "Rotazione: password tolta dalla configurazione"
: > "$WORK/run/sweetspot.conf"
avvia
expect "nuova password generata" 36 "$(printf '%s' "$(cfg LYRION_PASSWORD)" | wc -c | tr -d ' ')"
expect "impronta coerente" "$(sha "$(cfg LYRION_PASSWORD)")" "$(pref password)"

echo "Credenziali Lyrion preesistenti"
rm -f "$PREFS/sweetspot-auth.hash"
printf 'language: IT\nauthorize: 1\nusername: giovanni\npassword: AbCdEfGhIjKl\n' > "$PREFS/server.prefs"
: > "$WORK/run/sweetspot.conf"
avvia
expect "utente conservato" giovanni "$(pref username)"
expect "impronta conservata" AbCdEfGhIjKl "$(pref password)"
expect "nessuna password inventata" "" "$(cfg LYRION_PASSWORD)"
expect "stato: preesistente" preesistente "$(cat "$WORK/run/lyrion-auth.stato")"
avvia
expect "conservate anche al secondo avvio" AbCdEfGhIjKl "$(pref password)"

echo "Credenziali preesistenti dichiarate in sweetspot.txt"
printf 'LYRION_UTENTE=giovanni\nLYRION_PASSWORD=la-sua\n' > "$WORK/run/sweetspot.conf"
avvia
expect "allineate a sweetspot.txt" "$(sha 'la-sua')" "$(pref password)"
expect "dichiarato nel diario" 1 "$(grep -c 'al posto di quelle precedenti' "$WORK/log")"
expect "il diario non contiene la password" 0 "$(grep -c 'la-sua' "$WORK/log")"

echo "Fail-closed: se la protezione non e' applicabile, Lyrion non parte"
mkdir -p "$WORK/senzaperl"
printf '#!/bin/sh\nexit 1\n' > "$WORK/senzaperl/perl"
chmod +x "$WORK/senzaperl/perl"
printf 'language: IT\n' > "$PREFS/server.prefs"
: > "$WORK/run/sweetspot.conf"
rm -f "$WORK/data/prefs/sweetspot-auth.hash"
PATH=$WORK/senzaperl:$WORK/bin:$PATH SWEETSPOT_PATH=$WORK/senzaperl SWEETSPOT_TEST=1 SWEETSPOT_LMS_DATA=$WORK/data SWEETSPOT_RUN=$WORK/run \
	SWEETSPOT_LOG=$WORK/log SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot \
	SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf \
	sh -c ". $OVERLAY/usr/bin/sweetspot-lms; ensure_auth"
expect "ensure_auth fallisce senza impronta" 1 "$?"
expect "nessuna autorizzazione scritta" "" "$(pref authorize)"
lancia() { # lancia: comando completo con l'ambiente del test, senza perl
	(
		export PATH="$EXTRA$WORK/senzaperl:$WORK/bin:$PATH" SWEETSPOT_PATH=$WORK/senzaperl \
			SWEETSPOT_LMS_DATA=$WORK/data SWEETSPOT_RUN=$WORK/run SWEETSPOT_LOG=$WORK/log \
			SWEETSPOT_LIB=$OVERLAY/usr/lib/sweetspot SWEETSPOT_DEFAULTS=$OVERLAY/etc/sweetspot/defaults.conf
		"$@"
	) > "$WORK/out" 2>&1
}
EXTRA=
rm -f "$WORK/run/lyrion-auth.stato"
lancia sh "$OVERLAY/usr/bin/sweetspot-lms" prepara
expect "prepara esce con errore" 1 "$?"
lancia timeout 20 sh "$OVERLAY/usr/bin/sweetspot-lms" servizio
expect "servizio non parte senza protezione" 1 "$?"
expect "il diario lo dichiara" 1 "$(grep -c 'servizio non avviato' "$WORK/log")"
mkdir -p "$WORK/finti"
printf '#!/bin/sh\nexit 1\n' > "$WORK/finti/sweetspot-lms"
printf '#!/bin/sh\necho avviato >> "%s/avvii"\n' "$WORK" > "$WORK/finti/start-stop-daemon"
chmod +x "$WORK/finti/"*
EXTRA=$WORK/finti:
lancia sh "$OVERLAY/etc/init.d/S62sweetspot-lms" start
expect "init: esce con errore se prepara fallisce" 1 "$?"
expect "init: nessun avvio" 0 "$(cat "$WORK/avvii" 2>/dev/null | wc -l | tr -d ' ')"
expect "init: non scrive 'fatto'" 0 "$(grep -c fatto "$WORK/out")"
printf '#!/bin/sh\nexit 0\n' > "$WORK/finti/sweetspot-lms"
lancia sh "$OVERLAY/etc/init.d/S62sweetspot-lms" start
expect "init: ripristinato, parte" 1 "$(grep -c avviato "$WORK/avvii" 2>/dev/null)"

echo
[ "$FAIL" -eq 0 ] && echo "lyrion-auth: tutto ok" || echo "lyrion-auth: $FAIL falliti"
exit "$FAIL"
