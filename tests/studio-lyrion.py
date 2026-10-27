#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reference Studio contro un Lyrion Music Server VERO.

Le CGI del Reference Studio (studio-api.json, studio-copertina) girano con
busybox sh e la vera sweetspot-lms/lms_json, che parlano in JSON-RPC
(/jsonrpc.js) e HTTP (/music/ID/cover_*) con un Lyrion reale, su una
libreria di prova generata qui (FLAC sintetici con sox: nessun file con
copyright) e con un player Squeezebox finto (squeezelite senza scheda audio).
Si lancia da tests/prova-studio-lyrion.sh, che prepara i container:

    LYRION_HOST=lms LYRION_PLAYER_MAC=02:00:00:00:00:01 python3 tests/studio-lyrion.py
    python3 tests/studio-lyrion.py --genera /music      # solo la libreria

Senza LYRION_HOST le prove vengono saltate.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "board/sweetspot/rootfs-overlay"
HOST = os.environ.get("LYRION_HOST", "")
PORT = os.environ.get("LYRION_PORT", "9000")
MAC = os.environ.get("LYRION_PLAYER_MAC", "02:00:00:00:00:01")

# (cartella, artista, album, anno, genere, [(titolo, secondi)], copertina)
LIBRERIA = [
    ("Trio Prova/Alpha Prova", "Trio Prova", "Alpha Prova", "2001", "Jazz Prova",
     [("Primo Alpha", 40), ("Secondo Alpha", 40)], True),
    ("Cafe Prova/Beta Prova", "Café Prova", "Beta Prova", "2005", "Rock Prova",
     [("È sera", 40)], False),
]


def png(path, lato=64):
    """PNG a tinta unita con la sola libreria standard."""
    riga = b"\x00" + bytes((40, 90, 160)) * lato
    dati = zlib.compress(riga * lato)

    def chunk(tipo, d):
        c = struct.pack(">I", len(d)) + tipo + d
        return c + struct.pack(">I", zlib.crc32(tipo + d) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n"
                           + chunk(b"IHDR", struct.pack(">IIBBBBB", lato, lato, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", dati) + chunk(b"IEND", b""))


def genera(dest):
    dest = Path(dest)
    for cartella, artista, album, anno, genere, brani, copertina in LIBRERIA:
        d = dest / cartella
        d.mkdir(parents=True, exist_ok=True)
        cover = d / "cover.png"
        if copertina:
            png(cover)
        for n, (titolo, sec) in enumerate(brani, 1):
            wav = d / ("%02d.wav" % n)
            subprocess.run(["sox", "-n", "-r", "44100", "-b", "16", "-c", "2", str(wav),
                            "synth", str(sec), "sine", str(220 * n)], check=True)
            cmd = ["flac", "-s", "-f", "-o", str(d / ("%02d.flac" % n)),
                   "--tag=TITLE=" + titolo, "--tag=ARTIST=" + artista,
                   "--tag=ALBUMARTIST=" + artista, "--tag=ALBUM=" + album,
                   "--tag=DATE=" + anno, "--tag=GENRE=" + genere,
                   "--tag=TRACKNUMBER=%d" % n]
            if copertina:
                cmd.append("--picture=" + str(cover))
            subprocess.run(cmd + [str(wav)], check=True)
            wav.unlink()
        cover.unlink(missing_ok=True)
    for p in dest.rglob("*"):
        p.chmod(0o755 if p.is_dir() else 0o644)
    dest.chmod(0o755)


def rpc(player, *cmd):
    req = urllib.request.Request(
        "http://%s:%s/jsonrpc.js" % (HOST, PORT),
        json.dumps({"id": 1, "method": "slim.request", "params": [player, list(cmd)]}).encode(),
        {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)["result"]


def attendi(cosa, condizione, secondi=120):
    fine = time.time() + secondi
    ultimo = None
    while time.time() < fine:
        try:
            ultimo = condizione()
            if ultimo:
                return ultimo
        except Exception as e:  # Lyrion in avvio
            ultimo = e
        time.sleep(1)
    raise AssertionError("tempo scaduto: %s (ultimo: %r)" % (cosa, ultimo))


def prepara_lyrion():
    attendi("Lyrion risponde", lambda: rpc("", "serverstatus", 0, 1))
    mediadirs = rpc("", "pref", "mediadirs", "?").get("_p2")
    if not mediadirs:
        rpc("", "pref", "mediadirs", "/music")
    rpc("", "rescan")
    attendi("scansione finita", lambda: "rescan" not in rpc("", "serverstatus", 0, 1))
    attendi("album in libreria", lambda: rpc("", "albums", 0, 10).get("count") == len(LIBRERIA))
    attendi("player connesso", lambda: any(p["playerid"] == MAC
                                           for p in rpc("", "players", 0, 10).get("players_loop", [])))


class StudioLyrionTests(unittest.TestCase):
    SID = "0123456789abcdef0123456789abcdef"
    SECRET = "tok123"
    # Gettone legato alla sessione, come lo calcola web.sh: sha256("sessione:<sid>:<segreto>")[:32].
    TOKEN = hashlib.sha256(("sessione:%s:%s" % (SID, SECRET)).encode()).hexdigest()[:32]

    @classmethod
    def setUpClass(cls):
        if not HOST:
            raise unittest.SkipTest("LYRION_HOST non impostato: serve un Lyrion vero")
        prepara_lyrion()
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-studio-lms-")
        root = cls.root = Path(cls.temp.name)
        (root / "run/web/sessioni").mkdir(parents=True)
        (root / "run/sweetspot.conf").write_text("MODALITA=completa\nPASSWORD_WEB=x\n")
        (root / "run/sweetspot.web").write_text("MODALITA=completa\nPASSWORD_WEB=x\n")
        (root / "run/web/sessioni" / cls.SID).write_text(str(2 ** 31))
        (root / "run/web.token").write_text(cls.SECRET + "\n")
        # lms_in_esecuzione guarda questo pid: il processo di prova e' vivo.
        (root / "run/lms.pid").write_text("%d\n" % os.getpid())
        # sweetspot-priv finto: esegue il comando (qui non c'e' separazione
        # di utenti) con sweetspot-lms vera nel PATH.
        priv = root / "priv"
        priv.write_text('#!/bin/sh\nexec "$@"\n')
        priv.chmod(0o755)
        bindir = root / "bin"
        bindir.mkdir()
        (bindir / "sweetspot-lms").symlink_to(OVERLAY / "usr/bin/sweetspot-lms")
        cls.env = dict(
            os.environ, GATEWAY_INTERFACE="CGI/1.1", HTTP_HOST="127.0.0.1", REMOTE_ADDR="127.0.0.1",
            PATH="%s:%s" % (bindir, os.environ["PATH"]),
            SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"), SWEETSPOT_RUN=str(root / "run"),
            SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
            SWEETSPOT_LOG=str(root / "log"), SWEETSPOT_PRIV=str(priv),
            SWEETSPOT_ASSETS=str(OVERLAY / "usr/share/sweetspot"),
            SWEETSPOT_LMS_HOST=HOST, SWEETSPOT_LMS_HTTP_PORT=PORT,
            SWEETSPOT_LMS_DATA=str(root / "lms"), LMS_CACHE_TTL="0")

    @classmethod
    def tearDownClass(cls):
        if HOST:
            cls.temp.cleanup()

    def setUp(self):
        # Ogni prova parte da una coda vuota.
        rpc(MAC, "playlist", "clear")
        rpc(MAC, "mixer", "volume", 50)

    def cgi(self, name, method="GET", query="", body=""):
        env = dict(self.env, REQUEST_METHOD=method, QUERY_STRING=query,
                   SCRIPT_NAME="/cgi-bin/" + name, REQUEST_URI="/cgi-bin/" + name,
                   CONTENT_LENGTH=str(len(body.encode())),
                   CONTENT_TYPE="application/x-www-form-urlencoded",
                   HTTP_COOKIE="sweetspot_sid=" + self.SID)
        if method == "POST":
            env["HTTP_X_SWEETSPOT_TOKEN"] = self.TOKEN
        script = OVERLAY / "usr/share/sweetspot/www/cgi-bin" / name
        r = subprocess.run(["busybox", "sh", str(script)], input=body.encode(),
                           capture_output=True, env=env, timeout=60)
        head, _, payload = r.stdout.partition(b"\r\n\r\n")
        if not payload and b"\n\n" in r.stdout:
            head, _, payload = r.stdout.partition(b"\n\n")
        status = 200
        for line in head.decode("utf-8", "replace").splitlines():
            if line.startswith("Status:"):
                status = int(line.split()[1])
        return status, head.decode("utf-8", "replace"), payload

    def api(self, query):
        status, _, body = self.cgi("studio-api.json", query=query)
        self.assertEqual(status, 200, body)
        return json.loads(body)["result"]

    def post(self, **campi):
        campi.setdefault("player", MAC)
        status, _, body = self.cgi("studio-api.json", "POST", body=urllib.parse.urlencode(campi))
        self.assertEqual(status, 200, body)
        return json.loads(body)

    def album(self, nome):
        r = self.api("op=albums&count=50&search=" + urllib.parse.quote(nome))
        self.assertEqual(len(r["albums_loop"]), 1, r)
        return r["albums_loop"][0]

    def stato(self):
        return self.api("op=stato&player=" + MAC)

    # --- Ricerca ------------------------------------------------------------
    def test_players_elenca_il_player_finto(self):
        r = self.api("op=players")
        self.assertEqual([p["playerid"] for p in r["players_loop"]], [MAC])
        self.assertTrue(r["players_loop"][0]["name"])

    def test_albums_campi_usati_da_studio_js(self):
        r = self.api("op=albums&count=48")
        self.assertEqual(int(r["count"]), 2)
        a = self.album("Alpha")
        self.assertEqual((a["album"], a["artist"], str(a["year"])), ("Alpha Prova", "Trio Prova", "2001"))
        self.assertTrue(a["id"])
        self.assertIn("artwork_track_id", a)

    def test_ricerca_con_accenti_e_parole_multiple(self):
        r = self.api("op=albums&count=50&search=" + urllib.parse.quote("Café Prova"))
        self.assertEqual([a["album"] for a in r["albums_loop"]], ["Beta Prova"])
        r = self.api("op=titles&count=50&search=" + urllib.parse.quote("è sera"))
        self.assertEqual([t["title"] for t in r["titles_loop"]], ["È sera"])
        r = self.api("op=albums&count=50&search=nonesistente")
        self.assertEqual(r.get("albums_loop", []), [])

    def test_artisti_generi_playlist(self):
        r = self.api("op=artists&count=50")
        self.assertEqual(sorted(a["artist"] for a in r["artists_loop"]), ["Café Prova", "Trio Prova"])
        r = self.api("op=genres&count=50")
        self.assertEqual(sorted(g["genre"] for g in r["genres_loop"]), ["Jazz Prova", "Rock Prova"])
        g = next(g for g in r["genres_loop"] if g["genre"] == "Rock Prova")
        r = self.api("op=albums&count=50&genre_id=%s" % g["id"])
        self.assertEqual([a["album"] for a in r["albums_loop"]], ["Beta Prova"])
        # Senza playlist Lyrion risponde {} (niente "count"): studio.js lo gestisce.
        self.assertEqual(self.api("op=playlists&count=10").get("playlists_loop", []), [])

    def test_brani_di_un_album_in_ordine_con_i_campi_usati(self):
        a = self.album("Alpha")
        r = self.api("op=titles&count=50&album_id=%s" % a["id"])
        titoli = r["titles_loop"]
        self.assertEqual([t["title"] for t in titoli], ["Primo Alpha", "Secondo Alpha"])
        t = titoli[0]
        self.assertEqual((t["artist"], t["album"]), ("Trio Prova", "Alpha Prova"))
        self.assertAlmostEqual(float(t["duration"]), 40, delta=1)
        self.assertTrue(t["coverid"])
        self.assertTrue(t["albumartist"], "studio.js mostra albumartist nell'intestazione dell'album")

    def test_cartelle(self):
        r = self.api("op=cartella")
        self.assertTrue(r["folder_loop"], r)
        self.assertIn("Trio Prova", [f["filename"] for f in r["folder_loop"]])

    # --- Copertine ----------------------------------------------------------
    def test_copertina_vera_e_segnaposto(self):
        t = self.api("op=titles&count=50&album_id=%s" % self.album("Alpha")["id"])["titles_loop"][0]
        status, head, img = self.cgi("studio-copertina", query="id=%s&s=200" % t["coverid"])
        self.assertEqual(status, 200)
        self.assertIn("image/jpeg", head)
        self.assertEqual(img[:3], b"\xff\xd8\xff")
        status, head, img = self.cgi("studio-copertina", query="id=0&s=200")
        self.assertEqual(status, 200)
        self.assertIn("image/", head)
        self.assertTrue(img)

    # --- Comandi al player --------------------------------------------------
    def test_carica_album_coda_e_riproduzione(self):
        a = self.album("Alpha")
        self.post(op="carica", kind="album", id=a["id"], mode="load")
        s = attendi("in riproduzione", lambda: (lambda s: s if s.get("mode") == "play" else None)(self.stato()))
        self.assertEqual(s["playlist_tracks"], 2)
        self.assertEqual(s["playlist_loop"][0]["title"], "Primo Alpha")
        coda = self.api("op=coda&player=%s&start=0&count=50" % MAC)
        self.assertEqual([t["title"] for t in coda["playlist_loop"]], ["Primo Alpha", "Secondo Alpha"])
        b = self.api("op=titles&count=50&album_id=%s" % self.album("Beta")["id"])["titles_loop"][0]
        self.post(op="carica", kind="track", id=b["id"], mode="add")
        coda = self.api("op=coda&player=%s&start=0&count=50" % MAC)
        self.assertEqual(len(coda["playlist_loop"]), 3)

    def test_trasporto_volume_seek_e_coda(self):
        a = self.album("Alpha")
        self.post(op="carica", kind="album", id=a["id"], mode="load")
        # Il brano deve essere davvero in corso (non solo in caricamento).
        attendi("brano in corso", lambda: float(self.stato().get("time", 0)) > 1)
        # Pausa e ripresa sono idempotenti: si ripetono finche' il player segue.
        attendi("in pausa", lambda: self.post(op="pausa", v="1") and self.stato().get("mode") == "pause", 30)
        attendi("riparte", lambda: self.post(op="pausa", v="0") and self.stato().get("mode") == "play", 30)
        self.post(op="volume", v="37")
        self.assertEqual(int(self.stato()["mixer volume"]), 37)
        self.post(op="seek", v="20")
        attendi("posizione", lambda: float(self.stato().get("time", 0)) >= 20)
        self.post(op="avanti")
        attendi("secondo brano", lambda: int(self.stato()["playlist_cur_index"]) == 1)
        self.post(op="indietro")
        attendi("primo brano", lambda: int(self.stato()["playlist_cur_index"]) == 0)
        self.post(op="salta", v="1")
        attendi("salto", lambda: int(self.stato()["playlist_cur_index"]) == 1)
        self.post(op="togli", v="0")
        attendi("brano tolto", lambda: int(self.stato()["playlist_tracks"]) == 1)
        self.post(op="stop")
        attendi("fermo", lambda: self.stato().get("mode") == "stop")
        self.post(op="play")
        attendi("play", lambda: self.stato().get("mode") == "play")
        self.post(op="svuota")
        attendi("coda vuota", lambda: int(self.stato().get("playlist_tracks", 0)) == 0)

    def test_zona_lascia_il_gruppo(self):
        self.post(op="zona", to="-")
        self.assertEqual(rpc(MAC, "sync", "?").get("_sync", "-"), "-")

    def test_parametro_non_valido_non_arriva_a_lyrion(self):
        status, _, _ = self.cgi("studio-api.json", "POST", body="op=volume&v=101&player=" + MAC)
        self.assertEqual(status, 400)


def pozzo():
    """Scheda audio finta con tempo reale: legge da stdin a 44,1 kHz/16 bit/
    stereo (176400 byte al secondo), come farebbe un DAC. Senza questo
    squeezelite consuma i brani alla velocita' del processore e Lyrion li
    vede finiti in un attimo."""
    letti = 0
    inizio = time.monotonic()
    while True:
        blocco = sys.stdin.buffer.read(17640)
        if not blocco:
            return
        letti += len(blocco)
        attesa = inizio + letti / 176400.0 - time.monotonic()
        if attesa > 0:
            time.sleep(attesa)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--genera":
        genera(sys.argv[2])
    elif sys.argv[1:] == ["--pozzo"]:
        pozzo()
    else:
        unittest.main()
