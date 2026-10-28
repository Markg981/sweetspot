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
grep -q 'chain ingresso { type' "\$2" && { cp "\$2" "$W/fallback.nft"; exit 0; }
exit 1
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
PATH=$W/bin:$PATH SWEETSPOT_LIB=$OV/usr/lib/sweetspot SWEETSPOT_NFT=$W/nft SWEETSPOT_RUN=$W/run SWEETSPOT_LOG=$W/log \
	sh "$FW" applica wlan0 2>/dev/null
ok "esito 1 anche senza fallback" 1 "$?"
ok "scheda abbassata" "link set dev wlan0 down" "$(cat "$W/ip.log" 2>/dev/null)"

# 3) validazione reale delle regole e del fallback, se possibile.
if command -v nft >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
	{ echo 'define AP_IF = "lo"'; cat "$OV/etc/sweetspot/firewall.nft"; } > "$W/fw.nft"
	unshare -rn nft -c -f "$W/fw.nft" >/dev/null 2>&1; ok "nft -c: regole complete" 0 "$?"
	unshare -rn nft -c -f "$W/fallback.nft" >/dev/null 2>&1; ok "nft -c: fallback" 0 "$?"
else
	echo "  --  salto nft -c reale (nft o unshare -rn non disponibili)"
fi
exit $FAIL
