/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Sweetspot - Reference Studio. Nessuna dipendenza: i dati arrivano da
   /cgi-bin/studio-api.json (Lyrion) e il testo si inserisce sempre con
   textContent, mai come HTML. */
(function () {
	'use strict';
	var API = '/cgi-bin/studio-api.json';
	var PAGE = 48;
	var $ = function (id) { return document.getElementById(id); };
	var app = $('st-app');
	var TOKEN = (document.querySelector('meta[name="sweetspot-token"]') || {}).content || '';
	var VOLMODE = app.getAttribute('data-volume');
	var VOLTXT = app.getAttribute('data-volume-testo') || '';
	var MAINMAC = (app.getAttribute('data-main-mac') || '').toLowerCase();
	var VOLZONE = 'Volume digitale di Lyrion su questo player: sotto il 100% non è bit-perfect.';
	var MATERIAL = app.getAttribute('data-material') || '/';
	var S = { players: [], player: '', st: null, stAt: 0, seeking: false, volTimer: 0, reqId: 0 };

	function h(tag, attrs, kids) {
		var e = document.createElement(tag), k;
		if (attrs) for (k in attrs) {
			if (k === 'text') e.textContent = attrs[k];
			else if (k === 'on') for (var ev in attrs.on) e.addEventListener(ev, attrs.on[ev]);
			else if (attrs[k] !== null && attrs[k] !== undefined && attrs[k] !== false) e.setAttribute(k, attrs[k] === true ? '' : attrs[k]);
		}
		(kids || []).forEach(function (c) { if (c) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
		return e;
	}
	function fmt(sec) {
		sec = Math.max(0, Math.floor(Number(sec) || 0));
		var m = Math.floor(sec / 60), s = sec % 60;
		return m + ':' + (s < 10 ? '0' : '') + s;
	}
	function enc(v) { return encodeURIComponent(v); }

	// --- Banner ed errori ---------------------------------------------------
	var banner = $('st-banner');
	function say(msg, link) {
		if (!msg) { banner.hidden = true; banner.textContent = ''; return; }
		banner.textContent = msg + ' ';
		if (link) banner.appendChild(h('a', { href: link[0], text: link[1] }));
		banner.hidden = false;
	}
	function failure(e) {
		if (e && e.status === 401) { say('La sessione è scaduta.', ['/cgi-bin/accesso', 'Accedi di nuovo']); return; }
		if (e && e.status === 409) { say('Il Reference Studio richiede la modalità completa.', ['/cgi-bin/stato', 'Apri lo stato']); return; }
		if (e && e.testo) { say(e.testo); return; }
		say('Connessione con SweetSpot interrotta. Riprovo automaticamente.');
	}

	// --- API ----------------------------------------------------------------
	function api(params, post) {
		var opt = { credentials: 'same-origin', cache: 'no-store' }, url = API, q = [], k;
		if (post) {
			var b = [];
			for (k in params) b.push(enc(k) + '=' + enc(params[k]));
			opt.method = 'POST';
			opt.headers = { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Sweetspot-Token': TOKEN };
			opt.body = b.join('&');
		} else {
			for (k in params) if (params[k] !== '' && params[k] !== undefined) q.push(enc(k) + '=' + enc(params[k]));
			url += '?' + q.join('&');
		}
		return fetch(url, opt).then(function (r) {
			return r.text().then(function (t) {
				var j = null;
				try { j = JSON.parse(t); } catch (x) { /* risposta non JSON */ }
				if (r.ok && j && j.ok) { say(''); return j.result || {}; }
				var err = (j && j.errore) ? j : { errore: 'http', testo: 'Risposta non valida (' + r.status + ').' };
				err.status = r.status;
				throw err;
			});
		});
	}
	function act(op, extra) {
		var p = { op: op, player: S.player }, k;
		for (k in (extra || {})) p[k] = extra[k];
		// Risolve true solo se il comando e' riuscito: chi chiama non deve
		// mostrare un successo quando la richiesta e' fallita.
		return api(p, true).then(function () { return refreshStatus(); }).then(function () { return true; }, function (e) { failure(e); return false; });
	}
	// Il modo volume configurato vale solo per il player principale (MAC di
	// player.mac); gli altri (zone, app) hanno il volume digitale di Lyrion.
	// Senza MAC noto (player non ancora pronto) si resta prudenti: modo del principale.
	function isMain() { return !!S.player && (!MAINMAC || S.player.toLowerCase() === MAINMAC); }
	function volFixed() { return isMain() && VOLMODE === 'fisso'; }
	function volText() { return isMain() ? VOLTXT : VOLZONE; }

	function cover(id, size, alt) {
		var img = h('img', { alt: alt || '', width: size, height: size, loading: 'lazy' });
		img.src = id ? '/cgi-bin/studio-copertina?id=' + enc(id) + '&s=' + size : '/cgi-bin/studio-copertina?id=0&s=' + size;
		return img;
	}

	// --- Stato del player ----------------------------------------------------
	function cur() {
		var l = S.st && S.st.playlist_loop;
		return (l && l[0]) || null;
	}
	// Nella pagina di un album evidenzia il brano in riproduzione, senza ridisegnare la vista.
	function markNow() {
		var t = cur(), rows = document.querySelectorAll('.st-track[data-id]');
		for (var i = 0; i < rows.length; i++) {
			var on = !!t && rows[i].getAttribute('data-id') === String(t.id);
			rows[i].classList.toggle('on', on);
			if (on) rows[i].setAttribute('aria-current', 'true'); else rows[i].removeAttribute('aria-current');
		}
	}
	function elapsed() {
		if (!S.st) return 0;
		var t = Number(S.st.time) || 0;
		if (S.st.mode === 'play') t += (Date.now() - S.stAt) / 1000;
		var d = Number(S.st.duration) || 0;
		return d ? Math.min(t, d) : t;
	}
	function paintBar() {
		var t = cur(), st = S.st, play = st && st.mode === 'play';
		$('st-bar-title').textContent = t ? (t.title || 'Senza titolo') : (S.player ? 'Nessun brano in coda' : 'Nessun player');
		$('st-bar-sub').textContent = t ? [t.artist, t.album].filter(Boolean).join(' · ') : '';
		var c = $('st-bar-cover');
		c.src = '/cgi-bin/studio-copertina?id=' + enc((t && t.coverid) || 0) + '&s=96';
		var b = $('st-play');
		b.textContent = play ? '\u23F8' : '\u25B6';
		b.setAttribute('aria-label', play ? 'Pausa' : 'Riproduci');
		var d = t ? Number(t.duration || (st && st.duration)) || 0 : 0;
		var sk = $('st-seek');
		sk.max = d || 0; sk.disabled = !d || !S.player;
		if (!S.seeking) { sk.value = elapsed(); $('st-t0').textContent = fmt(elapsed()); }
		$('st-t1').textContent = fmt(d);
		var v = $('st-vol');
		var vol = st && st['mixer volume'] !== undefined ? Number(st['mixer volume']) : 0;
		if (document.activeElement !== v) v.value = Math.max(0, vol);
		$('st-volv').textContent = Math.round(vol) + '%';
		v.disabled = !S.player || volFixed();
		v.title = volText();
		['st-prev', 'st-play', 'st-next'].forEach(function (i) { $(i).disabled = !S.player; });
	}
	function refreshStatus() {
		if (!S.player) { S.st = null; paintBar(); return Promise.resolve(); }
		var id = ++S.reqId;
		return api({ op: 'stato', player: S.player }).then(function (r) {
			if (id !== S.reqId) return;
			var before = cur() && cur().id + '/' + S.st.mode, was = !!S.st;
			S.st = r; S.stAt = Date.now(); paintBar(); markNow();
			// La vista si ridisegna solo se cambia il brano o il modo.
			if ((view === 'home' || view === 'audio') && (!was || before !== (cur() && cur().id + '/' + r.mode))) render();
		}).catch(function (e) { failure(e); });
	}

	// --- Player ----------------------------------------------------------------
	function loadPlayers() {
		return api({ op: 'players' }).then(function (r) {
			S.players = r.players_loop || [];
			var sel = $('st-player'), saved = '';
			try { saved = localStorage.getItem('sweetspot.studio.player') || ''; } catch (x) { /* senza archivio */ }
			var ok = S.players.some(function (p) { return p.playerid === saved; });
			if (ok) S.player = saved;
			else {
				var c = S.players.filter(function (p) { return Number(p.connected) === 1; })[0] || S.players[0];
				S.player = c ? c.playerid : '';
			}
			sel.textContent = '';
			S.players.forEach(function (p) {
				sel.appendChild(h('option', { value: p.playerid, text: p.name || p.playerid, selected: p.playerid === S.player }));
			});
			sel.disabled = !S.players.length;
		});
	}
	function pickPlayer(id) {
		S.player = id; S.st = null;
		try { localStorage.setItem('sweetspot.studio.player', id); } catch (x) { /* senza archivio */ }
		var sel = $('st-player'); if (sel.value !== id) sel.value = id;
		paintBar();
		return refreshStatus().then(function () { if (view !== 'home') render(); });
	}
	function needPlayer() {
		if (S.player) return false;
		say('Nessun player collegato a Lyrion: accendi il player SweetSpot e riprova.');
		return true;
	}

	// --- Viste -------------------------------------------------------------------
	var view = '', main = $('st-main');
	function route() {
		var hs = location.hash.replace(/^#\/?/, ''), qi = hs.indexOf('?'), p = {}, path = qi < 0 ? hs : hs.slice(0, qi);
		if (qi >= 0) hs.slice(qi + 1).split('&').forEach(function (kv) {
			var i = kv.indexOf('='); if (i > 0) p[decodeURIComponent(kv.slice(0, i))] = decodeURIComponent(kv.slice(i + 1).replace(/\+/g, ' '));
		});
		var parts = path.split('/');
		return { v: parts[0] || 'home', id: parts[1] || '', p: p };
	}
	function link(v, p) {
		var q = [], k;
		for (k in (p || {})) if (p[k] !== '' && p[k] !== undefined) q.push(enc(k) + '=' + enc(p[k]));
		return '#/' + v + (q.length ? '?' + q.join('&') : '');
	}
	function albumHref(id, name) { return '#/album/' + enc(id) + '?n=' + enc(name || ''); }
	function setMain(kids, title) {
		main.textContent = '';
		kids.forEach(function (k) { if (k) main.appendChild(k); });
		document.title = (title ? title + ' - ' : '') + 'Ascolta - SweetSpot';
	}
	function empty(msg, hint) {
		return h('div', { class: 'st-vuoto' }, [h('p', { text: msg }), hint ? h('p', { class: 'st-hint', text: hint }) : null]);
	}
	function loading() { setMain([h('p', { class: 'st-vuoto', text: 'Caricamento…' })]); }
	function retry(e) {
		failure(e);
		setMain([h('div', { class: 'st-vuoto' }, [
			h('p', { text: (e && e.testo) || 'Non riesco a leggere i dati da Lyrion.' }),
			h('button', { type: 'button', text: 'Riprova', on: { click: render } })])]);
	}

	// Con molte pagine si salta: prima e ultima, dieci pagine alla volta e un
	// selettore per andare direttamente a una pagina.
	function pager(p, n, total, v) {
		var pg = Number(p.p) || 0, last = Math.max(0, Math.ceil(total / n) - 1), opts = [], i;
		if (total <= n) return null;
		function page(i) {
			var q = {}, k;
			for (k in p) q[k] = p[k];
			q.p = i;
			return link(v, q);
		}
		function to(i, text, label) {
			i = Math.max(0, Math.min(last, i));
			return i !== pg ? h('a', { href: page(i), text: text, 'aria-label': label || null })
				: h('span', { text: text, 'aria-label': label || null, 'aria-disabled': 'true' });
		}
		for (i = 0; i <= last; i++) opts.push(h('option', { value: i, text: 'Pagina ' + (i + 1) + ' di ' + (last + 1), selected: i === pg }));
		var sel = h('select', { class: 'mono', 'aria-label': 'Vai alla pagina', on: { change: function () { location.hash = page(Number(this.value) || 0); } } }, opts);
		var far = last >= 10;
		return h('nav', { class: 'st-pager', 'aria-label': 'Pagine' }, [
			to(0, '⏮', 'Prima pagina'),
			far ? to(pg - 10, '−10', 'Indietro di 10 pagine') : null,
			to(pg - 1, '← Precedenti'),
			sel,
			to(pg + 1, 'Successivi →'),
			far ? to(pg + 10, '+10', 'Avanti di 10 pagine') : null,
			to(last, '⏭', 'Ultima pagina'),
			h('span', { class: 'mono st-tot', text: total + ' in tutto' })
		]);
	}

	function albumCard(a) {
		return h('li', { class: 'st-card' }, [
			h('a', { href: albumHref(a.id, a.album) }, [
				cover(a.artwork_track_id, 200, ''),
				h('strong', { text: a.album || 'Senza titolo' }),
				h('span', { text: [a.artist, a.year && a.year !== '0' ? a.year : ''].filter(Boolean).join(' · ') })
			]),
			h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Riproduci ' + (a.album || 'album'), text: '\u25B6', on: { click: function () { load('album', a.id, 'load'); } } })
		]);
	}
	function load(kind, id, mode, msg) {
		if (needPlayer()) return;
		act('carica', { kind: kind, id: id, mode: mode }).then(function (ok) {
			if (!ok) return;
			if (mode !== 'load') say(msg || 'Aggiunto alla coda.');
			else say('');
		});
	}

	var SORTS = [['album', 'Titolo'], ['new', 'Aggiunti di recente'], ['artflow', 'Artista'], ['random', 'Casuale']];
	function vAlbums(r) {
		var p = r.p, q = { op: 'albums', start: (Number(p.p) || 0) * PAGE, count: PAGE, sort: p.sort || 'album', search: p.q, genre_id: p.genre, artist_id: p.artist };
		loading();
		Promise.all([api(q), api({ op: 'genres', count: 100 })]).then(function (res) {
			var list = res[0].albums_loop || [], genres = res[1].genres_loop || [], total = Number(res[0].count) || list.length;
			var kids = [h('h1', { text: p.n || (p.q ? 'Album per “' + p.q + '”' : 'Album') })];
			var sel = h('select', { id: 'st-sort', 'aria-label': 'Ordina per', on: { change: function () { p.sort = this.value; p.p = 0; location.hash = link('albums', p); } } },
				SORTS.map(function (s) { return h('option', { value: s[0], text: s[1], selected: (p.sort || 'album') === s[0] }); }));
			var chips = h('div', { class: 'st-chips', role: 'group', 'aria-label': 'Filtra per genere' }, [
				h('a', { href: link('albums', { sort: p.sort, q: p.q, artist: p.artist, n: p.n }), class: 'st-chip', 'aria-pressed': !p.genre ? 'true' : 'false', text: 'Tutti' })
			].concat(genres.slice(0, 40).map(function (g) {
				return h('a', { href: link('albums', { sort: p.sort, q: p.q, artist: p.artist, n: p.n, genre: g.id }), class: 'st-chip', 'aria-pressed': String(p.genre) === String(g.id) ? 'true' : 'false', text: g.genre });
			})));
			kids.push(h('div', { class: 'st-tools' }, [h('label', { for: 'st-sort', text: 'Ordina' }), sel]), chips);
			if (!list.length) kids.push(empty(p.q || p.genre || p.artist ? 'Nessun album corrisponde alla ricerca.' : 'La libreria non contiene ancora album.',
				p.q || p.genre || p.artist ? 'Prova a togliere un filtro.' : 'Aggiungi una sorgente e avvia la scansione dalle impostazioni.'));
			else kids.push(h('ul', { class: 'st-grid' }, list.map(albumCard)));
			kids.push(pager(p, PAGE, total, 'albums'));
			setMain(kids, 'Album');
		}).catch(retry);
	}

	function vArtists(r) {
		var p = r.p;
		loading();
		api({ op: 'artists', start: (Number(p.p) || 0) * PAGE, count: PAGE, search: p.q }).then(function (res) {
			var list = res.artists_loop || [], total = Number(res.count) || list.length;
			var kids = [h('h1', { text: p.q ? 'Artisti per “' + p.q + '”' : 'Artisti' })];
			if (!list.length) kids.push(empty('Nessun artista trovato.', p.q ? 'Prova con un altro testo.' : 'La libreria è vuota o ancora in scansione.'));
			else kids.push(h('ul', { class: 'st-list' }, list.map(function (a) {
				return h('li', {}, [h('a', { href: link('albums', { artist: a.id, n: a.artist }), text: a.artist || 'Sconosciuto' })]);
			})));
			kids.push(pager(p, PAGE, total, 'artists'));
			setMain(kids, 'Artisti');
		}).catch(retry);
	}

	function trackRow(t, n) {
		var cols = [h('span', { class: 'mono st-n', text: n }), h('span', { class: 'st-t' }, [h('strong', { text: t.title || 'Senza titolo' }), h('small', { text: [t.artist, t.album].filter(Boolean).join(' · ') })]),
			h('span', { class: 'mono', text: fmt(t.duration) })];
		return h('li', { class: 'st-track', 'data-id': t.id }, cols.concat([
			h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Riproduci ' + (t.title || ''), text: '\u25B6', on: { click: function () { load('track', t.id, 'load'); } } }),
			h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Aggiungi alla coda ' + (t.title || ''), text: '+', on: { click: function () { load('track', t.id, 'add'); } } })]));
	}
	function vAlbum(r) {
		loading();
		api({ op: 'titles', album_id: r.id, count: 200 }).then(function (res) {
			var list = res.titles_loop || [], t0 = list[0] || {};
			var kids = [h('a', { href: '#/albums', class: 'st-back', text: '← Album' }),
				h('div', { class: 'st-hero' }, [cover(t0.coverid, 300, ''),
					h('div', {}, [h('h1', { text: t0.album || r.p.n || 'Album' }), h('p', { text: [t0.albumartist || t0.artist, t0.year && t0.year !== '0' ? t0.year : ''].filter(Boolean).join(' · ') }),
						h('div', { class: 'st-actions' }, [
							h('button', { type: 'button', class: 'st-primary', text: 'Riproduci', on: { click: function () { load('album', r.id, 'load'); } } }),
							h('button', { type: 'button', text: 'Aggiungi alla coda', on: { click: function () { load('album', r.id, 'add'); } } }),
							h('button', { type: 'button', text: 'Suona dopo', on: { click: function () { load('album', r.id, 'insert', 'Suonerà dopo il brano in corso.'); } } })])])])];
			if (!list.length) kids.push(empty('L’album non ha brani leggibili.'));
			else kids.push(h('ol', { class: 'st-tracks' }, list.map(function (t, i) { return trackRow(t, t.tracknum || i + 1); })));
			setMain(kids, t0.album || 'Album');
			markNow();
		}).catch(retry);
	}

	function vPlaylists(r) {
		var p = r.p;
		loading();
		api({ op: 'playlists', start: (Number(p.p) || 0) * PAGE, count: PAGE }).then(function (res) {
			var list = res.playlists_loop || [], total = Number(res.count) || list.length;
			var kids = [h('h1', { text: 'Playlist' })];
			if (!list.length) kids.push(empty('Non ci sono playlist salvate.', "Si creano dall'interfaccia Lyrion o dalla coda di un player."));
			else kids.push(h('ul', { class: 'st-list' }, list.map(function (pl) {
				return h('li', {}, [h('span', { text: pl.playlist || 'Senza nome' }),
					h('button', { type: 'button', text: 'Riproduci', on: { click: function () { load('playlist', pl.id, 'load'); } } }),
					h('button', { type: 'button', text: 'Aggiungi', on: { click: function () { load('playlist', pl.id, 'add'); } } })]);
			})));
			kids.push(pager(p, PAGE, total, 'playlists'));
			setMain(kids, 'Playlist');
		}).catch(retry);
	}

	// Cartelle: i dischi della libreria come in Esplora risorse, in sola lettura
	// (Lyrion legge le cartelle, non scrive sui dischi). Lyrion non da' la
	// cartella superiore: il percorso fatto finora viaggia nell'indirizzo (t).
	var FOLDER_PAGE = 200;
	function vFolders(r) {
		var p = r.p, trail = [];
		try { trail = JSON.parse(p.t || '[]'); } catch (x) { trail = []; }
		if (!Array.isArray(trail)) trail = [];
		function href(id, t) { return link('folders/' + enc(id), { t: JSON.stringify(t) }); }
		loading();
		api({ op: 'cartella', folder_id: r.id, start: (Number(p.p) || 0) * FOLDER_PAGE, count: FOLDER_PAGE }).then(function (res) {
			var list = res.folder_loop || [], total = Number(res.count) || list.length, here = trail[trail.length - 1];
			var dirs = list.filter(function (x) { return x.type === 'folder'; });
			var tracks = list.filter(function (x) { return x.type === 'track'; });
			var crumbs = [h('a', { href: '#/folders', text: 'Cartelle' })];
			trail.forEach(function (c, i) {
				crumbs.push(' / ', i < trail.length - 1 ? h('a', { href: href(c[0], trail.slice(0, i + 1)), text: c[1] }) : h('span', { text: c[1] }));
			});
			var kids = [h('nav', { class: 'st-back', 'aria-label': 'Percorso' }, crumbs),
				h('h1', { text: here ? here[1] : 'Cartelle' })];
			if (r.id) kids.push(h('div', { class: 'st-actions' }, [
				h('button', { type: 'button', class: 'st-primary', text: 'Riproduci la cartella', on: { click: function () { load('folder', r.id, 'load'); } } }),
				h('button', { type: 'button', text: 'Aggiungi alla coda', on: { click: function () { load('folder', r.id, 'add'); } } })]));
			else kids.push(h('p', { class: 'st-hint', text: 'I dischi e le cartelle della libreria, in sola lettura. ▶ su un disco o una cartella suona tutto quello che contiene, sottocartelle comprese.' }));
			if (!dirs.length && !tracks.length) kids.push(empty(r.id ? 'In questa cartella non ci sono brani.' : 'Nessun disco nella libreria.',
				r.id ? '' : 'Collega un disco USB o aggiungi una cartella di rete dalle impostazioni.'));
			if (dirs.length) kids.push(h('ul', { class: 'st-list' }, dirs.map(function (d) {
				var name = d.filename || 'Senza nome';
				return h('li', {}, [h('a', { href: href(d.id, trail.concat([[d.id, name]])), text: '📁 ' + name }),
					h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Riproduci la cartella ' + name, text: '▶', on: { click: function () { load('folder', d.id, 'load'); } } }),
					h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Aggiungi alla coda la cartella ' + name, text: '+', on: { click: function () { load('folder', d.id, 'add'); } } })]);
			})));
			if (tracks.length) kids.push(h('ol', { class: 'st-tracks' }, tracks.map(function (t, i) {
				var name = t.filename || 'Senza nome';
				return h('li', { class: 'st-track', 'data-id': t.id }, [
					h('span', { class: 'mono st-n', text: i + 1 }), h('span', { class: 'st-t' }, [h('strong', { text: name })]),
					h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Riproduci ' + name, text: '▶', on: { click: function () { load('track', t.id, 'load'); } } }),
					h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Aggiungi alla coda ' + name, text: '+', on: { click: function () { load('track', t.id, 'add'); } } })]);
			})));
			kids.push(pager(p, FOLDER_PAGE, total, 'folders' + (r.id ? '/' + enc(r.id) : '')));
			setMain(kids, here ? here[1] : 'Cartelle');
			markNow();
		}).catch(retry);
	}

	// Testo per il confronto: minuscole e senza accenti ("è" trova "e").
	function norm(s) {
		s = String(s || '').toLowerCase();
		return s.normalize ? s.normalize('NFD').replace(/[̀-ͯ]/g, '') : s;
	}
	// Ripiego quando Lyrion non esegue la ricerca (chiude la connessione senza
	// risposta, per esempio con l'indice di ricerca assente o rovinato): si legge
	// l'elenco completo a blocchi e si filtra qui, fino a max risultati.
	function filterAll(op, loop, fields, q, max) {
		var words = norm(q).split(/\s+/).filter(Boolean), found = [], BLOCK = 500;
		function step(start) {
			return api({ op: op, start: start, count: BLOCK, sort: op === 'albums' ? 'album' : undefined }).then(function (r) {
				var list = r[loop] || [], total = Number(r.count) || 0;
				list.forEach(function (x) {
					var t = norm(fields.map(function (f) { return x[f]; }).join(' '));
					if (found.length < max && words.every(function (w) { return t.indexOf(w) >= 0; })) found.push(x);
				});
				return found.length < max && list.length && start + BLOCK < total ? step(start + BLOCK) : found;
			});
		}
		return step(0);
	}
	// Le tre ricerche partono una dopo l'altra (Lyrion le esegue comunque in
	// sequenza) e una che fallisce non nasconde i risultati delle altre.
	var searchId = 0;
	function vSearch(r) {
		var q = r.p.q || '', id = ++searchId, res = {}, errs = [], simple = false;
		var steps = [
			['al', { op: 'albums', search: q, count: 12, sort: 'album' }, 'albums_loop', ['album', 'artist']],
			['ar', { op: 'artists', search: q, count: 12 }, 'artists_loop', ['artist']],
			['ti', { op: 'titles', search: q, count: 20 }, 'titles_loop', null]];
		loading();
		steps.reduce(function (pr, s) {
			return pr.then(function () {
				return api(s[1]).then(function (x) { res[s[0]] = x[s[2]] || []; }, function (e) {
					if (!s[3] || (e && (e.status === 401 || e.status === 409))) { errs.push(e); return; }
					return filterAll(s[1].op, s[2], s[3], q, s[1].count).then(function (x) { res[s[0]] = x; simple = true; }, function (e2) { errs.push(e2); });
				});
			});
		}, Promise.resolve()).then(function () {
			if (id !== searchId || route().v !== 'search') return;
			var al = res.al || [], ar = res.ar || [], ti = res.ti || [];
			if (errs.length === steps.length) { retry(errs[0]); return; }
			var kids = [h('h1', { text: 'Risultati per “' + q + '”' })];
			if (simple || errs.length) kids.push(h('p', { class: 'st-hint', text: 'Lyrion non ha eseguito la ricerca completa: ' + (simple ? 'album e artisti sono cercati solo nei titoli e nei nomi' : 'alcuni risultati mancano') + (res.ti ? '.' : ', i brani non sono disponibili.') }));
			errs.forEach(function (e) { if (e && (e.status === 401 || e.status === 409)) failure(e); });
			if (!al.length && !ar.length && !ti.length) { kids.push(empty('Nessun risultato.', 'Controlla l’ortografia o prova una parola più corta.')); setMain(kids, 'Ricerca'); return; }
			if (al.length) kids.push(h('h2', { text: 'Album' }), h('ul', { class: 'st-grid' }, al.map(albumCard)), simple ? null : h('p', {}, [h('a', { href: link('albums', { q: q }), text: 'Tutti gli album trovati' })]));
			if (ar.length) kids.push(h('h2', { text: 'Artisti' }), h('ul', { class: 'st-list' }, ar.map(function (a) { return h('li', {}, [h('a', { href: link('albums', { artist: a.id, n: a.artist }), text: a.artist })]); })));
			if (ti.length) kids.push(h('h2', { text: 'Brani' }), h('ol', { class: 'st-tracks' }, ti.map(function (t, i) { return trackRow(t, i + 1); })));
			setMain(kids, 'Ricerca');
		});
	}

	function techLine(t) {
		var o = [];
		if (!t) return o;
		if (t.type) o.push(['Formato', String(t.type).toUpperCase()]);
		if (t.samplerate) o.push(['Frequenza', (Number(t.samplerate) / 1000) + ' kHz']);
		if (t.samplesize) o.push(['Profondità', t.samplesize + ' bit']);
		if (t.bitrate) o.push(['Bitrate', t.bitrate]);
		return o;
	}
	function vHome() {
		var t = cur(), kids = [];
		if (!S.player) kids.push(empty('Nessun player collegato a Lyrion.', 'Accendi il player SweetSpot: apparirà qui.'));
		else if (!t) kids.push(empty('Nessun brano in riproduzione.', 'Scegli un album qui sotto per iniziare.'));
		else {
			var tl = techLine(t);
			kids.push(h('div', { class: 'st-hero st-now' }, [cover(t.coverid, 400, ''),
				h('div', {}, [h('p', { class: 'st-eyebrow', text: S.st && S.st.mode === 'play' ? 'In ascolto' : 'In pausa' }), h('h1', { text: t.title || 'Senza titolo' }),
					h('p', { text: [t.artist, t.album].filter(Boolean).join(' · ') }),
					tl.length ? h('dl', { class: 'st-tech mono' }, tl.reduce(function (a, x) { return a.concat([h('dt', { text: x[0] }), h('dd', { text: x[1] })]); }, [])) : null,
					h('p', { class: 'st-actions' }, [t.album_id ? h('a', { href: albumHref(t.album_id, t.album), text: 'Vedi tutto l’album' }) : null,
						h('a', { href: '#/audio', text: 'Vedi il percorso audio' })])])]));
		}
		setMain(kids, 'Ascolta');
		var box = h('section', { 'aria-labelledby': 'st-new' }, [h('h2', { id: 'st-new', text: 'Aggiunti di recente' }), h('p', { class: 'st-vuoto', text: 'Caricamento…' })]);
		main.appendChild(box);
		api({ op: 'albums', count: 12, sort: 'new' }).then(function (res) {
			var list = res.albums_loop || [];
			box.removeChild(box.lastChild);
			box.appendChild(list.length ? h('ul', { class: 'st-grid' }, list.map(albumCard)) : empty('La libreria è vuota.', 'Aggiungi una sorgente e avvia la scansione dalle impostazioni.'));
			box.appendChild(h('p', {}, [h('a', { href: '#/albums', text: 'Sfoglia tutti gli album' })]));
		}).catch(function (e) { box.removeChild(box.lastChild); box.appendChild(h('p', { class: 'st-vuoto', text: (e && e.testo) || 'Libreria non disponibile.' })); failure(e); });
	}

	function vQueue(r) {
		if (!S.player) { setMain([h('h1', { text: 'Coda' }), empty('Nessun player collegato a Lyrion.')], 'Coda'); return; }
		var start = (Number(r.p.p) || 0) * PAGE;
		loading();
		api({ op: 'coda', player: S.player, start: start, count: PAGE }).then(function (res) {
			var list = res.playlist_loop || [], total = Number(res.playlist_tracks) || list.length, now = Number(res.playlist_cur_index);
			var kids = [h('h1', { text: 'Coda' })];
			if (!list.length) kids.push(empty('La coda è vuota.', 'Scegli un album o una playlist per riprodurli.'));
			else {
				kids.push(h('div', { class: 'st-actions' }, [h('button', { type: 'button', text: 'Svuota la coda', on: { click: function () { act('svuota').then(render); } } })]));
				kids.push(h('ol', { class: 'st-tracks', start: start + 1 }, list.map(function (t, i) {
					var idx = start + i, on = idx === now;
					return h('li', { class: 'st-track' + (on ? ' on' : ''), 'aria-current': on ? 'true' : null }, [
						h('span', { class: 'mono st-n', text: idx + 1 }),
						h('span', { class: 'st-t' }, [h('strong', { text: t.title || 'Senza titolo' }), h('small', {}, [t.artist, t.artist && t.album ? ' · ' : '',
							t.album && t.album_id ? h('a', { href: albumHref(t.album_id, t.album), text: t.album }) : t.album])]),
						h('span', { class: 'mono', text: fmt(t.duration) }),
						h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Suona ' + (t.title || ''), text: '\u25B6', on: { click: function () { act('salta', { v: idx }); } } }),
						h('button', { type: 'button', class: 'st-mini', 'aria-label': 'Togli ' + (t.title || ''), text: '×', on: { click: function () { act('togli', { v: idx }).then(render); } } })]);
				})));
				kids.push(pager(r.p, PAGE, total, 'queue'));
			}
			setMain(kids, 'Coda');
		}).catch(retry);
	}

	function vPlayers() {
		loading();
		loadPlayers().then(function () {
			var kids = [h('h1', { text: 'Zone e player' })];
			if (!S.players.length) { kids.push(empty('Nessun player collegato a Lyrion.', 'Accendi il player SweetSpot: apparirà qui.')); setMain(kids, 'Zone'); return; }
			kids.push(h('ul', { class: 'st-list' }, S.players.map(function (p) {
				var others = S.players.filter(function (o) { return o.playerid !== p.playerid && Number(o.connected) === 1; });
				var sel = h('select', { 'aria-label': 'Sincronizza ' + (p.name || p.playerid) + ' con' }, [h('option', { value: '', text: 'Sincronizza con…' })].concat(others.map(function (o) { return h('option', { value: o.playerid, text: o.name || o.playerid }); })));
				return h('li', {}, [h('span', { class: 'st-t' }, [h('strong', { text: p.name || p.playerid }), h('small', { class: 'mono', text: [p.model, Number(p.connected) === 1 ? 'connesso' : 'non connesso', Number(p.isplaying) === 1 ? 'in riproduzione' : ''].filter(Boolean).join(' · ') })]),
					h('button', { type: 'button', text: p.playerid === S.player ? 'In uso' : 'Controlla', 'aria-pressed': p.playerid === S.player ? 'true' : 'false', on: { click: function () { pickPlayer(p.playerid); } } }),
					others.length ? sel : null,
					others.length ? h('button', { type: 'button', text: 'Sincronizza', on: { click: function () { if (!sel.value) return; api({ op: 'zona', player: p.playerid, to: sel.value }, true).then(vPlayers).catch(failure); } } }) : null,
					h('button', { type: 'button', text: 'Separa', on: { click: function () { api({ op: 'zona', player: p.playerid, to: '-' }, true).then(vPlayers).catch(failure); } } })]);
			})));
			setMain(kids, 'Zone');
		}).catch(retry);
	}

	function vAudio() {
		var t = cur(), tl = techLine(t);
		var kids = [h('h1', { text: 'Percorso audio' })];
		kids.push(h('p', { class: 'st-hint', text: 'Dati reali del brano in ascolto e del volume configurato. Il percorso completo (DAC, DSP, filtri, uscita) è nella pagina Audio.' }));
		kids.push(h('dl', { class: 'st-tech mono' }, [h('dt', { text: 'Brano' }), h('dd', { text: t ? (t.title || 'Senza titolo') : 'nessuno in riproduzione' })]
			.concat(tl.reduce(function (a, x) { return a.concat([h('dt', { text: x[0] }), h('dd', { text: x[1] })]); }, []))
			.concat([h('dt', { text: 'Volume' }), h('dd', { text: volText() })])));
		kids.push(h('p', {}, [h('a', { class: 'st-primary', href: '/cgi-bin/audio', target: '_top', text: 'Apri il percorso audio completo' })]));
		setMain(kids, 'Percorso audio');
	}

	var cur_route = null;
	function render() {
		var r = cur_route = route();
		view = r.v;
		var links = document.querySelectorAll('.st-nav a[data-v]');
		for (var i = 0; i < links.length; i++) {
			if (links[i].getAttribute('data-v') === (r.v === 'album' || r.v === 'search' ? 'albums' : r.v)) links[i].setAttribute('aria-current', 'page');
			else links[i].removeAttribute('aria-current');
		}
		switch (r.v) {
			case 'albums': return vAlbums(r);
			case 'album': return vAlbum(r);
			case 'artists': return vArtists(r);
			case 'playlists': return vPlaylists(r);
			case 'folders': return vFolders(r);
			case 'search': return vSearch(r);
			case 'queue': return vQueue(r);
			case 'players': return vPlayers(r);
			case 'audio': return vAudio(r);
			default: view = 'home'; return vHome(r);
		}
	}

	// --- Comandi della barra ---------------------------------------------------------
	$('st-play').addEventListener('click', function () {
		if (needPlayer()) return;
		if (!cur()) { say('La coda è vuota: scegli prima un album.'); return; }
		var playing = S.st && S.st.mode === 'play';
		act(playing ? 'pausa' : 'play', playing ? { v: 1 } : {});
	});
	$('st-next').addEventListener('click', function () { if (!needPlayer()) act('avanti'); });
	$('st-prev').addEventListener('click', function () { if (!needPlayer()) act('indietro'); });
	var sk = $('st-seek');
	sk.addEventListener('input', function () { S.seeking = true; $('st-t0').textContent = fmt(sk.value); });
	sk.addEventListener('change', function () { S.seeking = false; act('seek', { v: Math.floor(sk.value) }); });
	var vr = $('st-vol');
	vr.addEventListener('input', function () {
		$('st-volv').textContent = vr.value + '%';
		clearTimeout(S.volTimer);
		S.volTimer = setTimeout(function () { api({ op: 'volume', player: S.player, v: vr.value }, true).catch(failure); }, 150);
	});
	$('st-player').addEventListener('change', function () { pickPlayer(this.value); });
	$('st-search').addEventListener('submit', function (ev) {
		ev.preventDefault();
		var q = $('st-q').value.trim();
		if (q) location.hash = link('search', { q: q });
	});
	window.addEventListener('hashchange', function () { render(); main.focus(); });

	// Lo stato si rilegge ogni 5 secondi a scheda visibile; fra una lettura e
	// l'altra il tempo avanza solo nella pagina, senza altre richieste.
	setInterval(function () { if (!document.hidden && S.player && !S.seeking) { var sk2 = $('st-seek'); if (!sk2.disabled || S.st) { sk2.value = elapsed(); $('st-t0').textContent = fmt(elapsed()); } } }, 1000);
	setInterval(function () { if (!document.hidden && !S.seeking) refreshStatus(); }, 5000);
	document.addEventListener('visibilitychange', function () { if (!document.hidden) refreshStatus(); });

	loadPlayers().then(function () { paintBar(); return refreshStatus(); }).catch(failure).then(render);
}());
