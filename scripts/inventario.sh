#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - integrita' dei sorgenti e inventario dei componenti distribuiti.
#
#   ./scripts/inventario.sh verifica          controlla i file .hash dei pacchetti
#   ./scripts/inventario.sh sbom DIR_OUTPUT   inventario dall'albero di Buildroot gia'
#                                             configurato (DIR_OUTPUT = O= della build)
#
# "verifica" non richiede rete ne' Buildroot: fallisce se un pacchetto propri
# scarica un sorgente senza una riga di hash o se qualcuno ha escluso il
# controllo con BR_NO_CHECK_HASH_FOR.
#
# "sbom" lancia "make legal-info" e "make show-info" di Buildroot e raccoglie
# in DIR_OUTPUT/inventario: manifest.csv (pacchetti e licenze realmente nella
# build) e show-info.json. Non esegue scansioni CVE e non ne stampa risultati:
# per le vulnerabilita' usare "make pkg-stats" con il database NVD (vedi
# docs/supply-chain.md); l'esito dipende dalla data della scansione.

ROOT=$(cd "$(dirname "$0")/.." && pwd)

verifica() {
	local errori=0 mk dir nome hash
	for mk in "$ROOT"/package/*/*.mk; do
		dir=$(dirname "$mk")
		nome=$(basename "$dir")
		hash="$dir/$nome.hash"
		if grep -q 'BR_NO_CHECK_HASH_FOR' "$mk"; then
			echo "KO  $nome: esclude il controllo dell'hash" >&2
			errori=1
		fi
		# Pacchetti senza sorgente scaricato (solo file locali) non hanno hash.
		if ! grep -Eq '^[A-Z0-9_]+_(SITE|SOURCE)[[:space:]]*[:+]?=' "$mk"; then
			continue
		fi
		if grep -Eq '^[A-Z0-9_]+_SITE[[:space:]]*[:+]?=[[:space:]]*(\$\(TOPDIR\)|\$\(BR2_EXTERNAL|file://|\.)' "$mk"; then
			continue
		fi
		if [ ! -s "$hash" ] || ! grep -Eq '^(sha256|sha512)[[:space:]]+[0-9a-f]{64,128}[[:space:]]+' "$hash"; then
			echo "KO  $nome: manca una riga sha256/sha512 in $nome.hash" >&2
			errori=1
		else
			echo "ok  $nome"
		fi
	done
	return $errori
}

sbom() {
	local out="$1"
	[ -n "$out" ] && [ -f "$out/.config" ] || {
		echo "uso: $0 sbom DIR_OUTPUT (con .config di Buildroot)" >&2
		return 2
	}
	local br="${BUILDROOT_DIR:-$ROOT/buildroot}"
	[ -f "$br/Makefile" ] || {
		echo "Buildroot non trovato in $br (impostare BUILDROOT_DIR)" >&2
		return 2
	}
	mkdir -p "$out/inventario" || return 1
	make -C "$br" O="$out" BR2_EXTERNAL="$ROOT" legal-info || return 1
	cp "$out/legal-info/manifest.csv" "$out/inventario/manifest.csv" || return 1
	make -s -C "$br" O="$out" BR2_EXTERNAL="$ROOT" show-info \
		>"$out/inventario/show-info.json" || return 1
	echo "Inventario in $out/inventario"
}

case "$1" in
verifica) verifica ;;
sbom) sbom "$2" ;;
*)
	echo "uso: $0 verifica | sbom DIR_OUTPUT" >&2
	exit 2
	;;
esac
