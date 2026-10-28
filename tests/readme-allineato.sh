#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - il README non deve contraddire il codice: controlli statici sulle
# promesse piu' facili da far deragliare (comandi documentati, password del
# pannello obbligatoria, SSH descritto una volta, verifica del pacchetto).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV=$ROOT/board/sweetspot/rootfs-overlay
R=$ROOT/README.md
PASS=0
FAIL=0
t() { # descrizione, esito (0 = ok)
	if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "  ok  $1"; else FAIL=$((FAIL + 1)); echo "  NO  $1"; fi
}
has() { grep -q -- "$1" "$2"; }

echo "== README allineato al codice"

# Comandi di sweetspot-dati: tutti quelli dell'intestazione hanno un ramo nel case.
for c in ripristina salva checkpoint sblocca sorveglia; do
	has "^	$c)" "$OV/usr/bin/sweetspot-dati"; t "sweetspot-dati gestisce '$c'" $?
done
has 'ripristina|assente|salva \[--forza\]|checkpoint|sblocca|sorveglia' "$OV/usr/bin/sweetspot-dati"; t "sweetspot-dati: l'uso elenca checkpoint e sblocca" $?

# Il pannello non e' mai "senza login": PASSWORD_WEB e' obbligatoria.
! has 'senza login' "$R"; t "README: nessun pannello 'senza login'" $?
has 'obbligatoria: al primo avvio' "$R"; t "README: PASSWORD_WEB obbligatoria" $?
has 'Primo accesso' "$OV/usr/share/sweetspot/www/cgi-bin/primo-accesso" ||
	has 'primo' "$OV/usr/share/sweetspot/www/cgi-bin/primo-accesso"; t "pagina primo-accesso presente" $?
has 'auth_enabled' "$OV/usr/lib/sweetspot/web.sh"; t "web.sh controlla PASSWORD_WEB" $?

# SSH: una sola riga di tabella nel README, con SSH_UTENTE come nel servizio.
n=$(grep -c '^| `SSH`' "$R")
[ "$n" -eq 1 ]; t "README: SSH descritto in una sola riga ($n)" $?
has 'SSH_UTENTE' "$OV/etc/init.d/S45sweetspot-ssh"; t "S45sweetspot-ssh legge SSH_UTENTE" $?

# Aggiornamenti: elenco del tar prima, manifesto sulla cartella temporanea dopo.
A=$OV/usr/bin/sweetspot-aggiorna
has 'tar -tvf' "$A"; t "aggiorna: ispeziona il tar prima di estrarre" $?
has 'tar -xf "\$archive" -C "\$x"' "$A"; t "aggiorna: estrae in cartella temporanea" $?
has 'non coperto dal manifesto' "$A"; t "aggiorna: copertura del manifesto verificata" $?
has 'cartella temporanea' "$R"; t "README: verifica del manifesto su cartella temporanea" $?

# Ogni chiave di defaults.conf deve comparire nel README. Chiavi interne
# (non destinate all'utente, quindi non documentate) in questa lista esplicita.
INTERNE=""
for k in $(grep -o '^[A-Z][A-Z0-9_]*=' "$OV/etc/sweetspot/defaults.conf" | tr -d '='); do
	case " $INTERNE " in *" $k "*) continue ;; esac
	grep -q "\\b$k\\b" "$R"; t "README documenta la chiave $k di defaults.conf" $?
done

echo "readme-allineato: $PASS ok, $FAIL falliti"
[ "$FAIL" -eq 0 ]
