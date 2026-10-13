#!/usr/bin/env bash
#
# Third-party connectivity checks -> Uptime Kuma push monitors.
#
# Two modes, because one provider is far more expensive to check than the rest:
#
#   (no args)   five providers via plain python      ~0.3s  - every 5 minutes
#   --twilio    Twilio via `manage.py shell`         ~4.3s  - every 30 minutes
#
# Twilio needs Django loaded so SecretManager can decrypt its Fernet-encrypted
# credentials. That costs ~4.3s of CPU, which on a 2-vCPU box was a recurring
# 0.7-core burst every five minutes, competing with the latency-critical Retell
# webhook. Splitting it cut the daily cost from ~1238 to ~290 CPU-seconds.
#
# A provider with a blank push token is probed and logged but not reported to
# Kuma. That is how the currently-broken integrations are kept off the
# dashboard - a permanently red monitor teaches people to ignore red.

set -uo pipefail

KUMA_BASE="${KUMA_BASE:-https://uptime.callingyounow.us}"

PUSH_XTIME="${PUSH_XTIME:-}"
PUSH_TWILIO="${PUSH_TWILIO:-}"
PUSH_WASSENGER="${PUSH_WASSENGER:-}"
PUSH_ASSEMBLYAI="${PUSH_ASSEMBLYAI:-}"   # broken - account disabled at provider
PUSH_RETELL="${PUSH_RETELL:-}"           # broken - key missing
PUSH_OPENROUTER="${PUSH_OPENROUTER:-}"   # not in use per backend team

PROBE_FAST="/usr/local/bin/thirdparty-probe-fast.py"
PROBE_TWILIO="/usr/local/bin/thirdparty-probe-twilio.py"
ACTIVE_ENV_FILE="/opt/dealerpulse/backend/active_env"

MODE="${1:-fast}"

log() { printf '%s check-thirdparty: %s\n' "$(date -Is)" "$*" >&2; }

push() {
    local token="$1" status="$2" msg="$3" ms="$4" name="$5"
    if [ -z "$token" ]; then
        log "${name}: no monitor configured - ${status} - ${msg}"
        return 0
    fi
    curl -fsS -m 10 --get \
        --data-urlencode "status=${status}" \
        --data-urlencode "msg=${msg}" \
        --data-urlencode "ping=${ms}" \
        "${KUMA_BASE}/api/push/${token}" >/dev/null \
        || log "PUSH FAILED for ${name}: ${status} - ${msg}"
}

token_for() {
    case "$1" in
        XTIME)      printf '%s' "$PUSH_XTIME" ;;
        TWILIO)     printf '%s' "$PUSH_TWILIO" ;;
        WASSENGER)  printf '%s' "$PUSH_WASSENGER" ;;
        ASSEMBLYAI) printf '%s' "$PUSH_ASSEMBLYAI" ;;
        RETELL)     printf '%s' "$PUSH_RETELL" ;;
        OPENROUTER) printf '%s' "$PUSH_OPENROUTER" ;;
        *)          printf '' ;;
    esac
}

colour=$(cat "$ACTIVE_ENV_FILE" 2>/dev/null || echo blue)
container="dealerpulse_backend-web_${colour}-1"

if [ "$MODE" = "--twilio" ]; then
    PROVIDERS="TWILIO"
    # manage.py shell prints a banner to stdout, so filter to the result shape.
    output=$(docker exec -i -w /app/server "$container" \
                python manage.py shell -c "exec(open('/dev/stdin').read())" \
                < "$PROBE_TWILIO" 2>/dev/null | grep -E '^[A-Z]+\|(UP|DOWN)\|')
else
    PROVIDERS="XTIME WASSENGER ASSEMBLYAI RETELL OPENROUTER"
    output=$(docker exec -i "$container" python - \
                < "$PROBE_FAST" 2>/dev/null | grep -E '^[A-Z]+\|(UP|DOWN)\|')
fi

if [ -z "$output" ]; then
    for p in $PROVIDERS; do
        push "$(token_for "$p")" down "probe did not run - ${container} unreachable" 0 "$p"
    done
    exit 0
fi

while IFS='|' read -r name status msg ms; do
    [ -z "$name" ] && continue
    case "$status" in
        UP)   push "$(token_for "$name")" up   "$msg" "${ms:-0}" "$name" ;;
        DOWN) push "$(token_for "$name")" down "$msg" "${ms:-0}" "$name" ;;
    esac
done <<< "$output"
