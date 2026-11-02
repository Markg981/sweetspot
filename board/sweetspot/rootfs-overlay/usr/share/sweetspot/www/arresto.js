/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Pagina di spegnimento e riavvio (cgi-bin/arresto): segue le fasi
   interrogando /cgi-bin/vivo, che risponde "ok ..." finche' il server web
   e' acceso. Il server web si ferma tra gli ultimi servizi, dopo il
   salvataggio di libreria e impostazioni.
   - risponde: Sweetspot sta ancora salvando e fermando i servizi;
   - non risponde (due volte di fila): il computer si spegne o si riavvia;
   - riavvio, risponde di nuovo: pronto, si passa alla pagina Stato. */
(function () {
	'use strict';
	var box = document.querySelector('[data-arresto]');
	if (!box || !window.fetch) return;

	var RIAVVIO = box.getAttribute('data-arresto') !== 'spegnimento';
	var DOPO = box.getAttribute('data-dopo') || '/cgi-bin/stato';
	var OGNI = 2000;          // ms fra due domande
	var ATTESA_RISPOSTA = 4000;
	var CODA_SPEGNIMENTO = 12000; // dopo il server web: smontaggio dei dischi
	var LENTO_ARRESTO = 180000;
	var LENTO_AVVIO = 240000;

	var fase = document.getElementById('arresto-fase');
	var nota = box.querySelector('[data-arresto-nota]');
	var tempo = box.querySelector('[data-arresto-tempo]');
	var inizio = Date.now();
	var giuDa = 0;
	var mancate = 0;
	var finito = false;

	function stato(classe, testo, testoNota) {
		box.className = 'card arresto ' + classe;
		if (testo && fase.textContent !== testo) fase.textContent = testo;
		if (testoNota !== undefined && nota) nota.textContent = testoNota;
	}

	function passo(n) {
		var li = box.querySelectorAll('[data-passo]');
		for (var i = 0; i < li.length; i++) {
			var k = +li[i].getAttribute('data-passo');
			li[i].className = k < n ? 'fatto' : k === n ? 'in-corso' : '';
		}
	}

	function orologio() {
		if (!tempo || finito) return;
		var s = Math.floor((Date.now() - inizio) / 1000);
		tempo.hidden = false;
		tempo.textContent = 'Trascorsi ' + Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2);
	}

	function sonda(fatto) {
		var ctl = window.AbortController ? new AbortController() : null;
		var timer = setTimeout(function () { if (ctl) ctl.abort(); }, ATTESA_RISPOSTA);
		var opz = { cache: 'no-store', credentials: 'same-origin' };
		if (ctl) opz.signal = ctl.signal;
		fetch('/cgi-bin/vivo?_=' + Date.now(), opz)
			.then(function (r) { return r.ok ? r.text() : ''; })
			.then(function (t) { clearTimeout(timer); fatto(/^ok/.test(t)); })
			.catch(function () { clearTimeout(timer); fatto(false); });
	}

	function prossimo(ms) { if (!finito) setTimeout(giro, ms || OGNI); }

	function giro() {
		sonda(function (su) {
			var ora = Date.now();
			if (!giuDa) {
				// Fase 1: salvataggio e arresto dei servizi.
				mancate = su ? 0 : mancate + 1;
				if (mancate < 2) {
					if (ora - inizio > LENTO_ARRESTO) {
						stato('arresta lento', null, 'Ci sta mettendo più del solito. Se tra qualche minuto non cambia nulla, apri la pagina Stato per controllare.');
					}
					return prossimo();
				}
				giuDa = ora;
				passo(2);
				if (RIAVVIO) {
					stato('avvio', 'Riavvio del computer', 'Sweetspot riparte: la pagina si aggiorna da sola appena risponde.');
				} else {
					stato('spegne', 'Spegnimento del computer', 'Ultimi passi: i dischi vengono chiusi. Non staccare ancora la corrente.');
				}
				return prossimo();
			}
			if (!RIAVVIO) {
				// Fase 2 dello spegnimento: il server non risponde piu'.
				if (ora - giuDa < CODA_SPEGNIMENTO) return prossimo();
				finito = true;
				passo(4);
				stato('spento', 'Sweetspot è spento',
					'Quando il computer è fermo (ventola e luci spente) puoi staccare la corrente. Per riaccenderlo usa il suo pulsante.');
				return;
			}
			// Fase 2 del riavvio: si aspetta che torni.
			if (su) {
				finito = true;
				passo(3);
				stato('pronto', 'Sweetspot è di nuovo pronto', 'Apertura della pagina Stato…');
				setTimeout(function () { location.replace(DOPO); }, 1500);
				return;
			}
			if (ora - giuDa > LENTO_AVVIO) {
				stato('avvio lento', null, 'Non risponde ancora. Controlla che il computer sia acceso e collegato alla rete: la pagina continua a provare.');
				return prossimo(5000);
			}
			prossimo();
		});
	}

	stato('arresta');
	setInterval(orologio, 1000);
	prossimo(1500);
}());
