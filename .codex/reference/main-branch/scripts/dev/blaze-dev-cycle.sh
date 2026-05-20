#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)"
RUN_DIR="${BLAZE_DEV_RUN_DIR:-$ROOT_DIR/build/dev-loop/$RUN_ID}"
RESTORE_AFTER="${SURGE_RESTORE_AFTER_SECONDS:-120}"
TEST_WINDOW="${BLAZE_TEST_WINDOW_SECONDS:-20}"

mkdir -p "$RUN_DIR"

log() {
    printf '[%s] %s\n' "$(/bin/date '+%H:%M:%S')" "$*" | /usr/bin/tee -a "$RUN_DIR/cycle.log"
}

run_step() {
    local name="$1"
    shift
    log "start: $name"
    {
        echo "### $name"
        echo "command: $*"
        "$@"
        echo
    } >>"$RUN_DIR/$name.log" 2>&1 || {
        local code=$?
        log "failed: $name exit=$code"
        return "$code"
    }
    log "done: $name"
}

blaze_listeners_running() {
    local count
    count="$(/usr/sbin/lsof -nP -iTCP:19080 -iTCP:19081 -sTCP:LISTEN 2>/dev/null | /usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }')"
    [[ "$count" -ge 2 ]]
}

restore_surge() {
    log "stopping Blaze packet tunnel before restoring Surge"
    "$ROOT_DIR/scripts/dev/blaze-control.sh" stop-tunnel >>"$RUN_DIR/blaze-stop-tunnel-restore.log" 2>&1 || true
    log "restoring Surge System Proxy + Enhanced Mode"
    if "$ROOT_DIR/scripts/dev/surge-control.sh" ensure-on >>"$RUN_DIR/surge-restore.log" 2>&1; then
        "$ROOT_DIR/scripts/dev/surge-control.sh" cancel-watchdog >>"$RUN_DIR/surge-restore.log" 2>&1 || true
    else
        log "Surge restore failed; leaving watchdog armed"
        return 1
    fi
}

trap restore_surge EXIT INT TERM

log "run_dir=$RUN_DIR"
log "arming offline Surge restore watchdog: ${RESTORE_AFTER}s"
"$ROOT_DIR/scripts/dev/surge-control.sh" arm-watchdog "$RESTORE_AFTER" >"$RUN_DIR/watchdog.txt"

run_step surge-status-before "$ROOT_DIR/scripts/dev/surge-control.sh" status
run_step blaze-launch "$ROOT_DIR/scripts/dev/blaze-control.sh" launch
if [[ "${BLAZE_ASSUME_LISTENERS:-0}" == "1" ]] || blaze_listeners_running; then
    log "Blaze local listeners already running; skipping UI menu automation"
    run_step blaze-listeners-status "$ROOT_DIR/scripts/dev/blaze-control.sh" status
else
    run_step blaze-start-listeners "$ROOT_DIR/scripts/dev/blaze-control.sh" start-listeners
fi
run_step blaze-start-tunnel "$ROOT_DIR/scripts/dev/blaze-control.sh" start-tunnel || true
run_step probe-before "$ROOT_DIR/scripts/dev/net-probe.sh" all

log "turning Surge takeover off for Blaze-only window"
"$ROOT_DIR/scripts/dev/surge-control.sh" off >"$RUN_DIR/surge-off.log" 2>&1

log "running Blaze-only probes for ${TEST_WINDOW}s"
run_step probe-blaze-only "$ROOT_DIR/scripts/dev/net-probe.sh" all || true

if [[ "${BLAZE_OPEN_BROWSER:-0}" == "1" ]]; then
    run_step browser-transparent "$ROOT_DIR/scripts/dev/net-probe.sh" browser-transparent || true
fi

if [[ "$TEST_WINDOW" =~ ^[0-9]+$ ]] && (( TEST_WINDOW > 0 )); then
    /bin/sleep "$TEST_WINDOW"
fi

run_step collect-logs "$ROOT_DIR/scripts/dev/collect-network-logs.sh" "$RUN_DIR/diagnostics"
restore_surge
trap - EXIT INT TERM

run_step probe-after-restore "$ROOT_DIR/scripts/dev/net-probe.sh" curl-surge || true
log "complete"
echo "$RUN_DIR"
