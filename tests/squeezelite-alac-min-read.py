#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0008 di Squeezelite: il decoder ALAC parte solo con un pacchetto intero.

Upstream il decoder ffmpeg viene chiamato appena streambuf contiene READ_SIZE
(16 KB), ma un pacchetto ALAC (4096 frame) puo' essere piu' grande: se il
buffer si svuota a meta' pacchetto, _read_data restituisce 0, ffmpeg lo prende
per fine file e scarta il pacchetto troncato ("Packet corrupt"). Il caso
alac-192000-24 della prova Lyrion lo mostrava di tanto in tanto.

Applica la patch vera a un estratto fedele di ffmpeg.c, lo compila e verifica
che la lettura minima di alc copra il pacchetto piu' grande (misurato sulle
fixture ALAC vere a 192 kHz/24 bit e calcolato per 32 bit) piu' un blocco
di lettura di AVIO, e che wma resti com'era. Servono un compilatore C e Git,
nessuna rete.
"""

import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import audio_verification as verifier  # noqa: E402

FIXTURE = ROOT / "tests/fixtures/squeezelite-ffmpeg-register.c"
PATCH = ROOT / "patches/squeezelite/0008-alac-whole-packet-before-decode.patch"
READ_SIZE = 4096 * 4
# pacchetto ALAC stereo a 32 bit non compresso: 4096 frame x 2 canali x 4 byte
# piu' l'intestazione del pacchetto (pochi byte; 64 e' un margine largo)
MAX_STEREO_PACKET = 4096 * 2 * 4 + 64

STUBS = r'''
#include <stdio.h>
#include <string.h>
typedef unsigned char u8_t;
typedef int decode_state;
struct codec {
	char id;
	char *types;
	unsigned min_read_bytes;
	unsigned min_space;
	void (*open)(u8_t sample_size, u8_t sample_rate, u8_t channels, u8_t endianness);
	void (*close)(void);
	decode_state (*decode)(void);
};
#define LOG_INFO(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
static void ff_open_wma(u8_t s, u8_t r, u8_t c, u8_t e) { (void)s; (void)r; (void)c; (void)e; }
static void ff_open_alac(u8_t s, u8_t r, u8_t c, u8_t e) { (void)s; (void)r; (void)c; (void)e; }
static void ff_close(void) {}
static decode_state ff_decode(void) { return 0; }
'''

HARNESS = r'''
#include "ffmpeg.c"
int main(void) {
	printf("%u %u\n", register_ff("wma")->min_read_bytes, register_ff("alc")->min_read_bytes);
	return 0;
}
'''


def max_packet(m4a):
    """Il pacchetto piu' grande della tabella stsz di un .m4a ALAC."""
    data = m4a.read_bytes()
    at = data.index(b"stsz") + 4  # dopo il tipo: versione/flag, dimensione fissa, numero
    fixed, count = struct.unpack(">4xII", data[at:at + 12])
    if fixed:
        return fixed
    return max(struct.unpack(">%dI" % count, data[at + 12:at + 12 + 4 * count]))


def compile_register(work, patched):
    shutil.copyfile(FIXTURE, work / "ffmpeg.c")
    if patched:
        subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=work, check=True)
        subprocess.run(["git", "apply", str(PATCH)], cwd=work, check=True)
    (work / "stubs.h").write_text(STUBS, encoding="utf-8")
    (work / "harness.c").write_text(HARNESS, encoding="utf-8")
    binary = work / "register"
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=gnu99", "-Wall", "-Werror", "-I", str(work),
        str(work / "harness.c"), "-o", str(binary)], check=True)
    out = subprocess.run([str(binary)], text=True, capture_output=True, check=True).stdout
    return tuple(int(v) for v in out.split())


class AlacMinRead(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-alac-min-read-")
        base = Path(cls.temp.name)
        for name in ("upstream", "patched", "fixtures"):
            (base / name).mkdir()
        cls.upstream = compile_register(base / "upstream", patched=False)
        cls.patched = compile_register(base / "patched", patched=True)
        sources, _ = verifier.generate_codec_fixtures(base / "fixtures", 192000, 24, "alac")
        cls.packet_192_24 = max(max_packet(source) for source in sources)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_upstream_legge_meno_di_un_pacchetto(self):
        # il difetto: a 192 kHz/24 bit un pacchetto non sta in READ_SIZE
        self.assertEqual(self.upstream, (READ_SIZE, READ_SIZE))
        self.assertGreater(self.packet_192_24, READ_SIZE)

    def test_alac_aspetta_un_pacchetto_intero_piu_un_blocco_avio(self):
        _, alc = self.patched
        self.assertGreaterEqual(alc, self.packet_192_24 + READ_SIZE)
        self.assertGreaterEqual(alc, MAX_STEREO_PACKET + READ_SIZE)

    def test_alac_resta_ben_sotto_streambuf(self):
        # streambuf predefinito: 2 MB (STREAMBUF_SIZE); il decoder deve poter partire
        self.assertLessEqual(self.patched[1], 2 * 1024 * 1024 // 8)

    def test_wma_invariato(self):
        self.assertEqual(self.patched[0], self.upstream[0])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
