#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - crea la coppia di chiavi che firma gli aggiornamenti.
#
#   ./scripts/genera-chiave-firma.sh
#
# La chiave pubblica va nel repository (il sistema accetta solo aggiornamenti
# firmati con la chiave privata corrispondente). La chiave privata va SOLO nei
# segreti del repository su GitHub, dove la usa la compilazione ufficiale:
# chi la possiede puo' pubblicare aggiornamenti accettati da ogni Sweetspot.
# Serve minisign (Debian/Ubuntu/WSL: sudo apt install minisign).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PUB=$ROOT/board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub
command -v minisign > /dev/null || { echo "Serve minisign: sudo apt install minisign"; exit 1; }
if [ -f "$PUB" ] && [ "${1:-}" != --sostituisci ]; then
	echo "Esiste gia' una chiave pubblica ($PUB)."
	echo "Per sostituirla: $0 --sostituisci (gli Sweetspot gia' installati"
	echo "accetteranno la nuova chiave solo dopo un aggiornamento firmato con la vecchia)."
	exit 1
fi
d=$(mktemp -d)
chmod 700 "$d"
# Senza password (-W): la usa la compilazione su GitHub, senza nessuno davanti.
minisign -G -W -p "$d/aggiornamenti.pub" -s "$d/aggiornamenti.key" -c "Sweetspot - aggiornamenti ufficiali" > /dev/null
cp "$d/aggiornamenti.pub" "$PUB"
cat <<TESTO

Chiave pubblica scritta in:
  $PUB
  -> fai commit e push (oppure manda la sua seconda riga a chi cura il progetto):
     $(sed -n 2p "$d/aggiornamenti.pub")

Chiave privata: su GitHub, Settings > Secrets and variables > Actions >
New repository secret, nome SWEETSPOT_FIRMA, come valore tutto il testo
tra le righe qui sotto:
----------------------------------------------------------------------
$(cat "$d/aggiornamenti.key")
----------------------------------------------------------------------

Poi cancella la copia locale (o conservala offline, per esempio su una
chiavetta in un cassetto):
  rm -r $d
TESTO
