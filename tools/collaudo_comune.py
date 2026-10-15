# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - parti comuni di collaudo-prolungato.py e benchmark-libreria.py:
# client JSON-RPC di Lyrion (come lo usa Material Skin), misure di processo
# e un Lyrion finto per provare gli strumenti senza hardware (--simula).

import base64
import http.server
import json
import math
import os
import shlex
import subprocess
import threading
import time
import urllib.request


def percentile(valori, p):
    """Percentile (metodo del rango piu' vicino); None se non ci sono valori."""
    if not valori:
        return None
    v = sorted(valori)
    return v[min(len(v) - 1, max(0, math.ceil(p / 100.0 * len(v)) - 1))]


class Lms:
    def __init__(self, host="127.0.0.1", porta=9000, auth=None, timeout=30):
        self.base = "http://%s:%d" % (host, porta)
        self.timeout = timeout
        self.auth = auth  # "utente:password" oppure None

    def _req(self, url, dati=None):
        r = urllib.request.Request(url, data=dati)
        if dati is not None:
            r.add_header("Content-Type", "application/json")
        if self.auth:
            r.add_header("Authorization", "Basic " + base64.b64encode(self.auth.encode()).decode())
        with urllib.request.urlopen(r, timeout=self.timeout) as f:
            return f.read()

    def rpc(self, player, *comando):
        corpo = json.dumps({"id": 1, "method": "slim.request", "params": [player, list(comando)]})
        return json.loads(self._req(self.base + "/jsonrpc.js", corpo.encode())).get("result", {})

    def get(self, percorso):
        return self._req(self.base + percorso)


def timed(f, *a):
    t = time.monotonic()
    try:
        f(*a)
        return time.monotonic() - t, True
    except Exception:
        return time.monotonic() - t, False


class Sistema:
    """Il sistema da collaudare: questo computer o, con ssh, il player remoto.

    L'immagine Sweetspot non ha Python: gli strumenti girano su un altro
    computer Linux e osservano/guastano il player via SSH (a chiavi, senza
    password: BatchMode)."""

    def __init__(self, ssh=None):
        self.ssh = ssh

    def _remoto(self, argv, extra=()):
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", *extra, self.ssh,
                " ".join(shlex.quote(x) for x in argv)]

    def run(self, argv, timeout=60):
        if self.ssh:
            argv = self._remoto(argv)
        return subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout)

    def popen(self, argv):
        if self.ssh:
            argv = self._remoto(argv)
        return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def leggi(self, percorso, predefinito=""):
        if not self.ssh:
            try:
                with open(percorso, errors="replace") as f:
                    return f.read()
            except OSError:
                return predefinito
        try:
            r = self.run(["cat", percorso])
        except (OSError, subprocess.SubprocessError):
            return predefinito
        return r.stdout if r.returncode == 0 else predefinito

    def dim(self, percorso):
        if not self.ssh:
            try:
                return os.path.getsize(percorso)
            except OSError:
                return 0
        try:
            r = self.run(["sh", "-c", "wc -c < " + shlex.quote(percorso)])
            return int(r.stdout.strip() or 0)
        except (OSError, ValueError, subprocess.SubprocessError):
            return 0

    def leggi_da(self, percorso, pos):
        if not self.ssh:
            with open(percorso, "rb") as f:
                f.seek(pos)
                return f.read().decode("utf-8", "replace")
        return self.run(["tail", "-c", "+%d" % (pos + 1), percorso]).stdout

    def esiste_comando(self, nome):
        try:
            return self.run(["sh", "-c", "command -v " + shlex.quote(nome)]).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False


SIS = Sistema()


def leggi_file(percorso, predefinito=""):
    return SIS.leggi(percorso, predefinito)


ELENCO_CMDLINE = 'for d in /proc/[0-9]*; do printf "%s " "${d#/proc/}"; tr "\\000" " " < $d/cmdline 2>/dev/null; echo; done'


def pids(nome_processo, proc="/proc"):
    """Pid dei processi il cui comando contiene nome (esclusi gli strumenti di collaudo)."""
    if SIS.ssh:
        try:
            out = SIS.run(["sh", "-c", ELENCO_CMDLINE]).stdout
        except (OSError, subprocess.SubprocessError):
            return []
        voci = [r.split(" ", 1) for r in out.splitlines() if " " in r]
    else:
        try:
            voci = [[d, leggi_file(os.path.join(proc, d, "cmdline")).replace("\0", " ")]
                    for d in os.listdir(proc) if d.isdigit()]
        except OSError:
            return []
    return sorted(int(d) for d, c in voci
                  if d.isdigit() and nome_processo in c and "collaudo" not in c and "benchmark" not in c)


def rss_kb(pid, proc="/proc"):
    for riga in leggi_file(os.path.join(proc, str(pid), "status")).splitlines():
        if riga.startswith("VmRSS:"):
            return int(riga.split()[1])
    return None


def mem_disponibile_kb(proc="/proc"):
    for riga in leggi_file(os.path.join(proc, "meminfo")).splitlines():
        if riga.startswith("MemAvailable:"):
            return int(riga.split()[1])
    return None


class LyrionFinto:
    """Lyrion minimo in-process: stato di riproduzione, navigazione, rescan."""

    def __init__(self, brani=2000, durata_rescan=0.5):
        self.brani = brani
        self.durata_rescan = durata_rescan
        self.rescan_fino = 0.0
        self.t0 = time.monotonic()
        self.prefs = {}
        self.richieste = 0
        finto = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                finto.richieste += 1
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.end_headers()
                self.wfile.write(b"\xff\xd8\xff\xd9")

            def do_POST(self):
                finto.richieste += 1
                n = int(self.headers.get("Content-Length", 0))
                cmd = json.loads(self.rfile.read(n))["params"][1]
                out = json.dumps({"id": 1, "result": finto.risposta(cmd)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.porta = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def chiudi(self):
        self.server.shutdown()

    def risposta(self, cmd):
        c = cmd[0]
        if c == "status":
            return {"mode": "play", "player_connected": 1, "time": time.monotonic() - self.t0}
        if c in ("rescan", "wipecache"):
            self.rescan_fino = time.monotonic() + self.durata_rescan
            return {}
        if c == "serverstatus":
            return {"rescan": 1 if time.monotonic() < self.rescan_fino else 0, "info total songs": self.brani}
        if c == "pref":
            if len(cmd) > 2:
                self.prefs[cmd[1]] = cmd[2]
            return {"_p2": self.prefs.get(cmd[1], 0)}
        if c in ("albums", "artists", "titles", "search"):
            return {"count": 3, "albums_loop": [{"id": 1, "artwork_track_id": "abc"}]}
        return {}
