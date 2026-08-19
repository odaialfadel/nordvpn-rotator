# Changelog

Versions match `VERSION=` in `nordvpn-rotate.sh`, which is also the version
`opkg status nordvpn-rotate` reports on the router.

## v0.2.0

First tagged release. The rotator's decision logic is unchanged from what has
been running on my own router for weeks — everything new here is about getting
it onto a router without a scp dance, and proving it lands correctly.

### Packaging

- **`nordvpn-rotate_0.2.0-1_all.ipk`** — a real opkg package. It installs with
  `opkg install`, shows up in the GL.iNet panel's Plug-ins list, keeps a
  modified `/etc/nordvpn-rotate.conf` across upgrades (it is a declared
  conffile), and removes cleanly with `opkg remove`, cron lines included.
- **`install-remote.sh`** — one line over ssh installs the latest release. It
  resolves the release, verifies the `.ipk` against the published
  `sha256sums`, and only then hands the file to opkg. `opkg` cannot install
  from a URL, which is the only reason this script exists.
- **The release doubles as an opkg feed.** `Packages` and `Packages.gz` are
  published as release assets, so `releases/latest/download` works as a
  `src/gz` line and `opkg install nordvpn-rotate` resolves by name.
- The package now declares `Depends: curl, jsonfilter, uci, ubus` — the four
  stock packages the script cannot work without. `wireguard-tools` is
  deliberately not a dependency: without `wg` the health check falls back to
  ping and the rotator still works.
- `License: MIT` is recorded in the package metadata.

### Fixed

- **CRLF on Windows checkouts.** The blobs in git were always LF, but with
  git's `core.autocrlf=true` (the Windows default) a checkout produced CRLF
  files, and scp-ing those to a router gave an `install.sh` that busybox ash
  refuses to parse: `syntax error: unexpected word`. `.gitattributes` now
  pins `eol=lf` for every text file, and CI fails on a stray CR.
  Existing Windows clones need one `git rm --cached -r . && git reset --hard`
  to pick the new checkout rules up.
- **`test/run-local.sh` could not run on Linux or in CI.** It called `python`,
  which Ubuntu does not ship — only `python3`. It now probes for a working
  Python 3 by output rather than exit status, because Windows ships a `python3`
  shim that prints "not found" and still exits 0.

### Tests

- **`test/test-package.sh`** (51 checks) — ipk envelope, control metadata,
  maintainer scripts, payload paths and modes, feed index arithmetic
  (`Size`/`SHA256sum`/`MD5Sum`/`Installed-Size` all recomputed and compared).
  Runs in Git Bash on Windows; needs no router and no root.
- **`test/test-openwrt.sh`** (58 checks) — unpacks a real OpenWrt rootfs and
  drives the real `opkg` binary through install, reinstall, conffile
  preservation and removal, then through a served feed, then through
  `install-remote.sh` against a mock GitHub release, including a tampered
  download that must be refused. Also runs `nordvpn-rotate.sh check` under real
  busybox ash, which is the shell Git Bash cannot imitate.
- CI runs all three suites on every push, against **OpenWrt 21.02.7 and
  23.05.5** — the two bases GL.iNet 4.x firmware is built on.
