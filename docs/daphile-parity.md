# Sweetspot: parità con Daphile e miglioramenti verificabili

Obiettivo del prodotto: conservare i punti di forza di Daphile, completarli
senza regressioni e migliorare compatibilità, affidabilità, semplicità d'uso
e controllo del percorso audio. Le correzioni di un singolo commit non
esauriscono questo obiettivo. Una superiorità sonora richiede prove sullo
stesso hardware, DAC e livello d'ascolto.

Questa analisi riguarda il codice di `main` al commit `3295d58`. Le funzioni presenti
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

## Stato delle funzioni rispetto a Daphile

Stato verificato leggendo il codice di `main`. Colonna **Verifica**:
*CI* = coperto da test automatici (`tests/run.sh`, prove audio, prova Lyrion
in QEMU) che non richiedono un DAC; *hardware* = provato su un DAC o un
computer reale con rapporto in [`compatibilita/`](compatibilita/); *non
verificato* = nessuna delle due. Al momento nessuna riga ha una verifica
su hardware: la matrice (`docs/compatibilita.md`) non contiene ancora rapporti.

| Area | Stato su main | Verifica | Cosa manca |
| --- | --- | --- | --- |
| Riproduzione dalla RAM | Implementata: `sweetspot-precarico` (`S68sweetspot-precarico`) carica in RAM la coda di ascolto con budget (`PRECARICO_MB`, `PRECARICO_FILE_MAX_MB`), esclude i file troppo grandi, stato in `precarico.json` e sulla pagina Stato; i buffer del player restano (`player_buffers`). Solo in modalità completa. | CI (`tests/run.sh`, `tests/precarica.py`); non verificato su hardware | Prova su dischi/NAS reali e con musica in alta risoluzione; lo streaming resta fuori dal precarico. |
| Gapless e integrità PCM/DSD | Motore e configurazione presenti; prove di campioni e confini fra brani su Squeezelite stdout e su `snd-aloop` (vedi sotto). | CI per PCM, DoP, DSF/DFF e sei cambi di frequenza WAV24; non verificato sui DAC | DSD nativo, DAC reali, cambi PCM/DSD, hotplug, carico prolungato. |
| Convoluzione FIR/DRC | Implementata in `sweetspot-dsp`: un FIR per frequenza (`fir-FREQ.wav`, oppure `fir-sinistro-FREQ.wav` e `fir-destro-FREQ.wav`; i vecchi `fir-sinistro.wav`/`fir-destro.wav` valgono per la frequenza scritta nel file), validazione per frequenza (`fir_ok`, dimensione massima, frequenza nel nome uguale a quella nel file, canali coerenti), frequenza senza FIR: `blocca`, `diretto` o ricampionamento esplicito (`FIR_RICAMPIONA=si`); un'unica istanza di CamillaDSP per sessione avviata dal player sui core di sistema, con cambio di configurazione a ogni frequenza senza riavvio (#90), priorità per ruolo (riproduzione >= elaborazione >= cattura), margine di ampiezza `FIR_MARGINE_DB` (3 dB), latenza dichiarata; si somma ai biquad REW tramite CamillaDSP. | CI (generazione della configurazione, guadagno, `extra_samples`); non verificato su hardware | Misura della risposta a valle e confronto a pari volume; comportamento di CamillaDSP ai ricaricamenti con dispositivi diversi, compilazione del plugin e prova QEMU (`tests/camilladsp-sessione.py`) verificati solo dalla CI. |
| Più DAC locali | Implementati come zone con `ALTRI_DAC=si`: un Squeezelite per ogni altro DAC USB, MAC stabile da identificativo USB e numero di serie, avvio e arresto con il collegamento, il principale resta fisso per tutto l'avvio. | CI (scelta e conservazione del DAC principale); non verificato su hardware | Due DAC reali in contemporanea; sincronizzazione fra zone, delegata ai gruppi di Lyrion, non provata. |
| Renderer UPnP/DLNA in ingresso | `RENDERER_UPNP=si` (`S70sweetspot-renderer`, `renderer.pl`): SweetSpot compare come MediaRenderer; l'audio passa da Lyrion e dal player. Di serie spento. | CI (`tests/renderer-upnp.py`, prova Lyrion); non verificato con le app reali | Prova con BubbleUPnP, JPlay, mconnect; gapless e formati da app. |
| Media server UPnP/DLNA | `SERVER_UPNP=si` (`S71sweetspot-mediaserver`, `sweetspot-mediaserver`, MiniDLNA): la libreria in rete per streamer e DAC di rete; DSF/DFF inviati senza conversione. Di serie spento. | CI (configurazione, pannello, stato, helper privilegiato); non verificato con renderer reali | Prova con un renderer DSD in rete (es. Gustard R26) fino a DSD512; librerie grandi; cartelle di rete aggiornate da altri computer. |
| PCM→DSD | `-R` configura ricampionamento PCM; le opzioni DSD gestiscono sorgenti già DSD. Non c'è conversione PCM→DSD e non è prevista, per scelta: costo di CPU del modulatore, rischio di peggiorare il suono su hardware modesto, supporto dei DAC; motivi in [`pcm-dsd.md`](pcm-dsd.md). | non implementato, non previsto | Nessuno. |
| Primo avvio Wi-Fi | Hotspot di configurazione `Sweetspot-XXXX` (`sweetspot-hotspot`, `hostapd`, `udhcpd`/`dnsd`) quando dopo `HOTSPOT_ATTESA` non c'è rete e un adattatore supporta AP; scelta della rete dalla pagina Rete, recupero se la rete salvata non si collega. Firewall dell'hotspot (`S41sweetspot-firewall`, `firewall.nft`): sulla sola scheda dell'AP ammette DNS, DHCP, HTTP e HTTPS, il resto del traffico resta com'era; Lyrion, SMB e DLNA non vi sono esposti. Pagine per il portale captive (`hotspot-detect.html`, `canonical.html`) che portano alla pagina Rete. | CI (logica dell'hotspot, contenuto del firewall e `nft -c` sulle regole se `nft` è disponibile, pagine del portale); non verificato su hardware | Prova con Intel, Realtek, Broadcom del Pi; comportamento reale del portale captive su iPhone, Android, Windows. |
| Ambito hardware | Target x86_64 (`sweetspot_x86_64_defconfig`) e aarch64 per Pi 4/5 (`sweetspot_rpi_defconfig`). x86 a 32 bit e ARM a 32 bit non sono supportati e sono fuori ambito. Il rapporto (`sweetspot-rapporto`) e la matrice generata (`tools/matrice-compatibilita.py`, `docs/compatibilita.md`, controllata dalla CI con `--verifica`) esistono. | CI (compilazione delle due immagini, generazione e coerenza della matrice) | Matrice pubblica ancora senza rapporti reali. |
| RAAT / Roon | Assente. Roon Ready richiede SDK e certificazione ufficiali di Roon Labs: non si dichiara compatibilità. | non applicabile | Fuori ambito finché non esiste un accordo con Roon. |
| WASAPI / CoreAudio | Fuori ambito: SweetSpot è un'appliance Linux con ALSA diretto. | non applicabile | Nessuno. |

Streaming e ingressi hanno una tabella di stato dedicata nel
[README](../README.md#servizi-in-streaming-e-ingressi-stato-e-qualificazione).

Le PR #82 (alterazioni del segnale e volume), #84 (demone a eventi dello
stato), #87 (Bluetooth come sorgente) e #89 (drain al cambio di frequenza)
sono ora su `main`, con test in `tests/` (`demone-eventi.sh`, `bluetooth.sh`
e i controlli di `tests/run.sh`), ma non hanno ancora una riga propria in
questa tabella. Altre PR aperte non sono su `main` e non sono descritte qui.

Evidenze nel codice:

- `usr/lib/sweetspot/common.sh`: `player_buffers`, `dac_find`, `dac_wanted`, `dac_is_zone`.
- `usr/bin/sweetspot-player`: `resample_args`, `run_player`, zone `ALTRI_DAC`.
- `usr/bin/sweetspot-precarico`: precarico della coda.
- `usr/bin/sweetspot-hotspot`, `usr/bin/sweetspot-firewall`, `etc/init.d/S41sweetspot-firewall`, `etc/sweetspot/firewall.nft`: hotspot e suo firewall.
- `etc/init.d/S21sweetspot-watchdog` (e l'opzione `WATCHDOG` in `etc/init.d/S03sweetspot-early`); `CONFIG_WATCHDOG` in `board/sweetspot/common/linux.fragment` e `busybox.fragment`.
- `tools/matrice-compatibilita.py` e `docs/compatibilita.md`.
- `usr/bin/sweetspot-dsp`: `parse_rew`, `fir_ok`, `write_filters_yaml`, `write_config`.
- `usr/lib/sweetspot/renderer.pl` e `etc/init.d/S70sweetspot-renderer`.
- `usr/bin/sweetspot-mediaserver` e `etc/init.d/S71sweetspot-mediaserver`.
- `configs/sweetspot_x86_64_defconfig` e `configs/sweetspot_rpi_defconfig`: architetture e pacchetti.

I percorsi `usr/` ed `etc/` sono relativi a `board/sweetspot/rootfs-overlay/`.

## Miglioramenti che devono distinguere Sweetspot

1. **Compatibilità pubblica e riproducibile.** La FAQ Daphile dichiara che il
   progetto non mantiene informazioni di compatibilità e non supporta ARM.
   Sweetspot aggiunge target Raspberry Pi e deve pubblicare risultati per
   release, computer, DAC, firmware e adattatori di rete. Separare riconoscimento,
   funzionamento verificato e certificazione audio. Non promettere ogni dispositivo.
2. **Recupero verificato.** A/B, firme e backup sono presenti, compresi un watchdog hardware e il
   ritorno automatico dopo riavvii ripetuti. La conferma
   controlla ora impostazioni leggibili, `/cgi-bin/vivo`, supervisore del
   player in esecuzione, Lyrion che risponde (solo in modalità completa, con
   attesa fino a 10 minuti per il primo avvio su Raspberry Pi) e accesso a
   musica e dati di Lyrion; il controllo fallito è registrato (pagina Sistema,
   rapporto, registro). L'assenza di un DAC opzionale ("in attesa del DAC")
   non provoca un ciclo di rollback. Il watchdog (`S21sweetspot-watchdog`, attivo di serie,
   `WATCHDOG=no` lo spegne) usa il watchdog del chipset (iTCO, SP5100, Raspberry
   Pi) o `softdog`, e riavvia una macchina bloccata; se l'avvio precedente è
   finito per il watchdog, `sweetspot-aggiorna watchdog` conta i riavvii e al
   secondo di seguito avvia l'altra copia dal prossimo avvio. In CI: conteggio
   dei riavvii e passaggio alla copia B (`tests/run.sh`); watchdog i6300ESB di
   QEMU attivo e computer che riparte da un blocco simulato, con player di nuovo
   attivo (`tests/prova-robustezza-qemu.sh`, solo x86). Scaricamento
   interrotto con copia precedente intatta e copia troncata da un taglio di
   corrente sono coperti da `tests/run.sh`. Restano da fare:
   inizializzazione del percorso audio richiesto nella conferma, database
   corrotti, aggiornamenti interrotti e perdita di alimentazione su hardware
   reale, watchdog su Raspberry Pi e su chipset reali (non verificati).
3. **Audio diagnosticabile.** Mostrare trasformazioni del server, volume,
   DSP, formato realmente aperto, clipping e underrun delle singole fasi.
   Le misure dello scheduler non sono misure del clock del DAC. Valutare le
   ottimizzazioni CPU/IRQ contro un profilo conservativo usando dati.
4. **Distribuzione utilizzabile.** La chiave pubblica degli aggiornamenti è nel
   repository e la CI rifiuta release non firmate o con firma non valida
   (`tests/release-gates.py`); la privata sta in un ambiente GitHub limitato ai tag
   `v*` ([`aggiornamenti.md`](aggiornamenti.md)), cosa che nessun test verifica.
   Il pannello ha una password amministrativa con sessione (`PASSWORD_WEB`,
   `tests/accesso.sh`); il token POST protegge dalle richieste incrociate, non è
   un login. Il modello di minaccia è deciso: LAN fidata, hotspot non fidato
   ([docs/modello-minaccia.md](modello-minaccia.md)). Resta da fare
   il ripristino semplice delle impostazioni.

## Ordine di realizzazione e criteri di accettazione

| Traguardo | Lavoro | Criterio di completamento |
| --- | --- | --- |
| 1 — Percorso audio verificabile | Harness di confronto dei campioni e transizioni; matrice PCM/DSD/DoP, cambio frequenza, hotplug e carico. | Report collegato alla release; bit-perfect PCM e gapless dimostrati per ogni combinazione certificata; guasti riproducibili e diagnosticati. |
| 2 — RAM e FIR | Precaricamento esplicito e convoluzione opzionale; mantenere biquad REW e modalità originale. | Per un file finito che rientra nel budget, carico completato prima della riproduzione e prova del comportamento dichiarato su rete/disco; FIR validati con risposta e headroom verificati, senza regressioni gapless. |
| 3 — Parità funzionale | Più DAC locali, hotspot (con firewall), renderer e media server UPnP/DLNA (PCM→DSD e x86 a 32 bit sono fuori ambito). | Scenari di uso coperti su dispositivi compatibili, limiti visibili e nessuna modifica involontaria del percorso originale. |
| 4 — Distribuzione | Autenticazione, chiavi, controlli A/B completi, recupero e matrice hardware pubblica. | Nuova installazione senza terminale, aggiornamento firmato verificato, recupero di fallimenti provato e test di alimentazione su hardware reale. |

**Avanzamento del traguardo 1:** prima copertura del confronto PCM e dei
confini fra due brani locali a frequenza costante, incluse profondità PCM
miste, del payload WAV DoP a 176,4/352,8 kHz e delle sorgenti DSF/DFF DSD64/128
nel backend stdout del Squeezelite compilato. Il
[protocollo di verifica](audio-verification.md) descrive report e limiti.
La matrice aggiunge sei transizioni WAV24 fra 44,1, 48 e 96 kHz, confrontando
la sequenza completa dei frame e gli annunci di rate del motore. Il pacing
del consumer stdout resta distinto dalla frequenza delle tracce e dal clock
del DAC; la nuova estensione richiede la propria evidenza di esecuzione.
Le nuove fixture DFF hanno individuato un errore di allineamento dei chunk
dispari nel decoder, corretto con una patch comune alle due piattaforme.
Le immagini complete x86 e ARM hanno superato i 18 casi software nella
[CI della PR #15](https://github.com/Markg981/sweetspot/actions/runs/38051082986).
La diagnostica Audio e Stato osserva ora il solo PCM selezionato, distingue
gli stati ALSA di riproduzione, preparazione e guasto e segnala dati mancanti
o più substream aperti. Gli eventi XRUN e i recuperi falliti sono conteggiati
separatamente nel registro storico. Queste osservazioni aiutano a individuare
un guasto, ma non certificano i campioni né l'uscita del DAC.
La [CI della PR #16](https://github.com/Markg981/sweetspot/actions/runs/38056065758)
ha confermato le compilazioni e i 18 casi precedenti su x86 e ARM, pubblicando
anche entrambi gli archivi di evidenza audio.
I 18 casi a frequenza costante si ripetono ora sul driver ALSA del kernel x86
di Sweetspot (PREEMPT_RT, avviato in QEMU nella CI), su `hw:Loopback` di
snd-aloop, con i parametri `hw:`, mmap e periodi del player. Un XRUN o un
campione diverso blocca la release. Su ARM resta la sola prova stdout.
Un caso a parte (`tests/camilladsp-sessione.py`) prova CamillaDSP di sessione:
una sola istanza con il plugin cdsp, un cambio di frequenza 44,1 → 96 kHz dal
websocket, stesso PID prima e dopo e tono a 1 kHz corretto a entrambe le
frequenze; salta se l'immagine non include CamillaDSP.
**Avanzamento dei traguardi 2-4:** la RAM (`sweetspot-precarico`) e i FIR
(`sweetspot-dsp`) sono implementati e coperti dalla CI, non verificati su
hardware né con misure a valle. Del traguardo 3 sono su `main` più DAC locali,
hotspot con firewall, renderer e media server UPnP/DLNA, tutti coperti dalla CI
e nessuno provato su dispositivi reali. Del traguardo 4 sono presenti il ritorno
A/B con watchdog, la firma degli aggiornamenti, la password del pannello e la
matrice di compatibilità (strumento e pagina generata, senza rapporti); mancano
i test di alimentazione e i rapporti su hardware reale.

Il traguardo 1 resta parziale: DSD nativo, DAC reali, cambi PCM/DSD, cambi
frequenza su ALSA e sui DAC, hotplug, rete e carico prolungato richiedono
ancora prove.

Il confronto di ascolto con Daphile usa la stessa sorgente, DAC, uscita,
livello e impostazioni equivalenti. La correzione ambientale può migliorare
il risultato acustico; per confrontarla bisogna verificare anche le misure
della stanza e la risposta dei filtri. Non si dichiara un vantaggio sonoro
generale dalla sola scelta del player, del kernel o dei buffer.

Modello di minaccia e requisiti di sicurezza: [modello-minaccia.md](modello-minaccia.md).
