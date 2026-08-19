#!/bin/sh
# install-remote.sh — network installer for nordvpn-rotate. Runs ON the router.
#
#   wget -qO- https://raw.githubusercontent.com/odaialfadel/nordvpn-rotator/main/install-remote.sh | sh
#
# Resolves the latest GitHub release, downloads its .ipk, verifies the SHA256
# against the sha256sums published alongside it, and hands the file to opkg.
# The verify step is the point: opkg cannot install from a URL, so something
# has to do the download, and a downloader that skips the checksum is worse
# than no downloader at all.
#
#   sh install-remote.sh              latest release
#   sh install-remote.sh v0.2.0       a specific release
#   sh install-remote.sh uninstall    opkg remove nordvpn-rotate
#
# Env overrides (for testing against a local mirror):
#   NVR_REPO   owner/name           default odaialfadel/nordvpn-rotator
#   NVR_API    GitHub API base      default https://api.github.com
#   NVR_INSECURE=1                  skip TLS verification (last resort)

PKG=nordvpn-rotate
REPO="${NVR_REPO:-odaialfadel/nordvpn-rotator}"
API="${NVR_API:-https://api.github.com}"
TMP="/tmp/$PKG-install.$$"

say()  { echo "$*"; }
die()  { echo "error: $*" >&2; rm -rf "$TMP"; exit 1; }

# --- preconditions -----------------------------------------------------------
command -v opkg >/dev/null 2>&1 \
    || die "no opkg here. This script installs a router package — run it on the
       router (ssh root@192.168.8.1), not on your PC."

[ "$(id -u 2>/dev/null || echo 0)" = 0 ] || die "run as root"

# --- downloader: curl, then uclient-fetch, then busybox wget -----------------
# GL.iNet 4.x ships all three; plain busybox wget is the one that may lack TLS,
# so it is tried last.
INSECURE=""
if command -v curl >/dev/null 2>&1; then
    [ "$NVR_INSECURE" = 1 ] && INSECURE="-k"
    fetch() { curl -fsSL --connect-timeout 20 $INSECURE -o "$2" "$1"; }
elif command -v uclient-fetch >/dev/null 2>&1; then
    [ "$NVR_INSECURE" = 1 ] && INSECURE="--no-check-certificate"
    fetch() { uclient-fetch -q $INSECURE -O "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    [ "$NVR_INSECURE" = 1 ] && INSECURE="--no-check-certificate"
    fetch() { wget -q $INSECURE -O "$2" "$1"; }
else
    die "no curl, uclient-fetch or wget on this router"
fi

# --- uninstall ---------------------------------------------------------------
if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
    opkg list-installed 2>/dev/null | grep -q "^$PKG " \
        || die "$PKG is not installed via opkg (loose install? use install.sh uninstall)"
    opkg remove "$PKG"
    exit $?
fi

TAG="${1:-latest}"

mkdir -p "$TMP" || die "cannot create $TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- resolve the release -----------------------------------------------------
if [ "$TAG" = latest ]; then
    URL="$API/repos/$REPO/releases/latest"
else
    URL="$API/repos/$REPO/releases/tags/$TAG"
fi

say "looking up $REPO release: $TAG"
fetch "$URL" "$TMP/release.json" \
    || die "cannot reach $URL — check the router's DNS and clock (TLS fails on a
       wrong date: run 'date' and fix it with ntpd if it is off)"

# jsonfilter ships with the firmware; the sed fallback parses GitHub's
# pretty-printed JSON one line at a time and is only there for odd builds.
asset_urls() {
    _out=""
    if command -v jsonfilter >/dev/null 2>&1; then
        _out=$(jsonfilter -i "$1" -e '@.assets[*].browser_download_url' 2>/dev/null)
    fi
    [ -n "$_out" ] || _out=$(sed -n \
        's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1")
    printf '%s\n' "$_out"
}

IPK_URL=$(asset_urls "$TMP/release.json" | grep '\.ipk$' | head -n 1)
SUM_URL=$(asset_urls "$TMP/release.json" | grep 'sha256sums$' | head -n 1)
[ -n "$IPK_URL" ] || die "no .ipk asset on release '$TAG' of $REPO"

IPK_NAME=$(basename "$IPK_URL")
IPK="$TMP/$IPK_NAME"

say "downloading $IPK_NAME"
fetch "$IPK_URL" "$IPK" || die "download failed: $IPK_URL"
[ -s "$IPK" ] || die "downloaded an empty file"

# --- verify ------------------------------------------------------------------
if [ -z "$SUM_URL" ]; then
    say "WARNING: this release publishes no sha256sums — cannot verify the download"
elif ! command -v sha256sum >/dev/null 2>&1; then
    say "WARNING: no sha256sum on this firmware — cannot verify the download"
else
    fetch "$SUM_URL" "$TMP/sha256sums" || die "cannot fetch sha256sums"
    want=$(awk -v f="$IPK_NAME" '{ sub(/^\*/, "", $2); if ($2 == f) print $1 }' \
        "$TMP/sha256sums" | head -n 1)
    [ -n "$want" ] || die "$IPK_NAME is not listed in sha256sums"
    got=$(sha256sum "$IPK" | awk '{print $1}')
    [ "$want" = "$got" ] || die "checksum mismatch for $IPK_NAME
       expected $want
       got      $got"
    say "sha256 verified"
fi

# --- install -----------------------------------------------------------------
# opkg keeps a modified /etc/nordvpn-rotate.conf on upgrade (it is a conffile),
# so reinstalling never silently resets a live configuration.
if opkg list-installed 2>/dev/null | grep -q "^$PKG "; then
    say "$PKG is already installed — upgrading, your /etc/nordvpn-rotate.conf is kept"
    opkg install --force-reinstall "$IPK" || die "opkg install failed"
else
    opkg install "$IPK" || die "opkg install failed"
fi

say ""
say "next: /usr/bin/nordvpn-rotate.sh check      (read-only pre-flight)"
say "      it stays in DRY_RUN=1 until you edit /etc/nordvpn-rotate.conf"
