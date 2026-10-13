#!/usr/bin/env bash
#
# DealerPulse custom health checks -> Uptime Kuma push monitors.
#
# Why these three, and not netdata's stock alarms: netdata has ~290 alarms that
# fire correctly but have never had a delivery path, and most of them are noise
# for this workload. Rather than plumb a second notification system, these
# checks evaluate the few signals that actually matter here and push into Kuma,
# which already has a working, tested Slack route.
#
# READ-ONLY. Inspects metrics, logs and container state. Changes nothing.
#
# Install: /usr/local/bin/check-health.sh, run every minute by a systemd timer.
# Config:  /etc/default/check-health  (push tokens)

set -uo pipefail

KUMA_BASE="${KUMA_BASE:-https://uptime.callingyounow.us}"
# Kuma push tokens, one per monitor.
PUSH_THREADS="${PUSH_THREADS:-}"      # "DealerPulse Backend Threads"
PUSH_ERRORS="${PUSH_ERRORS:-}"        # "DealerPulse Error Rate"
PUSH_RESOURCES="${PUSH_RESOURCES:-}"  # "DealerPulse Host Resources"

NETDATA="http://127.0.0.1:19999"
ACTIVE_ENV_FILE="/opt/dealerpulse/backend/active_env"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
REDIS_CONTAINER="dealerpulse_backend-redis-1"

# --- Thresholds, all derived from measured behaviour -------------------------

# Backend threads. Normal daily peak over 2026-09-12..18 was 9-14. The
# 2026-09-16 outage climbed 12 -> 142 while CPU stayed at 8%. 30 is ~2x the
# highest normal peak and fires ~25 minutes into that incident.
THREAD_LIMIT="${THREAD_LIMIT:-30}"

# 5xx + 499 responses in one minute. Baseline is 0-1. The outage sustained
# roughly 5/min with bursts far higher.
ERROR_LIMIT="${ERROR_LIMIT:-10}"

DISK_LIMIT_PCT="${DISK_LIMIT_PCT:-80}"     # root filesystem, currently 30%
MEM_MIN_MB="${MEM_MIN_MB:-500}"            # available, currently ~4800 MB
REDIS_LIMIT_PCT="${REDIS_LIMIT_PCT:-80}"   # of maxmemory; eviction drops
                                           # queued Celery tasks silently

log() { printf '%s check-health: %s\n' "$(date -Is)" "$*" >&2; }

# push <token> <up|down> <message> <elapsed_ms>
push() {
    local token="$1" status="$2" msg="$3" ms="$4"
    if [ -z "$token" ]; then
        log "no token configured, would have sent: $status - $msg"
        return 0
    fi
    curl -fsS -m 10 --get \
        --data-urlencode "status=${status}" \
        --data-urlencode "msg=${msg}" \
        --data-urlencode "ping=${ms}" \
        "${KUMA_BASE}/api/push/${token}" >/dev/null \
        || log "PUSH FAILED: $status - $msg"
}

# --- 1. Backend thread count -------------------------------------------------
# The signal that caught the 2026-09-16 outage, and the only one that moved.
check_threads() {
    local start colour container value
    start=$(date +%s%3N)

    colour=$(cat "$ACTIVE_ENV_FILE" 2>/dev/null || echo blue)
    container="dealerpulse_backend-web_${colour}-1"

    # netdata's CSV output is CRLF-terminated, so strip \r before parsing —
    # without it the value comes through as $'7\r' and fails every numeric test.
    value=$(curl -fsS -m 8 \
        "${NETDATA}/api/v1/data?chart=cgroup_${container}.pids_current&after=-60&points=1&group=max&format=csv" \
        2>/dev/null | tr -d '\r' | tail -1 | cut -d, -f2 | cut -d. -f1)

    local elapsed=$(( $(date +%s%3N) - start ))

    # Regex rather than the `[ "$v" -eq "$v" ]` integer trick: that idiom
    # misbehaves inside an `||` list and reported a valid value of 7 as
    # unreadable on the first run.
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        push "$PUSH_THREADS" down "cannot read thread count for ${container} from netdata" "$elapsed"
        return
    fi

    if [ "$value" -gt "$THREAD_LIMIT" ]; then
        push "$PUSH_THREADS" down "${value} threads on ${colour} (limit ${THREAD_LIMIT}, normal 9-14) - requests are blocking and not returning" "$elapsed"
    else
        push "$PUSH_THREADS" up "${value} threads on ${colour}" "$elapsed"
    fi
}

# --- 2. Customer-visible error rate -----------------------------------------
# Counts the previous whole minute so the window is never partial.
# 499 matters as much as 5xx here: it means the caller gave up waiting, which
# on the Retell webhooks is a customer hearing silence on a live call.
check_errors() {
    local start window count
    start=$(date +%s%3N)

    window=$(date -u -d "1 minute ago" "+%d/%b/%Y:%H:%M")
    count=$(grep -F "$window" "$NGINX_ACCESS_LOG" 2>/dev/null \
            | awk '$9 ~ /^(50[0-9]|499)$/' | wc -l)

    local elapsed=$(( $(date +%s%3N) - start ))

    if [ "$count" -gt "$ERROR_LIMIT" ]; then
        push "$PUSH_ERRORS" down "${count} errors (5xx/499) in the last minute, limit ${ERROR_LIMIT}" "$elapsed"
    else
        push "$PUSH_ERRORS" up "${count} errors in the last minute" "$elapsed"
    fi
}

# --- 3. Host resources -------------------------------------------------------
# Slow-burn failures. The journal is uncapped and the box has no swap, so
# memory pressure goes straight to the OOM killer.
check_resources() {
    local start disk mem redis_used redis_max redis_pct problems
    start=$(date +%s%3N)
    problems=""

    disk=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    [ "${disk:-0}" -gt "$DISK_LIMIT_PCT" ] && problems="${problems}disk ${disk}% "

    mem=$(free -m | awk '/^Mem:/ {print $7}')
    [ "${mem:-99999}" -lt "$MEM_MIN_MB" ] && problems="${problems}memory ${mem}MB available "

    redis_used=$(docker exec "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null \
                 | grep -E "^used_memory:" | tr -d '\r' | cut -d: -f2)
    redis_max=$(docker exec "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null \
                | grep -E "^maxmemory:" | tr -d '\r' | cut -d: -f2)
    if [ -n "${redis_used:-}" ] && [ -n "${redis_max:-}" ] && [ "${redis_max:-0}" -gt 0 ]; then
        redis_pct=$(( redis_used * 100 / redis_max ))
        [ "$redis_pct" -gt "$REDIS_LIMIT_PCT" ] && problems="${problems}redis ${redis_pct}% of maxmemory (evicting queued tasks) "
    fi

    local elapsed=$(( $(date +%s%3N) - start ))

    if [ -n "$problems" ]; then
        push "$PUSH_RESOURCES" down "${problems}" "$elapsed"
    else
        push "$PUSH_RESOURCES" up "disk ${disk}%, mem ${mem}MB free, redis ${redis_pct:-?}%" "$elapsed"
    fi
}

check_threads
check_errors
check_resources
