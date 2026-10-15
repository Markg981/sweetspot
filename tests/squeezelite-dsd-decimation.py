#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0004 di Squeezelite: DSD -> PCM alla frequenza che il DAC accetta.

Estrae dalla patch vera il file dsd_decim.h (lo stadio di decimazione), lo
compila con un compilatore C e verifica, per un DAC che accetta al massimo
192 kHz (e per uno che accetta 384 kHz):
  - la scelta della frequenza: DSD64 -> 176,4 kHz, DSD128 -> 176,4 kHz,
    DSD256 -> 176,4 kHz; con 352,8 kHz accettata non si decima;
  - il filtro, per ogni cascata (DSD64/128/256/512 verso 176,4 e 44,1 kHz):
    passband piatto fino a 20 kHz (+-0,1 dB) e almeno 100 dB di attenuazione
    da sopra la nuova Nyquist fino alla vecchia, quindi niente alias;
  - il costo: le moltiplicazioni al secondo per DSD512 verso 44,1 kHz restano
    entro il budget stimato per il Raspberry Pi 4;
  - il numero di campioni e il segnale: un tono a 1 kHz resta invariato;
  - lo stato e' continuo fra blocchi di lunghezza qualsiasi (stesso risultato
    di un'unica chiamata);
  - il margine (DSD_PCM_MARGINE_DB, predefinito -3 dB, mai sopra 0): con -3 dB
    un picco del +3 dB (141%) non satura a 32 bit; i valori non validi cadono
    sul predefinito.
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

static dsd_decim ctx, ctx2;

int main(int argc, char **argv) {
	(void)argc;
	if (!strcmp(argv[1], "stages")) {
		unsigned rate = (unsigned)atoi(argv[2]);
		printf("%u\n", dsd_decim_stages_for(rate, !strcmp(argv[3], "192") ? dac192 : dac384));
		return 0;
	}
	if (!strcmp(argv[1], "tone")) {
		/* tone <Hz> <blocco> <frequenza in ingresso> <stadi> */
		double f = atof(argv[2]);
		unsigned chunk = (unsigned)atoi(argv[3]);
		const unsigned base = (unsigned)atoi(argv[4]), stages = (unsigned)atoi(argv[5]);
		const unsigned n = base / 2;
		double out_rate = (double)(base >> stages);
		float *in = malloc(n * sizeof(float)), *a = malloc(n * sizeof(float)), *b = malloc(n * sizeof(float));
		unsigned i, na = 0, nb = 0, pos;
		for (i = 0; i < n; i++) in[i] = (float)sin(2 * M_PI * f * i / (double)base);
		dsd_decim_reset(&ctx, base, stages);
		dsd_decim_reset(&ctx2, base, stages);
		memcpy(a, in, n * sizeof(float));
		na = dsd_decim_run(&ctx, 0, a, n);
		for (pos = 0; pos < n; ) {
			unsigned len = chunk < n - pos ? chunk : n - pos;
			memcpy(b + nb, in + pos, len * sizeof(float));
			nb += dsd_decim_run(&ctx2, 0, b + nb, len);
			pos += len;
		}
		printf("%u %u %d %.9f\n", na, nb, memcmp(a, b, na * sizeof(float)) == 0, tone_amplitude(a, na, f, out_rate));
		return 0;
	}
	if (!strcmp(argv[1], "cost")) {
		/* lunghezze dei filtri e moltiplicazioni al secondo per canale (filtro simmetrico) */
		unsigned base = (unsigned)atoi(argv[2]), stages = (unsigned)atoi(argv[3]), s;
		double mac = 0;
		dsd_decim_reset(&ctx, base, stages);
		for (s = 0; s < stages; s++) {
			mac += (ctx.taps[s] + 1) / 2 * ((double)(base >> s) / 2);
			printf("%u ", ctx.taps[s]);
		}
		printf("%.0f\n", mac);
		return 0;
	}
	if (!strcmp(argv[1], "margin")) {
		/* margin <testo|-> -> margine in dB e fondo scala rispetto a 2^31-1 */
		dsd_pcm_set_margin(!strcmp(argv[2], "-") ? NULL : argv[2]);
		printf("%.4f %.9f\n", dsd_pcm_margin_db, DSD_PCM_FULLSCALE / 2147483647.0);
		return 0;
	}
	if (!strcmp(argv[1], "headroom")) {
		/* headroom <testo|-> <picco> -> 1 se il picco non satura a 32 bit */
		double peak = atof(argv[3]);
		dsd_pcm_set_margin(!strcmp(argv[2], "-") ? NULL : argv[2]);
		printf("%d\n", peak * DSD_PCM_FULLSCALE <= 2147483647.0);
		return 0;
	}
	return 2;
}
'''

# (frequenza di ingresso = DSD / 8, stadi): DSD64 -> 176,4 kHz, DSD128 -> 176,4 e 88,2,
# DSD256 -> 176,4 e 44,1, DSD512 -> 176,4 e 44,1 kHz.
CASCATE = (
    (352800, 1), (352800, 2), (352800, 3),
    (705600, 2), (705600, 4),
    (1411200, 3), (1411200, 5),
    (2822400, 4), (2822400, 6),
)


class DsdDecimation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-dsd-decim-")
        cls.work = Path(cls.temp.name)
        subprocess.run(["git", "apply", "--include=dsd_decim.h", str(PATCH)], cwd=cls.work, check=True)
        (cls.work / "harness.c").write_text(HARNESS, encoding="utf-8")
        cls.binary = cls.work / "decim"
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=gnu99", "-O2", "-Wall", "-Werror", "-Wno-unused-function", "-I", str(cls.work),
            str(cls.work / "harness.c"), "-o", str(cls.binary), "-lm"], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_bin(self, *args):
        return subprocess.run([str(self.binary), *args], text=True, capture_output=True, check=True).stdout.split()

    def tone(self, hz, base, stages, chunk=4096):
        return float(self.run_bin("tone", str(hz), str(chunk), str(base), str(stages))[3])

    def test_frequenza_scelta_per_un_dac_da_192k(self):
        for dsd_rate, atteso in ((2822400, "1"), (5644800, "2"), (11289600, "3")):
            with self.subTest(dsd=dsd_rate):
                self.assertEqual(self.run_bin("stages", str(dsd_rate // 8), "192"), [atteso])

    def test_senza_decimazione_se_il_dac_accetta_dsd_diviso_8(self):
        self.assertEqual(self.run_bin("stages", "352800", "384"), ["0"])
        self.assertEqual(self.run_bin("stages", "705600", "384"), ["1"])

    def test_tono_1k_invariato_e_stato_continuo(self):
        na, nb, uguali, ampiezza = self.run_bin("tone", "1000", "977", "352800", "1")
        self.assertEqual((na, nb), ("88200", "88200"))
        self.assertEqual(uguali, "1", "blocchi di lunghezza qualsiasi devono dare lo stesso risultato")
        self.assertAlmostEqual(float(ampiezza), 1.0, delta=0.0005)

    def test_stato_continuo_in_cascata(self):
        for base, stages in ((705600, 2), (2822400, 6)):
            with self.subTest(base=base, stadi=stages):
                na, nb, uguali, _ = self.run_bin("tone", "1000", "977", str(base), str(stages))
                self.assertEqual(na, nb)
                self.assertEqual(int(na), base // 2 >> stages)
                self.assertEqual(uguali, "1")

    def test_passband_piatto_fino_a_20k(self):
        # +-0,1 dB = ampiezza fra 0,98855 e 1,01158.
        for base, stages in CASCATE:
            for hz in (100, 1000, 10000, 15000, 20000):
                with self.subTest(ingresso=base, stadi=stages, hz=hz):
                    ampiezza = self.tone(hz, base, stages)
                    self.assertGreater(ampiezza, 0.98855)
                    self.assertLess(ampiezza, 1.01158)

    def test_stopband_100_db_sopra_la_nuova_nyquist(self):
        # Ogni tono sopra la nuova Nyquist (fino alla vecchia, base/2) ripiegherebbe
        # nella banda: deve restare sotto -100 dB (1e-5) in ogni cascata.
        for base, stages in CASCATE:
            nyquist = (base >> stages) / 2
            for fattore in (1.02, 1.37, 2.31, 4.7):
                hz = nyquist * fattore
                if hz >= base / 2:
                    continue
                with self.subTest(ingresso=base, stadi=stages, hz=hz):
                    self.assertLess(self.tone(int(hz), base, stages), 1e-5)
            with self.subTest(ingresso=base, stadi=stages, hz="quasi base/2"):
                self.assertLess(self.tone(int(base / 2 * 0.93), base, stages), 1e-5)

    def test_tono_160k_attenuato_oltre_60_db(self):
        # Il caso storico: 160 kHz ripiegherebbe a 16,4 kHz nella banda audio.
        self.assertLess(self.tone(160000, 352800, 1), 1e-5)

    def test_costo_cpu_entro_il_budget(self):
        # DSD512 -> 44,1 kHz e' il caso peggiore: 6 stadi, il primo corto e
        # largo, l'ultimo ripido. Budget: 70 milioni di moltiplicazioni al
        # secondo per canale (circa 10% di un core del Pi 4 a 1,5 GHz, in
        # scalare, per due canali).
        *lunghezze, mac = map(float, self.run_bin("cost", "2822400", "6"))
        self.assertEqual(len(lunghezze), 6)
        self.assertTrue(all(n % 2 == 1 and n <= 511 for n in lunghezze), lunghezze)
        self.assertLess(mac, 70e6)
        # Anche l'ultimo stadio (88,2 -> 44,1 kHz) sta nel limite di 511 punti.
        self.assertLess(lunghezze[-1], 511)

    def test_margine_predefinito_e_scelta(self):
        for testo, db, scala in (("-", -3.0, 0.707945784), ("-3", -3.0, 0.707945784),
                                 ("0", 0.0, 1.0), ("-6", -6.0, 0.501187234),
                                 ("-1.5", -1.5, 0.841395142)):
            with self.subTest(testo=testo):
                letto_db, letto_scala = self.run_bin("margin", testo)
                self.assertAlmostEqual(float(letto_db), db, places=3)
                self.assertAlmostEqual(float(letto_scala), scala, places=6)

    def test_margine_mai_sopra_zero_e_valori_non_validi(self):
        # Sopra 0 dB amplificherebbe e satura: 0. Il testo non numerico o
        # vuoto non cambia il predefinito; sotto il minimo (-24 dB): -24.
        for testo, db in (("3", 0.0), ("+1", 0.0), ("abc", -3.0), ("", -3.0), ("-3x", -3.0),
                          ("nan", -3.0), ("-100", -24.0)):
            with self.subTest(testo=testo):
                self.assertAlmostEqual(float(self.run_bin("margin", testo)[0]), db, places=3)

    def test_margine_contro_il_clipping(self):
        # I DSD "over" arrivano a +3 dB (141%): con -3 dB non si satura, senza
        # margine (0 dB) si.
        self.assertEqual(self.run_bin("headroom", "-", "1.3"), ["1"])
        self.assertEqual(self.run_bin("headroom", "-", "1.41"), ["1"])
        self.assertEqual(self.run_bin("headroom", "-3", "1.41"), ["1"])
        self.assertEqual(self.run_bin("headroom", "0", "1.41"), ["0"])
        self.assertEqual(self.run_bin("headroom", "0", "1.0"), ["1"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
