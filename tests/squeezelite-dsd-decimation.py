#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0004 di Squeezelite: DSD -> PCM alla frequenza che il DAC accetta.

Estrae dalla patch vera il file dsd_decim.h (lo stadio di decimazione), lo
compila con un compilatore C e verifica, per un DAC che accetta al massimo
192 kHz (e per uno che accetta 384 kHz):
  - la scelta della frequenza: DSD64 -> 176,4 kHz, DSD128 -> 176,4 kHz,
    DSD256 -> 176,4 kHz; con 352,8 kHz accettata non si decima;
  - il numero di campioni e il segnale: un tono a 1 kHz resta invariato, un
    tono a 160 kHz (che ripiegherebbe a 16 kHz) e' attenuato di oltre 60 dB;
  - lo stato e' continuo fra blocchi di lunghezza qualsiasi (stesso risultato
    di un'unica chiamata);
  - il margine di -3 dB evita il clipping a 32 bit di un picco del 130%.
Servono un compilatore C e Git, nessuna rete.
"""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/squeezelite/0004-dsd-pcm-decimation-and-headroom.patch"

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#define MAX_SUPPORTED_SAMPLERATES 20
#include "dsd_decim.h"

static const unsigned dac192[] = {192000, 176400, 96000, 88200, 48000, 44100, 0};
static const unsigned dac384[] = {384000, 352800, 192000, 176400, 96000, 88200, 48000, 44100, 0};

static double tone_amplitude(const float *x, unsigned n, double f, double fs) {
	double re = 0, im = 0;
	unsigned i, from = n / 2; /* dopo il transitorio */
	for (i = from; i < n; i++) {
		re += x[i] * cos(2 * M_PI * f * i / fs);
		im += x[i] * sin(2 * M_PI * f * i / fs);
	}
	return 2 * sqrt(re * re + im * im) / (n - from);
}

int main(int argc, char **argv) {
	(void)argc;
	if (!strcmp(argv[1], "stages")) {
		unsigned rate = (unsigned)atoi(argv[2]);
		printf("%u\n", dsd_decim_stages_for(rate, !strcmp(argv[3], "192") ? dac192 : dac384));
		return 0;
	}
	if (!strcmp(argv[1], "tone")) {
		double f = atof(argv[2]);
		unsigned chunk = (unsigned)atoi(argv[3]);
		const unsigned n = 352800, stages = 1;
		float *in = malloc(n * sizeof(float)), *a = malloc(n * sizeof(float)), *b = malloc(n * sizeof(float));
		dsd_decim c1, c2;
		unsigned i, na = 0, nb = 0, pos;
		for (i = 0; i < n; i++) in[i] = (float)sin(2 * M_PI * f * i / 352800.0);
		dsd_decim_reset(&c1, stages);
		dsd_decim_reset(&c2, stages);
		memcpy(a, in, n * sizeof(float));
		na = dsd_decim_run(&c1, 0, a, n);
		for (pos = 0; pos < n; ) {
			unsigned len = chunk < n - pos ? chunk : n - pos;
			memcpy(b + nb, in + pos, len * sizeof(float));
			nb += dsd_decim_run(&c2, 0, b + nb, len);
			pos += len;
		}
		printf("%u %u %d %.6f\n", na, nb, memcmp(a, b, na * sizeof(float)) == 0, tone_amplitude(a, na, f, 176400.0));
		return 0;
	}
	if (!strcmp(argv[1], "headroom")) {
		double peak = 1.3 * DSD_PCM_FULLSCALE;
		printf("%d\n", peak <= 2147483647.0);
		return 0;
	}
	return 2;
}
'''


class DsdDecimation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-dsd-decim-")
        cls.work = Path(cls.temp.name)
        subprocess.run(["git", "apply", "--include=dsd_decim.h", str(PATCH)], cwd=cls.work, check=True)
        (cls.work / "harness.c").write_text(HARNESS, encoding="utf-8")
        cls.binary = cls.work / "decim"
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=gnu99", "-Wall", "-Werror", "-Wno-unused-function", "-I", str(cls.work),
            str(cls.work / "harness.c"), "-o", str(cls.binary), "-lm"], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_bin(self, *args):
        return subprocess.run([str(self.binary), *args], text=True, capture_output=True, check=True).stdout.split()

    def test_frequenza_scelta_per_un_dac_da_192k(self):
        for dsd_rate, atteso in ((2822400, "1"), (5644800, "2"), (11289600, "3")):
            with self.subTest(dsd=dsd_rate):
                self.assertEqual(self.run_bin("stages", str(dsd_rate // 8), "192"), [atteso])

    def test_senza_decimazione_se_il_dac_accetta_dsd_diviso_8(self):
        self.assertEqual(self.run_bin("stages", "352800", "384"), ["0"])
        self.assertEqual(self.run_bin("stages", "705600", "384"), ["1"])

    def test_tono_1k_invariato_e_stato_continuo(self):
        na, nb, uguali, ampiezza = self.run_bin("tone", "1000", "977")
        self.assertEqual((na, nb), ("176400", "176400"))
        self.assertEqual(uguali, "1", "blocchi di lunghezza qualsiasi devono dare lo stesso risultato")
        self.assertAlmostEqual(float(ampiezza), 1.0, delta=0.005)

    def test_tono_20k_nella_banda(self):
        ampiezza = float(self.run_bin("tone", "20000", "4096")[3])
        self.assertAlmostEqual(ampiezza, 1.0, delta=0.02)

    def test_tono_oltre_nyquist_attenuato(self):
        # 160 kHz ripiegherebbe a 16,4 kHz nella banda audio.
        ampiezza = float(self.run_bin("tone", "160000", "4096")[3])
        self.assertLess(ampiezza, 0.001)

    def test_margine_contro_il_clipping(self):
        self.assertEqual(self.run_bin("headroom"), ["1"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
