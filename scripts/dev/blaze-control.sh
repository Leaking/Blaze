#!/usr/bin/env bash
set -euo pipefail

BLAZE_APP_NAME="${BLAZE_APP_NAME:-blaze}"
BLAZE_APP_PATH="${BLAZE_APP_PATH:-/Applications/blaze.app}"
BLAZE_VPN_SERVICE="${BLAZE_VPN_SERVICE:-blaze Packet Tunnel}"
BLAZE_HTTP_PORT="${BLAZE_HTTP_PORT:-19080}"
BLAZE_SOCKS_PORT="${BLAZE_SOCKS_PORT:-19081}"
BLAZE_TUNNEL_BUNDLE_ID="${BLAZE_TUNNEL_BUNDLE_ID:-com.chenhuazhao.blaze.tunnel}"

usage() {
    cat <<'EOF'
Usage:
  scripts/dev/blaze-control.sh status
  scripts/dev/blaze-control.sh launch
  scripts/dev/blaze-control.sh quit
  scripts/dev/blaze-control.sh restart
  scripts/dev/blaze-control.sh force-kill
  scripts/dev/blaze-control.sh start-listeners
  scripts/dev/blaze-control.sh stop-listeners
  scripts/dev/blaze-control.sh start-tunnel
  scripts/dev/blaze-control.sh stop-tunnel

Notes:
  - start-listeners/stop-listeners prefer blaze://control URLs and fall back to the app's Proxy menu.
  - start-tunnel/stop-tunnel use macOS scutil and do not require UI automation.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

blaze_pid() {
    /usr/bin/pgrep -x "$BLAZE_APP_NAME" 2>/dev/null | /usr/bin/head -1 || true
}

launch_blaze() {
    if [[ -d "$BLAZE_APP_PATH" ]]; then
        /usr/bin/open -ga "$BLAZE_APP_PATH"
    else
        /usr/bin/open -ga "$BLAZE_APP_NAME"
    fi
}

wait_for_blaze() {
    local deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        [[ -n "$(blaze_pid)" ]] && return 0
        /bin/sleep 0.5
    done
    die "blaze did not start"
}

click_proxy_menu_item() {
    local item="$1"
    launch_blaze
    wait_for_blaze
    local output status
    output="$(/usr/bin/osascript 2>&1 <<EOF
tell application "$BLAZE_APP_NAME" to activate
delay 0.5
tell application "System Events"
    tell process "$BLAZE_APP_NAME"
        click menu item "$item" of menu "Proxy" of menu bar 1
    end tell
end tell
EOF
)" || status=$?
    status="${status:-0}"
    if [[ "$status" != "0" ]]; then
        echo "$output" >&2
        if [[ "$output" == *"assistive access"* || "$output" == *"-1719"* ]]; then
            echo "Grant Accessibility permission to the terminal/Codex host in System Settings -> Privacy & Security -> Accessibility, then retry." >&2
        fi
        return "$status"
    fi
}

vpn_status() {
    /usr/sbin/scutil --nc status "$BLAZE_VPN_SERVICE" 2>/dev/null || true
}

listener_count() {
    /usr/sbin/lsof -nP -iTCP:"$BLAZE_HTTP_PORT" -iTCP:"$BLAZE_SOCKS_PORT" -sTCP:LISTEN 2>/dev/null \
        | /usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }'
}

wait_for_listener_state() {
    local expected="$1"
    local deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        local count
        count="$(listener_count)"
        if [[ "$expected" == "running" && "$count" -ge 2 ]]; then
            return 0
        fi
        if [[ "$expected" == "stopped" && "$count" -eq 0 ]]; then
            return 0
        fi
        /bin/sleep 0.5
    done
    return 1
}

open_control_url() {
    local action="$1"
    launch_blaze
    wait_for_blaze
    /usr/bin/open -g "blaze://control/$action" >/dev/null 2>&1
}

print_status() {
    printf 'blaze process: %s\n' "$(blaze_pid || true)"
    printf 'local listeners:\n'
    /usr/sbin/lsof -nP -iTCP:"$BLAZE_HTTP_PORT" -iTCP:"$BLAZE_SOCKS_PORT" -sTCP:LISTEN 2>/dev/null || true
    printf '\npacket tunnel service:\n'
    vpn_status
    printf '\nsystem extension:\n'
    /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/grep -i "$BLAZE_TUNNEL_BUNDLE_ID" || true
}

quit_blaze() {
    /usr/bin/osascript -e "tell application \"$BLAZE_APP_NAME\" to quit" >/dev/null 2>&1 || true
}

restart_blaze() {
    quit_blaze
    local deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        [[ -z "$(blaze_pid)" ]] && break
        /bin/sleep 0.5
    done
    if [[ -n "$(blaze_pid)" ]]; then
        /usr/bin/pkill -x "$BLAZE_APP_NAME" || true
    fi
    launch_blaze
    wait_for_blaze
    print_status
}

start_listeners() {
    if open_control_url "start-listeners" && wait_for_listener_state running; then
        print_status
        return 0
    fi
    click_proxy_menu_item "Start Local Listeners"
    /bin/sleep 1
    print_status
}

stop_listeners() {
    if open_control_url "stop-listeners" && wait_for_listener_state stopped; then
        print_status
        return 0
    fi
    click_proxy_menu_item "Stop Local Listeners"
    /bin/sleep 1
    print_status
}

case "${1:-}" in
    status)
        print_status
        ;;
    launch)
        launch_blaze
        wait_for_blaze
        print_status
        ;;
    quit)
        quit_blaze
        ;;
    restart)
        restart_blaze
        ;;
    force-kill)
        /usr/bin/pkill -x "$BLAZE_APP_NAME"
        ;;
    start-listeners)
        start_listeners
        ;;
    stop-listeners)
        stop_listeners
        ;;
    start-tunnel)
        /usr/sbin/scutil --nc start "$BLAZE_VPN_SERVICE"
        /bin/sleep 2
        print_status
        ;;
    stop-tunnel)
        /usr/sbin/scutil --nc stop "$BLAZE_VPN_SERVICE" || true
        /bin/sleep 1
        print_status
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
