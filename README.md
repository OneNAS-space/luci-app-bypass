# luci-app-bypass

Direct-bypass rules for PassWall2 routers, with a LuCI page (**Services → PassWall2 → Bypass**).
A JavaScript view plus a small rpcd ucode plugin; the rules themselves live in the nft table `inet bypass_logic`,
managed by `/etc/init.d/bypass`. **No translations are shipped** (strings are wrapped in `_()` if you want to add your own).

## What it does

PassWall2 decides what is proxied; this package decides which LAN traffic never reaches it.

- **VPN clients are identified by MAC address.** A DHCP host entry (`/etc/config/dhcp`, `config host`) whose `tag`
  list contains `VPN` (any case; a tag such as `grp-VPNBox` or `grp_VPNBox` does not count) and which has one or more `mac` entries
  is a VPN client. Such a device is handed to
  PassWall2 whatever IP address it uses (IPv4, IPv6, privacy / temporary addresses, renumbering), so it needs no
  static address.
- **Everything else from the LAN goes direct.** The catch-all rule `Non-VPN-Client-Direct` marks LAN traffic of
  devices that are not VPN clients, so PassWall2 leaves it alone.
- **Port 7844 goes direct for every VPN client** (TCP and UDP, IPv4 and IPv6). These connections set up
  peer-to-peer tunnels (Cloudflare tunnels, NetBird and similar) and have to leave without the proxy.
- **Several network cards, one device.** A host can have several `config host` entries (one per NIC, each with its own
  name). Give them all the same tag `grp-<Name>` (for example `grp-MacBook`) and the page shows them as one device
  called `<Name>`; hover the name to see the entries behind it. `grp-` tags are ignored by the rules. `grp_<Name>` works the same way (LuCI's *Match Tag* field does not accept a
  hyphen, so use the underscore there); both spellings can be mixed and the name is case-insensitive. Entries without
  a `grp` tag are shown one per entry, by their own name.
- The `Server` tag has no effect on the rules; it is only a badge on the client page, so that a server can be recognised at a glance.
  Tags are combined freely (`VPN` plus `Server` plus `grp-...` plus anything else).
- Local-delivery and LAN-subnet destinations are left untouched (`Local-Fix`, `Loopback-Fix`, `Loopback-v6-Fix`).
- Optional **Natmap qBittorrent port integration**: while the switch is on, a small watcher follows Natmap's status
  files (`/var/run/natmap/*.json`) and keeps the qB direct rules (`qB-*`, the port forward of the TCP side of
  BitTorrent) in line with the current public and inner ports. It is only started while the switch is on **and**
  an enabled Natmap entry carries qBittorrent: its `comment` starts with `qB`, or it has `refresh` on with the
  `qBittorrent` client script. Natmap's configuration is only read, never changed, so an entry's own
  `custom_script` is left alone and Natmap is never restarted by this package.
- The VPN client set is rebuilt automatically when `dhcp`, `passwall2` or the WAN interfaces change.

## Rules at a glance

| Chain | Hook / priority | Purpose |
|---|---|---|
| `static_privilege` | prerouting −410 | Direct rules: port 7844 of VPN clients, qBittorrent ports |
| `static_privilege_output` | output −410 | STUN servers (only with Natmap) |
| `dynamic_logic` | prerouting −400 | Local / loopback exceptions, `AGENT-PASS` (VPN clients → PassWall2), `Non-VPN-Client-Direct` |
| `qb_fix` | nat prerouting −110 | Dual-stack port forwards (only with Natmap) |
| `acct_in`, `acct_out` | prerouting −50, postrouting 0 | Learn client addresses and count proxied traffic |

Direct traffic is marked `0xff`, which PassWall2 skips. `dynamic_logic`, `acct_in` and `acct_out` are rebuilt in one
nft transaction on every reload, so non-VPN devices are never proxied during a reload, and a failed load leaves the
previous rules untouched.

### Client addresses and accounting

- Every packet from a VPN client's MAC refreshes its source address in the maps `vpn_seen4` / `vpn_seen6`
  (address → MAC; link-local addresses excluded, and only addresses the router has a route back to through the LAN
  interface: a stray source address such as a virtual adapter's is not listed). The MAC is stored with the address,
  so the page knows exactly which card an address belongs to. Entries are kept for a week, and the page counts an
  address as **active** while it has had traffic within the last 10 minutes; nothing to configure.
- Proxied traffic is counted per address in the dynamic sets `acct_up4/6` and `acct_dn4/6` (per-element counters).
  Only traffic PassWall2 proxies is counted (conntrack mark equal to PassWall2's `FWMARK`, read from
  `/usr/share/passwall2/nftables.sh`); direct traffic is not included. Elements are kept for a week without traffic.
  The sets are not flushed on reload; the counters reset when the service stops.
- Upgrading from a version that used plain `vpn_seen` sets: the first start replaces them with the maps and
  zeroes the counters once.

## LuCI page

- **Main Switch** and **Natmap qB Direct** on one row. Click a badge to enable / disable. Natmap shows
  *Not Installed* (not clickable) when `/etc/config/natmap` is absent. With Natmap enabled, the badge also tells
  what the watcher is doing (hover it for the full explanation):

  | Badge | Meaning |
  |---|---|
  | green **Enabled · Watching** | the watcher is running and Natmap has a running instance |
  | amber **Enabled · No instances** | the watcher is running, but Natmap has no running instance yet; it picks the ports up once Natmap starts |
  | amber **Enabled · No qB entry** | no enabled Natmap entry is recognised as qBittorrent, so no watcher is running |
- **Traffic Statistics** tab: packets, bytes and current speed of every rule, with a readable action label, and a
  final **Total (all Direct rules)** row: everything the direct rules kept away from PassWall2.
  The qBittorrent rules are only listed while Natmap is installed and **Natmap qB Direct** is enabled.
  The counters of the `dynamic_logic` rules restart from zero whenever the rules are reloaded.
- **VPN Clients** tab: one row per device (hosts sharing a `grp-` / `grp_` tag are one device), with these columns:
  - **Hostname**; hover for the `config host` entries of a grouped device.
  - **IP Address / MAC**: the addresses in use now (IPv4 first, then IPv6), then the MAC they belong to. A device with
    several network cards lists each MAC with its own addresses. A device is active while any of its addresses has
    had traffic (proxied or direct) within 10 minutes.
  - **Traffic / speed of the proxied traffic only** (↑ upload / ↓ download), added up over all addresses, centred so
    the numbers do not jiggle when they change. Hover for the split per address and MAC, with each address's own speed.
  - **Type**: IPv4, IPv6 or both.
  - **Device**: `Server` and every other tag except `VPN` and `grp-...` / `grp_...` (for example `phone`, `pc`), as coloured badges;
    the same tag always has the same colour. The colours follow the LuCI theme, dark mode included.

  A configured VPN device with no traffic for 10 minutes is listed as a grey **Inactive** row with the totals it last
  moved (no speed). It may still be online, e.g. asleep; the page does not try to tell.
  Click a column title to sort; click again to reverse.
- Refreshes every second in place (no scroll jumps), and adapts to the width: table, three-zone layout or cards (traffic and speed move under the Device badges on narrow screens).

## Install

Remove `luci-app-pw2-guard` (and `luci-app-advanced`) first, then install this package. The post-install step
creates `/etc/config/bypass` with both switches off, restarts `rpcd` and, if enabled, the service. Switch it on
from the page, or:

```sh
uci set bypass.global.enable_bypass=1; uci commit bypass
/etc/init.d/bypass enable; /etc/init.d/bypass start
```

Tag the devices in **Network → DHCP and DNS → Static Leases** (`VPN`, optionally `Server`, a type such as `phone`,
and `grp-<Name>` for a device with several cards), or in `/etc/config/dhcp`:

```
config host
	option name 'macbook-wifi'
	list mac 'aa:bb:cc:dd:ee:ff'
	list tag 'VPN'
	list tag 'pc'
	list tag 'grp-MacBook'

config host
	option name 'macbook-lan'
	list mac '11:22:33:44:55:66'
	list tag 'VPN'
	list tag 'pc'
	list tag 'grp-MacBook'
```

The two entries above show up as one device, **MacBook**, with both MACs.

To remove everything cleanly: `apk del luci-app-bypass --purge` (or `opkg remove luci-app-bypass`).

## Notes

- Connections handled by **flow offloading** bypass the netfilter hooks after their first packets and are not
  counted, so the numbers can be too low.
- `/etc/init.d/bypass` keeps one idle `/bin/sleep 2147483647` process under procd so that `status` reports *running*;
  the rules need no process.
- The STUN server list used with Natmap is fetched with `curl`.
- The Natmap watcher polls every 5 seconds without starting any program besides `sleep`; a port change reaches
  the rules within that time. Nothing is written to flash.
- Requires `rpcd-mod-ucode`, `ucode-mod-fs`, `ucode-mod-uci` and a PassWall2 install on firewall4 (nft).
- The repository name must equal the package name (`luci-app-bypass`) for the CI workflow.

## License

GPL-3.0 (see `LICENSE`).
