#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0003 di Squeezelite: con -H il ripiego hw: -> plughw: e' vietato.

Applica la patch vera (la parte di output_alsa.c) a un estratto fedele del
sorgente upstream, lo compila con un'API ALSA simulata che rifiuta la
frequenza su hw: e verifica due casi: senza -H il ripiego su plughw: resta
(comportamento upstream invariato), con -H l'apertura fallisce con un
errore esplicito e il dispositivo non diventa mai plughw:. Servono un
compilatore C e Git, nessuna rete.
"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/squeezelite-alsa-rate.c"
PATCH = ROOT / "patches/squeezelite/0003-strict-hw-no-plughw-fallback.patch"

STUBS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8_t;
typedef struct snd_pcm_s snd_pcm_t;
typedef struct snd_pcm_hw_params_s snd_pcm_hw_params_t;
#define LOG_ERROR(...) do { fprintf(stderr, "ERROR "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOG_INFO(...) do { fprintf(stderr, "INFO "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
static const char *current_dev;
static const char *snd_strerror(int e) { (void)e; return "Invalid argument"; }
static int snd_pcm_close(snd_pcm_t *p) { (void)p; return 0; }
static int snd_pcm_hw_params_set_rate_resample(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned v) { (void)p; (void)h; (void)v; return 0; }
/* Il DAC simulato rifiuta la frequenza su hw: e la accetta su plughw:. */
static int snd_pcm_hw_params_set_rate(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned r, int d) {
	(void)p; (void)h; (void)r; (void)d;
	return strncmp(current_dev, "hw:", 3) ? 0 : -22;
}
'''

HARNESS = r'''
#include "output_alsa.c"
int main(int argc, char **argv) {
	(void)argv;
	if (argc > 1) alsa_strict_hw = true;
	strcpy(alsa.device, "hw:CARD=Test,DEV=0");
	current_dev = alsa.device;
	/* Come in alsa_open: il nome completo, da cui il ripiego fa "plug" + nome. */
	int err = open_rate("hw:CARD=Test,DEV=0", 96000);
	printf("%d %s\n", err, alsa.device);
	return 0;
}
'''


class StrictHw(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-strict-hw-")
        cls.work = Path(cls.temp.name)
        shutil.copyfile(FIXTURE, cls.work / "output_alsa.c")
        subprocess.run(["git", "apply", "--check", "--include=output_alsa.c", str(PATCH)],
                       cwd=cls.work, check=True)
        subprocess.run(["git", "apply", "--include=output_alsa.c", str(PATCH)], cwd=cls.work, check=True)
        (cls.work / "stubs.h").write_text(STUBS, encoding="utf-8")
        (cls.work / "harness.c").write_text(HARNESS, encoding="utf-8")
        cls.binary = cls.work / "rate"
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=gnu99", "-Wall", "-Werror", "-Wno-unused-function", "-I", str(cls.work),
            str(cls.work / "harness.c"), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_open(self, *args):
        return subprocess.run([str(self.binary), *args], text=True, capture_output=True, check=True)

    def test_senza_h_resta_il_ripiego_upstream(self):
        run = self.run_open()
        self.assertEqual(run.stdout.strip(), "0 plughw:CARD=Test,DEV=0")
        self.assertIn("reopening device", run.stderr)

    def test_con_h_si_ferma_con_errore_esplicito(self):
        run = self.run_open("-H")
        self.assertEqual(run.stdout.strip(), "-22 hw:CARD=Test,DEV=0", "non deve passare a plughw:")
        self.assertIn("ERROR", run.stderr)
        self.assertIn("strict hw mode (-H)", run.stderr)
        self.assertNotIn("reopening device", run.stderr)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
