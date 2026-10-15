#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Patch 0007 di Squeezelite: se il mixer hardware fallisce, il DSD va in PCM.

Il ripiego sul volume software non agisce sul DSD nativo ne' sul DoP
(output.c): senza la patch, dopo un brano PCM attenuato un DSF suonerebbe al
100%. La patch deve (1) ricordare il ripiego subito dopo il messaggio reale
"Initialization of mixer failed, reverting to software volume", (2) scriverlo
nel log, (3) azzerare il formato DSD in main.c prima di dsd_init, (4) toccare
solo main.c e output_alsa.c e non la chiusura del PCM (alsa_close/drain).
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/squeezelite/0007-mixer-fallback-disables-dsd.patch"


class MixerFallbackDsd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = PATCH.read_text(encoding="utf-8")
        cls.files = re.findall(r"^--- a/(\S+)", cls.text, re.M)
        cls.added = [line[1:] for line in cls.text.splitlines() if line.startswith("+") and not line.startswith("+++")]

    def test_tocca_solo_main_e_output_alsa(self):
        self.assertEqual(self.files, ["main.c", "output_alsa.c"])

    def test_ricorda_il_ripiego_e_lo_scrive_nel_log(self):
        self.assertIn("alsa_sw_volume_fallback = true;", [a.strip() for a in self.added])
        self.assertTrue(any("LOG_WARN" in a and "DSD" in a and "PCM" in a for a in self.added))
        # il contesto del punto di aggancio e' il messaggio reale di Squeezelite
        self.assertIn("Initialization of mixer failed, reverting to software volume", self.text)

    def test_main_azzera_il_formato_dsd_prima_di_dsd_init(self):
        lines = self.text.splitlines()
        force = next(i for i, l in enumerate(lines) if l.strip() == "+	if (alsa_sw_volume_fallback) dsd_outfmt = PCM;".strip())
        init = next(i for i, l in enumerate(lines) if "dsd_init(dsd_outfmt, dsd_delay);" in l)
        self.assertLess(force, init)

    def test_non_tocca_la_chiusura_del_pcm(self):
        for parola in ("snd_pcm_drain", "snd_pcm_close", "alsa_close", "snd_pcm_drop"):
            self.assertFalse(any(parola in a for a in self.added), parola)


if __name__ == "__main__":
    unittest.main()
