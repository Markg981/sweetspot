#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - benchmark riproducibile di Lyrion con una grande libreria.
#   python3 tools/libreria-sintetica.py /musica/sintetica --brani 100000
#   python3 tools/benchmark-libreria.py [--profilo disco|ram|entrambi]
#           [--brani 100000] [--interrogazioni 200] [--json rapporto.json]
# Misura, per ogni profilo di database:
#   - tempo di indicizzazione completa (wipecache) e incrementale (rescan
#     dopo aver aggiunto l'1% di brani, se --aggiungi-comando e' dato);
#   - latenza p50/p99 di ricerca, elenco album/artisti e copertine;
#   - RAM (RSS) di Lyrion a riposo e il picco durante la scansione.
# Profili: "disco" = database SQLite sul disco (pref dbhighmem 0, il
# predefinito di Lyrion; con la cache su SSD/chiavetta), "ram" = database
# tenuto in memoria (dbhighmem 2). Sweetspot non lo imposta da solo (vedi
# docs/collaudo.md): qui si cambia la pref via JSON-RPC e si riavvia Lyrion
# con --riavvia-comando se serve che abbia effetto.
# Con --simula usa un Lyrion finto (per la CI): i numeri non hanno valore.

import argparse
import json
import os
import random
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collaudo_comune  # noqa: E402
from collaudo_comune import Lms, LyrionFinto, percentile, pids, rss_kb, timed  # noqa: E402

PROFILI = {"disco": 0, "ram": 2}
PAROLE = ["brano", "album", "artista", "000", "12", "love", "blues", "no"]

DESCRIZIONE = "Strumento Sweetspot di collaudo (vedi il commento in testa al file e docs/collaudo.md)"


def run_cmd(c):
    """Comando shell, sul player se c'e' --ssh."""
    if collaudo_comune.SIS.ssh:
        collaudo_comune.SIS.run(["sh", "-c", c], timeout=3600)
    else:
        subprocess.run(c, shell=True, check=False)


def attendi_scansione(lms, massimo, picco):
    """Attende la fine della scansione; ritorna i secondi, aggiorna il picco RSS."""
    t = time.monotonic()
    time.sleep(1)
    while time.monotonic() - t < massimo:
        for p in pids("slimserver.pl") + pids("scanner.pl"):
            r = rss_kb(p)
            if r:
                picco[0] = max(picco[0], r)
        if not lms.rpc("", "serverstatus", 0, 1).get("rescan"):
            return time.monotonic() - t
        time.sleep(1)
    return None


def latenze(lms, n, rnd):
    voci = {"ricerca": [], "album": [], "artisti": [], "copertina": []}
    for _ in range(n):
        d, ok = timed(lms.rpc, "", "search", 0, 50, "term:" + rnd.choice(PAROLE))
        voci["ricerca"].append(d) if ok else None
        d, ok = timed(lms.rpc, "", "albums", rnd.randrange(0, 2000), 50, "tags:ljta", "sort:album")
        voci["album"].append(d) if ok else None
        d, ok = timed(lms.rpc, "", "artists", rnd.randrange(0, 500), 50)
        voci["artisti"].append(d) if ok else None
        d, ok = timed(lms.get, "/music/%d/cover_100x100_o" % rnd.randrange(1, 5000))
        voci["copertina"].append(d) if ok else None
    return {k: {"n": len(v), "p50_ms": round(1000 * (percentile(v, 50) or 0), 1),
                "p99_ms": round(1000 * (percentile(v, 99) or 0), 1)} for k, v in voci.items()}


def esegui_profilo(lms, nome, a, rnd):
    lms.rpc("", "pref", "dbhighmem", PROFILI[nome])
    if a.riavvia_comando:
        run_cmd(a.riavvia_comando)
        time.sleep(a.attesa_riavvio)
    ris = {"profilo": nome, "dbhighmem": PROFILI[nome]}
    picco = [0]
    lms.rpc("", "wipecache")
    ris["indicizzazione_completa_s"] = attendi_scansione(lms, a.massimo_scansione, picco)
    if a.aggiungi_comando:
        run_cmd(a.aggiungi_comando)
        lms.rpc("", "rescan")
        ris["indicizzazione_incrementale_s"] = attendi_scansione(lms, a.massimo_scansione, picco)
    ris["brani_indicizzati"] = lms.rpc("", "serverstatus", 0, 1).get("info total songs")
    ris["ram_picco_scansione_kb"] = picco[0] or None
    ris["latenza"] = latenze(lms, a.interrogazioni, rnd)
    righe = [rss_kb(p) for p in pids("slimserver.pl")]
    ris["ram_lyrion_riposo_kb"] = max([r for r in righe if r] or [0]) or None
    return ris


def main():
    p = argparse.ArgumentParser(description=DESCRIZIONE)
    p.add_argument("--profilo", choices=["disco", "ram", "entrambi"], default="entrambi")
    p.add_argument("--brani", type=int, default=0, help="brani attesi (solo nel rapporto)")
    p.add_argument("--interrogazioni", type=int, default=200)
    p.add_argument("--seme", type=int, default=1)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--porta", type=int, default=9000)
    p.add_argument("--ssh", help="utente@player: misura la RAM di Lyrion sul player remoto")
    p.add_argument("--auth", help="utente:password di Lyrion")
    p.add_argument("--massimo-scansione", type=int, default=6 * 3600)
    p.add_argument("--aggiungi-comando", help="comando che aggiunge l'1%% di brani (scansione incrementale)")
    p.add_argument("--riavvia-comando", help="es. 'sweetspot-lms riavvia', dopo il cambio di profilo")
    p.add_argument("--attesa-riavvio", type=int, default=60)
    p.add_argument("--json", help="scrive il rapporto in questo file")
    p.add_argument("--simula", action="store_true", help="Lyrion finto, per la CI")
    a = p.parse_args()
    collaudo_comune.SIS.ssh = a.ssh
    if a.ssh and a.host == '127.0.0.1':
        a.host = a.ssh.rpartition('@')[2]
    finto = None
    if a.simula:
        finto = LyrionFinto(brani=a.brani or 1000, durata_rescan=1.0)
        a.porta = finto.porta
    lms = Lms(a.host, a.porta, a.auth)
    rnd = random.Random(a.seme)
    profili = ["disco", "ram"] if a.profilo == "entrambi" else [a.profilo]
    rapporto = {"brani": a.brani, "seme": a.seme, "profili": [esegui_profilo(lms, n, a, rnd) for n in profili]}
    if len(rapporto["profili"]) == 2:
        d, r = rapporto["profili"]
        rapporto["confronto"] = {
            "ram_meno_disco_kb": (r["ram_lyrion_riposo_kb"] or 0) - (d["ram_lyrion_riposo_kb"] or 0),
            "scansione_completa_ram_su_disco": round((r["indicizzazione_completa_s"] or 0)
                                                    / max(d["indicizzazione_completa_s"] or 1e-9, 1e-9), 2),
        }
    testo = json.dumps(rapporto, indent=2, ensure_ascii=False)
    print(testo)
    if a.json:
        with open(a.json, "w") as f:
            f.write(testo + "\n")
    if finto:
        finto.chiudi()
    sys.exit(0 if all(x["indicizzazione_completa_s"] is not None for x in rapporto["profili"]) else 1)


if __name__ == "__main__":
    main()
