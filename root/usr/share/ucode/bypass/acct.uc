/* Per-MAC traffic totals of the VPN clients: live nft counters plus the saved totals in /tmp (RAM). */
'use strict';

import { popen, readfile, writefile, rename } from 'fs';

const NFT = '/usr/sbin/nft';
const TABLE = 'inet bypass_logic';
const STORE = '/tmp/bypass_acct.json';
const ACCT_SETS = [ 'acct_up4', 'acct_up6', 'acct_dn4', 'acct_dn6' ];

export const DEFAULT_TTL = 2592000;

function run(cmd) {
	const p = popen(cmd + ' 2>/dev/null', 'r');

	if (!p)
		return '';

	const out = p.read('all');
	p.close();

	return out ?? '';
}

export function load_live() {
	const live = { sets: {}, ttl: DEFAULT_TTL };
	let doc = null;

	try {
		doc = json(run(NFT + ' -j list table ' + TABLE));
	}
	catch (e) {
		doc = null;
	}

	if (type(doc) != 'object' || type(doc.nftables) != 'array')
		return live;

	for (let item in doc.nftables) {
		const o = (type(item) == 'object') ? (item.set ?? item.map) : null;

		if (type(o) != 'object' || type(o.name) != 'string')
			continue;

		live.sets[o.name] = (type(o.elem) == 'array') ? o.elem : [];

		if (o.name == 'vpn_seen4' && int(o.timeout) > 0)
			live.ttl = int(o.timeout);
	}

	return live;
}

export function seen(live, name) {
	const out = [];

	for (let el in (live.sets[name] ?? [])) {
		if (type(el) != 'array' || type(el[0]) != 'object' || type(el[0].elem) != 'object' || type(el[1]) != 'string')
			continue;

		const e = el[0].elem;

		if (type(e.val) == 'string')
			push(out, { ip: e.val, mac: lc(el[1]), age: live.ttl - int(e.expires ?? 0) });
	}

	return out;
}

function fetch_acct(live, name) {
	const out = {};

	for (let el in (live.sets[name] ?? [])) {
		if (type(el) != 'object' || type(el.elem) != 'object')
			continue;

		const e = el.elem;

		if (type(e.val) == 'string' && type(e.counter) == 'object')
			out[e.val] = int(e.counter.bytes);
	}

	return out;
}

export function counters(live) {
	const up = fetch_acct(live, 'acct_up4');
	const down = fetch_acct(live, 'acct_dn4');

	for (let k, v in fetch_acct(live, 'acct_up6'))
		up[k] = v;

	for (let k, v in fetch_acct(live, 'acct_dn6'))
		down[k] = v;

	return { up: up, down: down };
}

function write_store(st) {
	writefile(STORE + '.tmp', sprintf('%J', st));
	rename(STORE + '.tmp', STORE);
}

export function read_store() {
	let st = null;

	try {
		st = json(readfile(STORE) ?? '');
	}
	catch (e) {
		st = null;
	}

	if (type(st) != 'object' || type(st.since) != 'int') {
		st = { since: time(), macs: {} };
		write_store(st);
	}

	if (type(st.macs) != 'object')
		st.macs = {};

	return st;
}

export function save() {
	const live = load_live();
	const st = read_store();
	const c = counters(live);
	let changed = false;

	for (let e in [ ...seen(live, 'vpn_seen4'), ...seen(live, 'vpn_seen6') ]) {
		const u = c.up[e.ip] ?? 0;
		const d = c.down[e.ip] ?? 0;

		if (!u && !d)
			continue;

		const m = st.macs[e.mac] ?? { up: 0, down: 0 };

		m.up = int(m.up ?? 0) + u;
		m.down = int(m.down ?? 0) + d;
		st.macs[e.mac] = m;
		changed = true;
	}

	if (changed)
		write_store(st);
}

function drop_elements(live, ips, sets) {
	for (let name in sets)
		for (let el in (live.sets[name] ?? [])) {
			const e = (type(el) == 'array') ? el[0]?.elem : el?.elem;

			if (type(e) == 'object' && ips[e.val])
				run(NFT + ' delete element ' + TABLE + ' ' + name + ' "{ ' + e.val + ' }"');
		}
}

export function prune(macs) {
	const keep = {};

	for (let m in macs)
		keep[lc(m)] = true;

	if (!length(keep))
		return;

	const live = load_live();
	const st = read_store();
	const gone = {};
	let changed = false;

	for (let m in keys(st.macs))
		if (!keep[m]) {
			delete st.macs[m];
			changed = true;
		}

	for (let e in [ ...seen(live, 'vpn_seen4'), ...seen(live, 'vpn_seen6') ])
		if (!keep[e.mac])
			gone[e.ip] = true;

	if (length(gone))
		drop_elements(live, gone, [ 'vpn_seen4', 'vpn_seen6', ...ACCT_SETS ]);

	if (changed)
		write_store(st);
}

export function reset_all() {
	for (let name in ACCT_SETS)
		run(NFT + ' flush set ' + TABLE + ' ' + name);

	write_store({ since: time(), macs: {} });
}

export function reset_macs(macs) {
	const live = load_live();
	const st = read_store();
	const want = {};
	const ips = {};
	const now = time();

	for (let m in macs) {
		m = lc(m);
		want[m] = true;
		st.macs[m] = { up: 0, down: 0, since: now };
	}

	for (let e in [ ...seen(live, 'vpn_seen4'), ...seen(live, 'vpn_seen6') ])
		if (want[e.mac])
			ips[e.ip] = true;

	drop_elements(live, ips, ACCT_SETS);
	write_store(st);
}
