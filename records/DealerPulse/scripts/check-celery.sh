#!/usr/bin/env bash
#
# Celery liveness check -> Uptime Kuma push monitors.
#
# Why this exists: `worker` and `beat` have no Docker health check and no
# restart policy. If either dies it stays dead, nothing restarts it, and the
# website stays green while appointment confirmations, reminder calls, no-show
# recovery and the hourly BDC report all silently stop. No HTTP monitor can see
# that. This script is what tells Kuma they are alive.
#
# It is READ-ONLY. It inspects container state and reads logs. It changes
# nothing and never restarts anything.
#
# Install: /usr/local/bin/check-celery.sh, run every minute by a systemd timer.
# Config:  /etc/default/check-celery  (holds the two push tokens)

set -uo pipefail

KUMA_BASE="${KUMA_BASE:-https://uptime.callingyounow.us}"
PUSH_BEAT="${PUSH_BEAT:-}"      # push token from the Kuma "beat" monitor
PUSH_WORKER="${PUSH_WORKER:-}"  # push token from the Kuma "worker" monitor

BEAT_CONTAINER="${BEAT_CONTAINER:-dealerpulse_backend-beat-1}"
WORKER_CONTAINER="${WORKER_CONTAINER:-dealerpulse_backend-worker-1}"

# beat dispatches `dispatch-appointment-confirmations` every single minute, so
# three minutes of silence from the scheduler is a genuine fault, not a quiet
# period.
BEAT_WINDOW="${BEAT_WINDOW:-3m}"
# the worker consumes those, but some tasks are slow, so allow more slack
# before calling it dead.
WORKER_WINDOW="${WORKER_WINDOW:-10m}"

log() { printf '%s check-celery: %s\n' "$(date -Is)" "$*" >&2; }

# push <token> <up|down> <message> <elapsed_ms>
push() {
    local token="$1" status="$2" msg="$3" ms="$4"
    if [ -z "$token" ]; then
        log "no push token configured, would have sent: $status - $msg"
        return 0
    fi
    if ! curl -fsS -m 10 --get \
            --data-urlencode "status=${status}" \
            --data-urlencode "msg=${msg}" \
            --data-urlencode "ping=${ms}" \
            "${KUMA_BASE}/api/push/${token}" >/dev/null; then
        log "PUSH FAILED for ${status} - ${msg}"
        return 1
    fi
}

# running <container>
running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# log_has <container> <since> <extended-regex>
#
# NOTE: deliberately NOT `grep -q`. With `pipefail` set, grep -q exits on the
# first match, closing the pipe, which kills `docker logs` with SIGPIPE (141)
# and makes the whole pipeline report failure even though the pattern matched.
# That produced a false "worker is wedged" on the first live run, because the
# worker's log is large enough for grep to exit before docker finishes writing,
# while beat's is small enough that it never triggered. Reading the full stream
# avoids it.
log_has() {
    docker logs --since "$2" "$1" 2>&1 | grep -E "$3" >/dev/null
}

check() {
    local name="$1" container="$2" window="$3" pattern="$4" token="$5"
    local start elapsed

    start=$(date +%s%3N)

    if ! docker inspect "$container" >/dev/null 2>&1; then
        elapsed=$(( $(date +%s%3N) - start ))
        push "$token" down "container ${container} does not exist" "$elapsed"
        return
    fi

    if ! running "$container"; then
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
        elapsed=$(( $(date +%s%3N) - start ))
        push "$token" down "${name} container is ${state:-unknown}, not running" "$elapsed"
        return
    fi

    # Running is not the same as working. A wedged Celery process stays
    # "running" indefinitely, which is exactly the failure we are trying to
    # catch, so check it is actually doing something.
    if ! log_has "$container" "$window" "$pattern"; then
        elapsed=$(( $(date +%s%3N) - start ))
        push "$token" down "${name} container is up but produced no activity in ${window} - likely wedged" "$elapsed"
        return
    fi

    elapsed=$(( $(date +%s%3N) - start ))
    push "$token" up "${name} running and active within ${window}" "$elapsed"
}

# beat logs "Scheduler: Sending due task <name> (<task>)" on every dispatch
check "beat" "$BEAT_CONTAINER" "$BEAT_WINDOW" \
      "Sending due task" "$PUSH_BEAT"

# worker logs "Task <name>[<uuid>] received" and "... succeeded"
check "worker" "$WORKER_CONTAINER" "$WORKER_WINDOW" \
      "Task .*(received|succeeded)" "$PUSH_WORKER"
