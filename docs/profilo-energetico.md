# Profilo energetico: fisso o conservativo

Le ottimizzazioni predefinite (profilo `fisso`) spengono l'SMT, limitano
gli stati C a C1 (`intel_idle.max_cstate=1 processor.max_cstate=1`, su
Raspberry Pi `cpuidle.off=1`) e bloccano la frequenza (`sweetspot-cpu`,
governor `performance`). Su un computer senza ventola possono alzare
consumo e temperatura e togliere risorse a scansione e DSP.

Il profilo `conservativo` le disattiva: SMT attivo, stati C liberi, governor
`schedutil` (o `ondemand`) con l'intera gamma di frequenza.

## Selezione

In `sweetspot.txt` sulla chiavetta:

    ENERGIA=fisso          # predefinito
    ENERGIA=conservativo

Dove si applica:

- `sweetspot-autotune`: nosmt e parametri degli stati C entrano nella riga
  di comando solo con `fisso`; al cambio di profilo cambia l'hash dei
  parametri e c'e' un solo riavvio (come per le altre impostazioni).
- `sweetspot-cpu` (a runtime, senza riavvio): con `conservativo` imposta il
  governor, riapre l'intervallo di frequenza, riattiva l'SMT
  (`smt/control`) e abilita tutti gli stati C (`cpuidle/state*/disable`).
- `sweetspot-check` riporta i valori come informazione, non come avviso.

Il passaggio a `conservativo` a runtime e' completo; il ritorno a `fisso`
richiede il riavvio per spegnere l'SMT e limitare gli stati C (parametri
del kernel).

## Confronto

Per ogni profilo, a parita' di brano e di condizioni (stesso DAC, stessa
temperatura ambiente, almeno 10 minuti di riproduzione a regime):

    sweetspot-energia misura 60 10 /tmp/fisso.txt
    # impostare ENERGIA=conservativo, riavviare, riprodurre lo stesso brano
    sweetspot-energia misura 60 10 /tmp/conservativo.txt
    sweetspot-energia confronta /tmp/fisso.txt /tmp/conservativo.txt

Il riepilogo contiene: XRUN (il maggiore fra i campioni in stato XRUN e la crescita, durante la misura, di `xrun_counter` del kernel con `CONFIG_SND_PCM_XRUN_DEBUG` e degli eventi XRUN nel registro di Squeezelite: contano anche gli XRUN recuperati entro un campionamento) e ritardo massimo da
`/proc/asound/card*/pcm*p/sub*/status`, CPU, memoria residente dei processi
principali, PSI (`/proc/pressure/*`), temperatura massima e throttling
(`/sys/class/thermal`, `thermal_throttle`), frequenza media (cpufreq),
potenza media in mW se c'e' RAPL (`powercap`) e tempo di risposta di
`/cgi-bin/sistema` (variabile `SWEETSPOT_URL`, serve `curl`).

Il profilo conservativo e' preferibile se temperatura o potenza scendono
senza XRUN e senza aumento di ritardi o di PSI. Altrimenti resta `fisso`.
