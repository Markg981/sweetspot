/* SPDX-License-Identifier: GPL-3.0-or-later
 * Pubblica un file sullo stesso filesystem senza sovrascrivere la destinazione.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct stat st;
	char *parent;
	int fd, dirfd;

	if (argc != 3) {
		fprintf(stderr, "uso: %s ORIGINE DESTINAZIONE\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		fprintf(stderr, "%s: origine non valida, serve un file regolare\n", argv[1]);
		close(fd);
		return 1;
	}
	if (fsync(fd) != 0) {
		perror(argv[1]);
		close(fd);
		return 1;
	}
	if (close(fd) != 0) {
		perror(argv[1]);
		return 1;
	}
	parent = strdup(argv[2]);
	if (!parent) {
		perror("pubblicazione");
		return 1;
	}
	dirfd = open(dirname(parent), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	free(parent);
	if (dirfd < 0) {
		perror(argv[2]);
		return 1;
	}
	/* Un controllo in shell seguito da rename lascerebbe una finestra di gara. */
	if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_NOREPLACE) != 0) {
		int rc = errno == EEXIST ? 3 : 1;
		perror(argv[2]);
		close(dirfd);
		return rc;
	}
	if (fsync(dirfd) != 0) {
		perror("pubblicazione: sincronizzazione della cartella");
		close(dirfd);
		return 1;
	}
	if (close(dirfd) != 0) {
		perror("pubblicazione: chiusura della cartella");
		return 1;
	}
	return 0;
}
