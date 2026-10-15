# Matrice di compatibilità

Generata da `tools/matrice-compatibilita.py` dai rapporti in
[`docs/compatibilita/`](compatibilita/): non modificarla a mano.

Ogni riga è un rapporto creato su un sistema reale con
`sweetspot-rapporto` (pagina **Stato** → *Scarica il rapporto di
compatibilità*) e inviato con una segnalazione *Rapporto di compatibilità*
su GitHub. "Avvisi" conta le voci ATTENZIONE della pagina Stato in quel
momento; la prova di durata è `sweetspot-durata` (24 ore di ascolto).

## Cosa copre la CI e cosa no

La CI prova il percorso software senza un DAC fisico: Lyrion, Squeezelite e il
driver ALSA del kernel su `snd-aloop` (dettagli in
[`audio-verification.md`](audio-verification.md)). Non sostituisce le prove su
hardware reale, che sono le righe di questa tabella.

| In CI (campioni identici, sorgenti sintetiche) | Non in CI (serve hardware) |
| --- | --- |
| WAV, FLAC e ALAC a 16/24 bit, 44,1-192 kHz, fino al PCM bit-identico | Clock, jitter e firmware di un DAC USB/I2S/S/PDIF reale |
| Cambi di frequenza 44,1/48/96 kHz, in stdout e su ALSA (`snd-aloop`) | Cambio di frequenza su un DAC vero (rilock, pop, mute) |
| DSF/DFF come DoP con i marcatori, e ritorno al PCM pulito su ALSA | DSD nativo, DST, DoP riconosciuto da un DAC |
| Nessuna riproduzione persa o duplicata nella coda prima della riapertura | Hotplug del DAC durante l'ascolto (`snd-aloop` non si può rimuovere con il flusso aperto) |

Nessun rapporto ancora: il primo arriverà dalle prove sull'hardware.

## Come compilare un rapporto

Il rapporto JSON (`sweetspot-rapporto`) registra ciò che il sistema sa da
solo. Per la parte che solo chi ascolta può dire, dal terminale:

    sweetspot-rapporto modello

stampa un modello in Markdown già compilato con DAC, firmware (bcdDevice),
frequenze dichiarate, piattaforma, kernel, release di SweetSpot e avvisi della
pagina Stato. Restano da riempire, con "non provato" come valore di partenza,
le prove di PCM (44,1-48 e 88,2-192 kHz), DSD nativo, DoP, cambio di
frequenza fra brani, hotplug del DAC e l'esito complessivo. Incolla il modello
e il JSON nella segnalazione *Rapporto di compatibilità*.

Il modello non certifica nulla: un esito OK senza ascolto o misura dei
campioni non va dichiarato. Un riconoscimento del DAC non è una verifica
audio (vedi [audio-verification.md](audio-verification.md)).
