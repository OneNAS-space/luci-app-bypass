/* Bypass status page. Backend: bypass.uc (ubus luci.bypass).
 * LuCI's E() takes a lone string child as HTML: router-provided text goes in an array or textContent. */
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const callStatus = rpc.declare({ object: 'luci.bypass', method: 'status' });
const callData = rpc.declare({ object: 'luci.bypass', method: 'data' });
const callSetBypass = rpc.declare({ object: 'luci.bypass', method: 'set_bypass', params: [ 'set' ] });
const callSetNatmap = rpc.declare({ object: 'luci.bypass', method: 'set_natmap', params: [ 'set' ] });

const POLL_INTERVAL = 1;

const RULES_TABLE_MIN = 661;
const CLIENTS_TABLE_MIN = 661;

function wideCss(sel) {
	return sel + ' { display:table !important; width:100% !important; }' +
		sel + ' .tr { display:table-row !important; }' +
		sel + ' .tr.cbi-section-table-titles { display:table-row !important; }' +
		sel + ' .th, ' + sel + ' .td { display:table-cell !important; position:static !important; float:none !important; width:auto; max-width:none !important; height:auto !important; padding:.6rem .5rem !important; text-align:center !important; vertical-align:middle !important; white-space:nowrap; }' +
		sel + ' .td::before, ' + sel + ' .td::after { content:none !important; }';
}

function narrowCss(sel) {
	return sel + ' .tr.cbi-section-table-titles { display:none !important; }' +
		sel + ' .tr.cbi-section-table-row { display:grid !important; align-items:baseline; gap:.2rem 1rem; padding:.6rem 1rem !important; margin:0 !important; height:auto !important; min-height:0 !important; flex:none !important; border-top:1px solid rgba(128,128,128,.15); }' +
		sel + ' .tr.cbi-section-table-row .td { display:block !important; position:static !important; float:none !important; flex:none !important; width:auto !important; max-width:none !important; min-width:0 !important; height:auto !important; min-height:0 !important; margin:0 !important; padding:0 !important; border:0 !important; transform:none !important; text-align:left !important; white-space:normal; line-height:1.4; }' +
		sel + ' .td::after, ' + sel + ' .td::before { content:none !important; }';
}

const CSS =
	'.pg-label { display:inline-block; padding:2px 6px; border-radius:3px; color:#fff; font-weight:bold; font-size:0.85em; }' +
	'.pg-speed { color:#0069d6; font-size:0.8em; font-weight:bold; margin-left:4px; }' +
	'.pg-tbl { font-variant-numeric:tabular-nums; }' +
	'.pg-pk, .pg-by, .pg-speed { display:inline-block; text-align:inherit; vertical-align:baseline; white-space:nowrap; }' +
	'.pg-pk { min-width:8ch; }' +
	'.pg-by { min-width:9ch; }' +
	'.pg-speed { min-width:7.5em; text-align:left; }' +
	'.pg-sp-inline { display:none; }' +
	'.pg-rsp .pg-speed { text-align:center; margin-left:0; }' +
	'.pg-ip6 { font-size:0.85em; }' +
	'.pg-wrap { container-type:inline-size; }' +
	'.pg-tbl .td.pg-tag .pg-label { margin:0 4px 2px 0; }' +
	'.pg-speed { white-space:nowrap; }' +
	'.pg-clients .pg-ip, .pg-clients .pg-mac { display:block; }' +
	'.pg-clients .pg-mac { font-size:.85em; opacity:.8; }' +
	'.pg-clients .pg-offline { color:#d9534f; font-weight:bold; }' +
	'.pg-clients .pg-cn, .pg-clients .pg-cs { display:inline-block; white-space:nowrap; text-align:center; }' +
	'.pg-clients .pg-arr { font-size:.7em; margin-right:.3em; vertical-align:.08em; }' +
	'.pg-clients .pg-cn { min-width:10.5ch; }' +
	'.pg-clients .pg-cs { min-width:12ch; font-size:.85em; font-weight:bold; }' +
	'.pg-clients .pg-cs-dn { color:blue; }' +
	'.pg-clients .pg-cs-up { color:green; }' +
	'.pg-clients .pg-trafbox { display:inline-grid; grid-template-columns:auto auto; align-items:baseline; column-gap:.7em; row-gap:.05rem; text-align:center; }' +
	'.pg-clients .pg-sort { cursor:pointer; user-select:none; }' +
	'.pg-clients .pg-sort:hover, .pg-clients .pg-sort:focus-visible { background:rgba(128,128,128,.12); outline:none; }' +
	'.pg-clients .pg-sortind { display:inline-block; margin-left:.35em; font-size:.7em; opacity:.7; vertical-align:middle; }' +
	'.pg-clients .pg-sortind:empty { display:none; }' +
	'.pg-tbl, .pg-tbl .tr.cbi-section-table-titles, .pg-tbl .tr:first-child, .pg-tbl .tr:first-child > .th, .pg-tbl .th { border-top-left-radius:0 !important; border-top-right-radius:0 !important; }' +
	'.pg-clients .th.pg-split { padding:0 !important; }' +
	'.pg-clients .pg-sort-half { display:inline-block; padding:.6rem .5rem; }' +
	'.pg-rules .tr.pg-total .td { font-weight:bold; }' +
	'@container (min-width: ' + RULES_TABLE_MIN + 'px) {' +
	wideCss('.pg-rules') +
	'  .pg-rules .td.pg-ract { white-space:normal; }' +
	'}' +
	'@container (min-width: ' + CLIENTS_TABLE_MIN + 'px) {' +
	wideCss('.pg-clients') +
	'  .pg-clients .td.pg-host, .pg-clients .td.pg-tag { white-space:normal; }' +
	'  .pg-clients .td.pg-host { overflow-wrap:anywhere; }' +
	'  .pg-clients .td.pg-type, .pg-clients .td.pg-traf { width:1%; }' +
	'}' +
	'@container (max-width: ' + (RULES_TABLE_MIN - 1) + 'px) {' +
	narrowCss('.pg-rules') +
	'  .pg-rules .td.pg-rpk::before, .pg-rules .td.pg-rby::before { content:attr(data-title) ":" !important; display:inline !important; position:static !important; float:none !important; width:auto !important; margin:0 .4em 0 0 !important; padding:0 !important; font-weight:600; opacity:.7; }' +
	'  .pg-rules .tr.cbi-section-table-row { grid-template-columns:9rem minmax(0,1fr) fit-content(60%); grid-template-areas:"name name act" "pk by by"; }' +
	'  .pg-rules .td.pg-rname { grid-area:name; font-weight:600; overflow-wrap:anywhere; }' +
	'  .pg-rules .td.pg-ract { grid-area:act; justify-self:end; text-align:right; min-width:0; }' +
	'  .pg-rules .td.pg-rpk { grid-area:pk; }' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rby { grid-area:by; white-space:nowrap; }' +
	'  .pg-rules .td.pg-rpk, .pg-rules .td.pg-rby { font-size:.85em; opacity:.8; }' +
	'  .pg-rules .td.pg-ract .pg-label { font-size:.8em; white-space:normal; display:inline-block; }' +
	'}' +
	'@container (max-width: ' + (CLIENTS_TABLE_MIN - 1) + 'px) {' +
	narrowCss('.pg-clients') +
	'  .pg-clients .tr.cbi-section-table-row { grid-template-columns:minmax(0,1fr) auto; grid-template-areas:"host tag" "ip ip" "mac mac" "traf traf"; }' +
	'  .pg-clients .td.pg-host { grid-area:host; font-weight:600; overflow-wrap:anywhere; }' +
	'  .pg-clients .td.pg-tag { grid-area:tag; justify-self:end; }' +
	'  .pg-clients .tr.cbi-section-table-row .td.pg-addr { display:contents !important; }' +
	'  .pg-clients .pg-ip { grid-area:ip; overflow-wrap:anywhere; }' +
	'  .pg-clients .pg-mac { grid-area:mac; }' +
	'  .pg-clients .tr.cbi-section-table-row .td.pg-type { display:none !important; }' +
	'  .pg-clients .td.pg-traf { grid-area:traf; font-size:.9em; }' +
	'  .pg-clients .pg-cn, .pg-clients .pg-cs { min-width:0; }' +
	'}' +
	'@container (min-width: 501px) and (max-width: ' + (CLIENTS_TABLE_MIN - 1) + 'px) {' +
	'  .pg-clients .tr.cbi-section-table-row { grid-template-columns:minmax(0,1fr) minmax(0,1.2fr) 6.2rem; grid-template-areas:"host ip tag" "host mac tag" "traf traf tag"; align-items:center; column-gap:.75rem; }' +
	'  .pg-clients .pg-ip, .pg-clients .pg-mac { text-align:center; }' +
	'  .pg-clients .tr.cbi-section-table-row .td.pg-tag { align-self:center; justify-self:stretch; text-align:right !important; }' +
	'  .pg-clients .td.pg-tag .pg-label { margin:1px 0 1px 4px; }' +
	'}' +
	'@container (min-width: 501px) and (max-width: ' + (RULES_TABLE_MIN - 1) + 'px) {' +
	'  .pg-rules .tr.cbi-section-table-row { grid-template-columns:minmax(0,1.25fr) auto minmax(0,.9fr); grid-template-areas:"name pk act" "name by act"; align-items:center; column-gap:1rem; }' +
	'  .pg-rules .td.pg-rname, .pg-rules .td.pg-ract { align-self:center; }' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rpk, .pg-rules .tr.cbi-section-table-row .td.pg-rby { text-align:left !important; justify-self:stretch; }' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rpk::before, .pg-rules .tr.cbi-section-table-row .td.pg-rby::before { display:inline-block !important; min-width:4.6em; }' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rby .pg-sp-inline { display:block; min-width:0; min-height:1.3em; margin-left:6.25em; }' +
	'}' +
	'@container (max-width: ' + (RULES_TABLE_MIN - 1) + 'px) {' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rsp { display:none !important; }' +
	'  .pg-rules .td.pg-rby .pg-sp-inline { display:inline-block; }' +
	'}' +
	'@container (max-width: 500px) {' +
	'  .pg-pk, .pg-by, .pg-speed { min-width:0; }' +
	'}' +
	'@container (max-width: 420px) {' +
	'  .pg-rules .tr.cbi-section-table-row { grid-template-columns:minmax(0,1fr) minmax(0,1fr); grid-template-areas:"name name" "act act" "pk by"; }' +
	'  .pg-rules .td.pg-ract { justify-self:start; text-align:left; }' +
	'  .pg-rules .tr.cbi-section-table-row .td.pg-rby { white-space:normal; }' +
	'}' +
	'.pg-head { display:flex; align-items:center; flex-wrap:wrap; gap:.5rem 1.5rem; padding:var(--field-gap) var(--section-inset) var(--field-gap) calc(var(--section-inset) + .8rem); border-radius:var(--radius-card); background:var(--surface-raised); box-shadow:0 4px 8px rgba(0,0,0,.03); }' +
	'.pg-natmap { display:inline-flex; align-items:center; gap:.75rem; }' +
	'.pg-switch { display:inline-flex; align-items:center; gap:.4rem; height:auto; min-height:0; line-height:1.4; padding:.25rem .8rem; margin:0; border-radius:999px; font-weight:600; font-size:.9rem; border:0; box-shadow:none; cursor:pointer; transition:filter .15s; }' +
	'.pg-switch:hover { filter:brightness(.95); }' +
	'.pg-switch:disabled { opacity:.6; cursor:default; }' +
	'.pg-switch::before { content:""; width:.55rem; height:.55rem; border-radius:50%; background:currentColor; }' +
	'.pg-switch.on { color:#1a7f37; background:#dafbe1; }' +
	'.pg-switch.warn { color:#9a6700; background:#fff8c5; }' +
	'.pg-switch.na { color:#6b7280; background:rgba(128,128,128,.18); }' +
	'.pg-switch.na:disabled { opacity:1; cursor:not-allowed; }' +
	'.pg-switch.off { color:#82071e; background:#ffebe9; }';

function formatBytes(n) {
	n = Number(n) || 0;

	if (n >= 1073741824)
		return (n / 1073741824).toFixed(2) + ' GiB';
	if (n >= 1048576)
		return (n / 1048576).toFixed(2) + ' MiB';
	if (n >= 1024)
		return (n / 1024).toFixed(2) + ' KiB';

	return n.toFixed(0) + ' B';
}

function cmpIp(a, b) {
	const v6a = a.indexOf(':') > -1, v6b = b.indexOf(':') > -1;

	if (v6a !== v6b)
		return v6a ? 1 : -1;

	if (v6a)
		return (a < b) ? -1 : (a > b) ? 1 : 0;

	const pa = a.split('.'), pb = b.split('.');

	for (let i = 0; i < 4; i++) {
		const d = (+pa[i] || 0) - (+pb[i] || 0);

		if (d)
			return d;
	}

	return 0;
}

function cmpAddr(x, y) {
	if (!!x.offline !== !!y.offline)
		return x.offline ? -1 : 1;

	return x.offline ? 0 : cmpIp(x.ip, y.ip);
}

function textEl(tag, cls, text) {
	const n = E(tag, cls ? { 'class': cls } : {});
	n.textContent = text;
	return n;
}

function badge(text, color) {
	const n = textEl('span', 'pg-label', text);
	n.style.backgroundColor = color;
	return n;
}

function cell(child, cls, title) {
	const td = E('td', { 'class': 'td' + (cls ? ' ' + cls : '') }, [ child ]);

	if (title)
		td.setAttribute('data-title', title);

	return td;
}

function emptyRow(cols, text) {
	return E('tr', { 'class': 'tr cbi-section-table-row' }, [
		E('td', { 'class': 'td', 'colspan': String(cols) }, [ E('em', {}, [ text ]) ])
	]);
}

function headerRow(titles) {
	return E('tr', { 'class': 'tr cbi-section-table-titles' },
		titles.map(t => E('th', { 'class': 'th cbi-section-table-th' }, [ t ])));
}

function actionBadge(raw) {
	const label = _(raw);

	if (/Direct/.test(raw))
		return badge(label, '#46a546');
	if (/Proxy|Agent/i.test(raw))
		return badge(label, '#0069d6');
	if (/NAT/.test(raw))
		return badge(label, '#d9822b');

	return textEl('small', '', label);
}

return view.extend({
	lastBytes: {},
	lastClient: {},
	lastRate: {},
	sort: { key: 'host', dir: 1 },
	shownOrder: null,
	curClients: [],

	load() {
		return callStatus();
	},

	render(st) {
		st = st || {};

		const head = E('div', { 'class': 'cbi-map-descr pg-head' }, [
			E('span', { 'class': 'pg-natmap' }, [
				textEl('span', '', _('Main Switch')),
				this.buildSwitch(!!st.running)
			])
		]);

		head.appendChild(this.buildNatmapOption(st.natmap, st.has_natmap, st.watching, st.instances));

		const root = E('div', {}, [
			E('style', {}, [ CSS ]),
			head
		]);

		if (!st.running) {
			root.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('em', { 'style': 'color:#999' }, [ _('Statistics and Client list not available (Service is stopped)') ])
			]));

			return root;
		}

		this.rulesTable = E('table', { 'class': 'table cbi-section-table pg-tbl pg-rules' }, [
			headerRow([ _('Rule Name'), _('Packets'), _('Bytes'), _('Speed'), _('Action / Comment') ]),
			emptyRow(5, _('Collecting data...'))
		]);

		this.clientsTable = E('table', { 'class': 'table cbi-section-table pg-tbl pg-clients' }, [
			this.clientHeader(),
			emptyRow(5, _('Fetching client list...'))
		]);

		const node = E('div', { 'class': 'cbi-section-node cbi-section-node-tabbed' }, [
			E('div', { 'data-tab': 'stats', 'data-tab-title': _('Traffic Statistics') }, [
				E('div', { 'class': 'pg-wrap' }, [ this.rulesTable ])
			]),
			E('div', { 'data-tab': 'clients', 'data-tab-title': _('VPN Clients') }, [
				E('div', { 'class': 'pg-wrap' }, [ this.clientsTable ])
			])
		]);

		const tabs = E('div', { 'class': 'cbi-section' }, [ node ]);

		ui.tabs.initTabGroup(node.childNodes);
		root.appendChild(tabs);

		this.refresh();
		poll.add(() => this.refresh(), POLL_INTERVAL);

		return root;
	},

	refresh() {
		return callData().then(data => this.update(data || {})).catch(() => null);
	},

	update(data) {
		const now = Date.now();
		const dt = this.lastSample ? (now - this.lastSample) / 1000 : 0;

		this.lastSample = now;

		this.updateRules(data.rules || [], dt);
		this.updateClients(data.clients || [], dt);
	},

	keepScroll(fn) {
		const sc = document.scrollingElement || document.documentElement;
		const top = sc.scrollTop;

		fn();

		if (sc.scrollTop !== top)
			sc.scrollTop = top;
	},

	updateRules(rules, dt) {
		const direct = rules.filter(r => /^Direct/.test(r.comment || ''));

		if (direct.length > 1) {
			rules = rules.concat([ {
				name: _('Total (all Direct rules)'),
				comment: 'Direct / Bypassed PassWall2',
				packets: direct.reduce((a, r) => a + (Number(r.packets) || 0), 0),
				bytes: direct.reduce((a, r) => a + (Number(r.bytes) || 0), 0),
				total: true
			} ]);
		}

		const key = rules.map(r => r.name).join('\n');

		if (key !== this.ruleKey) {
			this.ruleKey = key;
			this.ruleRefs = {};

			const rows = [ headerRow([ _('Rule Name'), _('Packets'), _('Bytes'), _('Speed'), _('Action / Comment') ]) ];

			if (!rules.length)
				rows.push(emptyRow(5, _('No traffic data detected yet...')));

			rules.forEach((r, i) => {
				const pk = textEl('span', 'pg-pk', '');
				const by = textEl('span', 'pg-by', '');
				const sp = textEl('span', 'pg-speed pg-sp-inline', '');
				const sp2 = textEl('span', 'pg-speed', '');

				this.ruleRefs[r.name] = { pk: pk, by: by, sp: sp, sp2: sp2 };

				rows.push(E('tr', { 'class': 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2) + (r.total ? ' pg-total' : '') }, [
					cell(textEl('span', '', r.name), 'pg-rname'),
					cell(pk, 'pg-rpk', _('Packets')),
					E('td', { 'class': 'td pg-rby', 'data-title': _('Bytes') }, [ by, sp ]),
					cell(sp2, 'pg-rsp'),
					cell(actionBadge(r.comment || ''), 'pg-ract')
				]));
			});

			this.keepScroll(() => L.dom.content(this.rulesTable, rows));
		}

		rules.forEach(r => {
			const ref = this.ruleRefs[r.name];
			const cur = Number(r.bytes) || 0;
			const prev = this.lastBytes[r.name];

			if (!ref)
				return;

			ref.pk.textContent = String(r.packets);
			ref.by.textContent = formatBytes(cur);
			const speed = (prev !== undefined && cur > prev && dt > 0)
				? '\u2191 ' + formatBytes((cur - prev) / dt) + '/s' : '';

			ref.sp.textContent = speed ? ' ' + speed : '';
			ref.sp2.textContent = speed;

			this.lastBytes[r.name] = cur;
		});
	},

	clientHeader() {
		const target = (key, label, cls, tag) => E(tag, {
			'class': cls + ' pg-sort', 'role': 'button', 'tabindex': '0', 'data-sort': key,
			'title': _('Click to sort'),
			'click': () => this.setSort(key),
			'keydown': ev => {
				if (ev.key === 'Enter' || ev.key === ' ') {
					ev.preventDefault();
					this.setSort(key);
				}
			}
		}, [ label, E('span', { 'class': 'pg-sortind' }) ]);

		const th = (key, label) => target(key, label, 'th cbi-section-table-th', 'th');

		const split = (k1, l1, k2, l2) => E('th', { 'class': 'th cbi-section-table-th pg-split' }, [
			target(k1, l1, 'pg-sort-half', 'span'), '/', target(k2, l2, 'pg-sort-half', 'span')
		]);

		const tr = E('tr', { 'class': 'tr cbi-section-table-titles' }, [
			th('host', _('Hostname')),
			split('addr', _('IP Address'), 'mac', _('MAC')),
			split('traf', _('Traffic'), 'speed', _('Speed')),
			th('type', _('Type')),
			th('tag', _('Tag'))
		]);

		this.paintHeader(tr);

		return tr;
	},

	setSort(key) {
		if (this.sort.key === key)
			this.sort = { key: key, dir: -this.sort.dir };
		else
			this.sort = { key: key, dir: (key === 'traf' || key === 'speed') ? -1 : 1 };

		this.paintHeader(this.clientsTable);
		this.applySort();
	},

	paintHeader(root) {
		const s = this.sort;

		root.querySelectorAll('.pg-sort').forEach(el => {
			const on = (s.key === el.getAttribute('data-sort'));

			el.querySelector('.pg-sortind').textContent = on ? ((s.dir > 0) ? '\u25B2' : '\u25BC') : '';
		});
	},

	applySort() {
		const list = this.curClients || [];
		const s = this.sort;
		const by = {};

		list.forEach(c => { by[c.id] = c; });

		const macOf = c => (c.mac && c.mac !== '\u2014') ? c.mac : '';
		const byName = (a, b) => String(by[a].hostname || '').localeCompare(String(by[b].hostname || ''), undefined, { numeric: true, sensitivity: 'base' });

		const rank = c => c.offline ? -1 : (c.ip.indexOf(':') > -1 ? 1 : 0);

		const cmp = (a, b) => {
			const x = by[a], y = by[b];

			switch (s.key) {
			case 'addr':
				return cmpAddr(x, y);
			case 'mac':
				return macOf(x).localeCompare(macOf(y));
			case 'traf':
				return ((x.up || 0) + (x.down || 0)) - ((y.up || 0) + (y.down || 0));
			case 'speed':
				return (this.lastRate[a] || 0) - (this.lastRate[b] || 0);
			case 'type':
				return rank(x) - rank(y);
			case 'tag':
				return (x.is_server ? 1 : 0) - (y.is_server ? 1 : 0);
			}

			return byName(a, b);
		};

		const order = list.map(c => c.id).sort((a, b) => {
			const r = cmp(a, b);

			return r ? r * s.dir : (byName(a, b) || cmpAddr(by[a], by[b]) || (a < b ? -1 : a > b ? 1 : 0));
		});

		const sig = order.join('|');

		if (sig === this.shownOrder)
			return;

		this.shownOrder = sig;

		this.keepScroll(() => order.forEach((id, i) => {
			const ref = this.clientRefs[id];

			if (!ref || !ref.row)
				return;

			ref.row.className = 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2);
			this.clientsTable.appendChild(ref.row);
		}));
	},

	updateClients(clients, dt) {
		this.curClients = clients;

		const key = JSON.stringify(clients.map(c => [ c.id, c.ip, c.mac, c.hostname, c.is_server, !!c.offline, c.up != null ]));

		if (key !== this.clientKey) {
			this.clientKey = key;
			this.clientRefs = {};

			const crows = [ this.clientHeader() ];

			if (!clients.length)
				crows.push(emptyRow(5, _('No VPN clients configured.')));

			clients.forEach((c, i) => {
				const isV6 = String(c.ip).indexOf(':') > -1;
				const tag = E('td', { 'class': 'td pg-tag' }, [ badge('VPN', '#46a546') ]);

				if (c.is_server)
					tag.appendChild(badge('Server', '#0069d6'));

				if (c.offline) {
					const ref = { offline: true };
					let traf = E('td', { 'class': 'td pg-traf' });

					if (c.up != null) {
						const mk = arrow => {
							const v = textEl('span', '', '');

							return { v: v, o: E('span', { 'class': 'pg-cn', 'style': 'grid-column:1' }, [ textEl('span', 'pg-arr', arrow), v ]) };
						};

						ref.tu = mk('\u2191');
						ref.td = mk('\u2193');

						traf = E('td', { 'class': 'td pg-traf', 'title': _('Upload / Download') }, [
							E('div', { 'class': 'pg-trafbox' }, [ ref.tu.o, ref.td.o ])
						]);
					}

					this.clientRefs[c.id] = ref;

					ref.row = E('tr', { 'class': 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2) }, [
						cell(c.hostname ? textEl('span', '', c.hostname) : E('em', {}, [ 'unknown' ]), 'pg-host'),
						E('td', { 'class': 'td pg-addr' }, [
							textEl('div', 'pg-ip pg-offline', _('Offline')),
							textEl('div', 'pg-mac', c.mac || '\u2014')
						]),
						traf,
						cell(textEl('span', '', ''), 'pg-type'),
						tag
					]);

					crows.push(ref.row);
					return;
				}

				const mk = (cls, arrow) => {
					const v = textEl('span', '', '');

					return { v: v, o: E('span', { 'class': cls }, [ textEl('span', 'pg-arr', arrow), v ]) };
				};

				const ref = {
					tu: mk('pg-cn', '\u2191'), td: mk('pg-cn', '\u2193'),
					su: mk('pg-cs pg-cs-up', '\u2191'), sd: mk('pg-cs pg-cs-dn', '\u2193')
				};

				this.clientRefs[c.id] = ref;

				const traf = E('td', { 'class': 'td pg-traf', 'title': _('Upload / Download') }, [
					E('div', { 'class': 'pg-trafbox' }, [ ref.tu.o, ref.su.o, ref.td.o, ref.sd.o ])
				]);

				ref.row = E('tr', { 'class': 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2) }, [
					cell(c.hostname ? textEl('span', '', c.hostname) : E('em', {}, [ 'unknown' ]), 'pg-host'),
					E('td', { 'class': 'td pg-addr' }, [
						textEl('div', 'pg-ip' + (isV6 ? ' pg-ip6' : ''), c.ip),
						textEl('div', 'pg-mac', c.mac || '\u2014')
					]),
					traf,
					cell(textEl('span', '', isV6 ? 'IPv6' : 'IPv4'), 'pg-type'),
					tag
				]);

				crows.push(ref.row);
			});

			this.keepScroll(() => L.dom.content(this.clientsTable, crows));
			this.shownOrder = null;
		}

		clients.forEach(c => {
			const ref = this.clientRefs[c.id];

			if (!ref)
				return;

			if (ref.offline) {
				delete this.lastClient[c.id];
				this.lastRate[c.id] = 0;

				if (ref.tu && c.up != null) {
					ref.tu.v.textContent = formatBytes(c.up);
					ref.td.v.textContent = formatBytes(c.down);
				}

				return;
			}

			const up = c.up, down = c.down;

			if (up == null || down == null) {
				ref.tu.v.textContent = ref.td.v.textContent = ref.su.v.textContent = ref.sd.v.textContent = '\u2014';
				delete this.lastClient[c.id];
				this.lastRate[c.id] = 0;
				return;
			}

			const prev = this.lastClient[c.id];

			const rate = (cur, old) => (old !== undefined && cur >= old && dt > 0) ? (cur - old) / dt : 0;

			const ru = rate(up, prev && prev.up), rd = rate(down, prev && prev.down);

			ref.tu.v.textContent = formatBytes(up);
			ref.td.v.textContent = formatBytes(down);
			ref.su.v.textContent = formatBytes(ru) + '/s';
			ref.sd.v.textContent = formatBytes(rd) + '/s';

			this.lastRate[c.id] = ru + rd;
			this.lastClient[c.id] = { up: up, down: down };
		});

		this.applySort();
	},

	buildNatmapOption(checked, installed, running, inst) {
		const tip = _('Update firewall rules automatically when Natmap port changes.');
		let on = !!checked;
		let watching = !!running;
		let hasInst = !!inst;

		const paint = () => {
			if (!installed) {
				sw.className = 'pg-switch na';
				sw.textContent = _('Not Installed');
				sw.title = '';
				sw.disabled = true;
				return;
			}

			let state = _('Enabled'), hint = '';

			let cls = on ? 'on' : 'off';

			if (on) {
				if (!watching) {
					cls = 'warn';
					state += ' · ' + _('No qB entry');
					hint = _('No enabled Natmap entry is recognised as qBittorrent (its comment must start with "qB", or it uses the qBittorrent client script with refresh on), so the watcher is not running.');
				}
				else if (!hasInst) {
					cls = 'warn';
					state += ' · ' + _('No instances');
					hint = _('The watcher is running, but Natmap has no running instance, so there are no ports to follow yet. It picks them up automatically once Natmap starts.');
				}
				else {
					state += ' · ' + _('Watching');
					hint = _('The watcher is running and keeps the qB direct rules in line with the current Natmap ports.');
				}

				hint += ' ';
			}

			sw.className = 'pg-switch ' + cls;
			sw.textContent = on ? state : _('Disabled');
			sw.title = on ? hint + _('Click to disable') : _('Click to enable');
		};

		const sw = E('button', {
			'type': 'button',
			'click': ev => {
				ev.preventDefault();

				if (!installed)
					return;

				sw.disabled = true;
				sw.textContent = _('Applying...');

				callSetNatmap(on ? '0' : '1').then(res => {
					if (!res || res.code !== 0)
						throw new Error('failed');

					on = !on;

					return callStatus().then(s => { watching = !!(s && s.watching); hasInst = !!(s && s.instances); });
				}).catch(() => {
					ui.addNotification(null, E('p', {}, [ _('Config Update Failed') ]), 'danger');
				}).then(() => {
					sw.disabled = false;
					paint();
				});
			}
		});

		paint();

		return E('span', { 'class': 'pg-natmap', 'title': tip }, [
			textEl('span', '', _('Natmap qB Direct')),
			sw
		]);
	},

	buildSwitch(running) {
		const label = running ? _('Enabled') : _('Disabled');

		const sw = E('button', {
			'class': 'pg-switch ' + (running ? 'on' : 'off'),
			'type': 'button',
			'title': running ? _('Click to disable') : _('Click to enable'),
			'click': ev => {
				ev.preventDefault();
				sw.disabled = true;
				sw.textContent = _('Applying...');

				callSetBypass(running ? 'disable' : 'enable').then(res => {
					if (res && res.code === 0) {
						window.location.reload();
						return;
					}

					throw new Error('failed');
				}).catch(() => {
					sw.disabled = false;
					sw.textContent = label;
					ui.addNotification(null, E('p', {}, [ _('Config Update Failed') ]), 'danger');
				});
			}
		}, [ label ]);

		return sw;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
