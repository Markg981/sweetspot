#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - confronta le versioni dei componenti con le ultime pubblicate.
# Stampa una tabella in Markdown; esce con 1 se qualcosa va aggiornato (2 se
# qualche controllo non e' stato possibile e nulla e' da aggiornare).
#
#   ./scripts/controlla-versioni.sh
#
# Regole: Buildroot, Lyrion, Material, CamillaDSP, firmware del Raspberry Pi,
# azioni di GitHub, server di GitHub e Debian alla versione piu' recente;
# kernel all'ultima versione della serie LTS (longterm) piu' recente, sia
# sul PC sia sul Raspberry Pi; moduli di Lyrion per ARM dall'ultimo commit
# del ramo di slimserver-vendor della versione di Lyrion in uso. Fedora,
# dove si compilano i moduli di Lyrion per ARM, e' solo indicata: deve
# avere la stessa glibc della toolchain di Buildroot, non la piu' recente.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DA_AGGIORNARE=0
IGNOTI=0

riga() { # componente in_uso ultima [nota]
	local stato
	if [ -z "$3" ]; then
		stato="non controllabile"
		IGNOTI=1
	elif [ "$2" = "$3" ]; then
		stato="aggiornato"
	else
		stato="**da aggiornare**"
		DA_AGGIORNARE=1
	fi
	[ -n "${4:-}" ] && stato="$stato ($4)"
	printf '| %s | %s | %s | %s |\n' "$1" "${2:--}" "${3:--}" "$stato"
}

info() { # componente in_uso ultima nota
	printf '| %s | %s | %s | %s |\n' "$1" "${2:--}" "${3:--}" "$4"
}

# Valore di una variabile in un file .mk o defconfig (VAR = valore).
valore() { # file variabile
	sed -n "s/^$2 *[?:]*= *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$1" 2>/dev/null | head -n 1
}

# Tag di un repository GitHub (senza ^{}), uno per riga.
tag() { # proprietario/progetto
	git ls-remote --tags "https://github.com/$1" 2>/dev/null | sed 's#.*refs/tags/##; s#\^{}$##' | sort -u
}

ultima() { # filtro (regex estesa) - legge i tag da stdin
	grep -E "$1" | sort -V | tail -n 1
}

ramo() { # proprietario/progetto ramo -> commit
	git ls-remote "https://github.com/$1" "refs/heads/$2" 2>/dev/null | cut -f1
}

scarica() { curl -fsSL --max-time 30 "$1" 2>/dev/null; }

echo "| Componente | In uso | Ultima | Stato |"
echo "|---|---|---|---|"

# --- Buildroot -------------------------------------------------------------------
br=$(sed -n 's/^BR_VERSION=//p' "$ROOT/scripts/build.sh")
br_new=$(tag buildroot/buildroot | ultima '^20[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$')
[ -n "$br_new" ] || br_new=$(git ls-remote --tags https://gitlab.com/buildroot.org/buildroot.git 2>/dev/null |
	sed 's#.*refs/tags/##; s#\^{}$##' | ultima '^20[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$')
riga "Buildroot" "$br" "$br_new"

# --- Kernel ------------------------------------------------------------------------
rel=$(scarica https://www.kernel.org/releases.json)
lts=$(printf '%s' "$rel" | jq -r '[.releases[] | select(.moniker == "longterm") | .version] | sort_by(split(".") | map(tonumber)) | last' 2>/dev/null)
stable=$(printf '%s' "$rel" | jq -r '.latest_stable.version' 2>/dev/null)
[ "$lts" = null ] && lts=""
[ "$stable" = null ] && stable=""
pc=$(valore "$ROOT/configs/sweetspot_x86_64_defconfig" BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)
riga "Kernel del PC (LTS)" "$pc" "$lts"
[ -n "$stable" ] && info "Kernel stabile (non LTS)" "-" "$stable" "solo indicazione: si usa la serie LTS"

# Kernel del Raspberry Pi: ramo rpi-<serie LTS>.y della Raspberry Pi Foundation.
rpi_def=$ROOT/configs/sweetspot_rpi_defconfig
rpi_sha=$(sed -n 's#.*raspberrypi,linux,\([0-9a-f]\{40\}\).*#\1#p' "$rpi_def" | head -n 1)
[ -n "$rpi_sha" ] || rpi_sha=$(valore "$rpi_def" BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION)
rpi_ramo=$(sed -n 's/^# Ramo del kernel: *//p' "$rpi_def")
if [ -n "$lts" ]; then
	want="rpi-$(echo "$lts" | cut -d. -f1-2).y"
	if [ -n "$rpi_ramo" ] && [ "$rpi_ramo" != "$want" ] && [ -n "$(ramo raspberrypi/linux "$want")" ]; then
		riga "Kernel del Raspberry Pi (ramo)" "$rpi_ramo" "$want"
	fi
fi
if [ -n "$rpi_ramo" ]; then
	head=$(ramo raspberrypi/linux "$rpi_ramo")
	riga "Kernel del Raspberry Pi ($rpi_ramo)" "$(echo "$rpi_sha" | cut -c1-12)" "$(echo "$head" | cut -c1-12)"
else
	riga "Kernel del Raspberry Pi" "$(echo "$rpi_sha" | cut -c1-12)" "" "ramo non indicato nel defconfig"
fi

# Firmware del Raspberry Pi (start4.elf e fixup4.dat del Pi 4).
fw_mk=$ROOT/package/sweetspot-rpi-firmware/sweetspot-rpi-firmware.mk
if [ -f "$fw_mk" ]; then
	fw=$(valore "$fw_mk" SWEETSPOT_RPI_FIRMWARE_VERSION)
	fw_new=$(tag raspberrypi/firmware | ultima '^1\.[0-9]{8}$')
	riga "Firmware del Raspberry Pi" "$fw" "$fw_new"
fi

# --- Lyrion e plugin ------------------------------------------------------------
lms=$(valore "$ROOT/package/lms/lms.mk" LMS_VERSION)
riga "Lyrion Music Server" "$lms" "$(tag LMS-Community/slimserver | ultima '^[0-9]+\.[0-9]+\.[0-9]+$')"
vend=$(sed -n 's/^ *VENDOR_REF: *//p' "$ROOT/.github/workflows/moduli-lyrion.yml")
vend_ramo="public/$(echo "$lms" | cut -d. -f1-2)"
vend_new=$(ramo LMS-Community/slimserver-vendor "$vend_ramo")
riga "Moduli di Lyrion per ARM ($vend_ramo)" "$(echo "$vend" | cut -c1-12)" "$(echo "$vend_new" | cut -c1-12)" \
	"un aggiornamento richiede una nuova release dipendenze-lyrion"
mat=$(valore "$ROOT/package/lms-material/lms-material.mk" LMS_MATERIAL_VERSION)
riga "Material Skin" "$mat" "$(tag CDrummond/lms-material | ultima '^[0-9]+\.[0-9]+\.[0-9]+$')"

# --- Correzione ambientale ----------------------------------------------------------
cdsp=$(valore "$ROOT/package/camilladsp/camilladsp.mk" CAMILLADSP_VERSION)
riga "CamillaDSP" "$cdsp" "$(tag HEnquist/camilladsp | ultima '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//')"
acd=$(valore "$ROOT/package/alsa-cdsp/alsa-cdsp.mk" ALSA_CDSP_VERSION)
acd_new=$(git ls-remote https://github.com/scripple/alsa_cdsp HEAD 2>/dev/null | cut -f1)
riga "alsa_cdsp" "$(echo "$acd" | cut -c1-12)" "$(echo "$acd_new" | cut -c1-12)"

# --- Fedora per i moduli di Lyrion (solo indicazione) ----------------------------------
fed=$(sed -n "s/^ *FEDORA: *'\{0,1\}\([0-9]*\)'\{0,1\}.*/\1/p" "$ROOT/.github/workflows/moduli-lyrion.yml")
fed_new=$(scarica https://fedoraproject.org/releases.json |
	jq -r '[.[] | select(.variant == "Server" or .variant == "Everything") | .version | select(test("^[0-9]+$")) | tonumber] | max' 2>/dev/null)
[ "$fed_new" = null ] && fed_new=""
info "Fedora (moduli di Lyrion per ARM)" "$fed" "${fed_new:-?}" "solo indicazione: serve la stessa glibc della toolchain di Buildroot"

# --- Server e azioni di GitHub -----------------------------------------------------------
img=$(mktemp -d)
if git -C "$img" init -q 2>/dev/null &&
	git -C "$img" fetch -q --depth=1 --filter=blob:none https://github.com/actions/runner-images HEAD 2>/dev/null; then
	ubu=$(git -C "$img" ls-tree --name-only FETCH_HEAD images/ubuntu/ |
		sed -n 's#images/ubuntu/Ubuntu\([0-9][0-9]\)\([0-9][0-9]\)-Readme.md#\1.\2#p' | sort -V | tail -n 1)
fi
rm -rf "$img"
usati=$(grep -ho 'ubuntu-[0-9][0-9]\.[0-9][0-9]' "$ROOT"/.github/workflows/*.yml | sort -u -V | tr '\n' ' ' | sed 's/ $//')
riga "Server di GitHub (Ubuntu, anche -arm)" "$usati" "${ubu:+ubuntu-$ubu}"
for a in $(grep -ho 'uses: *[A-Za-z0-9_.-]*/[A-Za-z0-9_./-]*@v[0-9]*' "$ROOT"/.github/workflows/*.yml | sed 's/uses: *//' | sort -u); do
	repo=$(echo "${a%@*}" | cut -d/ -f1-2)
	have=${a##*@}
	new=$(tag "$repo" | ultima '^v[0-9]+$')
	[ -n "$new" ] || new=v$(tag "$repo" | ultima '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | cut -d. -f1)
	[ "$new" = v ] && new=""
	riga "Azione ${a%@*}" "$have" "$new"
done

# --- Immagine Docker per compilare -------------------------------------------------------
deb=$(sed -n 's/^FROM debian:\([a-z]*\).*/\1/p' "$ROOT/docker/Dockerfile")
deb_new=$(scarica https://deb.debian.org/debian/dists/stable/Release | sed -n 's/^Codename: *//p')
riga "Debian (Docker per compilare)" "$deb" "$deb_new"

if [ $DA_AGGIORNARE -ne 0 ]; then exit 1; fi
if [ $IGNOTI -ne 0 ]; then exit 2; fi
exit 0
