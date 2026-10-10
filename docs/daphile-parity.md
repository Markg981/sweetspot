# Sweetspot: parità con Daphile e miglioramenti verificabili

Obiettivo del prodotto: conservare i punti di forza di Daphile, completarli
senza regressioni e migliorare compatibilità, affidabilità, semplicità d'uso
e controllo del percorso audio. Le correzioni di un singolo commit non
esauriscono questo obiettivo. Una superiorità sonora richiede prove sullo
stesso hardware, DAC e livello d'ascolto.

Questa analisi riguarda il codice del commit `591942b`. Le funzioni presenti
nel codice non sono automaticamente certificate sui dispositivi reali.

## Baseline Daphile da raggiungere e conservare

- Controllo dal browser e dalle app compatibili, libreria Lyrion, plugin e streaming.
- Percorso ALSA diretto; PCM, DSD nativo e DoP; volume fisso senza DSP come impostazione iniziale.
- Riproduzione gapless, da verificare alla transizione fra brani.
- Musica da dischi e NAS, archivio condiviso, ripping sicuro con AccurateRip, tag e copertine.
- Installazione semplice, aggiornamenti e conservazione di impostazioni, libreria e plugin.
- Ricampionamento facoltativo, correzione ambientale, riproduzione dalla RAM e più player.

Riferimenti Daphile: [funzioni dichiarate](https://www.daphile.com/index.html)
e [FAQ ufficiale](https://www.daphile.com/download/FAQ.txt).

## Gap confermati nel progetto

| Area | Stato attuale | Risultato necessario |
| --- | --- | --- |
| Riproduzione dalla RAM | Il sistema è in RAM; `player_buffers()` e `squeezelite -b` impostano buffer, senza garantire il caricamento completo di un brano. | Modalità di precaricamento per file finiti, con budget di memoria, stato visibile e gestione esplicita di file troppo grandi. Lo streaming rimane distinto. |
| Gapless e integrità PCM/DSD | Motore e configurazione presenti; mancano prove dei campioni e delle transizioni sui DAC fisici. | Evidenze per formato, frequenza, modalità, hardware e firmware; nessuna etichetta di certificazione basata solo sul display del DAC. |
| Convoluzione FIR/DRC | `sweetspot-dsp` importa biquad REW stereo; CamillaDSP è presente, ma non esiste il caricamento di impulsi FIR. | FIR importabili e validati, gestione delle frequenze, headroom, latenza e confronto a pari volume; mantenere il percorso originale. |
| Più DAC locali | Un supervisore, un PID e una MAC Squeezelite; i player remoti di Lyrion non risolvono questa lacuna. | Più uscite indipendenti sullo stesso host, con configurazioni e recupero separati; sincronizzazione verificata quando richiesta. |
| PCM→DSD | `-R` configura ricampionamento PCM; le opzioni DSD gestiscono sorgenti già DSD. | Conversione opzionale esplicita, backend e modulatore definiti, limiti di CPU e DAC verificati. |
| Primo avvio Wi-Fi | Senza `WIFI_NOME` le interfacce wireless sono ignorate; non c'è un hotspot di configurazione. | Configurazione senza cavo su adattatori compatibili, credenziali sicure e recupero dopo impostazioni errate. |
| Ambito hardware | Target x86_64 e Pi 4/5 e varianti; manca il target CPU x86 a 32 bit presente fra i download Daphile. | Matrice di supporto e decisione esplicita sul target x86 a 32 bit; ampliare driver e firmware in base a prove. |

Evidenze nel codice:

- `usr/lib/sweetspot/common.sh`: `player_buffers`, `dac_find`.
- `usr/bin/sweetspot-player`: `resample_args`, `run_player`, supervisione di un solo player.
- `usr/bin/sweetspot-dsp`: `parse_rew`, `write_filters_yaml`, `write_config`.
- `etc/init.d/S40sweetspot-net`: configurazione Wi-Fi solo con SSID impostato.
- `configs/sweetspot_x86_64_defconfig` e `configs/sweetspot_rpi_defconfig`: architetture e pacchetti.

I percorsi `usr/` ed `etc/` sono relativi a `board/sweetspot/rootfs-overlay/`.

## Miglioramenti che devono distinguere Sweetspot

1. **Compatibilità pubblica e riproducibile.** La FAQ Daphile dichiara che il
   progetto non mantiene informazioni di compatibilità e non supporta ARM.
   Sweetspot aggiunge target Raspberry Pi e deve pubblicare risultati per
   release, computer, DAC, firmware e adattatori di rete. Separare riconoscimento,
   funzionamento verificato e certificazione audio. Non promettere ogni dispositivo.
2. **Recupero verificato.** A/B, firme e backup sono presenti. La conferma
   attuale controlla soltanto `/cgi-bin/vivo`: va estesa a integrità delle
   impostazioni, avvio di Lyrion e supervisore, accesso alla libreria e
   inizializzazione del percorso richiesto. L'assenza di un DAC opzionale non
   deve provocare un ciclo di rollback. Provare anche aggiornamenti interrotti,
   database corrotti e perdita di alimentazione. Il ritorno attuale avviene
   al prossimo avvio, non tramite un watchdog che riavvia una macchina bloccata.
3. **Audio diagnosticabile.** Mostrare trasformazioni del server, volume,
   DSP, formato realmente aperto, clipping e underrun delle singole fasi.
   Le misure dello scheduler non sono misure del clock del DAC. Valutare le
   ottimizzazioni CPU/IRQ contro un profilo conservativo usando dati.
4. **Distribuzione utilizzabile.** Provisioning delle chiavi degli aggiornamenti,
   protezione amministrativa del pannello e ripristino semplice delle impostazioni.
   Il token POST esistente protegge dalle richieste incrociate, non costituisce un login.

## Ordine di realizzazione e criteri di accettazione

| Traguardo | Lavoro | Criterio di completamento |
| --- | --- | --- |
| 1 — Percorso audio verificabile | Harness di confronto dei campioni e transizioni; matrice PCM/DSD/DoP, cambio frequenza, hotplug e carico. | Report collegato alla release; bit-perfect PCM e gapless dimostrati per ogni combinazione certificata; guasti riproducibili e diagnosticati. |
| 2 — RAM e FIR | Precaricamento esplicito e convoluzione opzionale; mantenere biquad REW e modalità originale. | Per un file finito che rientra nel budget, carico completato prima della riproduzione e prova del comportamento dichiarato su rete/disco; FIR validati con risposta e headroom verificati, senza regressioni gapless. |
| 3 — Parità funzionale | Più DAC locali, PCM→DSD opzionale, hotspot e definizione del supporto x86 a 32 bit. | Scenari di uso coperti su dispositivi compatibili, limiti visibili e nessuna modifica involontaria del percorso originale. |
| 4 — Distribuzione | Autenticazione, chiavi, controlli A/B completi, recupero e matrice hardware pubblica. | Nuova installazione senza terminale, aggiornamento firmato verificato, recupero di fallimenti provato e test di alimentazione su hardware reale. |

**Avanzamento del traguardo 1:** prima copertura del confronto PCM e dei
confini fra due brani locali a frequenza costante, incluse profondità PCM
miste, del payload WAV DoP a 176,4/352,8 kHz e delle sorgenti DSF/DFF DSD64/128
nel backend stdout del Squeezelite compilato. Il
[protocollo di verifica](audio-verification.md) descrive report e limiti.
Le nuove fixture DFF hanno individuato un errore di allineamento dei chunk
dispari nel decoder, corretto con una patch comune alle due piattaforme.
Il traguardo resta parziale: DSD nativo, ALSA e DAC reali,
cambi frequenza, hotplug, rete e carico prolungato richiedono ancora prove.

Il confronto di ascolto con Daphile usa la stessa sorgente, DAC, uscita,
livello e impostazioni equivalenti. La correzione ambientale può migliorare
il risultato acustico; per confrontarla bisogna verificare anche le misure
della stanza e la risposta dei filtri. Non si dichiara un vantaggio sonoro
generale dalla sola scelta del player, del kernel o dei buffer.
