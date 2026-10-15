#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova degli strumenti di collaudo (senza hardware):
# generatore di libreria sintetica, benchmark e collaudo prolungato contro un
# Lyrion finto, piu' il giudizio pass/fail del collaudo sugli eventi.
#   python3 tests/prova-collaudo.py

import argparse
import glob
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

RADICE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(RADICE, "tools")
ESITI = []


def verifica(nome, ok, dettaglio=""):
    ESITI.append(ok)
    print("  %s  %s%s" % ("ok" if ok else "NO", nome, "" if ok else "  [%s]" % dettaglio))


def esegui(*argv):
    return subprocess.run([sys.executable] + list(argv), capture_output=True, text=True, timeout=300)


def carica(nome, file):
    sys.path.insert(0, TOOLS)
    s = importlib.util.spec_from_file_location(nome, os.path.join(TOOLS, file))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


with tempfile.TemporaryDirectory() as w:
    print("Libreria sintetica")
    lib = os.path.join(w, "lib")
    r = esegui(os.path.join(TOOLS, "libreria-sintetica.py"), lib, "--brani", "50", "--dimensione-kb", "64")
    mp3 = sorted(glob.glob(os.path.join(lib, "**", "*.mp3"), recursive=True))
    verifica("50 brani creati", len(mp3) == 50, r.stderr)
    dati = open(mp3[0], "rb").read(2000)
    verifica("tag ID3v2.3 con titolo e copertina", dati[:3] == b"ID3" and b"TIT2" in dati and b"APIC" in dati)
    verifica("file sparso alla dimensione richiesta", os.path.getsize(mp3[0]) == 64 * 1024)
    lib2 = os.path.join(w, "lib2")
    esegui(os.path.join(TOOLS, "libreria-sintetica.py"), lib2, "--brani", "50", "--dimensione-kb", "64")
    mp3b = sorted(glob.glob(os.path.join(lib2, "**", "*.mp3"), recursive=True))
    verifica("stesso seme, stessi file",
             [os.path.relpath(x, lib) for x in mp3] == [os.path.relpath(x, lib2) for x in mp3b]
             and open(mp3[7], "rb").read(500) == open(mp3b[7], "rb").read(500))

    print("Benchmark (Lyrion finto)")
    out = os.path.join(w, "bench.json")
    r = esegui(os.path.join(TOOLS, "benchmark-libreria.py"), "--simula", "--interrogazioni", "10",
               "--brani", "1000", "--json", out)
    verifica("benchmark termina bene", r.returncode == 0, r.stderr[-300:])
    if os.path.exists(out):
        j = json.load(open(out))
        verifica("due profili disco/ram con p50 e p99",
                 [p["profilo"] for p in j["profili"]] == ["disco", "ram"]
                 and all("p99_ms" in p["latenza"]["ricerca"] for p in j["profili"]))
        verifica("profili con dbhighmem 0 e 2", [p["dbhighmem"] for p in j["profili"]] == [0, 2])
        verifica("tempo di indicizzazione completa misurato",
                 all(p["indicizzazione_completa_s"] >= 1 for p in j["profili"]))

    print("Collaudo prolungato (Lyrion finto)")
    out = os.path.join(w, "collaudo.json")
    r = esegui(os.path.join(TOOLS, "collaudo-prolungato.py"), "--simula", "--secondi", "16", "--intervallo", "1",
               "--durata-guasto", "1", "--ram-max-mb", "16", "--json", out)
    verifica("collaudo breve riuscito", r.returncode == 0, r.stdout[-400:] + r.stderr[-300:])
    if os.path.exists(out):
        j = json.load(open(out))
        nomi = {g["nome"] for g in j["guasti_iniettati"]}
        verifica("guasti rete, scansione, navigazione, ram iniettati",
                 nomi >= {"rete", "scansione", "navigazione", "ram"}, nomi)
        verifica("rapporto con tutte le misure",
                 set(j["misure"]) >= {"xrun", "buffer_svuotato", "salti_tempo", "oom"})

    print("Giudizio sulle soglie")
    m = carica("collaudo_prolungato", "collaudo-prolungato.py")
    a = argparse.Namespace(host="127.0.0.1", porta=1, auth=None, player="", seme=1, log_squeezelite=os.devnull,
                           simula=True, soglia_dict={"xrun": 2})
    c = m.Collaudo(a)
    c.evento("xrun", "a")
    c.evento("xrun", "b")
    verifica("2 XRUN con soglia 2: riuscito", c.rapporto(1, 0)["esito"] == "RIUSCITO")
    c.evento("salti_tempo", "scarto 3 s")
    c.evento("restart_servizi", "slimserver.pl")
    rp = c.rapporto(1, 0)
    verifica("salto nel tempo e restart: non riuscito", rp["esito"] == "NON RIUSCITO"
             and not rp["misure"]["salti_tempo"]["ok"] and not rp["misure"]["restart_servizi"]["ok"])
    cm = carica("collaudo_comune", "collaudo_comune.py")
    verifica("percentili", cm.percentile(list(range(1, 101)), 50) == 50
             and cm.percentile(list(range(1, 101)), 99) == 99)

sys.exit(0 if all(ESITI) else 1)
