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
//   sweetspot-priv @conferma-nuova           stampa un gettone monouso
//   sweetspot-priv @conferma GETTONE SCRIPT ARGOMENTI...   (password del
//                                            pannello sull'ingresso standard)
//
// Le operazioni che aprono root (SSH, il suo utente e la sua password)
// non passano dall'elenco normale: servono @conferma,
// con un gettone monouso e la password del pannello verificata da root.
//
// Esce con 126 se la richiesta non e' nell'elenco (nulla viene eseguito).

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// Solo per i test (tests/run.sh): niente controllo dell'utente, script finti
// in un'altra cartella e file delle pagine in un'altra base.
#ifdef SWEETSPOT_PRIV_PROVA
#define BIN_DIR PROVA_BIN
#define BASE_WEB PROVA_WEB
#define BASE_CONFERMA PROVA_WEB "conferma/"
#else
#define BIN_DIR "/usr/bin/"
#define BASE_WEB "/run/sweetspot/web/"
#define BASE_CONFERMA "/run/sweetspot/conferma/" // solo di root: le pagine non vi scrivono
#endif

#define UTENTE_WEB "web"
#define BASE_FILTRI "/run/sweetspot/correzione/" // filtri gia' salvati (di root)
#define LOGFILE "/var/log/sweetspot.log"
#define MAX_ARG 1024
#define MAX_FILE (1024 * 1024)
#define NO_ELENCO 126
#define CONFERMA_VALIDITA 600 // secondi
#define CONFERMA_MAX 16

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
	int protetta;       // 1 = solo con @conferma (apre root)
};

static const struct regola REGOLE[] = {
	{"sweetspot-accesso", "applica", "", "", 0},
	{"sweetspot-accesso", "hash", "s", "", 0},
	{"sweetspot-accesso", "verifica", "", "", 0}, // password dall'ingresso standard
	{"sweetspot-aggiorna", "altra", "", "", 0},
	{"sweetspot-aggiorna", "annulla", "", "", 0},
	{"sweetspot-aggiorna", "cerca", "", "", 0},
	{"sweetspot-aggiorna", "file", "s", "", 0},
	{"sweetspot-aggiorna", "pacchetti", "", "", 0},
	{"sweetspot-aggiorna", "predefinita", "", "", 0},
	{"sweetspot-aggiorna", "scarica", "", "", 0},
	{"sweetspot-aggiorna", "stato", "", "", 0},
	{"sweetspot-cd", "annulla", "", "", 0},
	{"sweetspot-cd", "copia", "sss", "", 0},
	{"sweetspot-cd", "espelli", "", "", 0},
	{"sweetspot-cd", "leggi", "", "", 0},
	{"sweetspot-cd", "lettore", "", "", 0},
	{"sweetspot-cd", "stato", "", "", 0},
	{"sweetspot-check", "--dati", "", "", 0},
	{"sweetspot-config", "imposta", "", "ks", 0},
	{"sweetspot-config", "rimuovi", "", "k", 0},
	{"sweetspot-config", "ripristina", "", "", 0},
	{"sweetspot-copia", "annulla", "", "", 0},
	{"sweetspot-copia", "avvia", "s", "", 0},
	{"sweetspot-copia", "elimina", "s", "", 0},
	{"sweetspot-copia", "sorgente", "s", "", 0},
	{"sweetspot-copia", "stato", "", "", 0},
	{"sweetspot-diario", "bundle", "", "", 0}, // tar.gz diagnostico sull'uscita standard
	{"sweetspot-dischi", "archivio", "", "", 0},
	{"sweetspot-dischi", "monta", "", "", 0},
	{"sweetspot-dischi", "smonta", "s", "", 0},
	{"sweetspot-dsp", "fir", "", "", 0},
	{"sweetspot-dsp", "guadagno", "", "", 0},
	{"sweetspot-dsp", "leggi", "p", "", 0},
	{"sweetspot-dsp", "risposta", "", "", 0},
	{"sweetspot-dsp", "salva", "pp", "", 0},
	{"sweetspot-hotspot", "richiesta", "", "", 0},
	{"sweetspot-https", "applica", "", "", 0},
	{"sweetspot-hotspot", "scansiona", "", "", 0},
	{"sweetspot-installa", "avvia", "ss", "", 0},
	{"sweetspot-installa", "dischi", "", "", 0},
	{"sweetspot-installa", "stato", "", "", 0},
	{"sweetspot-lms", "aggiorna", "", "", 0},
	{"sweetspot-lms", "json", "", "", 0}, // controllato a parte (lms_json_ok)
	{"sweetspot-lms", "plugin", "", "", 0}, // controllato a parte
	{"sweetspot-lms", "ricostruisci", "", "", 0},
	{"sweetspot-lms", "riavvia", "", "", 0},
	{"sweetspot-nas", "ferma", "", "", 0},
	{"sweetspot-nas", "riavvia", "", "", 0},
	{"sweetspot-rapporto", NULL, "", "", 0},
	{"sweetspot-rete", "prova", "n", "", 0},
	{"sweetspot-rete", "smonta-una", "n", "", 0},
	{"sweetspot-spazio", "crea", "", "", 0},
	{"sweetspot-spazio", "lavoro", "", "", 0},
	{"sweetspot-spazio", "stato", "", "", 0},
};

// Chiavi di sweetspot.txt che le pagine possono cambiare, con il tipo del
// valore (a ogni chiave il suo: un valore finito in una riga di comando, in
// un file di configurazione o nei parametri del kernel non deve poter
// portare altro). Le altre chiavi (comandi, percorsi, opzioni di basso
// livello) si toccano solo dalla chiavetta, con il computer.
//  s  testo libero senza caratteri di controllo
//  w  parola (lettere, cifre, _ . : -)
//  d  solo cifre (al massimo 9)
//  i  lettere minuscole, cifre e trattini (overlay, nome in rete)
//  a  indirizzo IPv4, con maschera /N se serve
//  h  nome o indirizzo di un server
//  q  identita' di un disco (UUID=..., PARTUUID=...)
//  l  elenco di nomi di dischi separati da virgole
//  b  si oppure no
//  g  guadagno in dB (margine): da -24 a 0, al massimo un decimale (0, -3, -1.5)
struct chiave {
	const char *nome;
	char valore;
	int protetta; // 1 = solo con @conferma
};

static const struct chiave CHIAVI[] = {
	{"VOLUME", 'w', 0}, {"DSD", 'w', 0}, {"DSD_PCM_MARGINE_DB", 'g', 0}, {"RICAMPIONAMENTO", 'w', 0}, {"FILTRO", 'w', 0},
	{"FREQUENZA_MAX", 'd', 0}, {"BUFFER_ALSA_MS", 'd', 0}, {"PERIODI_ALSA", 'd', 0},
	{"PAUSA_FREQUENZA_MS", 'd', 0}, {"PAUSA_DSD_MS", 'd', 0}, {"ALTRI_DAC", 'w', 0},
	{"DAC", 'w', 0}, {"ESCLUDI_DISCHI", 'l', 0}, {"ARCHIVIO", 'q', 0},
	{"ARCHIVIO_CONDIVISO", 'w', 0}, {"ARCHIVIO_PASSWORD", 's', 0},
	{"WIFI_NOME", 's', 0}, {"WIFI_PASSWORD", 's', 0}, {"NOME_RETE", 'i', 0},
	{"RISPARMIO_RETE", 'w', 0}, {"IP_FISSO", 'a', 0}, {"GATEWAY", 'a', 0}, {"DNS", 'a', 0},
	{"SCHEDA_I2S", 'i', 0}, // finisce nella riga di comando del kernel
	{"NOME_PLAYER", 's', 0}, {"MODALITA", 'w', 0}, {"PROFILO", 'w', 0},
	{"MODALITA_ASCOLTO", 'w', 0}, {"PRECARICO", 'w', 0}, {"OTTIMIZZAZIONI", 'w', 0},
	{"RENDERER_UPNP", 'b', 0},
	{"CACHE_COPERTINE", 'w', 0}, {"CACHE_COPERTINE_DISCO", 'l', 0}, {"CACHE_COPERTINE_MB", 'w', 0},
	{"PASSWORD_WEB", 's', 0}, {"SERVER", 'h', 0}, {"CORREZIONE", 'w', 0},
	{"HTTPS", 'w', 0}, {"HTTPS_REINDIRIZZA", 'w', 0},
	// Aprono root (login SSH come root o come utente di assistenza): solo con @conferma.
	{"SSH", 'w', 1}, {"SSH_PASSWORD", 's', 1}, {"SSH_UTENTE", 'w', 1},
	{NULL, 0, 0},
};

static int consenti_protette; // vero solo dopo @conferma riuscito

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

static const struct chiave CHIAVE_CONDIVISIONE = {"CONDIVISIONE", 's', 0};
static const struct chiave CHIAVE_SMB1 = {"CONDIVISIONE_SMB1", 'b', 0};

static const struct chiave *chiave_cerca(const char *s)
{
	int i;
	// CONDIVISIONE_1..9 con _UTENTE, _PASSWORD e _SMB1
	if (!strncmp(s, "CONDIVISIONE_", 13) && s[13] >= '1' && s[13] <= '9') {
		const char *r = s + 14;
		if (!strcmp(r, "_SMB1"))
			return &CHIAVE_SMB1; // booleano si/no
		return (!*r || !strcmp(r, "_UTENTE") || !strcmp(r, "_PASSWORD")) ? &CHIAVE_CONDIVISIONE : NULL;
	}
	for (i = 0; CHIAVI[i].nome; i++)
		if (!strcmp(s, CHIAVI[i].nome))
			return &CHIAVI[i];
	return NULL;
}

static int chiave_ok(const char *s)
{
	const struct chiave *c = chiave_cerca(s);
	return c && (!c->protetta || consenti_protette);
}

static int solo(const char *s, size_t max, int (*ok)(unsigned char))
{
	size_t n = strlen(s);
	if (n > max)
		return 0;
	for (; *s; s++)
		if (!ok((unsigned char)*s))
			return 0;
	return 1;
}
static int c_cifra(unsigned char c) { return isdigit(c); }
static int c_minuscola(unsigned char c) { return islower(c) || isdigit(c) || c == '-'; }
static int c_indirizzo(unsigned char c) { return isdigit(c) || c == '.' || c == '/'; }
static int c_host(unsigned char c) { return isalnum(c) || strchr(".:_-", c) != NULL; }
static int c_disco(unsigned char c) { return isalnum(c) || strchr("=_.:-", c) != NULL; }
static int c_elenco(unsigned char c) { return isalnum(c) || strchr(" ._,-", c) != NULL; }

// Margine in dB (DSD_PCM_MARGINE_DB): 0 oppure da -24 a 0, con al massimo un
// decimale ("-3", "-1.5", "0", "-24.0"); niente "+", spazi, esponenti o altro.
static int margine_ok(const char *v)
{
	int neg = 0, intero = 0, cifre = 0, dec = 0;
	if (*v == '-') {
		neg = 1;
		v++;
	}
	for (; isdigit((unsigned char)*v) && cifre < 3; v++, cifre++)
		intero = intero * 10 + (*v - '0');
	if (cifre == 0 || cifre > 2)
		return 0;
	if (*v == '.') {
		v++;
		if (!isdigit((unsigned char)*v))
			return 0;
		dec = *v++ - '0';
	}
	if (*v)
		return 0;
	if (!neg)
		return intero == 0 && dec == 0; // "0" e "0.0": niente guadagno
	return intero < 24 || (intero == 24 && dec == 0);
}

// Il valore va bene per la chiave? (vuoto: sempre, e' "nessun valore")
static int valore_ok(const char *chiave, const char *v)
{
	const struct chiave *c = chiave_cerca(chiave);
	if (!c || !testo_ok(v))
		return 0;
	if (!*v)
		return 1;
	switch (c->valore) {
	case 's': return 1;
	case 'w': return parola_ok(v);
	case 'd': return solo(v, 9, c_cifra);
	case 'i': return solo(v, 60, c_minuscola) && v[0] != '-';
	case 'a': return solo(v, 18, c_indirizzo);
	case 'h': return solo(v, 253, c_host);
	case 'q': return solo(v, 100, c_disco);
	case 'l': return solo(v, 400, c_elenco);
	case 'b': return !strcmp(v, "si") || !strcmp(v, "no");
	case 'g': return margine_ok(v);
	}
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

// --- Conferma forte --------------------------------------------------------
// Gettone monouso (file di root, 32 cifre esadecimali) + password del
// pannello. Il gettone si consuma prima di guardare la password: un tentativo
// sbagliato ne costa uno e la pagina va ricaricata.

static int hex32(const char *t)
{
	size_t i;
	if (strlen(t) != 32)
		return 0;
	for (i = 0; i < 32; i++)
		if (!isxdigit((unsigned char)t[i]) || isupper((unsigned char)t[i]))
			return 0;
	return 1;
}

static int conferma_nuova(void)
{
	DIR *d;
	struct dirent *e;
	unsigned char r[16];
	char tok[33], path[512], vecchio[512] = "";
	int fd, n = 0, i;
	time_t ora = time(NULL), vecchio_t = 0;

	mkdir(BASE_CONFERMA, 0700);
	d = opendir(BASE_CONFERMA);
	if (!d)
		return 1;
	while ((e = readdir(d))) {
		struct stat st;
		if (!hex32(e->d_name))
			continue;
		snprintf(path, sizeof path, "%s%s", BASE_CONFERMA, e->d_name);
		if (lstat(path, &st))
			continue;
		if (ora - st.st_mtime > CONFERMA_VALIDITA) {
			unlink(path);
		} else {
			n++;
			if (!vecchio[0] || st.st_mtime < vecchio_t) {
				snprintf(vecchio, sizeof vecchio, "%s", path);
				vecchio_t = st.st_mtime;
			}
		}
	}
	closedir(d);
	// Troppi gettoni in giro (pagine ricaricate di continuo): cede il piu' vecchio.
	if (n >= CONFERMA_MAX && vecchio[0])
		unlink(vecchio);
	fd = open("/dev/urandom", O_RDONLY);
	if (fd < 0 || read(fd, r, sizeof r) != (ssize_t)sizeof r)
		return 1;
	close(fd);
	for (i = 0; i < 16; i++)
		snprintf(tok + 2 * i, 3, "%02x", r[i]);
	snprintf(path, sizeof path, "%s%s", BASE_CONFERMA, tok);
	fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
	if (fd < 0)
		return 1;
	close(fd);
	printf("%s\n", tok);
	return 0;
}

// Consuma il gettone: vero solo se esisteva ed e' recente.
static int conferma_usa(const char *tok)
{
	struct stat st;
	char path[512];
	if (!hex32(tok))
		return 0;
	snprintf(path, sizeof path, "%s%s", BASE_CONFERMA, tok);
	if (lstat(path, &st) || !S_ISREG(st.st_mode))
		return 0;
	if (unlink(path))
		return 0;
	return time(NULL) - st.st_mtime <= CONFERMA_VALIDITA;
}

// Password del pannello dall'ingresso standard, verificata da sweetspot-accesso
// (che la confronta con PASSWORD_WEB: senza password del pannello rifiuta sempre).
static int password_ok(void)
{
	char pw[300];
	int p[2], st;
	pid_t pid;
	size_t n;

	if (!fgets(pw, sizeof pw, stdin))
		return 0;
	n = strcspn(pw, "\r\n");
	pw[n] = 0;
	if (!n || !testo_ok(pw) || pipe(p))
		return 0;
	pid = fork();
	if (pid < 0)
		return 0;
	if (pid == 0) {
		char sub[] = "verifica";
		char *a[] = {BIN_DIR "sweetspot-accesso", sub, NULL};
		dup2(p[0], 0);
		close(p[0]);
		close(p[1]);
		esegui(a);
	}
	close(p[0]);
	if (write(p[1], pw, n) < 0 || write(p[1], "\n", 1) < 0) {
		/* lo script legge una riga vuota e rifiuta */
	}
	close(p[1]);
	if (waitpid(pid, &st, 0) < 0)
		return 0;
	return WIFEXITED(st) && WEXITSTATUS(st) == 0;
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

	if (!strcmp(argv[-1], "@conferma-nuova") && argc == 0)
		return conferma_nuova();
	if (!strcmp(argv[-1], "@conferma")) {
		// argv: GETTONE SCRIPT ARGOMENTI... (password sull'ingresso standard)
		if (argc < 2 || !conferma_usa(argv[0]) || !password_ok()) {
#ifndef SWEETSPOT_PRIV_PROVA
			sleep(2); // frena i tentativi a raffica
#endif
			return NO_ELENCO;
		}
		consenti_protette = 1;
		argv += 2;
		argc -= 2;
		// ora argv[-1] e' lo script
	}

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
		if (REGOLE[i].protetta && !consenti_protette)
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
		// Valore di una chiave: deve andare bene per quella chiave.
		if (!strcmp(r->script, "sweetspot-config") && !strcmp(r->sub, "imposta") &&
		    tipo == 's' && i > 0 && !valore_ok(argv[i - 1], argv[i]))
			return NO_ELENCO;
		av[2 + i] = sost ? sost : argv[i];
	}
	av[2 + argc] = NULL;
	esegui(av);
	return 1;
}
