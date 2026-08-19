#!/bin/sh
# test-package.sh — structural checks on the built .ipk and the opkg feed.
#
#   sh test/test-package.sh
#
# Runs anywhere tar/gzip/sha256sum exist, Git Bash on Windows included, and
# needs neither a router nor root. It answers "is this a well-formed opkg
# package and a well-formed feed index" — test/test-openwrt.sh answers "does
# opkg actually install it", which needs Linux.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=nordvpn-rotate
WORK="$ROOT/dist/.pkgtest"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
has() { # label, pattern, file
    if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (no /$2/ in $(basename "$3"))"; fi
}

trap 'rm -rf "$WORK"' EXIT INT TERM

echo "=== 0. build"
sh "$ROOT/package/build-ipk.sh"  >/dev/null || { echo "build-ipk.sh failed";  exit 2; }
sh "$ROOT/package/build-feed.sh" >/dev/null || { echo "build-feed.sh failed"; exit 2; }
IPK=$(ls "$ROOT"/dist/${PKG}_*_all.ipk | head -n 1)
IPK_NAME=$(basename "$IPK")
VER=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/nordvpn-rotate.sh")
ok "built $IPK_NAME"

case "$IPK_NAME" in
    ${PKG}_${VER}-*_all.ipk) ok "filename carries VERSION=$VER from nordvpn-rotate.sh" ;;
    *) bad "filename $IPK_NAME does not match VERSION=$VER" ;;
esac

rm -rf "$WORK"; mkdir -p "$WORK/c" "$WORK/d"
tar xzf "$IPK" -C "$WORK"

echo "=== 1. ipk envelope"
for m in debian-binary control.tar.gz data.tar.gz; do
    [ -f "$WORK/$m" ] && ok "contains $m" || bad "missing $m"
done
[ "$(cat "$WORK/debian-binary" 2>/dev/null)" = "2.0" ] && ok "debian-binary says 2.0" || bad "debian-binary is not 2.0"

tar xzf "$WORK/control.tar.gz" -C "$WORK/c"
tar xzf "$WORK/data.tar.gz"    -C "$WORK/d"

echo "=== 2. control metadata"
CTRL="$WORK/c/control"
has "Package field"       "^Package: $PKG\$"        "$CTRL"
has "Version field"       "^Version: $VER-"          "$CTRL"
has "Architecture: all"   "^Architecture: all\$"     "$CTRL"
has "Section: net"        "^Section: net\$"          "$CTRL"
has "License: MIT"        "^License: MIT\$"          "$CTRL"
has "Maintainer field"    "^Maintainer: "            "$CTRL"
has "Description field"   "^Description: "           "$CTRL"
has "Depends on curl"     "^Depends:.*curl"          "$CTRL"
has "Depends on jsonfilter" "^Depends:.*jsonfilter"  "$CTRL"
# a continuation line must start with a space or opkg swallows the next field
awk '/^Description:/{d=1;next} d&&/^[^ ]/{print "BADCONT"} ' "$CTRL" | grep -q BADCONT \
    && bad "Description continuation lines are malformed" || ok "Description continuation is well-formed"

echo "=== 3. maintainer scripts"
for s in postinst prerm postrm; do
    if [ -f "$WORK/c/$s" ]; then
        sh -n "$WORK/c/$s" 2>/dev/null && ok "$s parses" || bad "$s has a syntax error"
    else
        bad "$s missing from control.tar.gz"
    fi
done
has "conffiles lists the config" "^/etc/nordvpn-rotate.conf\$" "$WORK/c/conffiles"

echo "=== 4. payload"
for p in usr/bin/nordvpn-rotate.sh www/cgi-bin/rotator etc/nordvpn-rotate.conf; do
    [ -f "$WORK/d/$p" ] && ok "payload has /$p" || bad "payload missing /$p"
done
[ -f "$WORK/d/usr/bin/nordvpn-rotate.sh" ] && { sh -n "$WORK/d/usr/bin/nordvpn-rotate.sh" 2>/dev/null \
    && ok "packaged nordvpn-rotate.sh parses" || bad "packaged nordvpn-rotate.sh has a syntax error"; }
[ -f "$WORK/d/www/cgi-bin/rotator" ] && { sh -n "$WORK/d/www/cgi-bin/rotator" 2>/dev/null \
    && ok "packaged dashboard parses" || bad "packaged dashboard has a syntax error"; }
has "shipped conf is dry-run" "^DRY_RUN=1" "$WORK/d/etc/nordvpn-rotate.conf"

# the whole point of .gitattributes: a CR here is a broken router install
crc=$(find "$WORK/d" "$WORK/c" -type f -exec cat {} + | tr -dc '\r' | wc -c | tr -d ' ')
[ "$crc" = 0 ] && ok "no CR bytes anywhere in the package" || bad "$crc CR bytes in the package"

# tar records modes even though the extract may not preserve them on Windows
tar tzvf "$WORK/data.tar.gz" | grep -q '^-rwxr-xr-x.*usr/bin/nordvpn-rotate.sh' \
    && ok "script is 0755 in the archive" || bad "script is not 0755 in the archive"
tar tzvf "$WORK/data.tar.gz" | grep -q '^-rw-r--r--.*etc/nordvpn-rotate.conf' \
    && ok "conf is 0644 in the archive" || bad "conf is not 0644 in the archive"
tar tzvf "$WORK/control.tar.gz" | grep -q '^-rwxr-xr-x.*postinst' \
    && ok "postinst is 0755 in the archive" || bad "postinst is not 0755 in the archive"

echo "=== 5. feed index"
FEED="$ROOT/dist/feed"
for f in Packages Packages.gz "$IPK_NAME"; do
    [ -f "$FEED/$f" ] && ok "feed has $f" || bad "feed missing $f"
done
gzip -dc "$FEED/Packages.gz" > "$WORK/Packages.un" 2>/dev/null \
    && { cmp -s "$WORK/Packages.un" "$FEED/Packages" && ok "Packages.gz matches Packages" \
         || bad "Packages.gz does not match Packages"; } \
    || bad "Packages.gz is not valid gzip"

has "index Filename"  "^Filename: $IPK_NAME\$" "$FEED/Packages"
has "index Package"   "^Package: $PKG\$"        "$FEED/Packages"
has "index has Depends" "^Depends: "            "$FEED/Packages"

want_size=$(wc -c < "$FEED/$IPK_NAME" | tr -d ' ')
got_size=$(sed -n 's/^Size: //p' "$FEED/Packages" | head -n 1)
[ "$want_size" = "$got_size" ] && ok "index Size matches the file ($want_size)" || bad "index Size $got_size != $want_size"

want_sha=$(sha256sum "$FEED/$IPK_NAME" | awk '{print $1}')
got_sha=$(sed -n 's/^SHA256sum: //p' "$FEED/Packages" | head -n 1)
[ "$want_sha" = "$got_sha" ] && ok "index SHA256sum matches the file" || bad "index SHA256sum is wrong"

want_md5=$(md5sum "$FEED/$IPK_NAME" | awk '{print $1}')
got_md5=$(sed -n 's/^MD5Sum: //p' "$FEED/Packages" | head -n 1)
[ "$want_md5" = "$got_md5" ] && ok "index MD5Sum matches the file" || bad "index MD5Sum is wrong"

want_isz=$(find "$WORK/d" -type f -exec ls -ln {} + | awk '{s+=$5} END {print s+0}')
got_isz=$(sed -n 's/^Installed-Size: //p' "$FEED/Packages" | head -n 1)
[ "$want_isz" = "$got_isz" ] && ok "index Installed-Size matches the payload ($want_isz)" \
                             || bad "index Installed-Size $got_isz != $want_isz"

# opkg splits stanzas on a blank line
tail -c 2 "$FEED/Packages" | od -An -c | grep -q '\\n  *\\n' \
    && ok "index ends with a blank line" || bad "index does not end with a blank line"

echo "=== 6. repo shell scripts parse"
for s in nordvpn-rotate.sh install.sh install-remote.sh rotator-dashboard.cgi \
         package/build-ipk.sh package/build-feed.sh package/postinst package/prerm package/postrm; do
    if [ -f "$ROOT/$s" ]; then
        sh -n "$ROOT/$s" 2>/dev/null && ok "$s parses" || bad "$s has a syntax error"
    else
        bad "$s is missing"
    fi
done

echo
echo "==="
echo "result: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
