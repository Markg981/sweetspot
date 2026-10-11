/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Sweetspot - un comando al server websocket di CamillaDSP (solo locale).
 * Stampa la risposta JSON cosi' com'e', per esempio:
 *
 *   sweetspot-camilla 1234 GetClippedSamples
 *   {"GetClippedSamples":{"result":"Ok","value":0}}
 *
 * Basta un client minimo: una connessione, un messaggio di testo, una
 * risposta. Esce con 1 se CamillaDSP non risponde entro due secondi.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>

#define MAX_REPLY 65536

static int send_all(int fd, const unsigned char *buf, size_t len)
{
	while (len > 0) {
		ssize_t n = write(fd, buf, len);
		if (n <= 0)
			return -1;
		buf += n;
		len -= (size_t)n;
	}
	return 0;
}

static int recv_all(int fd, unsigned char *buf, size_t len)
{
	while (len > 0) {
		ssize_t n = read(fd, buf, len);
		if (n <= 0)
			return -1;
		buf += n;
		len -= (size_t)n;
	}
	return 0;
}

/* Legge l'intestazione HTTP della risposta all'handshake fino alla riga vuota. */
static int handshake(int fd, int port)
{
	char req[256], head[2048];
	size_t used = 0;

	snprintf(req, sizeof(req),
		 "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
		 "Connection: Upgrade\r\nSec-WebSocket-Key: c3dlZXRzcG90LWNhbWlsbA==\r\n"
		 "Sec-WebSocket-Version: 13\r\n\r\n", port);
	if (send_all(fd, (const unsigned char *)req, strlen(req)) != 0)
		return -1;
	while (used < sizeof(head) - 1) {
		if (read(fd, head + used, 1) != 1)
			return -1;
		used++;
		head[used] = '\0';
		if (used >= 4 && strcmp(head + used - 4, "\r\n\r\n") == 0)
			return strncmp(head, "HTTP/1.1 101", 12) == 0 ? 0 : -1;
	}
	return -1;
}

/* Il client deve mascherare i propri frame; la maschera puo' essere fissa. */
static int send_text(int fd, const char *text)
{
	static const unsigned char mask[4] = { 0x5e, 0x37, 0xa1, 0x0c };
	unsigned char frame[14 + 512];
	size_t len = strlen(text), h = 0, i;

	if (len > 512)
		return -1;
	frame[h++] = 0x81;
	if (len < 126) {
		frame[h++] = 0x80 | (unsigned char)len;
	} else {
		frame[h++] = 0x80 | 126;
		frame[h++] = (unsigned char)(len >> 8);
		frame[h++] = (unsigned char)len;
	}
	memcpy(frame + h, mask, 4);
	h += 4;
	for (i = 0; i < len; i++)
		frame[h + i] = (unsigned char)text[i] ^ mask[i % 4];
	return send_all(fd, frame, h + len);
}

/* Primo frame di testo della risposta (salta ping e altri frame di controllo). */
static int recv_text(int fd, char *out, size_t cap)
{
	unsigned char h[8];
	unsigned long long len;
	int opcode, i;

	for (;;) {
		if (recv_all(fd, h, 2) != 0)
			return -1;
		opcode = h[0] & 0x0f;
		len = h[1] & 0x7f;
		if (h[1] & 0x80)
			return -1;
		if (len == 126) {
			if (recv_all(fd, h, 2) != 0)
				return -1;
			len = ((unsigned long long)h[0] << 8) | h[1];
		} else if (len == 127) {
			if (recv_all(fd, h, 8) != 0)
				return -1;
			for (len = 0, i = 0; i < 8; i++)
				len = (len << 8) | h[i];
		}
		if (len >= cap)
			return -1;
		if (recv_all(fd, (unsigned char *)out, (size_t)len) != 0)
			return -1;
		out[len] = '\0';
		if (opcode == 0x1)
			return 0;
		if (opcode == 0x8)
			return -1;
	}
}

int main(int argc, char **argv)
{
	struct sockaddr_in addr;
	struct timeval tv = { 2, 0 };
	char command[520];
	static char reply[MAX_REPLY];
	int fd, port;

	if (argc != 3 || (port = atoi(argv[1])) <= 0 || port > 65535 ||
	    strlen(argv[2]) > 500 || strpbrk(argv[2], "\"\\")) {
		fprintf(stderr, "uso: sweetspot-camilla PORTA COMANDO\n");
		return 2;
	}
	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return 1;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((unsigned short)port);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	snprintf(command, sizeof(command), "\"%s\"", argv[2]);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
	    handshake(fd, port) != 0 || send_text(fd, command) != 0 ||
	    recv_text(fd, reply, sizeof(reply)) != 0) {
		close(fd);
		return 1;
	}
	close(fd);
	puts(reply);
	return 0;
}
