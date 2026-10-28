#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verifica che le fixture dei test di Squeezelite corrispondano al sorgente vero.

Uso: squeezelite-sorgente-reale.py DIR_SORGENTE   (checkout di squeezelite al
commit pinnato). Controlla che (1) tutte le patch di patches/squeezelite/
si applichino in sequenza al sorgente vero, (2) squeezelite-output-pack.c sia
identica a output_pack.c, (3) le righe di codice di squeezelite-dsd-header.c
compaiano nello stesso ordine in dsd.c, (4) l'estratto di output_alsa.c
differisca dal vero solo per le righe di adattamento note (stubs.h), (5) le
righe dell'estratto di ffmpeg.c compaiano nello stesso ordine nel vero.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "tests/fixtures"
# righe dell'estratto alsa-rate che adattano (non copiano) l'upstream
ADATTATE_ALSA = {'#include "stubs.h"', "\tchar device[64];",
                 "static int open_rate(const char *device, unsigned sample_rate) {",
                 "\tsnd_pcm_hw_params_t *hw_params = NULL;"}


def righe(p):
    return [r.rstrip() for r in Path(p).read_text(encoding="utf-8", errors="replace")
            .replace("\r\n", "\n").split("\n")]


def mancanti(fixture, reale):
    # salta il commento iniziale di intestazione della fixture
    fx, i, out, in_head = righe(fixture), 0, [], True
    rl = righe(reale)
    for r in fx:
        if in_head:
            if r.strip() == "*/" and out == [] and fx.index(r) > 0 and "Exact" in "\n".join(fx[:fx.index(r)]):
                in_head = False
            elif r.startswith("/* Estratto"):
                pass
            if in_head:
                continue
        if not r.strip():
            continue
        try:
            i = rl.index(r, i) + 1
        except ValueError:
            out.append(r)
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    errori = []
    with tempfile.TemporaryDirectory(prefix="sq-reale-") as t:
        work = Path(t) / "src"
        shutil.copytree(src, work, ignore=shutil.ignore_patterns(".git"))
        for patch in sorted((ROOT / "patches/squeezelite").glob("*.patch")):
            r = subprocess.run(["git", "apply", "--check", str(patch)], cwd=work,
                               capture_output=True, text=True)
            if r.returncode == 0:
                subprocess.run(["git", "apply", str(patch)], cwd=work, check=True)
            else:
                errori.append(f"patch non applicabile: {patch.name}: {r.stderr.strip()}")
    if righe(FIX / "squeezelite-output-pack.c") != righe(src / "output_pack.c"):
        errori.append("squeezelite-output-pack.c diversa da output_pack.c vero")
    m = mancanti(FIX / "squeezelite-dsd-header.c", src / "dsd.c")
    if m:
        errori.append("righe di squeezelite-dsd-header.c assenti da dsd.c: %r" % m)
    m = [r for r in mancanti(FIX / "squeezelite-alsa-rate.c", src / "output_alsa.c")
         if r not in ADATTATE_ALSA and not r.startswith(("/*", " *"))]
    if m:
        errori.append("righe di squeezelite-alsa-rate.c assenti da output_alsa.c: %r" % m)
    m = [r for r in mancanti(FIX / "squeezelite-ffmpeg-register.c", src / "ffmpeg.c")
         if r != '#include "stubs.h"' and not r.startswith(("/*", " *"))]
    if m:
        errori.append("righe di squeezelite-ffmpeg-register.c assenti da ffmpeg.c: %r" % m)
    for e in errori:
        print("ERRORE:", e)
    print("fixture e patch coerenti con il sorgente vero" if not errori else "")
    sys.exit(1 if errori else 0)


main()
