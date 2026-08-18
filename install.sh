#!/bin/sh
# install.sh — idempotent installer for nordvpn-rotate on a GL.iNet 4.x router.
# Run ON the router, from the directory the files were uploaded to:
#   sh install.sh            install / update (keeps existing /etc conf)
#   sh install.sh uninstall  remove everything (cron line, script, conf, sysupgrade entries)
#
# What install does — nothing else:
#   1. strips Windows line endings from the uploaded files (safe no-op otherwise)
#   2. copies nordvpn-rotate.sh -> /usr/bin/ (0755)
#   3. copies nordvpn-rotate.conf -> /etc/ ONLY if not already there
#   4. adds one line to /etc/crontabs/root (every 30 min) if missing; enables cron
#   5. lists the files in /etc/sysupgrade.conf so "keep settings" upgrades try to keep them
#      (GL upgrades are not guaranteed to honor this — re-run this installer after upgrades)

DIR=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/bin/nordvpn-rotate.sh
CONF=/etc/nordvpn-rotate.conf
DASH=/www/cgi-bin/rotator
CRONTAB=/etc/crontabs/root
CRON_LINE="*/30 * * * * $BIN run"
NIGHTLY_LINE="30 4 * * * $BIN nightly"

if [ "$1" = "uninstall" ]; then
    # note: grep -v exits 1 when nothing is left — an empty file is still the
    # correct result, so never condition the mv on grep's exit code
    if [ -f "$CRONTAB" ]; then
        grep -v "nordvpn-rotate" "$CRONTAB" > "$CRONTAB.tmp"
        mv "$CRONTAB.tmp" "$CRONTAB"
    fi
    rm -f "$BIN" "$CONF" "$DASH" /etc/nordvpn-rotate.prev /etc/rotator-dash.secret
    if [ -f /etc/sysupgrade.conf ]; then
        grep -v "nordvpn-rotate" /etc/sysupgrade.conf > /tmp/su.tmp
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

cp "$DIR/nordvpn-rotate.sh" "$BIN"
chmod 755 "$BIN"

# read-only status page (optional file — older uploads simply skip it)
if [ -f "$DIR/rotator-dashboard.cgi" ] && [ -d /www/cgi-bin ]; then
    cp "$DIR/rotator-dashboard.cgi" "$DASH"
    chmod 755 "$DASH"
    echo "dashboard installed: http://192.168.8.1/cgi-bin/rotator (read-only, no auth)"
fi

if [ -f "$CONF" ]; then
    echo "kept existing $CONF"
else
    cp "$DIR/nordvpn-rotate.conf" "$CONF"
    echo "installed $CONF (DRY_RUN=1 — it will only log until you change that)"
fi

touch "$CRONTAB"
if grep -qF "$BIN run" "$CRONTAB"; then
    echo "cron entry already present"
else
    echo "$CRON_LINE" >> "$CRONTAB"
    echo "cron entry added: $CRON_LINE"
fi
if grep -qF "$BIN nightly" "$CRONTAB"; then
    echo "nightly cron entry already present"
else
    echo "$NIGHTLY_LINE" >> "$CRONTAB"
    echo "cron entry added: $NIGHTLY_LINE (no-op unless NIGHTLY_ROTATE=1 in $CONF)"
fi
/etc/init.d/cron enable 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

touch /etc/sysupgrade.conf
for p in "$BIN" "$CONF" "$CRONTAB" "$DASH"; do
    grep -qxF "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done
# keep the dashboard password across upgrades, once the user has set it up
if [ -s /etc/rotator-dash.secret ]; then
    grep -qxF "/etc/rotator-dash.secret" /etc/sysupgrade.conf || echo "/etc/rotator-dash.secret" >> /etc/sysupgrade.conf
fi

echo "---"
echo "installed. Next: $BIN check   (read-only verification)"
echo "then let it DRY-RUN for a few days: tail -f /tmp/nordvpn-rotate.log"
