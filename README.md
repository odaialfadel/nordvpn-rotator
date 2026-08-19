# nordvpn-rotate

A small shell script and dashboard that keep a GL.iNet router on a fast
NordVPN server, instead of the one it happened to pick last month.

[![ci](https://github.com/odaialfadel/nordvpn-rotator/actions/workflows/ci.yml/badge.svg)](https://github.com/odaialfadel/nordvpn-rotator/actions/workflows/ci.yml)
[![latest release](https://img.shields.io/github/v/release/odaialfadel/nordvpn-rotator?label=release)](https://github.com/odaialfadel/nordvpn-rotator/releases/latest)

Installs as an opkg package, so it shows up in the GL panel's Plug-ins list —
one line over ssh, or a `.ipk` you can inspect first. [Install](#install).

| Dark | Light |
|------|-------|
| ![dashboard, dark](docs/dashboard-dark.png) | ![dashboard, light](docs/dashboard-light.png) |

## Why this exists

My whole household's traffic goes through one NordVPN WireGuard tunnel on a
GL.iNet router. The GL panel picks a server once and then never thinks about
it again. A few weeks later that server sits at 70% load, evening streaming
turns into a slideshow, and the VPN everyone pays for feels like dial-up.

NordVPN's phone and desktop apps re-pick servers all the time. Routers don't
get an app. This is the missing piece: a cron job that asks NordVPN's public
recommendations API every 30 minutes whether your server is still a good
idea, and moves the tunnel when the answer is clearly no.

## The version for non-technical people

Think of a VPN server as a checkout lane at the supermarket. Your router
picked a lane once and refuses to change, even when eight people are queuing
in it and the lane next door is empty. This script checks the queues every
half hour and switches lanes when yours is jammed. The internet blips for
about 15 seconds during a switch, and that's the whole cost.

It can also grab a fresh IP address on demand (one button on the dashboard),
which helps when a website has decided it doesn't like the VPN address you
share with a few thousand strangers.

## What it actually does

Every 30 minutes, cron runs one decision cycle:

1. Fetch NordVPN's recommended servers for your country. Public API, no
   account or token needed.
2. Find your current server in that list.
3. Switch only when the current server is at or above the load threshold
   (default 60%) **and** some candidate is at least 15 points lower. Having
   dropped out of the recommended list entirely also counts as a reason.
4. Health-check the new tunnel (WireGuard handshake plus a ping through it).
   If it doesn't come up, roll back to the old server automatically.

There are anti-flap rules so it doesn't bounce around: a minimum dwell time
between switches (default 60 min), the minimum-improvement requirement, and a
cooldown after any failed attempt. A marker file on flash survives reboots,
so a switch interrupted halfway gets repaired on the next cycle.

It never touches your WireGuard private key, DNS, MTU, or the kill switch.
The only thing it ever rewrites is the peer's endpoint and public key — the
same change you'd make by clicking a different server in the GL panel.

And it installs in **dry-run mode**: it logs what it *would* do and touches
nothing until you deliberately arm it.

## Requirements

- A GL.iNet router on firmware 4.x with the NordVPN WireGuard client already
  set up and working in the GL panel. Built and tested on an XE3000
  (firmware 4.8.3); anything with the same `uci`/`ubus`/`jsonfilter` layout
  should behave.
- Nothing else. It uses only tools that ship with the stock firmware —
  `curl`, `jsonfilter`, `uci` and `ubus`, which the package declares as
  dependencies so opkg refuses to install onto a router that is missing one.
  `wg` is optional: without it the health check falls back to ping.

One gotcha I hit: on the XE3000 the WireGuard client interface is
`wgclient1`, not the `wgclient` most forum posts mention. That's what the
`WG_IFACE` setting is for, and `check` (below) will tell you if it's wrong.

## Install

It ships as an opkg package, so the router treats it like any other plug-in: it
appears in the GL.iNet panel's **Plug-ins** list, and `opkg remove` takes it
away again, cron lines included. Pick whichever route suits you — they install
exactly the same files.

### One line over ssh

```bash
ssh root@192.168.8.1 'curl -fsSL https://raw.githubusercontent.com/odaialfadel/nordvpn-rotator/main/install-remote.sh | sh'
```

That looks up the latest release, checks the `.ipk` against the `sha256sums`
published with it, and only then hands the file to `opkg`. Nothing is needed on
your PC. Append a tag to pin a version rather than taking the newest:

```bash
ssh root@192.168.8.1 'curl -fsSL https://raw.githubusercontent.com/odaialfadel/nordvpn-rotator/main/install-remote.sh | sh -s v0.2.0'
```

### A downloaded .ipk

Take `nordvpn-rotate_<version>_all.ipk` from
[Releases](https://github.com/odaialfadel/nordvpn-rotator/releases):

```bash
scp -O nordvpn-rotate_*_all.ipk root@192.168.8.1:/tmp/
```

```bash
ssh root@192.168.8.1 "opkg install /tmp/nordvpn-rotate_*_all.ipk"
```

### As an opkg feed

If you would rather install it by name and pick up later versions with
`opkg upgrade`, point opkg at the releases — that URL always resolves to the
newest one:

```bash
echo 'src/gz nordvpn_rotator https://github.com/odaialfadel/nordvpn-rotator/releases/latest/download' >> /etc/opkg/customfeeds.conf
```

Stock firmware sets `option check_signature` in `/etc/opkg.conf` and this feed
is not usign-signed, so `opkg update` refuses it until that line is commented
out:

```bash
sed -i 's/^option check_signature/# option check_signature/' /etc/opkg.conf
opkg update && opkg install nordvpn-rotate
```

Be aware that switch is global: it lowers the bar for *every* feed on the
router, the official ones included. The two routes above need no such change —
they verify the download by SHA256 before installing — so this one is really
for people who already run their own feeds.

### The old way, loose files

Still supported, and still what `install.sh` is for:

```bash
scp -O nordvpn-rotate.sh nordvpn-rotate.conf rotator-dashboard.cgi install.sh root@192.168.8.1:/tmp/nvr/
```

```bash
ssh root@192.168.8.1 "sh /tmp/nvr/install.sh"
```

`install.sh` does the same runtime setup as the package (cron lines,
`/etc/sysupgrade.conf` entries), but opkg knows nothing about the files, so
they will not show up under Plug-ins and `opkg remove` will not find them.
Reverse it with `sh /tmp/nvr/install.sh uninstall`.

### Then, whichever route you took

```bash
ssh root@192.168.8.1 "/usr/bin/nordvpn-rotate.sh check"
```

`check` is a read-only pre-flight that verifies every assumption on your router
(tools present, interface up, peer section found, API reachable) and prints
OK/WARN/FAIL for each. Nothing is switched yet — the shipped config has
`DRY_RUN=1`.

Now let it run for a couple of days and read its diary:

```bash
ssh root@192.168.8.1 "tail -f /tmp/nordvpn-rotate.log"
```

Lines like `OK: de1478... load 23% (rank 2 of 20)` mean it's happy. Lines like
`DRY-RUN: would switch ...` show what it would have done and why. When those
decisions look sensible to you, arm it.

### Updating

Re-run the one-liner, or `opkg install --force-reinstall` a newer `.ipk`. Your
`/etc/nordvpn-rotate.conf` survives either way — it is a declared conffile, so
opkg leaves an edited one alone.

## Going live

Either set `DRY_RUN=0` in `/etc/nordvpn-rotate.conf`, or do it from the
dashboard. The dashboard is read-only until you give it a password:

```bash
ssh root@192.168.8.1 'umask 077; echo "CHOOSE-A-PASSWORD" > /etc/rotator-dash.secret'
```

After that, `http://192.168.8.1/cgi-bin/rotator` asks for HTTP Basic login
(user `admin` by default — set `DASH_USER` in the conf to change it) and you
get the Force button plus every setting, including the LIVE-mode checkbox.
No secret file, no writes: every button press is refused server-side, so a
fresh install can't be clicked into switching servers by whoever is on your
LAN. Deleting the secret file returns the page to read-only.

## The dashboard

What you're looking at, top to bottom:

- **Current server** — hostname, city, load, its rank in NordVPN's list,
  round-trip time, handshake age, last switch.
- **Decision** — a gauge with the current server, the best candidate, and
  the switch line, plus one sentence saying exactly what the rotator will do
  next and why. If it says "Holding", nothing moves.
- **Candidates** — NordVPN's recommended servers in their ranking order,
  with load and RTT. The RTT is pinged from the router itself once per
  cycle. The current server is reached directly while the others are
  measured through the tunnel, so treat the column as a sanity check, not a
  benchmark.
- **Switch history / recent activity** — the log, colour-coded, newest
  first.

The moon/sun button toggles dark and light mode; the choice sticks per
browser. The page refreshes itself every 60 seconds but politely waits while
you're typing in a settings field.

## Configuration

Everything lives in `/etc/nordvpn-rotate.conf` (shell syntax) and is also
editable from the dashboard once the secret exists.

| Key | Default | Meaning |
|-----|---------|---------|
| `DRY_RUN` | `1` | 1 = log only. Only the exact value `0` arms it; typos stay dry. |
| `COUNTRY_ID` | `81` | NordVPN country id (81 = Germany). List: `api.nordvpn.com/v1/servers/countries` |
| `LOAD_THRESHOLD` | `60` | Switch when the current server's load reaches this % |
| `MIN_IMPROVEMENT` | `15` | ...and a candidate is at least this many points lower |
| `MIN_DWELL_MIN` | `60` | Never switch again within this many minutes |
| `CANDIDATES` | `20` | How many recommended servers to fetch |
| `NIGHTLY_ROTATE` | `0` | 1 = also rotate every night ~04:30 for a fresh IP |
| `WG_IFACE` | `wgclient` | WireGuard client interface (`wgclient1` on the XE3000) |
| `DASH_USER` | `admin` | Dashboard login name |

## Commands

```
nordvpn-rotate.sh run      # one decision cycle (what cron calls)
nordvpn-rotate.sh force    # switch to the best candidate NOW (fresh IP)
nordvpn-rotate.sh nightly  # like force, but only if NIGHTLY_ROTATE=1
nordvpn-rotate.sh check    # read-only pre-flight, run this first
nordvpn-rotate.sh status   # current server, last switch, recent log
```

`force` skips the load and dwell gates but keeps the health check and
rollback, and it respects dry-run.

## Testing

Three suites, none of which need a router.

`test/run-local.sh` runs the real scripts on a normal PC with every router
command mocked (`uci`, `ubus`, `wg`, `ping`, ...) — 74 checks covering the
switch logic, rollback, recovery after interrupted switches, the dashboard
rendering, and the dashboard's auth. It runs in Git Bash on Windows and on
Linux; you need Python 3 and `openssl` on the PATH.

```bash
sh test/run-local.sh
```

`test/test-package.sh` builds the `.ipk` and the feed and picks both apart —
51 checks on the archive envelope, the control metadata, file modes, and the
feed index arithmetic (every `Size`, `SHA256sum` and `Installed-Size` is
recomputed and compared). No root, no router, works on Windows.

```bash
sh test/test-package.sh
```

`test/test-openwrt.sh` is the one that actually proves the package: it unpacks
a real OpenWrt rootfs, chroots in, and drives the **real `opkg` binary**
through install, reinstall, conffile preservation and removal, then through a
served feed, then through `install-remote.sh` against a mock GitHub release —
including a tampered download that has to be refused. It also runs
`nordvpn-rotate.sh check` under real busybox ash, which is the shell Git Bash
cannot imitate and the one that rejects bashisms. Linux and root only.

```bash
sudo sh test/test-openwrt.sh
```

CI runs all three on every push, against OpenWrt 21.02.7 and 23.05.5 — the two
bases GL.iNet 4.x firmware is built on.

## Building the package yourself

```bash
sh package/build-ipk.sh        # -> dist/nordvpn-rotate_<version>_all.ipk
sh package/build-feed.sh       # -> dist/feed/{Packages,Packages.gz,*.ipk}
```

Both need nothing but tar, gzip and coreutils, so Git Bash on Windows is
enough. There is no cross-compiling and no OpenWrt SDK involved: everything in
the package is shell, so it is `Architecture: all` and installs on any
opkg-based firmware. The version comes from `VERSION=` in `nordvpn-rotate.sh`,
and a release is refused if the git tag disagrees with it.

If you want the feed to work without editing `/etc/opkg.conf` on every router,
sign it with your own usign key and install the public half into
`/etc/opkg/keys/` on the routers:

```bash
usign -G -s nvr.sec -p nvr.pub
NVR_USIGN_KEY=nvr.sec sh package/build-feed.sh
```

## Uninstall

If you installed the package:

```bash
ssh root@192.168.8.1 "opkg remove nordvpn-rotate"
```

or use the Plug-ins list in the GL panel. If you installed loose files with
`install.sh`:

```bash
ssh root@192.168.8.1 "sh /tmp/nvr/install.sh uninstall"
```

Either way it removes the script, conf, cron lines, dashboard and state. The
WireGuard peer keeps whatever endpoint it had last; pick a server in the GL
panel if you want a specific one back.

## Fine print

- The recommendations API is public but not officially documented for third
  parties. If NordVPN changes the format, the script refuses to act rather
  than guessing (it parses defensively and dies loudly).
- GL.iNet firmware upgrades tend to wipe `/usr/bin` extras and the crontab.
  Both the package's postinst and `install.sh` register everything in
  `/etc/sysupgrade.conf`, but GL doesn't guarantee honoring it — re-run the
  install after a firmware upgrade and check `opkg list-installed | grep
  nordvpn`.
- The package is `Architecture: all` — it is shell, so there is nothing
  compiled to match against your router's CPU. Tested against OpenWrt 21.02
  and 23.05 userspace, which is what GL.iNet 4.x is built on. OpenWrt 24.10+
  replaced opkg with apk and is not covered.
- All German NordVPN servers currently share one WireGuard public key, so a
  switch is just an endpoint change. The script still updates the key when
  it differs, so other countries should work too.
- This moves your traffic between NordVPN's servers. It can't make a bad
  line good — it just stops you from staying in the slowest queue.

MIT licensed. Built for my own router; issues and PRs welcome, but I can
only test on GL.iNet 4.x.
