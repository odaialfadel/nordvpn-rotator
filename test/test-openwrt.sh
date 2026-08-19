#!/bin/sh
# test-openwrt.sh — end-to-end package test against a REAL OpenWrt userspace.
#
# Unpacks an OpenWrt rootfs, chroots into it and drives the actual opkg binary
# through install / reinstall / remove, then serves dist/feed over HTTP and does
# the same again through "opkg update && opkg install nordvpn-rotate", then runs
# install-remote.sh against a mock GitHub release. Same binaries the router
# runs — busybox ash included, which is the shell that actually rejects the
# bashisms Git Bash lets through in run-local.sh.
#
#   sudo sh test/test-openwrt.sh
#
# Env:
#   OWRT_VERSION   OpenWrt release to test against   (default 23.05.5)
#   OWRT_ROOTFS    path to an already-downloaded rootfs tarball
#   OWRT_CACHE     where to keep downloads           (default /tmp/owrt-cache)
#   OWRT_PORT      base port for the two test servers (default 8731)
#
# Needs root (chroot) plus tar/gzip/curl/python3 on the host. The first run
# downloads a ~4 MB rootfs and adds curl to it from the OpenWrt feed, then
# caches the result; later runs are offline and fast.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION="${OWRT_VERSION:-23.05.5}"
CACHE="${OWRT_CACHE:-/tmp/owrt-cache}"
WORK="${TMPDIR:-/tmp}/nvr-owrt-test.$$"
R="$WORK/root"
PORT="${OWRT_PORT:-8731}"
GHPORT=$((PORT + 1))
PKG=nordvpn-rotate

pass=0; fail=0; skip=0
ok()    { echo "PASS: $1"; pass=$((pass + 1)); }
bad()   { echo "FAIL: $1"; fail=$((fail + 1)); }
skipit(){ echo "SKIP: $1"; skip=$((skip + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
cr()    { chroot "$R" /bin/sh -c "$1"; }
crq()   { chroot "$R" /bin/sh -c "$1" >/dev/null 2>&1; }

FEED_PID=""; GH_PID=""
cleanup() {
    [ -n "$FEED_PID" ] && kill "$FEED_PID" 2>/dev/null
    [ -n "$GH_PID" ]   && kill "$GH_PID"   2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" = 0 ] || { echo "must run as root (chroot); try: sudo sh $0"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed to serve the test feed"; exit 2; }

make_dev() { # $1 = rootfs — the tarball ships an empty /dev, and a router
    # populates it from devtmpfs at boot. Without /dev/urandom the mbedTLS
    # inside curl on 21.02 dies with "error initializing curl library".
    # mknod rather than a bind mount so cleanup stays a plain rm -rf.
    mkdir -p "$1/dev"
    [ -c "$1/dev/null" ]    || mknod -m 666 "$1/dev/null"    c 1 3 2>/dev/null
    [ -c "$1/dev/zero" ]    || mknod -m 666 "$1/dev/zero"    c 1 5 2>/dev/null
    [ -c "$1/dev/random" ]  || mknod -m 666 "$1/dev/random"  c 1 8 2>/dev/null
    [ -c "$1/dev/urandom" ] || mknod -m 666 "$1/dev/urandom" c 1 9 2>/dev/null
}

wait_for_url() { # url — poll instead of sleeping a fixed amount
    i=0
    while [ "$i" -lt 100 ]; do
        curl -fsS "$1" -o /dev/null 2>/dev/null && return 0
        i=$((i + 1)); sleep 0.1
    done
    return 1
}

# ------------------------------------------------------------- rootfs --------
mkdir -p "$CACHE"
BASE="${OWRT_ROOTFS:-$CACHE/openwrt-$VERSION-x86-64-rootfs.tar.gz}"
READY="$CACHE/openwrt-$VERSION-x86-64-provisioned.tar.gz"

if [ ! -f "$BASE" ]; then
    URL="https://downloads.openwrt.org/releases/$VERSION/targets/x86/64/openwrt-$VERSION-x86-64-rootfs.tar.gz"
    echo "downloading $URL"
    curl -fsSL -o "$BASE.part" "$URL" || { echo "rootfs download failed"; exit 2; }
    mv "$BASE.part" "$BASE"
fi

HAVE_CURL=1
if [ ! -f "$READY" ]; then
    # The stock rootfs has no HTTP client at all. The router does, so add one
    # here too — otherwise `nordvpn-rotate.sh check` cannot be exercised.
    echo "provisioning a rootfs with curl (one-off, then cached)"
    P="$WORK/provision"
    mkdir -p "$P/tmp/lock"
    tar xzf "$BASE" -C "$P"
    make_dev "$P"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$P/tmp/resolv.conf"
    # the base image has no CA bundle wired into opkg; the feeds are usign-signed
    # either way, so plain HTTP is safe here and avoids a TLS chicken-and-egg
    sed -i 's#https://#http://#' "$P/etc/opkg/distfeeds.conf"
    if chroot "$P" /bin/sh -c "opkg update && opkg install curl" >/dev/null 2>&1; then
        rm -f "$P/tmp/resolv.conf"
        rm -rf "$P/var/opkg-lists" "$P/tmp/opkg-lists"
        ( cd "$P" && tar czf "$READY.part" . ) && mv "$READY.part" "$READY"
    else
        echo "  (no network for the OpenWrt feed — falling back to the bare rootfs)"
        HAVE_CURL=0
        READY="$BASE"
    fi
    rm -rf "$P"
fi
# a cached provisioned image always has curl; a fallback to $BASE never does
[ "$READY" = "$BASE" ] && HAVE_CURL=0

# ---------------------------------------------------------------- build ------
sh "$ROOT/package/build-ipk.sh"  >/dev/null || { echo "build-ipk.sh failed";  exit 2; }
sh "$ROOT/package/build-feed.sh" >/dev/null || { echo "build-feed.sh failed"; exit 2; }
IPK=$(ls "$ROOT"/dist/${PKG}_*_all.ipk | head -n 1)
IPK_NAME=$(basename "$IPK")
VER=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/nordvpn-rotate.sh")
echo "testing $IPK_NAME against OpenWrt $VERSION (curl in rootfs: $HAVE_CURL)"
echo

fresh_root() {
    rm -rf "$R"; mkdir -p "$R"
    tar xzf "$READY" -C "$R"
    mkdir -p "$R/tmp/lock" "$R/etc/crontabs" "$R/www/cgi-bin" "$R/tmp/dl"
    make_dev "$R"
    # nothing in these tests should ever reach the real OpenWrt feeds
    : > "$R/etc/opkg/distfeeds.conf"
    cp "$IPK" "$R/tmp/dl/"
}

# =============================================================================
echo "=== 1. opkg install on a clean router"
fresh_root
out=$(cr "opkg install /tmp/dl/$IPK_NAME" 2>&1)
echo "$out" | sed 's/^/    | /'
echo "$out" | grep -q "Configuring $PKG" && ok "opkg reports Configuring" || bad "opkg did not configure the package"
crq "opkg list-installed | grep -q '^$PKG '";          check "listed by opkg list-installed" $?
crq "opkg status $PKG | grep -q 'Status:.*installed'"; check "opkg status says installed" $?
crq "opkg status $PKG | grep -q '^Version: $VER-'";    check "installed version is $VER" $?

echo "=== 2. payload landed at the right paths with the right modes"
for spec in "/usr/bin/nordvpn-rotate.sh 755" "/www/cgi-bin/rotator 755" "/etc/nordvpn-rotate.conf 644"; do
    p=${spec% *}; m=${spec#* }
    if [ -f "$R$p" ]; then
        got=$(stat -c '%a' "$R$p")
        [ "$got" = "$m" ] && ok "$p present, mode $m" || bad "$p mode $got, expected $m"
    else
        bad "$p missing"
    fi
done
crq "opkg files $PKG | grep -q /usr/bin/nordvpn-rotate.sh"; check "opkg files lists the script" $?

echo "=== 3. no CR bytes survived into the installed files"
crc=$(cat "$R/usr/bin/nordvpn-rotate.sh" "$R/etc/nordvpn-rotate.conf" "$R/www/cgi-bin/rotator" | tr -dc '\r' | wc -c)
[ "$crc" -eq 0 ] && ok "installed files are LF-clean" || bad "$crc CR bytes in installed files"

echo "=== 4. postinst wired up cron and sysupgrade.conf"
grep -qF "/usr/bin/nordvpn-rotate.sh run"     "$R/etc/crontabs/root"  && ok "cron run entry added"     || bad "cron run entry missing"
grep -qF "/usr/bin/nordvpn-rotate.sh nightly" "$R/etc/crontabs/root"  && ok "cron nightly entry added" || bad "cron nightly entry missing"
grep -qxF "/usr/bin/nordvpn-rotate.sh"        "$R/etc/sysupgrade.conf" && ok "script in sysupgrade.conf" || bad "script not in sysupgrade.conf"
grep -qxF "/etc/nordvpn-rotate.conf"          "$R/etc/sysupgrade.conf" && ok "conf in sysupgrade.conf"   || bad "conf not in sysupgrade.conf"
[ "$(grep -c 'nordvpn-rotate.sh run' "$R/etc/crontabs/root")" = 1 ] && ok "exactly one run entry" || bad "duplicate cron entries"

echo "=== 4b. declared dependencies resolve against a stock image"
crq "opkg status $PKG | grep -q 'Depends:.*curl'"; check "control declares curl as a dependency" $?
for d in curl jsonfilter uci ubus; do
    crq "opkg list-installed | grep -q \"^$d \"" && ok "dependency '$d' satisfied by the base image" \
                                                 || bad "dependency '$d' is not an installed package"
done

echo "=== 5. ships disarmed"
grep -q '^DRY_RUN=1' "$R/etc/nordvpn-rotate.conf" && ok "DRY_RUN=1 in the shipped conf" || bad "shipped conf is not dry-run"

echo "=== 6. parses and runs under real busybox ash"
crq "/bin/sh -n /usr/bin/nordvpn-rotate.sh"; check "nordvpn-rotate.sh parses under ash" $?
crq "/bin/sh -n /www/cgi-bin/rotator";       check "rotator-dashboard.cgi parses under ash" $?
if [ "$HAVE_CURL" = 1 ]; then
    out=$(cr "/usr/bin/nordvpn-rotate.sh check" 2>&1)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q 'OK     tool: jsonfilter' && ok "check detects jsonfilter" || bad "check missed jsonfilter"
    echo "$out" | grep -q 'OK     tool: uci'        && ok "check detects uci"        || bad "check missed uci"
    echo "$out" | grep -q 'OK     cron entry present' && ok "check sees the cron entry postinst wrote" || bad "check did not see the cron entry"
    # the interpreter's own complaints, not the script's OK/WARN/FAIL verdicts
    echo "$out" | grep -qE 'syntax error|bad substitution|Illegal option|not expected' \
        && bad "ash reported shell errors in check" || ok "no ash shell errors in check"
    out=$(cr "/usr/bin/nordvpn-rotate.sh status" 2>&1)
    echo "$out" | grep -qE 'syntax error|bad substitution' && bad "ash shell errors in status" || ok "status runs clean under ash"
else
    skipit "check/status under ash (no curl in the test rootfs)"
fi

echo "=== 7. reinstall is idempotent"
crq "opkg install --force-reinstall /tmp/dl/$IPK_NAME"; check "force-reinstall succeeds" $?
[ "$(grep -c 'nordvpn-rotate.sh run' "$R/etc/crontabs/root")" = 1 ] && ok "still exactly one run entry" || bad "reinstall duplicated cron entries"
[ "$(grep -c '^/usr/bin/nordvpn-rotate.sh$' "$R/etc/sysupgrade.conf")" = 1 ] && ok "no duplicate sysupgrade entry" || bad "reinstall duplicated sysupgrade entries"

echo "=== 8. a user-edited conf survives reinstall (conffiles)"
sed -i 's/^DRY_RUN=1/DRY_RUN=0/; s/^COUNTRY_ID=81/COUNTRY_ID=228/' "$R/etc/nordvpn-rotate.conf"
crq "opkg install --force-reinstall /tmp/dl/$IPK_NAME"
grep -q '^DRY_RUN=0'      "$R/etc/nordvpn-rotate.conf" && ok "edited DRY_RUN kept"     || bad "reinstall reset DRY_RUN"
grep -q '^COUNTRY_ID=228' "$R/etc/nordvpn-rotate.conf" && ok "edited COUNTRY_ID kept"  || bad "reinstall reset COUNTRY_ID"

echo "=== 9. opkg remove runs prerm/postrm and cleans up"
echo "*/5 * * * * /usr/bin/other-job" >> "$R/etc/crontabs/root"
cr "opkg remove $PKG" 2>&1 | sed 's/^/    | /'
[ -f "$R/usr/bin/nordvpn-rotate.sh" ] && bad "script left behind"    || ok "script removed"
[ -f "$R/www/cgi-bin/rotator" ]       && bad "dashboard left behind" || ok "dashboard removed"
grep -q 'nordvpn-rotate' "$R/etc/crontabs/root"   && bad "cron entries left behind" || ok "cron entries removed"
grep -q 'other-job'      "$R/etc/crontabs/root"   && ok "unrelated cron job preserved" || bad "prerm ate an unrelated cron job"
grep -q 'nordvpn-rotate' "$R/etc/sysupgrade.conf" && bad "sysupgrade.conf entries left" || ok "sysupgrade.conf cleaned"
crq "opkg list-installed | grep -q '^$PKG '" && bad "still listed after remove" || ok "no longer listed by opkg"

# =============================================================================
echo
echo "=== 10. install through an opkg FEED"
fresh_root
( cd "$ROOT/dist/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
FEED_PID=$!
wait_for_url "http://127.0.0.1:$PORT/Packages.gz" && ok "feed server up" || bad "feed server never came up"
echo "src/gz nvr_test http://127.0.0.1:$PORT" >> "$R/etc/opkg/customfeeds.conf"

echo "--- 10a. stock opkg.conf (check_signature on) against an unsigned feed"
out=$(cr "opkg update" 2>&1); echo "$out" | sed 's/^/    | /'
if echo "$out" | grep -qE 'Signature (check|file download) failed'; then
    ok "unsigned feed is refused while check_signature is on (this is why the README says to comment it out)"
else
    bad "expected a signature refusal, got something else"
fi
crq "opkg list | grep -q '^$PKG '" && bad "package usable from an unverified feed" || ok "package not usable until the feed is trusted"

echo "--- 10b. with check_signature commented out"
sed -i 's/^option check_signature/# option check_signature/' "$R/etc/opkg.conf"
out=$(cr "opkg update" 2>&1); echo "$out" | sed 's/^/    | /'
echo "$out" | grep -q 'nvr_test' && ok "opkg update fetched the feed index" || bad "opkg update did not fetch the feed"
crq "opkg list | grep -q '^$PKG '"; check "package visible in 'opkg list'" $?
out=$(cr "opkg install $PKG" 2>&1); echo "$out" | sed 's/^/    | /'
echo "$out" | grep -q "Configuring $PKG" && ok "installed by name from the feed" || bad "install-by-name from the feed failed"
[ -f "$R/usr/bin/nordvpn-rotate.sh" ] && ok "feed install placed the script" || bad "feed install placed nothing"

echo "--- 10c. the index SHA256sum is enforced"
crq "opkg remove $PKG"
cp "$ROOT/dist/feed/$IPK_NAME" "$WORK/good.ipk"
printf 'garbage' >> "$ROOT/dist/feed/$IPK_NAME"
out=$(cr "opkg install $PKG" 2>&1)
echo "$out" | grep -qiE 'checksum|sha256|corrupt' && ok "opkg rejects an .ipk that does not match the index" \
                                                  || bad "opkg accepted a corrupted .ipk"
cp "$WORK/good.ipk" "$ROOT/dist/feed/$IPK_NAME"
kill "$FEED_PID" 2>/dev/null; FEED_PID=""

# =============================================================================
echo
echo "=== 11. install-remote.sh against a mock GitHub release"
if [ "$HAVE_CURL" = 0 ]; then
    skipit "install-remote.sh (no HTTP client in the test rootfs)"
else
    fresh_root
    GH="$WORK/gh"
    mkdir -p "$GH/repos/testowner/testrepo/releases" "$GH/dl"
    cp "$ROOT/dist/$IPK_NAME" "$GH/dl/"
    ( cd "$GH/dl" && sha256sum "$IPK_NAME" > sha256sums )
    cat > "$GH/repos/testowner/testrepo/releases/latest" <<JSON
{
  "tag_name": "v$VER",
  "assets": [
    { "browser_download_url": "http://127.0.0.1:$GHPORT/dl/$IPK_NAME" },
    { "browser_download_url": "http://127.0.0.1:$GHPORT/dl/sha256sums" }
  ]
}
JSON
    ( cd "$GH" && exec python3 -m http.server "$GHPORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
    GH_PID=$!
    wait_for_url "http://127.0.0.1:$GHPORT/dl/sha256sums" && ok "mock GitHub up" || bad "mock GitHub never came up"

    cp "$ROOT/install-remote.sh" "$R/tmp/install-remote.sh"
    ENVV="NVR_REPO=testowner/testrepo NVR_API=http://127.0.0.1:$GHPORT"

    out=$(cr "$ENVV sh /tmp/install-remote.sh" 2>&1); echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q 'sha256 verified' && ok "installer verified the checksum" || bad "installer did not verify the checksum"
    crq "opkg list-installed | grep -q '^$PKG '"; check "installer installed the package" $?
    [ -f "$R/usr/bin/nordvpn-rotate.sh" ] && ok "installer placed the script" || bad "installer placed nothing"

    echo "--- 11b. re-running the installer upgrades in place and keeps the conf"
    sed -i 's/^DRY_RUN=1/DRY_RUN=0/' "$R/etc/nordvpn-rotate.conf"
    out=$(cr "$ENVV sh /tmp/install-remote.sh" 2>&1)
    echo "$out" | grep -q 'already installed' && ok "installer noticed the existing install" || bad "installer did not notice the existing install"
    grep -q '^DRY_RUN=0' "$R/etc/nordvpn-rotate.conf" && ok "live conf survived the re-run" || bad "re-run reset the conf"

    echo "--- 11c. a tampered download is refused"
    crq "sh /tmp/install-remote.sh uninstall"
    printf 'garbage' >> "$GH/dl/$IPK_NAME"
    out=$(cr "$ENVV sh /tmp/install-remote.sh" 2>&1)
    echo "$out" | grep -q 'checksum mismatch' && ok "installer refuses a tampered .ipk" || bad "installer accepted a tampered .ipk"
    crq "opkg list-installed | grep -q '^$PKG '" && bad "tampered package got installed" || ok "nothing installed after the refusal"
    cp "$ROOT/dist/$IPK_NAME" "$GH/dl/$IPK_NAME"

    echo "--- 11d. uninstall path"
    crq "$ENVV sh /tmp/install-remote.sh"
    out=$(cr "sh /tmp/install-remote.sh uninstall" 2>&1); echo "$out" | sed 's/^/    | /'
    crq "opkg list-installed | grep -q '^$PKG '" && bad "still installed after uninstall" || ok "uninstall removed the package"

    echo "--- 11e. the piped form from the README (wget -qO- ... | sh)"
    # the headline install line pipes the script into sh, so it must not depend
    # on $0 or on stdin, and "sh -s <tag>" has to still reach $1
    out=$(cr "$ENVV sh -c 'cat /tmp/install-remote.sh | sh'" 2>&1)
    echo "$out" | grep -q 'sha256 verified' && ok "piped install works" || bad "piped install failed"
    crq "opkg list-installed | grep -q '^$PKG '"; check "piped install placed the package" $?
    crq "sh /tmp/install-remote.sh uninstall"
    out=$(cr "$ENVV sh -c 'cat /tmp/install-remote.sh | sh -s v$VER'" 2>&1)
    echo "$out" | grep -q "release: v$VER" && ok "sh -s <tag> pins the version" || bad "sh -s <tag> did not reach \$1"
    crq "sh /tmp/install-remote.sh uninstall"

    echo "--- 11f. refuses to run where there is no opkg"
    out=$(sh "$ROOT/install-remote.sh" 2>&1)
    echo "$out" | grep -q 'no opkg here' && ok "refuses to run on a PC with a useful message" || bad "did not refuse to run without opkg"

    kill "$GH_PID" 2>/dev/null; GH_PID=""
fi

echo
echo "==="
echo "result: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
