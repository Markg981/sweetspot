/* Estratto fedele di ffmpeg.c di Squeezelite (ralph-irving/squeezelite
 * 72e1fd8abfa9b2f8e9636f033247526920878718): costanti di lettura e
 * registrazione dei codec wma e alc in register_ff. La patch 0008 si applica
 * a questo file; struct codec e le funzioni del decoder sono in stubs.h. */
#include "stubs.h"

#define READ_SIZE  4096 * 4   // this is large enough to ensure ffmpeg always gets new data when decode is called
#define WRITE_SIZE 256 * 1024 // FIXME - make smaller, but still to absorb max wma output

// FIXME - do we need to align these params as per ffmpeg on i386? 
#define attribute_align_arg

struct codec *register_ff(const char *codec) {
	if (!strcmp(codec, "wma")) {

		static struct codec ret = { 
			'w',         // id
			"wma,wmap,wmal", // types
			READ_SIZE,   // min read
			WRITE_SIZE,  // min space
			ff_open_wma, // open
			ff_close,    // close
			ff_decode,   // decode
		};
		
		LOG_INFO("using ffmpeg to decode wma,wmap,wmal");
		return &ret;
	}

	if (!strcmp(codec, "alc")) {

		static struct codec ret = { 
			'l',         // id
			"alc",       // types
			READ_SIZE,   // min read
			WRITE_SIZE,  // min space
			ff_open_alac,// open
			ff_close,    // close
			ff_decode,   // decode
		};
		
		LOG_INFO("using ffmpeg to decode alc");		
		return &ret;
	}

	return NULL;
}
