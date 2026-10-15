# Profili CPU, banco di prova e cosa misura (e cosa no)

## Profili (`PROFILO` in `sweetspot.txt`, pagina Sistema)

| Profilo | Frequenza | Stati C | Uso |
| --- | --- | --- | --- |
| `bilanciato` (predefinito) | **fissa**, a metà fra minima e nominale | come da ottimizzazioni di avvio | compromesso a frequenza costante |
| `silenzio` | fissa alla minima | come da ottimizzazioni | meno corrente e calore |
| `prestazioni` | fissa alla nominale | core sempre svegli (PM QoS) | massima prontezza, più calore |
| `dinamico` | governor `schedutil` (o `ondemand`), minima libera, massima la nominale | profondi consentiti, esclusi i core isolati per l'audio (risveglio > 50 us) | meno consumo e temperatura a riposo |

"Bilanciato" indica il compromesso fra consumo e prontezza, non una gestione
dinamica della frequenza: l'interfaccia lo dichiara ("frequenza fissa
intermedia, non dinamica"). Chi vuole che la frequenza segua il carico sceglie
`dinamico`. Il Turbo resta spento in tutti i profili. Il profilo `dinamico`
non cambia SMT né i parametri di avvio (`max_cstate`, `isolcpus`): per questi
c'è `ENERGIA=conservativo` (vedi `docs/profilo-energetico.md`).

## Banco di prova: `sweetspot-banco`

```
sweetspot-banco -p dinamico -c pcm -d 600 -i 5 -o /tmp/dinamico-pcm
sweetspot-banco -p bilanciato -c pcm -d 600 -i 5 -o /tmp/bilanciato-pcm
sweetspot-banco confronta /tmp/dinamico-pcm.json /tmp/bilanciato-pcm.json
```

Carichi: `pcm` (PCM a 384 kHz verso ALSA, dispositivo in
`SWEETSPOT_BANCO_ALSA`), `fir` (CamillaDSP con `SWEETSPOT_BANCO_FIR_CONF`,
altrimenti CPU sintetica), `scansione` (visita della libreria), `navigazione`
(richieste all'interfaccia web), `nessuno`. Ogni carico si sostituisce con
`SWEETSPOT_BANCO_<CARICO>="comando"`.

Produce `PREFISSO.csv` (un campione ogni intervallo: temperatura, frequenza,
throttling, energia RAPL, memoria libera, XRUN) e `PREFISSO.json` (riepilogo
piatto: temperatura massima e media, frequenze, eventi di throttling,
potenza media se c'è RAPL, memoria libera minima, XRUN, latenza p99 e massima
se c'è `cyclictest`). Dato non disponibile = `null`. Il throttling usa
`vcgencmd get_throttled` sul Raspberry Pi e `thermal_throttle` su x86.

Per confrontare davvero i profili: stesso carico, stessa durata, macchina già
a regime termico e più ripetizioni.

## Scheduling e jitter del clock: due cose diverse

PREEMPT_RT, affinità dei core, priorità real-time e buffer più ampi
migliorano la **puntualità con cui i dati arrivano al DAC** (meno XRUN, meno
rischio di buffer vuoto). Con USB **asincrona** però il clock della
conversione lo detta il DAC, che regola il flusso con il feedback verso il
PC. Quindi:

- la latenza dello scheduler (`cyclictest`, `sweetspot-latenza`) e il margine
  del buffer (`sweetspot-alsa-misura`) non dimostrano un jitter di conversione
  più basso;
- il jitter del clock del DAC si misura sul DAC (uscita analogica o
  digitale con strumenti adatti), non sul PC;
- un profilo CPU che riduce latenza o XRUN è utile per la continuità
  dell'ascolto; ogni affermazione sul suono richiede misure e ascolto alla
  cieca.

I testi dell'interfaccia e degli script seguono questa distinzione.
