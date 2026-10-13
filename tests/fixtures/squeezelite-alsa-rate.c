/* Estratto fedele di output_alsa.c di Squeezelite (ralph-irving/squeezelite
 * 72e1fd8abfa9b2f8e9636f033247526920878718): variabile dell'uscita e blocco
 * che imposta la frequenza su hw: con ripiego su plughw:. La patch 0003 si
 * applica a questo file; l'API ALSA e' simulata da stubs.h. */
#include "stubs.h"

static struct {
	char device[64];
} alsa;

static snd_pcm_t *pcmp = NULL;

extern u8_t *silencebuf;

static int open_rate(const char *device, unsigned sample_rate) {
	int err;
	bool retry;
	snd_pcm_hw_params_t *hw_params = NULL;
	do {
		// open hw: devices without resampling, if sample rate fails try plughw: with resampling
		bool hw = !strncmp(alsa.device, "hw:", 3);
		retry = false;

		if ((err = snd_pcm_hw_params_set_rate_resample(pcmp, hw_params, !hw)) < 0) {
			LOG_ERROR("resampling setup failed: %s", snd_strerror(err));
			return err;
		}

		if ((err = snd_pcm_hw_params_set_rate(pcmp, hw_params, sample_rate, 0)) < 0) {
			if (hw) {
				strcpy(alsa.device + 4, device);
				memcpy(alsa.device, "plug", 4);
				LOG_INFO("reopening device %s in plug mode as %s for resampling", device, alsa.device);
				snd_pcm_close(pcmp);
				retry = true;
			}
		}

	} while (retry);
	return 0;
}
