# Matrice di compatibilità

Generata da `tools/matrice-compatibilita.py` dai rapporti in
[`docs/compatibilita/`](compatibilita/): non modificarla a mano.

Ogni riga è un rapporto creato su un sistema reale con
`sweetspot-rapporto` (pagina **Stato** → *Scarica il rapporto di
compatibilità*) e inviato con una segnalazione *Rapporto di compatibilità*
su GitHub. "Avvisi" conta le voci ATTENZIONE della pagina Stato in quel
momento; la prova di durata è `sweetspot-durata` (24 ore di ascolto).

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
