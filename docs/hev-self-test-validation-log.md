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
