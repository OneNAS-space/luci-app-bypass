# luci-app-pw2-guard

Bypass logic for PassWall2 routers (nft table `inet bypass_logic`) with a LuCI status page
(**Services → PW2 Guard**). Split out of `luci-app-advanced`. JavaScript view plus a small rpcd ucode plugin;
**no translations are shipped** (strings are wrapped in `_()` if you want to add your own).

## What it does

- DHCP hosts tagged `VPN` (static leases in `/etc/config/dhcp`) are handed to PassWall2; everything else goes direct
  (the catch-all rule `Non-VPN-Client-Direct`, which only sees LAN traffic of devices that are not VPN clients).
  A host also tagged `Server` additionally has its connections to remote port 7844 (TCP and UDP) sent direct. These are the control connections that
  set up peer-to-peer tunnels (Cloudflare tunnels, NetBird, WireGuard and similar).
  The client sets are rebuilt automatically when `dhcp`, `passwall2` or the WAN interfaces change.
- Optional **Natmap qBittorrent port integration**: when the Natmap port changes, the firewall rules follow.
- Per-client **traffic accounting** (nft sets with per-element counters), used by the page below. It counts only
  the traffic PassWall2 actually proxies (conntrack mark equal to PassWall2's `FWMARK`); direct traffic, whether from
  `bypass_guard`'s own rules or from PassWall2's direct rules, is not included. This assumes PassWall2 marks proxied
  flows, which is the case for TPROXY and for all UDP.

## LuCI page

- **Main Switch** and **Natmap qB-port Direct** badges on one row. Click to enable / disable. Natmap shows
  Enabled / Disabled, or *Not Installed* (not clickable) when `/etc/config/natmap` is absent.
- **Traffic Statistics** tab: packets, bytes and current speed of every rule, with a readable action label.
  Unlike the VPN Clients tab it covers the direct rules too.
  The qBittorrent rules (`qB-*` and the dual-stack port forwards) are only listed while Natmap is installed and
  **Natmap qB-port Direct** is enabled.
- **VPN Clients** tab: hostname, IP address over MAC, **traffic and speed of the proxied traffic only** (↑ upload /
  ↓ download; speed colours match the realtime bandwidth page: download blue, upload green), IPv4 / IPv6 type and
  the `VPN` / `Server` tags.
  Click a column title to sort, like in the file manager: the arrow shows the direction, clicking the same title again
  reverses it. Hostname, IP Address, MAC, Traffic (total), Speed (current), Type and Tag are separate sort targets
  (IP Address and MAC, Traffic and Speed share a header cell but sort independently). Traffic and Speed start
  with the largest first. The titles only exist in the table layout; the stacked card layouts have no header row.
- Refreshes every 3 s **in place**: no scroll jumps, tabular digits and fixed minimum widths keep the columns still.
- Responsive without horizontal scrolling, following the real content width (sidebar themes such as Argon included):
  a native table when wide, a three-zone layout on medium widths (fixed tracks, so the middle zone starts at the same x on every row),
  and stacked cards when narrow.

## Install / upgrade

- **From luci-app-advanced:** remove it first (`apk del luci-app-advanced --purge`, or `opkg remove luci-app-advanced`), then install this package.
  The two switches are imported from `/etc/config/advanced` into `/etc/config/pw2_guard`; the old file is left untouched.
- **From an older luci-app-pw2-guard:** just install the new one. The post-install step restarts `bypass_guard` (if enabled)
  and `rpcd`, so new rules and the new rpcd plugin are active immediately. Web sessions are logged out once.
- If you replace `/etc/init.d/bypass_guard` and `natmap_bypass.sh` by hand, they must use the new config name:
  `CONF="pw2_guard"` in the init script and `pw2_guard.global.enable_natmap` in `natmap_bypass.sh`.

## Notes

- Counters are per client IP (a host with both IPv4 and IPv6 addresses shows one row per address) and reset when the
  service is stopped or restarted. Only proxied traffic entering or leaving the LAN is counted, not LAN-to-LAN routing.
- Connections handled by **flow offloading** bypass the netfilter forward hook and are not counted, so the numbers can be too low.
- `bypass_guard` keeps one idle `/bin/sleep 2147483647` process under procd so that `status` reports *running*;
  the actual work is done by the nft rules, which need no process.
- Requires `rpcd-mod-ucode`, `ucode-mod-fs`, `ucode-mod-uci`.
- The repository name must equal the package name (`luci-app-pw2-guard`) for the CI workflow.

## License

GPL-3.0 (see `LICENSE`).
