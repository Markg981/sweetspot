# Controlli negativi (RED) delle correzioni di stabilizzazione

Un test vale come regressione solo se fallisce senza la correzione. Qui c'e'
la prova per i punti della stabilizzazione (commit `3481f8c`) che non
l'avevano, e per la correzione della CI di questo ramo.

Ambiente: WSL Ubuntu 24.04, BusyBox di sistema, 16/10/2026, sulla HEAD
`2be0a7b` di `markg81-completamento-sweetspot`.

## I2 - scanner nel gruppo cgroup dedicato

Eseguito in CI (job `test` dell'esecuzione 38897665344, HEAD `2be0a7b`):
verdi "ascolto: scanner con tetti propri, CPU limitata sul posto", "scanner
non spostato nel gruppo dell'ascolto", "scanner ancora nel gruppo server, il
server non e' limitato" e "scanner spostato nel gruppo dedicato prima del
limite".

## I3 - spostamento della cache copertine con WAL

Blocco "Cache delle copertine" di `tests/run.sh` (righe 1925-2006) eseguito da
solo, con `sweetspot-lms` della HEAD e con lo stesso file a cui e' stata tolta
la sola correzione (`git show 3481f8c -- .../sweetspot-lms | git apply -R`):

| `sweetspot-lms` | Superati | Falliti |
|---|---|---|
| con la correzione | 21 | 0 |
| senza la correzione | 18 | 3 |

I tre fallimenti senza correzione sono esattamente il difetto: dopo una copia
fallita `artwork.db` e il suo `-wal` sono **persi** (ottenuto `[||si]` invece di
`[prezioso|wal-prezioso|no]`), lo stato non dichiara "migrazione non riuscita"
e la migrazione successiva non recupera i dati.

## I5 - corsa fra il giro del demone e `stato.ts` nel test

Il giro si conta all'inizio (nel `sweetspot-check` finto) ma `stato.ts` si
scrive alla fine: se il test scrive `stato.ts` mentre un giro e' ancora in
corso, la fine del giro lo sovrascrive e la richiesta non produce un giro
nuovo. In CI la finestra e' stretta e il difetto compariva a caso; per renderlo
deterministico il `sweetspot-check` finto dorme 5 s durante il solo giro 5
(quello dell'evento inotify che precede la richiesta), in entrambe le varianti.

| `tests/demone-eventi.sh` rallentato | Esecuzioni | Esito su "richiesta: un giro in piu'" |
|---|---|---|
| senza `attendi 20 giri_chiusi` | 4 | 4 rossi (5 giri invece di 6) |
| con `attendi 20 giri_chiusi` | 9 | 6 tutto verde, 3 con fallimenti (*) |

(*) Con la correzione e il rallentamento artificiale:

- 1 esecuzione: l'evento inotify non ha prodotto il giro entro 10 s
  ("atteso 5, ottenuto 4"); la richiesta e' poi verde;
- 1 esecuzione: il primo evento udev non ha prodotto alcun giro e tutti i
  conteggi successivi sono slittati di uno, richiesta compresa;
- 1 esecuzione: "richiesta" e "un giro in piu'" rossi, dettaglio non salvato,
  quindi **non attribuito**.

I primi due casi sono un evento scritto nelle FIFO del banco di prova che non
diventa un giro: un'instabilita' distinta dalla corsa di I5, che compare
solo con il giro rallentato di 5 s. Il test **originale** (senza
rallentamento) e' stato eseguito 8 volte di seguito: 8 verdi, 0 rossi.

Da fare: ripetere la variante con la correzione salvando `stato.debug` per
chiarire il terzo caso e la perdita degli eventi sulle FIFO.

## CI: job `lyrion` con la compilazione saltata

Nuovi casi in `tests/release-gates.py` (`test_lyrion_runs_only_when_there_are_packages_to_prove`,
`test_lyrion_reports_a_missing_build_once`). Con il `build.yml` precedente
falliscono 2 casi su 9 test: compilazione dovuta ma saltata per test falliti
(il job partiva e falliva a catena sugli artifact mancanti, come nelle
esecuzioni 38875402521 e 38888445939) e artifact della scheda assente
(nessun errore unico, il job proseguiva fino al `tar` in QEMU, come in
38890815579). Con il nuovo `build.yml` 9/9 verdi.
