#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CamillaDSP di sessione sul percorso ALSA (snd-aloop) del sistema avviato.

Una sola istanza di CamillaDSP, avviata come fa il player (stdin da una pipe,
websocket su 127.0.0.1), e il plugin ALSA cdsp in modalita' sessione che vi
scrive i campioni. Si suona un tono a 44,1 kHz e poi uno a 96 kHz: al cambio di
frequenza il plugin fa caricare la nuova configurazione dal websocket. Si
verifica che

  - il processo CamillaDSP sia lo stesso (stesso PID) prima, fra e dopo i due
    brani, e che ce ne sia uno solo;
  - l'audio registrato dal lato di cattura di hw:Loopback sia il tono a 1 kHz,
    con il livello atteso, senza buchi, a ciascuna frequenza (se il cambio non
    arrivasse, il tono a 96 kHz uscirebbe a un'altra frequenza);
  - alla fine CamillaDSP stia usando la configurazione a 96 kHz.

Serve il sistema avviato in QEMU con snd-aloop gia' caricato, raggiungibile in
SSH (password in SSHPASS), come per tests/prova-alsa-qemu.sh. Senza argomenti
--ssh-port analizza solo un file: --analizza FILE.raw FREQUENZA.
"""
import argparse
import array
import json
import math
import os
import subprocess
import sys
import time
import wave
from pathlib import Path

TONO_HZ = 1000.0
AMPIEZZA = 0.5          # picco, rispetto al fondo scala
SECONDI = 3             # durata di ogni brano
CATTURA_SECONDI = 2     # registrati, dopo il silenzio iniziale
RATES = (44100, 96000)
PORTA = 1234
DIR = "/tmp/sessione-cdsp"

YML = """---
devices:
  samplerate: {rate}
  chunksize: 4096
  queuelimit: 1
  volume_limit: 0.0
  capture:
    type: Stdin
    channels: 2
    format: S32_LE
    extra_samples: 8192
  playback:
    type: Alsa
    channels: 2
    device: "hw:CARD=Loopback,DEV=0"
    format: S32_LE
filters:
  attenuazione:
    type: Gain
    parameters:
      gain: 0.0
pipeline:
  - type: Filter
    channels: [0]
    names:
      - attenuazione
  - type: Filter
    channels: [1]
    names:
      - attenuazione
"""

ASOUND = """pcm.cdsptest {{
	type cdsp
	cpath "/usr/bin/camilladsp"
	config_out "{dir}/avvio.yml"
	config_cdsp 1
	channels 2
	rates = [ {rates} ]
	fifo "{dir}/fifo"
	ws_port {porta}
	config_rate_prefix "{dir}/camilladsp-"
	chunk_frames 4096
	tail_frames 8192
}}
"""


class Errore(RuntimeError):
    pass


def tono(path, rate, secondi=SECONDI):
    """WAV stereo a 32 bit con un tono a 1 kHz, -6 dBFS."""
    n = int(rate * secondi)
    dati = array.array("i")
    for i in range(n):
        v = int(AMPIEZZA * 2147483647 * math.sin(2 * math.pi * TONO_HZ * i / rate))
        dati.append(v)
        dati.append(v)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(4)
        w.setframerate(rate)
        w.writeframes(dati.tobytes())


def analizza(raw, rate, secondi=CATTURA_SECONDI):
    """Verifica un registrazione S32_LE stereo: tono a 1 kHz, livello, buchi.

    Salta il silenzio iniziale (il blocco di silenzio che segue il cambio di
    configurazione) e un po' di margine, poi guarda `secondi` secondi del
    canale sinistro. Restituisce un dizionario con il verdetto.
    """
    dati = array.array("i")
    dati.frombytes(raw[: len(raw) // 8 * 8])
    sinistro = dati[0::2]
    soglia = int(0.05 * 2147483647)
    inizio = next((i for i, v in enumerate(sinistro) if abs(v) > soglia), None)
    esito = {"rate": rate, "campioni": len(sinistro), "status": "fail"}
    if inizio is None:
        esito["errore"] = "nessun segnale nella registrazione"
        return esito
    inizio += int(0.05 * rate)
    fine = inizio + int(secondi * rate)
    if fine > len(sinistro):
        esito["errore"] = "registrazione troppo corta: %d campioni dopo l'inizio, ne servono %d" % (
            len(sinistro) - inizio, fine - inizio)
        return esito
    x = [v / 2147483647.0 for v in sinistro[inizio:fine]]
    n = len(x)
    # Componente a 1 kHz (ampiezza e fase) e residuo.
    w = 2 * math.pi * TONO_HZ / rate
    c = sum(v * math.cos(w * i) for i, v in enumerate(x)) * 2 / n
    s = sum(v * math.sin(w * i) for i, v in enumerate(x)) * 2 / n
    ampiezza = math.hypot(c, s)
    rms2 = sum(v * v for v in x) / n
    parte_tono = ampiezza * ampiezza / 2
    residuo_db = 10 * math.log10(max(rms2 - parte_tono, 1e-30) / max(parte_tono, 1e-30))
    # Buchi: piu' di 64 campioni consecutivi a zero dentro il tono.
    corsa = massimo = 0
    for v in x:
        corsa = corsa + 1 if v == 0.0 else 0
        massimo = max(massimo, corsa)
    esito.update(ampiezza=round(ampiezza, 4), residuo_db=round(residuo_db, 1), zeri_consecutivi=massimo)
    if abs(ampiezza - AMPIEZZA) > 0.05:
        esito["errore"] = "livello del tono a 1 kHz %.3f invece di %.3f" % (ampiezza, AMPIEZZA)
    elif residuo_db > -30:
        esito["errore"] = "troppa energia fuori dal tono a 1 kHz (%.1f dB): frequenza sbagliata o disturbi" % residuo_db
    elif massimo > 64:
        esito["errore"] = "buco nell'audio: %d campioni a zero di seguito" % massimo
    else:
        esito["status"] = "pass"
    return esito


class Ospite:
    def __init__(self, porta, host="127.0.0.1"):
        self.base = ["sshpass", "-e", "ssh", "-p", str(porta), "-o", "StrictHostKeyChecking=no",
                     "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                     "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "root@" + host]

    def run(self, comando, dati=None, timeout=120, controlla=True):
        r = subprocess.run(self.base + [comando], input=dati, capture_output=True, timeout=timeout)
        if controlla and r.returncode != 0:
            raise Errore("sull'ospite \"%s\" e' fallito (%d): %s" % (
                comando[:80], r.returncode, r.stderr.decode(errors="replace")[-400:]))
        return r

    def invia(self, locale, remoto):
        self.run("cat > %s" % remoto, dati=Path(locale).read_bytes())

    def preleva(self, remoto):
        return self.run("cat %s" % remoto).stdout


def pid_camilla(ospite):
    pids = ospite.run("pidof camilladsp", controlla=False).stdout.decode().split()
    return pids


def esegui(porta, uscita):
    uscita.mkdir(parents=True, exist_ok=True)
    g = Ospite(porta)
    rapporto = {"scope": "camilladsp-sessione", "status": "fail", "brani": []}
    try:
        if g.run("[ -x /usr/bin/camilladsp ]", controlla=False).returncode != 0:
            rapporto["status"] = "skip"
            rapporto["nota"] = "l'immagine non include CamillaDSP"
            print("CamillaDSP non presente nell'immagine: prova saltata")
            return 0
        if g.run("pidof camilladsp", controlla=False).returncode == 0:
            raise Errore("CamillaDSP e' gia' in esecuzione: la prova userebbe la stessa scheda e la stessa porta")
        for rate in RATES:
            tono(uscita / ("tono-%d.wav" % rate), rate)
        g.run("rm -rf {d} && mkdir -p {d}".format(d=DIR))
        for rate in RATES:
            Path(uscita / ("camilladsp-%d.yml" % rate)).write_text(YML.format(rate=rate))
            g.invia(uscita / ("camilladsp-%d.yml" % rate), "%s/camilladsp-%d.yml" % (DIR, rate))
            g.invia(uscita / ("tono-%d.wav" % rate), "%s/tono-%d.wav" % (DIR, rate))
        asound = ASOUND.format(dir=DIR, porta=PORTA, rates=" ".join(str(r) for r in RATES))
        (uscita / "asound.conf").write_text(asound)
        g.invia(uscita / "asound.conf", DIR + "/asound.conf")
        # Come il player: pipe aperta in lettura e scrittura, websocket locale.
        g.run("mkfifo {d}/fifo && (camilladsp -l warn -o {d}/camilladsp.log -p {p} -a 127.0.0.1 "
              "{d}/camilladsp-{r}.yml <> {d}/fifo > /dev/null 2>&1 &)".format(d=DIR, p=PORTA, r=RATES[0]))
        for _ in range(50):
            if g.run("sweetspot-camilla %d GetState" % PORTA, controlla=False).returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise Errore("CamillaDSP non risponde al websocket")
        pids = [pid_camilla(g)]
        if len(pids[0]) != 1:
            raise Errore("attesa una sola istanza di CamillaDSP, trovate: %s" % pids[0])
        for rate in RATES:
            raw = "%s/cattura-%d.raw" % (DIR, rate)
            # aplay suona sul plugin; appena l'uscita di CamillaDSP e' in
            # riproduzione si registra dal lato di cattura di Loopback.
            script = (
                "ALSA_CONFIG_PATH={d}/asound.conf "
                "aplay -q -D cdsptest {d}/tono-{r}.wav 2> {d}/aplay-{r}.err & ap=$!; "
                "i=0; until grep -q '^rate: {r} ' /proc/asound/Loopback/pcm0p/sub0/hw_params 2>/dev/null && "
                "grep -q '^state: RUNNING' /proc/asound/Loopback/pcm0p/sub0/status 2>/dev/null; do "
                "i=$((i+1)); [ $i -gt 100 ] && break; sleep 0.1; done; "
                "arecord -q -D hw:CARD=Loopback,DEV=1 -f S32_LE -c 2 -r {r} -d {s} -t raw {raw} 2> {d}/arecord-{r}.err; "
                "wait $ap; echo aplay=$?"
            ).format(d=DIR, r=rate, s=CATTURA_SECONDI + 1, raw=raw)
            r = g.run(script, timeout=90, controlla=False)
            brano = {"rate": rate, "uscita": r.stdout.decode().strip()}
            (uscita / ("cattura-%d.raw" % rate)).write_bytes(g.preleva(raw))
            brano["analisi"] = analizza((uscita / ("cattura-%d.raw" % rate)).read_bytes(), rate)
            brano["pid"] = pid_camilla(g)
            pids.append(brano["pid"])
            rapporto["brani"].append(brano)
        rapporto["pid"] = pids
        if any(p != pids[0] for p in pids):
            raise Errore("il processo CamillaDSP non e' rimasto lo stesso: %s" % pids)
        for brano in rapporto["brani"]:
            if brano["analisi"]["status"] != "pass":
                raise Errore("audio a %d Hz non corretto: %s" % (brano["rate"], brano["analisi"].get("errore")))
            if "aplay=0" not in brano["uscita"]:
                raise Errore("aplay a %d Hz terminato con errore: %s" % (brano["rate"], brano["uscita"]))
        corrente = g.run("sweetspot-camilla %d GetConfigFilePath" % PORTA).stdout.decode()
        rapporto["configurazione_finale"] = corrente.strip()
        if "camilladsp-%d.yml" % RATES[-1] not in corrente:
            raise Errore("CamillaDSP non usa la configurazione a %d Hz: %s" % (RATES[-1], corrente.strip()))
        rapporto["status"] = "pass"
        print("CamillaDSP di sessione: stesso PID %s, audio corretto a %s Hz" % (pids[0][0], "/".join(str(r) for r in RATES)))
        return 0
    except Errore as e:
        rapporto["errore"] = str(e)
        print("CamillaDSP di sessione: FALLITO: %s" % e, file=sys.stderr)
        return 1
    finally:
        try:
            for nome in ("camilladsp.log", "aplay-44100.err", "aplay-96000.err", "arecord-44100.err", "arecord-96000.err"):
                dati = g.run("cat %s/%s 2>/dev/null; true" % (DIR, nome), controlla=False).stdout
                (uscita / nome).write_bytes(dati)
                if rapporto["status"] != "pass" and dati.strip():
                    print("--- " + nome + " ---" + chr(10) + dati.decode(errors="replace")[-1500:], file=sys.stderr)
            g.run("killall camilladsp 2>/dev/null; rm -rf %s" % DIR, controlla=False)
        except Exception as e:  # raccolta delle prove, non deve nascondere l'errore
            rapporto.setdefault("raccolta", str(e))
        (uscita / "report.json").write_text(json.dumps(rapporto, indent=2))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--ssh-port", type=int)
    p.add_argument("--output", type=Path)
    p.add_argument("--analizza", nargs=2, metavar=("FILE", "FREQUENZA"))
    a = p.parse_args(argv)
    if a.analizza:
        esito = analizza(Path(a.analizza[0]).read_bytes(), int(a.analizza[1]))
        print(json.dumps(esito))
        return 0 if esito["status"] == "pass" else 1
    if a.ssh_port is None or a.output is None:
        p.error("servono --ssh-port e --output (oppure --analizza)")
    return esegui(a.ssh_port, a.output)


if __name__ == "__main__":
    raise SystemExit(main())
