#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - genera un file di prova per verificare che il percorso del
# segnale sia bit-perfect.
#
# Il file e' un WAV PCM 24 bit / 176,4 kHz che contiene un tono DSD64 a
# 1 kHz impacchettato in DoP (DSD over PCM). Il DAC riconosce il DSD solo
# se riceve i campioni esattamente come sono nel file: basta un volume
# digitale non al 100%, un ricampionamento o un dither per far sparire i
# marcatori DoP.
#
# Come si usa:
#   1. python3 genera-test-dop.py         (crea sweetspot-test-dop.wav)
#   2. copia il file nella libreria musicale di Lyrion e riproducilo
#      con DSD=dop oppure DSD=no in sweetspot.txt (deve arrivare come PCM);
#   3. ABBASSA il volume dell'amplificatore prima di avviarlo.
#   Esito: il DAC indica DSD/DoP e si sente un tono a 1 kHz -> bit-perfect.
#          Il DAC indica PCM 176,4 kHz o si sente fruscio -> qualcosa
#          altera i campioni (di solito il volume del player in Lyrion).
#
# Funziona con Python 3 senza librerie aggiuntive.

import math
import struct
import sys

DSD_RATE = 2822400          # DSD64
PCM_RATE = DSD_RATE // 16   # 176400: 16 bit DSD per campione DoP
TONE_HZ = 1000.0
LEVEL = 0.05                # circa -26 dB: prudente per i tweeter
SECONDS = 6
FADE_S = 0.5
MARKERS = (0x05, 0xFA)


def dsd_bits(n):
    """Modulatore sigma-delta del secondo ordine: restituisce i bit DSD."""
    i1 = i2 = 0.0
    y = -1.0
    w = 2.0 * math.pi * TONE_HZ / DSD_RATE
    fade = FADE_S * DSD_RATE
    out = bytearray((n + 7) // 8)
    for k in range(n):
        g = min(1.0, k / fade, (n - k) / fade)
        x = LEVEL * g * math.sin(w * k)
        i1 += x - y
        i2 += i1 - y
        y = 1.0 if i2 >= 0.0 else -1.0
        if y > 0:
            out[k >> 3] |= 0x80 >> (k & 7)   # primo bit nel bit piu' alto
    return bytes(out)


def main(path="sweetspot-test-dop.wav"):
    n_bits = DSD_RATE * SECONDS
    sys.stderr.write("Generazione del segnale DSD (qualche decina di secondi)...\n")
    bits = dsd_bits(n_bits)
    frames = len(bits) // 2
    data = bytearray()
    for f in range(frames):
        marker = MARKERS[f & 1]
        b1, b2 = bits[2 * f], bits[2 * f + 1]
        sample = struct.pack("<BBB", b2, b1, marker)   # 24 bit little-endian
        data += sample + sample                        # stesso segnale L e R
    channels, width = 2, 3
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, PCM_RATE,
                                    PCM_RATE * channels * width, channels * width, 24)
    header += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as fh:
        fh.write(header)
        fh.write(data)
    sys.stderr.write(f"Creato {path}: {SECONDS} s, PCM 24 bit / {PCM_RATE} Hz con DSD64 in DoP.\n")


if __name__ == "__main__":
    main(*sys.argv[1:2])
