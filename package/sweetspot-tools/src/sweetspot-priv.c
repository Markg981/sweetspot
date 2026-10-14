// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sweetspot - helper privilegiato del pannello web.
//
// L'httpd di BusyBox e le pagine CGI girano come utente "web" (httpd -u).
// Le poche operazioni che richiedono root passano da qui: il programma e'
// setuid root, parte solo se chi lo chiama e' root o "web", accetta un
// ELENCO CHIUSO di comandi (script di Sweetspot con sottocomando e argomenti
// controllati) e li esegue con un ambiente ripulito. Niente shell, niente
// percorsi dal chiamante, niente variabili d'ambiente ereditate.
//
//   sweetspot-priv sweetspot-config imposta CHIAVE VALORE ...
//   sweetspot-priv @riavvia | @spegni | @player | @autotune | @log TESTO
//
// Esce con 126 se la richiesta non e' nell'elenco (nulla viene eseguito).

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

// Solo per i test (tests/run.sh): niente controllo dell'utente, script finti
// in un'altra cartella e file delle pagine in un'altra base.
#ifdef SWEETSPOT_PRIV_PROVA
#define BIN_DIR PROVA_BIN
#define BASE_WEB PROVA_WEB
#else
#define BIN_DIR "/usr/bin/"
#define BASE_WEB "/run/sweetspot/web/"
#endif

#define UTENTE_WEB "web"
#define BASE_FILTRI "/run/sweetspot/correzione/" // filtri gia' salvati (di root)
#define LOGFILE "/var/log/sweetspot.log"
#define MAX_ARG 1024
#define MAX_FILE (1024 * 1024)
#define NO_ELENCO 126

// Tipi di argomento:
//  s  testo libero senza caratteri di controllo
//  w  parola: lettere, cifre, _ . : - (nomi, MAC, plugin)
//  n  numero 1-9 (condivisione di rete)
//  k  chiave di sweetspot.txt dell'elenco chiuso
//  p  file di testo scritto dalle pagine in BASE_WEB (si passa il
//     descrittore aperto senza seguire i collegamenti simbolici)
struct regola {
	const char *script; // nome in /usr/bin
	const char *sub;    // primo argomento
	const char *fissi;  // tipi degli argomenti dopo il sottocomando
	const char *ripeti; // tipi di un gruppo ripetuto (almeno una volta), o ""
};

static const struct regola REGOLE[] = {
	{"sweetspot-accesso", "applica", "", ""},
	{"sweetspot-accesso", "hash", "s", ""},
	{"sweetspot-accesso", "verifica", "", ""}, // password dall'ingresso standard
	{"sweetspot-aggiorna", "altra", "", ""},
	{"sweetspot-aggiorna", "annulla", "", ""},
	{"sweetspot-aggiorna", "cerca", "", ""},
	{"sweetspot-aggiorna", "file", "s", ""},
	{"sweetspot-aggiorna", "pacchetti", "", ""},
	{"sweetspot-aggiorna", "predefinita", "", ""},
	{"sweetspot-aggiorna", "scarica", "", ""},
	{"sweetspot-aggiorna", "stato", "", ""},
	{"sweetspot-cd", "annulla", "", ""},
	{"sweetspot-cd", "copia", "sss", ""},
	{"sweetspot-cd", "espelli", "", ""},
	{"sweetspot-cd", "leggi", "", ""},
	{"sweetspot-cd", "lettore", "", ""},
	{"sweetspot-cd", "stato", "", ""},
	{"sweetspot-check", "--dati", "", ""},
	{"sweetspot-config", "imposta", "", "ks"},
	{"sweetspot-config", "rimuovi", "", "k"},
	{"sweetspot-config", "ripristina", "", ""},
	{"sweetspot-copia", "annulla", "", ""},
	{"sweetspot-copia", "avvia", "s", ""},
	{"sweetspot-copia", "elimina", "s", ""},
	{"sweetspot-copia", "sorgente", "s", ""},
	{"sweetspot-copia", "stato", "", ""},
	{"sweetspot-diario", "bundle", "", ""}, // tar.gz diagnostico sull'uscita standard
	{"sweetspot-dischi", "archivio", "", ""},
	{"sweetspot-dischi", "monta", "", ""},
	{"sweetspot-dischi", "smonta", "s", ""},
	{"sweetspot-dsp", "fir", "", ""},
	{"sweetspot-dsp", "fir-frequenze", "", ""},
	{"sweetspot-dsp", "guadagno", "", ""},
	{"sweetspot-dsp", "leggi", "p", ""},
	{"sweetspot-dsp", "risposta", "", ""},
	{"sweetspot-dsp", "salva", "pp", ""},
	{"sweetspot-hotspot", "richiesta", "", ""},
	{"sweetspot-hotspot", "scansiona", "", ""},
	{"sweetspot-installa", "avvia", "ss", ""},
	{"sweetspot-installa", "dischi", "", ""},
	{"sweetspot-installa", "stato", "", ""},
	{"sweetspot-lms", "aggiorna", "", ""},
	{"sweetspot-lms", "json", "", ""}, // controllato a parte (lms_json_ok)
	{"sweetspot-lms", "plugin", "", ""}, // controllato a parte
	{"sweetspot-lms", "ricostruisci", "", ""},
	{"sweetspot-lms", "riavvia", "", ""},
	{"sweetspot-nas", "ferma", "", ""},
	{"sweetspot-nas", "riavvia", "", ""},
	{"sweetspot-rapporto", NULL, "", ""},
	{"sweetspot-rete", "prova", "n", ""},
	{"sweetspot-rete", "smonta-una", "n", ""},
	{"sweetspot-spazio", "crea", "", ""},
	{"sweetspot-spazio", "lavoro", "", ""},
	{"sweetspot-spazio", "stato", "", ""},
};

// Chiavi di sweetspot.txt che le pagine possono cambiare. Le altre
// (comandi, percorsi, opzioni di basso livello) si toccano solo dalla
// chiavetta, con il computer.
static const char *const CHIAVI[] = {
	"VOLUME", "DSD", "RICAMPIONAMENTO", "FILTRO", "FREQUENZA_MAX", "BUFFER_ALSA_MS",
	"PERIODI_ALSA", "PAUSA_FREQUENZA_MS", "PAUSA_DSD_MS", "ALTRI_DAC", "DAC",
	"ESCLUDI_DISCHI", "ARCHIVIO", "ARCHIVIO_CONDIVISO", "ARCHIVIO_PASSWORD",
	"WIFI_NOME", "WIFI_PASSWORD", "NOME_RETE", "RISPARMIO_RETE", "IP_FISSO",
	"GATEWAY", "DNS", "SCHEDA_I2S", "NOME_PLAYER", "MODALITA", "PROFILO",
	"MODALITA_ASCOLTO", "PRECARICO", "SSH", "SSH_PASSWORD", "OTTIMIZZAZIONI",
	"PASSWORD_WEB", "SERVER", "CORREZIONE", NULL,
};

static uid_t uid_web(void)
{
	struct passwd *p = getpwnam(UTENTE_WEB);
	return p ? p->pw_uid : (uid_t)-1;
}

static int testo_ok(const char *s)
{
	size_t n = strlen(s);
	if (n > MAX_ARG)
		return 0;
	for (; *s; s++)
		if ((unsigned char)*s < 0x20 || *s == 0x7f)
			return 0;
	return 1;
}

static int parola_ok(const char *s)
{
	size_t n = strlen(s);
	if (n == 0 || n > 64)
		return 0;
	for (; *s; s++)
		if (!isalnum((unsigned char)*s) && !strchr("_.:-", *s))
			return 0;
	return 1;
}

static int chiave_ok(const char *s)
{
	int i;
	// CONDIVISIONE_1..9 con _UTENTE, _PASSWORD e _SMB1
	if (!strncmp(s, "CONDIVISIONE_", 13) && s[13] >= '1' && s[13] <= '9') {
		const char *r = s + 14;
		return !*r || !strcmp(r, "_UTENTE") || !strcmp(r, "_PASSWORD") || !strcmp(r, "_SMB1");
	}
	for (i = 0; CHIAVI[i]; i++)
		if (!strcmp(s, CHIAVI[i]))
			return 1;
	return 0;
}

// Apre il file in BASE_WEB senza seguire collegamenti; ritorna il percorso
// /proc/self/fd/N da passare allo script (lo stesso file che abbiamo
// controllato, anche se nel frattempo la cartella cambia).
static char *file_web(const char *s, uid_t web)
{
	struct stat st;
	char *out;
	int fd;

	if ((strncmp(s, BASE_WEB, strlen(BASE_WEB)) && strncmp(s, BASE_FILTRI, strlen(BASE_FILTRI))) ||
	    strstr(s, "..") || !testo_ok(s))
		return NULL;
	fd = open(s, O_RDONLY | O_NOFOLLOW | O_NOCTTY);
	if (fd < 0)
		return NULL;
	if (fstat(fd, &st)) {
		close(fd);
		return NULL;
	}
#ifdef SWEETSPOT_PRIV_PROVA
	web = st.st_uid; // (nei test il proprietario e' chi esegue)
#endif
	if (!S_ISREG(st.st_mode) || st.st_size > MAX_FILE ||
	    (st.st_uid != web && st.st_uid != 0) || st.st_nlink != 1) {
		close(fd);
		return NULL;
	}
	if (asprintf(&out, "/proc/self/fd/%d", fd) < 0)
		return NULL;
	return out;
}

static int arg_ok(char tipo, const char *s, char **sost, uid_t web)
{
	*sost = NULL;
	switch (tipo) {
	case 's': return testo_ok(s);
	case 'w': return parola_ok(s);
	case 'n': return s[0] >= '1' && s[0] <= '9' && !s[1];
	case 'k': return chiave_ok(s);
	case 'p': *sost = file_web(s, web); return *sost != NULL;
	}
	return 0;
}

// Comandi di Lyrion consentiti alle pagine: stato del server, anteprima
// della prova DoP (e suo arresto), nome del player. Nient'altro: con Lyrion
// protetto da password questo helper parla a nome di Sweetspot.
static int lms_json_ok(int argc, char **argv)
{
	// argv: PLAYER PAROLA...
	const char *player;
	if (argc < 3 || !testo_ok(argv[0]))
		return 0;
	player = argv[0];
	if (argc == 4 && !strcmp(argv[1], "serverstatus") && !strcmp(argv[2], "0") &&
	    !strcmp(argv[3], "0"))
		return !*player || parola_ok(player);
	if (!parola_ok(player))
		return 0;
	if (argc == 4 && !strcmp(argv[1], "playlist") && !strcmp(argv[2], "preview") &&
	    !strcmp(argv[3], "cmd:stop"))
		return 1;
	// Brano in ascolto (pagina Audio, lms_now_playing).
	if (argc == 5 && !strcmp(argv[1], "status") && !strcmp(argv[2], "-") &&
	    !strcmp(argv[3], "1") && !strcmp(argv[4], "tags:aloITr"))
		return 1;
	if (argc == 5 && !strcmp(argv[1], "playlist") && !strcmp(argv[2], "preview") &&
	    !strncmp(argv[3], "url:file:///", 12) && !strstr(argv[3], "..") &&
	    testo_ok(argv[3]) && !strcmp(argv[4], "title:Prova DoP"))
		return 1;
	if (argc == 3 && !strcmp(argv[1], "name") && argv[2][0] && strlen(argv[2]) <= 40)
		return testo_ok(argv[2]);
	return 0;
}

static int plugin_ok(int argc, char **argv)
{
	// argv: stato | installa NOME | rimuovi NOME
	size_t i;
	if (argc == 1)
		return !strcmp(argv[0], "stato");
	if (argc != 2 || (strcmp(argv[0], "installa") && strcmp(argv[0], "rimuovi")))
		return 0;
	for (i = 0; argv[1][i]; i++)
		if (!isalnum((unsigned char)argv[1][i]) && argv[1][i] != '_')
			return 0;
	return i > 0 && i <= 64;
}

static void ambiente(void)
{
	static char *env[] = {
		"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/root",
		"LANG=C",
		NULL,
	};
	extern char **environ;
	environ = env;
}

static void chiudi_descrittori(void)
{
	int fd;
	for (fd = 3; fd < 64; fd++)
		close(fd);
}

static void esegui(char *const argv[])
{
	execv(argv[0], argv);
	perror("sweetspot-priv: exec");
	_exit(127);
}

// Lancia il comando in sottofondo (come "( sleep N; setsid cmd ) &"):
// la pagina risponde subito, il comando parte dopo il ritardo.
static void differito(unsigned ritardo, char *const argv[])
{
	pid_t p = fork();
	if (p < 0)
		_exit(1);
	if (p > 0)
		_exit(0);
	setsid();
	{
		int nul = open("/dev/null", O_RDWR);
		if (nul >= 0) {
			dup2(nul, 0);
			dup2(nul, 1);
			dup2(nul, 2);
		}
	}
	if (ritardo)
		sleep(ritardo);
	esegui(argv);
}

static int azione_interna(const char *nome, int argc, char **argv)
{
	if (!strcmp(nome, "@riavvia") && argc == 0) {
		char *a[] = {"/usr/bin/sweetspot-riavvia", NULL};
		differito(2, a);
	}
	if (!strcmp(nome, "@spegni") && argc == 0) {
		char *a[] = {"/sbin/poweroff", NULL};
		differito(2, a);
	}
	if (!strcmp(nome, "@player") && argc == 0) {
		char *a[] = {"/etc/init.d/S60sweetspot-player", "restart", NULL};
		differito(0, a);
	}
	if (!strcmp(nome, "@autotune") && argc == 0) {
		char *a[] = {"/usr/bin/sweetspot-autotune", "--applica", NULL};
		differito(2, a);
	}
	if (!strcmp(nome, "@log") && argc == 1 && testo_ok(argv[0])) {
		char ora[32];
		time_t t = time(NULL);
		FILE *f = fopen(LOGFILE, "a");
		if (!f)
			return 1;
		strftime(ora, sizeof ora, "%Y-%m-%d %H:%M:%S", localtime(&t));
		fprintf(f, "%s %s\n", ora, argv[0]);
		fclose(f);
		return 0;
	}
	return -1;
}

int main(int argc, char **argv)
{
	uid_t web = uid_web(), io = getuid();
	const struct regola *r = NULL;
	char **av;
	char *percorso;
	size_t i, nfissi, nrip, n;
	int rc;

#ifndef SWEETSPOT_PRIV_PROVA
	if (io != 0 && (web == (uid_t)-1 || io != web)) {
		fprintf(stderr, "sweetspot-priv: non autorizzato\n");
		return NO_ELENCO;
	}
	if (setgroups(0, NULL) || setgid(0) || setuid(0)) // niente privilegi a meta'
		return 1;
#else
	(void)io;
#endif
	ambiente();
	chiudi_descrittori();
	if (argc < 2)
		return NO_ELENCO;
	argc -= 2;
	argv += 2;
	// argv[-1] e' il nome del comando

	if (argv[-1][0] == '@') {
		for (i = 0; i < (size_t)argc; i++)
			if (!testo_ok(argv[i]))
				return NO_ELENCO;
		rc = azione_interna(argv[-1], argc, argv);
		return rc < 0 ? NO_ELENCO : rc;
	}

	for (i = 0; i < sizeof REGOLE / sizeof *REGOLE; i++) {
		if (strcmp(REGOLE[i].script, argv[-1]))
			continue;
		if (REGOLE[i].sub == NULL) { // script senza sottocomando
			if (argc == 0) { r = &REGOLE[i]; break; }
			continue;
		}
		if (argc >= 1 && !strcmp(REGOLE[i].sub, argv[0])) {
			r = &REGOLE[i];
			break;
		}
	}
	if (!r)
		return NO_ELENCO;

	av = calloc((size_t)argc + 3, sizeof *av);
	if (!av)
		return 1;
	if (asprintf(&percorso, "%s%s", BIN_DIR, r->script) < 0)
		return 1;
	av[0] = percorso;

	if (r->sub == NULL) {
		av[1] = NULL;
		esegui(av);
	}
	av[1] = (char *)r->sub;
	argc--;
	argv++; // restano gli argomenti dopo il sottocomando

	if (!strcmp(r->sub, "json") && !strcmp(r->script, "sweetspot-lms")) {
		if (!lms_json_ok(argc, argv))
			return NO_ELENCO;
		for (i = 0; i < (size_t)argc; i++)
			av[2 + i] = argv[i];
		esegui(av);
	}
	if (!strcmp(r->sub, "plugin") && !strcmp(r->script, "sweetspot-lms")) {
		if (!plugin_ok(argc, argv))
			return NO_ELENCO;
		av = realloc(av, ((size_t)argc + 4) * sizeof *av);
		for (i = 0; i < (size_t)argc; i++)
			av[2 + i] = argv[i];
		av[2 + argc] = NULL;
		esegui(av);
	}

	nfissi = strlen(r->fissi);
	nrip = strlen(r->ripeti);
	if ((size_t)argc < nfissi)
		return NO_ELENCO;
	n = (size_t)argc - nfissi;
	if (nrip == 0 ? n != 0 : (n == 0 || n % nrip != 0))
		return NO_ELENCO;
	for (i = 0; i < (size_t)argc; i++) {
		char tipo = i < nfissi ? r->fissi[i] : r->ripeti[(i - nfissi) % nrip];
		char *sost;
		if (!arg_ok(tipo, argv[i], &sost, web))
			return NO_ELENCO;
		av[2 + i] = sost ? sost : argv[i];
	}
	av[2 + argc] = NULL;
	esegui(av);
	return 1;
}
