#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Limite di connessioni SSH contemporanee per indirizzo (sweetspot-ssh-conn).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV=$ROOT/board/sweetspot/rootfs-overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf "#!/bin/sh
while [ ! -e %s/via ]; do sleep 0.2; done
" "$T" > "$T/bin/dropbear"; chmod +x "$T/bin/dropbear"
i=0
while [ $i -lt 20 ]; do
	( TCPREMOTEIP=10.0.0.7 SWEETSPOT_SSH_STATE=$T/st SWEETSPOT_SSH_ATTESA=0 SWEETSPOT_SSH_MAX=4 PATH=$T/bin:$PATH \
		sh "$OV/usr/bin/sweetspot-ssh-conn" > /dev/null 2>&1; echo $? >> "$T/esiti" ) &
	i=$((i + 1))
done
# Le 4 connessioni ammesse restano aperte finche' le altre 16 non sono state rifiutate.
k=0; while [ "$(grep -c '^1$' "$T/esiti" 2> /dev/null)" != 16 ] && [ $k -lt 120 ]; do sleep 0.5; k=$((k + 1)); done
: > "$T/via"
wait
ok=$(grep -c '^0$' "$T/esiti"); no=$(grep -c '^1$' "$T/esiti")
if [ "$ok" = 4 ] && [ "$no" = 16 ]; then echo "PASS ssh: 20 connessioni parallele, 4 passano e 16 rifiutate"
else echo "FAIL ssh: passate=$ok rifiutate=$no (attese 4/16)"; exit 1; fi
# Contatore dei fallimenti: 10 errori paralleli non si perdono.
printf '#!/bin/sh\necho "Bad password attempt" >&2\n' > "$T/bin/dropbear"
rm -rf "$T/st"; i=0
while [ $i -lt 4 ]; do
	( TCPREMOTEIP=10.0.0.8 SWEETSPOT_SSH_STATE=$T/st SWEETSPOT_SSH_ATTESA=0 PATH=$T/bin:$PATH sh "$OV/usr/bin/sweetspot-ssh-conn" >/dev/null 2>&1; echo $? >> "$T/esiti2" ) &
	i=$((i + 1))
done
wait
n=$(cat "$T/st/10.0.0.8")
if [ "$n" = 4 ]; then echo "PASS ssh: errori paralleli contati senza perdite"
else
	# esiti 1 = connessione senza posto; tutti 0 = aggiornamento del contatore perso
	echo "FAIL ssh: contati $n su 4 (esiti: $(sort "$T/esiti2" | tr '\n' ' '); stato: $(ls "$T/st" | tr '\n' ' '))"
	exit 1
fi
# Posti orfani (processi uccisi con SIGKILL): 3 posti con pid inesistente e uno
# senza pid e vecchio devono essere recuperati, e la connessione deve passare.
if [ "$(uname -s)" != Linux ]; then
	echo "SKIP ssh: recupero dei posti orfani (kill -0 e /proc affidabili solo su Linux)"
	exit 0
fi
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dropbear"
rm -rf "$T/st"; mkdir -p "$T/st"
for n in 1 2 3; do mkdir "$T/st/10.0.0.6.posto$n"; echo 999999 > "$T/st/10.0.0.6.posto$n/pid"; done
mkdir "$T/st/10.0.0.6.posto4"; touch -d '1 minute ago' "$T/st/10.0.0.6.posto4"
TCPREMOTEIP=10.0.0.6 SWEETSPOT_SSH_STATE=$T/st SWEETSPOT_SSH_ATTESA=0 SWEETSPOT_SSH_MAX=4 PATH=$T/bin:$PATH sh "$OV/usr/bin/sweetspot-ssh-conn" > /dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && [ -z "$(ls -d "$T"/st/10.0.0.6.posto* 2> /dev/null)" ]; then echo "PASS ssh: posti orfani recuperati"
else echo "FAIL ssh: posti orfani non recuperati (uscita $rc)"; exit 1; fi
