---
name: blaze-hev-self-test-loop
description: Run the Blaze HEV socks5 tunnel self-test and repair loop for this repository. Use when continuing Blaze Packet Tunnel/System Extension debugging, build-numbered Developer ID packaging, notarization submission or polling, install/update verification, startup workflow testing, watchdog recovery, Surge restoration, and log-driven follow-up development.
---

# Blaze HEV Self-Test Loop

Use this skill when the task is to continue the Blaze HEV integration loop end to end: inspect the latest test evidence, make one focused code improvement, build, notarize, install when allowed, run the guarded startup workflow, and repeat until the test evidence is clean.

For command details, read [self-test-cycle.md](references/self-test-cycle.md) before running the loop.

## Operating Rules

- Work from `/Users/chenhuazhao/Documents/workspace/Blaze-hev-socks5-tunnel` on branch `codex/hev-socks5-tunnel-research` unless the user says otherwise.
- Do not install, launch Blaze, change system proxy, or stop/start Surge unless the current user request explicitly authorizes that phase.
- Treat network loss as expected during validation. Always arm an external 5-minute watchdog before startup workflow testing.
- If validation fails, restore Surge, stop Blaze VPN, quit/kill Blaze, capture logs, then continue analysis and code changes.
- Verify app build, bundled system extension build, active system extension build, code signature, and Gatekeeper trust before interpreting HEV connectivity failures.
- If notarization waiting exceeds 10 minutes, resubmit instead of waiting indefinitely.
- Commit focused changes after tests/build pass.

## Loop Summary

1. Inspect `git status`, latest commits, recovery record, `proxy-events.log`, `systemextensionsctl list`, installed app build, bundled extension build, active extension build, `codesign`, and `spctl`.
2. Classify the blocker:
   - App trust rejected: fix notarization/stapling/install before touching HEV logic.
   - Bundled extension build differs from active extension build: fix extension activation/update before Step 7 work.
   - Step 7 SOCKS5 Fetch timeout or partial connectivity: inspect HEV/TCP/proxy path and recent DIAG lines.
   - Watchdog did not restore Surge or quit Blaze: fix recovery first.
3. Make the smallest code change that improves the current blocker and also improves visible diagnostics when useful.
4. Run `swift test` and `swift build -c release --product blaze`.
5. Commit the code.
6. Package the next build number with `scripts/build-app.sh`, then submit notarization.
7. After notarization is accepted and stapled, install only if authorized, then run the startup workflow with the external watchdog.
8. Capture results, mark the watchdog done, and either stop on clean evidence or continue the loop.

## Evidence To Preserve

Save or summarize these in each loop report:

- commit hash and build number
- notarization submission id and final status, if checked
- app/bundled extension/active extension builds
- `spctl` source and `codesign` result
- startup step that failed first
- watchdog recovery phase
- Step 7 blocking failures and slowest successful probes
- whether Surge was restored and Blaze was terminated
