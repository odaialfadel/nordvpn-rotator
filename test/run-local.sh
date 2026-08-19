#!/bin/sh
# Local harness: runs the REAL nordvpn-rotate.sh with router commands mocked.
# Usage (Git Bash):  sh test/run-local.sh
# Exercises: OK/no-switch, not-in-list, threshold breach, all-hot hold,
# real switch (mocked), dwell guard, failed-switch rollback.

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRIPT="$ROOT/nordvpn-rotate.sh"
SAMPLE="$ROOT/samples/recommendations-de.json"

export NVR_TEST_DIR="$ROOT/test/tmp"
export NVR_CONF="$NVR_TEST_DIR/conf"
export PATH="$ROOT/test/mock-bin:$PATH"
rm -rf "$NVR_TEST_DIR"
mkdir -p "$NVR_TEST_DIR"

# file:// URL that Windows curl accepts
if command -v cygpath >/dev/null 2>&1; then
    SAMPLE_URL="file:///$(cygpath -m "$SAMPLE")"
    HOT_URL="file:///$(cygpath -m "$NVR_TEST_DIR/reco-hot.json")"
    ALLHOT_URL="file:///$(cygpath -m "$NVR_TEST_DIR/reco-allhot.json")"
else
    SAMPLE_URL="file://$SAMPLE"
    HOT_URL="file://$NVR_TEST_DIR/reco-hot.json"
    ALLHOT_URL="file://$NVR_TEST_DIR/reco-allhot.json"
fi

# derived fixtures: current-server-is-hot, and everything-is-hot
python - "$SAMPLE" "$NVR_TEST_DIR" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
hot = json.loads(json.dumps(d)); hot[0]["load"] = 85
json.dump(hot, open(sys.argv[2] + "/reco-hot.json", "w"))
allhot = json.loads(json.dumps(d))
for s in allhot: s["load"] = 90
json.dump(allhot, open(sys.argv[2] + "/reco-allhot.json", "w"))
PYEOF

S0=$(jsonfilter -i "$SAMPLE" -e '@[0].station')   # NordVPN's rank-1 server (load 5% -> load-rank 3)
SB_ST=$(jsonfilter -i "$SAMPLE" -e '@[3].station')    # lowest load in the sample (4%) — what the picker takes
SB_HOST=$(jsonfilter -i "$SAMPLE" -e '@[3].hostname')
LOG="$NVR_TEST_DIR/rotate.log"
pass=0; fail=0

check() { # label, pattern, file
    if grep -q "$2" "$3" 2>/dev/null; then
        echo "PASS: $1"; pass=$((pass + 1))
    else
        echo "FAIL: $1  (expected /$2/ in $3)"; fail=$((fail + 1))
    fi
}
check_absent() {
    if grep -q "$2" "$3" 2>/dev/null; then
        echo "FAIL: $1  (found unexpected /$2/ in $3)"; fail=$((fail + 1))
    else
        echo "PASS: $1"; pass=$((pass + 1))
    fi
}

mkconf() { # $1 = API url, $2 = extra lines
    # the harness defaults to DRY_RUN=1 so scenarios must opt INTO live mode —
    # the shipped default is live (DRY_RUN=0), covered by its own scenario
    {
        echo "LOAD_THRESHOLD=60"
        echo "MIN_IMPROVEMENT=15"
        echo "MIN_DWELL_MIN=60"
        echo "DRY_RUN=1"
        echo "STATE_DIR=$NVR_TEST_DIR/state"
        echo "LOG_FILE=$LOG"
        echo "PREV_FILE=$NVR_TEST_DIR/state/prev"
        echo "API_URL=$1"
        [ -n "$2" ] && printf '%s\n' "$2"
    } > "$NVR_CONF"
}

reset() { # $1 = current endpoint host/IP, $2 = API url, $3 = extra conf
    rm -rf "$NVR_TEST_DIR/state" "$LOG" "$NVR_TEST_DIR/actions.log"
    mkdir -p "$NVR_TEST_DIR/state"
    {
        echo "network.wgclient.config=wg_peer_1794"
        echo "wireguard.wg_peer_1794.end_point=$1:51820"
        echo "wireguard.wg_peer_1794.public_key=OLDKEY="
        echo "wireguard.wg_peer_1794.name=de9999.nordvpn.com"
        echo "wireguard.wg_peer_1794.location=Germany,Oldtown"
    } > "$NVR_TEST_DIR/uci.env"
    echo "$1:51820" > "$NVR_TEST_DIR/live_ep"
    echo true > "$NVR_TEST_DIR/vpn_up"
    echo ok > "$NVR_TEST_DIR/health"
    mkconf "$2" "$3"
}

check_gone() { # label, file that must NOT exist
    if [ -f "$2" ]; then
        echo "FAIL: $1  ($2 still exists)"; fail=$((fail + 1))
    else
        echo "PASS: $1"; pass=$((pass + 1))
    fi
}

echo "=== 1. current server healthy and recommended -> no action"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" run
check "logs OK / no switch (load-sorted rank)" "^.* OK: de.*rank 3 of 20" "$LOG"
check "latency cache written for rank-1 station" "^$S0 23" "$NVR_TEST_DIR/state/latency"

echo "=== 2. current server not in recommendations -> dry-run announce"
reset "203.0.113.99" "$SAMPLE_URL" ""
sh "$SCRIPT" run
check "dry-run would switch" "DRY-RUN: would switch 203.0.113.99" "$LOG"
check_absent "dry-run touches nothing" "uci set" "$NVR_TEST_DIR/actions.log"

echo "=== 3. current server over threshold -> dry-run announce"
reset "$S0" "$HOT_URL" ""
sh "$SCRIPT" run
check "threshold reason logged" "load 85% >= threshold 60%" "$LOG"

echo "=== 4. every candidate loaded -> hold"
reset "203.0.113.99" "$ALLHOT_URL" ""
sh "$SCRIPT" run
check "holds when all hot" "HOLD:.*also loaded" "$LOG"

echo "=== 5. DRY_RUN=0, healthy -> real switch via uci + bounce (lowest-load pick)"
reset "203.0.113.99" "$SAMPLE_URL" "DRY_RUN=0"
sh "$SCRIPT" run
check "switch logged" "SWITCHED: now on" "$LOG"
check "endpoint updated to the lowest-load server" "end_point=$SB_ST:51820" "$NVR_TEST_DIR/uci.env"
check "pubkey updated" "public_key=3ZNjosvvIqfvu3" "$NVR_TEST_DIR/uci.env"
check "tunnel bounced" "ifup wgclient" "$NVR_TEST_DIR/actions.log"
check_gone "switch marker cleared after success" "$NVR_TEST_DIR/state/prev"

echo "=== 6. immediately after a switch -> dwell guard blocks"
# keep state dir from scenario 5, point current back at an unknown server
sed -i "s|end_point=.*|end_point=203.0.113.99:51820|" "$NVR_TEST_DIR/uci.env"
rm -f "$LOG" "$NVR_TEST_DIR/actions.log"
sh "$SCRIPT" run
check "dwell hold logged" "HOLD: would switch.*dwell" "$LOG"

echo "=== 7. DRY_RUN=0, new server unhealthy -> rollback restores old peer"
reset "203.0.113.99" "$SAMPLE_URL" "DRY_RUN=0"
echo fail > "$NVR_TEST_DIR/health"
sh "$SCRIPT" run
check "failure logged" "ERROR: tunnel not healthy" "$LOG"
check "rollback attempted (critical since health still down)" "CRITICAL: rollback failed" "$LOG"
check "endpoint restored" "end_point=203.0.113.99:51820" "$NVR_TEST_DIR/uci.env"
check "pubkey restored" "public_key=OLDKEY=" "$NVR_TEST_DIR/uci.env"
check "CRITICAL starts a cooldown (no flap loop)" "." "$NVR_TEST_DIR/state/last_switch"
check "marker kept for auto-recovery" "203.0.113.99:51820" "$NVR_TEST_DIR/state/prev"

echo "=== 7b. next cycle, still unhealthy -> single recovery attempt, not a full re-switch"
rm -f "$LOG" "$NVR_TEST_DIR/actions.log"
sh "$SCRIPT" run
check "recovery attempted" "RECOVERY:" "$LOG"
check "recovery failure noted" "RECOVERY attempt failed" "$LOG"
check_absent "no new switch attempted while broken" "switching:" "$LOG"

echo "=== 7c. tunnel healthy again -> marker cleaned up, dwell respected"
echo ok > "$NVR_TEST_DIR/health"
rm -f "$LOG" "$NVR_TEST_DIR/actions.log"
sh "$SCRIPT" run
check_gone "marker removed once healthy" "$NVR_TEST_DIR/state/prev"
check "dwell blocks the next switch" "HOLD: would switch.*dwell" "$LOG"

echo "=== 8. VPN switched off by user -> script leaves it alone"
reset "$S0" "$SAMPLE_URL" ""
echo false > "$NVR_TEST_DIR/vpn_up"
sh "$SCRIPT" run
check "skip logged" "skipped: VPN interface" "$LOG"

echo "=== 9. hostname-form endpoint (the real router's state) + live wg endpoint -> correctly matched, no switch"
reset "frankfurt.de.wg.nordhold.net" "$SAMPLE_URL" ""
echo "$S0:51820" > "$NVR_TEST_DIR/live_ep"
sh "$SCRIPT" run
check "current server identified via live endpoint" "OK: de.*rank 3" "$LOG"

echo "=== 10. hostname-form endpoint, no live endpoint available -> normalizing switch announced"
reset "frankfurt.de.wg.nordhold.net" "$SAMPLE_URL" ""
rm -f "$NVR_TEST_DIR/live_ep"
sh "$SCRIPT" run
check "falls back to config host + would normalize" "DRY-RUN: would switch frankfurt.de.wg.nordhold.net" "$LOG"

echo "=== 11. best candidate missing its public key -> skipped, next-best by load used"
python - "$SAMPLE" "$NVR_TEST_DIR" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
broken = json.loads(json.dumps(d))
broken[3]["technologies"] = []   # index 3 = the lowest-load pick
json.dump(broken, open(sys.argv[2] + "/reco-nopub.json", "w"))
PYEOF
if command -v cygpath >/dev/null 2>&1; then NOPUB_URL="file:///$(cygpath -m "$NVR_TEST_DIR/reco-nopub.json")"; else NOPUB_URL="file://$NVR_TEST_DIR/reco-nopub.json"; fi
H19=$(jsonfilter -i "$SAMPLE" -e '@[19].hostname')   # second-lowest load (also 4%)
reset "203.0.113.99" "$NOPUB_URL" ""
sh "$SCRIPT" run
check "half-parsed candidate skipped, next taken" "would switch 203.0.113.99 -> $H19" "$LOG"

echo "=== 12. DRY_RUN typo (yes) -> noted, treated as live (live is the default mode)"
reset "203.0.113.99" "$SAMPLE_URL" "DRY_RUN=yes"
sh "$SCRIPT" run
check "typo noted" "DRY_RUN='yes' unrecognized" "$LOG"
check "typo falls back to live" "SWITCHED: now on" "$LOG"

echo "=== 12a. no DRY_RUN key at all -> live by default, really switches"
reset "203.0.113.99" "$SAMPLE_URL" ""
sed -i '/^DRY_RUN=/d' "$NVR_CONF"
sh "$SCRIPT" run
check "default is live" "SWITCHED: now on" "$LOG"
check "endpoint really written" "end_point=$SB_ST:51820" "$NVR_TEST_DIR/uci.env"

echo "=== 12b. force in dry-run -> announces, ignores dwell, touches nothing"
reset "$S0" "$SAMPLE_URL" ""
date +%s > "$NVR_TEST_DIR/state/last_switch"   # dwell window active right now
sh "$SCRIPT" force
check "forced dry-run announce despite dwell" "DRY-RUN: would switch.*forced switch (manual)" "$LOG"

echo "=== 12c. force live -> switches even though current server is fine"
reset "$S0" "$SAMPLE_URL" "DRY_RUN=0"
sh "$SCRIPT" force
check "forced switch executed" "SWITCHED: now on" "$LOG"
check "forced reason logged" "forced switch (manual)" "$LOG"
check "moved to the lowest-load candidate" "end_point=$SB_ST:51820" "$NVR_TEST_DIR/uci.env"

echo "=== 12d. nightly is ON by default, honors an explicit off"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" nightly
check "nightly default on -> dry-run announce" "forced switch (nightly rotation)" "$LOG"
reset "$S0" "$SAMPLE_URL" "NIGHTLY_ROTATE=0"
sh "$SCRIPT" nightly
check_absent "nightly off -> silent no-op" "would switch" "$LOG"

echo "=== 12e. forced/nightly switch proceeds even when every candidate is loaded (fresh IP wins)"
reset "203.0.113.99" "$ALLHOT_URL" "DRY_RUN=0"
sh "$SCRIPT" nightly
check "loaded candidate noted, not held" "fresh IP wins" "$LOG"
check "nightly switched anyway" "SWITCHED: now on" "$LOG"

echo "=== 12f. lock: regular run yields, forced run waits (04:30 cron collision fix)"
reset "$S0" "$SAMPLE_URL" ""
mkdir -p "$NVR_TEST_DIR/state/lock"
sh "$SCRIPT" run
check "regular run skips immediately" "skipped: another run in progress" "$LOG"
rm -f "$LOG"
sh "$SCRIPT" force
check "forced run waited before giving up" "another run still busy after 2 min wait" "$LOG"
rmdir "$NVR_TEST_DIR/state/lock"
rm -f "$LOG"
sh "$SCRIPT" force
check "forced run proceeds once the lock is free" "forced switch (manual)" "$LOG"

echo "=== 12g. CANDIDATES=5: current server below the window stays visible to the engine"
S6=$(jsonfilter -i "$SAMPLE" -e '@[6].station')   # load-rank 6 -> below a top-5 window
reset "$S6" "$SAMPLE_URL" "CANDIDATES=5"
sh "$SCRIPT" run
check "current matched beyond the target window" "rank 6 of 20" "$LOG"
check_absent "no bogus not-recommended switch" "not matched in top" "$LOG"

echo "=== 12i. force reuses a fresh candidate list — the pick comes from what the dashboard shows"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" run
rm -f "$LOG"
mkconf "file:///nonexistent-nvr-reuse-test.json" ""   # a fetch would fail loudly
sh "$SCRIPT" force
check "fresh list reused instead of fetched" "force: reusing the candidate list" "$LOG"
check "decision made from the reused list" "DRY-RUN: would switch" "$LOG"

echo "=== 12h. refresh: re-fetches candidate data, decides nothing"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" refresh
check "refresh logged" "refreshed: 20 servers fetched" "$LOG"
check_absent "refresh never decides" "would switch\|SWITCHED\|OK:" "$LOG"

echo "=== 13. dashboard CGI renders current state, read-only"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" run
rm -f "$NVR_TEST_DIR/actions.log"
H0=$(jsonfilter -i "$SAMPLE" -e '@[0].hostname')
DASH="$NVR_TEST_DIR/dash.html"
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>"$NVR_TEST_DIR/dash.err"
check "CGI content-type header" "Content-Type: text/html" "$DASH"
check "current server matched + marked" "$H0.*current" "$DASH"
check "rtt column rendered from latency cache" "23 ms" "$DASH"
check "log tail included" "OK: de" "$DASH"
check "settings form rendered without any secret" "cfgform" "$DASH"
check_absent "dashboard writes nothing" "uci set" "$NVR_TEST_DIR/actions.log"
check_absent "no shell errors" "." "$NVR_TEST_DIR/dash.err"

echo "=== 13b. dashboard with no state (fresh boot) -> renders, says no data"
rm -rf "$NVR_TEST_DIR/state" "$LOG"
mkdir -p "$NVR_TEST_DIR/state"
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>"$NVR_TEST_DIR/dash.err"
check "renders without state" "no candidate data yet" "$DASH"
check_absent "no shell errors on empty state" "." "$NVR_TEST_DIR/dash.err"

echo "=== 13b2. COUNTRY_ID absent from conf -> dashboard still defaults it (was rendering blank)"
reset "$S0" "$SAMPLE_URL" ""
sed -i '/^COUNTRY_ID/d' "$NVR_CONF"
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>"$NVR_TEST_DIR/dash.err"
check "country field defaults instead of rendering blank" 'name="COUNTRY_ID"[^>]*value="81"' "$DASH"
check_absent "no shell errors" "." "$NVR_TEST_DIR/dash.err"

echo "=== 13c. dashboard POST: save config (no auth layer — LAN page)"
post() { # $1 body, $2 referer override
    printf '%s' "$1" | REQUEST_METHOD=POST CONTENT_LENGTH=$(printf '%s' "$1" | wc -c) \
        HTTP_HOST=192.168.8.1 HTTP_REFERER="${2:-http://192.168.8.1/cgi-bin/rotator}" \
        NVR_ROTATE_BIN="$SCRIPT" \
        sh "$ROOT/rotator-dashboard.cgi" 2>"$NVR_TEST_DIR/post.err"
}
reset "$S0" "$SAMPLE_URL" ""
post "action=save&LOAD_THRESHOLD=55&MIN_IMPROVEMENT=20&MIN_DWELL_MIN=90&COUNTRY_ID=81&CANDIDATES=20&NIGHTLY_ROTATE=1&MODE=live" > "$NVR_TEST_DIR/post.out"
check "save redirects" "303" "$NVR_TEST_DIR/post.out"
check "threshold written" "^LOAD_THRESHOLD=55" "$NVR_CONF"
check "mode live -> DRY_RUN=0" "^DRY_RUN=0" "$NVR_CONF"
# a save kicks off an immediate background refresh with the new settings
n=0
while [ "$n" -lt 160 ] && ! grep -q "refreshed:" "$LOG" 2>/dev/null; do
    /bin/sleep 0.25 2>/dev/null || sleep 1
    n=$((n + 1))
done
check "save triggers an immediate data refresh" "refreshed: 20 servers fetched" "$LOG"
post "action=save&LOAD_THRESHOLD=55&MIN_IMPROVEMENT=20&MIN_DWELL_MIN=90&COUNTRY_ID=81&CANDIDATES=20&MODE=dry" > "$NVR_TEST_DIR/post.out"
check "mode dry -> DRY_RUN=1" "^DRY_RUN=1" "$NVR_CONF"
# wait for this save's background refresh too, so later scenarios start clean
n=0
while [ "$n" -lt 160 ] && [ "$(grep -c 'refreshed:' "$LOG" 2>/dev/null)" -lt 2 ]; do
    /bin/sleep 0.25 2>/dev/null || sleep 1
    n=$((n + 1))
done
post "action=save&LOAD_THRESHOLD=55&MIN_IMPROVEMENT=20&MIN_DWELL_MIN=90&COUNTRY_ID=81&CANDIDATES=20" > "$NVR_TEST_DIR/post.out"
check "missing mode -> 400" "400" "$NVR_TEST_DIR/post.out"
check_absent "no shell errors on save" "." "$NVR_TEST_DIR/post.err"

echo "=== 13d. dashboard POST: bad values rejected, conf untouched"
post "action=save&LOAD_THRESHOLD=abc&MIN_IMPROVEMENT=20&MIN_DWELL_MIN=90&COUNTRY_ID=81&CANDIDATES=20" > "$NVR_TEST_DIR/post.out"
check "non-numeric -> 400" "400" "$NVR_TEST_DIR/post.out"
check "conf keeps last good value" "^LOAD_THRESHOLD=55" "$NVR_CONF"
post "action=save&LOAD_THRESHOLD=55&MIN_IMPROVEMENT=20&MIN_DWELL_MIN=90&COUNTRY_ID=9999&CANDIDATES=20" > "$NVR_TEST_DIR/post.out"
check "country out of range -> 400" "400" "$NVR_TEST_DIR/post.out"
post "action=reboot" > "$NVR_TEST_DIR/post.out"
check "unknown action -> 400" "400" "$NVR_TEST_DIR/post.out"

echo "=== 13e. dashboard POST: force triggers a (dry-run) cycle"
reset "$S0" "$SAMPLE_URL" ""
post "action=force" > "$NVR_TEST_DIR/post.out"
check "force redirects" "303" "$NVR_TEST_DIR/post.out"
# generous window: the latency probe adds ~20 mocked jsonfilter calls before
# the decision line, and each spawn is slow under Git Bash (instant on-router)
n=0
while [ "$n" -lt 160 ] && ! grep -q "forced switch (manual)" "$LOG" 2>/dev/null; do
    /bin/sleep 0.25 2>/dev/null || sleep 1
    n=$((n + 1))
done
check "forced cycle logged" "forced switch (manual)" "$LOG"

echo "=== 13f. dashboard: cross-site POSTs still rejected (the only gate left)"
post "action=force" "http://evil.example/attack" > "$NVR_TEST_DIR/post.out"
check "foreign referer -> 403" "403" "$NVR_TEST_DIR/post.out"

echo "=== 13g. dashboard: CANDIDATES=5 keeps the current server on the board (load-rank 6)"
reset "$S6" "$SAMPLE_URL" "CANDIDATES=5"
sh "$SCRIPT" run
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>"$NVR_TEST_DIR/dash.err"
H6=$(jsonfilter -i "$SAMPLE" -e '@[6].hostname')
check "current row appended below the cutoff" "not a switch target" "$DASH"
check "current server still shown + marked" "$H6" "$DASH"
check "real load-rank kept on the appended row" ">6<" "$DASH"
check "board is sorted by load (lowest-load server first)" ">1</td><td class=\"sv\">$SB_HOST" "$DASH"
check_absent "no shell errors with a small candidate count" "." "$NVR_TEST_DIR/dash.err"

echo "=== 13h. dashboard: dry-run log lines only show in dry-run mode"
reset "203.0.113.99" "$SAMPLE_URL" ""
sh "$SCRIPT" run     # writes a DRY-RUN: would switch line (harness conf is dry)
sed -i 's/^DRY_RUN=1/DRY_RUN=0/' "$NVR_CONF"
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check_absent "live mode hides dry-run chatter" "DRY-RUN: would switch" "$DASH"
sed -i 's/^DRY_RUN=0/DRY_RUN=1/' "$NVR_CONF"
sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "dry-run mode shows its own announcements" "DRY-RUN: would switch" "$DASH"

echo "=== 13i. save feedback: applying banner polls until the fresh list lands, warns on timeout"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" run     # reco.json now exists with a current mtime
NOWT=$(date +%s)
QUERY_STRING="msg=saved&t=1" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "data newer than the save -> applied" "Settings applied" "$DASH"
QUERY_STRING="msg=saved&t=$((NOWT + 30))" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "data older than the save -> applying banner" "Applying new settings" "$DASH"
check "applying page polls itself" 'http-equiv="refresh" content="3"' "$DASH"
touch -d '2020-01-01' "$NVR_TEST_DIR/state/reco.json"
QUERY_STRING="msg=saved&t=$((NOWT - 100))" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "refresh never landed -> timeout warning" "has not finished after 45" "$DASH"

echo "=== 13j. force feedback: waits while the run holds the lock, done when it reports back"
reset "$S0" "$SAMPLE_URL" ""
sh "$SCRIPT" run     # log exists with a current mtime
NOWT=$(date +%s)
mkdir -p "$NVR_TEST_DIR/state/lock"
QUERY_STRING="msg=forced&t=$((NOWT - 5))" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "log written but run still busy -> keeps waiting" "Switching servers" "$DASH"
rmdir "$NVR_TEST_DIR/state/lock"
QUERY_STRING="msg=forced&t=$((NOWT - 5))" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "run finished -> result message" "Forced switch finished" "$DASH"
QUERY_STRING="msg=forced&t=$((NOWT + 30))" sh "$ROOT/rotator-dashboard.cgi" > "$DASH" 2>/dev/null
check "run has not reported yet -> waiting banner + poll" 'http-equiv="refresh" content="3"' "$DASH"

echo "==="
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
