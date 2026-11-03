'use strict';

/*
 * rpcd plugin for luci-app-bypass (object: luci.bypass)
 *
 *   status      -> { enabled, running, natmap, has_natmap }
 *   data        -> { rules: [...], clients: [...] }   (parsed from the nft table; clients carry up / down byte counters)
 *   set_bypass  -> { set: 'enable' | 'disable' }
 *   set_natmap  -> { set: '1' | '0' }
 *
 * Only these methods are exposed to the web UI (see acl.d), no generic
 * command execution is needed.
 */

import { cursor } from 'uci';
import { popen, access, writefile } from 'fs';

const CONF = 'bypass';
const SECTION = 'global';
const INIT = '/etc/init.d/bypass';
const NATMAP_SCRIPT = '/usr/share/bypass/scripts/natmap_bypass.sh';
const NFT = '/usr/sbin/nft';

/* ---------- helpers ---------- */

function run(cmd) {
	const p = popen(cmd + ' 2>/dev/null', 'r');

	if (!p)
		return '';

	const out = p.read('all');
	p.close();

	return out ?? '';
}

function open_cursor() {
	if (!access('/etc/config/' + CONF))
		writefile('/etc/config/' + CONF, '');

	const ctx = cursor();

	if (!ctx.get(CONF, SECTION))
		ctx.set(CONF, SECTION, CONF);

	return ctx;
}

function save_config(ctx, name) {
	ctx.save(name);
	ctx.commit(name);
}

/* ---------- nft parsing ---------- */

/* split "nft list table" output into { chain_name: [ trimmed rule lines ] } */
function parse_chains(text) {
	const chains = {};
	let cur = null;

	for (let line in split(text, '\n')) {
		const t = trim(line);
		const m = match(t, /^chain ([A-Za-z0-9_]+) \{$/);

		if (m) {
			cur = m[1];
			chains[cur] = [];
		}
		else if (t == '}') {
			cur = null;
		}
		else if (cur) {
			push(chains[cur], t);
		}
	}

	return chains;
}

function normalize_key(comment) {
	let key = replace(comment, /-?[tT][cC][pP]-?/g, '-');

	key = replace(key, /-?[uU][dD][pP]-?/g, '-');
	key = replace(key, /-?[vV]?[46]-?/g, '-');
	key = replace(key, /-+/g, '-');
	key = replace(key, /-+$/, '');
	key = replace(key, /^-+/, '');

	return key;
}

function friendly_action(key) {
	if (index(key, 'Direct') >= 0) {
		if (index(key, 'BT') >= 0 || index(key, 'qB') >= 0)
			return 'Direct / BitTorrent';
		if (index(key, 'P2P-Tunnel-Setup') >= 0)
			return 'Direct / P2P Tunnel Setup (port 7844)';
		if (index(key, 'CN-Direct') >= 0)
			return 'Direct / China IP Address';
		if (index(key, 'STUN-Direct') >= 0)
			return 'Direct / STUN Penetration';

		if (index(key, 'Non-VPN-Client') >= 0)
			return 'Direct / Non-VPN Devices';

		return 'Direct / Bypass';
	}

	if (index(key, 'PASS') >= 0)
		return 'Proxy / Agent Redirect';

	if (index(key, 'Fix') >= 0 || index(key, 'Loopback') >= 0) {
		if (index(key, 'Local') >= 0)
			return 'System / Router Self-Agent Redirect';
		if (index(key, 'Loopback') >= 0)
			return 'System / Loopback Bypass';

		return 'System / Routing Fix';
	}

	return '—';
}

/* the qBittorrent rules are only shown while the Natmap qB-port integration is installed AND switched on */
function natmap_active() {
	const ctx = cursor();

	return access('/etc/config/natmap') && ctx.get(CONF, SECTION, 'enable_natmap') == '1';
}

function collect_rules(chains, show_qb) {
	const rules = [];
	const agg = {};
	const order = [];

	for (let name in [ 'static_privilege', 'static_privilege_output', 'dynamic_logic' ]) {
		for (let line in (chains[name] ?? [])) {
			const c = match(line, /counter packets ([0-9]+) bytes ([0-9]+)/);
			const k = match(line, /comment "([^"]*)"/);

			if (!c || !k)
				continue;

			const key = normalize_key(k[1]);

			if (!show_qb && substr(key, 0, 2) == 'qB')
				continue;

			if (!agg[key]) {
				agg[key] = { name: key, packets: 0, bytes: 0, comment: friendly_action(key) };
				push(order, key);
			}

			agg[key].packets += int(c[1]);
			agg[key].bytes += int(c[2]);
		}
	}

	for (let key in order)
		push(rules, agg[key]);

	/* qBittorrent dual-stack port forwards */
	const nat = {};
	const nat_order = [];

	for (let line in (show_qb ? (chains['qb_fix'] ?? []) : [])) {
		const f = match(line, /ipv[0-9]/);
		const d = match(line, /([a-z]+) dport ([0-9]+)/);
		const c = match(line, /counter packets ([0-9]+) bytes ([0-9]+)/);
		const t = match(line, / to ([^ ]+)/);

		if (!f || !d || !c || !t)
			continue;

		const tp = match(t[1], /:([0-9]+)$/);
		const target_port = tp ? tp[1] : t[1];
		const key = d[2] + '_' + target_port;

		if (!nat[key]) {
			nat[key] = { dport: d[2], target_port: target_port, packets: 0, bytes: 0, protos: {} };
			push(nat_order, key);
		}

		nat[key].packets += int(c[1]);
		nat[key].bytes += int(c[2]);
		nat[key].protos[uc(d[1])] = true;
	}

	for (let key in nat_order) {
		const n = nat[key];

		push(rules, {
			name: join('/', sort(keys(n.protos))) + '-Fix: ' + n.dport,
			packets: n.packets,
			bytes: n.bytes,
			comment: 'NAT / Dual-Stack Forward -> :' + n.target_port
		});
	}

	return rules;
}

/* ---------- clients ---------- */

/* DHCP host entries tagged VPN: [ { name, macs: [ 'aa:bb:..' ], server } ]. The tags and MACs are what bypass uses too. */
function load_hosts() {
	const ctx = cursor();
	const list = [];

	ctx.foreach('dhcp', 'host', (s) => {
		const tags = lc(join(' ', (type(s.tag) == 'array') ? s.tag : [ s.tag ?? '' ]));

		if (index(tags, 'vpn') < 0 || !s.mac)
			return;

		const macs = [];

		for (let m in ((type(s.mac) == 'array') ? s.mac : split(s.mac, /[ \t]+/))) {
			m = lc(m);

			if (match(m, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/))
				push(macs, m);
		}

		if (length(macs))
			push(list, { name: s.name ?? 'Configured-Device', macs: macs, server: !!match(tags, /(^|[^a-z0-9_])server([^a-z0-9_]|$)/) });
	});

	return list;
}

function load_neighbours() {
	const map = {};

	for (let line in split(run('ip neigh show'), '\n')) {
		const f = split(trim(line), /[ \t]+/);
		const i = index(f, 'lladdr');

		if (i >= 0 && f[0] && f[i + 1])
			map[f[0]] = lc(f[i + 1]);
	}

	return map;
}

/* all sets of the table in ONE nft call (forking is the expensive part on small ARM routers): { name: [ elem, ... ] } */
let SETS = {};

function load_sets() {
	let doc = null;

	SETS = {};

	try {
		doc = json(run(NFT + ' -j list table inet bypass_logic'));
	}
	catch (e) {
		doc = null;
	}

	if (type(doc) != 'object' || type(doc.nftables) != 'array')
		return;

	for (let item in doc.nftables) {
		if (type(item) == 'object' && type(item.set) == 'object' && type(item.set.name) == 'string')
			SETS[item.set.name] = (type(item.set.elem) == 'array') ? item.set.elem : [];
	}
}

/* plain member addresses of a set */
function fetch_set(name) {
	const out = [];

	for (let el in (SETS[name] ?? [])) {
		if (type(el) == 'string')
			push(out, el);
		else if (type(el) == 'object' && type(el.elem) == 'object' && type(el.elem.val) == 'string')
			push(out, el.elem.val);
		else if (type(el) == 'object' && type(el.prefix) == 'object')
			push(out, el.prefix.addr + '/' + el.prefix.len);
	}

	return out;
}

/* per-element byte counters of an accounting set: { "<ip>": bytes } (empty when the set does not exist) */
function fetch_acct(name) {
	const out = {};

	for (let el in (SETS[name] ?? [])) {
		if (type(el) != 'object' || type(el.elem) != 'object')
			continue;

		const e = el.elem;

		if (type(e.val) == 'string' && type(e.counter) == 'object')
			out[e.val] = int(e.counter.bytes);
	}

	return out;
}

/*
 * One row per address a VPN client is currently seen with (bypass learns them from the client's MAC; they expire
 * after an hour without traffic), plus one "offline" row for every configured VPN MAC that has no address right now.
 */
function collect_clients() {
	load_sets();

	const up = fetch_acct('acct_up4');
	const down = fetch_acct('acct_dn4');

	for (let k, v in fetch_acct('acct_up6'))
		up[k] = v;

	for (let k, v in fetch_acct('acct_dn6'))
		down[k] = v;

	const hosts = load_hosts();
	const neigh = load_neighbours();
	const by_mac = {};
	const online = {};
	const shown = {};
	const clients = [];

	for (let h in hosts)
		for (let m in h.macs)
			by_mac[m] = h;

	for (let ip in [ ...fetch_set('vpn_seen4'), ...fetch_set('vpn_seen6') ]) {
		const mac = neigh[ip] ?? '';
		const h = (mac != '') ? by_mac[mac] : null;

		if (mac != '')
			online[mac] = true;

		shown[ip] = true;

		push(clients, {
			id: ip,
			ip: ip,
			mac: (mac != '') ? uc(mac) : '\u2014',
			hostname: h ? h.name : '',
			is_server: h ? h.server : false,
			up: up[ip] ?? 0,        /* bytes sent by the client / received by it through the proxy */
			down: down[ip] ?? 0
		});
	}

	/*
	 * What an offline device last moved: the accounting counters outlive the learned address by up to a week, so the
	 * counters of every address that is no longer listed are added up per MAC (the MAC of an address comes from the
	 * neighbour table, best effort). The page shows these totals, never a speed.
	 */
	const past = {};

	for (let ip in keys({ ...up, ...down })) {
		const m = shown[ip] ? '' : (neigh[ip] ?? '');

		if (m == '' || !by_mac[m])
			continue;

		if (!past[m])
			past[m] = { up: 0, down: 0 };

		past[m].up += up[ip] ?? 0;
		past[m].down += down[ip] ?? 0;
	}

	for (let h in hosts) {
		for (let m in h.macs) {
			if (online[m])
				continue;

			const row = {
				id: 'off:' + m,
				offline: true,
				mac: uc(m),
				hostname: h.name,
				is_server: h.server
			};

			if (past[m] && (past[m].up || past[m].down)) {
				row.up = past[m].up;
				row.down = past[m].down;
			}

			push(clients, row);
		}
	}

	return clients;
}

/* ---------- methods ---------- */

const methods = {
	status: {
		call: function() {
			const ctx = cursor();
			const enabled = (ctx.get(CONF, SECTION, 'enable_bypass') == '1');
			const table_up = (system(NFT + ' list table inet bypass_logic >/dev/null 2>&1') == 0);

			return {
				enabled: enabled,
				running: enabled && table_up,
				natmap: (ctx.get(CONF, SECTION, 'enable_natmap') == '1'),
				has_natmap: access('/etc/config/natmap') ? true : false
			};
		}
	},

	data: {
		call: function() {
			const text = run(NFT + ' -p list table inet bypass_logic');

			if (text == '')
				return { rules: [], clients: [] };

			return {
				rules: collect_rules(parse_chains(text), natmap_active()),
				clients: collect_clients()
			};
		}
	},

	set_bypass: {
		args: { set: 'enable' },
		call: function(req) {
			const act = req.args.set;

			if (act != 'enable' && act != 'disable')
				return { code: 1, error: 'invalid argument' };

			const ctx = open_cursor();

			ctx.set(CONF, SECTION, 'enable_bypass', (act == 'enable') ? '1' : '0');
			save_config(ctx, CONF);

			if (act == 'enable') {
				system([ INIT, 'enable' ], 30000);
				system([ INIT, 'start' ], 30000);
			}
			else {
				system([ INIT, 'stop' ], 30000);
				system([ INIT, 'disable' ], 30000);
			}

			return { code: 0 };
		}
	},

	set_natmap: {
		args: { set: '1' },
		call: function(req) {
			const val = req.args.set;

			if (val != '1' && val != '0')
				return { code: 1, error: 'invalid argument' };

			const ctx = open_cursor();

			ctx.set(CONF, SECTION, 'enable_natmap', val);
			save_config(ctx, CONF);

			if (access('/etc/config/natmap')) {
				ctx.foreach('natmap', 'natmap', (s) => {
					if (match(s.comment ?? '', /^qB/))
						ctx.set('natmap', s['.name'], 'custom_script', (val == '1') ? NATMAP_SCRIPT : '');
				});

				save_config(ctx, 'natmap');
				system([ '/etc/init.d/natmap', 'reload' ], 30000);
			}

			if (system(INIT + ' status >/dev/null 2>&1') == 0)
				system([ INIT, 'reload' ], 30000);

			return { code: 0 };
		}
	}
};

return { 'luci.bypass': methods };
