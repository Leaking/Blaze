# Blaze Local Development Loop

This project depends on Surge for Codex/ChatGPT connectivity while Blaze is not yet a complete replacement. Any test that disables Surge must therefore arm an offline restore watchdog first.

## Safety Invariant

Before turning off Surge `System Proxy` or `Enhanced Mode`, run:

```bash
./scripts/dev/surge-control.sh arm-watchdog 120
```

The watchdog is a detached local shell process. It does not need Codex, ChatGPT, or network access. After the timeout it runs:

```bash
./scripts/dev/surge-control.sh ensure-on
```

Manual emergency restore:

```bash
./scripts/dev/surge-control.sh on
```

## Tool Map

`scripts/dev/surge-control.sh`

- `status`: show Surge process, system proxy state, Enhanced Mode VPN state, and effective macOS proxy.
- `on`: start Surge if needed, point macOS system proxy to Surge, start Surge's VPN service.
- `off`: stop Surge's VPN service, then disable macOS system proxy.
- `arm-watchdog 120`: restore Surge automatically after 120 seconds.
- `restart`, `quit`, `force-kill`: explicit operator commands only. The dev loop does not call them.

The script uses `networksetup` for System Proxy restoration and Surge's main-app HTTP API for Enhanced Mode. Direct `scutil --nc start Surge` is not sufficient because Surge rejects starts that are not initiated by the main app. `on` also stops Blaze's Packet Tunnel first, because only one primary packet tunnel can own the route table cleanly during recovery.

The restore path verifies that Surge reaches `Connected` before the watchdog is cancelled. If recovery fails transiently, the watchdog keeps retrying instead of silently leaving Enhanced Mode down.

`scripts/dev/blaze-control.sh`

- `launch`, `restart`, `quit`, `force-kill`.
- `start-listeners`, `stop-listeners`: prefer the app's fixed `blaze://control/start-listeners` and `blaze://control/stop-listeners` URLs, then fall back to the Blaze `Proxy` menu through System Events for older builds.
- `start-tunnel`, `stop-tunnel`: use `scutil --nc`.
- `status`: print listeners, VPN status, and system extension state.

`scripts/dev/net-probe.sh`

- `curl-surge`: explicit curl through Surge.
- `curl-blaze`: explicit curl through Blaze HTTP and SOCKS.
- `curl-transparent`: curl with proxy environment removed and `--noproxy '*'`, useful for Packet Tunnel verification.
- `browser-blaze`: isolated Chrome profile with explicit Blaze proxy.
- `browser-transparent`: isolated Chrome profile without explicit proxy, useful for tunnel tests.

`scripts/dev/blaze-dev-cycle.sh`

Runs one guarded cycle:

1. Arm the Surge restore watchdog.
2. Launch Blaze.
3. Start local listeners.
4. Start the Packet Tunnel.
5. Probe with Surge still on.
6. Turn Surge takeover off.
7. Probe Blaze explicit proxy and transparent path.
8. Collect logs.
9. Restore Surge and cancel the watchdog.

Run:

```bash
./scripts/dev/blaze-dev-cycle.sh
```

Output is written under `build/dev-loop/<timestamp>/`.

If Accessibility permission is not available, start Blaze's local listeners manually in the app first, then run:

```bash
BLAZE_ASSUME_LISTENERS=1 ./scripts/dev/blaze-dev-cycle.sh
```

## Current Limitation

The URL control API exists in builds that include the `blaze` URL scheme in `Info.plist`. If an older installed app is still running, `start-listeners` falls back to macOS UI automation against the app menu, so Terminal/Codex may still need Accessibility permission until the newer app bundle is installed.
