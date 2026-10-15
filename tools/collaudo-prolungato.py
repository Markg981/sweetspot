#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - collaudo prolungato: riproduzione continua con guasti iniettati.
#   python3 tools/collaudo-prolungato.py --ore 24 [--json rapporto.json]
#   python3 tools/collaudo-prolungato.py --secondi 300 --guasti rete,scansione
# Si avvia sul player (SSH) con un brano lungo o una playlist in riproduzione.
# Mentre l'audio suona inietta, a rotazione e con un seme riproducibile:
#   rete       interfaccia giu'/su e perdita di pacchetti con tc netem (se c'e');
#   scansione  rescan della libreria;
#   navigazione chiamate JSON-RPC come farebbe Material Skin, copertine incluse;
#   ram        un allocatore che sale a gradini fino a una quota della RAM libera.
# Misura ogni interruzione, non solo gli XRUN: buffer di output svuotato e
# XRUN (dal registro di Squeezelite), salti nel tempo di riproduzione,
# riproduzione fermata, riconnessioni del player, riavvii di servizi (cambio
# di pid), OOM del kernel. Il rapporto (testo e JSON) ha l'esito pass/fail
# rispetto alle soglie (--soglia nome=valore; predefinite tutte 0).
# Riusa sweetspot-durata (misure di memoria/temperatura) e il registro di
# Squeezelite gia' esistenti; in CI: tests/prova-collaudo.py usa --simula.

import argparse
import json
import os
import random
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collaudo_comune  # noqa: E402
from collaudo_comune import SIS, Lms, LyrionFinto, leggi_file, mem_disponibile_kb, pids  # noqa: E402

DESCRIZIONE = "Strumento Sweetspot di collaudo (vedi il commento in testa al file e docs/collaudo.md)"
SERVIZI = ["squeezelite", "slimserver.pl", "sweetspot-player", "sweetspot-lms"]
RE_BUFFER = re.compile(r"underrun|under-run|buffer.*(empty|vuot)|output.*(empty|starv)", re.I)
RE_XRUN = re.compile(r"xrun|snd_pcm_recover|broken pipe", re.I)
RE_OOM = re.compile(r"out of memory|oom-kill|killed process", re.I)
SOGLIE = {"xrun": 0, "buffer_svuotato": 0, "salti_tempo": 0, "interruzioni": 0,
          "riconnessioni_player": 0, "restart_servizi": 0, "oom": 0, "rpc_fallite_percento": 5}
SALTO_MAX_S = 1.5  # scarto tra tempo di riproduzione e orologio oltre cui e' un salto


class Collaudo:
    def __init__(self, a):
        self.a = a
        self.lms = Lms(a.host, a.porta, a.auth, timeout=15)
        self.player = a.player
        self.stop = threading.Event()
        self.t0 = time.time()
        self.eventi = []   # {t, tipo, dettaglio, guasto}
        self.guasti = []   # {t, nome, durata_s, esito}
        self.guasto_in_corso = None
        self.rpc = {"ok": 0, "no": 0}
        self.lock = threading.Lock()
        self.rnd = random.Random(a.seme)
        self.sqlog_pos = self._dim(a.log_squeezelite)
        self.oom0 = self._oom()

    # --- utilita'
    @staticmethod
    def _dim(percorso):
        return SIS.dim(percorso)

    def _oom(self):
        if self.a.simula:
            return 0
        try:
            out = SIS.run(["dmesg"], timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return 0
        return len(RE_OOM.findall(out))

    def evento(self, tipo, dettaglio=""):
        with self.lock:
            self.eventi.append({"t": round(time.time() - self.t0, 1), "tipo": tipo,
                                "dettaglio": dettaglio, "guasto": self.guasto_in_corso})
        print("[%7.1f] %s %s%s" % (time.time() - self.t0, tipo, dettaglio,
                                   " (durante: %s)" % self.guasto_in_corso if self.guasto_in_corso else ""),
              flush=True)

    def rpc_call(self, *cmd):
        try:
            r = self.lms.rpc(self.player, *cmd)
            self.rpc["ok"] += 1
            return r
        except Exception:
            self.rpc["no"] += 1
            return None

    def comando(self, argv):
        """Esegue un comando di sistema; in simulazione lo annota soltanto."""
        if self.a.simula or self.a.a_secco:
            print("[a secco]", " ".join(argv), flush=True)
            return True
        return SIS.run(argv).returncode == 0

    def dormi(self, s):
        return self.stop.wait(s)

    # --- osservazione
    def monitor(self):
        servizi0 = {s: pids(s) for s in SERVIZI}
        prec = None
        while not self.stop.is_set():
            ora = time.monotonic()
            st = self.rpc_call("status", "-", 1, "tags:")
            if st is not None:
                modo = st.get("mode")
                tempo = float(st.get("time", 0) or 0)
                idx = st.get("playlist_cur_index")
                if not st.get("player_connected", 1):
                    self.evento("riconnessione_player", "player non connesso")
                if prec and prec["modo"] == "play":
                    if modo != "play":
                        self.evento("interruzioni", "modo %s dopo play" % modo)
                    elif idx == prec["idx"]:
                        scarto = (tempo - prec["tempo"]) - (ora - prec["ora"])
                        if abs(scarto) > SALTO_MAX_S:
                            self.evento("salti_tempo", "scarto %.1f s" % scarto)
                prec = {"modo": modo, "tempo": tempo, "idx": idx, "ora": ora}
            self.controlla_servizi(servizi0)
            self.controlla_registro()
            self.dormi(1.0)

    def controlla_servizi(self, servizi0):
        for s in SERVIZI:
            ora = pids(s)
            if servizi0[s] and ora != servizi0[s]:
                if s == "squeezelite":
                    self.evento("riconnessioni_player", "squeezelite %s -> %s" % (servizi0[s], ora))
                self.evento("restart_servizi", "%s %s -> %s" % (s, servizi0[s], ora))
            if ora:
                servizi0[s] = ora
        oom = self._oom()
        if oom > self.oom0:
            self.evento("oom", "%d nuove segnalazioni nel kernel" % (oom - self.oom0))
            self.oom0 = oom

    def controlla_registro(self):
        p = self.a.log_squeezelite
        dim = self._dim(p)
        if dim == 0:
            return  # assente o SSH momentaneamente irraggiungibile
        if dim < self.sqlog_pos:
            self.sqlog_pos = 0  # ruotato
        if dim == self.sqlog_pos:
            return
        try:
            nuovo = SIS.leggi_da(p, self.sqlog_pos)
        except (OSError, subprocess.SubprocessError):
            return
        self.sqlog_pos = dim
        for riga in nuovo.splitlines():
            if RE_XRUN.search(riga):
                self.evento("xrun", riga.strip()[:120])
            elif RE_BUFFER.search(riga):
                self.evento("buffer_svuotato", riga.strip()[:120])

    # --- guasti
    def guasto_rete(self):
        """Giu'/su e netem in un unico comando sganciato dal player: se l'SSH
        passa dalla stessa interfaccia, il "su" parte comunque."""
        d = self.a.interfaccia
        s = int(min(self.rnd.randint(3, 15), self.a.durata_guasto))
        netem = self.a.simula or SIS.esiste_comando("tc")
        n = int(min(30, self.a.durata_guasto))
        seq = "ip link set %s down; sleep %d; ip link set %s up" % (d, s, d)
        if netem:
            seq += "; sleep 2; tc qdisc replace dev %s root netem loss 10%% delay 50ms; sleep %d; tc qdisc del dev %s root" % (d, n, d)
        self.comando(["sh", "-c", "nohup sh -c '%s' >/dev/null 2>&1 &" % seq])
        self.dormi(s + 2 + (n if netem else 0))
        return s + (n if netem else 0), "netem" if netem else "solo giu/su (tc assente)"

    def guasto_scansione(self):
        self.rpc_call("rescan")
        self.dormi(self.a.durata_guasto)
        return self.a.durata_guasto, "rescan"

    def guasto_navigazione(self):
        fine = time.monotonic() + self.a.durata_guasto
        n = 0
        while time.monotonic() < fine and not self.stop.is_set():
            r = self.rnd.randrange(4)
            if r == 0:
                self.rpc_call("albums", self.rnd.randrange(0, 2000), 50, "tags:ljta", "sort:album")
            elif r == 1:
                self.rpc_call("artists", self.rnd.randrange(0, 500), 50)
            elif r == 2:
                self.rpc_call("search", 0, 50, "term:" + self.rnd.choice(["a", "brano", "love", "12"]))
            else:
                try:
                    self.lms.get("/music/%d/cover_100x100_o" % self.rnd.randrange(1, 5000))
                    self.rpc["ok"] += 1
                except Exception:
                    self.rpc["no"] += 1
            n += 1
            self.dormi(0.2)
        return self.a.durata_guasto, "%d chiamate" % n

    def guasto_ram(self):
        libera = mem_disponibile_kb() or 0
        tetto = min(libera * self.a.ram_percento // 100 // 1024, self.a.ram_max_mb)
        gradino = max(tetto // 8, 1)
        if SIS.ssh and not self.a.simula:
            return self.guasto_ram_remoto(tetto, gradino)
        blocchi = []
        try:
            for _ in range(8):
                if self.stop.is_set():
                    break
                b = bytearray(gradino * 1024 * 1024)
                for i in range(0, len(b), 4096):
                    b[i] = 1  # tocca ogni pagina: la RAM e' davvero occupata
                blocchi.append(b)
                self.dormi(max(self.a.durata_guasto / 8, 0.2))
        except MemoryError:
            self.evento("allocazione_fallita", "MemoryError a %d MB" % (len(blocchi) * gradino))
        tot = len(blocchi) * gradino
        blocchi.clear()
        return self.a.durata_guasto, "fino a %d MB (tetto %d MB)" % (tot, tetto)

    def guasto_ram_remoto(self, tetto, gradino):
        """Sul player (BusyBox): head | tail tiene il blocco in RAM finche' vive il comando."""
        procs = []
        durata = int(self.a.durata_guasto)
        try:
            for i in range(1, 9):
                if self.stop.is_set():
                    break
                mb = gradino * i
                procs.append(SIS.popen(["sh", "-c", "head -c %dM /dev/zero | tail -c %dM | sleep %d" % (mb, mb, durata)]))
                self.dormi(max(durata / 8, 0.2))
        finally:
            for pr in procs:
                pr.terminate()
        return durata, "fino a ~%d MB (tetto %d MB)" % (sum(gradino * i for i in range(1, len(procs) + 1)), tetto)

    def guasti_loop(self):
        nomi = [g for g in self.a.guasti.split(",") if g]
        fn = {"rete": self.guasto_rete, "scansione": self.guasto_scansione,
              "navigazione": self.guasto_navigazione, "ram": self.guasto_ram}
        i = 0
        while not self.dormi(self.a.intervallo):
            nome = nomi[i % len(nomi)]
            i += 1
            self.guasto_in_corso = nome
            t = time.time() - self.t0
            try:
                durata, det = fn[nome]()
                esito = det
            except Exception as e:  # un guasto che non si inietta non ferma il collaudo
                durata, esito = 0, "errore: %s" % e
            self.guasto_in_corso = None
            self.guasti.append({"t": round(t, 1), "nome": nome, "durata_s": round(durata, 1), "esito": esito})
            print("[%7.1f] guasto %s: %s" % (t, nome, esito), flush=True)

    # --- esecuzione e rapporto
    def esegui(self):
        durata = self.a.secondi if self.a.secondi else int(self.a.ore * 3600)
        mem0 = mem_disponibile_kb()
        th = [threading.Thread(target=self.monitor, daemon=True),
              threading.Thread(target=self.guasti_loop, daemon=True)]
        for t in th:
            t.start()
        try:
            self.dormi(durata)
        except KeyboardInterrupt:
            pass
        self.stop.set()
        for t in th:
            t.join(timeout=70)
        return self.rapporto(durata, mem0)

    def rapporto(self, durata, mem0):
        conta = {k: 0 for k in SOGLIE}
        for e in self.eventi:
            if e["tipo"] in conta:
                conta[e["tipo"]] += 1
        tot = self.rpc["ok"] + self.rpc["no"]
        conta["rpc_fallite_percento"] = round(100.0 * self.rpc["no"] / tot, 1) if tot else 0
        soglie = dict(SOGLIE)
        soglie.update(self.a.soglia_dict)
        esiti = {k: {"valore": conta[k], "soglia": soglie[k], "ok": conta[k] <= soglie[k]} for k in SOGLIE}
        mem1 = mem_disponibile_kb()
        riuscito = all(v["ok"] for v in esiti.values())
        return {
            "esito": "RIUSCITO" if riuscito else "NON RIUSCITO",
            "durata_s": durata, "seme": self.a.seme, "simulato": self.a.simula,
            "versione": leggi_file("/etc/sweetspot-version").strip() or None,
            "guasti_iniettati": self.guasti,
            "misure": esiti,
            "memoria_disponibile_kb": {"inizio": mem0, "fine": mem1},
            "eventi": self.eventi,
        }


def testo(r):
    righe = ["Collaudo prolungato: %s" % r["esito"], "durata: %d s, guasti iniettati: %d%s" % (
        r["durata_s"], len(r["guasti_iniettati"]), " (SIMULATO)" if r["simulato"] else "")]
    for k, v in r["misure"].items():
        righe.append("%-24s %6s (massimo %s) %s" % (k, v["valore"], v["soglia"], "ok" if v["ok"] else "NO"))
    righe.append("memoria disponibile: %s -> %s kB" % (r["memoria_disponibile_kb"]["inizio"],
                                                       r["memoria_disponibile_kb"]["fine"]))
    return "\n".join(righe)


def interfaccia_predefinita():
    try:
        for n in sorted(os.listdir("/sys/class/net")):
            if n != "lo":
                return n
    except OSError:
        pass
    return "eth0"


def main():
    p = argparse.ArgumentParser(description=DESCRIZIONE)
    p.add_argument("--ore", type=float, default=24)
    p.add_argument("--secondi", type=int, default=0, help="durata in secondi (prevale su --ore): CI")
    p.add_argument("--guasti", default="rete,scansione,navigazione,ram")
    p.add_argument("--intervallo", type=float, default=300, help="secondi tra un guasto e il successivo")
    p.add_argument("--durata-guasto", type=float, default=60)
    p.add_argument("--ram-percento", type=int, default=60, help="quota della RAM libera da occupare")
    p.add_argument("--ram-max-mb", type=int, default=4096)
    p.add_argument("--soglia", action="append", default=[], metavar="NOME=VALORE")
    p.add_argument("--player", default="", help="MAC del player ('' = il primo)")
    p.add_argument("--interfaccia", default=interfaccia_predefinita())
    p.add_argument("--log-squeezelite", default="/var/log/squeezelite.log")
    p.add_argument("--host", default="127.0.0.1", help="Lyrion (con --ssh: lo stesso del player)")
    p.add_argument("--porta", type=int, default=9000)
    p.add_argument("--auth")
    p.add_argument("--ssh", help="utente@player: osserva e guasta il player remoto (l'immagine non ha Python)")
    p.add_argument("--seme", type=int, default=1)
    p.add_argument("--a-secco", action="store_true", help="non esegue ip/tc (le chiamate JSON-RPC si)")
    p.add_argument("--simula", action="store_true", help="Lyrion finto e nessun comando di sistema (CI)")
    p.add_argument("--json", help="scrive il rapporto JSON in questo file")
    p.add_argument("--testo", help="scrive il rapporto in testo in questo file")
    a = p.parse_args()
    a.host_dato = a.host != '127.0.0.1'
    a.soglia_dict = {}
    collaudo_comune.SIS.ssh = a.ssh
    for s in a.soglia:
        k, _, v = s.partition("=")
        if k not in SOGLIE or not v.replace(".", "", 1).isdigit():
            sys.exit("soglia non valida: %s (nomi: %s)" % (s, ", ".join(SOGLIE)))
        a.soglia_dict[k] = float(v)
    finto = None
    if a.simula:
        finto = LyrionFinto()
        a.porta = finto.porta
        a.log_squeezelite = os.devnull
    if a.ssh and not a.host_dato:
        a.host = a.ssh.rpartition('@')[2]
    c = Collaudo(a)
    r = c.esegui()
    t = testo(r)
    print(t)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(r, f, indent=2, ensure_ascii=False)
            f.write("\n")
    if a.testo:
        with open(a.testo, "w") as f:
            f.write(t + "\n")
    if finto:
        finto.chiudi()
    sys.exit(0 if r["esito"] == "RIUSCITO" else 1)


if __name__ == "__main__":
    main()
