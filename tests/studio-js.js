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
		createElement: () => el(''),
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
		if (q.indexOf('op=players') >= 0) json = { ok: true, result: { players_loop: opts.players } };
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

	console.log('studio-js: volume per player e esiti OK');
})().catch((e) => { console.error('studio-js FALLITO:', e.message); process.exit(1); });
