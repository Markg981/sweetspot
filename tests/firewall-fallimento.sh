#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - se nft non carica le regole il firewall dell'hotspot fallisce
# chiuso (drop sulla scheda dell'AP, o scheda spenta), mai aperto.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV=$ROOT/board/sweetspot/rootfs-overlay
FW=$OV/usr/bin/sweetspot-firewall
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/run" "$W/bin"
FAIL=0
ok() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  NO  $1 (atteso $2, ottenuto $3)"; FAIL=1; fi; }
echo "== firewall: fallimento di nft = chiuso"

# 1) nft rifiuta il file completo ma accetta il fallback minimo.
cat > "$W/nft" <<EOF
#!/bin/sh
[ "\$1" = -f ] || exit 0
# il file completo comincia con define AP_IF, il fallback no
grep -q 'define AP_IF' "\$2" && exit 1
cp "\$2" "$W/fallback.nft"
EOF
chmod +x "$W/nft"
SWEETSPOT_LIB=$OV/usr/lib/sweetspot SWEETSPOT_NFT=$W/nft SWEETSPOT_RUN=$W/run SWEETSPOT_LOG=$W/log \
	sh "$FW" applica wlan0 2>/dev/null
rc=$?
ok "esito 1" 1 "$rc"
ok "errore nel registro" 1 "$(grep -c 'firewall: regole non caricate' "$W/log" 2>/dev/null)"
ok "fallback: drop su wlan0" 1 "$(grep -c 'iifname "wlan0" drop' "$W/fallback.nft" 2>/dev/null)"

# 2) nft fallisce sempre: la scheda viene abbassata.
printf '#!/bin/sh\nexit 1\n' > "$W/nft"
printf '#!/bin/sh\necho "$*" >> "%s/ip.log"\n' "$W" > "$W/bin/ip"; chmod +x "$W/bin/ip"
# common.sh mette /usr/sbin davanti al PATH: SWEETSPOT_PATH fa usare il finto ip.
SWEETSPOT_PATH=$W/bin SWEETSPOT_LIB=$OV/usr/lib/sweetspot SWEETSPOT_NFT=$W/nft SWEETSPOT_RUN=$W/run SWEETSPOT_LOG=$W/log \
	sh "$FW" applica wlan0 2>/dev/null
ok "esito 1 anche senza fallback" 1 "$?"
ok "scheda abbassata" "link set dev wlan0 down" "$(cat "$W/ip.log" 2>/dev/null)"

# 3) validazione reale delle regole e del fallback, se possibile. nft -c apre
# un socket netlink: come in run.sh si prova diretto, poi in un user+net
# namespace, poi con sudo -n. Dove unshare -rn riesce ma il namespace non ha
# i permessi (AppArmor su Ubuntu recenti) nft risponde "Operation not
# permitted": e' un limite dell'ambiente, non un errore delle regole.
nft_c() { # file -> esito; l'output in $W/nft.out
	nft -c -f "$1" > "$W/nft.out" 2>&1 && return 0
	command -v unshare >/dev/null 2>&1 && unshare -rn nft -c -f "$1" > "$W/nft.out" 2>&1 && return 0
	command -v sudo >/dev/null 2>&1 && sudo -n nft -c -f "$1" > "$W/nft.out" 2>&1 && return 0
	return 1
}
senza_privilegi() { grep -qE 'Operation not permitted|Permission denied|Operation not supported|password is required' "$W/nft.out"; }
if command -v nft >/dev/null 2>&1; then
	{ echo 'define AP_IF = "lo"'; cat "$OV/etc/sweetspot/firewall.nft"; } > "$W/fw.nft"
	for f in fw fallback; do
		nft_c "$W/$f.nft"; rc=$?
		if [ "$rc" -ne 0 ] && senza_privilegi; then
			echo "  --  salto nft -c reale su $f (privilegi insufficienti)"
		else
			[ "$rc" -eq 0 ] || sed 's/^/      /' "$W/nft.out"
			ok "nft -c: $f" 0 "$rc"
		fi
	done
else
	echo "  --  salto nft -c reale (nft non disponibile)"
fi
exit $FAIL
