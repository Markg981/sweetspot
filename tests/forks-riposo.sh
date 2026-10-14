#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - conta i fork al minuto del sistema a riposo.
# Il kernel conta ogni processo creato dall'avvio nella riga "processes" di
# /proc/stat (fork e clone): la differenza su N secondi, meno quelli di questo
# stesso script, e' il lavoro dei servizi. Va eseguito sul player (o nella VM
# di prova-robustezza-qemu.sh) quando non si sta ascoltando e nessuno guarda
# le pagine web.
#
#   sh forks-riposo.sh [secondi] [massimo_al_minuto]
#
# Stampa i fork al minuto; esce con 1 se superano il massimo (predefinito
# 100). Prima della misura attende 20 s che l'avvio si assesti
# (FORKS_ATTESA=0 per non aspettare).

SECONDI=${1:-60}
MASSIMO=${2:-100}
PROC=${SWEETSPOT_PROCFS:-/proc}

forks() { awk '/^processes / { print $2 }' "$PROC/stat"; }

# Diagnosi (solo se la soglia e' superata): per FORKS_DETTAGLIO secondi legge
# /proc ogni 0,1 s e raggruppa i processi visti per "padre > comando".
dettaglio() {
	local fine
	fine=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt "$fine" ]; do
		for d in /proc/[0-9]*; do
			read -r l < "$d/stat" 2>/dev/null && echo "$l"
		done
		usleep 100000
	done | awk '
		{ pid = $1; s = $0
		  c = s; sub(/^[^(]*\(/, "", c); sub(/\).*$/, "", c)
		  r = s; sub(/^.*\) /, "", r); split(r, f, " ")
		  comm[pid] = c; ppid[pid] = f[2]; start[pid] = f[20] }
		END { for (p in comm) if (start[p] > 0) n[comm[ppid[p]] " > " comm[p]]++
		      for (k in n) printf "%6d %s\n", n[k], k }' | sort -rn | head -n 15
}

sleep "${FORKS_ATTESA:-20}"
a=$(forks)
sleep "$SECONDI"
b=$(forks)
# awk, sleep e la sostituzione dei comandi di questo script: 4-5 fork propri.
propri=${FORKS_PROPRI:-5}
tot=$((b - a - propri))
[ "$tot" -ge 0 ] || tot=0
al_minuto=$((tot * 60 / SECONDI))
echo "fork in ${SECONDI}s: $tot (al minuto: $al_minuto, massimo $MASSIMO)"
if [ "$al_minuto" -ge "$MASSIMO" ]; then
	echo "Troppi fork. Chi li fa (processi visti in ${FORKS_DETTAGLIO:-30} s, per padre > comando):"
	dettaglio "${FORKS_DETTAGLIO:-30}"
	exit 1
fi
