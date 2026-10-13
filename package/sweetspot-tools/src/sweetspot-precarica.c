/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - precarico dei brani in RAM. I buffer del player non bastano:
 * la cache del kernel puo' liberare le pagine di un file in qualunque
 * momento. Qui ogni file viene mappato e bloccato in memoria (mlock), cosi'
 * resta in RAM finche' il processo e' vivo e il disco puo' fermarsi.
 *
 *   sweetspot-precarica tieni ELENCO STATO
 *       carica i file elencati (un percorso per riga), li blocca in RAM e
 *       resta attivo fino a SIGTERM. STATO viene riscritto dopo ogni file:
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_FILES 4096

struct entry {
	char *path;
	long long size;
	char result[160];
};

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int write_state(const char *state, const char *phase, struct entry *e, int n)
{
	char tmp[4096];
	FILE *f;
	int i;

	if (snprintf(tmp, sizeof(tmp), "%s.tmp", state) >= (int)sizeof(tmp))
		return -1;
	f = fopen(tmp, "w");
	if (!f)
		return -1;
	fprintf(f, "stato\t%s\n", phase);
	for (i = 0; i < n; i++)
		fprintf(f, "file\t%lld\t%s\t%s\n", e[i].size, e[i].result, e[i].path);
	if (fclose(f) != 0)
		return -1;
	return rename(tmp, state);
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
	snprintf(e->result, sizeof(e->result), "ok");
}

static int cmd_hold(const char *list, const char *state)
{
	static struct entry e[MAX_FILES];
	struct sigaction sa;
	char line[4096];
	FILE *f;
	int n = 0, i;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	f = fopen(list, "r");
	if (!f) {
		perror(list);
		return 2;
	}
	while (n < MAX_FILES && fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\n")] = 0;
		if (!*line)
			continue;
		e[n].path = strdup(line);
		if (!e[n].path) {
			fclose(f);
			return 2;
		}
		e[n].size = 0;
		snprintf(e[n].result, sizeof(e[n].result), "in attesa");
		n++;
	}
	fclose(f);

	write_state(state, "caricamento", e, n);
	for (i = 0; i < n && !stop; i++) {
		hold(&e[i]);
		write_state(state, "caricamento", e, n);
	}
	if (stop)
		return 0;
	if (write_state(state, "pronto", e, n) != 0) {
		perror(state);
		return 2;
	}
	while (!stop)
		pause();
	return 0;
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
