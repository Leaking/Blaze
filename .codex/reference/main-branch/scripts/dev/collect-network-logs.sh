#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-build/dev-loop/logs.$(/bin/date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

{
    echo "date=$(/bin/date)"
    echo "user=$(/usr/bin/id -un)"
    echo "cwd=$(/bin/pwd)"
} >"$OUT_DIR/context.txt"

/usr/sbin/scutil --proxy >"$OUT_DIR/scutil-proxy.txt" 2>&1 || true
/usr/sbin/scutil --nc status "blaze Packet Tunnel" >"$OUT_DIR/blaze-vpn-status.txt" 2>&1 || true
/usr/bin/systemextensionsctl list >"$OUT_DIR/systemextensions.txt" 2>&1 || true
/usr/sbin/lsof -nP -iTCP:19080 -iTCP:19081 -iTCP:6152 -iTCP:6153 -sTCP:LISTEN >"$OUT_DIR/listeners.txt" 2>&1 || true
/bin/ps aux >"$OUT_DIR/ps.txt" 2>&1 || true

/usr/bin/log show --style compact --last 10m \
    --predicate 'process == "blaze" || process == "BlazeTunnelExtension" || process == "sysextd" || process == "neagent" || subsystem CONTAINS "com.chenhuazhao.blaze"' \
    >"$OUT_DIR/apple-network-extension.log" 2>&1 || true

echo "$OUT_DIR"
