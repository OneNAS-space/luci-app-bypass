/* rpcd plugin for luci-app-bypass (object luci.bypass): status, data, set_bypass, set_natmap */
'use strict';

import { cursor } from 'uci';
import { popen, access, writefile } from 'fs';

const CONF = 'bypass';
const SECTION = 'global';
const INIT = '/etc/init.d/bypass';
const SEEN_TTL = 604800;
const ONLINE_WITHIN = 600;
const UI_REV = 1;
const NFT = '/usr/sbin/nft';

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

function natmap_instances() {
	const out = trim(run("ubus call service list '{\"name\":\"natmap\"}'"));

	if (!out)
		return false;

	let svc;

	try {
		svc = json(out);
	} catch (e) {
		return false;
	}

	const inst = svc?.natmap?.instances;

	for (let k in inst)
		if (inst[k]?.running)
			return true;

	return false;
}

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

function load_hosts() {
	const ctx = cursor();
	const list = [];
	const by_group = {};

	ctx.foreach('dhcp', 'host', (s) => {
		let group = '';
		const plain = [];
		const labels = [];

		for (let t in ((type(s.tag) == 'array') ? s.tag : split(s.tag ?? '', /[ \t]+/))) {
			if (match(lc(t), /^grp[-_]./))
				group = (group != '') ? group : substr(t, 4);
			else {
				push(plain, lc(t));

				if (t != '' && index(lc(t), 'vpn') < 0 && !match(lc(t), /(^|[^a-z0-9_])server([^a-z0-9_]|$)/))
					push(labels, t);
			}
		}

		const tags = join(' ', plain);

		if (index(tags, 'vpn') < 0 || !s.mac)
			return;

		const macs = [];

		for (let m in ((type(s.mac) == 'array') ? s.mac : split(s.mac, /[ \t]+/))) {
			m = lc(m);

			if (match(m, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/))
				push(macs, m);
		}

		if (!length(macs))
			return;

		const name = s.name ?? '';
		const server = !!match(tags, /(^|[^a-z0-9_])server([^a-z0-9_]|$)/);
		let h = (group != '') ? by_group[lc(group)] : null;

		if (h) {
			for (let m in macs)
				if (index(h.macs, m) < 0)
					push(h.macs, m);

			h.server = h.server || server;

			for (let t in labels)
				if (!length(filter(h.tags, (x) => lc(x) == lc(t))))
					push(h.tags, t);

			if (name != '')
				push(h.members, name);

			return;
		}

		h = {
			name: (group != '') ? group : ((name != '') ? name : 'Configured-Device'),
			macs: macs,
			server: server,
			tags: labels,
			members: (group != '' && name != '') ? [ name ] : []
		};

		push(list, h);

		if (group != '')
			by_group[lc(group)] = h;
	});

	for (let h in list)
		h.macs = sort(h.macs);

	return list;
}

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
		else if (type(item) == 'object' && type(item.map) == 'object' && type(item.map.name) == 'string')
			SETS[item.map.name] = (type(item.map.elem) == 'array') ? item.map.elem : [];
	}
}

function fetch_seen(name) {
	const out = [];

	for (let el in (SETS[name] ?? [])) {
		if (type(el) != 'array' || type(el[0]) != 'object' || type(el[0].elem) != 'object' || type(el[1]) != 'string')
			continue;

		const e = el[0].elem;

		if (type(e.val) == 'string')
			push(out, { ip: e.val, mac: lc(el[1]), age: SEEN_TTL - int(e.expires ?? 0) });
	}

	return out;
}

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

function collect_clients() {
	load_sets();

	const up = fetch_acct('acct_up4');
	const down = fetch_acct('acct_dn4');

	for (let k, v in fetch_acct('acct_up6'))
		up[k] = v;

	for (let k, v in fetch_acct('acct_dn6'))
		down[k] = v;

	const rows = {};
	const by_mac = {};
	const order = [];

	for (let h in load_hosts()) {
		const r = {
			id: 'h:' + h.macs[0],
			hostname: h.name,
			is_server: h.server,
			macs: map(h.macs, uc),
			members: h.members,
			tags: h.tags,
			addrs: [],
			up: 0,
			down: 0
		};

		rows[r.id] = r;
		push(order, r);

		for (let m in h.macs)
			by_mac[m] = r;
	}

	for (let e in [ ...fetch_seen('vpn_seen4'), ...fetch_seen('vpn_seen6') ]) {
		const r = by_mac[e.mac];

		if (!r)
			continue;

		r.up += up[e.ip] ?? 0;
		r.down += down[e.ip] ?? 0;

		if (e.age <= ONLINE_WITHIN)
			push(r.addrs, { ip: e.ip, mac: uc(e.mac), age: e.age, up: up[e.ip] ?? 0, down: down[e.ip] ?? 0 });
	}

	const clients = [];

	for (let r in order) {
		if (length(r.addrs)) {
			r.addrs = sort(r.addrs, (a, b) => {
				const fa = (index(a.ip, ':') >= 0) ? 1 : 0, fb = (index(b.ip, ':') >= 0) ? 1 : 0;

				return (fa != fb) ? fa - fb : ((a.ip < b.ip) ? -1 : (a.ip > b.ip) ? 1 : 0);
			});

			push(clients, { id: r.id, hostname: r.hostname, members: r.members, tags: r.tags, is_server: r.is_server, addrs: r.addrs, up: r.up, down: r.down });
		}
		else {
			const row = { id: r.id, inactive: true, hostname: r.hostname, members: r.members, tags: r.tags, is_server: r.is_server, macs: r.macs };

			if (r.up || r.down) {
				row.up = r.up;
				row.down = r.down;
			}

			push(clients, row);
		}
	}

	return clients;
}

const methods = {
	status: {
		call: function() {
			const ctx = cursor();
			const enabled = (ctx.get(CONF, SECTION, 'enable_bypass') == '1');
			const table_up = (system(NFT + ' list table inet bypass_logic >/dev/null 2>&1') == 0);

			return {
				rev: UI_REV,
				enabled: enabled,
				running: enabled && table_up,
				natmap: (ctx.get(CONF, SECTION, 'enable_natmap') == '1'),
				has_natmap: access('/etc/config/natmap') ? true : false,
				watching: (system('pgrep -f "[n]atmap_watch.sh" >/dev/null 2>&1') == 0),
				instances: natmap_instances()
			};
		}
	},

	data: {
		call: function() {
			const text = run(NFT + ' -p list table inet bypass_logic');

			if (text == '')
				return { rev: UI_REV, rules: [], clients: [] };

			return {
				rev: UI_REV,
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

			if (system(INIT + ' status >/dev/null 2>&1') == 0)
				system([ INIT, 'reload' ], 30000);

			return { code: 0 };
		}
	}
};

return { 'luci.bypass': methods };

