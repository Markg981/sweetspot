# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - attesa del sistema stabile nelle prove in QEMU (da includere
# con ".", dopo aver definito guest() e $W/seriale.log).
#
# Al primo avvio S20sweetspot-tune (sweetspot-autotune --applica) scrive i
# parametri del kernel sulla chiavetta e riavvia UNA volta, ~30-40 s dopo il
# boot. SSH e Lyrion rispondono gia' prima, ma la prova a meta' verrebbe
# interrotta (Connection reset) e snd-aloop caricato prima andrebbe perso.
# Il sistema e' stabile quando l'avvio e' completato (/run/sweetspot/
# avvio-completato) e il riavvio non c'e' piu' da aspettare: o il kernel ha
# gia' ricevuto sweetspot.tune= in /proc/cmdline, oppure l'autotune ha deciso
# di non riavviare (autotune.stato presente e diverso da "riavvio").

# Stampa il boot_id del sistema avviato, vuoto se SSH non risponde.
qemu_boot_id() {
	guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true
}

# qemu_attendi_stabile SECONDI: ritorna 0 a sistema stabile, 1 al timeout.
# Lascia in QEMU_BOOT_ID l'identificativo dell'avvio stabile.
qemu_attendi_stabile() {
	limite=$1
	t=0
	prima=""
	QEMU_BOOT_ID=""
	while [ "$t" -lt "$limite" ]; do
		stato=$(guest '
			[ -f /run/sweetspot/avvio-completato ] || { echo attesa; exit 0; }
			grep -q "sweetspot.tune=" /proc/cmdline && { echo stabile; exit 0; }
			s=$(cat /run/sweetspot/autotune.stato 2>/dev/null)
			if [ -n "$s" ] && [ "$s" != riavvio ]; then echo stabile; exit 0; fi
			echo attesa' 2>/dev/null) || stato=""
		if [ "$stato" = stabile ]; then
			ora=$(qemu_boot_id)
			if [ -z "$ora" ]; then
				prima=""
			elif [ "$ora" = "$prima" ]; then
				# Due letture uguali a distanza: nessun riavvio in corso.
				QEMU_BOOT_ID=$ora
				echo "Sistema stabile dopo circa $t secondi (boot_id $ora)"
				return 0
			else
				prima=$ora
			fi
		else
			prima=""
		fi
		sleep 5
		t=$((t + 5))
	done
	echo "Il sistema non e' stabile dopo $limite secondi (riavvio del primo avvio non avvenuto o SSH non torna). Console:"
	tail -n 60 "$W/seriale.log" 2>/dev/null || true
	return 1
}
