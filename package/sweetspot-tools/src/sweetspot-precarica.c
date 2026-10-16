/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - precarico dei brani in RAM. I buffer del player non bastano:
 * la cache del kernel puo' liberare le pagine di un file in qualunque
 * momento. Qui ogni file viene mappato e bloccato in memoria (mlock), cosi'
 * resta in RAM finche' il processo e' vivo e il disco puo' fermarsi.
 *
 *   sweetspot-precarica tieni ELENCO STATO
 *       carica i file elencati (un percorso per riga), li blocca in RAM e
 *       resta attivo fino a SIGTERM. Con SIGUSR1 rilegge ELENCO e rilascia
 *       (munlock/munmap) i file che non ci sono piu': e' come il precarico
 *       cede memoria quando scende sotto la riserva. STATO viene riscritto
 *       durante il caricamento (al massimo una volta al secondo) e alla fine:
 *           stato<TAB>caricamento|pronto
 *           file<TAB>byte<TAB>ok|errore: motivo<TAB>percorso
 *   sweetspot-precarica residenza FILE...
 *       per ogni file stampa "byte_in_ram<TAB>byte<TAB>percorso", senza
 *       caricarlo (mincore).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct entry {
	char *path;
	long long size;
	char result[160];
	void *map;
	int dropped;
};

static volatile sig_atomic_t stop;
static volatile sig_atomic_t reload;

static void on_reload(int sig)
{
	(void)sig;
	reload = 1;
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int write_state(const char *state, const char *phase, struct entry *e, size_t n)
{
	char tmp[4096];
	FILE *f;
	size_t i;

	if (snprintf(tmp, sizeof(tmp), "%s.tmp", state) >= (int)sizeof(tmp))
		return -1;
	f = fopen(tmp, "w");
	if (!f)
		return -1;
	fprintf(f, "stato\t%s\n", phase);
	for (i = 0; i < n; i++)
		if (!e[i].dropped)
			fprintf(f, "file\t%lld\t%s\t%s\n", e[i].size, e[i].result, e[i].path);
	if (fclose(f) != 0)
		return -1;
	return rename(tmp, state);
}

static void free_paths(char **paths, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++)
		free(paths[i]);
	free(paths);
}

static int read_paths(const char *list, char ***paths, size_t *count)
{
	FILE *f = fopen(list, "r");
	char *line = NULL, **items = NULL;
	size_t length = 0, n = 0, capacity = 0;
	int saved;

	if (!f)
		return -1;
	while (getline(&line, &length, f) >= 0) {
		line[strcspn(line, "\n")] = 0;
		if (!*line)
			continue;
		if (n == capacity) {
			char **grown;
			size_t next;

			if (capacity > SIZE_MAX / sizeof(*items) / 2) {
				errno = ENOMEM;
				goto failed;
			}
			next = capacity ? capacity * 2 : 128;
			grown = realloc(items, next * sizeof(*items));
			if (!grown)
				goto failed;
			items = grown;
			capacity = next;
		}
		items[n] = strdup(line);
		if (!items[n])
			goto failed;
		n++;
	}
	if (ferror(f))
		goto failed;
	free(line);
	if (fclose(f) != 0) {
		saved = errno;
		free_paths(items, n);
		errno = saved;
		return -1;
	}
	*paths = items;
	*count = n;
	return 0;

failed:
	saved = errno;
	free(line);
	fclose(f);
	free_paths(items, n);
	errno = saved;
	return -1;
}

/* Mappa e blocca un file: mlock legge dal disco ogni pagina mancante. */
static void hold(struct entry *e)
{
	struct stat st;
	void *p;
	int fd;

	fd = open(e->path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		snprintf(e->result, sizeof(e->result), "errore: %s", strerror(errno));
		return;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		snprintf(e->result, sizeof(e->result), "errore: non e' un file");
		close(fd);
		return;
	}
	e->size = st.st_size;
	if (st.st_size == 0) {
		snprintf(e->result, sizeof(e->result), "ok");
		close(fd);
		return;
	}
	p = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
	close(fd);
	if (p == MAP_FAILED) {
		snprintf(e->result, sizeof(e->result), "errore: %s", strerror(errno));
		return;
	}
	posix_madvise(p, st.st_size, POSIX_MADV_WILLNEED);
	if (mlock(p, st.st_size) != 0) {
		snprintf(e->result, sizeof(e->result), "errore: %s", strerror(errno));
		munmap(p, st.st_size);
		return;
	}
	e->map = p;
	snprintf(e->result, sizeof(e->result), "ok");
}

/* Rilegge l'elenco: i file che non ci sono piu' si sbloccano e si liberano. */
static int compare_paths(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static int drop_missing(const char *list, struct entry *e, size_t n)
{
	char **keep = NULL;
	size_t i, k = 0;

	if (read_paths(list, &keep, &k) != 0)
		return -1;
	if (k)
		qsort(keep, k, sizeof(*keep), compare_paths);
	for (i = 0; i < n; i++) {
		if (e[i].dropped)
			continue;
		if (k && bsearch(&e[i].path, keep, k, sizeof(*keep), compare_paths))
			continue;
		if (e[i].map) {
			munlock(e[i].map, e[i].size);
			munmap(e[i].map, e[i].size);
			e[i].map = NULL;
		}
		e[i].dropped = 1;
	}
	free_paths(keep, k);
	return 0;
}

static int cmd_hold(const char *list, const char *state)
{
	struct entry *e;
	struct sigaction sa;
	struct timespec now;
	char **paths = NULL;
	size_t n = 0, i;
	time_t last_report = 0;
	int rc = 2;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sa.sa_handler = on_reload;
	sigaction(SIGUSR1, &sa, NULL);

	if (read_paths(list, &paths, &n) != 0) {
		perror(list);
		return 2;
	}
	e = calloc(n ? n : 1, sizeof(*e));
	if (!e) {
		perror("precarica");
		free_paths(paths, n);
		return 2;
	}
	for (i = 0; i < n; i++) {
		e[i].path = paths[i];
		snprintf(e[i].result, sizeof(e[i].result), "in attesa");
	}
	free(paths);

	if (write_state(state, "caricamento", e, n) != 0) {
		perror(state);
		goto done;
	}
	for (i = 0; i < n && !stop; i++) {
		if (reload) {
			reload = 0;
			if (drop_missing(list, e, n) != 0) {
				perror(list);
				goto done;
			}
		}
		if (e[i].dropped)
			continue;
		hold(&e[i]);
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
			perror("clock_gettime");
			goto done;
		}
		if (now.tv_sec != last_report) {
			if (write_state(state, "caricamento", e, n) != 0) {
				perror(state);
				goto done;
			}
			last_report = now.tv_sec;
		}
	}
	if (stop) {
		rc = 0;
		goto done;
	}
	if (write_state(state, "pronto", e, n) != 0) {
		perror(state);
		goto done;
	}
	while (!stop) {
		if (reload) {
			reload = 0;
			if (drop_missing(list, e, n) != 0) {
				perror(list);
				goto done;
			}
			if (write_state(state, "pronto", e, n) != 0) {
				perror(state);
				goto done;
			}
		}
		sleep(1);
	}
	rc = 0;
done:
	for (i = 0; i < n; i++) {
		if (e[i].map) {
			munlock(e[i].map, e[i].size);
			munmap(e[i].map, e[i].size);
		}
		free(e[i].path);
	}
	free(e);
	return rc;
}

static int cmd_residency(int argc, char **argv)
{
	long page = sysconf(_SC_PAGESIZE);
	int i, rc = 0;

	for (i = 0; i < argc; i++) {
		struct stat st;
		unsigned char *vec;
		long long resident = 0, pages, j;
		void *p;
		int fd = open(argv[i], O_RDONLY | O_CLOEXEC);

		if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
			if (fd >= 0)
				close(fd);
			fprintf(stderr, "%s: non leggibile\n", argv[i]);
			rc = 1;
			continue;
		}
		if (st.st_size == 0) {
			close(fd);
			printf("0\t0\t%s\n", argv[i]);
			continue;
		}
		p = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
		close(fd);
		pages = (st.st_size + page - 1) / page;
		vec = p == MAP_FAILED ? NULL : malloc(pages);
		if (!vec || mincore(p, st.st_size, vec) != 0) {
			fprintf(stderr, "%s: residenza non disponibile\n", argv[i]);
			free(vec);
			if (p != MAP_FAILED)
				munmap(p, st.st_size);
			rc = 1;
			continue;
		}
		for (j = 0; j < pages; j++)
			if (vec[j] & 1)
				resident += j == pages - 1 ? st.st_size - j * page : page;
		printf("%lld\t%lld\t%s\n", resident, (long long)st.st_size, argv[i]);
		free(vec);
		munmap(p, st.st_size);
	}
	return rc;
}

int main(int argc, char **argv)
{
	if (argc == 4 && strcmp(argv[1], "tieni") == 0)
		return cmd_hold(argv[2], argv[3]);
	if (argc >= 3 && strcmp(argv[1], "residenza") == 0)
		return cmd_residency(argc - 2, argv + 2);
	fprintf(stderr, "uso: sweetspot-precarica tieni ELENCO STATO | residenza FILE...\n");
	return 2;
}
