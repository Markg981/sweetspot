#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Matrice di verifica del segnale di Sweetspot.

Esegue i casi dichiarati in tools/matrice-segnale.json (FLAC/ALAC/WAV, 16/24/32
bit, fino a 384 kHz, DSD64-256 in DoP da DSF/DFF, cambi PCM/DSD in coda,
hotplug del DAC, carico prolungato) sopra i confrontatori di
tools/audio_verification.py: nessun confronto e' riscritto qui.

    python3 tools/matrice-segnale.py elenca
    python3 tools/matrice-segnale.py prepara --output DIR [--filtro TESTO]
    python3 tools/matrice-segnale.py verifica --dir DIR --catture CART \\
        --ambito digitale_spdif [--report FILE]

L'esito di ogni caso e' PASS, FAIL o NON ESEGUITO (con il motivo). PASS si
dichiara solo con una cattura digitale confrontata bit a bit con la sorgente
decodificata, con allineamento ammesso soltanto sul silenzio iniziale; il
display del DAC e l'ascolto non contano. Senza cattura il caso resta NON
ESEGUITO. Con --completa l'uscita e' 1 anche se resta qualche NON ESEGUITO.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import wave

ROOT = Path(__file__).resolve().parent.parent
MATRICE = Path(__file__).resolve().with_name("matrice-segnale.json")
_spec = importlib.util.spec_from_file_location("audio_verification", ROOT / "tools" / "audio_verification.py")
av = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = av
_spec.loader.exec_module(av)

AMBITI = ("software_stdout", "alsa_loopback", "digitale_spdif", "digitale_usb", "digitale_i2s")
FORMATO_CATTURA = {16: "s16_le", 24: "s24_3le", 32: "s32_le"}
CODEC = {"flac": "flac", "alac": "alac"}
ESTENSIONE = {"flac": "flac", "alac": "m4a"}


def carica_casi(percorso=MATRICE):
    """Espande le famiglie e restituisce l'elenco dei casi."""
    dati = json.loads(Path(percorso).read_text(encoding="utf-8"))
    casi = []
    for famiglia in dati["famiglie"]:
        for formato in famiglia["formati"]:
            for bits in famiglia["bits"]:
                for frequenza in famiglia["frequenze"]:
                    segmento = {"tipo": famiglia["tipo"], "formato": formato,
                                "frequenza": frequenza, "bits": bits}
                    casi.append({"id": f"{formato}-{frequenza}-{bits}", "categoria": famiglia["categoria"],
                                 "descrizione": f"{formato} {frequenza} Hz {bits} bit",
                                 "evidenze": [], "segmenti": [segmento]})
    casi.extend({"evidenze": [], **caso} for caso in dati["casi"])
    ids = [caso["id"] for caso in casi]
    if len(ids) != len(set(ids)):
        raise ValueError("id duplicati nella matrice")
    return casi


def _dati_wav(percorso):
    with wave.open(str(percorso), "rb") as flusso:
        return flusso.readframes(flusso.getnframes())


def _codifica(wav, formato, cartella):
    """Codifica con ffmpeg e rilegge: restituisce (sorgente, riferimento, motivo)."""
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        return None, None, f"ffmpeg non trovato: impossibile generare {formato}"
    sorgente = cartella / f"{wav.stem}.{ESTENSIONE[formato]}"
    decodificato = cartella / f"{wav.stem}-{formato}-decodificato.wav"
    with wave.open(str(wav), "rb") as flusso:
        bits = flusso.getsampwidth() * 8
    passi = ([ffmpeg, "-v", "error", "-y", "-i", str(wav), "-c:a", CODEC[formato], str(sorgente)],
             [ffmpeg, "-v", "error", "-y", "-i", str(sorgente), "-c:a", f"pcm_s{bits}le", str(decodificato)])
    for passo in passi:
        esito = subprocess.run(passo, capture_output=True, text=True, check=False)
        if esito.returncode != 0:
            return None, None, f"ffmpeg ha rifiutato {formato} a {bits} bit: {esito.stderr.strip()[:120]}"
    if _dati_wav(wav) != _dati_wav(decodificato):
        return None, None, f"{formato} non lossless a {bits} bit con questo ffmpeg"
    return sorgente, decodificato, None


def _prepara_segmento(radice, segmento, frames):
    tipo, formato = segmento["tipo"], segmento["formato"]
    frequenza, bits = segmento["frequenza"], segmento["bits"]
    cartella = radice / "sorgenti" / f"{tipo}-{formato}-{frequenza}-{bits}"
    cartella.mkdir(parents=True, exist_ok=True)
    n = frames if frames else frequenza
    if tipo == "pcm":
        riferimenti = av.generate_fixtures(cartella, frequenza, bits, n)
        sorgenti = riferimenti
    elif tipo == "dop":
        sorgenti = riferimenti = av.generate_dop_fixtures(cartella, frequenza, n)
    else:
        sorgenti, riferimenti = av.generate_dsd_fixtures(cartella, frequenza, container=formato, frames=n)
    motivo = None
    if formato in CODEC:
        codificati, decodificati = [], []
        for wav in riferimenti:
            sorgente, decodificato, motivo = _codifica(wav, formato, cartella)
            if motivo:
                break
            codificati.append(sorgente)
            decodificati.append(decodificato)
        if not motivo:
            sorgenti, riferimenti = codificati, decodificati

    def rel(percorso):
        return Path(percorso).relative_to(radice).as_posix()

    return {"segmento": segmento, "formato_cattura": FORMATO_CATTURA[bits if tipo == "pcm" else 24],
            "frequenza_cattura": frequenza, "sorgenti": [rel(p) for p in sorgenti],
            "riferimenti": [rel(p) for p in riferimenti], "non_eseguito": motivo}


def _selezionato(caso, filtro):
    return not filtro or filtro in caso["id"] or filtro == caso["categoria"]


def prepara(output, filtro=None, frames=None, casi=None):
    """Genera sorgenti e riferimenti, scrive manifesto.json e lo restituisce."""
    radice = Path(output)
    radice.mkdir(parents=True, exist_ok=True)
    voci = []
    for caso in casi or carica_casi():
        if not _selezionato(caso, filtro):
            continue
        n_frames = frames
        if caso.get("durata_s") and not frames:
            # Due brani consecutivi: ciascuno dura meta' della durata dichiarata.
            n_frames = caso["durata_s"] * caso["segmenti"][0]["frequenza"] // 2
        voci.append({**caso, "preparati": [_prepara_segmento(radice, s, n_frames) for s in caso["segmenti"]]})
    manifesto = {"formato": 1, "casi": voci}
    (radice / "manifesto.json").write_text(json.dumps(manifesto, indent=2) + "\n", encoding="utf-8")
    return manifesto


def verifica_caso(caso, radice, catture, ambito):
    """Esito di un caso: stato PASS/FAIL/NON ESEGUITO, motivo e dettaglio dei segmenti."""
    esito = {"id": caso["id"], "categoria": caso["categoria"], "descrizione": caso["descrizione"],
             "ambito": ambito, "segmenti": []}
    motivi = [p["non_eseguito"] for p in caso["preparati"] if p["non_eseguito"]]
    if motivi:
        return {**esito, "stato": "NON ESEGUITO", "motivo": "; ".join(motivi)}
    totale = len(caso["preparati"])
    file_catture = [Path(catture) / (f"{caso['id']}.raw" if totale == 1 else f"{caso['id']}.{i}.raw")
                    for i in range(1, totale + 1)]
    mancanti = [p.name for p in file_catture if not p.is_file()]
    mancanti += [f"{caso['id']}.{e}.txt" for e in caso["evidenze"]
                 if not (Path(catture) / f"{caso['id']}.{e}.txt").is_file()]
    if mancanti:
        return {**esito, "stato": "NON ESEGUITO",
                "motivo": "cattura digitale o evidenza assente: " + ", ".join(mancanti)}
    stato = "PASS"
    for preparato, cattura in zip(caso["preparati"], file_catture):
        riferimenti = [Path(radice) / r for r in preparato["riferimenti"]]
        opzioni = {"capture_format": preparato["formato_cattura"], "capture_rate": preparato["frequenza_cattura"]}
        comparatore = av.compare_capture if preparato["segmento"]["tipo"] == "pcm" else av.compare_dop_capture
        try:
            rapporto = comparatore(riferimenti, cattura, **opzioni)
        except (ValueError, OSError) as errore:
            rapporto = {"status": "error", "error": str(errore)}
        esito["segmenti"].append({"cattura": cattura.name, "stato": rapporto["status"],
                                  "primo_scarto": rapporto.get("first_mismatch"), "errore": rapporto.get("error")})
        if rapporto["status"] != "pass":
            stato = "FAIL"
    return {**esito, "stato": stato}


def verifica(radice, catture, ambito, filtro=None):
    radice = Path(radice)
    if ambito not in AMBITI:
        raise ValueError(f"ambito sconosciuto: {ambito}")
    manifesto = json.loads((radice / "manifesto.json").read_text(encoding="utf-8"))
    esiti = [verifica_caso(c, radice, catture, ambito) for c in manifesto["casi"] if _selezionato(c, filtro)]
    conteggi = {s: sum(e["stato"] == s for e in esiti) for s in ("PASS", "FAIL", "NON ESEGUITO")}
    return {"ambito": ambito, "conteggi": conteggi, "casi": esiti}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    comandi = parser.add_subparsers(dest="comando", required=True)
    comandi.add_parser("elenca")
    prep = comandi.add_parser("prepara")
    prep.add_argument("--output", type=Path, required=True)
    prep.add_argument("--filtro")
    prep.add_argument("--frames", type=int, help="frame per brano (default: un secondo; durata_s per il carico)")
    ver = comandi.add_parser("verifica")
    ver.add_argument("--dir", type=Path, required=True)
    ver.add_argument("--catture", type=Path, required=True)
    ver.add_argument("--ambito", choices=AMBITI, required=True)
    ver.add_argument("--filtro")
    ver.add_argument("--report", type=Path)
    ver.add_argument("--completa", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.comando == "elenca":
            for caso in carica_casi():
                print(f"{caso['id']:28} {caso['categoria']:18} {caso['descrizione']}")
            return 0
        if args.comando == "prepara":
            for caso in prepara(args.output, args.filtro, args.frames)["casi"]:
                motivi = [p["non_eseguito"] for p in caso["preparati"] if p["non_eseguito"]]
                print(f"{caso['id']:28} {'NON ESEGUITO: ' + '; '.join(motivi) if motivi else 'pronto'}")
            return 0
        rapporto = verifica(args.dir, args.catture, args.ambito, args.filtro)
    except (ValueError, OSError) as errore:
        print(f"errore: {errore}", file=sys.stderr)
        return 2
    for e in rapporto["casi"]:
        print(f"{e['stato']:13} {e['id']:28}" + (f" {e['motivo']}" if e.get("motivo") else ""))
    c = rapporto["conteggi"]
    print(f"\nPASS {c['PASS']}  FAIL {c['FAIL']}  NON ESEGUITO {c['NON ESEGUITO']}  (ambito {rapporto['ambito']})")
    if args.report:
        args.report.write_text(json.dumps(rapporto, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 1 if c["FAIL"] or (args.completa and c["NON ESEGUITO"]) else 0


if __name__ == "__main__":
    sys.exit(main())
