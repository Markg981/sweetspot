/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Tema chiaro/scuro di Studio e impostazioni. La scelta resta nel browser
   (localStorage) e vale per tutte le pagine sulla porta 80. Caricato nel
   <head> per applicarla prima del disegno; senza JavaScript resta lo scuro e
   l'interruttore resta nascosto. */
(function () {
	'use strict';
	var KEY = 'sweetspot-tema';
	var root = document.documentElement;
	var COLORE = { scuro: '#10151d', chiaro: '#f4f6f9' };

	function letto() {
		try { return localStorage.getItem(KEY) === 'chiaro' ? 'chiaro' : 'scuro'; } catch (e) { return 'scuro'; }
	}

	var attuale = letto();

	function applica(tema) {
		attuale = tema;
		if (tema === 'chiaro') root.setAttribute('data-tema', 'chiaro');
		else root.removeAttribute('data-tema');
		var meta = document.querySelector('meta[name="theme-color"]');
		if (meta) meta.setAttribute('content', COLORE[tema]);
		var btn = document.querySelectorAll('[data-tema-switch]');
		for (var i = 0; i < btn.length; i++) {
			btn[i].hidden = false;
			btn[i].textContent = tema === 'chiaro' ? 'Tema scuro' : 'Tema chiaro';
		}
	}

	function cambia() {
		var tema = attuale === 'chiaro' ? 'scuro' : 'chiaro';
		try { localStorage.setItem(KEY, tema); } catch (e) { /* vale solo per questa pagina */ }
		applica(tema);
	}

	applica(attuale);
	document.addEventListener('DOMContentLoaded', function () {
		var btn = document.querySelectorAll('[data-tema-switch]');
		for (var i = 0; i < btn.length; i++) btn[i].addEventListener('click', cambia);
		applica(attuale);
	});
	// Altre schede e riquadri (impostazioni dentro Material) seguono la scelta.
	window.addEventListener('storage', function (e) {
		if (e.key === KEY) applica(letto());
	});
})();
