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
// Le operazioni che aprono root o il pannello per sempre (SSH, il suo utente
// e la sua password, la password del pannello, un pacchetto di aggiornamento
// da disco) o cancellano un disco (installazione) non passano dall'elenco
// normale: servono @conferma, con un gettone monouso e la password del
// pannello (quella attuale) verificata da root. Una sessione rubata da sola
// non basta.
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
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
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
#define MAX_LOG 512 // lunghezza massima di una riga di @log
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
	{"sweetspot-accesso", "verifica", "s", "", 0}, // sorgente (IP) come argomento, password dall'ingresso standard
	{"sweetspot-accesso", "primo", "", "", 0},    // codice e password nuova dall'ingresso standard
	{"sweetspot-aggiorna", "altra", "", "", 0},
	{"sweetspot-aggiorna", "annulla", "", "", 0},
	{"sweetspot-aggiorna", "cerca", "", "", 0},
	{"sweetspot-aggiorna", "file", "s", "", 1}, // installa un pacchetto qualsiasi del disco: solo con @conferma
	{"sweetspot-aggiorna", "file-downgrade", "s", "", 1}, // come "file" ma accetta una versione piu' vecchia: solo con @conferma
	{"sweetspot-aggiorna", "libera", "", "", 0},
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
	{"sweetspot-bluetooth", "abbina", "n", "", 0},
	{"sweetspot-bluetooth", "applica", "", "", 0},
	{"sweetspot-bluetooth", "chiudi", "", "", 0},
	{"sweetspot-bluetooth", "elenco", "", "", 0},
	{"sweetspot-bluetooth", "rimuovi", "w", "", 0},
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
	{"sweetspot-dsp", "fir-frequenze", "", "", 0},
	{"sweetspot-dsp", "guadagno", "", "", 0},
	{"sweetspot-dsp", "leggi", "p", "", 0},
	{"sweetspot-dsp", "risposta", "", "", 0},
	{"sweetspot-dsp", "salva", "pp", "", 0},
	{"sweetspot-hotspot", "collega", "", "", 0},
	{"sweetspot-hotspot", "richiesta", "", "", 0},
	{"sweetspot-https", "applica", "", "", 0},
	{"sweetspot-hotspot", "scansiona", "", "", 0},
	// Cancella un disco: solo con @conferma, piu' la dimensione del disco scritta.
	{"sweetspot-installa", "avvia", "sss", "", 1},
	{"sweetspot-installa", "dischi", "", "", 0},
	// Accanto al sistema esistente: scrive solo nello spazio libero, ma
	// cambia la tabella delle partizioni e la NVRAM: anche qui @conferma.
	{"sweetspot-installa", "affianca", "ss", "", 1},
	{"sweetspot-installa", "accanto", "", "", 0},
	{"sweetspot-installa", "stato", "", "", 0},
	{"sweetspot-lms", "aggiorna", "", "", 0},
	{"sweetspot-lms", "applica", "", "", 0},
	{"sweetspot-lms", "cover", "ww", "", 0},
	{"sweetspot-lms", "credenziali", "", "", 0},
	{"sweetspot-lms", "json", "", "", 0}, // controllato a parte (lms_json_ok)
	{"sweetspot-lms", "operazione", "", "", 0}, // controllato a parte (operazione_ok)
	{"sweetspot-lms", "plugin", "", "", 0}, // controllato a parte
	{"sweetspot-lms", "ricostruisci", "", "", 0},
	{"sweetspot-lms", "riavvia", "", "", 0},
	{"sweetspot-nas", "ferma", "", "", 0},
	{"sweetspot-mediaserver", "riavvia", "", "", 0},
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
//  m  nome di dispositivo: lettere, cifre, spazio, . _ - (al massimo 40)
//  g  guadagno in dB (margine): da -24 a 0, al massimo un decimale (0, -3, -1.5)
//  y  password di Lyrion: da 10 a 64 caratteri ASCII stampabili, senza spazi
//     e senza % (la CLI di Lyrion decodifica gli argomenti di "login")
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
	{"SERVER_UPNP", 'b', 0},
	{"CACHE_COPERTINE", 'w', 0}, {"CACHE_COPERTINE_DISCO", 'l', 0}, {"CACHE_COPERTINE_MB", 'w', 0},
	{"SERVER", 'h', 0}, {"CORREZIONE", 'w', 0},
	{"HTTPS", 'w', 0}, {"HTTPS_REINDIRIZZA", 'w', 0},
	{"BLUETOOTH", 'b', 0}, {"BLUETOOTH_NOME", 'm', 0},
	{"LYRION_UTENTE", 'w', 0}, {"LYRION_PASSWORD", 'y', 0},
	// Aprono root (login SSH come root o come utente di assistenza): solo con @conferma.
	{"SSH", 'w', 1}, {"SSH_PASSWORD", 's', 1}, {"SSH_UTENTE", 'w', 1},
	// Cambiarla senza conoscere quella attuale terrebbe fuori il proprietario: solo con @conferma.
	{"PASSWORD_WEB", 's', 1},
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
static int c_nome(unsigned char c) { return isalnum(c) || strchr(" ._-", c) != NULL; }
static int c_password_lyrion(unsigned char c) { return c > ' ' && c < 0x7f && c != '%'; }

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
	case 'm': return solo(v, 40, c_nome);
	case 'g': return margine_ok(v);
	case 'y': return strlen(v) >= 10 && solo(v, 64, c_password_lyrion);
	}
	return 0;
}

// Apre `rel` (percorso relativo) sotto la cartella `base` senza seguire
// collegamenti simbolici in NESSUN componente (O_NOFOLLOW vale solo per
// l'ultimo: web puo' creare web/x -> /etc). Prima openat2() con
// RESOLVE_NO_SYMLINKS|RESOLVE_BENEATH; se il kernel non la ha (ENOSYS, o
// bloccata da seccomp) si scende componente per componente con
// openat(O_NOFOLLOW).
struct apri_come { // = struct open_how del kernel (gli header di Buildroot potrebbero non averla)
	unsigned long long flags, mode, resolve;
};
#define RISOLVI_NO_MAGICLINKS 0x02ULL
#define RISOLVI_NO_SYMLINKS 0x04ULL
#define RISOLVI_BENEATH 0x08ULL

static int apri_sotto(const char *base, const char *rel)
{
	int dfd, fd = -1;
	char *copia, *comp, *succ;

	dfd = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NOCTTY);
	if (dfd < 0)
		return -1;
#ifdef SYS_openat2
	{
		struct apri_come how = {O_RDONLY | O_NOFOLLOW | O_NOCTTY, 0,
					RISOLVI_NO_SYMLINKS | RISOLVI_BENEATH | RISOLVI_NO_MAGICLINKS};
		long r = syscall(SYS_openat2, dfd, rel, &how, sizeof how);
		if (r >= 0) {
			close(dfd);
			return (int)r;
		}
		if (errno != ENOSYS && errno != EPERM) {
			close(dfd);
			return -1;
		}
	}
#endif
	copia = strdup(rel);
	if (!copia) {
		close(dfd);
		return -1;
	}
	for (comp = copia; comp && dfd >= 0; comp = succ) {
		int ultimo, nfd;
		succ = strchr(comp, '/');
		if (succ)
			*succ++ = 0;
		ultimo = succ == NULL;
		if (!*comp || !strcmp(comp, ".") || !strcmp(comp, "..")) // anche "a//b" e "a/"
			break;
		nfd = openat(dfd, comp, O_RDONLY | O_NOFOLLOW | O_NOCTTY | (ultimo ? 0 : O_DIRECTORY));
		close(dfd);
		dfd = nfd;
		if (ultimo) {
			fd = dfd;
			dfd = -1;
		}
	}
	if (dfd >= 0)
		close(dfd);
	free(copia);
	return fd;
}

// Apre il file passato dalle pagine (sotto BASE_WEB o BASE_FILTRI) senza
// seguire collegamenti; ritorna il percorso /proc/self/fd/N da passare allo
// script (lo stesso file che abbiamo controllato, anche se nel frattempo la
// cartella cambia). Proprietario: sotto BASE_WEB solo web (cartella di web:
// un file di root li' non l'ha messo web); sotto BASE_FILTRI (cartella di
// root, non scrivibile da web) solo root.
static char *file_web(const char *s, uid_t web)
{
	struct stat st;
	char *out;
	const char *base;
	uid_t atteso;
	int fd;

	if (strstr(s, "..") || !testo_ok(s))
		return NULL;
	if (!strncmp(s, BASE_WEB, strlen(BASE_WEB))) {
		base = BASE_WEB;
		atteso = web;
	} else if (!strncmp(s, BASE_FILTRI, strlen(BASE_FILTRI))) {
		base = BASE_FILTRI;
		atteso = 0;
	} else
		return NULL;
	if (!s[strlen(base)] || strstr(s + strlen(base), "//") || s[strlen(s) - 1] == '/')
		return NULL; // niente componenti vuoti (stesso esito con openat2 e col ripiego)
	fd = apri_sotto(base, s + strlen(base));
	if (fd < 0)
		return NULL;
	if (fstat(fd, &st)) {
		close(fd);
		return NULL;
	}
#ifdef SWEETSPOT_PRIV_PROVA
	{ // nei test "web" e' chi esegue, o l'uid di SWEETSPOT_PROVA_UID
		const char *u = getenv("SWEETSPOT_PROVA_UID");
		atteso = u ? (uid_t)atol(u) : getuid();
	}
#else
	(void)0;
#endif
	if (!S_ISREG(st.st_mode) || st.st_size > MAX_FILE ||
	    st.st_uid != atteso || st.st_nlink != 1) {
		close(fd);
		return NULL;
	}
	if (asprintf(&out, "/proc/self/fd/%d", fd) < 0) {
		close(fd);
		return NULL;
	}
	return out;
}

static int arg_ok(char tipo, const char *s, char **sost, uid_t web)
{
	*sost = NULL;
	switch (tipo) {
	case 's': return testo_ok(s);
	case 'w': return parola_ok(s) && s[0] != '-'; // niente opzioni
	case 'n': return s[0] >= '1' && s[0] <= '9' && !s[1];
	case 'k': return chiave_ok(s);
	case 'p': *sost = file_web(s, web); return *sost != NULL;
	}
	return 0;
}

static int cifre_ok(const char *s)
{
	size_t n = strlen(s);
	if (n < 1 || n > 9)
		return 0;
	for (; *s; s++)
		if (!isdigit((unsigned char)*s))
			return 0;
	return 1;
}

static int numero_ok(const char *s, int segno)
{
	if (segno && (*s == '+' || *s == '-'))
		s++;
	return cifre_ok(s);
}

// Opzioni "chiave:valore" delle ricerche del Reference Studio.
static int opzione_ok(const char *s)
{
	static const char *const num[] = {"artist_id:", "album_id:", "genre_id:",
	    "track_id:", "playlist_id:", "folder_id:", "year:", "compilation:", NULL};
	size_t i, n;
	for (i = 0; num[i]; i++)
		if (!strncmp(s, num[i], strlen(num[i])))
			return cifre_ok(s + strlen(num[i]));
	if (!strncmp(s, "tags:", 5)) {
		for (n = 0, s += 5; isalpha((unsigned char)*s); s++, n++)
			;
		return n > 0 && n <= 40 && !*s;
	}
	if (!strncmp(s, "sort:", 5))
		return !strcmp(s + 5, "new") || !strcmp(s + 5, "album") ||
		    !strcmp(s + 5, "artflow") || !strcmp(s + 5, "random") ||
		    !strcmp(s + 5, "artistalbum") || !strcmp(s + 5, "title") || !strcmp(s + 5, "tracknum");
	if (!strncmp(s, "search:", 7))
		return s[7] && strlen(s + 7) <= 64 && testo_ok(s);
	return 0;
}

// Comandi del Reference Studio: elenchi (albums, artists..., musicfolder per
// sfogliare i dischi: Lyrion li legge soltanto), stato e coda, trasporto,
// volume, posizione, riproduzione di un elemento, zone (sync).
static int studio_ok(int argc, char **argv)
{
	const char *player = argv[0], *c = argv[1];
	static const char *const elenchi[] = {"albums", "artists", "genres",
	    "titles", "playlists", "players", "musicfolder", NULL};
	int i, j;
	for (i = 0; elenchi[i]; i++)
		if (!strcmp(c, elenchi[i])) {
			if (argc < 4 || argc > 9 || (*player && !parola_ok(player)))
				return 0;
			if (!cifre_ok(argv[2]) || !cifre_ok(argv[3]) || atol(argv[3]) > 500)
				return 0;
			for (j = 4; j < argc; j++)
				if (!opzione_ok(argv[j]))
					return 0;
			return 1;
		}
	if (!parola_ok(player))
		return 0;
	if (!strcmp(c, "status")) {
		if (argc < 4 || argc > 7 || (strcmp(argv[2], "-") && !cifre_ok(argv[2])) ||
		    !cifre_ok(argv[3]) || atol(argv[3]) > 500)
			return 0;
		for (j = 4; j < argc; j++)
			if (!opzione_ok(argv[j]))
				return 0;
		return 1;
	}
	if (argc == 2)
		return !strcmp(c, "play") || !strcmp(c, "stop");
	if (argc == 3) {
		if (!strcmp(c, "pause"))
			return !strcmp(argv[2], "0") || !strcmp(argv[2], "1");
		if (!strcmp(c, "time"))
			return cifre_ok(argv[2]);
		if (!strcmp(c, "sync"))
			return !strcmp(argv[2], "-") || (parola_ok(argv[2]) && !strchr(argv[2], '.'));
		if (!strcmp(c, "playlist"))
			return !strcmp(argv[2], "clear");
		return 0;
	}
	if (argc == 4) {
		if (!strcmp(c, "mixer") && !strcmp(argv[2], "volume"))
			return numero_ok(argv[3], 1) && atol(argv[3] + (*argv[3] == '+' || *argv[3] == '-')) <= 100;
		if (!strcmp(c, "playlist") && !strcmp(argv[2], "index"))
			return numero_ok(argv[3], 1);
		if (!strcmp(c, "playlist") && !strcmp(argv[2], "delete"))
			return cifre_ok(argv[3]);
		if (!strcmp(c, "playlistcontrol")) {
			if (strcmp(argv[2], "cmd:load") && strcmp(argv[2], "cmd:add") &&
			    strcmp(argv[2], "cmd:insert"))
				return 0;
			return (!strncmp(argv[3], "album_id:", 9) || !strncmp(argv[3], "track_id:", 9) ||
			    !strncmp(argv[3], "artist_id:", 10) || !strncmp(argv[3], "playlist_id:", 12) ||
			    !strncmp(argv[3], "folder_id:", 10)) &&
			    opzione_ok(argv[3]);
		}
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
	if (argc >= 2 && testo_ok(argv[0]) && studio_ok(argc, argv))
		return 1;
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

// Operazioni lunghe in background (sweetspot-lms operazione): solo "avvia",
// con un tipo dell'elenco. Lo stato lo legge la pagina direttamente.
static int operazione_ok(int argc, char **argv)
{
	// argv: avvia plugin-installa|plugin-rimuovi NOME | avvia aggiorna|ricostruisci
	size_t i;
	if (argc < 2 || strcmp(argv[0], "avvia"))
		return 0;
	if (argc == 2)
		return !strcmp(argv[1], "aggiorna") || !strcmp(argv[1], "ricostruisci");
	if (argc != 3 || (strcmp(argv[1], "plugin-installa") && strcmp(argv[1], "plugin-rimuovi")))
		return 0;
	for (i = 0; argv[2][i]; i++)
		if (!isalnum((unsigned char)argv[2][i]) && argv[2][i] != '_')
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

// Chiude tutti i descrittori ereditati (3 e oltre). Va chiamata PRIMA di
// aprire i file di file_web(): quelli si ereditano di proposito (lo script
// li legge da /proc/self/fd).
static void chiudi_descrittori(void)
{
	struct rlimit rl;
	long max = sysconf(_SC_OPEN_MAX);
	int fd;

#ifdef SYS_close_range
	if (syscall(SYS_close_range, 3U, ~0U, 0U) == 0)
		return;
#endif
	if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_max != RLIM_INFINITY && (long)rl.rlim_max > max)
		max = (long)rl.rlim_max;
	if (max < 64 || max > 1048576)
		max = 65536;
	for (fd = 3; fd < max; fd++)
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

// Chi chiede la conferma (IP del client, lo passa la pagina in
// SWEETSPOT_SORGENTE; letto prima che ambiente() ripulisca l'ambiente): serve
// a sweetspot-accesso per contare gli errori per sorgente. Solo caratteri di
// un indirizzo, altrimenti "locale".
static char sorgente_conferma[64] = "locale";

static void sorgente_leggi(void)
{
	const char *s = getenv("SWEETSPOT_SORGENTE");
	size_t i;
	if (!s || !*s || strlen(s) >= sizeof sorgente_conferma)
		return;
	for (i = 0; s[i]; i++)
		if (!isxdigit((unsigned char)s[i]) && s[i] != '.' && s[i] != ':')
			return;
	strcpy(sorgente_conferma, s);
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
		char *a[] = {BIN_DIR "sweetspot-accesso", sub, sorgente_conferma, NULL};
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
	if (!strcmp(nome, "@log") && argc == 1 && testo_ok(argv[0]) &&
	    strlen(argv[0]) <= MAX_LOG) {
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
	sorgente_leggi();
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
	if (!strcmp(r->sub, "cover") && !strcmp(r->script, "sweetspot-lms")) {
		static const char *const dim[] = {"64", "96", "128", "200", "300", "400", "600"};
		size_t k, buono = 0;
		if (argc != 2 || strlen(argv[0]) == 0 || strlen(argv[0]) > 32 || strspn(argv[0], "0123456789abcdefABCDEF") != strlen(argv[0]))
			return NO_ELENCO;
		for (k = 0; k < sizeof(dim) / sizeof(dim[0]); k++)
			if (!strcmp(argv[1], dim[k]))
				buono = 1;
		if (!buono)
			return NO_ELENCO;
		for (i = 0; i < (size_t)argc; i++)
			av[2 + i] = argv[i];
		esegui(av);
	}
	if (!strcmp(r->sub, "operazione") && !strcmp(r->script, "sweetspot-lms")) {
		if (!operazione_ok(argc, argv))
			return NO_ELENCO;
		for (i = 0; i < (size_t)argc; i++)
			av[2 + i] = argv[i];
		av[2 + argc] = NULL;
		esegui(av);
	}
	if (!strcmp(r->sub, "plugin") && !strcmp(r->script, "sweetspot-lms")) {
		if (!plugin_ok(argc, argv))
			return NO_ELENCO;
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
		// Un testo che inizia con '-' sarebbe preso per un'opzione dallo
		// script di root: lo ammettono solo config (valori), accesso
		// (password) e cd (nomi), che non lo usano come opzione.
		if (tipo == 's' && argv[i][0] == '-' && strcmp(r->script, "sweetspot-config") &&
		    strcmp(r->script, "sweetspot-accesso") && strcmp(r->script, "sweetspot-cd"))
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
