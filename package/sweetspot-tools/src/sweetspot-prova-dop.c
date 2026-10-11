/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - file di prova DoP generato sul player, per la prova guidata
 * della pagina Audio: un WAV PCM 24 bit / 176,4 kHz con un tono DSD64 a
 * 1 kHz (circa -26 dB, con dissolvenze) impacchettato in DoP. Il DAC
 * mostra DSD/DoP e suona il tono solo se riceve i campioni intatti e se
 * riconosce il DoP; altrimenti mostra PCM o si sente fruscio.
 *
 * Stesso segnale di tools/genera-test-dop.py (modulatore sigma-delta del
 * secondo ordine, marcatori 0x05/0xFA alternati, stesso segnale su L e R).
 *
 *   sweetspot-prova-dop FILE [secondi]    (predefinito 6, da 1 a 30)
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PCM_RATE 176400
#define DSD_RATE (PCM_RATE * 16)
#define TONE_HZ 1000.0
#define LEVEL 0.05
#define FADE_S 0.5

static void le16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void le32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

int main(int argc, char **argv)
{
	static const unsigned char markers[2] = { 0x05, 0xFA };
	unsigned char header[44], frame[6];
	long seconds = 6, n, k, frames, f;
	double i1 = 0, i2 = 0, y = -1, w = 2.0 * M_PI * TONE_HZ / DSD_RATE, fade = FADE_S * DSD_RATE;
	unsigned char *bits;
	uint32_t bytes;
	FILE *out;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "uso: sweetspot-prova-dop FILE [secondi]\n");
		return 2;
	}
	if (argc == 3) {
		char *end;
		seconds = strtol(argv[2], &end, 10);
		if (*end || seconds < 1 || seconds > 30) {
			fprintf(stderr, "sweetspot-prova-dop: durata da 1 a 30 secondi\n");
			return 2;
		}
	}
	n = (long)DSD_RATE * seconds;
	bits = calloc((n + 7) / 8, 1);
	if (!bits) {
		perror("sweetspot-prova-dop");
		return 1;
	}
	for (k = 0; k < n; k++) {
		double g = fmin(1.0, fmin(k / fade, (n - k) / fade));
		double x = LEVEL * g * sin(w * k);
		i1 += x - y;
		i2 += i1 - y;
		y = i2 >= 0.0 ? 1.0 : -1.0;
		if (y > 0)
			bits[k >> 3] |= 0x80 >> (k & 7); /* primo bit nel bit piu' alto */
	}

	frames = (n + 7) / 8 / 2;
	bytes = (uint32_t)frames * 6;
	memcpy(header, "RIFF", 4);
	le32(header + 4, 36 + bytes);
	memcpy(header + 8, "WAVEfmt ", 8);
	le32(header + 16, 16);
	le16(header + 20, 1);
	le16(header + 22, 2);
	le32(header + 24, PCM_RATE);
	le32(header + 28, PCM_RATE * 6);
	le16(header + 32, 6);
	le16(header + 34, 24);
	memcpy(header + 36, "data", 4);
	le32(header + 40, bytes);

	out = fopen(argv[1], "wb");
	if (!out || fwrite(header, sizeof(header), 1, out) != 1) {
		perror(argv[1]);
		return 1;
	}
	for (f = 0; f < frames; f++) {
		/* 24 bit little-endian: secondo byte DSD, primo byte DSD, marcatore. */
		frame[0] = bits[2 * f + 1];
		frame[1] = bits[2 * f];
		frame[2] = markers[f & 1];
		memcpy(frame + 3, frame, 3);
		if (fwrite(frame, sizeof(frame), 1, out) != 1) {
			perror(argv[1]);
			return 1;
		}
	}
	if (fclose(out) != 0) {
		perror(argv[1]);
		return 1;
	}
	free(bits);
	return 0;
}
