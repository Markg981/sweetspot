#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0006 di Squeezelite: dither TPDF al posto del troncamento (16 e 24 bit).

Applica la patch vera a output_pack.c di Squeezelite (fixture identica
all'upstream pinnato), lo compila con un compilatore C e verifica:
  - uscita S16 da un segnale a piu' di 16 bit: l'errore rispetto al valore
    ideale ha media zero e deviazione standard ~0,5 LSB (TPDF piu'
    arrotondamento), mai oltre 1,5 LSB (rumore del dither entro +-1 LSB);
  - un tono a -90 dBFS: con il dither le armoniche spariscono nel rumore,
    mentre il troncamento le lascia (prova di controllo);
  - nessun effetto a guadagno unitario: S24 e S32 identici all'ingresso, S16
    da una sorgente a 16 bit (bit-perfect) identico, silenzio digitale
    sempre silenzio, anche con il volume abbassato;
  - volume software: S16 e S24 attenuati senza troncamento (errore entro
    1,5 LSB, media zero).
Servono un compilatore C e Git, nessuna rete.
"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/squeezelite-output-pack.c"
PATCH = ROOT / "patches/squeezelite/0006-tpdf-dither-16bit.patch"

STUB_HEADER = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8_t;
typedef uint16_t u16_t;
typedef uint32_t u32_t;
typedef int32_t s32_t;
typedef int64_t s64_t;
typedef u32_t frames_t;
#define DSD 0
#define WIN 1
#define SL_LITTLE_ENDIAN 1
#define FIXED_ONE 0x10000
#define BYTES_PER_FRAME 8
#define MONO_LEFT 0x01
#define MONO_RIGHT 0x02
typedef enum { S32_LE, S24_LE, S24_3LE, S16_LE } output_format;
'''

HARNESS = r'''
#include "output_pack.c"
#include <math.h>
#include <stdio.h>

#define N 200000

static uint64_t lcg_state = 12345;
static int rnd(void) { lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL; return (int)(lcg_state >> 33); }

/* ampiezza della componente a f Hz (in unita' di LSB) di x[0..n) a fs Hz */
static double amplitude(const double *x, unsigned n, double f, double fs) {
	double re = 0, im = 0;
	unsigned i;
	for (i = 0; i < n; i++) {
		re += x[i] * cos(2 * M_PI * f * i / fs);
		im += x[i] * sin(2 * M_PI * f * i / fs);
	}
	return 2 * sqrt(re * re + im * im) / n;
}

static void stats(const double *err, unsigned n, double *mean, double *sd, double *max) {
	double s = 0, q = 0, m = 0;
	unsigned i;
	for (i = 0; i < n; i++) { s += err[i]; q += err[i] * err[i]; if (fabs(err[i]) > m) m = fabs(err[i]); }
	*mean = s / n;
	*sd = sqrt(q / n - (s / n) * (s / n));
	*max = m;
}

int main(int argc, char **argv) {
	static s32_t in[2 * N];
	static int16_t out16[2 * N];
	static s32_t out32[2 * N];
	static double err[N];
	const char *mode = argv[1];
	unsigned i;
	double mean, sd, max;

	if (!strcmp(mode, "s16") || !strcmp(mode, "s16gain") || !strcmp(mode, "s24gain")) {
		/* segnale casuale a 32 bit giustificato a sinistra, lontano dalla saturazione */
		s32_t g = strcmp(mode, "s16") ? 32768 : FIXED_ONE; /* -6 dB */
		for (i = 0; i < 2 * N; i++) in[i] = (s32_t)((rnd() % 2000000) - 1000000) * 1000;
		if (!strcmp(mode, "s24gain")) {
			_scale_and_pack_frames(out32, in, N, g, g, 0, S24_LE);
			for (i = 0; i < N; i++) err[i] = out32[2 * i] - (double)in[2 * i] * g / 65536.0 / 256.0;
		} else {
			_scale_and_pack_frames(out16, in, N, g, g, 0, S16_LE);
			for (i = 0; i < N; i++) err[i] = out16[2 * i] - (double)in[2 * i] * g / 65536.0 / 65536.0;
		}
		stats(err, N, &mean, &sd, &max);
		printf("%.4f %.4f %.4f\n", mean, sd, max);
		return 0;
	}
	if (!strcmp(mode, "tone")) {
		/* 1 kHz a -90 dBFS su 44,1 kHz, quantizzato a 24 bit; N campioni */
		const double fs = 44100.0, f = 1000.0, amp = 2147483648.0 * pow(10.0, -90.0 / 20.0);
		static double d[N], t[N];
		double fund, hd = 0, ht = 0;
		unsigned k;
		for (i = 0; i < N; i++) {
			s32_t v = (s32_t)(lrint(sin(2 * M_PI * f * i / fs) * amp / 256.0) * 256);
			in[2 * i] = in[2 * i + 1] = v;
		}
		_scale_and_pack_frames(out16, in, N, FIXED_ONE, FIXED_ONE, 0, S16_LE);
		for (i = 0; i < N; i++) { d[i] = out16[2 * i]; t[i] = in[2 * i] >> 16; }
		fund = amplitude(d, N, f, fs);
		for (k = 2; k <= 7; k++) {
			double a = amplitude(d, N, k * f, fs), b = amplitude(t, N, k * f, fs);
			if (a > hd) hd = a;
			if (b > ht) ht = b;
		}
		printf("%.4f %.4f %.4f\n", fund, hd, ht);
		return 0;
	}
	if (!strcmp(mode, "unity")) {
		int s24 = 1, s32 = 1, s16src = 1, silent = 1, silent24 = 1;
		for (i = 0; i < 2 * N; i++) in[i] = (s32_t)(rnd() % 65000 - 32500) * 65536; /* sorgente a 16 bit */
		_scale_and_pack_frames(out16, in, N, FIXED_ONE, FIXED_ONE, 0, S16_LE);
		for (i = 0; i < 2 * N; i++) if (out16[i] != (int16_t)(in[i] >> 16)) s16src = 0;
		for (i = 0; i < 2 * N; i++) in[i] = (s32_t)((rnd() % 2000000) - 1000000) * 1000 + 77; /* 32 bit */
		_scale_and_pack_frames(out32, in, N, FIXED_ONE, FIXED_ONE, 0, S24_LE);
		for (i = 0; i < 2 * N; i++) if (out32[i] != (in[i] >> 8)) s24 = 0;
		_scale_and_pack_frames(out32, in, N, FIXED_ONE, FIXED_ONE, 0, S32_LE);
		for (i = 0; i < 2 * N; i++) if (out32[i] != in[i]) s32 = 0;
		memset(in, 0, sizeof(in));
		_scale_and_pack_frames(out16, in, N, 20000, 20000, 0, S16_LE);
		for (i = 0; i < 2 * N; i++) if (out16[i]) silent = 0;
		_scale_and_pack_frames(out32, in, N, 20000, 20000, 0, S24_LE);
		for (i = 0; i < 2 * N; i++) if (out32[i]) silent24 = 0;
		printf("%d %d %d %d %d\n", s16src, s24, s32, silent, silent24);
		return 0;
	}
	return 2;
}
'''


class Dither(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-dither-")
        cls.work = Path(cls.temp.name)
        shutil.copyfile(FIXTURE, cls.work / "output_pack.c")
        subprocess.run(["git", "apply", "--include=output_pack.c", str(PATCH)], cwd=cls.work, check=True)
        (cls.work / "squeezelite.h").write_text(STUB_HEADER, encoding="utf-8")
        (cls.work / "harness.c").write_text(HARNESS, encoding="utf-8")
        cls.binary = cls.work / "dither"
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=gnu99", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-I", str(cls.work),
            str(cls.work / "harness.c"), "-o", str(cls.binary), "-lm"], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_bin(self, *args):
        return [float(v) for v in subprocess.run([str(self.binary), *args], text=True,
                                                 capture_output=True, check=True).stdout.split()]

    def test_s16_dither_tpdf_senza_bias_e_entro_il_limite(self):
        mean, sd, peak = self.run_bin("s16")
        self.assertLess(abs(mean), 0.02)
        self.assertAlmostEqual(sd, 0.5, delta=0.05)  # TPDF (1/6) + arrotondamento (1/12)
        self.assertLessEqual(peak, 1.5)

    def test_tono_a_meno_90_dbfs_senza_distorsione_armonica(self):
        fund, dithered, truncated = self.run_bin("tone")
        self.assertAlmostEqual(fund, 1.04, delta=0.1)
        self.assertLess(dithered, 0.02)    # armoniche nel rumore (~0,001 LSB per bin)
        self.assertGreater(truncated, 0.03)  # il troncamento le lascia: la prova e' sensibile

    def test_volume_software_senza_troncamento_a_16_e_24_bit(self):
        for modo in ("s16gain", "s24gain"):
            with self.subTest(modo=modo):
                mean, sd, peak = self.run_bin(modo)
                self.assertLess(abs(mean), 0.02)
                self.assertLessEqual(peak, 1.5)
                self.assertLess(sd, 0.6)

    def test_guadagno_unitario_invariato_e_silenzio_silenzioso(self):
        self.assertEqual(self.run_bin("unity"), [1, 1, 1, 1, 1])

    def test_la_patch_non_tocca_altro_che_output_pack(self):
        names = subprocess.run(["git", "apply", "--numstat", str(PATCH)], capture_output=True, text=True,
                               check=True, cwd=self.work).stdout.split()
        self.assertEqual(names[2::3], ["output_pack.c"])


if __name__ == "__main__":
    unittest.main()
