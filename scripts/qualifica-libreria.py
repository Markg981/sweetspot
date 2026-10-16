#!/usr/bin/env python3
"""Qualificazione della libreria musicale: corpus sintetico e misure su Lyrion.

  corpus DIR [--files N] [--seed S]   crea un corpus FLAC/WAV con tag, Unicode e
                                      file corrotti, piu' manifest.json
  misura URL [--user U --password P]  fa una scansione completa su un Lyrion
                                      VERO e misura scansione, ricerca, liste

Il comando "misura" parla solo JSON-RPC (/jsonrpc.js) col server indicato: non
contiene un server finto e non produce numeri se Lyrion non risponde. I
risultati vanno nel JSON scritto con --out e vanno letti insieme a "ambiente".
Vedi docs/qualificazione.md.
"""
import argparse
import base64
import json
import os
import platform
import random
import statistics
import struct
import sys
import time
import unicodedata
import urllib.request

SAMPLE_RATE = 44100


def tempo_lms(v):
    """totaltime di rescanprogress in LMS 9.1.1 e' HH:MM:SS (Queries.pm);
    si accetta anche un numero di secondi."""
    if v in (None, ""):
        return 0
    secs = 0
    try:
        for p in str(v).split(":"):
            secs = secs * 60 + int(p)
    except ValueError:
        return 0
    return secs


def flac_blocks(data):
    """Scorre i blocchi di metadati di un FLAC: (tipo, ultimo, corpo), resto."""
    assert data[:4] == b"fLaC"
    pos, out = 4, []
    while True:
        head = data[pos]
        size = int.from_bytes(data[pos + 1:pos + 4], "big")
        out.append((head & 0x7F, bool(head & 0x80), data[pos + 4:pos + 4 + size]))
        pos += 4 + size
        if head & 0x80:
            return out, data[pos:]


def vorbis_comment(tags):
    vendor = b"sweetspot-qualifica"
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(tags))
    for k, v in tags:
        item = f"{k}={v}".encode("utf-8")
        body += struct.pack("<I", len(item)) + item
    return body


def flac_with_tags(base, tags):
    """Sostituisce il VORBIS_COMMENT del FLAC base: il flusso audio non cambia."""
    blocks, audio = flac_blocks(base)
    blocks = [b for b in blocks if b[0] != 4]
    blocks.append((4, False, vorbis_comment(tags)))
    out = b"fLaC"
    for i, (kind, _, body) in enumerate(blocks):
        last = 0x80 if i == len(blocks) - 1 else 0
        out += bytes([kind | last]) + len(body).to_bytes(3, "big") + body
    return out + audio


def minimal_flac():
    """FLAC valido di 4096 campioni di silenzio, costruito a mano (senza flac)."""
    streaminfo = struct.pack(">HH", 4096, 4096) + (0).to_bytes(3, "big") + (0).to_bytes(3, "big")
    packed = (SAMPLE_RATE << 44) | (0 << 41) | (15 << 36) | 4096
    streaminfo += packed.to_bytes(8, "big") + bytes(16)
    # Frame: sync, blocco 4096, 44.1 kHz, mono, 16 bit; sottoframe CONSTANT = 0.
    header = bytes([0xFF, 0xF8, 0xC9, 0x08, 0x00])
    header += bytes([crc8(header)])
    sub = bytes([0x00, 0x00, 0x00])
    frame = header + sub
    frame += crc16(frame).to_bytes(2, "big")
    return b"fLaC" + bytes([0x80]) + len(streaminfo).to_bytes(3, "big") + streaminfo + frame


def crc8(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def crc16(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def wav_silence(frames=2205):
    data = bytes(frames * 4)
    fmt = struct.pack("<HHIIHH", 1, 2, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 16)
    return (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " +
            struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data)


UNICODE_ARTISTS = [
    "Björk", "Sigur Rós", "Motörhead", "Мусоргский", "坂本龍一", "Ólafur Arnalds",
    "Beyoncé", "Sinéad O'Connor", "אריק איינשטיין", "فيروز", "Μίκης Θεοδωράκης",
    "AC/DC", "Guns N' Roses", "Å", "Ænima", "Ñandú", "Lluís Llach",
]


def nfd(text):
    return unicodedata.normalize("NFD", text)


def make_corpus(root, files, seed):
    rng = random.Random(seed)
    base = minimal_flac()
    os.makedirs(root, exist_ok=True)
    artists = [f"Artista {i:04d}" for i in range(max(10, files // 25))] + UNICODE_ARTISTS
    manifest = {"seed": seed, "file": [], "attese": {}}
    per_album = 12
    created = 0
    album_no = 0
    while created < files:
        artist = rng.choice(artists)
        album = f"Album {album_no:05d} " + rng.choice(["", "(Deluxe)", "\u2014 Live", "\u00e9tude"])
        album_no += 1
        folder = os.path.join(root, nfd(artist) if album_no % 7 == 0 else artist, album.strip())
        os.makedirs(folder, exist_ok=True)
        for n in range(1, min(per_album, files - created) + 1):
            title = f"Brano {created:06d} " + rng.choice(["", "\U0001f3b5", "\u2019s", "(feat. X)"])
            tags = [("ARTIST", artist), ("ALBUMARTIST", artist), ("ALBUM", album.strip()),
                    ("TITLE", title.strip()), ("TRACKNUMBER", str(n)), ("DATE", str(1960 + created % 64))]
            if rng.random() < 0.05:
                tags = [t for t in tags if t[0] != "ARTIST"]
            if rng.random() < 0.02:
                tags.append(("ARTIST", "Secondo Artista"))
            path = os.path.join(folder, f"{n:02d} - {created:06d}.flac")
            with open(path, "wb") as fh:
                fh.write(flac_with_tags(base, tags))
            manifest["file"].append({"path": os.path.relpath(path, root), "artist": artist,
                                     "album": album.strip(), "title": title.strip()})
            created += 1
    # Casi limite: ogni file dichiarato "corrotto" non deve far fermare la scansione.
    bad = os.path.join(root, "_corrotti")
    os.makedirs(bad, exist_ok=True)
    good = flac_with_tags(base, [("ARTIST", "Corrotto"), ("TITLE", "troncato")])
    cases = {
        "troncato.flac": good[:len(good) // 2],
        "intestazione-azzerata.flac": bytes(64),
        "vuoto.flac": b"",
        "non-e-un-flac.flac": b"questo non e' audio" * 50,
        "wav-troncato.wav": wav_silence()[:30],
        "tag-enorme.flac": flac_with_tags(base, [("TITLE", "x" * 60000), ("ARTIST", "Enorme")]),
    }
    for name, content in cases.items():
        with open(os.path.join(bad, name), "wb") as fh:
            fh.write(content)
    with open(os.path.join(root, "audio-senza-tag.wav"), "wb") as fh:
        fh.write(wav_silence())
    manifest["attese"] = {
        "corrotti": sorted(cases), "tracce_valide_minime": created,
        "note": "i file in _corrotti non devono interrompere la scansione; "
                "i tag mancanti diventano Unknown Artist",
    }
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
    return manifest


class Lyrion:
    def __init__(self, url, user="", password="", timeout=60):
        self.url = url.rstrip("/") + "/jsonrpc.js"
        self.timeout = timeout
        self.auth = None
        if user or password:
            self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def req(self, *cmd, player=""):
        body = json.dumps({"id": 1, "method": "slim.request", "params": [player, list(cmd)]}).encode()
        request = urllib.request.Request(self.url, body, {"Content-Type": "application/json"})
        if self.auth:
            request.add_header("Authorization", self.auth)
        with urllib.request.urlopen(request, timeout=self.timeout) as r:
            return json.load(r).get("result", {})


def percentiles(values):
    values = sorted(values)
    if not values:
        return {}
    pick = lambda q: values[min(len(values) - 1, int(q * len(values)))]
    return {"n": len(values), "min_ms": round(values[0], 1), "p50_ms": round(pick(0.5), 1),
            "p95_ms": round(pick(0.95), 1), "max_ms": round(values[-1], 1),
            "media_ms": round(statistics.fmean(values), 1)}


def timed(fn):
    start = time.perf_counter()
    result = fn()
    return (time.perf_counter() - start) * 1000, result


def wait_scan(lms, poll, limit):
    """Aspetta la fine della scansione; restituisce secondi e curva di avanzamento."""
    start = time.monotonic()
    curve = []
    while time.monotonic() - start < limit:
        state = lms.req("rescanprogress")
        running = int(state.get("rescan", 0)) == 1
        curve.append([round(time.monotonic() - start, 1), state.get("steps", ""),
                      tempo_lms(state.get("totaltime"))])
        if not running:
            return time.monotonic() - start, curve
        time.sleep(poll)
    raise TimeoutError(f"scansione non terminata entro {limit} s")


def measure(args):
    lms = Lyrion(args.url, args.user, args.password)
    info = lms.req("serverstatus", 0, 0)
    if "version" not in info:
        raise SystemExit("il server non ha risposto come Lyrion (nessuna versione): nessuna misura")
    out = {"ambiente": {"lyrion": info["version"], "host": platform.node(),
                        "python": platform.python_version(), "data": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                        "nota": args.nota},
           "prima": {k: info.get(k) for k in ("info total songs", "info total albums", "info total artists")}}
    lms.req("wipecache" if args.wipe else "rescan", *(() if args.wipe else ("full",)))
    secs, curve = wait_scan(lms, args.poll, args.limite)
    after = lms.req("serverstatus", 0, 0)
    songs = int(after.get("info total songs", 0))
    out["scansione"] = {"secondi": round(secs, 1), "brani": songs,
                        "brani_al_secondo": round(songs / secs, 1) if secs else None,
                        "albums": after.get("info total albums"), "artists": after.get("info total artists"),
                        "curva": curve[:: max(1, len(curve) // 60)]}
    terms = args.termini or ["brano", "album", "artista", "bj\u00f6rk", "\u5742\u672c", "xyz-assente"]
    rows = {}
    for term in terms:
        ms = [timed(lambda t=term: lms.req("search", 0, 20, f"term:{t}"))[0] for _ in range(args.ripetizioni)]
        rows[term] = percentiles(ms)
    out["ricerca"] = rows
    lists = {}
    for name, cmd in (("artists", ("artists", 0, 50)), ("albums", ("albums", 0, 50, "sort:album")),
                      ("albums_profondo", ("albums", max(0, songs // 24), 50, "sort:album")),
                      ("titles", ("titles", 0, 50))):
        lists[name] = percentiles([timed(lambda c=cmd: lms.req(*c))[0] for _ in range(args.ripetizioni)])
    out["liste"] = lists
    out["scartati"] = lms.req("rescanprogress").get("lastscanfailure", "")
    json.dump(out, sys.stdout if args.out == "-" else open(args.out, "w"), ensure_ascii=False, indent=1)
    if args.out != "-":
        print(f"scritto {args.out}: {songs} brani, scansione {secs:.1f} s")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("corpus")
    c.add_argument("dir")
    c.add_argument("--files", type=int, default=50000)
    c.add_argument("--seed", type=int, default=1)
    m = sub.add_parser("misura")
    m.add_argument("url")
    m.add_argument("--user", default="")
    m.add_argument("--password", default=os.environ.get("LYRION_PASSWORD", ""))
    m.add_argument("--out", default="-")
    m.add_argument("--nota", default="")
    m.add_argument("--wipe", action="store_true", help="wipecache invece di rescan full")
    m.add_argument("--termini", nargs="*")
    m.add_argument("--ripetizioni", type=int, default=15)
    m.add_argument("--poll", type=float, default=2.0)
    m.add_argument("--limite", type=float, default=6 * 3600)
    args = p.parse_args()
    if args.cmd == "corpus":
        manifest = make_corpus(args.dir, args.files, args.seed)
        print(f"{len(manifest['file'])} file validi + {len(manifest['attese']['corrotti'])} corrotti in {args.dir}")
    else:
        measure(args)


if __name__ == "__main__":
    main()
