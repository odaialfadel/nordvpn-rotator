#!/bin/sh
# nordvpn-rotate — load-threshold NordVPN WireGuard server rotation for GL.iNet 4.x
#
# Policy: every cron run, fetch NordVPN's recommended servers (sorted best-first,
# with load %). Switch ONLY when the current server is overloaded or has
# verifiably left NordVPN's recommendations — otherwise do nothing. "Verifiably"
# matters: the API rotates which ~20 servers it surfaces, so absence from the
# small display pool is checked against a deep top-$PROBE_LIMIT probe and must
# persist for $MISS_LIMIT consecutive cycles before it counts as delisted
# (a healthy 8%-load server was observed leaving the top-20 within 45 min while
# still sitting in the top-100 — switching on the small pool alone changed the
# IP at every dwell expiry). Runs LIVE by default; DRY_RUN=1 is the opt-in
# testing mode that only logs what it would do.
#
# Commands:
#   run     one decision cycle (what cron calls)          [default]
#   force   switch to the best candidate NOW (fresh IP when a site blocks you);
#           skips the load/dwell gates, keeps health check + rollback + DRY_RUN
#   nightly like force, but only when NIGHTLY_ROTATE=1 (cron calls it 04:15 —
#           NOT :00/:30, which would collide with the regular run for the lock)
#   refresh re-fetch the candidate list + latency with the current settings,
#           decide nothing (the dashboard calls it right after a config save)
#   check   read-only pre-flight: verify every assumption on this router
#   status  current server, last switch, recent log
#
# Requires (stock GL.iNet 4.x firmware): curl, jsonfilter, uci, ubus.
# Optional: wg (better health check). Never touches: private key, address, MTU,
# kill switch, DNS. Only ever edits end_point/public_key of the active peer.

VERSION="0.3.1"
CONF="${NVR_CONF:-/etc/nordvpn-rotate.conf}"
[ -f "$CONF" ] && . "$CONF"

# --- defaults (override in $CONF) --------------------------------------------
COUNTRY_ID="${COUNTRY_ID:-81}"            # 81 = Germany
LOAD_THRESHOLD="${LOAD_THRESHOLD:-60}"    # switch when current load >= this %
MIN_IMPROVEMENT="${MIN_IMPROVEMENT:-15}"  # candidate must be this much lower %
CANDIDATES="${CANDIDATES:-20}"            # switch targets considered/displayed
MIN_DWELL_MIN="${MIN_DWELL_MIN:-60}"      # min minutes between switch attempts
NIGHTLY_ROTATE="${NIGHTLY_ROTATE:-1}"     # 1 = rotate once nightly via cron (fresh IP)
DRY_RUN="${DRY_RUN:-0}"                   # 1 = log only, never touch the tunnel
WG_IFACE="${WG_IFACE:-wgclient}"          # GL.iNet 4.x wireguard client iface
PEER_SECTION="${PEER_SECTION:-}"          # empty = follow network.$WG_IFACE.config
WG_PORT="${WG_PORT:-51820}"
STATE_DIR="${STATE_DIR:-/tmp/nordvpn-rotate}"
LOG_FILE="${LOG_FILE:-/tmp/nordvpn-rotate.log}"
PREV_FILE="${PREV_FILE:-/etc/nordvpn-rotate.prev}"   # flash: survives reboot mid-switch
API_TIMEOUT="${API_TIMEOUT:-15}"
PROBE_LIMIT="${PROBE_LIMIT:-100}"         # deep window for the delist check
MISS_LIMIT="${MISS_LIMIT:-2}"             # consecutive probe misses = delisted
# every numeric knob degrades to its default instead of aborting the script:
# the conf is hand-editable, and in ash a bad value inside $((...)) is FATAL —
# it would kill the run exactly on the cycles where a switch decision is due
case "$LOAD_THRESHOLD" in ''|*[!0-9]*) LOAD_THRESHOLD=60 ;; esac
case "$MIN_IMPROVEMENT" in ''|*[!0-9]*) MIN_IMPROVEMENT=15 ;; esac
case "$MIN_DWELL_MIN" in ''|*[!0-9]*) MIN_DWELL_MIN=60 ;; esac
case "$WG_PORT" in ''|*[!0-9]*) WG_PORT=51820 ;; esac
case "$COUNTRY_ID" in ''|*[!0-9]*) COUNTRY_ID=81 ;; esac
case "$API_TIMEOUT" in ''|*[!0-9]*) API_TIMEOUT=15 ;; esac
case "$PROBE_LIMIT" in ''|*[!0-9]*) PROBE_LIMIT=100 ;; esac
case "$MISS_LIMIT" in ''|*[!0-9]*|0) MISS_LIMIT=2 ;; esac
# fetch a larger pool than CANDIDATES so the CURRENT server can still be found
# in it (and its load read) even when only a few switch targets are wanted —
# otherwise CANDIDATES=5 makes the current server "vanish" from the data and
# every cycle looks like a not-recommended-anymore switch reason
case "$CANDIDATES" in ''|*[!0-9]*) CANDIDATES=20 ;; esac
[ "$CANDIDATES" -gt 30 ] && CANDIDATES=30   # dashboard cap; also bounds cycle time
FETCH_LIMIT="$CANDIDATES"
[ "$FETCH_LIMIT" -lt 20 ] && FETCH_LIMIT=20
API_URL="${API_URL:-https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=${COUNTRY_ID}&filters[servers_technologies][identifier]=wireguard_udp&limit=${FETCH_LIMIT}}"
# separate deep-probe URL: reco.json stays small (the RTT probe pings it and the
# dashboard re-parses it per row), the probe file is read ONLY inside the
# delist check — never fed to probe_latency, never rendered by the CGI
PROBE_URL="${PROBE_URL:-https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=${COUNTRY_ID}&filters[servers_technologies][identifier]=wireguard_udp&limit=${PROBE_LIMIT}}"

# --- helpers -----------------------------------------------------------------
log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line" >> "$LOG_FILE"
    logger -t nordvpn-rotate "$*" 2>/dev/null
    if [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

die() { log "ERROR: $*"; exit 1; }

jf() { jsonfilter -i "$RECO" -e "$1" 2>/dev/null; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

vpn_active() {
    ubus call "network.interface.$WG_IFACE" status 2>/dev/null \
        | jsonfilter -e '@.up' 2>/dev/null | grep -q true
}

bounce() {
    ifdown "$WG_IFACE" 2>/dev/null
    sleep 2
    ifup "$WG_IFACE" 2>/dev/null
}

tunnel_healthy() {
    if command -v wg >/dev/null 2>&1; then
        hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        # ash has no local: don't reuse cmd_run's $now, it is still live here
        hs_now=$(date +%s)
        # 190s: above WireGuard's ~120-135s keepalive-only rekey cadence
        { is_uint "$hs" && [ "$hs" -gt 0 ] && [ $((hs_now - hs)) -lt 190 ]; } || return 1
    fi
    ping -c 1 -W 3 -I "$WG_IFACE" 1.1.1.1 >/dev/null 2>&1 \
        || ping -c 1 -W 3 -I "$WG_IFACE" 9.9.9.9 >/dev/null 2>&1
}

wait_healthy() {
    n=0
    while [ "$n" -lt 6 ]; do
        sleep 4
        tunnel_healthy && return 0
        n=$((n + 1))
    done
    return 1
}

active_section() {
    if [ -n "$PEER_SECTION" ]; then
        echo "$PEER_SECTION"
    else
        uci -q get "network.$WG_IFACE.config"
    fi
}

# one ping per candidate, cached for the dashboard's RTT column. Best effort:
# a server that drops ICMP just has no entry. Worst case adds ~1s per candidate
# to a cron cycle. Note the current server is reached directly (its endpoint
# bypasses the tunnel); other stations are measured through the tunnel.
probe_latency() {
    : > "$STATE_DIR/latency.new"
    pi=0
    while [ "$pi" -lt "$FETCH_LIMIT" ]; do
        st=$(jf "@[$pi].station")
        [ -n "$st" ] || break
        rtt=$(ping -c 1 -W 1 "$st" 2>/dev/null \
            | sed -n 's/.*time=\([0-9][0-9.]*\).*/\1/p' | head -n 1)
        [ -n "$rtt" ] && printf '%s %s\n' "$st" "${rtt%%.*}" >> "$STATE_DIR/latency.new"
        pi=$((pi + 1))
    done
    # pi=0 means the reco parse yielded no stations at all — keep the previous
    # cache rather than blanking the dashboard's RTT column on a bad fetch
    if [ "$pi" -gt 0 ] || [ ! -f "$STATE_DIR/latency" ]; then
        mv "$STATE_DIR/latency.new" "$STATE_DIR/latency"
    else
        rm -f "$STATE_DIR/latency.new"
    fi
}

# take the run lock; with $1=1 wait up to ~2 min for a busy one (a forced or
# nightly run must survive colliding with a regular cron cycle — the silent
# 04:30 collision used to eat the nightly rotation entirely)
take_lock() {
    if [ -d "$STATE_DIR/lock" ] && [ -n "$(find "$STATE_DIR/lock" -mmin +10 2>/dev/null)" ]; then
        # reclaim by rename, not rmdir: mv is the atomic arbiter, so a second
        # contender that also saw the stale dir cannot remove the fresh lock
        # the first one is about to create (rmdir-then-mkdir raced exactly so)
        if mv "$STATE_DIR/lock" "$STATE_DIR/lock.stale.$$" 2>/dev/null; then
            rm -rf "$STATE_DIR/lock.stale.$$"
        fi
    fi
    mkdir "$STATE_DIR/lock" 2>/dev/null && return 0
    [ "$1" = "1" ] || return 1
    lw=0
    while [ "$lw" -lt 24 ]; do
        sleep 5
        mkdir "$STATE_DIR/lock" 2>/dev/null && return 0
        lw=$((lw + 1))
    done
    return 1
}

# --- run: one decision cycle -------------------------------------------------
cmd_run() {
    mkdir -p "$STATE_DIR"
    RECO="$STATE_DIR/reco.json"

    # take the lock; a forced/nightly run waits for a colliding regular cycle
    if ! take_lock "${FORCE_REASON:+1}"; then
        if [ -n "$FORCE_REASON" ]; then
            log "skipped: another run still busy after 2 min wait ($FORCE_REASON lost)"
        else
            log "skipped: another run in progress"
        fi
        exit 0
    fi
    trap 'rmdir "$STATE_DIR/lock" 2>/dev/null' EXIT
    # a trapped signal does NOT end the script in ash — exit explicitly
    trap 'rmdir "$STATE_DIR/lock" 2>/dev/null; trap - EXIT; exit 130' INT TERM

    for tool in curl jsonfilter uci ubus; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
    done

    if ! vpn_active; then
        log "skipped: VPN interface $WG_IFACE is not active (left alone on purpose)"
        exit 0
    fi

    SECT=$(active_section)
    [ -n "$SECT" ] || die "cannot determine active peer section (network.$WG_IFACE.config)"
    CUR_EP=$(uci -q get "wireguard.$SECT.end_point")
    CUR_PUB=$(uci -q get "wireguard.$SECT.public_key")
    [ -n "$CUR_EP" ] || die "peer section '$SECT' has no end_point — assumptions wrong, not touching anything"

    # interrupted/failed switch from an earlier run (marker survives reboot):
    # if the tunnel is unhealthy, restore the last known-good peer first
    if [ -f "$PREV_FILE" ]; then
        if tunnel_healthy; then
            rm -f "$PREV_FILE"
        else
            read -r old_sect old_ep old_pub < "$PREV_FILE"
            case "$old_sect" in
                *:*) # legacy 2-field marker (endpoint pubkey) from <= 0.3.0
                     old_pub="$old_ep"; old_ep="$old_sect"; old_sect="$SECT" ;;
            esac
            if [ -z "$old_ep" ]; then
                rm -f "$PREV_FILE"
            elif [ "$old_sect" != "$SECT" ]; then
                # the user picked another profile in the GL panel since the
                # failed switch — never write an old endpoint into THEIR choice
                log "RECOVERY: switch marker is for peer '$old_sect' but '$SECT' is active now — dropping the marker, leaving the active peer alone"
                rm -f "$PREV_FILE"
            elif [ "$DRY_RUN" = "1" ]; then
                # dry-run means "touch nothing", including recovery — the user
                # may have frozen the rotator exactly to investigate this state
                log "DRY-RUN: would restore $old_ep (unfinished switch marker, tunnel unhealthy) — flip to live to let recovery run"
            else
                log "RECOVERY: unfinished switch marker found and tunnel unhealthy — restoring $old_ep"
                uci set "wireguard.$SECT.end_point=$old_ep"
                [ -n "$old_pub" ] && uci set "wireguard.$SECT.public_key=$old_pub"
                uci commit wireguard
                bounce
                if wait_healthy; then
                    log "RECOVERY OK: back on $old_ep"
                    rm -f "$PREV_FILE"
                else
                    log "RECOVERY attempt failed — will retry next cycle. First aid: GL panel -> VPN Dashboard -> toggle VPN off/on."
                fi
                date +%s > "$STATE_DIR/last_switch"
            fi
            exit 0
        fi
    fi

    # current server identity: prefer the LIVE endpoint (always an IP, even when
    # the config stores a hostname like frankfurt.de.wg.nordhold.net), fall back
    # to the configured endpoint host
    CFG_HOST="${CUR_EP%:*}"; CFG_HOST="${CFG_HOST#[}"; CFG_HOST="${CFG_HOST%]}"
    CUR_IP=""
    if command -v wg >/dev/null 2>&1; then
        CUR_IP=$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk '{print $2; exit}')
        CUR_IP="${CUR_IP%:*}"; CUR_IP="${CUR_IP#[}"; CUR_IP="${CUR_IP%]}"
        [ "$CUR_IP" = "(none)" ] && CUR_IP=""
    fi
    [ -n "$CUR_IP" ] || CUR_IP="$CFG_HOST"

    # a forced/nightly run reuses a recent candidate list instead of fetching:
    # the pick then comes from the exact list the dashboard is showing, and the
    # switch starts immediately (no fetch + no latency probes first)
    reuse=0
    if [ -n "$FORCE_REASON" ] && [ -f "$RECO" ]; then
        rt=$(date -r "$RECO" +%s 2>/dev/null)
        ct=$(date -r "$CONF" +%s 2>/dev/null)
        is_uint "$ct" || ct=0
        # a list fetched BEFORE the last settings save may be for the wrong
        # country/size — only reuse data newer than the conf
        if is_uint "$rt" && [ "$rt" -ge "$ct" ] && [ $(( $(date +%s) - rt )) -lt 600 ]; then
            reuse=1
            log "force: reusing the candidate list fetched $(( ( $(date +%s) - rt ) / 60 )) min ago (same list the dashboard shows)"
        fi
    fi
    if [ "$reuse" != "1" ]; then
        if ! curl -g -fsS --max-time "$API_TIMEOUT" "$API_URL" -o "$RECO.new"; then
            if tunnel_healthy; then
                log "skipped: API fetch failed (tunnel is healthy — transient, will retry next cycle)"
            else
                log "WARNING: API fetch failed AND tunnel looks unhealthy — cannot pick a new server without the API; check GL panel"
            fi
            exit 0
        fi
        mv "$RECO.new" "$RECO"
        probe_latency
    fi

    # pass 1 — walk the whole fetched pool once: collect (load, api-index,
    # station, host) and match the CURRENT server anywhere in the pool
    RANKF="$STATE_DIR/rank.$$"
    : > "$RANKF"
    CUR_LOAD=""; CUR_HOST=""; CUR_RANK=""; CUR_IDX=""
    i=0; found=0
    while :; do
        host=$(jf "@[$i].hostname")
        [ -n "$host" ] || break
        found=$((found + 1))
        load=$(jf "@[$i].load")
        station=$(jf "@[$i].station")
        # first identity match wins — a duplicate row later in the pool must
        # not steal CUR_IDX, or pass 2 would "switch" to the server we're on
        if [ -z "$CUR_IDX" ] && { [ "$station" = "$CUR_IP" ] || [ "$host" = "$CFG_HOST" ]; }; then
            CUR_HOST="$host"; CUR_IDX="$i"
            is_uint "$load" && CUR_LOAD="$load"
        fi
        if is_uint "$load" && [ -n "$station" ]; then
            # zero-padded composite key: plain lexical sort then equals numeric
            # (load, api-order) — BusyBox sort breaks -k2,2 numeric ties
            # lexically, so `sort -n -k1,1 -k2,2` is NOT portable here
            printf '%03d%03d %s %s %s %s\n' "$load" "$i" "$load" "$i" "$station" "$host" >> "$RANKF"
        fi
        i=$((i + 1))
    done
    [ "$found" -gt 0 ] || { rm -f "$RANKF"; die "API response parsed to zero servers — response format may have changed, not touching anything"; }

    # order by load, ties keep NordVPN's order — the dashboard sorts the same
    # way, so the engine's pick is always one of the rows the user is looking at
    sort "$RANKF" > "$RANKF.sorted"
    if [ -n "$CUR_IDX" ]; then
        CUR_RANK=$(awk -v idx="$CUR_IDX" '$3 == idx { print NR; exit }' "$RANKF.sorted")
    fi

    # pass 2 — pick the lowest-load candidate within the top $CANDIDATES,
    # skipping the current server; accept one only when its public key parses
    # too — never switch onto half-parsed data
    BEST_HOST=""; BEST_LOAD=""; BEST_STATION=""; BEST_PUB=""; BEST_LOC=""
    r=0
    while read -r skey load idx station host; do
        r=$((r + 1))
        [ "$r" -le "$CANDIDATES" ] || break
        [ "$idx" = "$CUR_IDX" ] && continue
        # identity, not just index: a duplicate row for the current server must
        # never be picked (a same-server "switch" bounces the tunnel for nothing)
        [ "$station" = "$CUR_IP" ] && continue
        [ -n "$CFG_HOST" ] && [ "$host" = "$CFG_HOST" ] && continue
        pub=$(jf "@[$idx].technologies[@.identifier=\"wireguard_udp\"].metadata[@.name=\"public_key\"].value")
        [ -n "$pub" ] || continue
        BEST_HOST="$host"; BEST_LOAD="$load"; BEST_STATION="$station"; BEST_PUB="$pub"
        cc=$(jf "@[$idx].locations[0].country.name")
        city=$(jf "@[$idx].locations[0].country.city.name")
        [ -n "$cc" ] && [ -n "$city" ] && BEST_LOC="$cc,$city"
        break
    done < "$RANKF.sorted"
    rm -f "$RANKF" "$RANKF.sorted"

    # delist bookkeeping: matched in the pool = definitely still recommended
    MISS_FILE="$STATE_DIR/cur_miss"
    [ -n "$CUR_IDX" ] && rm -f "$MISS_FILE"

    # decide ($FORCE_REASON set = force/nightly: switch regardless of load/dwell)
    reason=""
    if [ -n "$FORCE_REASON" ]; then
        reason="$FORCE_REASON"
        if [ -n "$CUR_LOAD" ]; then cur_desc="$CUR_HOST (${CUR_LOAD}%)"; else cur_desc="$CUR_IP"; fi
    elif [ -z "$CUR_IDX" ]; then
        # current server absent from the display pool. NordVPN rotates which
        # ~$FETCH_LIMIT servers the recommendations endpoint surfaces, so this
        # alone is NOT delisting — look it up in a much deeper window, and only
        # a persistent absence there counts as gone.
        RECO_PROBE="$STATE_DIR/reco-probe.json"
        if ! curl -g -fsS --max-time "$API_TIMEOUT" "$PROBE_URL" -o "$RECO_PROBE.new"; then
            # a fetch failure is no evidence of anything — never count it
            log "skipped: $CUR_IP not in the pool and the deep probe fetch failed — keeping it this cycle"
            exit 0
        fi
        mv "$RECO_PROBE.new" "$RECO_PROBE"
        p_load=$(jsonfilter -i "$RECO_PROBE" -e "@[@.station=\"$CUR_IP\"].load" 2>/dev/null | head -n 1)
        p_host=$(jsonfilter -i "$RECO_PROBE" -e "@[@.station=\"$CUR_IP\"].hostname" 2>/dev/null | head -n 1)
        if [ -z "$p_host" ] && [ -n "$CFG_HOST" ]; then
            # no live endpoint (no wg) + hostname-form config: match by hostname
            p_load=$(jsonfilter -i "$RECO_PROBE" -e "@[@.hostname=\"$CFG_HOST\"].load" 2>/dev/null | head -n 1)
            [ -n "$p_load" ] && p_host="$CFG_HOST"
        fi
        if [ -n "$p_host" ]; then
            # still recommended, just beyond the display pool — take the probed
            # load into the normal ladder below (an overloaded server can still
            # be fled; a healthy one is left alone)
            rm -f "$MISS_FILE"
            CUR_HOST="$p_host"
            is_uint "$p_load" && CUR_LOAD="$p_load"
        else
            m_ip=""; m_n=""
            [ -f "$MISS_FILE" ] && read -r m_ip m_n < "$MISS_FILE"
            miss=1
            # keyed by identity: another server's misses never carry over, and
            # a successful switch resets the count by changing the key. Never
            # reset on dwell/candidate holds — that would destroy the evidence.
            [ "$m_ip" = "$CUR_IP" ] && is_uint "$m_n" && miss=$((m_n + 1))
            printf '%s %s\n' "$CUR_IP" "$miss" > "$MISS_FILE"
            if [ "$miss" -lt "$MISS_LIMIT" ]; then
                log "HOLD: $CUR_IP not in the top $PROBE_LIMIT recommendations (miss $miss of $MISS_LIMIT) — switching only if this persists"
                exit 0
            fi
            reason="current server $CUR_IP absent from the top $PROBE_LIMIT recommendations for $miss consecutive cycles"
            cur_desc="$CUR_IP"
        fi
    fi
    if [ -z "$reason" ]; then
        if [ -z "$CUR_LOAD" ]; then
            # identity matched but the load field did not parse — a data
            # problem, never a delist; hold and let the next cycle retry
            log "WARNING: ${CUR_HOST:-$CUR_IP} is still recommended but its load did not parse — holding this cycle"
            exit 0
        fi
        if [ "$CUR_LOAD" -ge "$LOAD_THRESHOLD" ]; then
            if [ -n "$BEST_LOAD" ] && [ "$BEST_LOAD" -le $((CUR_LOAD - MIN_IMPROVEMENT)) ]; then
                reason="load ${CUR_LOAD}% >= threshold ${LOAD_THRESHOLD}%"
            else
                log "HOLD: $CUR_HOST at ${CUR_LOAD}% but best candidate ($BEST_HOST ${BEST_LOAD}%) is not ${MIN_IMPROVEMENT}% better"
                exit 0
            fi
            cur_desc="$CUR_HOST (${CUR_LOAD}%)"
        else
            if [ -n "$CUR_RANK" ]; then rank_desc="rank $CUR_RANK of $found"; else rank_desc="beyond the top $found pool, still recommended"; fi
            log "OK: $CUR_HOST load ${CUR_LOAD}% ($rank_desc, threshold ${LOAD_THRESHOLD}%)"
            exit 0
        fi
    fi

    [ -n "$BEST_HOST" ] || { log "HOLD: would switch ($reason) but no candidate found"; exit 0; }
    if [ "$BEST_LOAD" -ge "$LOAD_THRESHOLD" ]; then
        # a forced/nightly run exists to deliver a FRESH IP — a loaded candidate
        # still beats keeping yesterday's address, so only automatic runs hold
        if [ -n "$FORCE_REASON" ]; then
            log "note: best candidate $BEST_HOST is loaded (${BEST_LOAD}%) but the forced switch proceeds — fresh IP wins"
        else
            log "HOLD: would switch ($reason) but best candidate $BEST_HOST is also loaded (${BEST_LOAD}%)"
            exit 0
        fi
    fi

    # dwell guard (a forced switch is deliberate — dwell does not apply)
    now=$(date +%s)
    if [ -z "$FORCE_REASON" ]; then
        last=$(cat "$STATE_DIR/last_switch" 2>/dev/null || echo 0)
        is_uint "$last" || last=0
        if [ $((now - last)) -lt $((MIN_DWELL_MIN * 60)) ]; then
            log "HOLD: would switch ($reason) but last switch was $(((now - last) / 60)) min ago (dwell ${MIN_DWELL_MIN} min)"
            exit 0
        fi
    fi

    # mode gate: live is the default; ONLY the exact value 1 opts into dry-run
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: would switch $cur_desc -> $BEST_HOST ($BEST_STATION, load ${BEST_LOAD}%) [$reason]"
        exit 0
    fi
    [ "$DRY_RUN" = "0" ] || log "note: DRY_RUN='$DRY_RUN' unrecognized — treating as live (set 1 for dry-run)"

    # apply — marker first (flash), so a reboot/kill mid-switch is recoverable;
    # the marker records the section so recovery never writes into a peer the
    # user selected afterwards
    log "switching: $cur_desc -> $BEST_HOST ($BEST_STATION, load ${BEST_LOAD}%) [$reason]"
    printf '%s %s %s\n' "$SECT" "$CUR_EP" "$CUR_PUB" > "$PREV_FILE"
    uci set "wireguard.$SECT.end_point=$BEST_STATION:$WG_PORT"
    if [ "$BEST_PUB" != "$CUR_PUB" ]; then
        uci set "wireguard.$SECT.public_key=$BEST_PUB"
    fi
    # keep the GL panel's profile label truthful (it shows name/location, never
    # re-reads the endpoint); restore on rollback below
    CUR_NAME=$(uci -q get "wireguard.$SECT.name")
    CUR_LOC=$(uci -q get "wireguard.$SECT.location")
    [ -n "$CUR_NAME" ] && uci set "wireguard.$SECT.name=$BEST_HOST"
    [ -n "$CUR_LOC" ] && [ -n "$BEST_LOC" ] && uci set "wireguard.$SECT.location=$BEST_LOC"
    uci commit wireguard
    bounce
    if wait_healthy; then
        echo "$now" > "$STATE_DIR/last_switch"
        rm -f "$PREV_FILE"
        log "SWITCHED: now on $BEST_HOST ($BEST_STATION, load ${BEST_LOAD}%)"
        exit 0
    fi

    log "ERROR: tunnel not healthy on $BEST_HOST — rolling back to $CUR_EP"
    uci set "wireguard.$SECT.end_point=$CUR_EP"
    [ -n "$CUR_PUB" ] && uci set "wireguard.$SECT.public_key=$CUR_PUB"
    [ -n "$CUR_NAME" ] && uci set "wireguard.$SECT.name=$CUR_NAME"
    [ -n "$CUR_LOC" ] && uci set "wireguard.$SECT.location=$CUR_LOC"
    uci commit wireguard
    bounce
    echo "$now" > "$STATE_DIR/last_switch"   # cooldown after ANY failed attempt — no flap loops
    if wait_healthy; then
        rm -f "$PREV_FILE"
        log "ROLLBACK OK: back on $CUR_EP"
    else
        log "CRITICAL: rollback failed — tunnel down, kill switch is blocking family traffic. Auto-recovery retries next cycle. First aid: GL panel -> VPN Dashboard -> toggle VPN off/on."
    fi
    exit 1
}

# --- refresh: re-fetch candidate data, decide nothing --------------------------
# The dashboard fires this in the background right after a config save, so a
# changed country/candidate count shows up within seconds instead of waiting
# for the next 30-min cron cycle. Never touches the tunnel.
cmd_refresh() {
    mkdir -p "$STATE_DIR"
    RECO="$STATE_DIR/reco.json"
    for tool in curl jsonfilter; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
    done
    if ! take_lock 1; then
        log "refresh skipped: another run still busy"
        exit 0
    fi
    trap 'rmdir "$STATE_DIR/lock" 2>/dev/null' EXIT
    trap 'rmdir "$STATE_DIR/lock" 2>/dev/null; trap - EXIT; exit 130' INT TERM
    if ! curl -g -fsS --max-time "$API_TIMEOUT" "$API_URL" -o "$RECO.new"; then
        log "refresh: API fetch failed — keeping the previous candidate list"
        exit 1
    fi
    mv "$RECO.new" "$RECO"
    probe_latency
    n=0
    while [ -n "$(jf "@[$n].hostname")" ]; do n=$((n + 1)); done
    log "refreshed: $n servers fetched (country $COUNTRY_ID, top $CANDIDATES considered)"
}

# --- check: read-only pre-flight ---------------------------------------------
ck() { printf '%-6s %s\n' "$1" "$2"; }

cmd_check() {
    echo "nordvpn-rotate $VERSION pre-flight (read-only)"
    echo "---"
    for tool in curl jsonfilter uci ubus; do
        if command -v "$tool" >/dev/null 2>&1; then ck OK "tool: $tool"; else ck FAIL "tool MISSING: $tool"; fi
    done
    if command -v wg >/dev/null 2>&1; then ck OK "tool: wg (handshake check available)"; else ck WARN "tool: wg missing — health check will use ping only"; fi
    [ -f /etc/glversion ] && ck INFO "firmware: $(cat /etc/glversion)"

    if vpn_active; then ck OK "interface $WG_IFACE is up"; else ck WARN "interface $WG_IFACE is NOT up (VPN off?)"; fi
    if command -v wg >/dev/null 2>&1; then
        lep=$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk '{print $2; exit}')
        [ -n "$lep" ] && ck INFO "live endpoint: $lep"
        hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        if is_uint "$hs" && [ "$hs" -gt 0 ]; then ck OK "last handshake: $(($(date +%s) - hs))s ago"; else ck WARN "no wireguard handshake recorded"; fi
    fi
    if ping -c 1 -W 3 -I "$WG_IFACE" 1.1.1.1 >/dev/null 2>&1; then ck OK "ping through tunnel works"; else ck WARN "ping through tunnel failed"; fi
    SECT=$(active_section)
    if [ -n "$SECT" ]; then
        ck OK "active peer section: $SECT"
        ep=$(uci -q get "wireguard.$SECT.end_point")
        pub=$(uci -q get "wireguard.$SECT.public_key")
        if [ -n "$ep" ]; then ck OK "current endpoint: $ep"; else ck FAIL "no end_point on section '$SECT' — config layout differs from expectations"; fi
        if [ -n "$pub" ]; then ck OK "current public_key: $(echo "$pub" | cut -c1-12)..."; else ck WARN "no public_key on section '$SECT'"; fi
    else
        ck FAIL "cannot read network.$WG_IFACE.config — is the WireGuard client configured?"
    fi

    RECO="/tmp/nordvpn-rotate-check.$$"
    if curl -g -fsS --max-time "$API_TIMEOUT" "$API_URL" -o "$RECO"; then
        h=$(jsonfilter -i "$RECO" -e '@[0].hostname' 2>/dev/null)
        l=$(jsonfilter -i "$RECO" -e '@[0].load' 2>/dev/null)
        p=$(jsonfilter -i "$RECO" -e '@[0].technologies[@.identifier="wireguard_udp"].metadata[@.name="public_key"].value' 2>/dev/null)
        if [ -n "$h" ] && [ -n "$l" ] && [ -n "$p" ]; then
            ck OK "API + jsonfilter: best candidate $h load ${l}%"
        else
            ck FAIL "API reachable but jsonfilter could not parse it (host='$h' load='$l' pub present=$([ -n "$p" ] && echo yes || echo no))"
        fi
        # the delist probe depends on root-level predicates — verify on THIS
        # router's jsonfilter by looking the best candidate up by its station
        st=$(jsonfilter -i "$RECO" -e '@[0].station' 2>/dev/null)
        pl=$(jsonfilter -i "$RECO" -e "@[@.station=\"$st\"].load" 2>/dev/null | head -n 1)
        if [ -n "$st" ] && [ "$pl" = "$l" ]; then
            ck OK "jsonfilter station predicate works (delist probe usable)"
        else
            ck FAIL "jsonfilter station predicate unsupported — the delist probe cannot verify servers (got '$pl', expected '$l')"
        fi
        rm -f "$RECO"
        if curl -g -fsS --max-time "$API_TIMEOUT" "$PROBE_URL" -o "$RECO.probe" 2>/dev/null; then
            pn=$(grep -o '"hostname"' "$RECO.probe" 2>/dev/null | wc -l)
            ck OK "deep probe: $pn servers at limit $PROBE_LIMIT"
            rm -f "$RECO.probe"
        else
            ck WARN "deep probe URL fetch failed — delist checks would hold, not switch"
        fi
    else
        ck FAIL "cannot fetch $API_URL"
    fi

    if grep -q "nordvpn-rotate" /etc/crontabs/root 2>/dev/null; then ck OK "cron entry present"; else ck INFO "cron entry not installed yet"; fi
    if [ -f /etc/sysupgrade.conf ] && grep -q "nordvpn-rotate" /etc/sysupgrade.conf 2>/dev/null; then ck OK "sysupgrade.conf entries present"; else ck INFO "sysupgrade.conf entries not installed yet"; fi
    echo "---"
    echo "config: threshold=${LOAD_THRESHOLD}% improvement=${MIN_IMPROVEMENT}% dwell=${MIN_DWELL_MIN}min dry_run=${DRY_RUN} country=${COUNTRY_ID} iface=${WG_IFACE}"
}

# --- status ------------------------------------------------------------------
cmd_status() {
    SECT=$(active_section)
    echo "active section:  ${SECT:-unknown}"
    [ -n "$SECT" ] && echo "endpoint:        $(uci -q get "wireguard.$SECT.end_point")"
    last=$(cat "$STATE_DIR/last_switch" 2>/dev/null)
    now=$(date +%s)
    if is_uint "$last" && [ "$last" -gt 0 ]; then
        echo "last switch:     $(((now - last) / 60)) min ago"
    else
        echo "last switch:     never (or state cleared by reboot)"
    fi
    echo "--- last log lines ($LOG_FILE):"
    tail -n 15 "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
}

case "${1:-run}" in
    run)     cmd_run ;;
    force)   FORCE_REASON="forced switch (manual)"; cmd_run ;;
    nightly) [ "$NIGHTLY_ROTATE" = "1" ] || exit 0
             FORCE_REASON="forced switch (nightly rotation)"; cmd_run ;;
    refresh) cmd_refresh ;;
    check)   cmd_check ;;
    status)  cmd_status ;;
    *)       echo "usage: $0 [run|force|nightly|refresh|check|status]"; exit 2 ;;
esac
