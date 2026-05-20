#!/usr/bin/env bash
set -euo pipefail

SURGE_APP_NAME="${SURGE_APP_NAME:-Surge}"
SURGE_BUNDLE_ID="${SURGE_BUNDLE_ID:-com.nssurge.surge-mac}"
SURGE_VPN_SERVICE="${SURGE_VPN_SERVICE:-Surge}"
SURGE_SUPPORT_DIR="${SURGE_SUPPORT_DIR:-$HOME/Library/Application Support/com.nssurge.surge-mac}"
SURGE_INTERNAL_CONTROLLER="${SURGE_INTERNAL_CONTROLLER:-$SURGE_SUPPORT_DIR/internal-controller}"
SURGE_HTTP_PORT="${SURGE_HTTP_PORT:-6152}"
SURGE_SOCKS_PORT="${SURGE_SOCKS_PORT:-6153}"
SURGE_STOP_BLAZE_TUNNEL_ON_RESTORE="${SURGE_STOP_BLAZE_TUNNEL_ON_RESTORE:-1}"
BLAZE_VPN_SERVICE="${BLAZE_VPN_SERVICE:-blaze Packet Tunnel}"
WATCHDOG_SECONDS="${SURGE_RESTORE_AFTER_SECONDS:-120}"
STATE_DIR="${BLAZE_DEV_STATE_DIR:-$HOME/Library/Application Support/blaze/dev-loop}"
LOG_DIR="$STATE_DIR/logs"
PID_FILE="$STATE_DIR/surge-restore-watchdog.pid"

mkdir -p "$LOG_DIR"

usage() {
    cat <<'EOF'
Usage:
  scripts/dev/surge-control.sh status
  scripts/dev/surge-control.sh on
  scripts/dev/surge-control.sh off
  scripts/dev/surge-control.sh ensure-on
  scripts/dev/surge-control.sh arm-watchdog [seconds]
  scripts/dev/surge-control.sh cancel-watchdog
  scripts/dev/surge-control.sh restart
  scripts/dev/surge-control.sh quit
  scripts/dev/surge-control.sh force-kill

Notes:
  - on/off use macOS networksetup and scutil so restore does not depend on network access.
  - arm-watchdog starts a detached offline restore job. Use it before any test that turns Surge off.
  - restart/quit/force-kill are explicit operator commands and are not used by the dev cycle.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

json_value() {
    local key="$1"
    local file="$2"
    /usr/bin/sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"?([^\",}]+)\"?.*/\\1/p" "$file" | /usr/bin/head -1
}

surge_pid() {
    /usr/bin/pgrep -x "$SURGE_APP_NAME" 2>/dev/null | /usr/bin/head -1 || true
}

ensure_running() {
    if [[ -z "$(surge_pid)" ]]; then
        /usr/bin/open -ga "$SURGE_APP_NAME"
    fi
}

api_key() {
    [[ -f "$SURGE_INTERNAL_CONTROLLER" ]] || die "missing Surge internal controller file: $SURGE_INTERNAL_CONTROLLER"
    local key
    key="$(json_value pass "$SURGE_INTERNAL_CONTROLLER")"
    [[ -n "$key" ]] || die "failed to read Surge API key"
    printf '%s\n' "$key"
}

candidate_ports() {
    local configured_port internal_port
    configured_port="${SURGE_API_PORT:-}"
    internal_port=""
    if [[ -f "$SURGE_INTERNAL_CONTROLLER" ]]; then
        internal_port="$(json_value port "$SURGE_INTERNAL_CONTROLLER" || true)"
    fi

    {
        [[ -n "$configured_port" ]] && printf '%s\n' "$configured_port"
        if [[ "$internal_port" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$internal_port"
            printf '%s\n' "$((internal_port + 1))"
        fi
        if [[ -n "$(surge_pid)" ]]; then
            /usr/sbin/lsof -nP -c "$SURGE_APP_NAME" -a -iTCP -sTCP:LISTEN 2>/dev/null \
                | /usr/bin/awk '
                    NR > 1 {
                        if (match($0, /127\.0\.0\.1:([0-9]+)/)) {
                            value = substr($0, RSTART, RLENGTH)
                            sub(/^127\.0\.0\.1:/, "", value)
                            print value
                        }
                    }
                '
        fi
    } | /usr/bin/awk 'NF && !seen[$0]++'
}

discover_api_port() {
    local key port response
    key="$(api_key)"
    if [[ -n "${SURGE_API_PORT:-}" ]]; then
        printf '%s\n' "$SURGE_API_PORT"
        return 0
    fi
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        for _ in 1 2; do
            response="$(/usr/bin/curl --http0.9 -fsS --connect-timeout 1 --max-time 2 \
                -H "X-Key: $key" \
                -H "Accept: */*" \
                "http://127.0.0.1:$port/v1/features/system_proxy" 2>/dev/null || true)"
            if [[ "$response" == *'"enabled"'* ]]; then
                printf '%s\n' "$port"
                return 0
            fi
            /bin/sleep 0.1
        done
    done < <(candidate_ports)
    if [[ -f "$SURGE_INTERNAL_CONTROLLER" ]]; then
        local internal_port fallback_port
        internal_port="$(json_value port "$SURGE_INTERNAL_CONTROLLER" || true)"
        if [[ "$internal_port" =~ ^[0-9]+$ ]]; then
            fallback_port="$((internal_port + 1))"
            if /usr/bin/nc -z 127.0.0.1 "$fallback_port" >/dev/null 2>&1; then
                printf '%s\n' "$fallback_port"
                return 0
            fi
        fi
    fi
    return 1
}

api_request_to_port() {
    local method="$1"
    local port="$2"
    local endpoint="$3"
    local body="${4:-}"
    local key
    key="$(api_key)"

    if [[ "$method" == "GET" ]]; then
        /usr/bin/curl --http0.9 -fsS --connect-timeout 1 --max-time 5 \
            -H "X-Key: $key" \
            -H "Accept: */*" \
            "http://127.0.0.1:$port$endpoint"
    else
        /usr/bin/curl --http0.9 -fsS --connect-timeout 1 --max-time 8 \
            -X "$method" \
            -H "X-Key: $key" \
            -H "Accept: */*" \
            -H "Content-Type: application/json" \
            --data "$body" \
            "http://127.0.0.1:$port$endpoint"
    fi
}

api_request() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local port
    port="$(discover_api_port)" || die "failed to discover Surge HTTP API port"
    api_request_to_port "$method" "$port" "$endpoint" "$body"
}

set_feature() {
    local feature="$1"
    local enabled="$2"
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if api_request POST "/v1/features/$feature" "{\"enabled\":$enabled}" >/dev/null 2>&1; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

feature_enabled() {
    local feature="$1"
    api_request GET "/v1/features/$feature" | /usr/bin/grep -q '"enabled":true'
}

feature_enabled_at_port() {
    local port="$1"
    local feature="$2"
    local response=""
    for _ in 1 2 3; do
        response="$(api_request_to_port GET "$port" "/v1/features/$feature" 2>/dev/null || true)"
        [[ "$response" == *'"enabled"'* ]] && break
        /bin/sleep 0.1
    done
    [[ "$response" == *'"enabled":true'* ]]
}

wait_for_api() {
    local deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        if discover_api_port >/dev/null 2>&1; then
            return 0
        fi
        /bin/sleep 0.5
    done
    die "Surge HTTP API did not become ready"
}

default_interface() {
    /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}'
}

network_service_for_device() {
    local device="$1"
    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | /usr/bin/awk -v device="$device" '
        /^\([0-9]+\)/ {
            service = $0
            sub(/^\([0-9]+\)[[:space:]]*/, "", service)
        }
        index($0, "Device: " device ")") || index($0, "Device: " device ",") {
            print service
            exit
        }
    '
}

all_network_services() {
    /usr/sbin/networksetup -listallnetworkservices 2>/dev/null \
        | /usr/bin/sed '1d; s/^[*]//'
}

network_service() {
    if [[ -n "${SURGE_NETWORK_SERVICE:-}" ]]; then
        printf '%s\n' "$SURGE_NETWORK_SERVICE"
        return 0
    fi

    local device service
    device="$(default_interface)"
    if [[ -n "$device" ]]; then
        service="$(network_service_for_device "$device")"
        if [[ -n "$service" ]]; then
            printf '%s\n' "$service"
            return 0
        fi
    fi

    if /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/grep -qx "Wi-Fi"; then
        printf 'Wi-Fi\n'
        return 0
    fi

    all_network_services | /usr/bin/head -1
}

target_services() {
    if [[ -n "${SURGE_NETWORK_SERVICE:-}" ]]; then
        printf '%s\n' "$SURGE_NETWORK_SERVICE"
    else
        all_network_services
    fi
}

set_macos_system_proxy() {
    local enabled="$1"
    local service did_update=false

    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        did_update=true
        if [[ "$enabled" == "true" ]]; then
            /usr/sbin/networksetup -setwebproxy "$service" 127.0.0.1 "$SURGE_HTTP_PORT" >/dev/null
            /usr/sbin/networksetup -setsecurewebproxy "$service" 127.0.0.1 "$SURGE_HTTP_PORT" >/dev/null
            /usr/sbin/networksetup -setsocksfirewallproxy "$service" 127.0.0.1 "$SURGE_SOCKS_PORT" >/dev/null
            /usr/sbin/networksetup -setwebproxystate "$service" on >/dev/null
            /usr/sbin/networksetup -setsecurewebproxystate "$service" on >/dev/null
            /usr/sbin/networksetup -setsocksfirewallproxystate "$service" on >/dev/null
        else
            /usr/sbin/networksetup -setwebproxystate "$service" off >/dev/null
            /usr/sbin/networksetup -setsecurewebproxystate "$service" off >/dev/null
            /usr/sbin/networksetup -setsocksfirewallproxystate "$service" off >/dev/null
        fi
    done < <(target_services)

    [[ "$did_update" == "true" ]] || die "no macOS network services found"
}

surge_vpn_state() {
    /usr/sbin/scutil --nc status "$SURGE_VPN_SERVICE" 2>/dev/null | /usr/bin/head -1 || true
}

set_enhanced_mode() {
    local enabled="$1"
    if [[ "$enabled" == "true" ]]; then
        wait_for_api
        set_feature enhanced_mode true || die "failed to enable Surge Enhanced Mode through Surge app API"
    else
        set_feature enhanced_mode false >/dev/null 2>&1 || /usr/sbin/scutil --nc stop "$SURGE_VPN_SERVICE" >/dev/null 2>&1 || true
    fi
}

stop_conflicting_blaze_tunnel() {
    [[ "$SURGE_STOP_BLAZE_TUNNEL_ON_RESTORE" == "1" ]] || return 0
    /usr/sbin/scutil --nc stop "$BLAZE_VPN_SERVICE" >/dev/null 2>&1 || true
}

system_proxy_state() {
    local proxy
    proxy="$(/usr/sbin/scutil --proxy 2>/dev/null)"
    if [[ "$proxy" == *"HTTPEnable : 1"* \
        && "$proxy" == *"HTTPProxy : 127.0.0.1"* \
        && "$proxy" == *"HTTPPort : $SURGE_HTTP_PORT"* \
        && "$proxy" == *"SOCKSEnable : 1"* \
        && "$proxy" == *"SOCKSProxy : 127.0.0.1"* \
        && "$proxy" == *"SOCKSPort : $SURGE_SOCKS_PORT"* ]]; then
        printf 'on\n'
    else
        printf 'off\n'
    fi
}

print_status() {
    local pid port system_proxy enhanced_mode scutil_proxy
    pid="$(surge_pid)"
    port="$(discover_api_port 2>/dev/null || true)"
    system_proxy="$(system_proxy_state)"
    enhanced_mode="$(surge_vpn_state)"
    scutil_proxy="$(/usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/awk '
        /HTTPEnable|HTTPProxy|HTTPPort|HTTPSEnable|HTTPSProxy|HTTPSPort|SOCKSEnable|SOCKSProxy|SOCKSPort/ {
            gsub(/^[[:space:]]+/, "")
            print
        }
    ' | /usr/bin/paste -sd ';' -)"

    printf 'Surge process: %s\n' "${pid:-not running}"
    printf 'Surge API port: %s\n' "${port:-not available}"
    printf 'System Proxy: %s\n' "$system_proxy"
    printf 'Enhanced Mode VPN: %s\n' "${enhanced_mode:-unknown}"
    printf 'Primary Network Service: %s\n' "$(network_service)"
    printf 'macOS effective proxy: %s\n' "${scutil_proxy:-none}"
}

wait_for_surge_ready() {
    local deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        if [[ "$(system_proxy_state)" == "on" && "$(surge_vpn_state)" == "Connected" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

turn_on() {
    ensure_running
    wait_for_api
    stop_conflicting_blaze_tunnel
    set_macos_system_proxy true
    set_enhanced_mode true
    wait_for_surge_ready || die "Surge did not reach connected recovery state"
    print_status
}

turn_off() {
    ensure_running
    set_enhanced_mode false
    set_macos_system_proxy false
    /bin/sleep 1
    print_status
}

watchdog() {
    local seconds="${1:-$WATCHDOG_SECONDS}"
    [[ "$seconds" =~ ^[0-9]+$ ]] || die "watchdog seconds must be numeric"
    echo "Surge restore watchdog armed for ${seconds}s at $(/bin/date)"
    /bin/sleep "$seconds"
    local attempt
    for attempt in 1 2 3 4 5 6; do
        echo "Restoring Surge attempt ${attempt} at $(/bin/date)"
        if "$0" ensure-on; then
            exit 0
        fi
        /bin/sleep 10
    done
    echo "Surge restore watchdog exhausted retries at $(/bin/date)" >&2
    exit 1
}

arm_watchdog() {
    local seconds="${1:-$WATCHDOG_SECONDS}"
    [[ "$seconds" =~ ^[0-9]+$ ]] || die "watchdog seconds must be numeric"
    local logfile="$LOG_DIR/surge-restore-watchdog.$(/bin/date +%Y%m%d-%H%M%S).log"
    /usr/bin/nohup "$0" watchdog "$seconds" >"$logfile" 2>&1 &
    local pid=$!
    printf '%s\n' "$pid" >"$PID_FILE"
    echo "watchdog_pid=$pid"
    echo "watchdog_log=$logfile"
}

cancel_watchdog() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(/bin/cat "$PID_FILE")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/kill "$pid" 2>/dev/null || true
            echo "cancelled watchdog pid $pid"
        fi
        /bin/rm -f "$PID_FILE"
    else
        echo "no watchdog pid file"
    fi
}

restart_surge() {
    /usr/bin/osascript -e "tell application \"$SURGE_APP_NAME\" to quit" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        [[ -z "$(surge_pid)" ]] && break
        /bin/sleep 0.5
    done
    if [[ -n "$(surge_pid)" ]]; then
        echo "Surge did not quit in time; leaving it running. Use force-kill explicitly if needed." >&2
    fi
    ensure_running
    turn_on
}

case "${1:-}" in
    status)
        print_status
        ;;
    on|ensure-on)
        turn_on
        ;;
    off)
        turn_off
        ;;
    watchdog)
        watchdog "${2:-$WATCHDOG_SECONDS}"
        ;;
    arm-watchdog)
        arm_watchdog "${2:-$WATCHDOG_SECONDS}"
        ;;
    cancel-watchdog)
        cancel_watchdog
        ;;
    restart)
        restart_surge
        ;;
    quit)
        /usr/bin/osascript -e "tell application \"$SURGE_APP_NAME\" to quit"
        ;;
    force-kill)
        /usr/bin/pkill -x "$SURGE_APP_NAME"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
