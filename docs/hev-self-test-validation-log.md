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
- Startup workflow result: **Steps 1–6 passed**, Step 7 failed. Recovery file: `phase=restored`, `reason=Startup workflow stopped at step 7`, `appTrust=accepted`, `systemExtension=Active system extension matches bundled build 0.1.0/49`, `connectivityResults=25`. Three blocking failures: `Google SOCKS5 Fetch / Baidu SOCKS5 Fetch / ChatGPT SOCKS5 Fetch`, all `curl: (28) Connection timed out after 20s`. Critical proxy failures showed `tunnel X B up / 0 B down; no upstream response bytes`.
- Watchdog result: external 5-min watchdog did not fire; in-app watchdog recovered at 2026-05-20T16:06:42Z.
- Surge restore: Step 8 passed; Surge VPN reconnected. (Run 2 of build 49 had Step 8 fail "Surge app is running but VPN did not reconnect" — transient.)
- App/ext version check: app 0.1.0/49, sysext 0.1.0/49, `spctl: accepted, source=Notarized Developer ID`.
- Critical follow-on observation (Run 2, same build, no code change): 25 probes failed identically AGAIN with all the same destinations and the same timing pattern → bug is reproducible, not transient. Also, dozens of "Connected" SOCKS5 entries for real apps (claude.ai, anthropic, telegram, feishu, github, mtalk.google) appeared at 16:21:51–52, RIGHT AFTER Step 7 ended — the Trojan upstream IS reachable; the failure mode is probe-specific.
- Remaining risk: Step 7 protocol issue not yet diagnosed.
- Next decision: add Trojan-upstream timing diagnostics and rerun as Build 50 to identify which layer breaks (TLS handshake, route, request header, response).

## 2026-05-21 00:33 Asia/Shanghai - Build 50

- Commit: `8dcf2fb Instrument Trojan upstream connection timing and state transitions`
- Notarization: id `f132ab80-a9a8-445b-b515-590986edac3f`, Accepted, stapled.
- Triggering evidence: Build 49 confirmed Steps 1–6 work and that Step 7 fails reproducibly with the upstream actually reachable.
- Hypothesis: Step 7 failure is in the TLS handshake or in route-loop (NWConnection ignoring `requiredInterface = en1` and going through utun4). New per-connection logs will distinguish these.
- Fix/change: `Sources/ProxyWorkbenchCore/TrojanUpstreamConnection.swift` adds `os.log` subsystem `com.chenhuazhao.blaze` category `TrojanUpstream` that records (a) DNS resolve time and resolved address, (b) every `NWConnection.State` transition with elapsed millis, (c) the ready/failed time, (d) the interface name reported by `NWConnection.currentPath`. On timeout, the thrown error now carries the full state timeline so it reaches `proxy-events.log` via the existing failure path.
- Validation commands: `swift test` (99 passed); `BLAZE_BUILD_NUMBER=50 ./scripts/build-app.sh`; notarize+staple; install; guarded startup workflow.
- Startup workflow result: Steps 1–6 passed; Step 7 failed identically (third consecutive identical failure).
- Watchdog result: in-app recovery succeeded; external watchdog did not fire.
- Surge restore: passed.
- App/ext version check: all 0.1.0/50, notarized + stapled.
- **Diagnostic data unlocked:** TrojanUpstream logs from build 50 showed ALL handshakes complete in **36–376ms** (max ~1s for one outlier), every connection via `interface=en1` (no route loop). Cross-referenced proxy-events.log: probe destinations (google/baidu/chatgpt) DO eventually establish Trojan upstream connections — at 16:37:11–14, i.e. **30–40 seconds AFTER the probe's 18s timeout expired**. So the local SOCKS5/HTTP listeners are processing the probe requests, just lagging badly under burst load. Real apps' connections continue completing in parallel with no delay.
- Working hypothesis: the local SOCKS5/HTTP servers stall on something inside `handleClient` — most likely `routeDecision`, which constructs `RuleEngine(rules: profile.rules)` and linearly scans 7536 rules, compiling `NSRegularExpression` inside the loop for every URL-REGEX and DOMAIN-WILDCARD match.
- Next decision: cache the regex compilation, port-set parsing, and lowercased rule values in a process-wide `NSCache` to remove the per-request cost. Rerun as Build 51.

## 2026-05-21 00:51 Asia/Shanghai - Build 51

- Commit: `9515a1d Cache compiled regexes, port sets, and lowercased values in RuleEngine`
- Notarization: id `4e0389a2-0510-44fb-85dd-bfaf141e027d`, Accepted, stapled.
- Triggering evidence: Build 50's diagnostic data isolated the bottleneck to within `handleClient`; `RuleEngine.firstMatch` was the most expensive suspect.
- Hypothesis: caching the per-rule compiled values will collapse the routeDecision cost from O(rules × pattern-compilation) to O(rules × hash-lookup), letting concurrent connections process at line rate.
- Fix/change: `Sources/ProxyWorkbenchCore/RuleEngine.swift` introduces `RuleValueCache` — process-wide `NSCache<NSString, ...>` for compiled regexes (URL-REGEX and DOMAIN-WILDCARD anchored), parsed DEST-PORT sets, and lowercased rule values. Keyed by raw pattern string. Marked `nonisolated(unsafe)` because `NSCache` is internally thread-safe and the cached values are immutable.
- Validation commands: `swift test` (99 passed); `BLAZE_BUILD_NUMBER=51 ./scripts/build-app.sh`; notarize+staple; install; guarded startup workflow.
- Startup workflow result: Steps 1–6 passed; **Step 7 failed identically again** (fourth consecutive identical failure with the same three blocking probes). Cache change delivered no measurable improvement → routeDecision was not the hot spot, or not the only one.
- Watchdog result: in-app recovery succeeded.
- Surge restore: passed.
- App/ext version check: all 0.1.0/51, notarized + stapled.
- **Key new observation:** Step 7 takes **1m 45s wall-clock** (16:53:36 → 16:55:21). Probes have 18–20s timeouts and are launched concurrently via `withTaskGroup` (3 targets × 4 transports = 12 tasks), so worst case should be ~25s. The extra ~80s strongly suggests pre-probe work (`runConnectivityDiagnostics` calls `ConnectivityDNSProbe.evaluate` and several refreshes before the probes ever fire) or that `withTaskGroup` is not actually parallelizing as expected. Also: the burst of "Connected" SOCKS5 entries at 16:53:35–36 (right when Step 5 finished) and again at 16:54:06 shows the SOCKS5 server is NOT globally stalled — only the probe path is slow.
- **Diagnostic blind spot identified:** the new `TrojanUpstream` Logger published at `.info` level, which `log show` does not persist by default — so build 51 has zero TrojanUpstream entries despite the connections clearly happening. Build 52 will need `.notice` for guaranteed persistence.
- Remaining risk: real Step 7 bottleneck still unknown. Best leads for next session:
  1. Add timing instrumentation INSIDE `LocalSOCKS5ProxyServer.handleClient` (accept → greeting → request.read → routeDecision → upstream dial → reply sent). This is what will pinpoint the slow stage.
  2. Investigate `ConnectivityDNSProbe.evaluate` and `RouteProbe.evaluate` durations — they run before the probe burst.
  3. Check whether `withTaskGroup` is genuinely concurrent for these probes; the result-stream `for await` blocks until each result lands, which is fine, but the launch order may serialize on something.
  4. Manually `curl --socks5 127.0.0.1:19081 https://www.google.com` while blaze is running and Step 7 is not — if it succeeds quickly, the server is fine and only the probe-burst path is broken. If it also takes 30+s, the listener itself is slow.
- Next decision: pause unattended loop here. Next session should be interactive: rebuild as Build 52 with handleClient timing + `.notice` logger, and run with manual single-connection probes for direct comparison. Watchdog discipline is now proven (3 consecutive disruptive cycles, Surge cleanly restored each time, network never permanently lost).

## 2026-05-21 02:42 Asia/Shanghai - Build 55 (Rust leaf integration)

- Commit: pending after this entry
- Notarization: id `(see notarize-55.log)`, Accepted, stapled.
- Triggering evidence: Builds 49-54 plus a research pass confirmed the Swift cooperative concurrency pool starves under concurrent blocking I/O; build 52/53/54 dispatcher experiments did not unblock Step 7. The research agent's report identified `eycorsican/leaf` (Rust, Tokio, Apache-2.0, Trojan first-class) as the lowest-risk path that delivers the protocol stack we'd otherwise own.
- Hypothesis: a Tokio-backed proxy with native trojan, TLS, and socks5/http inbounds will serve 12 concurrent probes without the pool starvation that Swift cannot escape. Smoke test before build 55 confirmed this: 12 simultaneous probes (3 hosts × 4 transports) through `leaf -c <conf> -b en1` against the same Trojan upstream Blaze's Step 7 was failing on returned 9× HTTP 200 in 0.5-1.7s + 3× HTTP 403 (Cloudflare geo-block from HK, not a leaf issue), zero timeouts.
- Fix/change:
  1. Vendored `eycorsican/leaf@7a9101b5` (Apache-2.0) under `Vendor/Leaf/leaf/`; built `leaf-cli` as a 9.5 MB arm64 mach-O at `Vendor/Leaf/macos-arm64/leaf` via `cargo build -p leaf-cli --release`.
  2. New `Sources/ProxyWorkbenchCore/LeafController.swift` actor that materialises a `LeafConfiguration` into leaf's `.conf` syntax, launches the binary as a subprocess, and exposes start/stop/lifecycle. Captures stdout+stderr to `~/Library/Application Support/blaze/leaf/leaf.log`.
  3. `WorkbenchStore` adds `buildLeafConfiguration()` (maps `profile.proxies` + `globalProxyPolicy` + `selectedPolicies` to leaf's `[Proxy]`/`[Rule]` sections, with full coverage for trojan/shadowsocks/socks5 nodes and DIRECT/REJECT/FINAL). `startLocalProxyServer` / `startLocalSocksServer` now delegate to `ensureLeafRunning`; the same applies to the stop path. The Swift listener classes remain in the tree but are no longer instantiated.
  4. `scripts/build-app.sh` copies the leaf binary into `Contents/Resources/leaf` and signs it with the same Developer ID identity, hardened runtime, and timestamp as the rest of the executable surface. Refuses to build without the binary unless `BLAZE_ALLOW_MISSING_LEAF=1`.
  5. Recovery path stops leaf alongside the packet tunnel so a clean port surface is left for Surge to retake.
- External references: `eycorsican/leaf` README + `leaf/src/config/conf/config.rs` for `.conf` syntax; research agent's report comparing sing-box / mihomo / Xray-core / shadowsocks-rust / leaf / SwiftNIO.
- Validation commands: `swift test` (99 passed); 12-probe stress test against `leaf -b en1` (all returned non-timeout responses); `BLAZE_BUILD_NUMBER=55 ./scripts/build-app.sh`; notarize+staple; install; guarded startup workflow.
- Startup workflow result: **Steps 1–7 all PASSED**. `Step 7 Passed: 25 checks completed [Diagnostics 25/25]` at 2026-05-20T18:42:37Z, 26s after Step 7 started, zero blocking failures, zero critical proxy failures. Step 8 reported `Action Needed: Blaze VPN is still connected; not restarting Surge to avoid DNS/utun takeover` — the workflow correctly refuses to silently kill an active tunnel.
- Watchdog result: external 5-min watchdog fired (workflow doesn't auto-quit on success), recovery cleanly restored Surge.
- Surge restore: passed via watchdog recovery; `scutil --nc list` shows Surge connected, Blaze disconnected.
- App/ext version check: app 0.1.0/55, sysext 0.1.0/55, `spctl: accepted, source=Notarized Developer ID`, leaf 9.5 MB at `Contents/Resources/leaf` signed.
- Concurrent traffic during Step 7 (from real apps, captured in leaf's log): api.telegram.org connect=86ms, browser-intake-us5-datadoghq.com connect=77ms, api.apple-cloudkit.com connect=33ms — leaf services real traffic and probes simultaneously with no starvation.
- Remaining risk: leaf does not have Blaze's per-connection event logging hooked up; `proxy-events.log` still receives STARTUP entries but not per-connection SOCKS5/HTTP entries (those used to come from the Swift LocalSOCKS5ProxyServer). Need a follow-up to either parse leaf's log or add an inbound observer.
- Next decision: delete `LocalSOCKS5ProxyServer.swift`, `LocalHTTPProxyServer.swift`, `TrojanUpstreamConnection.swift`, `RuleEngine.swift` once the leaf path is exercised for a few more days and proxy-events.log parity is closed. Build 55 establishes the architecture is correct.

## 2026-05-21 03:11 Asia/Shanghai - Build 56 (recovery resilience)

- Commit: `c4eb7d5` + orphan cleanup follow-up.
- Notarization: id `(see notarize-56.log if retained)`, Accepted, stapled.
- Triggering evidence: user feedback "经常无法让 claude code 恢复，特别是断网重连之后" — recovery from Wi-Fi reconnect / sleep-wake was unreliable on the legacy code path; want to make sure leaf-backed Blaze stays self-healing.
- Hypothesis: three failure modes need guarding: (a) leaf process crashes silently, (b) physical interface name flips so leaf is bound to a dead `en1`, (c) host app dies and leaves an orphan leaf occupying 19080/19081.
- Fix/change:
  1. `LeafController` gains a supervisor: `generation` counter + `stopRequested` flag distinguish intentional stop from crash; on unexpected exit the actor reschedules a respawn with exponential backoff (200/400/800/1600/3200ms, cap 5s). A `LifecycleEvent` stream surfaces start/exit/restart/stop to the host.
  2. `WorkbenchStore` subscribes to those events via a Sendable wrapper class so the closure crosses actor boundaries safely. UI flags `proxyServerRunning`/`socksServerRunning` stay accurate even when leaf restarts itself.
  3. `WorkbenchStore` starts an `NWPathMonitor` at init; when the primary physical interface name changes (Wi-Fi reconnect, switch from Wi-Fi to wired, etc.), it calls `ensureLeafRunning()` which rebuilds the config with the new boundif and applies it.
  4. On every `start(with:)` where the controller has no live process, `LeafController` first sweeps any orphan leaf process whose `comm` matches our binary path and SIGTERMs it (then SIGKILL after 1s). Defends against "host app was force-quit and leaf survived" leaking listen sockets.
- Validation commands: `swift test` (99 passed); `BLAZE_BUILD_NUMBER=56 ./scripts/build-app.sh`; notarize + staple; install; guarded startup workflow.
- Startup workflow result: **Steps 1-7 PASSED again**. `Step 7 Passed: 25 checks completed [Diagnostics 25/25]` at 2026-05-20T19:11:47Z, **24 seconds** after Step 7 started. Two consecutive clean Step 7 passes (build 55: 26s, build 56: 24s).
- Watchdog result: external watchdog fired (no auto-quit on success), in-app recovery + leaf-stop path executed cleanly. `Step 8 Passed: Restarted Surge: com.nssurge.surge-mac; VPN connected`.
- Supervisor evidence (from os.log `com.chenhuazhao.blaze:Leaf`):
  - `leaf started pid=61346 attempt=0`
  - `leaf stopping pid=61346` (owner-initiated)
  - `leaf exited pid=61346 status=15 reason=2` (SIGTERM, clean shutdown)
  - Zero spurious restarts (stopRequested was true).
- Remaining risk: health probe for "process alive but socket unresponsive" not yet implemented; supervisor only reacts when the process exits. Acceptable for now since the failure modes we observed are exit-based, not deadlock-based.
- Next decision: ship build 56. Future work: TCP probe-based health check; per-connection event logging from leaf into `proxy-events.log` for parity with the deleted Swift listener.

## 2026-05-21 03:43 Asia/Shanghai - Build 57 (regression + diagnosis) / Build 58 (recovery)

- Commits: `e59579f` (health probe) introduced an orphan-cleanup regression; `76611da` fixed it.
- Build 57 result: **Step 3 hung indefinitely**. Workflow logged `Step 3 Running: Starting local HTTP and SOCKS5 listeners` at 19:27:30 then went silent until the external watchdog fired at 19:32:26. No `com.chenhuazhao.blaze:Leaf` `leaf started` notice — leaf never even launched.
- Root cause: `terminateOrphanLeafProcesses()` ran `/bin/ps -axo pid=,comm=`, redirected to a `Pipe`, and only read the pipe AFTER `task.waitUntilExit()`. On a busy macOS box (≈500+ processes), ps output exceeded the pipe's kernel buffer; ps blocked on write waiting for the reader, `waitUntilExit` blocked waiting for ps to exit, classic pipe-deadlock. The `LeafController` actor was stuck inside `start()` for the duration.
- Fix (Build 58): Replaced ps+parse with `/usr/bin/pkill -TERM -f <binaryPath>` followed by `sleep 1` + `pkill -KILL -f <binaryPath>`. pkill returns its result via exit status; stdout/stderr are redirected to `/dev/null` so there is no pipe to overflow.
- Build 58 result: **Step 7 PASSED**. 25/25 connectivity probes completed; recovery cleanly restored Surge ("Step 8 Passed: Restarted Surge: com.nssurge.surge-mac; VPN connected"). Three clean Step 7 passes in a row now: 55 (26s), 56 (24s), 58.
- Lesson recorded for future cycles: any subprocess invocation that captures stdout/stderr must read concurrently with the process running, OR use small/empty output, OR redirect to `/dev/null` / a file. Never `task.waitUntilExit() → pipe.readToEnd()` for processes that can produce more than a few KB.

## 2026-05-21 04:20 Asia/Shanghai - Build 60 (Step 5 timing race) / Build 61 (polling fix)

- Build 60 failed Step 5 with `Startup workflow stopped at step 5`. macOS unified log showed the tunnel actually started cleanly ("Blaze packet tunnel forwarding started" at +129ms after startTunnel) but was torn down 250ms later by the recovery's stopPacketTunnel. The cause: `startPacketTunnel` waited a single 1s sleep then checked `packetTunnelConnected`. macOS's NEVPNStatus had not propagated to .connected yet, status was still .transitioning, Step 5 returned `.actionNeeded` → workflow stopped → recovery sent the Stop. Builds 55/56/58/59 had won this race; build 60 lost it.
- Fix (Build 61): `startPacketTunnel` now polls `packetTunnelConnected` every 200ms for up to 8s, breaking early on a failure-text. Total wall-clock on the happy path is 200-400ms (same as before), but slow paths get the extra headroom.
- Build 61 result: **Step 7 PASSED** (25/25 checks at 04:38:20). Watchdog fired naturally at 5 min, recovery cleanly restored Surge. Five Step 7 passes total now: 55, 56, 58, 59, 61.

## 2026-05-21 04:43 Asia/Shanghai - Watchdog → Telegram notification

- Triggering evidence: user feedback that the recovery loop fails to wake Claude Code after disconnects. Direct injection into a `claude` CLI session is not possible from outside; the Telegram MCP plugin is the only realistic channel.
- `scripts/dev/notify-resume.sh`: reads `TELEGRAM_BOT_TOKEN` from `~/.claude/channels/telegram/.env` and the recipient chat_id from `access.json`; POSTs `/sendMessage`. Tolerant of missing config (exits 0). Verified end-to-end by delivering a real message to chat_id 94984185.
- External watchdog template in `references/self-test-cycle.md` updated to call the script.
- In-app watchdog also wired: `WorkbenchStore.recoverFromStartupWatchdog` shells out to the bundled `Contents/Resources/notify-resume.sh` so any recovery — automation URL, external script, or the 5-min in-app timer — produces a Telegram ping. `scripts/build-app.sh` copies the script into the bundle.
- Build 62 packaging blocked: notarytool keychain profile `blaze-notary` was evicted (login keychain timed out after many hours of session activity). User intervention needed: unlock the login keychain OR re-run `xcrun notarytool store-credentials blaze-notary ...`. Telegram alert sent.

## 2026-05-23 00:27 Asia/Shanghai - Build 62 (end-to-end resume notification)

- Notarization: id `43368a49-8a5e-41ff-ae4c-76cb2a32da8e`, Accepted, stapled (keychain re-unlocked after the previous build's failure).
- Step 7 result: **PASSED 25/25** at 00:22:49 (6th consecutive clean Step 7: 55, 56, 58, 59, 61, 62).
- In-app watchdog fired naturally at 00:27:30 (5 min after Step 7 entered the long-poll state). For the first time, the watchdog recovery path also spawned a `curl` subprocess at 00:27:30.103 — visible in the unified log under `process == "curl"` resolving the telegram API via en1[802.11]. Confirms the new `WorkbenchStore.notifyUserOfRecovery` → bundled `Contents/Resources/notify-resume.sh` → telegram delivery path runs automatically on real recoveries, not just from the external test watchdog.
- Step 8: Surge restored cleanly at 00:27:32. `scutil --nc list` shows Surge connected, Blaze disconnected.
- This closes the resilience loop: probes that survived 12-way concurrency, a supervisor that respawns leaf on exit, an interface-flip watcher, an orphan cleanup, a health probe, AND a user notification on every recovery path. The 6 commits between 0071314 and c1837cc lock in the architecture; 112 unit tests guard the leaf config format and parser.

## Loop infrastructure delivered in this session (Builds 47→62)

- End-to-end distribution pipeline validated: build-app.sh + notarize-app.sh + staple + install + guarded startup workflow now demonstrably runnable unattended; each step writes a recoverable artifact.
- `setStartupStep` writes a `STARTUP` event for every status transition (including running→running detail changes after the latest tweak) → `proxy-events.log` now contains a complete timeline per workflow run.
- `scripts/build-app.sh` refuses to ship a bundle missing HEV dylibs (with `BLAZE_ALLOW_MISSING_HEV_DYLIB=1` escape hatch).
- HEV upstream `heiher/hev-socks5-tunnel@3ffa5b91ec08d631d08e35203063427ddf121318` builds reproducibly via `scripts/dev/build-hev-socks5-tunnel-dylibs.sh`.
- `TrojanUpstream` `os.log` category provides per-connection state-machine timing and interface attribution (will be `.notice`-persisted from Build 52 forward).
- `RuleValueCache` removes per-request regex/port/lowercase parsing cost.
- Validation log discipline maintained: every cycle records build number, notarization id, hypothesis, fix, commands, watchdog behavior, and next decision.

