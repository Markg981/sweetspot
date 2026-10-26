#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Controllo del triage delle CVE trovate da grype (vedi docs/supply-chain.md).

  triage-cve.py GRYPE.json [--triage docs/triage-cve.tsv] [--oggi AAAA-MM-GG]

Ogni corrispondenza Critical o High del rapporto di grype deve avere una riga
nella tabella di triage (stessa CVE, o un suo alias in relatedVulnerabilities,
stesso pacchetto, stessa versione o "*"). Esce con 1 se ne manca anche una, se
una decisione "accettata" e' scaduta o se la tabella e' malformata: in CI
blocca la compilazione. Le gravita' minori si contano ma non bloccano.
"""
import argparse
import datetime
import json
import sys

GRAVI = ("Critical", "High")
DECISIONI = ("non-affetta", "accettata")
COLONNE = ["cve", "pacchetto", "versione", "decisione", "rivedere-entro", "motivo"]


def leggi_triage(percorso):
    """Righe della tabella (TSV, # per i commenti) come dizionari; errori a parte."""
    righe, errori = [], []
    intestazione = None
    with open(percorso, encoding="utf-8") as f:
        for n, riga in enumerate(f, 1):
            riga = riga.rstrip("\r\n")
            if not riga.strip() or riga.startswith("#"):
                continue
            campi = riga.split("\t")
            if intestazione is None:
                if campi != COLONNE:
                    errori.append(f"{percorso}:{n}: intestazione attesa {COLONNE}")
                    return [], errori
                intestazione = campi
                continue
            if len(campi) != len(COLONNE):
                errori.append(f"{percorso}:{n}: {len(campi)} colonne invece di {len(COLONNE)}")
                continue
            r = dict(zip(COLONNE, campi), riga=n)
            if not r["cve"] or not r["pacchetto"] or not r["versione"] or not r["motivo"].strip():
                errori.append(f"{percorso}:{n}: cve, pacchetto, versione e motivo sono obbligatori")
                continue
            if r["decisione"] not in DECISIONI:
                errori.append(f"{percorso}:{n}: decisione '{r['decisione']}' non in {DECISIONI}")
                continue
            if r["rivedere-entro"]:
                try:
                    r["scadenza"] = datetime.date.fromisoformat(r["rivedere-entro"])
                except ValueError:
                    errori.append(f"{percorso}:{n}: data '{r['rivedere-entro']}' non AAAA-MM-GG")
                    continue
            elif r["decisione"] == "accettata":
                errori.append(f"{percorso}:{n}: una CVE accettata vuole la data rivedere-entro")
                continue
            righe.append(r)
    if intestazione is None:
        errori.append(f"{percorso}: tabella vuota, manca l'intestazione")
    return righe, errori


def corrispondenze(rapporto):
    """(id, alias, gravita', pacchetto, versione) di ogni corrispondenza di grype."""
    for m in rapporto.get("matches", []):
        v, a = m["vulnerability"], m["artifact"]
        alias = {r["id"] for r in m.get("relatedVulnerabilities", [])}
        yield v["id"], alias, v.get("severity", "Unknown"), a["name"], a["version"]


def controlla(rapporto, righe, oggi):
    """Esito del controllo: (problemi, note) come liste di righe di testo."""
    problemi, note, usate = [], [], set()
    conteggio = {}
    for cve, alias, gravita, pacchetto, versione in corrispondenze(rapporto):
        conteggio[gravita] = conteggio.get(gravita, 0) + 1
        if gravita not in GRAVI:
            continue
        trovate = [r for r in righe
                   if r["pacchetto"] == pacchetto
                   and r["versione"] in ("*", versione)
                   and (r["cve"] == cve or r["cve"] in alias)]
        if not trovate:
            problemi.append(f"{cve} ({gravita}) in {pacchetto} {versione}: senza triage")
            continue
        r = trovate[0]
        usate.add(r["riga"])
        if "scadenza" in r and r["scadenza"] < oggi:
            problemi.append(f"{cve} ({gravita}) in {pacchetto} {versione}: triage scaduto "
                            f"il {r['rivedere-entro']} (riga {r['riga']}), da rivedere")
        else:
            note.append(f"{cve} ({gravita}) in {pacchetto} {versione}: {r['decisione']}")
    for r in righe:
        if r["riga"] not in usate:
            note.append(f"riga {r['riga']} ({r['cve']} {r['pacchetto']}) non usata in questo rapporto")
    note.insert(0, "corrispondenze: " + (", ".join(f"{g} {n}" for g, n in sorted(conteggio.items())) or "nessuna"))
    return problemi, note


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("rapporto", help="JSON di grype (-o json)")
    p.add_argument("--triage", default="docs/triage-cve.tsv")
    p.add_argument("--oggi", type=datetime.date.fromisoformat, default=datetime.date.today())
    a = p.parse_args(argv)
    righe, errori = leggi_triage(a.triage)
    with open(a.rapporto, encoding="utf-8") as f:
        rapporto = json.load(f)
    problemi, note = controlla(rapporto, righe, a.oggi)
    for n in note:
        print(n)
    for e in errori + problemi:
        print("ERRORE: " + e, file=sys.stderr)
    if errori or problemi:
        print(f"Triage incompleto: {len(errori)} errori nella tabella, {len(problemi)} CVE gravi "
              "senza decisione valida (vedi docs/supply-chain.md).", file=sys.stderr)
        return 1
    print("Triage completo: ogni CVE Critical/High ha una decisione valida.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
