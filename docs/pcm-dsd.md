# PCM → DSD: nota di ricerca

Stato: **non implementato, per scelta**. La roadmap lo indica solo come
ricerca; questa nota raccoglie perché e a quali condizioni riaprirlo.

## Che cosa vorrebbe dire

Convertire in tempo reale i brani PCM (44,1–384 kHz) in DSD (DSD64–DSD512)
e mandarli al DAC in DSD nativo o DoP. Alcuni ascoltatori lo preferiscono
perché il DAC usa il suo percorso DSD invece del filtro PCM interno; è la
funzione principale di prodotti come HQPlayer.

## Perché oggi no

- **Nessuno dei componenti di Sweetspot lo fa.** Squeezelite riproduce DSD
  (nativo o DoP) ma non lo genera; CamillaDSP elabora solo PCM; Lyrion può
  convertire DSD→PCM, non il contrario.
- **Serve un modulatore delta-sigma di qualità.** La qualità sta tutta nel
  modulatore (ordine, stabilità, rumore fuori banda) e nel sovracampionamento
  che lo precede. Un modulatore semplice, come quello del generatore di prova
  DoP di Sweetspot (`sweetspot-prova-dop`, secondo ordine), serve a provare
  il collegamento, non ad ascoltare: peggiorerebbe il segnale invece di
  migliorarlo.
- **Costo di CPU alto e continuo.** Sovracampionare a 64–512 volte 44,1 kHz e
  modulare in tempo reale impegna molto il processore per tutta la durata
  dell'ascolto: contrario all'obiettivo di Sweetspot (core audio isolato e
  quasi fermo, pochi risvegli, CPU a frequenza fissa e bassa). Sui computer
  leggeri e sul Raspberry Pi non sarebbe sostenibile ai rapporti più alti.
- **Non è bit-perfect per definizione.** Ogni brano PCM verrebbe trasformato;
  il percorso attuale lascia invariati i campioni.

## Che cosa fa oggi Sweetspot con il DSD

- File DSD (DSF/DFF): al DAC in DSD nativo se lo dichiara, in DoP se scelto,
  oppure convertiti in PCM da Squeezelite, alla frequenza più alta che il DAC accetta (`DSD=auto`, pagina Audio).
  Se il DAC non regge DSD/8 (352,8 kHz per DSD64) il PCM si decima per 2 una
  o più volte (patch 0004): ogni stadio è un passa-basso a fase lineare
  (finestra di Kaiser) piatto entro ±0,001 dB fino a 20 kHz e attenuato di
  almeno 100 dB dalla nuova Nyquist in su, quindi nulla ripiega nella banda
  audio. Stima del costo per canale: DSD64 verso 176,4 kHz circa 3,5 milioni di
  moltiplicazioni al secondo; DSD512 verso 44,1 kHz circa 52 milioni (stadi di
  31, 33, 35, 39, 55 e 307 punti, l'ultimo ripido ma al ritmo più basso), cioè
  una frazione piccola di un core del Raspberry Pi 4. Il test di C
  (`tests/squeezelite-dsd-decimation.py`) misura passband, stopband e costo.
- Margine della conversione (`DSD_PCM_MARGINE_DB`, di serie -3 dB, da -24 a 0):
  i DSD "over" superano 0 dBFS fino a +3 dB, cioè il 50% di modulazione oltre lo
  standard, e senza margine verrebbero tagliati a 32 bit. Il prezzo è che tutto
  il DSD convertito suona 3 dB più piano; chi sa che i suoi file non superano
  0 dBFS può portarlo a 0. Si imposta e si legge nelle pagine Audio e Stato.
- Prova DoP guidata dalla pagina Audio per i DAC senza DSD nativo.

## Quando riaprirlo

1. Esiste un modulatore libero (licenza compatibile con GPL-3.0) di qualità
   misurata, utilizzabile come libreria o come processo a pipeline tra
   Squeezelite e ALSA.
2. Il costo di CPU, misurato sul computer di riferimento (N550JV) e su un
   Raspberry Pi 5, lascia la latenza durante l'ascolto sotto 150 µs
   (`LATENZA_ASCOLTO=si`) e nessun XRUN in una prova di 24 ore
   (`sweetspot-durata`).
3. Resta un'opzione esplicita, spenta di serie, mai attiva insieme al
   percorso bit-perfect.
