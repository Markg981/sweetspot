// SPDX-License-Identifier: GPL-3.0-or-later
// Prova di studio.js senza browser: DOM minimo e fetch simulato. Verifica che
// il volume segua il player scelto (non il modo del solo principale) e che un
// comando fallito non mostri mai "Aggiunto alla coda".
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'board', 'sweetspot', 'rootfs-overlay',
	'usr', 'share', 'sweetspot', 'www', 'studio.js'), 'utf8');

function el(id) {
	const e = {
		id, attrs: {}, children: [], listeners: {}, hidden: false, disabled: false,
		value: '', title: '', textContent: '', src: '', max: 0, style: {},
		setAttribute(k, v) { this.attrs[k] = String(v); },
		getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
		removeAttribute(k) { delete this.attrs[k]; },
		appendChild(c) { this.children.push(c); return c; },
		addEventListener(ev, fn) { this.listeners[ev] = fn; },
		focus() {},
	};
	return e;
}

function all(e, pred, out = []) {
	if (pred(e)) out.push(e);
	for (const c of e.children || []) all(c, pred, out);
	return out;
}
function texts(e) { return all(e, (x) => typeof x.textContent === 'string' && x.textContent).map((x) => x.textContent); }

function findText(e, txt) {
	if (e.textContent === txt && e.listeners && e.listeners.click) return e;
	for (const c of e.children || []) { const r = findText(c, txt); if (r) return r; }
	return null;
}

async function run(opts) {
	const els = {};
	const get = (id) => (els[id] = els[id] || el(id));
	const app = get('st-app');
	app.attrs = { 'data-volume': opts.mode, 'data-volume-testo': 'TESTO-PRINCIPALE', 'data-main-mac': opts.mainMac, 'data-material': '/' };
	const calls = [];
	const doc = {
		getElementById: get,
		querySelector: () => ({ content: 'tok' }),
		querySelectorAll: () => [],
		createElement: (tag) => Object.assign(el(''), { tag }),
		createTextNode: (t) => ({ text: t }),
		addEventListener() {},
		hidden: false,
		activeElement: null,
		title: '',
	};
	const fetchSim = async (url, o) => {
		const post = o && o.method === 'POST';
		const body = o && o.body ? o.body : '';
		calls.push({ url, post, body });
		const q = post ? body : url;
		let status = 200, json;
		const own = opts.route && opts.route(q);
		if (own) { status = own.status || 200; json = own.json; }
		else if (q.indexOf('op=players') >= 0) json = { ok: true, result: { players_loop: opts.players } };
		else if (post && q.indexOf('op=carica') >= 0 && opts.fail) { status = opts.fail; json = { ok: false, errore: 'x', testo: 'Errore ' + opts.fail }; }
		else if (q.indexOf('op=titles') >= 0) json = { ok: true, result: { titles_loop: [{ id: 1, title: 'T', album: 'A' }] } };
		else json = { ok: true, result: { mode: 'stop', 'mixer volume': 50, playlist_loop: [] } };
		const text = JSON.stringify(json);
		return { ok: status < 400, status, text: async () => text };
	};
	const ctx = {
		document: doc, fetch: fetchSim, location: { hash: opts.hash || '#/queue' }, console,
		localStorage: { getItem: () => opts.saved || null, setItem() {} },
		window: { addEventListener() {} }, Promise, JSON, Math, Date, Number, String, Array,
		setInterval: () => 0, setTimeout, clearTimeout, encodeURIComponent, decodeURIComponent,
	};
	ctx.window.document = doc;
	vm.createContext(ctx);
	vm.runInContext(SRC, ctx);
	await new Promise((r) => setTimeout(r, 30));
	return { els, get, calls, ctx };
}

const P = [{ playerid: 'aa:aa:aa:aa:aa:01', name: 'Principale', connected: 1 },
	{ playerid: 'bb:bb:bb:bb:bb:02', name: 'Zona', connected: 1 }];

(async () => {
	// Principale con volume fisso: cursore disattivato, testo del modo.
	let r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01' });
	assert.strictEqual(r.get('st-vol').disabled, true, 'principale fisso: cursore bloccato');
	assert.strictEqual(r.get('st-vol').title, 'TESTO-PRINCIPALE');

	// Zona software con principale fisso: il cursore deve funzionare.
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'bb:bb:bb:bb:bb:02' });
	assert.strictEqual(r.get('st-vol').disabled, false, 'zona: cursore attivo anche con principale fisso');
	assert.notStrictEqual(r.get('st-vol').title, 'TESTO-PRINCIPALE');

	// Cambio player dal selettore: lo stato segue il player scelto.
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01' });
	r.get('st-player').value = 'bb:bb:bb:bb:bb:02';
	r.get('st-player').listeners.change.call(r.get('st-player'));
	await new Promise((x) => setTimeout(x, 30));
	assert.strictEqual(r.get('st-vol').disabled, false, 'dopo il cambio verso la zona il cursore si attiva');
	r.get('st-player').value = 'aa:aa:aa:aa:aa:01';
	r.get('st-player').listeners.change.call(r.get('st-player'));
	await new Promise((x) => setTimeout(x, 30));
	assert.strictEqual(r.get('st-vol').disabled, true, 'di nuovo sul principale il cursore si blocca');

	// Esito negativo: errore 503 e sessione scaduta non diventano successo.
	for (const code of [503, 401]) {
		r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01', hash: '#/album/7', fail: code });
		const btn = findText(r.get('st-main'), 'Aggiungi alla coda');
		assert.ok(btn, 'pulsante Aggiungi alla coda presente');
		btn.listeners.click();
		await new Promise((x) => setTimeout(x, 30));
		const b = r.get('st-banner');
		assert.ok(!/Aggiunto alla coda/.test(b.textContent), 'HTTP ' + code + ': nessun falso successo (banner: ' + b.textContent + ')');
		assert.ok(b.textContent.length > 0 && b.hidden === false, 'HTTP ' + code + ': errore visibile');
	}
	// Esito positivo: il messaggio compare.
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01', hash: '#/album/7' });
	findText(r.get('st-main'), 'Aggiungi alla coda').listeners.click();
	await new Promise((x) => setTimeout(x, 30));
	assert.ok(/Aggiunto alla coda/.test(r.get('st-banner').textContent), 'successo reale mostrato');

	// Ricerca: Lyrion chiude la connessione sulle query con search (502
	// applicativo). Album e artisti si cercano nell'elenco completo, i brani no.
	const ALBUMS = [{ id: 1, album: 'The Wall', artist: 'Pink Floyd' }, { id: 2, album: 'Amami', artist: 'Arisa' },
		{ id: 3, album: 'Thé à la menthe', artist: 'X' }];
	const bad = { status: 502, json: { ok: false, errore: 'applicativo', testo: 'Risposta non valida da Lyrion.' } };
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01', hash: '#/search?q=the',
		route: (q) => {
			if (q.indexOf('search=') >= 0) return bad;
			if (q.indexOf('op=albums') >= 0) return { json: { ok: true, result: { count: 3, albums_loop: ALBUMS } } };
			if (q.indexOf('op=artists') >= 0) return { json: { ok: true, result: { count: 1, artists_loop: [{ id: 9, artist: 'Theo' }] } } };
			return null;
		} });
	await new Promise((x) => setTimeout(x, 50));
	let t = texts(r.get('st-main'));
	assert.ok(t.includes('The Wall') && t.includes('Thé à la menthe'), 'ripiego: album trovati senza accenti (' + t.join('|') + ')');
	assert.ok(!t.includes('Amami'), 'ripiego: album non corrispondenti esclusi');
	assert.ok(t.includes('Theo'), 'ripiego: artisti trovati');
	assert.ok(t.some((x) => /non ha eseguito la ricerca completa/.test(x)), 'ripiego dichiarato');
	assert.ok(!t.includes('Riprova'), 'nessuna schermata di errore');
	assert.ok(!r.calls.some((c) => /op=titles/.test(c.url) && !/search=/.test(c.url)), 'i brani non si leggono tutti');

	// Ricerca funzionante: niente ripiego, link a tutti gli album.
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01', hash: '#/search?q=wall',
		route: (q) => q.indexOf('op=albums') >= 0 ? { json: { ok: true, result: { count: 1, albums_loop: [ALBUMS[0]] } } } : null });
	await new Promise((x) => setTimeout(x, 50));
	t = texts(r.get('st-main'));
	assert.ok(t.includes('The Wall') && t.includes('Tutti gli album trovati'), 'ricerca normale');
	assert.ok(!t.some((x) => /non ha eseguito/.test(x)), 'nessun avviso con la ricerca riuscita');

	// Paginazione: 2276 album a pagine da 48, terza pagina aperta.
	r = await run({ mode: 'fisso', mainMac: 'aa:aa:aa:aa:aa:01', players: P, saved: 'aa:aa:aa:aa:aa:01', hash: '#/albums?p=2',
		route: (q) => q.indexOf('op=albums') >= 0 ? { json: { ok: true, result: { count: 2276, albums_loop: ALBUMS } } } : null });
	await new Promise((x) => setTimeout(x, 50));
	const nav = all(r.get('st-main'), (x) => x.tag === 'nav')[0];
	assert.ok(nav, 'paginazione presente');
	const opts2 = all(nav, (x) => x.tag === 'option');
	assert.strictEqual(opts2.length, 48, '48 pagine nel selettore');
	assert.ok('selected' in opts2[2].attrs && !('selected' in opts2[1].attrs), 'pagina corrente selezionata');
	const hrefs = {};
	all(nav, (x) => x.tag === 'a').forEach((a) => { hrefs[a.textContent] = a.attrs.href; });
	assert.ok(/[?&]p=0(&|$)/.test(hrefs['⏮']), 'prima pagina: ' + hrefs['⏮']);
	assert.ok(/[?&]p=47(&|$)/.test(hrefs['⏭']), 'ultima pagina: ' + hrefs['⏭']);
	assert.ok(/[?&]p=12(&|$)/.test(hrefs['+10']), 'avanti di 10: ' + hrefs['+10']);
	assert.ok(/[?&]p=0(&|$)/.test(hrefs['−10']), 'indietro di 10 si ferma alla prima: ' + hrefs['−10']);
	const sel = all(nav, (x) => x.tag === 'select')[0];
	sel.value = '30';
	sel.listeners.change.call(sel);
	assert.ok(/[?&]p=30(&|$)/.test(r.ctx.location.hash), 'il selettore salta alla pagina: ' + r.ctx.location.hash);

	console.log('studio-js: volume per player, esiti, ricerca e paginazione OK');
})().catch((e) => { console.error('studio-js FALLITO:', e.message); process.exit(1); });
