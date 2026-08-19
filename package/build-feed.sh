#!/bin/sh
# build-feed.sh — turn the .ipk files in dist/ into an opkg feed in dist/feed.
#
#   sh package/build-ipk.sh && sh package/build-feed.sh
#
# Produces the two files opkg looks for when you point a src/gz line at a URL:
#   Packages      the index: one stanza per package, plus Filename/Size/SHA256sum
#   Packages.gz   the same, gzipped — this is the one opkg actually downloads
# and copies the .ipk files next to them.
#
# Signing is optional. opkg's /etc/opkg.conf carries "option check_signature",
# so a router with the stock config refuses an unsigned feed. If usign is on
# PATH and a secret key is given, a Packages.sig is written and installing the
# matching public key into /etc/opkg/keys/ makes the feed work untouched:
#   NVR_USIGN_KEY=/path/to/secret.key sh package/build-feed.sh
# Without it the feed still works, the user just has to comment out that one
# option (the README spells out both routes).
#
# Needs only tar, gzip, sha256sum, md5sum and awk — Git Bash on Windows is fine.

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST="$ROOT/dist"
FEED="$DIST/feed"

[ -d "$DIST" ] || { echo "no dist/ — run package/build-ipk.sh first"; exit 1; }
set -- "$DIST"/*.ipk
[ -f "$1" ] || { echo "no .ipk in dist/ — run package/build-ipk.sh first"; exit 1; }

rm -rf "$FEED"
mkdir -p "$FEED"

: > "$FEED/Packages"

for ipk in "$DIST"/*.ipk; do
    name=$(basename "$ipk")
    work="$DIST/.feedwork"
    rm -rf "$work"
    mkdir -p "$work/c" "$work/d"

    tar xzf "$ipk" -C "$work"
    tar xzf "$work/control.tar.gz" -C "$work/c"
    tar xzf "$work/data.tar.gz"    -C "$work/d"

    size=$(wc -c < "$ipk" | tr -d ' ')
    sha=$(sha256sum "$ipk" | awk '{print $1}')
    md5=$(md5sum "$ipk" | awk '{print $1}')
    # busybox du has no -b, so sum the payload file sizes directly
    isize=$(find "$work/d" -type f -exec ls -ln {} + 2>/dev/null | awk '{s+=$5} END {print s+0}')

    # Emit the control stanza with the index-only fields inserted just before
    # Description, so the description's leading-space continuation lines stay
    # attached to it and nothing else gets swallowed into them.
    awk -v fn="$name" -v sz="$size" -v sha="$sha" -v md5="$md5" -v isz="$isize" '
        /^Description:/ && !done {
            print "Installed-Size: " isz
            print "Filename: " fn
            print "Size: " sz
            print "MD5Sum: " md5
            print "SHA256sum: " sha
            done = 1
        }
        { print }
        END {
            if (!done) {
                print "Installed-Size: " isz
                print "Filename: " fn
                print "Size: " sz
                print "MD5Sum: " md5
                print "SHA256sum: " sha
            }
        }
    ' "$work/c/control" | tr -d '\r' >> "$FEED/Packages"

    # opkg splits stanzas on a blank line; control files do not always end with one
    printf '\n' >> "$FEED/Packages"

    cp "$ipk" "$FEED/$name"
    rm -rf "$work"
    echo "indexed: $name"
done

# -n so the gzip header carries no name/mtime — same input, same bytes
gzip -n9 -c "$FEED/Packages" > "$FEED/Packages.gz"

if [ -n "${NVR_USIGN_KEY:-}" ] && command -v usign >/dev/null 2>&1; then
    usign -S -m "$FEED/Packages" -s "$NVR_USIGN_KEY" -x "$FEED/Packages.sig"
    echo "signed: Packages.sig"
elif [ -n "${NVR_USIGN_KEY:-}" ]; then
    echo "NVR_USIGN_KEY set but usign is not on PATH — feed left unsigned" >&2
fi

echo "feed: $FEED"
ls -1 "$FEED"
