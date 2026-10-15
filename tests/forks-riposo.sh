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
	local fine u last cur p l c r pp m pc me=$$
	read -r u _ < /proc/uptime
	fine=$(( ${u%%.*} + $1 ))
	: & last=$!
	# I PID si assegnano in sequenza: l'ultimo si ricava da un fork proprio
	# (": &", senza programmi; ns_last_pid richiede CHECKPOINT_RESTORE nel
	# kernel) e ogni PID nuovo si legge subito con soli comandi interni,
	# prima che il processo di breve vita sparisca. I processi gia' spariti
	# si contano come "? > ?"; quelli di questo stesso ciclo non si contano.
	me=
	while :; do
		# Il ciclo e' in una subshell (a sinistra della pipe): "self" e' lei.
		[ -n "$me" ] || read -r me _ < /proc/self/stat
		read -r u _ < /proc/uptime
		[ "${u%%.*}" -lt "$fine" ] || break
		: & cur=$!
			while [ $((last + 1)) -lt "$cur" ]; do
			last=$((last + 1))
			p=$last
			if { read -r l < "$PROC/$p/stat"; } 2>/dev/null; then
				c=${l#*(}; c=${c%)*}
				r=${l##*) }; r=${r#* }; pp=${r%% *}
				[ "$pp" != "$me" ] || continue
				if { read -r m < "$PROC/$pp/stat"; } 2>/dev/null; then pc=${m#*(}; pc=${pc%)*}; else pc='?'; fi
				echo "$pc > $c"
			else
				echo "? > ?"
			fi
			done
			last=$cur
	done | sort | uniq -c | sort -rn | head -n 25 | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "  %s: %d\n", $0, n }'
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
	echo "Troppi fork. Classifica dei processi nati in ${FORKS_DETTAGLIO:-30} s (padre > comando: numero):"
	dettaglio "${FORKS_DETTAGLIO:-30}"
	exit 1
fi
