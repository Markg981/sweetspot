/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - comunica al kernel una partizione appena aggiunta alla
 * tabella (BLKPG_ADD_PARTITION), senza rileggere tutta la tabella: funziona
 * anche mentre un'altra partizione dello stesso disco e' in uso.
 *
 *   sweetspot-partizione DISCO NUMERO INIZIO SETTORI   (settori da 512 byte)
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/blkpg.h>

static long long number(const char *s)
{
	char *end;
	long long v;

	errno = 0;
	v = strtoll(s, &end, 10);
	if (errno || *s == '\0' || *end != '\0' || v < 0)
		return -1;
	return v;
}

int main(int argc, char **argv)
{
	struct blkpg_partition part;
	struct blkpg_ioctl_arg arg;
	long long pno, start, size;
	int fd;

	if (argc != 5) {
		fprintf(stderr, "uso: %s DISCO NUMERO INIZIO SETTORI\n", argv[0]);
		return 2;
	}
	pno = number(argv[2]);
	start = number(argv[3]);
	size = number(argv[4]);
	if (pno < 1 || pno > 4 || start <= 0 || size <= 0) {
		fprintf(stderr, "%s: valori non validi\n", argv[0]);
		return 2;
	}

	memset(&part, 0, sizeof(part));
	part.pno = (int)pno;
	part.start = start * 512;
	part.length = size * 512;
	memset(&arg, 0, sizeof(arg));
	arg.op = BLKPG_ADD_PARTITION;
	arg.datalen = sizeof(part);
	arg.data = &part;

	fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	if (ioctl(fd, BLKPG, &arg) != 0) {
		perror("BLKPG_ADD_PARTITION");
		close(fd);
		return 1;
	}
	close(fd);
	return 0;
}
