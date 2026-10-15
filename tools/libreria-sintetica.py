#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - generatore di una libreria musicale sintetica e riproducibile.
#   python3 tools/libreria-sintetica.py DESTINAZIONE [--brani 50000] [--seme 1]
#                                       [--dimensione-kb 0] [--copertine 200]
# Crea brani MP3 con tag ID3v2.3 (artista, album, titolo, genere, anno,
# traccia) e una copertina piccola (JPEG minimo) condivisa da piu' album.
# Il contenuto audio e' una manciata di frame MPEG silenziosi: Lyrion li
# indicizza come brani veri. Con --dimensione-kb il file viene portato a
# quella misura come file sparso (truncate), senza occupare disco. Stesso
# seme, stessi file: i risultati dei benchmark si possono confrontare.

import argparse
import os
import random
import struct
import sys

# Frame MPEG1 Layer III, 128 kbps, 44,1 kHz, stereo: 417 byte di silenzio.
FRAME = b"\xff\xfb\x90\x64" + b"\x00" * 413

# JPEG minimo (1x1 pixel) usato come copertina.
JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb0043000806060706050807070709"
    "09080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c283729"
    "2c30313434341f27393d38323c2e333432ffc0000b080001000101011100ffc4001f0000"
    "010501010101010100000000000000000102030405060708090a0bffda00080101000003"
    "f0ffd9"
)

GENERI = ["Rock", "Jazz", "Classica", "Elettronica", "Folk", "Blues", "Pop", "Metal"]

DESCRIZIONE = "Strumento Sweetspot di collaudo (vedi il commento in testa al file e docs/collaudo.md)"


def synchsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def frame_id3(nome, dati):
    return nome + struct.pack(">I", len(dati)) + b"\x00\x00" + dati


def testo(nome, valore):
    return frame_id3(nome, b"\x03" + valore.encode("utf-8"))  # UTF-8


def tag_id3(artista, album, titolo, genere, anno, traccia, copertina):
    frames = b"".join([
        testo(b"TPE1", artista), testo(b"TPE2", artista), testo(b"TALB", album),
        testo(b"TIT2", titolo), testo(b"TCON", genere), testo(b"TYER", str(anno)),
        testo(b"TRCK", str(traccia)),
        frame_id3(b"APIC", b"\x00image/jpeg\x00\x03\x00" + copertina),
    ])
    return b"ID3\x03\x00\x00" + synchsafe(len(frames)) + frames


def genera(dest, brani, seme, dimensione_kb, copertine, per_album=12, frames=40):
    rnd = random.Random(seme)
    # Un byte di commento diverso rende ogni copertina unica.
    jpeg = [JPEG[:-2] + bytes([i & 255, (i >> 8) & 255]) + b"\xff\xd9" for i in range(copertine)]
    n = 0
    album_n = 0
    while n < brani:
        artista = "Artista %04d" % rnd.randrange(max(brani // 60, 1))
        album = "Album %05d" % album_n
        genere = rnd.choice(GENERI)
        anno = 1960 + rnd.randrange(65)
        cop = jpeg[album_n % copertine]
        cartella = os.path.join(dest, "%03d" % (album_n // 500), artista, album)
        os.makedirs(cartella, exist_ok=True)
        for t in range(1, min(per_album, brani - n) + 1):
            titolo = "Brano %06d" % n
            percorso = os.path.join(cartella, "%02d %s.mp3" % (t, titolo))
            with open(percorso, "wb") as f:
                f.write(tag_id3(artista, album, titolo, genere, anno, t, cop))
                f.write(FRAME * frames)
                if dimensione_kb:
                    f.truncate(max(dimensione_kb * 1024, f.tell()))
            n += 1
        album_n += 1
    return n, album_n


def main():
    p = argparse.ArgumentParser(description=DESCRIZIONE)
    p.add_argument("destinazione")
    p.add_argument("--brani", type=int, default=50000)
    p.add_argument("--seme", type=int, default=1)
    p.add_argument("--dimensione-kb", type=int, default=0, help="dimensione apparente (file sparso)")
    p.add_argument("--copertine", type=int, default=200, help="numero di copertine diverse")
    a = p.parse_args()
    if a.brani < 1 or a.copertine < 1:
        sys.exit("brani e copertine devono essere positivi")
    n, albums = genera(a.destinazione, a.brani, a.seme, a.dimensione_kb, a.copertine)
    print("%d brani in %d album in %s" % (n, albums, a.destinazione))


if __name__ == "__main__":
    main()
