#!/usr/bin/env bash
set -uo pipefail

BLAZE_HTTP_PORT="${BLAZE_HTTP_PORT:-19080}"
BLAZE_SOCKS_PORT="${BLAZE_SOCKS_PORT:-19081}"
SURGE_HTTP_PORT="${SURGE_HTTP_PORT:-6152}"
SURGE_SOCKS_PORT="${SURGE_SOCKS_PORT:-6153}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-25}"
CHROME_PROFILE="${CHROME_PROFILE:-$HOME/Library/Application Support/blaze/ChromeTestProfile}"

usage() {
    cat <<'EOF'
Usage:
  scripts/dev/net-probe.sh all
  scripts/dev/net-probe.sh status
  scripts/dev/net-probe.sh curl-blaze
  scripts/dev/net-probe.sh curl-surge
  scripts/dev/net-probe.sh curl-transparent
  scripts/dev/net-probe.sh browser-blaze
  scripts/dev/net-probe.sh browser-transparent

Targets:
  - Google generate_204
  - ChatGPT landing page
  - Baidu
EOF
}

targets=(
    "google|https://www.google.com/generate_204"
    "chatgpt|https://chatgpt.com/"
    "baidu|https://www.baidu.com/"
)

run_curl() {
    local label="$1"
    local proxy_arg="$2"
    local target_name="$3"
    local url="$4"
    local start output exit_code
    start="$(/bin/date +%s)"
    output="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        /usr/bin/curl -L -sS -o /dev/null \
        --connect-timeout 10 \
        --max-time "$PROBE_TIMEOUT" \
        -w "http_code=%{http_code} remote_ip=%{remote_ip} time_total=%{time_total}" \
        $proxy_arg \
        "$url" 2>&1)"
    exit_code=$?
    printf '%s\t%s\texit=%s\t%s\telapsed=%ss\n' "$label" "$target_name" "$exit_code" "$output" "$(( $(/bin/date +%s) - start ))"
}

curl_group() {
    local label="$1"
    local proxy_arg="$2"
    local item name url
    for item in "${targets[@]}"; do
        name="${item%%|*}"
        url="${item#*|}"
        run_curl "$label" "$proxy_arg" "$name" "$url"
    done
}

print_status() {
    echo "== scutil --proxy =="
    /usr/sbin/scutil --proxy | /usr/bin/sed -n '1,120p'
    echo
    echo "== local listeners =="
    /usr/sbin/lsof -nP \
        -iTCP:"$BLAZE_HTTP_PORT" \
        -iTCP:"$BLAZE_SOCKS_PORT" \
        -iTCP:"$SURGE_HTTP_PORT" \
        -iTCP:"$SURGE_SOCKS_PORT" \
        -sTCP:LISTEN 2>/dev/null || true
    echo
    echo "== blaze vpn =="
    /usr/sbin/scutil --nc status "blaze Packet Tunnel" 2>/dev/null || true
}

browser_blaze() {
    /bin/mkdir -p "$CHROME_PROFILE"
    /usr/bin/open -na "Google Chrome" --args \
        "--user-data-dir=$CHROME_PROFILE" \
        "--proxy-server=http=127.0.0.1:$BLAZE_HTTP_PORT;https=127.0.0.1:$BLAZE_HTTP_PORT;socks=socks5://127.0.0.1:$BLAZE_SOCKS_PORT" \
        "--disable-quic" \
        "--no-first-run" \
        "https://www.google.com/" \
        "https://chatgpt.com/"
}

browser_transparent() {
    /bin/mkdir -p "$CHROME_PROFILE"
    /usr/bin/open -na "Google Chrome" --args \
        "--user-data-dir=$CHROME_PROFILE" \
        "--disable-quic" \
        "--no-first-run" \
        "https://www.google.com/" \
        "https://chatgpt.com/"
}

case "${1:-all}" in
    status)
        print_status
        ;;
    curl-blaze)
        curl_group "blaze-http" "--proxy http://127.0.0.1:$BLAZE_HTTP_PORT"
        curl_group "blaze-socks" "--proxy socks5h://127.0.0.1:$BLAZE_SOCKS_PORT"
        ;;
    curl-surge)
        curl_group "surge-http" "--proxy http://127.0.0.1:$SURGE_HTTP_PORT"
        ;;
    curl-transparent)
        curl_group "transparent-no-proxy" "--noproxy '*'"
        ;;
    browser-blaze)
        browser_blaze
        ;;
    browser-transparent)
        browser_transparent
        ;;
    all)
        print_status
        echo
        curl_group "surge-http" "--proxy http://127.0.0.1:$SURGE_HTTP_PORT"
        curl_group "blaze-http" "--proxy http://127.0.0.1:$BLAZE_HTTP_PORT"
        curl_group "blaze-socks" "--proxy socks5h://127.0.0.1:$BLAZE_SOCKS_PORT"
        curl_group "transparent-no-proxy" "--noproxy '*'"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
