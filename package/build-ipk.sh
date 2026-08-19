#!/bin/sh
# build-ipk.sh — build dist/nordvpn-rotate_<version>-<rev>_all.ipk on your PC.
# Needs only GNU tar + gzip (Git Bash on Windows, or any Linux/WSL):
#   sh package/build-ipk.sh        rev defaults to 1
#   sh package/build-ipk.sh 2      bump the package revision without a version bump
#
# The ipk is the OpenWrt tar.gz form: debian-binary + control.tar.gz + data.tar.gz.
# Everything is shell, so Architecture: all — no SDK or cross-compile involved.
# Install on the router:
#   scp dist/nordvpn-rotate_*_all.ipk root@192.168.8.1:/tmp/
#   ssh root@192.168.8.1 "opkg install /tmp/nordvpn-rotate_*_all.ipk"
# Remove: opkg remove nordvpn-rotate  (or from the GL panel's Plug-ins list)

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=nordvpn-rotate
REV="${1:-1}"

VER=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/nordvpn-rotate.sh")
[ -n "$VER" ] || { echo "could not read VERSION= from nordvpn-rotate.sh"; exit 1; }

BUILD="$ROOT/dist/.build"
OUT="$ROOT/dist/${PKG}_${VER}-${REV}_all.ipk"
rm -rf "$BUILD"
mkdir -p "$BUILD/data/usr/bin" "$BUILD/data/etc" "$BUILD/data/www/cgi-bin" "$BUILD/control"

# copy payload, stripping Windows line endings (safe no-op otherwise)
sed 's/\r$//' "$ROOT/nordvpn-rotate.sh"     > "$BUILD/data/usr/bin/nordvpn-rotate.sh"
sed 's/\r$//' "$ROOT/nordvpn-rotate.conf"   > "$BUILD/data/etc/nordvpn-rotate.conf"
sed 's/\r$//' "$ROOT/rotator-dashboard.cgi" > "$BUILD/data/www/cgi-bin/rotator"

# control + maintainer scripts (also stripped)
# Depends lists the four stock packages the script genuinely cannot work
# without; all four are part of every OpenWrt/GL.iNet 4.x base image and are
# recorded in opkg's status file, so this resolves without a feed configured.
# wireguard-tools (wg) is deliberately absent — without it the health check
# falls back to ping and the rotator still works.
cat > "$BUILD/control/control" <<EOF
Package: $PKG
Version: $VER-$REV
Depends: curl, jsonfilter, uci, ubus
Architecture: all
Maintainer: Odai Al Fadel
License: MIT
Section: net
Priority: optional
Description: Load-threshold NordVPN WireGuard server rotation for GL.iNet 4.x.
 Cron runs one decision cycle every 30 min and switches the peer endpoint
 only when the current server is overloaded or dropped from NordVPN's
 recommendations. Ships with DRY_RUN=1 (log-only) until configured.
EOF
for f in postinst prerm postrm conffiles; do
    sed 's/\r$//' "$ROOT/package/$f" > "$BUILD/control/$f"
done

printf '2.0\n' > "$BUILD/debian-binary"

# tar members are added one by one so each gets an explicit mode, and
# --owner/--group=0 keeps the archive reproducible regardless of build host
TAR="tar --owner=0 --group=0 --numeric-owner"
(
    cd "$BUILD/data"
    $TAR --mode=0755 --no-recursion -cf ../data.tar \
        ./usr ./usr/bin ./usr/bin/nordvpn-rotate.sh \
        ./www ./www/cgi-bin ./www/cgi-bin/rotator ./etc
    $TAR --mode=0644 -rf ../data.tar ./etc/nordvpn-rotate.conf
    gzip -n ../data.tar
)
(
    cd "$BUILD/control"
    $TAR --mode=0644 -cf ../control.tar ./control ./conffiles
    $TAR --mode=0755 -rf ../control.tar ./postinst ./prerm ./postrm
    gzip -n ../control.tar
)
(
    cd "$BUILD"
    $TAR -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz
)
rm -rf "$BUILD"

echo "built: $OUT"
