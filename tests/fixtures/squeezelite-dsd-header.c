/*
 *  Squeezelite - lightweight headless squeezebox emulator
 *
 *  (c) Adrian Smith 2012-2015, triode1@btinternet.com
 *      Ralph Irving 2015-2025, ralph_irving@hotmail.com
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

/* Exact relevant declarations, unpack helpers and _read_header from:
 * https://github.com/ralph-irving/squeezelite/blob/72e1fd8abfa9b2f8e9636f033247526920878718/dsd.c
 * Upstream lines 64, 68-207; source version selected by Buildroot 2026.08.
 * Full upstream dsd.c SHA-256:
 * 86c554133aa33aa5cdbe007ec88e18d6951d7b5d831003d283435912c0e38e3d
 * Code kept unmodified; only trailing whitespace normalized. Tests apply
 * the actual Sweetspot Buildroot patch before compilation.
 * The complete GPL-3.0-or-later license is in ../../LICENSE.
 */

typedef enum { UNKNOWN=0, DSF, DSDIFF } dsd_type;

struct dsd {
	dsd_type type;
	u32_t consume;
	u32_t sample_rate;
	u32_t channels;
	u64_t sample_bytes;
	u32_t block_size;
	bool  lsb_first;
	dsd2pcm_ctx *dsd2pcm_ctx[2];
	float *transfer[2];
};

static struct dsd *d;

static u64_t unpack64be(const u8_t *p) {
	return
		(u64_t)p[0] << 56 | (u64_t)p[1] << 48 | (u64_t)p[2] << 40 | (u64_t)p[3] << 32 |
		(u64_t)p[4] << 24 | (u64_t)p[5] << 16 |	(u64_t)p[6] << 8 | (u64_t)p[7];
}

static u64_t unpack64le(const u8_t *p) {
	return
		(u64_t)p[7] << 56 | (u64_t)p[6] << 48 | (u64_t)p[5] << 40 | (u64_t)p[4] << 32 |
		(u64_t)p[3] << 24 | (u64_t)p[2] << 16 |	(u64_t)p[1] << 8 | (u64_t)p[0];
}

static u32_t unpack32le(const u8_t *p) {
	return
		(u32_t)p[3] << 24 | (u32_t)p[2] << 16 |	(u32_t)p[1] << 8 | (u32_t)p[0];
}

static int _read_header(void) {
	unsigned bytes = min(_buf_used(streambuf), _buf_cont_read(streambuf));
	s32_t consume;

	if (!d->type && bytes >= 4) {
		if (!memcmp(streambuf->readp, "FRM8", 4)) {
			d->type = DSDIFF;
		} else if (!memcmp(streambuf->readp, "DSD ", 4)) {
			d->type = DSF;
		} else {
			LOG_WARN("bad type");
			return -1;
		}
	}

	while (bytes >= 16) {
		char id[5];
		u64_t len = d->type == DSDIFF ? unpack64be(streambuf->readp + 4) : unpack64le(streambuf->readp + 4);
		memcpy(id, streambuf->readp, 4);
		id[4] = '\0';
		consume = 0;

		if (d->type == DSDIFF) {
			if (!strcmp(id, "FRM8")) {
				if (!memcmp(streambuf->readp + 12, "DSD ", 4)) {
					consume = 16; // read into
				} else {
					LOG_WARN("bad dsdiff FRM8");
					return -1;
				}
			}
			if (!strcmp(id, "PROP") && !memcmp(streambuf->readp + 12, "SND ", 4)) {
				consume = 16; // read into
			}
			if (!strcmp(id, "FVER")) {
				LOG_INFO("DSDIFF version: %u.%u.%u.%u", *(streambuf->readp + 12), *(streambuf->readp + 13),
					 *(streambuf->readp + 14), *(streambuf->readp + 15));
			}
			if (!strcmp(id, "FS  ")) {
				d->sample_rate = unpackN((void *)(streambuf->readp + 12));
				LOG_INFO("sample rate: %u", d->sample_rate);
			}
			if (!strcmp(id, "CHNL")) {
				d->channels = unpackn((void *)(streambuf->readp + 12));
				LOG_INFO("channels: %u", d->channels);
			}
			if (!strcmp(id, "DSD ")) {
				LOG_INFO("found dsd len: " FMT_u64, len);
				d->sample_bytes = len;
				_buf_inc_readp(streambuf, 12);
				bytes  -= 12;
				return 1; // got to the audio
			}
		}

		if (d->type == DSF) {
			if (!strcmp(id, "fmt ")) {
				if (bytes >= len && bytes >= 52) {
					u32_t version = unpack32le((void *)(streambuf->readp + 12));
					u32_t format  = unpack32le((void *)(streambuf->readp + 16));
					LOG_INFO("DSF version: %u format: %u", version, format);
					if (format != 0) {
						LOG_WARN("only support DSD raw format");
						return -1;
					}
					d->channels = unpack32le((void *)(streambuf->readp + 24));
					d->sample_rate = unpack32le((void *)(streambuf->readp + 28));
					d->lsb_first = (unpack32le((void *)(streambuf->readp + 32)) == 1);
					d->sample_bytes = unpack64le((void *)(streambuf->readp + 36)) / 8;
					d->block_size = unpack32le((void *)(streambuf->readp + 44));
					LOG_INFO("channels: %u", d->channels);
					LOG_INFO("sample rate: %u", d->sample_rate);
					LOG_INFO("lsb first: %u", d->lsb_first);
					LOG_INFO("sample bytes: " FMT_u64, d->sample_bytes);
					LOG_INFO("block size: %u", d->block_size);
				} else {
					consume = -1; // come back later
				}
			}
			if (!strcmp(id, "data")) {
				LOG_INFO("found dsd len: " FMT_u64, len);
				_buf_inc_readp(streambuf, 12);
				bytes  -= 12;
				return 1; // got to the audio
			}
		}

		// default to consuming whole chunk
		if (!consume) {
			consume = (s32_t)((d->type == DSDIFF) ? len + 12 : len);
		}

		if (bytes >= consume) {
			LOG_DEBUG("id: %s len: " FMT_u64 " consume: %d", id, len, consume);
			_buf_inc_readp(streambuf, consume);
			bytes  -= consume;
		} else if (consume > 0) {
			LOG_DEBUG("id: %s len: " FMT_u64 " consume: %d - partial consume: %u", id, len, consume, bytes);
			_buf_inc_readp(streambuf, bytes);
			d->consume = consume - bytes;
			break;
		} else {
			break;
		}
	}

	return 0;
}
