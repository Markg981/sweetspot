#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Matrice di compatibilita' di Sweetspot.

Legge i rapporti (sweetspot-rapporto, formato 1) in docs/compatibilita/*.json
e scrive docs/compatibilita.md: una riga per computer + DAC + versione, con
l'esito delle verifiche di quel sistema. Nessun esito si scrive a mano: la
tabella viene solo dai rapporti.

    python3 tools/matrice-compatibilita.py            rigenera la pagina
    python3 tools/matrice-compatibilita.py --verifica esce con 1 se non e'
                                                      aggiornata (CI)
"""

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPORTS = ROOT / "docs" / "compatibilita"
PAGE = ROOT / "docs" / "compatibilita.md"

# Voci della pagina Stato che contano per la compatibilita' audio.
KEY_ITEMS = ("XRUN nella sessione", "Latenza durante l'ascolto", "DSD", "Watchdog", "Interruzioni sul core audio")

HEADER = """# Matrice di compatibilità

Generata da `tools/matrice-compatibilita.py` dai rapporti in
[`docs/compatibilita/`](compatibilita/): non modificarla a mano.

Ogni riga è un rapporto creato su un sistema reale con
`sweetspot-rapporto` (pagina **Stato** → *Scarica il rapporto di
compatibilità*) e inviato con una segnalazione *Rapporto di compatibilità*
su GitHub. "Avvisi" conta le voci ATTENZIONE della pagina Stato in quel
momento; la prova di durata è `sweetspot-durata` (24 ore di ascolto).

"""


def cell(text):
    return str(text or "").replace("|", "/").replace("\n", " ").strip() or "—"


def key_results(checks):
    found = []
    for item in KEY_ITEMS:
        for c in checks:
            if c.get("voce") == item:
                found.append(f"{item}: {c.get('esito')}")
                break
    return "; ".join(found)


def row(rep):
    comp = rep.get("computer") or {}
    dac = rep.get("dac") or {}
    nets = rep.get("rete") or []
    checks = rep.get("verifiche") or []
    computer = " ".join(x for x in (comp.get("produttore"), comp.get("modello")) if x)
    dac_txt = "nessun DAC"
    if dac:
        dac_txt = dac.get("nome") or dac.get("prodotto") or dac.get("usbid")
        extra = ", ".join(x for x in (dac.get("usbid"), f"firmware {dac['firmware']}" if dac.get("firmware") else "") if x)
        if extra:
            dac_txt += f" ({extra})"
    net = ", ".join(sorted({f"{n.get('driver')} ({n.get('tipo')})" for n in nets}))
    warnings = sum(1 for c in checks if c.get("esito") == "ATTENZIONE")
    return [
        cell(rep.get("data")), cell(rep.get("versione")), cell(computer), cell(comp.get("cpu")),
        cell(net), cell(dac_txt), cell(warnings), cell(key_results(checks)), cell(rep.get("prova_durata")),
    ]


def load(folder):
    reports = []
    for path in sorted(folder.glob("*.json")):
        with path.open(encoding="utf-8") as f:
            rep = json.load(f)
        if rep.get("formato") != 1:
            raise SystemExit(f"{path}: formato sconosciuto")
        reports.append(rep)
    reports.sort(key=lambda r: (r.get("data") or "", r.get("versione") or ""), reverse=True)
    return reports


def render(reports):
    out = [HEADER]
    if not reports:
        out.append("Nessun rapporto ancora: il primo arriverà dalle prove sull'hardware.\n")
        return "".join(out)
    cols = ["Data", "Versione", "Computer", "CPU", "Rete", "DAC", "Avvisi", "Verifiche audio", "Prova di durata"]
    out.append("| " + " | ".join(cols) + " |\n")
    out.append("|" + "---|" * len(cols) + "\n")
    for rep in reports:
        out.append("| " + " | ".join(row(rep)) + " |\n")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verifica", action="store_true")
    ap.add_argument("--rapporti", type=pathlib.Path, default=REPORTS)
    ap.add_argument("--pagina", type=pathlib.Path, default=PAGE)
    args = ap.parse_args()
    text = render(load(args.rapporti))
    if args.verifica:
        current = args.pagina.read_text(encoding="utf-8") if args.pagina.exists() else ""
        if current != text:
            print("docs/compatibilita.md non e' aggiornata: python3 tools/matrice-compatibilita.py", file=sys.stderr)
            return 1
        return 0
    args.pagina.write_text(text, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
