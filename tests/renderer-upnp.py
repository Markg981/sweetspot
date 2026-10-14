#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - prova del renderer UPnP/DLNA in entrata
# (usr/lib/sweetspot/renderer.pl).
#
# Due modi:
#   python3 tests/renderer-upnp.py
#       Lyrion finto (JSON-RPC in questo processo) e Perl del computer.
#       Parte da tests/run.sh. Controlla il protocollo: SSDP, descrittore,
#       servizi, SOAP, eventi, attivazione dal file delle impostazioni e i
#       comandi che arrivano a Lyrion.
#   python3 tests/renderer-upnp.py --rootfs SISTEMA --server http://127.0.0.1:9000
#       Lyrion vero e Perl del sistema compilato (chroot), chiamato da
#       tests/prova-lyrion.sh. Un Squeezelite vero suona un file di prova
#       mandato con SetAVTransportURI: l'uscita PCM deve contenere il segnale.

import argparse
import array
import signal
import http.server
import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RENDERER = ROOT / "board/sweetspot/rootfs-overlay/usr/lib/sweetspot/renderer.pl"
AV = "urn:schemas-upnp-org:service:AVTransport:1"
RC = "urn:schemas-upnp-org:service:RenderingControl:1"
CM = "urn:schemas-upnp-org:service:ConnectionManager:1"
DEVICE = "urn:schemas-upnp-org:device:MediaRenderer:1"
NS = {"d": "urn:schemas-upnp-org:device-1-0", "s": "urn:schemas-upnp-org:service-1-0"}

failures = []


def check(name, ok, detail=""):
    print(("  ok  " if ok else "  KO  ") + name + ("" if ok else "  -> " + str(detail)))
    if not ok:
        failures.append(name)


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(fn, timeout=15, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        value = fn()
        if value:
            return value
        time.sleep(step)
    return None


# --- Lyrion finto ------------------------------------------------------------------

class FakeLyrion:
    def __init__(self):
        self.calls = []
        self.mode = "stop"
        self.tracks = []
        self.index = 0
        self.volume = 50
        self.started = 0.0
        self.paused_at = 0.0
        self.lock = threading.Lock()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                player, cmd = body["params"]
                with owner.lock:
                    result = owner.handle(player, cmd)
                out = json.dumps({"id": body["id"], "method": "slim.request", "params": body["params"],
                                  "result": result}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def elapsed(self):
        if self.mode == "play":
            return time.time() - self.started
        return self.paused_at

    def handle(self, player, cmd):
        self.calls.append(list(cmd))
        c = [str(x) for x in cmd]
        if c[0] == "status":
            loop = []
            if self.tracks:
                loop = [{"url": self.tracks[self.index][0], "title": self.tracks[self.index][1], "duration": 240}]
            return {"mode": self.mode, "time": self.elapsed(), "duration": 240, "mixer volume": self.volume,
                    "playlist_cur_index": self.index, "playlist_tracks": len(self.tracks), "playlist_loop": loop}
        if c[:2] == ["playlist", "play"]:
            self.tracks = [(c[2], c[3] if len(c) > 3 else "")]
            self.index, self.mode, self.started, self.paused_at = 0, "play", time.time(), 0.0
        elif c[:2] == ["playlist", "add"]:
            self.tracks.append((c[2], c[3] if len(c) > 3 else ""))
        elif c[:2] == ["playlist", "index"]:
            self.index = min(self.index + 1, len(self.tracks) - 1)
        elif c[0] == "pause":
            if c[1] == "1" and self.mode == "play":
                self.paused_at, self.mode = self.elapsed(), "pause"
            elif c[1] == "0" and self.mode == "pause":
                self.started, self.mode = time.time() - self.paused_at, "play"
        elif c[0] == "stop":
            self.mode, self.paused_at = "stop", 0.0
        elif c[0] == "time":
            self.started, self.paused_at = time.time() - float(c[1]), float(c[1])
        elif c[:2] == ["mixer", "volume"]:
            self.volume = int(c[2])
        return {}


# --- Protocollo --------------------------------------------------------------------------

def soap(base, service, action, args=(), timeout=10):
    stype = {"AVTransport": AV, "RenderingControl": RC, "ConnectionManager": CM}[service]
    inner = "".join("<%s>%s</%s>" % (k, v, k) for k, v in args)
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            '<u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>' % (action, stype, inner, action)).encode()
    req = urllib.request.Request(base + "/ctl/" + service, data=body, method="POST",
                                 headers={"Content-Type": 'text/xml; charset="utf-8"', "SOAPACTION": '"%s#%s"' % (stype, action)})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        data, status = e.read(), e.code
    root = ET.fromstring(data)
    out = {}
    for el in root.iter():
        tag = el.tag.split("}")[-1]
        if el.tag.endswith("Response"):
            for child in el:
                out[child.tag.split("}")[-1]] = child.text or ""
        if tag == "errorCode":
            out["errorCode"] = el.text
    return status, out


def ssdp_search(port, st, timeout=3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.5)
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: %s\r\n\r\n" % st).encode()
    s.sendto(msg, ("127.0.0.1", port))
    found = []
    end = time.time() + timeout
    while time.time() < end:
        try:
            data, _ = s.recvfrom(2048)
        except (socket.timeout, ConnectionResetError):
            continue
        headers = {}
        lines = data.decode().split("\r\n")
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().upper()] = v.strip()
        headers["_status"] = lines[0]
        found.append(headers)
    s.close()
    return found


class EventSink:
    def __init__(self):
        self.events = []
        owner = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_NOTIFY(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                owner.events.append((dict(self.headers), body.decode()))
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def subscribe(base, service, callback):
    req = urllib.request.Request(base + "/evt/" + service, method="SUBSCRIBE",
                                 headers={"CALLBACK": "<%s>" % callback, "NT": "upnp:event", "TIMEOUT": "Second-300"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status, r.headers.get("SID"), r.headers.get("TIMEOUT")


def transport_state(base):
    return soap(base, "AVTransport", "GetTransportInfo", [("InstanceID", 0)])[1].get("CurrentTransportState")


def didl(title, url):
    return ('&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;'
            '&lt;item id="1" parentID="0" restricted="1"&gt;&lt;dc:title&gt;%s&lt;/dc:title&gt;'
            '&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;'
            '&lt;res protocolInfo="http-get:*:audio/wav:*"&gt;%s&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;' % (title, url))


def make_wav(path, seconds=8, rate=44100):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(seconds * rate):
            v = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
            frames += struct.pack("<hh", v, v)
        w.writeframes(bytes(frames))


# --- Prova -----------------------------------------------------------------------------------

def run(args):
    real = args.rootfs is not None
    if hasattr(signal, "alarm"):
        # Mai bloccati: dopo 5 minuti la prova fallisce (le attese singole sono di secondi).
        def timed_out(*_):
            raise TimeoutError("tempo massimo della prova scaduto (300 s)")
        signal.signal(signal.SIGALRM, timed_out)
        signal.alarm(300)
    tmp = Path(tempfile.mkdtemp(prefix="renderer-upnp-"))
    procs = []
    servers = []
    fake = None
    try:
        mac = "02:aa:bb:cc:dd:ee"
        http_port, ssdp_port = free_port(), free_port(socket.SOCK_DGRAM)
        if real:
            rootfs = Path(args.rootfs)
            run_dir = rootfs / "tmp" / "renderer-run"
            run_dir.mkdir(parents=True, exist_ok=True)
            lms_port = urllib.parse.urlsplit(args.server).port
            cmd_prefix = ["chroot", str(rootfs)]
            run_inside = "/tmp/renderer-run"
            log_inside = "/tmp/renderer-run/sweetspot.log"
            perl = ["/usr/bin/perl"]
            script = "/usr/lib/sweetspot/renderer.pl"
            wav_dir = tmp
        else:
            fake = FakeLyrion()
            servers.append(fake.server)
            lms_port = fake.port
            run_dir = tmp / "run"
            run_dir.mkdir()
            cmd_prefix, run_inside, log_inside = [], str(run_dir), str(tmp / "sweetspot.log")
            perl_bin = shutil.which("perl")
            if not perl_bin:
                if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
                    check("perl disponibile", False, "perl non trovato")
                    return
                print("  (perl non trovato, prova saltata)")
                return
            perl = [perl_bin]
            script = str(RENDERER)
        conf = run_dir / "sweetspot.conf"
        conf.write_text("NOME_PLAYER=Salotto\nMODALITA=completa\nRENDERER_UPNP=no\n", encoding="utf-8")
        (run_dir / "player.mac").write_text(mac + "\n", encoding="utf-8")

        env = {"SWEETSPOT_RUN": run_inside, "SWEETSPOT_LOG": log_inside, "SWEETSPOT_LMS_HTTP_PORT": str(lms_port),
               "SWEETSPOT_RENDERER_PORTA": str(http_port), "SWEETSPOT_RENDERER_SSDP_PORTA": str(ssdp_port),
               "SWEETSPOT_RENDERER_ADDR": "127.0.0.1", "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        envcmd = ["env"] + ["%s=%s" % kv for kv in env.items()]
        full = (cmd_prefix + envcmd + perl + [script]) if real else perl + [script]
        popen_env = None if real else dict(os.environ, **env)
        daemon_out = (tmp / "renderer.out").open("wb")
        daemon = subprocess.Popen(full, stdout=daemon_out, stderr=subprocess.STDOUT, env=popen_env)
        procs.append(daemon)
        base = "http://127.0.0.1:%d" % http_port

        print("== Spento di serie")
        time.sleep(2)
        sock = socket.socket()
        sock.settimeout(1)
        check("RENDERER_UPNP=no: la porta HTTP e' chiusa", sock.connect_ex(("127.0.0.1", http_port)) != 0)
        sock.close()
        check("RENDERER_UPNP=no: nessuna risposta SSDP", ssdp_search(ssdp_port, "ssdp:all", 1.5) == [])
        state = wait_for(lambda: (run_dir / "renderer.json").exists() and json.loads((run_dir / "renderer.json").read_text()))
        check("stato 'spento' scritto per la pagina Stato", bool(state) and state.get("stato") == "spento", state)

        print("== Acceso dal pannello (RENDERER_UPNP=si)")
        conf.write_text("NOME_PLAYER=Salotto\nMODALITA=completa\nRENDERER_UPNP=si\n", encoding="utf-8")

        def up():
            try:
                with urllib.request.urlopen(base + "/desc.xml", timeout=2) as r:
                    return r.read()
            except OSError:
                return None
        desc = wait_for(up, 15)
        check("il descrittore risponde dopo l'accensione", desc is not None, daemon_out and (tmp / "renderer.out").read_text(errors="replace"))
        if desc is None:
            return

        print("== SSDP")
        for st in ("ssdp:all", "upnp:rootdevice", DEVICE, AV, RC, CM):
            found = ssdp_search(ssdp_port, st, 2.5 if st != "ssdp:all" else 3.5)
            sts = sorted({f.get("ST") for f in found})
            if st == "ssdp:all":
                check("M-SEARCH ssdp:all: 6 risposte distinte", len(sts) == 6, sts)
            else:
                check("M-SEARCH %s: una risposta" % st, len(found) == 1 and found[0].get("ST") == st, found)
            for f in found:
                ok = (f["_status"] == "HTTP/1.1 200 OK" and f.get("LOCATION", "").endswith("/desc.xml")
                      and f.get("USN", "").startswith("uuid:") and "max-age" in f.get("CACHE-CONTROL", "") and "EXT" in f)
                if not ok:
                    check("intestazioni SSDP valide (%s)" % st, False, f)
        check("M-SEARCH di un tipo estraneo: nessuna risposta",
              ssdp_search(ssdp_port, "urn:schemas-upnp-org:device:MediaServer:1", 1.5) == [])
        loc = ssdp_search(ssdp_port, DEVICE, 2.5)[0]["LOCATION"]
        check("LOCATION punta alla porta HTTP del renderer", loc == base + "/desc.xml", loc)

        print("== Descrittore")
        root = ET.fromstring(desc)
        dev = root.find("d:device", NS)
        check("deviceType MediaRenderer:1", dev.findtext("d:deviceType", namespaces=NS) == DEVICE)
        check("friendlyName dal nome del player", dev.findtext("d:friendlyName", namespaces=NS) == "Salotto")
        udn = dev.findtext("d:UDN", namespaces=NS) or ""
        check("UDN uuid: valido", udn.startswith("uuid:") and len(udn) == 41, udn)
        check("UDN uguale nell'SSDP", udn in ssdp_search(ssdp_port, "upnp:rootdevice", 2.5)[0]["USN"], udn)
        services = {s.findtext("d:serviceType", namespaces=NS): s for s in dev.findall("d:serviceList/d:service", NS)}
        check("i tre servizi dichiarati", set(services) == {AV, RC, CM}, list(services))
        for stype, svc in services.items():
            for tag in ("serviceId", "SCPDURL", "controlURL", "eventSubURL"):
                check("%s: %s presente" % (stype.split(":")[-2], tag), bool(svc.findtext("d:" + tag, namespaces=NS)))
            with urllib.request.urlopen(base + svc.findtext("d:SCPDURL", namespaces=NS), timeout=5) as r:
                scpd = ET.fromstring(r.read())
            actions = [a.findtext("s:name", namespaces=NS) for a in scpd.findall("s:actionList/s:action", NS)]
            vars_ = {v.findtext("s:name", namespaces=NS) for v in scpd.findall("s:serviceStateTable/s:stateVariable", NS)}
            related = {a.text for a in scpd.iter("{%s}relatedStateVariable" % NS["s"])}
            check("%s: SCPD valido (%d azioni)" % (stype.split(":")[-2], len(actions)), bool(actions) and related <= vars_, related - vars_)
        want = {"SetAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetPositionInfo", "GetTransportInfo"}
        with urllib.request.urlopen(base + "/scpd/AVTransport.xml", timeout=5) as r:
            av_actions = {a.findtext("s:name", namespaces=NS) for a in ET.fromstring(r.read()).findall("s:actionList/s:action", NS)}
        check("AVTransport ha le azioni obbligatorie", want <= av_actions, want - av_actions)

        print("== SOAP")
        st, out = soap(base, "ConnectionManager", "GetProtocolInfo")
        check("GetProtocolInfo elenca FLAC e WAV", st == 200 and "audio/flac" in out.get("Sink", "") and "audio/wav" in out.get("Sink", ""), out)
        st, out = soap(base, "AVTransport", "GetTransportInfo", [("InstanceID", 0)])
        check("GetTransportInfo prima di tutto: NO_MEDIA_PRESENT", st == 200 and out.get("CurrentTransportState") == "NO_MEDIA_PRESENT", out)
        st, out = soap(base, "AVTransport", "Frobnicate", [("InstanceID", 0)])
        check("azione sconosciuta: errore UPnP 401", st == 500 and out.get("errorCode") == "401", (st, out))
        st, out = soap(base, "AVTransport", "Play", [("InstanceID", 0), ("Speed", 1)])
        check("Play senza contenuto: errore 701", st == 500 and out.get("errorCode") == "701", (st, out))

        sink = EventSink()
        servers.append(sink.server)
        status, sid, timeout = subscribe(base, "AVTransport", "http://127.0.0.1:%d/ev" % sink.port)
        check("SUBSCRIBE: SID e TIMEOUT", status == 200 and (sid or "").startswith("uuid:") and (timeout or "").startswith("Second-"), (status, sid, timeout))
        first = wait_for(lambda: sink.events and sink.events[0], 5)
        check("evento iniziale con LastChange", bool(first) and "LastChange" in first[1] and first[0].get("SEQ") == "0", first)

        if real:
            wav = tmp / "prova.wav"
            make_wav(wav, seconds=40)
            handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=str(tmp), **k)  # noqa: E731
            class QuietServer(http.server.ThreadingHTTPServer):
                def handle_error(self, request, client_address):
                    # Lyrion chiude la prima connessione al file: non e' un errore.
                    if not isinstance(sys.exc_info()[1], (ConnectionError, BrokenPipeError)):
                        super().handle_error(request, client_address)
            fileserver = QuietServer(("127.0.0.1", 0), handler)
            threading.Thread(target=fileserver.serve_forever, daemon=True).start()
            url = "http://127.0.0.1:%d/prova.wav" % fileserver.server_address[1]
            servers.append(fileserver)
            # L'uscita PCM (-o -) va in un pipe letto a velocita' di riproduzione
            # (0,1 s ogni 0,1 s): senza lettore Squeezelite si bloccherebbe, e
            # letta senza freno scriverebbe silenzio all'infinito. Il lettore
            # tiene solo il picco e i byte con segnale, mai l'uscita intera.
            sq = subprocess.Popen(["chroot", args.rootfs, "/usr/bin/squeezelite", "-o", "-", "-a", "32", "-r", "44100",
                                   "-s", "127.0.0.1", "-m", mac, "-n", "Prova-renderer"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            procs.append(sq)
            pcm = {"bytes": 0, "peak": 0, "signal": 0}

            def drain():
                chunk = 44100 * 8 // 10
                while True:
                    data = sq.stdout.read(chunk)
                    if not data:
                        return
                    data = data[: len(data) // 4 * 4]
                    samples = array.array("i")
                    samples.frombytes(data)
                    peak = max((abs(x) for x in samples), default=0)
                    pcm["bytes"] += len(data)
                    pcm["peak"] = max(pcm["peak"], peak)
                    if peak > (1 << 27):
                        pcm["signal"] += len(data)
                    time.sleep(0.1)
            threading.Thread(target=drain, daemon=True).start()
            lms = lambda cmd, p="": json.loads(urllib.request.urlopen(urllib.request.Request(  # noqa: E731
                args.server + "/jsonrpc.js", data=json.dumps({"id": 1, "method": "slim.request", "params": [p, cmd]}).encode(),
                headers={"Content-Type": "application/json"}), timeout=5).read())["result"]

            def connected():
                rows = lms(["players", 0, 100]).get("players_loop", [])
                return any(r["playerid"].lower() == mac and str(r.get("connected")) == "1" for r in rows)
            check("Squeezelite di prova collegato a Lyrion", bool(wait_for(connected, 20)))
            lms(["mixer", "volume", 100], mac)
        else:
            url = "http://192.0.2.10:8200/MediaItems/42.wav"
        meta = didl("Brano di prova &amp; C.", url)

        print("== Riproduzione")
        st, out = soap(base, "AVTransport", "SetAVTransportURI", [("InstanceID", 0), ("CurrentURI", url), ("CurrentURIMetaData", meta)])
        check("SetAVTransportURI accettato", st == 200, (st, out))
        st, out = soap(base, "AVTransport", "GetMediaInfo", [("InstanceID", 0)])
        check("GetMediaInfo restituisce l'indirizzo", out.get("CurrentURI") == url, out)
        check("GetMediaInfo restituisce i metadati senza doppio escape", "&lt;dc:title&gt;" in meta and "<dc:title>" in out.get("CurrentURIMetaData", ""), out.get("CurrentURIMetaData"))
        if fake:
            check("SetAVTransportURI da solo non avvia la musica", not any(c[:2] == ["playlist", "play"] for c in fake.calls), fake.calls)
        st, out = soap(base, "AVTransport", "Play", [("InstanceID", 0), ("Speed", 1)])
        check("Play accettato", st == 200, (st, out))
        playing = wait_for(lambda: transport_state(base) == "PLAYING", 15)
        check("GetTransportInfo: PLAYING", bool(playing), transport_state(base))
        if fake:
            plays = [c for c in fake.calls if c[:2] == ["playlist", "play"]]
            check("Play manda a Lyrion 'playlist play' con indirizzo e titolo", len(plays) == 1 and plays[0][2] == url and plays[0][3] == "Brano di prova & C.", plays)
        # La posizione avanza quando il player ha iniziato a suonare: su un computer
        # lento puo' volerci qualche secondo, quindi si attende (al massimo 20 s).
        def position():
            o = soap(base, "AVTransport", "GetPositionInfo", [("InstanceID", 0)])[1]
            return o if o.get("RelTime", "0:00:00") != "0:00:00" else None
        out = wait_for(position, 20, 0.5)
        if not out:
            out = soap(base, "AVTransport", "GetPositionInfo", [("InstanceID", 0)])[1]
        check("GetPositionInfo: traccia, indirizzo e posizione che avanza entro 20 s", out.get("Track") == "1"
              and out.get("TrackURI") == url and out.get("RelTime", "0:00:00") != "0:00:00"
              and out.get("RelTime", "").count(":") == 2, out)
        ev = wait_for(lambda: any("PLAYING" in e[1] for e in sink.events), 8)
        check("evento LastChange con TransportState PLAYING", bool(ev), [e[1][:120] for e in sink.events])
        seqs = [int(e[0].get("SEQ", -1)) for e in sink.events]
        check("SEQ degli eventi crescente", seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs)

        if real:
            got = wait_for(lambda: pcm["signal"] >= 44100 * 8, 25)
            check("l'uscita di Squeezelite contiene il segnale del file entro 25 s (%d byte letti, %d con segnale, picco %d)"
                  % (pcm["bytes"], pcm["signal"], pcm["peak"]), bool(got),
                  "nessun segnale: Lyrion ha scaricato il file ma Squeezelite non lo suona (modo Lyrion: %s)"
                  % lms(["status", "-", 1], mac).get("mode"))

        st, out = soap(base, "AVTransport", "Pause", [("InstanceID", 0)])
        check("Pause accettato", st == 200, (st, out))
        check("GetTransportInfo: PAUSED_PLAYBACK", bool(wait_for(lambda: transport_state(base) == "PAUSED_PLAYBACK", 10)), transport_state(base))
        st, out = soap(base, "AVTransport", "Play", [("InstanceID", 0), ("Speed", 1)])
        check("Play dopo la pausa", st == 200 and bool(wait_for(lambda: transport_state(base) == "PLAYING", 10)), (st, out))
        st, out = soap(base, "AVTransport", "Seek", [("InstanceID", 0), ("Unit", "REL_TIME"), ("Target", "0:00:02")])
        check("Seek REL_TIME accettato", st == 200, (st, out))
        st, out = soap(base, "AVTransport", "Seek", [("InstanceID", 0), ("Unit", "REL_TIME"), ("Target", "abc")])
        check("Seek con destinazione errata: errore 711", st == 500 and out.get("errorCode") == "711", (st, out))
        if fake:
            check("Seek arriva a Lyrion come 'time 2'", any(c[0] == "time" and str(c[1]) == "2" for c in fake.calls), fake.calls)

        st, out = soap(base, "RenderingControl", "SetVolume", [("InstanceID", 0), ("Channel", "Master"), ("DesiredVolume", 37)])
        check("SetVolume accettato", st == 200, (st, out))
        st, out = soap(base, "RenderingControl", "GetVolume", [("InstanceID", 0), ("Channel", "Master")])
        check("GetVolume restituisce 37", out.get("CurrentVolume") == "37", out)
        st, out = soap(base, "RenderingControl", "SetVolume", [("InstanceID", 0), ("Channel", "Master"), ("DesiredVolume", 400)])
        check("SetVolume fuori scala: errore 402", st == 500 and out.get("errorCode") == "402", (st, out))
        if real:
            lms(["mixer", "volume", 100], mac)

        st, out = soap(base, "AVTransport", "Stop", [("InstanceID", 0)])
        check("Stop accettato", st == 200, (st, out))
        check("GetTransportInfo: STOPPED", bool(wait_for(lambda: transport_state(base) == "STOPPED", 10)), transport_state(base))
        if fake:
            check("Stop arriva a Lyrion", fake.mode == "stop", fake.mode)

        print("== Altra musica su Lyrion")
        if fake:
            fake.handle(mac, ["playlist", "play", "file:///musica/altro.flac", "Altro"])
            time.sleep(2.5)
            check("musica non UPnP in corso: il renderer risulta fermo",
                  transport_state(base) in ("STOPPED", "NO_MEDIA_PRESENT"), transport_state(base))
            soap(base, "AVTransport", "Stop", [("InstanceID", 0)])
            check("Stop del renderer non ferma la musica che non e' sua", fake.mode == "play", fake.mode)
            fake.handle(mac, ["stop"])

        print("== Stato per la pagina Stato")
        time.sleep(5.5)
        state = json.loads((run_dir / "renderer.json").read_text())
        check("renderer.json: attivo con nome, porta e comandi", state.get("stato") == "attivo" and state.get("nome") == "Salotto"
              and state.get("porta") == http_port and state.get("comandi", 0) > 10, state)

        print("== Spegnimento dal pannello")
        conf.write_text("NOME_PLAYER=Salotto\nMODALITA=completa\nRENDERER_UPNP=no\n", encoding="utf-8")
        gone = wait_for(lambda: up() is None, 15)
        check("RENDERER_UPNP=no: il descrittore non risponde piu'", bool(gone))
        check("stato 'spento' dopo lo spegnimento", bool(wait_for(lambda: json.loads((run_dir / "renderer.json").read_text()).get("stato") == "spento", 10)))
        conf.write_text("NOME_PLAYER=Salotto\nMODALITA=player\nRENDERER_UPNP=si\n", encoding="utf-8")
        time.sleep(3)
        check("modalita' solo player: il renderer resta spento", up() is None)
        daemon.terminate()
        check("SIGTERM: il demone esce", daemon.wait(10) == 0 or os.name == "nt", daemon.returncode)
    finally:
        signal.alarm(0) if hasattr(signal, "alarm") else None
        for p in procs:
            if p.poll() is None:
                p.kill()
        for srv in servers:
            srv.shutdown()
            srv.server_close()
        if real:
            shutil.rmtree(Path(args.rootfs) / "tmp" / "renderer-run", ignore_errors=True)
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs")
    ap.add_argument("--server")
    args = ap.parse_args()
    if args.rootfs and not args.server:
        ap.error("--rootfs richiede --server")
    run(args)
    print()
    if failures:
        print("Renderer UPnP: %d prove fallite: %s" % (len(failures), "; ".join(failures)))
        return 1
    print("Renderer UPnP: tutte le prove superate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
