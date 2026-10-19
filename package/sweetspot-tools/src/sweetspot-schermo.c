// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sweetspot - schermata di benvenuto disegnata sul framebuffer.
//
// Sostituisce il testo sulla console: sfondo sfumato, marchio, indirizzo in
// grande, QR code su una scheda chiara e stato del player in basso. Le
// proporzioni seguono l'altezza dello schermo (da 1024x768 al 4K).
//
//   sweetspot-schermo FILE [TTY]           resta attivo e ridisegna al SIGHUP,
//                                          al ritorno sulla console (Alt+F1) e
//                                          quando lo schermo si riaccende
//   sweetspot-schermo -o OUT.ppm LxA FILE  disegna in un'immagine (prove)
//
// FILE ha righe CHIAVE=VALORE in UTF-8, gia' pronte da sweetspot-display:
//   occhiello titolo_prefisso titolo alt_etichetta alt riga1 riga2 qr qr_nota
//   stato stato_tipo (ok|attesa|errore) tasto tasto_nota
// Le chiavi mancanti non si disegnano. Senza "qr" a destra va il marchio.
//
// La console resta in modo testo: lo spegnimento dopo SCHERMO_MINUTI e il
// cambio di console li gestisce il kernel come prima. Esce con 1 se non
// c'e' un framebuffer o mancano i caratteri: lo script torna al testo.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/vt.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <qrencode.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <termios.h>
#include <unistd.h>

#include <ft2build.h>
#include FT_FREETYPE_H

static const char *const FONT_REG[] = {
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", NULL };
static const char *const FONT_BOLD[] = {
	"/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", NULL };

// Tavolozza: blu notte, oro caldo (il "punto dolce"), testi freddi.
#define C_FONDO_ALTO  0x0E1424
#define C_FONDO_BASSO 0x06080F
#define C_ORO         0xF2B35B
#define C_INDACO      0x4F46E5
#define C_TESTO       0xF4F6FB
#define C_CHIARO      0xD5DCEA
#define C_SPENTO      0x8D97AD
#define C_SCHEDA      0xFFFFFF
#define C_INCHIOSTRO  0x0B1020
#define C_OK          0x4ADE80
#define C_ATTESA      0xFBBF24
#define C_ERRORE      0xF87171

typedef struct { int w, h; float *px; } Tela; // RGB in virgola mobile 0..1

typedef struct {
	const char *occhiello, *titolo_prefisso, *titolo, *alt_etichetta, *alt, *riga1, *riga2;
	const char *qr, *qr_nota, *stato, *stato_tipo, *tasto, *tasto_nota;
} Testi;

static FT_Library ft;
static FT_Face f_reg, f_bold;

static float clampf(float v, float a, float b) { return v < a ? a : v > b ? b : v; }
static float ch(uint32_t c, int s) { return ((c >> s) & 255) / 255.0f; }

static void fondi(Tela *t, int x, int y, uint32_t c, float a)
{
	if (x < 0 || y < 0 || x >= t->w || y >= t->h || a <= 0) return;
	if (a > 1) a = 1;
	float *p = t->px + 3 * ((size_t)y * t->w + x);
	p[0] += (ch(c, 16) - p[0]) * a;
	p[1] += (ch(c, 8) - p[1]) * a;
	p[2] += (ch(c, 0) - p[2]) * a;
}

// Sfondo: sfumatura verticale, aloni morbidi, anelli concentrici attorno
// al centro (cx, cy) come onde sonore che si spengono allontanandosi.
static void sfondo(Tela *t, float s, float cx, float cy, float gx, float gy)
{
	const float passo = 7 * s, mezzo = fmaxf(0.06f * s, 0.6f);
	for (int y = 0; y < t->h; y++) {
		float k = (float)y / (t->h - 1);
		for (int x = 0; x < t->w; x++) {
			float *p = t->px + 3 * ((size_t)y * t->w + x);
			for (int i = 0; i < 3; i++) {
				int sh = 16 - 8 * i;
				p[i] = ch(C_FONDO_ALTO, sh) * (1 - k) + ch(C_FONDO_BASSO, sh) * k;
			}
			float dx = x + 0.5f - cx, dy = y + 0.5f - cy;
			float d = sqrtf(dx * dx + dy * dy);
			float a1 = 0.11f * expf(-(d * d) / (2 * 30 * s * 30 * s));
			float ex = x + 0.5f - gx, ey = y + 0.5f - gy;
			float a2 = 0.16f * expf(-(ex * ex + ey * ey) / (2 * 45 * s * 45 * s));
			for (int i = 0; i < 3; i++) {
				int sh = 16 - 8 * i;
				p[i] += ch(C_ORO, sh) * a1 + ch(C_INDACO, sh) * a2;
			}
			int n = (int)(d / passo + 0.5f);
			if (n >= 3 && n <= 11) {
				float cov = clampf(mezzo + 0.5f - fabsf(d - n * passo), 0, 1);
				float a = cov * 0.11f * (1 - (n - 3) / 9.0f);
				for (int i = 0; i < 3; i++)
					p[i] += (ch(C_ORO, 16 - 8 * i) - p[i]) * a;
			}
		}
	}
}

// Rettangolo arrotondato antialias (cx, cy centro; hw, hh mezze misure).
// bordo > 0 disegna solo il contorno di quello spessore; sfuma > 0 fa
// un'ombra che svanisce in "sfuma" pixel.
static void rett(Tela *t, float cx, float cy, float hw, float hh, float r,
		 uint32_t c, float a, float bordo, float sfuma)
{
	int x0 = (int)(cx - hw - sfuma - 2), x1 = (int)(cx + hw + sfuma + 2);
	int y0 = (int)(cy - hh - sfuma - 2), y1 = (int)(cy + hh + sfuma + 2);
	for (int y = y0; y <= y1; y++)
		for (int x = x0; x <= x1; x++) {
			float qx = fabsf(x + 0.5f - cx) - (hw - r), qy = fabsf(y + 0.5f - cy) - (hh - r);
			float mx = fmaxf(qx, 0), my = fmaxf(qy, 0);
			float d = sqrtf(mx * mx + my * my) + fminf(fmaxf(qx, qy), 0) - r;
			float cov;
			if (sfuma > 0) {
				float u = clampf(d / sfuma, 0, 1);
				cov = (1 - u) * (1 - u);
			} else if (bordo > 0)
				cov = clampf(bordo / 2 + 0.5f - fabsf(d + bordo / 2), 0, 1);
			else
				cov = clampf(0.5f - d, 0, 1);
			fondi(t, x, y, c, cov * a);
		}
}

static void cerchio(Tela *t, float cx, float cy, float r, uint32_t c, float a, float bordo)
{
	float e = r + bordo / 2 + 2;
	for (int y = (int)(cy - e); y <= (int)(cy + e); y++)
		for (int x = (int)(cx - e); x <= (int)(cx + e); x++) {
			float d = hypotf(x + 0.5f - cx, y + 0.5f - cy);
			float cov = bordo > 0 ? clampf(bordo / 2 + 0.5f - fabsf(d - r), 0, 1)
					      : clampf(r + 0.5f - d, 0, 1);
			fondi(t, x, y, c, cov * a);
		}
}

// Il marchio: un punto pieno con due cerchi attorno, il punto d'ascolto.
static void marchio(Tela *t, float cx, float cy, float r)
{
	cerchio(t, cx, cy, r, C_ORO, 0.35f, fmaxf(r * 0.07f, 1));
	cerchio(t, cx, cy, r * 0.66f, C_ORO, 0.85f, fmaxf(r * 0.11f, 1));
	cerchio(t, cx, cy, r * 0.30f, C_ORO, 1, 0);
}

static uint32_t utf8(const char **s)
{
	const unsigned char *p = (const unsigned char *)*s;
	uint32_t c = *p++;
	int n = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
	if (n) c &= 0x3F >> n;
	while (n-- && (*p & 0xC0) == 0x80) c = (c << 6) | (*p++ & 0x3F);
	*s = (const char *)p;
	return c;
}

// Scrive (o misura, con t == NULL) il testo dalla linea di base y.
// "spazio" e' la spaziatura in piu' fra le lettere, in pixel.
static float testo(Tela *t, FT_Face f, int px, float x, float y, const char *s,
		   uint32_t c, float a, float spazio)
{
	float pen = x;
	if (!s) return 0;
	FT_Set_Pixel_Sizes(f, 0, px);
	while (*s) {
		uint32_t cp = utf8(&s);
		if (FT_Load_Char(f, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) continue;
		FT_GlyphSlot g = f->glyph;
		if (t) {
			int gx = (int)(pen + 0.5f) + g->bitmap_left, gy = (int)(y + 0.5f) - g->bitmap_top;
			for (unsigned r = 0; r < g->bitmap.rows; r++)
				for (unsigned k = 0; k < g->bitmap.width; k++)
					fondi(t, gx + k, gy + r, c,
					      a * g->bitmap.buffer[r * g->bitmap.pitch + k] / 255.0f);
		}
		pen += g->advance.x / 64.0f + (*s ? spazio : 0);
	}
	return pen - x;
}

// Dimensione piu' grande (fino a px) con cui il testo sta in "largo".
static int adatta(FT_Face f, int px, const char *s, float largo)
{
	float w;
	while (px > 8 && (w = testo(NULL, f, px, 0, 0, s, 0, 0, 0)) > largo)
		px = (int)(px * largo / w);
	return px;
}

static int qr(Tela *t, const char *url, float x, float y, float lato)
{
	QRcode *q = QRcode_encodeString(url, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
	if (!q) return -1;
	int m = (int)(lato / q->width);
	if (m < 1) m = 1;
	int ox = (int)(x + (lato - m * q->width) / 2), oy = (int)(y + (lato - m * q->width) / 2);
	for (int r = 0; r < q->width; r++)
		for (int k = 0; k < q->width; k++)
			if (q->data[r * q->width + k] & 1)
				for (int yy = 0; yy < m; yy++)
					for (int xx = 0; xx < m; xx++)
						fondi(t, ox + k * m + xx, oy + r * m + yy, C_INCHIOSTRO, 1);
	QRcode_free(q);
	return 0;
}

static void disegna(Tela *t, const Testi *x)
{
	// Unita' di misura: 1/100 dell'altezza di un riquadro 16:9 centrato.
	float s = fminf(t->w * 9.0f / 16, t->h) / 100;
	float lw = s * 1600 / 9, ox = (t->w - lw) / 2, oy = (t->h - 100 * s) / 2;
	float mx = 8 * s, sx = ox + mx, dx = ox + lw - mx;

	float cw = 40 * s, chh = 45 * s;
	float kx = dx - cw / 2, ky = oy + 52 * s;
	sfondo(t, s, kx, ky, ox + 12 * s, oy + 100 * s);

	// Intestazione: marchio e nome.
	marchio(t, sx + 2.6f * s, oy + 10 * s, 2.6f * s);
	testo(t, f_bold, (int)(3.2f * s), sx + 7 * s, oy + 11.2f * s, "Sweetspot", C_TESTO, 1, 0.02f * s);

	// Destra: la scheda con il QR, oppure il marchio in grande.
	if (x->qr) {
		float top = ky - chh / 2, pad = 4 * s;
		rett(t, kx, ky + 1.5f * s, cw / 2, chh / 2, 2.4f * s, 0x000000, 0.55f, 0, 5 * s);
		rett(t, kx, ky, cw / 2, chh / 2, 2.4f * s, C_SCHEDA, 1, 0, 0);
		qr(t, x->qr, kx - cw / 2 + pad, top + pad, cw - 2 * pad);
		if (x->qr_nota) {
			int px = adatta(f_reg, (int)(1.9f * s), x->qr_nota, cw - 2 * pad);
			float w = testo(NULL, f_reg, px, 0, 0, x->qr_nota, 0, 0, 0);
			testo(t, f_reg, px, kx - w / 2, top + chh - 3.6f * s, x->qr_nota, 0x5B6478, 1, 0);
		}
	} else
		marchio(t, kx, ky, 11 * s);

	// Sinistra: l'indirizzo da aprire e due righe di spiegazione, centrate
	// in altezza (senza l'indirizzo alternativo il blocco e' piu' basso).
	float largo = (kx - cw / 2) - 6 * s - sx;
	float y = oy + (x->alt ? 35 : 38.5f) * s;
	if (x->occhiello)
		testo(t, f_bold, (int)(1.8f * s), sx, y, x->occhiello, C_ORO, 1, 0.3f * s);
	y += 10 * s;
	if (x->titolo) {
		// "http://" in tono smorzato: senza, certi browser cercano il nome.
		const char *pre = x->titolo_prefisso;
		int px = (int)(8 * s);
		float wp, wt;
		while (wp = testo(NULL, f_bold, px, 0, 0, pre, 0, 0, -0.01f * px),
		       wt = testo(NULL, f_bold, px, 0, 0, x->titolo, 0, 0, -0.01f * px),
		       px > 8 && wp + wt > largo)
			px = (int)(px * largo / (wp + wt));
		float tx = sx - 0.05f * px;
		if (pre)
			tx += testo(t, f_bold, px, tx, y, pre, C_SPENTO, 0.55f, -0.01f * px) - 0.01f * px;
		testo(t, f_bold, px, tx, y, x->titolo, C_TESTO, 1, -0.01f * px);
	}
	if (x->alt) {
		int px = (int)(2.8f * s);
		y += 7 * s;
		float w = x->alt_etichetta ? testo(t, f_reg, px, sx, y, x->alt_etichetta, C_SPENTO, 1, 0) + 1.2f * s : 0;
		testo(t, f_reg, px, sx + w, y, x->alt, C_CHIARO, 1, 0);
	}
	rett(t, sx + 2.5f * s, y + 5.5f * s, 2.5f * s, 0.2f * s, 0.2f * s, C_ORO, 1, 0, 0);
	y += 12 * s;
	if (x->riga1)
		testo(t, f_reg, adatta(f_reg, (int)(2.3f * s), x->riga1, largo), sx, y, x->riga1, C_SPENTO, 1, 0);
	if (x->riga2)
		testo(t, f_reg, adatta(f_reg, (int)(2.3f * s), x->riga2, largo), sx, y + 4.2f * s, x->riga2, C_SPENTO, 1, 0);

	// Piede: stato del player in una pillola, scorciatoia a destra.
	float py = oy + 90 * s;
	if (x->stato) {
		uint32_t c = C_ATTESA;
		if (x->stato_tipo && !strcmp(x->stato_tipo, "ok")) c = C_OK;
		if (x->stato_tipo && !strcmp(x->stato_tipo, "errore")) c = C_ERRORE;
		int px = (int)(2 * s);
		float w = testo(NULL, f_reg, px, 0, 0, x->stato, 0, 0, 0) + 7.2f * s;
		rett(t, sx + w / 2, py, w / 2, 2.6f * s, 2.6f * s, 0xFFFFFF, 0.06f, 0, 0);
		rett(t, sx + w / 2, py, w / 2, 2.6f * s, 2.6f * s, 0xFFFFFF, 0.10f, fmaxf(0.12f * s, 1), 0);
		cerchio(t, sx + 2.6f * s, py, 1.3f * s, c, 0.22f, 0);
		cerchio(t, sx + 2.6f * s, py, 0.65f * s, c, 1, 0);
		testo(t, f_reg, px, sx + 4.8f * s, py + 0.72f * s, x->stato, C_CHIARO, 1, 0);
	}
	if (x->tasto) {
		int pn = (int)(1.9f * s), pt = (int)(1.6f * s);
		float wn = x->tasto_nota ? testo(NULL, f_reg, pn, 0, 0, x->tasto_nota, 0, 0, 0) : 0;
		float wt = testo(NULL, f_bold, pt, 0, 0, x->tasto, 0, 0, 0.05f * s);
		float tx = dx - wn - (wn ? 1.4f * s : 0) - wt - 2.4f * s;
		rett(t, tx + wt / 2 + 1.2f * s, py, wt / 2 + 1.2f * s, 1.9f * s, 0.8f * s, 0xFFFFFF, 0.08f, 0, 0);
		rett(t, tx + wt / 2 + 1.2f * s, py, wt / 2 + 1.2f * s, 1.9f * s, 0.8f * s, 0xFFFFFF, 0.18f, fmaxf(0.12f * s, 1), 0);
		testo(t, f_bold, pt, tx + 1.2f * s, py + 0.58f * s, x->tasto, C_CHIARO, 1, 0.05f * s);
		if (x->tasto_nota)
			testo(t, f_reg, pn, dx - wn, py + 0.68f * s, x->tasto_nota, C_SPENTO, 1, 0);
	}
}

// Lettura del file dei testi: il buffer resta vivo, i campi puntano dentro.
static char buf[8192];

static int leggi(const char *path, Testi *x)
{
	memset(x, 0, sizeof(*x));
	FILE *f = fopen(path, "r");
	if (!f) return -1;
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	static const struct { const char *k; size_t o; } chiavi[] = {
#define K(n) { #n, offsetof(Testi, n) }
		K(occhiello), K(titolo_prefisso), K(titolo), K(alt_etichetta), K(alt), K(riga1), K(riga2),
		K(qr), K(qr_nota), K(stato), K(stato_tipo), K(tasto), K(tasto_nota),
#undef K
	};
	for (char *l = strtok(buf, "\n"); l; l = strtok(NULL, "\n")) {
		char *v = strchr(l, '=');
		if (!v || !v[1]) continue;
		*v++ = 0;
		for (size_t i = 0; i < sizeof(chiavi) / sizeof(*chiavi); i++)
			if (!strcmp(l, chiavi[i].k))
				*(const char **)((char *)x + chiavi[i].o) = v;
	}
	return 0;
}

static float rumore(int x, int y)
{
	uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
	h = (h ^ (h >> 13)) * 1274126177u;
	return ((h >> 16) & 0xFFFF) / 65535.0f - 0.5f;
}

// Da virgola mobile a 8 bit, con un filo di rumore contro le bande.
static int otto(float v, int x, int y)
{
	return (int)clampf(v * 255 + rumore(x, y) * 1.2f + 0.5f, 0, 255);
}

static int ppm(const char *out, int w, int h, const char *file)
{
	Testi x;
	Tela t = { w, h, calloc((size_t)w * h * 3, sizeof(float)) };
	if (!t.px || leggi(file, &x)) return 1;
	disegna(&t, &x);
	FILE *f = fopen(out, "wb");
	if (!f) return 1;
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	for (int y = 0; y < h; y++)
		for (int k = 0; k < w; k++)
			for (int i = 0; i < 3; i++)
				fputc(otto(t.px[3 * ((size_t)y * w + k) + i], k, y), f);
	return fclose(f) ? 1 : 0;
}

static uint32_t campo(int v, const struct fb_bitfield *b)
{
	return (uint32_t)(v >> (8 - (b->length > 8 ? 8 : b->length))) << b->offset;
}

// Disegna sul framebuffer, riaperto ogni volta: al caricamento del driver
// grafico (i915, amdgpu...) fb0 cambia dimensioni o sparisce e torna.
static int schermo(const char *file)
{
	struct fb_var_screeninfo v;
	struct fb_fix_screeninfo fx;
	Testi x;
	int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC), rc = 1;
	if (fd < 0) return 1;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &v) || ioctl(fd, FBIOGET_FSCREENINFO, &fx) ||
	    (v.bits_per_pixel != 16 && v.bits_per_pixel != 24 && v.bits_per_pixel != 32)) {
		close(fd);
		return 1;
	}
	int bpp = v.bits_per_pixel / 8;
	uint8_t *mem = mmap(NULL, fx.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	Tela t = { (int)v.xres, (int)v.yres, calloc((size_t)v.xres * v.yres * 3, sizeof(float)) };
	uint8_t *riga = malloc((size_t)v.xres * bpp);
	if (mem != MAP_FAILED && t.px && riga && !leggi(file, &x)) {
		disegna(&t, &x);
		for (int y = 0; y < t.h; y++) {
			for (int k = 0; k < t.w; k++) {
				const float *p = t.px + 3 * ((size_t)y * t.w + k);
				uint32_t c = campo(otto(p[0], k, y), &v.red) | campo(otto(p[1], k, y), &v.green) |
					     campo(otto(p[2], k, y), &v.blue);
				memcpy(riga + (size_t)k * bpp, &c, bpp);
			}
			size_t o = (size_t)(y + v.yoffset) * fx.line_length + (size_t)v.xoffset * bpp;
			if (o + (size_t)t.w * bpp <= fx.smem_len)
				memcpy(mem + o, riga, (size_t)t.w * bpp);
		}
		rc = 0;
	}
	if (mem != MAP_FAILED) munmap(mem, fx.smem_len);
	free(t.px);
	free(riga);
	close(fd);
	return rc;
}

// Il kernel avvisa quando si cambia console o lo schermo si riaccende: in
// quei momenti la console ridisegna il suo testo (vuoto) sopra il nostro.
static int pipe_vt[2], fd_tty;

static void *attendi_vt(void *arg)
{
	(void)arg;
	for (;;) {
		struct vt_event e = { .event = VT_EVENT_SWITCH | VT_EVENT_UNBLANK | VT_EVENT_RESIZE };
		if (ioctl(fd_tty, VT_WAITEVENT, &e) < 0) {
			if (errno == EINTR) continue;
			return NULL;
		}
		if (write(pipe_vt[1], "", 1) < 0) return NULL;
	}
}

static FT_Face carica(const char *const *nomi)
{
	FT_Face f;
	for (; *nomi; nomi++)
		if (!FT_New_Face(ft, *nomi, 0, &f)) return f;
	return NULL;
}

int main(int argc, char **argv)
{
	if (FT_Init_FreeType(&ft) || !(f_reg = carica(FONT_REG)) || !(f_bold = carica(FONT_BOLD))) {
		fprintf(stderr, "sweetspot-schermo: caratteri DejaVu non trovati\n");
		return 1;
	}
	if (argc == 5 && !strcmp(argv[1], "-o")) {
		int w, h;
		if (sscanf(argv[3], "%dx%d", &w, &h) != 2 || w < 64 || h < 64) return 2;
		return ppm(argv[2], w, h, argv[4]);
	}
	if (argc < 2 || argc > 3 || argv[1][0] == '-') {
		fprintf(stderr, "uso: sweetspot-schermo FILE [TTY] | -o OUT.ppm LxA FILE\n");
		return 2;
	}
	// Finisce con sweetspot-display, che lo avvia: SIGTERM, come uno stop.
	sigset_t ss;
	sigemptyset(&ss);
	sigaddset(&ss, SIGHUP);
	sigaddset(&ss, SIGTERM);
	sigaddset(&ss, SIGINT);
	sigprocmask(SIG_BLOCK, &ss, NULL);
	prctl(PR_SET_PDEATHSIG, SIGTERM);

	const char *tty = argc == 3 ? argv[2] : "/dev/tty1";
	int n_tty = atoi(tty + strcspn(tty, "0123456789"));
	if ((fd_tty = open(tty, O_RDWR | O_NOCTTY | O_CLOEXEC)) < 0) return 1;

	// Prima prova: se il framebuffer non c'e' lo script resta sul testo.
	struct termios prima, ora;
	int ha_termios = !tcgetattr(fd_tty, &prima);
	if (ha_termios) {
		ora = prima;
		ora.c_lflag &= ~(ECHO | ICANON);
		tcsetattr(fd_tty, TCSANOW, &ora);
	}
	// Cursore nascosto, schermo pulito.
	if (write(fd_tty, "\033[?25l\033[2J\033[H", 13) < 0) {}
	if (schermo(argv[1])) {
		if (write(fd_tty, "\033[?25h", 6) < 0) {}
		if (ha_termios) tcsetattr(fd_tty, TCSANOW, &prima);
		return 1;
	}

	int fd_sig = signalfd(-1, &ss, SFD_CLOEXEC);
	pthread_t th;
	if (fd_sig < 0 || pipe2(pipe_vt, O_CLOEXEC) || pthread_create(&th, NULL, attendi_vt, NULL))
		return 1;

	struct pollfd pf[2] = { { fd_sig, POLLIN, 0 }, { pipe_vt[0], POLLIN, 0 } };
	for (;;) {
		if (poll(pf, 2, -1) < 0) {
			if (errno == EINTR) continue;
			break;
		}
		int ridisegna = 0;
		if (pf[0].revents & POLLIN) {
			struct signalfd_siginfo si;
			if (read(fd_sig, &si, sizeof(si)) != sizeof(si)) continue;
			if (si.ssi_signo != SIGHUP) break;
			ridisegna = 1;
		}
		if (pf[1].revents & POLLIN) {
			char b[16];
			if (read(pipe_vt[0], b, sizeof(b)) < 0) {}
			// Lascia finire alla console il suo ridisegno.
			usleep(60000);
			ridisegna = 1;
		}
		struct vt_stat st;
		if (ridisegna && (ioctl(fd_tty, VT_GETSTATE, &st) || st.v_active == n_tty))
			schermo(argv[1]);
	}
	if (write(fd_tty, "\033[2J\033[H\033[?25h", 13) < 0) {}
	if (ha_termios) tcsetattr(fd_tty, TCSANOW, &prima);
	return 0;
}
