# Blaze HEV Self-Test Cycle

## Preflight

```zsh
cd /Users/chenhuazhao/Documents/workspace/Blaze-hev-socks5-tunnel
git status --short --branch
git log --oneline -8
```

Read local evidence without changing network state:

```zsh
RECOVERY="$HOME/Library/Application Support/blaze/startup-watchdog-recovery.txt"
LOG="$HOME/Library/Application Support/blaze/proxy-events.log"

test -f "$RECOVERY" && sed -n '1,240p' "$RECOVERY" || true
test -f "$LOG" && rg "AUTO|DIAG|curl|SOCKS5 Fetch|HTTP Fetch|Packet Tunnel|Surge|HEV|System Extension|App Trust" "$LOG" | tail -n 240 || true
systemextensionsctl list | rg "com\\.chenhuazhao\\.blaze|blaze|Surge" || true
scutil --nc list | rg "Surge|blaze" || true
```

Verify build/trust state for the candidate bundle:

```zsh
APP="build/blaze.app"
EXT="$APP/Contents/Library/SystemExtensions/com.chenhuazhao.blaze.tunnel.systemextension"

/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true
```

For installed state:

```zsh
APP="/Applications/blaze.app"
EXT="$APP/Contents/Library/SystemExtensions/com.chenhuazhao.blaze.tunnel.systemextension"

test -d "$APP" && /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" || true
test -d "$EXT" && /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/Contents/Info.plist" || true
test -d "$APP" && spctl --assess --type execute --verbose=4 "$APP" || true
systemextensionsctl list | rg "com\\.chenhuazhao\\.blaze" || true
```

## Development And Verification

Make one focused change for the current blocker. Prefer changes that leave better evidence in the Tests page and `startup-watchdog-recovery.txt`.

Before editing, update `docs/hev-self-test-validation-log.md` with the cycle hypothesis, planned validation, target build number, and the evidence that triggered the change.

```zsh
swift test
swift build -c release --product blaze
git status --short
git add <changed-files>
git commit -m "<focused message>"
```

After verification, update the same log entry with commands, pass/fail status, recovery behavior, notarization submission id or status, and next decision.

## Main Branch Reference

The current branch stores a read-only snapshot of `main` in `.codex/reference/main-branch`. Use it to compare previous PacketTunnelEngine, TCP shim, DNS, proxy, app lifecycle, scripts, and test logic without switching worktrees.

```zsh
MAIN_REF=".codex/reference/main-branch"
cat "$MAIN_REF/.source-commit"
diff -ru "$MAIN_REF/Sources/BlazeTunnelExtension" Sources/BlazeTunnelExtension | sed -n '1,240p' || true
diff -ru "$MAIN_REF/Sources/ProxyWorkbench" Sources/ProxyWorkbench | sed -n '1,240p' || true
git diff --stat main...HEAD
```

Use the snapshot critically:

- Prefer current-branch HEV logic when it better matches transparent tunnel requirements.
- Reuse main-branch behavior only when logs show the HEV branch regressed a proven lifecycle, DNS, route, or recovery behavior.
- Copy small proven patterns manually, never bulk overwrite current HEV work.
- If the snapshot gets stale, refresh it with `rm -rf .codex/reference/main-branch && mkdir -p .codex/reference/main-branch && git archive main | tar -x -C .codex/reference/main-branch && git rev-parse main > .codex/reference/main-branch/.source-commit`, then commit the snapshot update.

## Protocol And External Reference Pass

When Step 7, HEV, TCP, DNS, routing, SOCKS5, or upstream behavior is ambiguous, read `references/network-protocol-debugging.md` and do an external reference pass before choosing a fix.

Minimum pass:

1. Map the failure to layers: macOS Network Extension lifecycle, TUN route, DNS/FakeIP, lwIP/TCP state, SOCKS5/HTTP CONNECT, Trojan upstream dial, interface binding, MTU/MSS, timeout/concurrency, selected policy/node health.
2. Search official repos/docs and issue trackers for the closest failure pattern.
3. Compare at least two independent projects when possible, such as HEV/tun2socks, sing-box/mihomo/Xray, and gVisor/tun2socks.
4. Record useful references and rejected hypotheses in `docs/hev-self-test-validation-log.md`.
5. Do not copy incompatible code. Use outside projects primarily for architecture, protocol expectations, debugging counters, timeout behavior, and lifecycle checks.

## Package A Build

Increment the build number from the latest successful or submitted build.

```zsh
BUILD_NUMBER=48
BLAZE_ENABLE_SYSTEM_EXTENSION_ENTITLEMENTS=1 \
BLAZE_SIGN_IDENTITY="Developer ID Application: Huazhao Chen (HYF3XBWBL2)" \
BLAZE_BUILD_NUMBER="$BUILD_NUMBER" \
BLAZE_APP_PROVISIONING_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/3a17b845-d49a-42d2-804b-21caaab299d8.provisionprofile" \
BLAZE_TUNNEL_PROVISIONING_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/154fc183-7658-408f-9b6a-ecd5bb806af5.provisionprofile" \
./scripts/build-app.sh
```

Validate the packaged app:

```zsh
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/blaze.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/blaze.app/Contents/Library/SystemExtensions/com.chenhuazhao.blaze.tunnel.systemextension/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/blaze.app
spctl --assess --type execute --verbose=4 build/blaze.app || true
```

## Notarization

Submit without waiting when the user asks not to wait:

```zsh
BLAZE_NOTARY_PROFILE=blaze-notary \
BLAZE_NOTARY_SUBMIT_ONLY=1 \
./scripts/notarize-app.sh build/blaze.app
```

When waiting is authorized, wait at most 10 minutes per submission. If it is still not accepted after 10 minutes, resubmit.

```zsh
BLAZE_NOTARY_PROFILE=blaze-notary \
BLAZE_NOTARY_MAX_WAIT_SECONDS=600 \
BLAZE_NOTARY_POLL_INTERVAL_SECONDS=30 \
BLAZE_NOTARY_MAX_ATTEMPTS=1 \
./scripts/notarize-app.sh build/blaze.app
```

If notarization credentials are missing, stop and report the concrete blocker. Do not invent credentials. The expected profile name is `blaze-notary`.

## Install

Only install when authorized.

```zsh
osascript -e 'tell application "blaze" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x blaze >/dev/null 2>&1 || true
rm -rf /Applications/blaze.app /Applications/ProxyWorkbench.app
cp -R build/blaze.app /Applications/blaze.app
xattr -cr /Applications/blaze.app
```

Verify install before launch:

```zsh
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/blaze.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/blaze.app/Contents/Library/SystemExtensions/com.chenhuazhao.blaze.tunnel.systemextension/Contents/Info.plist
spctl --assess --type execute --verbose=4 /Applications/blaze.app
```

## Guarded Startup Test

Only run this when launch/test is authorized. The external watchdog is required because the test may interrupt network connectivity.

```zsh
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
RUN_DIR="$PWD/build/dev-loop/startup-$RUN_ID"
mkdir -p "$RUN_DIR"
printf '%s\n' "$RUN_DIR" > build/dev-loop/latest-startup-run.txt
DONE_FILE="$RUN_DIR/done"
WATCHDOG_LOG="$RUN_DIR/external-watchdog.log"

(
  sleep 300
  if [[ ! -f "$DONE_FILE" ]]; then
    printf '[%s] external watchdog fired; requesting Blaze recovery, quitting Blaze, opening Surge\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WATCHDOG_LOG"
    open 'blaze://control/recover-startup' >> "$WATCHDOG_LOG" 2>&1 || true
    sleep 10
    osascript -e 'tell application "blaze" to quit' >> "$WATCHDOG_LOG" 2>&1 || true
    pkill -x blaze >> "$WATCHDOG_LOG" 2>&1 || true
    open -a Surge >> "$WATCHDOG_LOG" 2>&1 || true
    "$PWD/scripts/dev/surge-control.sh" ensure-on >> "$WATCHDOG_LOG" 2>&1 || true
    scutil --nc list | rg "Surge|blaze" >> "$WATCHDOG_LOG" 2>&1 || true
    systemextensionsctl list >> "$WATCHDOG_LOG" 2>&1 || true
  fi
) &
printf '%s\n' "$!" > "$RUN_DIR/watchdog.pid"

rm -f "$HOME/Library/Application Support/blaze/startup-watchdog-recovery.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/start-ts.txt"
scutil --nc list | rg "Surge|blaze" > "$RUN_DIR/scutil-before.txt" || true
systemextensionsctl list > "$RUN_DIR/systemextensions-before.txt" 2>&1 || true

open /Applications/blaze.app
sleep 2
open 'blaze://control/run-startup-workflow'
printf 'run_dir=%s\n' "$RUN_DIR"
```

Monitor and capture:

```zsh
RUN_DIR="$(cat build/dev-loop/latest-startup-run.txt)"
{
  echo '--- scutil ---'
  scutil --nc list | rg "Surge|blaze" || true
  echo '--- processes ---'
  ps -axo pid,ppid,lstart,command | rg "blaze|BlazeTunnelExtension|Surge" || true
  echo '--- systemextensions ---'
  systemextensionsctl list | rg "com\\.chenhuazhao\\.blaze|blaze|Surge" || true
  echo '--- recovery ---'
  test -f "$HOME/Library/Application Support/blaze/startup-watchdog-recovery.txt" && sed -n '1,260p' "$HOME/Library/Application Support/blaze/startup-watchdog-recovery.txt" || true
  echo '--- recent diagnostics ---'
  rg "AUTO|DIAG|curl|SOCKS5 Fetch|HTTP Fetch|Packet Tunnel|Surge|HEV|System Extension|App Trust" "$HOME/Library/Application Support/blaze/proxy-events.log" | tail -n 260 || true
} | tee "$RUN_DIR/monitor.txt"
```

Always disarm the external watchdog after the run is resolved:

```zsh
RUN_DIR="$(cat build/dev-loop/latest-startup-run.txt 2>/dev/null || true)"
if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
  touch "$RUN_DIR/done"
  if [[ -f "$RUN_DIR/watchdog.pid" ]]; then
    kill "$(cat "$RUN_DIR/watchdog.pid")" >/dev/null 2>&1 || true
  fi
fi
```

## Result Classification

- If Step 2 fails and `App Trust` is rejected, do not debug HEV. Fix notarization/stapling/install.
- If Step 2 fails because active extension is older than bundled extension, do not debug Step 7. Fix system extension activation/update.
- If Step 7 fails with SOCKS5 Fetch timeout while CONNECT succeeds slowly, focus on HEV TCP flow timing, upstream dial path, selected policy latency, and timeout/concurrency pressure.
- If browser access partly works but curls time out, compare slow successful probe durations with curl max-time and inspect TCP/HEV counters.
- If watchdog does not restore Surge and terminate Blaze, fix recovery before running another disruptive test.
