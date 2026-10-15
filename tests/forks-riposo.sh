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

# Solo la classifica: sh forks-riposo.sh --dettaglio [secondi]
if [ "$1" = --dettaglio ]; then
	echo "Classifica dei processi nati in ${2:-10} s (padre > comando: numero):"
	dettaglio "${2:-10}"
	exit 0
fi

# FORKS_PRIMA=N: durante i primi N secondi dell'attesa classifica i processi
# nati (come --dettaglio) e li stampa solo se la soglia e' superata: mostra
# le raffiche dell'assestamento che la misura successiva conta.
PRIMA=
ATT=${FORKS_ATTESA:-20}
if [ "${FORKS_PRIMA:-0}" -gt 0 ]; then
	PRIMA=$(dettaglio "$FORKS_PRIMA")
	ATT=$((ATT - FORKS_PRIMA))
fi
[ "$ATT" -le 0 ] || sleep "$ATT"
# Conta i fork con la sola shell (FKV): la serie a passi di 5 s non costa awk.
forks_v() {
	local k v r
	while read -r k v r; do
		[ "$k" = processes ] && { FKV=$v; return 0; }
	done < "$PROC/stat"
}
a=$(forks)
serie=
passi=0
resto=$SECONDI
forks_v; prec=$FKV
while [ "$resto" -gt 0 ]; do
	p=5; [ "$resto" -ge 5 ] || p=$resto
	sleep "$p"
	resto=$((resto - p)); passi=$((passi + 1))
	forks_v; serie="$serie $((FKV - prec))"; prec=$FKV
done
b=$(forks)
# awk, sleep e la sostituzione dei comandi di questo script: 4-5 fork propri,
# piu' uno sleep per ogni passo della serie oltre il primo.
propri=$(( ${FORKS_PROPRI:-5} + passi - 1 ))
tot=$((b - a - propri))
[ "$tot" -ge 0 ] || tot=0
al_minuto=$((tot * 60 / SECONDI))
echo "fork in ${SECONDI}s: $tot (al minuto: $al_minuto, massimo $MASSIMO)"
if [ "$al_minuto" -ge "$MASSIMO" ]; then
	echo "Fork ogni 5 s:$serie"
	if [ -n "$PRIMA" ]; then
		echo "Classifica dei primi ${FORKS_PRIMA} s (padre > comando: numero):"
		echo "$PRIMA"
	fi
	echo "Troppi fork. Classifica dei processi nati in ${FORKS_DETTAGLIO:-30} s (padre > comando: numero):"
	dettaglio "${FORKS_DETTAGLIO:-30}"
	exit 1
fi
