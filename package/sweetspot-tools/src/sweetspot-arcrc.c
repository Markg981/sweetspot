/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - firme AccurateRip di una traccia di un CD audio copiata in
 * WAV (44,1 kHz, 16 bit, stereo).
 *
 *   sweetspot-arcrc crc FILE.wav [primo] [ultimo]
 *       stampa "v1 v2" in esadecimale. Sulla prima traccia si saltano i
 *       primi 5 settori, sull'ultima gli ultimi 5, come prevede AccurateRip.
 *
 *   sweetspot-arcrc cerca FILE.wav MARGINE CAMPIONI
 *       FILE contiene la traccia con MARGINE campioni in piu' prima e dopo
 *       (traccia centrale del disco). Per ogni spostamento k da -MARGINE a
 *       +MARGINE stampa "k v1", la firma v1 della traccia letta k campioni
 *       piu' avanti: serve a trovare la correzione del lettore (offset).
 *       Calcolo a finestra scorrevole: tempo proporzionale alla lunghezza.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SECTOR_SAMPLES 588

static uint32_t *load_wav(const char *path, size_t *count)
{
	FILE *f = fopen(path, "rb");
	unsigned char hdr[12], ch[8];
	uint32_t *data;
	size_t n;

	if (!f) {
		perror(path);
		exit(2);
	}
	if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4)) {
		fprintf(stderr, "%s: non e' un file WAV\n", path);
		exit(2);
	}
	/* Si cerca il blocco "data". */
	for (;;) {
		uint32_t len;
		if (fread(ch, 1, 8, f) != 8) {
			fprintf(stderr, "%s: dati audio non trovati\n", path);
			exit(2);
		}
		len = ch[4] | ch[5] << 8 | ch[6] << 16 | (uint32_t)ch[7] << 24;
		if (!memcmp(ch, "data", 4)) {
			n = len / 4;
			break;
		}
		if (fseek(f, len + (len & 1), SEEK_CUR)) {
			perror(path);
			exit(2);
		}
	}
	data = malloc(n * 4 + 4);
	if (!data) {
		fprintf(stderr, "memoria insufficiente\n");
		exit(2);
	}
	n = fread(data, 4, n, f);
	fclose(f);
	*count = n;
	return data; /* campioni stereo come parole di 32 bit little-endian */
}

/* Il calcolatore e' little-endian (x86, ARM): i campioni del WAV si usano
 * cosi' come sono. */
static void crc(const uint32_t *s, size_t n, int first, int last)
{
	uint32_t v1 = 0, v2 = 0, mul = 1;
	size_t from = 1, to = n, i;

	if (first)
		from += SECTOR_SAMPLES * 5 - 1;
	if (last)
		to -= SECTOR_SAMPLES * 5;
	for (i = 0; i < n; i++, mul++) {
		if (mul >= from && mul <= to) {
			uint64_t p = (uint64_t)s[i] * mul;
			v1 += mul * s[i];
			v2 += (uint32_t)(p >> 32) + (uint32_t)p;
		}
	}
	printf("%08x %08x\n", v1, v2);
}

static void search(const uint32_t *s, size_t n, long margin, size_t len)
{
	uint32_t c = 0, sum = 0;
	size_t j;
	long k;

	if ((size_t)(2 * margin) + len > n) {
		fprintf(stderr, "file troppo corto per il margine richiesto\n");
		exit(2);
	}
	/* Finestra iniziale: spostamento -margine, cioe' dal campione 0. */
	for (j = 0; j < len; j++) {
		c += (uint32_t)(j + 1) * s[j];
		sum += s[j];
	}
	for (k = -margin;; k++) {
		size_t a = (size_t)(k + margin);
		printf("%ld %08x\n", k, c);
		if (k == margin)
			break;
		/* CRC(k+1) = CRC(k) - S(k) + N * s[a+N] */
		c = c - sum + (uint32_t)len * s[a + len];
		sum = sum - s[a] + s[a + len];
	}
}

int main(int argc, char **argv)
{
	size_t n;
	uint32_t *s;

	if (argc >= 3 && !strcmp(argv[1], "crc")) {
		int first = 0, last = 0, i;
		for (i = 3; i < argc; i++) {
			if (!strcmp(argv[i], "primo"))
				first = 1;
			else if (!strcmp(argv[i], "ultimo"))
				last = 1;
		}
		s = load_wav(argv[2], &n);
		crc(s, n, first, last);
		return 0;
	}
	if (argc == 5 && !strcmp(argv[1], "cerca")) {
		s = load_wav(argv[2], &n);
		search(s, n, atol(argv[3]), (size_t)atol(argv[4]));
		return 0;
	}
	fprintf(stderr, "uso: %s crc FILE.wav [primo] [ultimo] | cerca FILE.wav MARGINE CAMPIONI\n", argv[0]);
	return 1;
}
