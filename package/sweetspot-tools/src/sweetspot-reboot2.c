/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - riavvio con un argomento per il firmware (reboot RESTART2).
 * Sul Raspberry Pi "0 tryboot" fa partire una volta sola la copia del
 * sistema indicata in tryboot.txt. Va chiamato dopo aver fermato i servizi
 * (lo fa sweetspot-riavvia): qui si riavvia e basta.
 *
 *   sweetspot-reboot2 "0 tryboot"
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(int argc, char **argv)
{
	const char *arg = argc > 1 ? argv[1] : "";

	sync();
	if (syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		    LINUX_REBOOT_CMD_RESTART2, arg) != 0) {
		perror("sweetspot-reboot2");
		return 1;
	}
	return 0;
}
