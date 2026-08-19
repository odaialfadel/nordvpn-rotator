#!/bin/sh
# rotator-dashboard.cgi — status page + controls for nordvpn-rotate.
# Installed to /www/cgi-bin/rotator; stock uhttpd executes it and nginx proxies
# /cgi-bin/ on port 80, so it answers at  http://192.168.8.1/cgi-bin/rotator
# (also :8080 direct, https :8443 self-signed).
#
# No authentication by design: this page lives on the LAN of a home router and
# anyone on that LAN already controls the GL panel. Cross-site POSTs from the
# internet are still rejected via the Referer host, so a malicious web page
# cannot click the buttons through your browser. Every setting incl. the
# live/dry-run mode is editable here.
#
# Design notes: Nord palette (Snow Storm light, Polar Night via
# prefers-color-scheme), system fonts only, no external requests, JS limited to
# auto-refresh, confirm guards and the settings policy preview. RTT column
# reads $STATE_DIR/latency, written by nordvpn-rotate.sh once per cycle. The
# "next pick" chip approximates the rotate script's choice (it additionally
# requires a parseable public key). After a save the script's `refresh` command
# re-fetches candidate data in the background so new settings show up within
# seconds, not on the next 30-min cron cycle.

CONF="${NVR_CONF:-/etc/nordvpn-rotate.conf}"
[ -f "$CONF" ] && . "$CONF"
LOAD_THRESHOLD="${LOAD_THRESHOLD:-60}"
MIN_IMPROVEMENT="${MIN_IMPROVEMENT:-15}"
MIN_DWELL_MIN="${MIN_DWELL_MIN:-60}"
NIGHTLY_ROTATE="${NIGHTLY_ROTATE:-1}"
DRY_RUN="${DRY_RUN:-0}"
WG_IFACE="${WG_IFACE:-wgclient}"
PEER_SECTION="${PEER_SECTION:-}"
CANDIDATES="${CANDIDATES:-20}"
case "$CANDIDATES" in ''|*[!0-9]*) CANDIDATES=20 ;; esac
STATE_DIR="${STATE_DIR:-/tmp/nordvpn-rotate}"
LOG_FILE="${LOG_FILE:-/tmp/nordvpn-rotate.log}"
RECO="$STATE_DIR/reco.json"
LAT_FILE="$STATE_DIR/latency"
ROTATE_BIN="${NVR_ROTATE_BIN:-/usr/bin/nordvpn-rotate.sh}"

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
jf() { jsonfilter -i "$RECO" -e "$1" 2>/dev/null; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
rtt_of() { awk -v ip="$1" '$1==ip{print $2; exit}' "$LAT_FILE" 2>/dev/null; }

fail() { printf 'Status: %s\r\nContent-Type: text/plain\r\n\r\n%s\n' "$1" "$2"; exit 0; }
redirect() { printf 'Status: 303 See Other\r\nLocation: %s\r\n\r\n' "$1"; exit 0; }

# --- POST: actions ------------------------------------------------------------
if [ "$REQUEST_METHOD" = "POST" ]; then
    case "$HTTP_REFERER" in
        *"//$HTTP_HOST/"*|*"//192.168.8.1/"*) : ;;
        *) fail "403 Forbidden" "cross-site request rejected" ;;
    esac
    len="${CONTENT_LENGTH:-0}"
    is_uint "$len" && [ "$len" -gt 0 ] && [ "$len" -le 4096 ] || fail "400 Bad Request" "bad content length"
    body=$(head -c "$len")
    action=""; th=""; imp=""; dwell=""; nightly="0"; country=""; cand=""; mode=""
    OLDIFS=$IFS; IFS='&'
    for pair in $body; do
        k="${pair%%=*}"; v="${pair#*=}"
        case "$k" in
            action)          action="$v" ;;
            LOAD_THRESHOLD)  th="$v" ;;
            MIN_IMPROVEMENT) imp="$v" ;;
            MIN_DWELL_MIN)   dwell="$v" ;;
            NIGHTLY_ROTATE)  nightly="$v" ;;
            COUNTRY_ID)      country="$v" ;;
            CANDIDATES)      cand="$v" ;;
            MODE)            mode="$v" ;;
        esac
    done
    IFS=$OLDIFS
    case "$action" in
    force)
        "$ROTATE_BIN" force >/dev/null 2>&1 &
        redirect "/cgi-bin/rotator?msg=forced" ;;
    save)
        # values arrive urlencoded, but digits never need encoding — the
        # numeric whitelist below doubles as decoding safety
        for v in "$th" "$imp" "$dwell" "$country" "$cand"; do
            is_uint "$v" || fail "400 Bad Request" "numbers only"
        done
        { [ "$th" -ge 1 ] && [ "$th" -le 100 ] && [ "$imp" -le 100 ] && [ "$dwell" -le 1440 ] \
            && [ "$country" -ge 1 ] && [ "$country" -le 999 ] && [ "$cand" -ge 1 ] && [ "$cand" -le 30 ]; } \
            || fail "400 Bad Request" "out of range (threshold 1-100, improvement 0-100, dwell 0-1440, country 1-999, candidates 1-30)"
        case "$nightly" in 0|1) : ;; *) fail "400 Bad Request" "bad nightly value" ;; esac
        case "$mode" in live|dry) : ;; *) fail "400 Bad Request" "bad mode value" ;; esac
        setconf() {
            if grep -q "^$1=" "$CONF" 2>/dev/null; then
                sed -i "s/^$1=.*/$1=$2/" "$CONF"
            else
                echo "$1=$2" >> "$CONF"
            fi
        }
        setconf LOAD_THRESHOLD "$th"
        setconf MIN_IMPROVEMENT "$imp"
        setconf MIN_DWELL_MIN "$dwell"
        setconf NIGHTLY_ROTATE "$nightly"
        setconf COUNTRY_ID "$country"
        setconf CANDIDATES "$cand"
        if [ "$mode" = "dry" ]; then setconf DRY_RUN 1; else setconf DRY_RUN 0; fi
        # apply immediately: re-fetch the candidate list with the new settings
        # in the background — the page shows fresh data on its next refresh
        "$ROTATE_BIN" refresh >/dev/null 2>&1 &
        redirect "/cgi-bin/rotator?msg=saved" ;;
    *) fail "400 Bad Request" "unknown action" ;;
    esac
fi

# --- GET: gather state (read-only) --------------------------------------------
NOW=$(date +%s)
SECT="$PEER_SECTION"
[ -n "$SECT" ] || SECT=$(uci -q get "network.$WG_IFACE.config" 2>/dev/null)
CFG_EP=$(uci -q get "wireguard.$SECT.end_point" 2>/dev/null)
CFG_HOST="${CFG_EP%:*}"; CFG_HOST="${CFG_HOST#[}"; CFG_HOST="${CFG_HOST%]}"

VPN_UP=no
ubus call "network.interface.$WG_IFACE" status 2>/dev/null \
    | jsonfilter -e '@.up' 2>/dev/null | grep -q true && VPN_UP=yes

CUR_IP=""; HS_AGE=""
if command -v wg >/dev/null 2>&1; then
    CUR_IP=$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk '{print $2; exit}')
    CUR_IP="${CUR_IP%:*}"; CUR_IP="${CUR_IP#[}"; CUR_IP="${CUR_IP%]}"
    [ "$CUR_IP" = "(none)" ] && CUR_IP=""
    hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    if is_uint "$hs" && [ "$hs" -gt 0 ]; then
        HS_AGE=$((NOW - hs))
        [ "$HS_AGE" -lt 0 ] && HS_AGE=0
    fi
fi
[ -n "$CUR_IP" ] || CUR_IP="$CFG_HOST"

HS_TEXT="unknown"; HS_CLS="warn"
if [ -n "$HS_AGE" ]; then
    HS_TEXT="${HS_AGE} s ago"
    if [ "$HS_AGE" -lt 190 ]; then HS_CLS="good"
    elif [ "$HS_AGE" -lt 600 ]; then HS_CLS="warn"
    else HS_CLS="bad"; fi
fi

# --- candidate board ----------------------------------------------------------
# The rotate script fetches a pool of at least 20 servers; only the top
# $CANDIDATES rows are switch targets and get displayed. The CURRENT server is
# matched anywhere in the pool — when it sits below the display cutoff its row
# is appended (real rank kept) so it never vanishes from the board.
CUR_HOST=""; CUR_LOAD=""; CUR_RANK=""; CUR_CITY=""; CUR_RTT=""
BEST_HOST=""; BEST_LOAD=""
FOUND=0; ROWS=""; CUR_ROW=""; FETCHED=""; FETCH_AGE=""; COUNTRY_NAME=""
if [ -f "$RECO" ]; then
    FETCHED=$(date -r "$RECO" '+%H:%M' 2>/dev/null)
    ft=$(date -r "$RECO" +%s 2>/dev/null)
    is_uint "$ft" && FETCH_AGE=$(( (NOW - ft) / 60 ))
    COUNTRY_NAME=$(jf '@[0].locations[0].country.name')
    i=0
    while :; do
        host=$(jf "@[$i].hostname"); [ -n "$host" ] || break
        FOUND=$((i + 1))
        is_cur=0
        load=$(jf "@[$i].load"); station=$(jf "@[$i].station")
        if [ "$station" = "$CUR_IP" ] || [ "$host" = "$CFG_HOST" ]; then is_cur=1; fi
        # below the display cutoff only the current server's row is built
        if [ "$i" -ge "$CANDIDATES" ] && [ "$is_cur" != "1" ]; then i=$((i + 1)); continue; fi
        city=$(jf "@[$i].locations[0].country.city.name")
        is_uint "$load" || load=""
        rtt=""
        [ -n "$station" ] && rtt=$(rtt_of "$station")
        [ -n "$rtt" ] && rtt_txt="$rtt ms" || rtt_txt="&#8211;"
        cls=""; chip=""
        if [ "$is_cur" = "1" ]; then
            CUR_HOST="$host"; CUR_LOAD="$load"; CUR_RANK=$((i + 1))
            CUR_CITY="$city"; CUR_RTT="$rtt"
            cls=" class=\"cur\""; chip="<span class=\"chip me\">&#9664; current</span>"
            [ "$i" -ge "$CANDIDATES" ] && cls=" class=\"cur below\""
        elif [ -z "$BEST_HOST" ] && [ -n "$load" ] && [ -n "$station" ]; then
            BEST_HOST="$host"; BEST_LOAD="$load"
            chip="%%BESTCHIP%%"
        fi
        [ -n "$load" ] && [ "$load" -ge "$LOAD_THRESHOLD" ] && barcls="hot" || barcls="cool"
        row="<tr$cls><td class=\"rk\">$((i + 1))</td><td class=\"sv\">$(printf '%s' "$host" | esc)<span class=\"st\">$(printf '%s' "$station" | esc)</span></td><td class=\"ct\">$(printf '%s' "$city" | esc)</td><td class=\"ld\"><div class=\"bar\"><i class=\"$barcls\" style=\"width:${load:-0}%\"></i></div><span class=\"n $barcls\">${load:-?}%</span></td><td class=\"rt\">$rtt_txt</td><td class=\"vc\">$chip</td></tr>"
        if [ "$is_cur" = "1" ] && [ "$i" -ge "$CANDIDATES" ]; then
            CUR_ROW="<tr class=\"gaprow\"><td colspan=\"6\">&#8942; not a switch target &mdash; ranked below the top $CANDIDATES</td></tr>$row"
        else
            ROWS="$ROWS$row"
        fi
        i=$((i + 1))
    done
    ROWS="$ROWS$CUR_ROW"
fi

# --- decision -----------------------------------------------------------------
LAST_SWITCH="never (or state cleared by reboot)"
DWELL_LEFT=""
last=$(cat "$STATE_DIR/last_switch" 2>/dev/null)
if is_uint "$last" && [ "$last" -gt 0 ]; then
    ago_min=$(( (NOW - last) / 60 ))
    if [ "$ago_min" -ge 120 ]; then LAST_SWITCH="$((ago_min / 60)) h ago"; else LAST_SWITCH="$ago_min min ago"; fi
    [ "$ago_min" -lt "$MIN_DWELL_MIN" ] && DWELL_LEFT=$((MIN_DWELL_MIN - ago_min))
fi

WOULD=0
if [ "$FOUND" -eq 0 ]; then
    VERDICT="No decision data yet — the rotator has not completed a cycle since the last reboot."
elif [ -z "$CUR_LOAD" ]; then
    if [ -n "$BEST_HOST" ]; then
        VERDICT="Current server is not in the top $FOUND recommendations — next cycle switches to $BEST_HOST (${BEST_LOAD}% load)."
        WOULD=1
    else
        VERDICT="Current server is not in the recommendations and no usable candidate was found — holding."
    fi
elif [ "$CUR_LOAD" -lt "$LOAD_THRESHOLD" ]; then
    VERDICT="Holding — $CUR_HOST at ${CUR_LOAD}% is under the ${LOAD_THRESHOLD}% switch line."
elif [ -n "$BEST_LOAD" ] && [ "$BEST_LOAD" -ge "$LOAD_THRESHOLD" ]; then
    VERDICT="$CUR_HOST is over the line at ${CUR_LOAD}%, but every candidate is loaded too — holding."
elif [ -n "$BEST_LOAD" ] && [ "$BEST_LOAD" -le $((CUR_LOAD - MIN_IMPROVEMENT)) ]; then
    VERDICT="Over the line — $CUR_HOST at ${CUR_LOAD}%; next cycle switches to $BEST_HOST (${BEST_LOAD}% load, ${MIN_IMPROVEMENT}+ points better)."
    WOULD=1
else
    VERDICT="$CUR_HOST is over the line at ${CUR_LOAD}%, but the best candidate is not ${MIN_IMPROVEMENT} points better — holding."
fi
[ -n "$DWELL_LEFT" ] && VERDICT="$VERDICT Dwell guard: no automatic switch for another $DWELL_LEFT min."
[ "$DRY_RUN" = "1" ] && VERDICT="$VERDICT Dry-run: decisions are only logged."

NEXT_CHIP=""
[ "$WOULD" = "1" ] && NEXT_CHIP='<span class="chip next">next pick</span>'
[ -n "$ROWS" ] && ROWS=$(printf '%s' "$ROWS" | sed "s|%%BESTCHIP%%|$NEXT_CHIP|")

# --- log timelines ------------------------------------------------------------
ev_html() { # stdin: chronological log lines -> styled rows, newest first
    sed '1!G;h;$!d' | awk '{
        ts=""; msg=$0
        if (msg ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] /) {
            ts=substr($0,6,11); msg=substr($0,21)
        }
        cls="mut"
        if      (msg ~ /^(SWITCHED|ROLLBACK OK|RECOVERY OK)/) cls="good"
        else if (msg ~ /^OK:/)                     cls="ok"
        else if (msg ~ /^HOLD:/)                   cls="hold"
        else if (msg ~ /^DRY-RUN:/)                cls="dry"
        else if (msg ~ /^(switching:|RECOVERY:)/)  cls="act"
        else if (msg ~ /^(ERROR|CRITICAL)/ || msg ~ /failed/) cls="bad"
        else if (msg ~ /^WARNING/)                 cls="warn"
        gsub(/&/,"\\&amp;",msg); gsub(/</,"\\&lt;",msg); gsub(/>/,"\\&gt;",msg)
        printf "<div class=\"ev %s\"><span class=\"t\">%s</span><span class=\"m\">%s</span></div>\n", cls, ts, msg
    }'
}
# dry-run chatter is only relevant while dry-run mode is active — in live mode
# the timelines show real actions only
if [ "$DRY_RUN" = "1" ]; then
    HIST=$(grep -E "SWITCHED|switching:|DRY-RUN|ROLLBACK|RECOVERY|CRITICAL|ERROR" "$LOG_FILE" 2>/dev/null | tail -n 15 | ev_html)
    ACT=$(tail -n 30 "$LOG_FILE" 2>/dev/null | ev_html)
else
    HIST=$(grep -E "SWITCHED|switching:|ROLLBACK|RECOVERY|CRITICAL|ERROR" "$LOG_FILE" 2>/dev/null | grep -v "DRY-RUN:" | tail -n 15 | ev_html)
    ACT=$(grep -v "DRY-RUN:" "$LOG_FILE" 2>/dev/null | tail -n 30 | ev_html)
fi

# --- page fragments -----------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
    BADGE='<span class="badge dry">dry-run</span>'
    FORCE_LABEL="Force switch (dry-run: logs only)"
    FORCE_CONFIRM="Dry-run: this only writes a log line. Continue?"
else
    BADGE='<span class="badge live">live</span>'
    FORCE_LABEL="Force switch now"
    FORCE_CONFIRM="Switch VPN server now? Family internet blips ~15 s."
fi
if [ "$VPN_UP" = "yes" ]; then
    VPN_BADGE='<span class="badge up">vpn up</span>'
else
    VPN_BADGE='<span class="badge down">vpn down</span>'
fi

MSG=""
case "$QUERY_STRING" in
    *msg=forced*) MSG="Forced switch triggered &mdash; the decision appears in the switch history below (page auto-refreshes)." ;;
    *msg=saved*)  MSG="Settings saved &mdash; the candidate list is re-fetching with the new values right now." ;;
esac

NIGHTLY_CHECKED=""
[ "$NIGHTLY_ROTATE" = "1" ] && NIGHTLY_CHECKED=" checked"
MODE_LIVE_CHECKED=" checked"; MODE_DRY_CHECKED=""
if [ "$DRY_RUN" = "1" ]; then MODE_LIVE_CHECKED=""; MODE_DRY_CHECKED=" checked"; fi

COUNTRY_ESC=$(printf '%s' "$COUNTRY_NAME" | esc)
HERO_HOST="${CUR_HOST:-$CUR_IP}"
HERO_SUB=""
if [ -n "$CUR_HOST" ]; then
    [ -n "$CUR_CITY" ] && HERO_SUB="$CUR_CITY"
    [ -n "$CUR_LOAD" ] && HERO_SUB="${HERO_SUB:+$HERO_SUB &middot; }load ${CUR_LOAD}%"
    [ -n "$CUR_RANK" ] && HERO_SUB="${HERO_SUB:+$HERO_SUB &middot; }rank $CUR_RANK of $FOUND"
else
    HERO_SUB="not in current recommendations"
fi
[ -z "$CUR_RTT" ] && [ -n "$CUR_IP" ] && CUR_RTT=$(rtt_of "$CUR_IP")
[ -n "$CUR_RTT" ] && HERO_SUB="$HERO_SUB &middot; ${CUR_RTT} ms"

CFG_NOTE=""
[ -n "$CFG_HOST" ] && [ "$CFG_HOST" != "$CUR_IP" ] && CFG_NOTE=" &middot; configured $(printf '%s' "$CFG_EP" | esc)"

FRESH_NOTE=""
if [ -n "$FETCH_AGE" ]; then
    FRESH_NOTE=" &middot; fetched $FETCHED (${FETCH_AGE} min ago)"
    [ "$FETCH_AGE" -gt 40 ] && FRESH_NOTE="$FRESH_NOTE <span class=\"stale\">stale &mdash; is cron running?</span>"
fi

GAUGE=""
if [ "$FOUND" -gt 0 ]; then
    DOTS=""
    LEGEND="<span class=\"lg\"><i class=\"tickl\"></i> switch line ${LOAD_THRESHOLD}%</span>"
    if [ -n "$CUR_LOAD" ]; then
        DOTS="$DOTS<b class=\"dot dc\" style=\"left:${CUR_LOAD}%\"></b>"
        LEGEND="<span class=\"lg\"><i class=\"dl dc\"></i> current ${CUR_LOAD}%</span> $LEGEND"
    fi
    if [ -n "$BEST_LOAD" ]; then
        DOTS="$DOTS<b class=\"dot db\" style=\"left:${BEST_LOAD}%\"></b>"
        LEGEND="$LEGEND <span class=\"lg\"><i class=\"dl db\"></i> best candidate ${BEST_LOAD}%</span>"
    fi
    GAUGE="<div class=\"track\" style=\"--th:${LOAD_THRESHOLD}%\"><i class=\"zone\"></i><b class=\"tick\"></b>$DOTS</div><div class=\"legend\">$LEGEND</div>"
fi

# --- render -------------------------------------------------------------------
printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
cat <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<noscript><meta http-equiv="refresh" content="60"></noscript>
<title>NordVPN rotator</title>
<script>
(function(){var t=null;try{t=localStorage.getItem('nvrTheme')}catch(e){}
if(t!=='light'&&t!=='dark'){t=window.matchMedia&&matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'}
document.documentElement.setAttribute('data-theme',t);})();
</script>
<style>
:root{
 --bg:#F0F2F7; --panel:#fff; --line:#E3E7F0; --soft:#EEF1F7;
 --ink:#1B2240; --mut:#4C567A; --dim:#8A93AF;
 --teal:#21C7A8; --tealtx:#0B8A70; --blue:#5B8DEF; --bluetx:#3B6BD6;
 --red:#E64C7B; --redtx:#C9315F; --amber:#E9BE55; --ambertx:#8F6B00; --orange:#E08D5A;
 --dbg:#C9315F; --dtx:#fff;
 --mono:ui-monospace,"Cascadia Mono",Consolas,Menlo,monospace;
}
[data-theme=dark]{
 --bg:#0D1024; --panel:#161B33; --line:#272E4E; --soft:#222848;
 --ink:#E9ECF8; --mut:#B9C1DB; --dim:#7E88AC;
 --teal:#2EDCB9; --tealtx:#2EDCB9; --blue:#6E9BFF; --bluetx:#8AB0FF;
 --red:#F0567A; --redtx:#F2708F; --amber:#E8C56A; --ambertx:#E8C56A; --orange:#E89A66;
 --dbg:#F0567A; --dtx:#26060F;
}
*{box-sizing:border-box}
body{margin:0;padding:16px 14px 40px;background:var(--bg);color:var(--ink);
 font:14px/1.55 -apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:880px;margin:0 auto;display:grid;gap:12px}
.wrap>*{min-width:0}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px 18px}
.eyebrow{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);font-weight:600;margin:0 0 10px}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}
.brand{font-weight:700;letter-spacing:.02em}
.brand b{color:var(--tealtx)}
.badges{display:flex;gap:6px;align-items:center}
.badge{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
 padding:3px 10px;border-radius:999px}
.badge.dry{background:var(--amber);color:#4A3608} .badge.live{background:var(--teal);color:#073226}
.badge.up{background:transparent;color:var(--tealtx);border:1px solid var(--tealtx);padding:2px 9px}
.badge.down{background:var(--dbg);color:var(--dtx)}
.msg{background:var(--teal);color:#073226;padding:8px 14px;border-radius:8px}
.warnbox{background:var(--dbg);color:var(--dtx);padding:8px 14px;border-radius:8px}
h1{font:600 26px/1.2 var(--mono);margin:2px 0 6px;word-break:break-all}
.sub{color:var(--mut);font-size:15px}
.facts{color:var(--dim);font-size:12.5px;margin-top:10px;font-family:var(--mono)}
.hs.good{color:var(--tealtx)} .hs.warn{color:var(--ambertx)} .hs.bad{color:var(--redtx)}
.track{position:relative;height:12px;border-radius:6px;background:var(--soft);margin:18px 8px 8px}
.zone{position:absolute;left:var(--th);right:0;top:0;bottom:0;background:rgba(230,76,123,.15);border-radius:0 6px 6px 0}
.tick{position:absolute;left:var(--th);top:-4px;bottom:-4px;width:2px;background:var(--red)}
.dot{position:absolute;top:50%;width:14px;height:14px;border-radius:50%;
 transform:translate(-50%,-50%);border:2px solid var(--panel);box-shadow:0 0 0 1px var(--line)}
.dc{background:var(--teal)} .db{background:var(--blue)}
.legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--dim);font-size:12px;margin:0 8px 12px}
.dl{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px}
.tickl{display:inline-block;width:2px;height:10px;background:var(--red);margin-right:5px}
.verdict{font-size:15px;margin:0}
.decfoot{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-top:12px}
.board{overflow-x:auto}
table{border-collapse:collapse;width:100%}
th{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--dim);
 text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}
td{padding:7px 10px;border-bottom:1px solid var(--soft);vertical-align:middle}
tr:last-child td{border-bottom:0}
.rk{color:var(--dim);font-family:var(--mono);width:1%}
.sv{font:600 13px var(--mono)}
.sv .st{display:block;font-weight:400;font-size:11px;color:var(--dim)}
.ct{color:var(--mut)}
.ld{white-space:nowrap}
.bar{display:inline-block;position:relative;width:90px;height:8px;background:var(--soft);
 border-radius:4px;vertical-align:middle;overflow:hidden}
.bar i{display:block;height:100%;border-radius:4px}
.bar::after{content:"";position:absolute;left:var(--th);top:0;bottom:0;width:1px;background:var(--dim);opacity:.55}
.bar i.cool{background:var(--teal)} .bar i.hot{background:var(--red)}
.ld .n{font-family:var(--mono);font-size:12.5px;margin-left:8px}
.ld .n.hot{color:var(--redtx);font-weight:600}
.rt{font-family:var(--mono);font-size:12.5px;text-align:right;white-space:nowrap}
th.rt{text-align:right}
.chip{font-size:11px;font-weight:600;border-radius:999px;padding:2px 9px;white-space:nowrap}
.chip.me{background:var(--teal);color:#073226}
.chip.next{background:var(--blue);color:#0E1B3D}
tr.cur td{background:rgba(35,200,170,.10)}
.stale{color:var(--ambertx);font-weight:600}
.tblnote{color:var(--dim);font-size:12px;margin:10px 0 0}
.ev{display:flex;gap:12px;padding:4px 10px;border-left:3px solid var(--line);
 font:12.5px/1.5 var(--mono);margin:2px 0}
.ev .t{color:var(--dim);white-space:nowrap}
.ev .m{overflow-wrap:anywhere}
.ev.ok{border-left-color:var(--blue)} .ev.good{border-left-color:var(--teal)}
.ev.hold{border-left-color:var(--amber)} .ev.dry{border-left-color:var(--orange)}
.ev.act{border-left-color:var(--teal)} .ev.warn{border-left-color:var(--amber)}
.ev.bad{border-left-color:var(--red);background:rgba(230,76,123,.08)}
.empty{color:var(--dim);font-family:var(--mono);font-size:12.5px}
details summary{cursor:pointer;color:var(--mut);font-size:13px}
details[open] summary{margin-bottom:8px}
.f label{display:block;font-size:11px;letter-spacing:.08em;text-transform:uppercase;
 color:var(--dim);font-weight:600;margin-bottom:4px}
.f .hint{font-size:11px;color:var(--dim);margin-top:3px}
input[type=number]{width:100%;background:var(--bg);color:var(--ink);
 border:1px solid var(--line);border-radius:6px;padding:6px 8px;font:13px var(--mono)}
.mode{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.seg{position:relative;display:block;cursor:pointer}
.seg input{position:absolute;opacity:0}
.segbody{display:block;height:100%;border:1px solid var(--line);border-radius:8px;
 padding:9px 12px;background:var(--bg)}
.segbody b{display:block;font-size:13px}
.segbody small{display:block;color:var(--dim);font-size:11.5px;line-height:1.35;margin-top:2px}
.seg input:checked+.segbody{border-color:var(--tealtx);box-shadow:inset 0 0 0 1px var(--tealtx)}
.seg input:checked+.segbody b::after{content:"\25CF";float:right;font-size:9px;color:var(--tealtx)}
.seg input[value=dry]:checked+.segbody{border-color:var(--ambertx);box-shadow:inset 0 0 0 1px var(--ambertx)}
.seg input[value=dry]:checked+.segbody b::after{color:var(--ambertx)}
.seg input:focus-visible+.segbody{outline:2px solid var(--tealtx);outline-offset:2px}
.fs{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-top:12px}
fieldset{border:1px solid var(--line);border-radius:8px;padding:10px 14px 12px;margin:0;min-width:0}
legend{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);
 font-weight:600;padding:0 6px}
fieldset .f{margin:8px 0 10px}
fieldset .f:last-child{margin-bottom:0}
.unit{display:flex;align-items:stretch}
.unit input[type=number]{flex:1;min-width:0;border-radius:6px 0 0 6px;border-right:0}
.unit i{font:11px/1 var(--mono);font-style:normal;color:var(--dim);background:var(--soft);
 border:1px solid var(--line);border-left:0;border-radius:0 6px 6px 0;
 display:flex;align-items:center;padding:0 8px;white-space:nowrap}
.nightly{display:block;color:var(--mut);margin:8px 0 3px}
.policy{font:12.5px/1.5 var(--mono);color:var(--mut);background:var(--soft);
 border-radius:8px;padding:9px 12px;margin:14px 0 12px;overflow-wrap:anywhere}
.policy .pk{color:var(--dim)}
.savebar{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
tr.gaprow td{color:var(--dim);font-size:11.5px;text-align:center;padding:5px 10px;border-bottom:0}
tr.below td{border-top:1px dashed var(--dim)}
button{background:var(--teal);color:#073226;border:0;border-radius:6px;
 padding:8px 16px;font:600 13px -apple-system,"Segoe UI",sans-serif;cursor:pointer}
button.danger{background:var(--dbg);color:var(--dtx)}
button.theme{background:transparent;color:var(--mut);border:1px solid var(--line);
 border-radius:999px;padding:2px 9px;font-size:13px;line-height:1.4}
button:focus-visible,input:focus-visible,summary:focus-visible,a:focus-visible{
 outline:2px solid var(--tealtx);outline-offset:2px}
.note{color:var(--dim);font-size:12px}
.foot{color:var(--dim);font-size:12px;text-align:center}
@media (max-width:620px){
 h1{font-size:20px}
 .sv .st{display:none}
 .ct{display:none}
 .bar{display:none}
 .ld .n{margin-left:0}
 td,th{padding-left:7px;padding-right:7px}
 .chip{font-size:10px;padding:2px 6px}
 .panel{padding:13px 14px}
 .ev{gap:8px}
}
</style></head><body><div class="wrap">
<div class="topbar">
<span class="brand">Nord<b>VPN</b> rotator${COUNTRY_ESC:+ &middot; <span class=note>$COUNTRY_ESC</span>}</span>
<span class="badges">$BADGE $VPN_BADGE <button type="button" id="themebtn" class="theme" onclick="themeFlip()" aria-label="toggle light/dark theme">&#9790;</button></span>
</div>
${MSG:+<div class="msg">$MSG</div>}
$([ "$VPN_UP" = "yes" ] || echo '<div class="warnbox">VPN interface is DOWN or off &mdash; the rotator leaves it alone while off.</div>')
<div class="panel">
<p class="eyebrow">current server</p>
<h1>$(printf '%s' "${HERO_HOST:-?}" | esc)</h1>
<div class="sub">$HERO_SUB</div>
<div class="facts">endpoint $(printf '%s' "${CUR_IP:-?}" | esc)$CFG_NOTE &middot; handshake <span class="hs $HS_CLS">$HS_TEXT</span> &middot; last switch $LAST_SWITCH</div>
</div>
<div class="panel">
<p class="eyebrow">decision</p>
$GAUGE
<p class="verdict">$(printf '%s' "$VERDICT" | esc)</p>
<div class="decfoot">
<span class="note">policy: switch when load &#8805; ${LOAD_THRESHOLD}% and a candidate is ${MIN_IMPROVEMENT}+ points lower &middot; ${MIN_DWELL_MIN} min dwell$([ "$NIGHTLY_ROTATE" = "1" ] && echo " &middot; nightly fresh IP 04:15")</span>
<form method="post" onsubmit="return confirm('$FORCE_CONFIRM')">
<input type="hidden" name="action" value="force">
<button class="danger">$FORCE_LABEL</button>
</form>
</div>
</div>
<div class="panel">
<p class="eyebrow">candidates &middot; ranked by NordVPN$FRESH_NOTE</p>
$(if [ -n "$ROWS" ]; then cat <<BOARD
<div class="board" style="--th:${LOAD_THRESHOLD}%">
<table>
<tr><th>#</th><th>server</th><th class="ct">city</th><th>load</th><th class="rt">rtt</th><th></th></tr>
$ROWS
</table>
</div>
<p class="tblnote">load from NordVPN's API &middot; rtt pinged from the router each cycle (current server direct, others through the tunnel) &middot; the tick on each bar is the ${LOAD_THRESHOLD}% switch line</p>
BOARD
else
    echo '<p class="empty">no candidate data yet &mdash; the rotator has not run since the last reboot.</p>'
fi)
</div>
<div class="panel">
<p class="eyebrow">settings</p>
<form method="post" id="cfgform">
<input type="hidden" name="action" value="save">
<div class="mode" role="radiogroup" aria-label="rotator mode">
<label class="seg"><input type="radio" name="MODE" value="live"$MODE_LIVE_CHECKED><span class="segbody"><b>Live</b><small>switches servers for real &mdash; the normal mode</small></span></label>
<label class="seg"><input type="radio" name="MODE" value="dry"$MODE_DRY_CHECKED><span class="segbody"><b>Dry-run</b><small>logs every decision, touches nothing &mdash; for testing</small></span></label>
</div>
<div class="fs">
<fieldset><legend>when to switch</legend>
<div class="f"><label for="in-th">switch line</label><span class="unit"><input id="in-th" type="number" name="LOAD_THRESHOLD" min="1" max="100" value="$LOAD_THRESHOLD"><i>%</i></span><div class="hint">switch when the current load reaches this</div></div>
<div class="f"><label for="in-imp">min improvement</label><span class="unit"><input id="in-imp" type="number" name="MIN_IMPROVEMENT" min="0" max="100" value="$MIN_IMPROVEMENT"><i>pts</i></span><div class="hint">a candidate must be this much lower</div></div>
<div class="f"><label for="in-dw">dwell</label><span class="unit"><input id="in-dw" type="number" name="MIN_DWELL_MIN" min="0" max="1440" value="$MIN_DWELL_MIN"><i>min</i></span><div class="hint">quiet time between switches</div></div>
</fieldset>
<fieldset><legend>server pool</legend>
<div class="f"><label for="in-cc">country</label><span class="unit"><input id="in-cc" type="number" name="COUNTRY_ID" min="1" max="999" value="$COUNTRY_ID"><i>id</i></span><div class="hint">81 = Germany &middot; list: api.nordvpn.com/v1/servers/countries</div></div>
<div class="f"><label for="in-cand">switch targets</label><span class="unit"><input id="in-cand" type="number" name="CANDIDATES" min="1" max="30" value="$CANDIDATES"><i>servers</i></span><div class="hint">top of NordVPN's ranking; the current server stays tracked even below this</div></div>
</fieldset>
<fieldset><legend>fresh ip</legend>
<label class="nightly"><input type="checkbox" name="NIGHTLY_ROTATE" value="1"$NIGHTLY_CHECKED> rotate every night at 04:15</label>
<div class="hint">a new address daily, while nobody is online &mdash; ages out website blocks</div>
</fieldset>
</div>
<p class="policy" id="polwrap" data-cid="$COUNTRY_ID" data-cname="$COUNTRY_ESC" aria-live="polite"><span class="pk">policy &#8594;</span> <span id="pol"></span></p>
<div class="savebar"><button>Save changes</button><span class="note">saving re-fetches the candidate list within seconds</span></div>
</form>
</div>
<div class="panel">
<p class="eyebrow">switch history &middot; newest first</p>
${HIST:-<p class=empty>(no switches or dry-run announcements yet)</p>}
</div>
<div class="panel">
<details>
<summary>Recent activity &mdash; last 30 log lines</summary>
${ACT:-<p class=empty>(no log yet)</p>}
</details>
</div>
<p class="foot">auto-refreshes every 60 s (paused while editing) &middot; generated $(date '+%Y-%m-%d %H:%M:%S')</p>
</div>
<script>
function themeIcon(){var b=document.getElementById('themebtn');
 if(b)b.innerHTML=document.documentElement.getAttribute('data-theme')==='dark'?'&#9788;':'&#9790;'}
function themeFlip(){var h=document.documentElement,
 t=h.getAttribute('data-theme')==='dark'?'light':'dark';
 h.setAttribute('data-theme',t);
 try{localStorage.setItem('nvrTheme',t)}catch(e){}
 themeIcon()}
themeIcon();
function polText(){
 var f=document.getElementById('cfgform'); if(!f)return;
 var w=document.getElementById('polwrap');
 var cc=f.COUNTRY_ID.value;
 var country=(cc===w.getAttribute('data-cid')&&w.getAttribute('data-cname'))
  ?w.getAttribute('data-cname'):('country '+cc);
 document.getElementById('pol').textContent=
  'switch when load ≥ '+f.LOAD_THRESHOLD.value+'% and a candidate is '
  +f.MIN_IMPROVEMENT.value+'+ pts lower · '+f.MIN_DWELL_MIN.value
  +' min dwell · top '+f.CANDIDATES.value+' of '+country
  +(f.NIGHTLY_ROTATE.checked?' · fresh IP nightly 04:15':'')
  +(f.MODE.value==='dry'?' · DRY-RUN: log only':' · LIVE');
}
(function(){var f=document.getElementById('cfgform');
 if(f){f.addEventListener('input',polText);f.addEventListener('change',polText);polText();}})();
(function(){
 function tick(){
  var e=document.activeElement;
  if(e&&/^(INPUT|SELECT|TEXTAREA)$/.test(e.tagName)){setTimeout(tick,15000);return}
  location.replace(location.pathname)}
 setTimeout(tick,60000);
})();
</script>
</body></html>
HTML
