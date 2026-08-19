#!/bin/sh
# install.sh — idempotent installer for nordvpn-rotate on a GL.iNet 4.x router.
# Run ON the router, from the directory the files were uploaded to:
#   sh install.sh            install / update (keeps existing /etc conf)
#   sh install.sh uninstall  remove everything (cron line, script, conf, sysupgrade entries)
#
# What install does — nothing else:
#   1. strips Windows line endings from the uploaded files (safe no-op otherwise)
#   2. copies nordvpn-rotate.sh -> /usr/bin/ (0755)
#   3. copies rotator-dashboard.cgi -> /www/cgi-bin/rotator (if present)
#   4. copies nordvpn-rotate.conf -> /etc/ ONLY if not already there
#   5. adds two cron lines to /etc/crontabs/root if missing (every 30 min run,
#      04:15 nightly rotation); enables cron
#   6. lists the files in /etc/sysupgrade.conf so "keep settings" upgrades try to keep them
#      (GL upgrades are not guaranteed to honor this — re-run this installer after upgrades)

DIR=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/bin/nordvpn-rotate.sh
CONF=/etc/nordvpn-rotate.conf
DASH=/www/cgi-bin/rotator
CRONTAB=/etc/crontabs/root
CRON_LINE="*/30 * * * * $BIN run"
# 04:15 on purpose: a :00/:30 time would fire together with the */30 run line
# and the two would race for the same lock — the nightly rotation used to lose
# that race at 04:30 and silently skip the fresh IP
NIGHTLY_LINE="15 4 * * * $BIN nightly"

if [ "$1" = "uninstall" ]; then
    # note: grep -v exits 1 when nothing is left — an empty file is still the
    # correct result, so never condition the mv on grep's exit code
    if [ -f "$CRONTAB" ]; then
        grep -v "nordvpn-rotate" "$CRONTAB" > "$CRONTAB.tmp"
        mv "$CRONTAB.tmp" "$CRONTAB"
    fi
    # rotator-dash.secret is legacy (pre-0.3 dashboard auth) — clean it up too
    rm -f "$BIN" "$CONF" "$DASH" /etc/nordvpn-rotate.prev /etc/rotator-dash.secret
    if [ -f /etc/sysupgrade.conf ]; then
        # same pattern as package/postrm: the dashboard and legacy secret
        # entries must go too, not just the nordvpn-rotate ones
        grep -v -E 'nordvpn-rotate|cgi-bin/rotator|rotator-dash' /etc/sysupgrade.conf > /tmp/su.tmp
        mv /tmp/su.tmp /etc/sysupgrade.conf
    fi
    /etc/init.d/cron restart 2>/dev/null
    rm -rf /tmp/nordvpn-rotate /tmp/nordvpn-rotate.log
    echo "uninstalled. The WireGuard peer keeps whatever endpoint it had last —"
    echo "pick a server in the GL panel if you want a specific one back."
    exit 0
fi

[ -f "$DIR/nordvpn-rotate.sh" ] || { echo "nordvpn-rotate.sh not found next to install.sh"; exit 1; }

sed -i 's/\r$//' "$DIR/nordvpn-rotate.sh" "$DIR/nordvpn-rotate.conf" "$DIR/rotator-dashboard.cgi" 2>/dev/null

cp "$DIR/nordvpn-rotate.sh" "$BIN" || { echo "FAILED to copy the engine to $BIN — nothing armed, fix and re-run"; exit 1; }
chmod 755 "$BIN"

# status page + controls (optional file — older uploads simply skip it)
if [ -f "$DIR/rotator-dashboard.cgi" ] && [ -d /www/cgi-bin ]; then
    cp "$DIR/rotator-dashboard.cgi" "$DASH" || { echo "FAILED to copy the dashboard to $DASH"; exit 1; }
    chmod 755 "$DASH"
    echo "dashboard installed: http://192.168.8.1/cgi-bin/rotator"
fi

if [ -f "$CONF" ]; then
    echo "kept existing $CONF"
    if grep -q '^DRY_RUN=1' "$CONF" 2>/dev/null; then
        echo "note: this conf still says DRY_RUN=1 (dry-run). Live is the normal mode now —"
        echo "      flip it on the dashboard (Settings -> Live) or set DRY_RUN=0 in $CONF."
    fi
else
    cp "$DIR/nordvpn-rotate.conf" "$CONF"
    echo "installed $CONF (live mode — use the dashboard's Dry-run mode for testing)"
fi

mkdir -p "$(dirname "$CRONTAB")"
touch "$CRONTAB"
if grep -qF "$BIN run" "$CRONTAB"; then
    echo "cron entry already present"
else
    echo "$CRON_LINE" >> "$CRONTAB"
    echo "cron entry added: $CRON_LINE"
fi
# migrate any older nightly line (e.g. the 04:30 one that raced the */30 run)
if grep -qF "$BIN nightly" "$CRONTAB" && ! grep -qxF "$NIGHTLY_LINE" "$CRONTAB"; then
    grep -vF "$BIN nightly" "$CRONTAB" > "$CRONTAB.tmp"
    mv "$CRONTAB.tmp" "$CRONTAB"
    echo "replaced outdated nightly cron entry"
fi
if grep -qxF "$NIGHTLY_LINE" "$CRONTAB"; then
    echo "nightly cron entry already present"
else
    echo "$NIGHTLY_LINE" >> "$CRONTAB"
    echo "cron entry added: $NIGHTLY_LINE (on by default — set NIGHTLY_ROTATE=0 in $CONF to disable)"
fi
/etc/init.d/cron enable 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

touch /etc/sysupgrade.conf
for p in "$BIN" "$CONF" "$CRONTAB" "$DASH"; do
    [ -e "$p" ] || continue   # e.g. the dashboard when /www/cgi-bin is absent
    grep -qxF "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done

echo "---"
echo "installed. Next: $BIN check   (read-only verification)"
echo "watch it work: tail -f /tmp/nordvpn-rotate.log"
