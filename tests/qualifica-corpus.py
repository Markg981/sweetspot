#!/usr/bin/env python3
"""Il generatore di corpus produce FLAC con struttura e tag corretti.

Non misura nulla di Lyrion: verifica solo lo strumento (il benchmark vero si
fa con scripts/qualifica-libreria.py misura contro un Lyrion reale).
"""
import importlib.util
import json
import os
import struct
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("q", os.path.join(ROOT, "scripts", "qualifica-libreria.py"))
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


def read_tags(path):
    blocks, _ = q.flac_blocks(open(path, "rb").read())
    body = next(b for kind, _, b in blocks if kind == 4)
    vendor = struct.unpack("<I", body[:4])[0]
    pos = 4 + vendor
    count = struct.unpack("<I", body[pos:pos + 4])[0]
    pos += 4
    tags = []
    for _ in range(count):
        size = struct.unpack("<I", body[pos:pos + 4])[0]
        tags.append(body[pos + 4:pos + 4 + size].decode("utf-8"))
        pos += 4 + size
    return tags


class Corpus(unittest.TestCase):
    def test_corpus(self):
        with tempfile.TemporaryDirectory() as d:
            man = q.make_corpus(d, 60, 7)
            self.assertEqual(len(man["file"]), 60)
            first = man["file"][0]
            tags = read_tags(os.path.join(d, first["path"]))
            self.assertIn("ALBUM=" + first["album"], tags)
            for name in man["attese"]["corrotti"]:
                self.assertTrue(os.path.exists(os.path.join(d, "_corrotti", name)))
            self.assertEqual(os.path.getsize(os.path.join(d, "_corrotti", "vuoto.flac")), 0)
            # stessa seed, stesso corpus
            with tempfile.TemporaryDirectory() as d2:
                man2 = q.make_corpus(d2, 60, 7)
                self.assertEqual(man["file"], man2["file"])
            # il manifest e' JSON valido con Unicode intatto
            json.load(open(os.path.join(d, "manifest.json"), encoding="utf-8"))

    def test_senza_lyrion_nessun_numero(self):
        class Fake(q.Lyrion):
            def req(self, *a, **k):
                return {}
        args = type("A", (), dict(url="http://x", user="", password="", out="-", nota="", wipe=False,
                                  termini=None, ripetizioni=1, poll=0, limite=1))()
        orig = q.Lyrion
        q.Lyrion = lambda *a, **k: Fake(*a, **k)
        try:
            with self.assertRaises(SystemExit):
                q.measure(args)
        finally:
            q.Lyrion = orig


if __name__ == "__main__":
    unittest.main()
