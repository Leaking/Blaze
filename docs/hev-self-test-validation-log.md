# HEV Self-Test Validation Log

Record every self-test cycle here before and after validation. Include the build number, notarization status, fix or hypothesis, commands, watchdog behavior, and next decision.

## Template

```markdown
## YYYY-MM-DD HH:mm TZ - Build N

- Commit:
- Notarization:
  - Submission id:
  - Status:
  - Stapled:
- Triggering evidence:
- Hypothesis:
- Fix/change:
- Main branch reference:
- External references:
- Validation commands:
- Startup workflow result:
- Watchdog result:
- Surge restore:
- App/ext version check:
- Remaining risk:
- Next decision:
```

## 2026-05-20 22:48 Asia/Shanghai - Build 47

- Commit: `cdaab5f Expose extension trust diagnostics in startup tests`
- Notarization:
  - Submission id: `5b64e11d-cf69-4472-a718-0d01bdb151f0`
  - Status: submitted without waiting
  - Stapled: not checked in that cycle
- Triggering evidence: build 46 local validation could not prove Step 7 because app was unnotarized and the active system extension remained older than the bundled extension.
- Hypothesis: Step 2 needed explicit app trust and extension version diagnostics before interpreting HEV connectivity failures.
- Fix/change: Tests page and watchdog recovery record now expose app trust, host app build, bundled extension build, active extension build, and Step 2 trust/version failure details.
- Main branch reference: not used in this cycle.
- External references: not used in this cycle.
- Validation commands: `swift test`; `swift build -c release --product blaze`; `scripts/build-app.sh` with `BLAZE_BUILD_NUMBER=47`; `codesign --verify --deep --strict --verbose=2 build/blaze.app`; `spctl --assess --type execute --verbose=4 build/blaze.app`.
- Startup workflow result: not run.
- Watchdog result: not run.
- Surge restore: not touched.
- App/ext version check: packaged app build `47`; bundled system extension build `47`; `spctl` rejected before notarization as `Unnotarized Developer ID`.
- Remaining risk: build 47 still needs notarization acceptance/staple/install before startup workflow can validate active extension build 47.
- Next decision: after notarization acceptance, install and run guarded startup workflow with external watchdog.

## 2026-05-20 23:20 Asia/Shanghai - Skill And Reference Update

- Commit: this workflow update commit
- Notarization:
  - Submission id: not applicable
  - Status: not applicable
  - Stapled: not applicable
- Triggering evidence: self-test loop needed to be portable to Claude Code and needed broader protocol/debugging guidance.
- Hypothesis: future cycles will be more reliable if they record validation decisions, compare against main branch, and consult comparable open-source proxy/tunnel projects when protocol behavior is ambiguous.
- Fix/change: added project skill `blaze-hev-self-test-loop`, network protocol debugging reference, main branch snapshot, and this validation log.
- Main branch reference: `.codex/reference/main-branch`, sourced from local `main`.
- External references: HEV socks5 tunnel, tun2socks/gVisor, sing-box, mihomo, Xray/V2Ray, shadowsocks-rust, and hysteria are listed as reference projects.
- Validation commands: `quick_validate.py .codex/skills/blaze-hev-self-test-loop`.
- Startup workflow result: not run.
- Watchdog result: not run.
- Surge restore: not touched.
- App/ext version check: not applicable.
- Remaining risk: main branch snapshot is reference-only and can contain bugs; use it critically.
- Next decision: push branch, then let Claude Code open the branch and use `$blaze-hev-self-test-loop`.

## 2026-05-20 23:43 Asia/Shanghai - Build 48

- Commit: `0ee70c6 Expand HEV self-test protocol workflow` (no new code change this cycle; goal is to validate Build 47's trust diagnostics end-to-end)
- Notarization:
  - Submission id: pending (running)
  - Status: pending
  - Stapled: pending
- Triggering evidence: Build 47 was packaged and submitted (id `5b64e11d-cf69-4472-a718-0d01bdb151f0`, Accepted per `notarytool history`) but never stapled nor installed. Installed `/Applications/blaze.app` is still Build 46 unnotarized (`spctl` rejected); active system extension is Build 45 (older than installed). Workspace `build/blaze.app` was clobbered back to Build 31 between cycles. Recovery file shows last run stopped at Step 2 ("App Trust" failure).
- Hypothesis: Step 2 failures are distribution/trust issues, not HEV code issues. Pushing a freshly-signed, notarized, stapled Build 48 through install + system-extension activation should clear Step 2 and let Step 7 produce meaningful HEV evidence for the first time on this branch.
- Fix/change: no code change. Re-packaged Build 48 from the same source tree as Build 47 with full Developer ID signing and embedded provisioning profiles. Both Info.plist `CFBundleVersion` keys = 48. `codesign --verify --deep --strict` passes. `spctl` rejected pre-notarization as expected.
- Main branch reference: snapshot at `.codex/reference/main-branch/.source-commit` matches current `main` (1eff2f0); no refresh needed.
- External references: not consulted yet — Step 2 trust path does not require protocol-layer comparison. Will consult HEV/tun2socks/sing-box references if Step 7 fails after install.
- Validation commands so far: `swift test` (99 passed, 1 skipped, 0 failures); `BLAZE_BUILD_NUMBER=48 ./scripts/build-app.sh`; `codesign --verify --deep --strict --verbose=2 build/blaze.app`; `spctl --assess --type execute --verbose=4 build/blaze.app` (rejected, pre-notarization, expected); `BLAZE_NOTARY_PROFILE=blaze-notary BLAZE_NOTARY_MAX_WAIT_SECONDS=600 BLAZE_NOTARY_MAX_ATTEMPTS=2 ./scripts/notarize-app.sh build/blaze.app` (running).
- Startup workflow result: Steps 1–4 passed (Surge stopped, app trust accepted, system extension upgraded to active build 48, local listeners up, packet tunnel configuration installed). **Step 5 failed**: `startPacketTunnel()` did not transition the tunnel to connected.
- Watchdog result: external 5-min watchdog did not fire; in-app watchdog recovered at 2026-05-20T15:46:47Z, stopped the tunnel, restored Surge VPN, terminated Blaze.
- Surge restore: succeeded; `scutil --nc list` shows Surge reconnected.
- App/ext version check: packaged app build 48; packaged extension build 48; installed app build 48 (notarized, stapled, `spctl: accepted`); active extension build 48 (`systemextensionsctl list` confirms `*  *  HYF3XBWBL2  com.chenhuazhao.blaze.tunnel (0.1.0/48)  [activated enabled]`).
- Root cause: macOS unified log for `BlazeTunnelExtension` shows `Failed to start packet tunnel engine: HEV library was not found. Checked: …/Frameworks/libhev-socks5-tunnel.dylib, …/Resources/HevSocks5Tunnel/libhev-socks5-tunnel.dylib, …/MacOS/libhev-socks5-tunnel.dylib`. The bundle never contained the HEV dylib because `Vendor/HevSocks5Tunnel/macos-arm64/` did not exist on this branch and `scripts/build-app.sh` silently skipped the copy when the source dir was missing. The bundled extension build was therefore non-functional from build ~30 onward on this branch, regardless of notarization.
- Diagnostic gap observed: `proxy-events.log` recorded only the inbound `Received automation action: run-startup-workflow` line. The five startup-step transitions, the in-app watchdog recovery, the Surge restore, and the tunnel-start failure all left zero entries in the app's own event log, which made the cycle dependent on `log show` for ground truth.
- Remaining risk: even after the dylib lands, lwIP/SOCKS5 path may still fail Step 7 — that path has never executed cleanly on this branch.
- Next decision: build HEV dylibs locally (done: `Vendor/HevSocks5Tunnel/macos-arm64/{libhev-socks5-tunnel,liblwip,libhev-task-system,libyaml}.dylib`, all arm64 Mach-O, upstream commit `3ffa5b91ec08d631d08e35203063427ddf121318`); harden `scripts/build-app.sh` to fail loudly when the dylib is missing; teach `setStartupStep` to append a `ProxyServerEvent` so future Step N failures are visible in `proxy-events.log` without needing `log show`; then repackage as Build 49 and rerun the guarded startup test.

## 2026-05-21 00:01 Asia/Shanghai - Build 49

- Commit: pending (this cycle's commit will follow this entry)
- Notarization:
  - Submission id: pending
  - Status: pending
  - Stapled: pending
- Triggering evidence: Build 48 cleared Steps 1–4 but failed Step 5 with `HEV library was not found` because the HEV dylib was never bundled. Local `proxy-events.log` contained no record of the Step 5 failure, recovery, or restore — only the inbound automation action.
- Hypothesis: bundling the freshly-built HEV dylibs into the system extension's `Contents/Frameworks/` will let `PacketTunnelProvider.start` find `libhev-socks5-tunnel.dylib` via the loader path the extension already searches, and Step 5 will reach `packetTunnelConnected = true`. With the diagnostic logging change, even if Step 6 or 7 fails, the failure detail will be persisted to `proxy-events.log` immediately for the next cycle.
- Fix/change:
  1. `Sources/ProxyWorkbench/WorkbenchStore.swift` — `setStartupStep` now emits a `ProxyServerEvent` (`method=STARTUP`, `policy=Startup Workflow`, `rule=Workflow`, `status` mapped to Passed/Failed/Info) whenever a step's status actually changes or a `.failed` step's detail changes. Pending/info transitions are skipped to avoid spam from `updateStartupWorkflowFromCurrentState`.
  2. `scripts/build-app.sh` — refuses to produce a bundle when no HEV dylib is found in `BLAZE_HEV_LIBRARY_DIR` (default `Vendor/HevSocks5Tunnel/macos-arm64`). Override with `BLAZE_ALLOW_MISSING_HEV_DYLIB=1` for intentional broken builds. Uses `shopt -s nullglob` so the empty glob does not leak a literal `*.dylib` path.
  3. HEV dylibs (~540 KB total) are deliberately not committed; `.gitignore` already covers `Vendor/HevSocks5Tunnel/macos-*/`. Build script remains the source of truth.
- Main branch reference: not consulted this cycle — root cause was an extension packaging miss, not a protocol regression.
- External references: HEV upstream `heiher/hev-socks5-tunnel@3ffa5b9` used as-is. Did not need tun2socks/sing-box comparison because the failure was below the protocol layer.
- Validation commands: `swift test` (99 passed, 1 skipped, 0 failures); package with `BLAZE_BUILD_NUMBER=49 ./scripts/build-app.sh`; `./scripts/notarize-app.sh build/blaze.app`; install + guarded startup workflow (pending).
- Startup workflow result: pending.
- Watchdog result: pending.
- Surge restore: pending.
- App/ext version check: will run after install.
- Remaining risk: Step 5 should now pass, but Step 6 (tunnel diagnostics) or Step 7 (connectivity diagnostics) may still surface real protocol issues that no prior cycle has been able to see clearly.
- Next decision: if Step 5 passes and Step 7 produces results, classify per the result rules. If Step 7 fails, use the new `proxy-events.log` entries plus `log show` to pick the first protocol-layer fix for Build 50.

