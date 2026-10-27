/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - alsa-cdsp: dopo un timeout la FIFO non deve contenere un frame
 * a meta'. Il sorgente di session_silence() si estrae da
 * package/alsa-cdsp/0002-session-mode.patch (vedi alsa-cdsp-frame.sh).
 *
 * Una write() parziale puo' fermarsi a un byte qualsiasi (POSIX); qui un
 * lettore simulato accetta pochi byte alla volta, si ferma con 3 byte di un
 * frame gia' scritti e riparte dopo il timeout. La scrittura deve completare
 * il frame; il totale nella FIFO deve essere multiplo del frame.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define SESSION_FRAME_BYTES 8
#define STOP_AT 1003            /* 125 frame e 3 byte */
#define RESUME_MS 2000          /* oltre il limite (500 + 1000 ms) */
static unsigned long long session_frames;
static long accepted;
static struct timespec t_start;

static long ms_since_start(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (t.tv_sec - t_start.tv_sec) * 1000L + (t.tv_nsec - t_start.tv_nsec) / 1000000L;
}

/* Lettore simulato: al massimo 5 byte per chiamata; fermo ("pieno") a
 * STOP_AT fino a RESUME_MS, poi accetta solo fino al frame intero e si
 * ferma di nuovo. */
static ssize_t fake_write(int fd, const void *b, size_t n) {
  long room = STOP_AT - accepted;
  if(room <= 0 && ms_since_start() >= RESUME_MS)
    room = (SESSION_FRAME_BYTES - accepted % SESSION_FRAME_BYTES) % SESSION_FRAME_BYTES;
  if(room <= 0) {
    usleep(1000);
    errno = EAGAIN;
    return -1;
  }
  if(n > 5) n = 5;
  if((long)n > room) n = (size_t)room;
  n = (size_t)write(fd, b, n);
  accepted += (long)n;
  return (ssize_t)n;
}
#define write fake_write
#include "session_silence.inc"
#undef write

int main(void) {
  int p[2], rc;
  clock_gettime(CLOCK_MONOTONIC, &t_start);
  if(pipe(p)) return 2;
  /* 1000 frame a 1000 Hz: limite 500 + 1000 ms */
  rc = session_silence(p[1], 1000, 1000);
  printf("rc=%d byte=%ld (resto %ld)\n", rc, accepted, accepted % SESSION_FRAME_BYTES);
  return rc == -1 && accepted % SESSION_FRAME_BYTES == 0 ? 0 : 1;
}
