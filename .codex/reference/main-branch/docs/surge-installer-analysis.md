# Surge Installer Analysis

This report uses non-invasive package inspection only. It does not include binary patching, private API reconstruction, license bypass work, disassembly, or decompilation.

Analyzed package:

- Path: `/Users/chenhuazhao/Downloads/Surge-latest (1).zip`
- Size: 47 MB
- SHA-256: `49598b0a4d6b21704d9ec6af86e712a345b2728ba1efa6308f3c15dee328b136`
- Extracted for inspection to: `/tmp/surge-inspect-20260504184546`

## Bundle Identity

The installer contains `Surge.app`, version `6.5.0` build `10960`.

Key `Info.plist` observations:

- Bundle ID: `com.nssurge.surge-mac`
- Minimum macOS: `12.0`
- Universal binary: `x86_64` and `arm64`
- Document types: `.conf` and `.surgeconfig` profiles
- Update feed: Sparkle appcast URLs under `https://nssurge.com/mac/latest/`
- Apple Events usage: browser URL collection through AppleScript
- Local network usage: LAN/router/device access
- Location usage: Wi-Fi SSID reading
- iCloud/FileProvider usage: profile sync or profile access in iCloud Drive
- ATS arbitrary loads enabled, consistent with a network debugging/proxy tool

Code-signing observations:

- Signed by `Developer ID Application: Surge Networks Inc. (YCKFLA6N72)`
- Hardened runtime enabled
- Stapled notarization ticket present on the main app
- Main app entitlement includes Network Extension, System Extension install, VM networking, CloudKit, Apple Events automation, and app group sharing

## Internal Components

The package is not a single process app. It ships several cooperating parts:

- `Surge.app/Contents/MacOS/Surge`: main AppKit application.
- `Contents/Applications/Surge Dashboard.app`: a nested Dashboard app with its own bundle ID, archive document type, and request/device/traffic views.
- `Contents/Library/LaunchServices/com.nssurge.surge-mac.helper`: privileged helper declared in `SMPrivilegedExecutables`.
- `Contents/Library/SystemExtensions/com.nssurge.surge-mac.ne.systemextension`: Network Extension system extension.
- `Contents/Resources/yasd.tar.gz`: bundled static Web Dashboard assets.
- `Contents/Frameworks/Sparkle.framework`: update delivery.
- `Contents/Frameworks/Bugsnag.framework`: crash/error reporting.
- `Contents/Frameworks/MMMarkdown.framework`: Markdown rendering.
- `Contents/Resources/ZipArchive_ZipArchive.bundle`: ZIP handling.

## Network Extension Layer

The system extension has:

- Bundle ID: `com.nssurge.surge-mac.ne`
- Package type: `SYSX`
- Display name: `Surge Network Extension`
- Network Extension class mapping for `com.apple.networkextension.packet-tunnel`
- Provider class name: `PacketTunnelProvider`
- Mach service name under the shared app group
- Entitlement: `packet-tunnel-provider-systemextension`

This confirms that Enhanced Mode is implemented through Apple's Network Extension packet tunnel system extension. The main app also has System Extension install and VM networking entitlements, which lines up with public documentation about Enhanced Mode and VM Gateway.

## Framework Inference

The main binary links to:

- `NetworkExtension.framework`, `SystemExtensions.framework`, `Network.framework`, `vmnet.framework`: packet tunnel, system extension, network stack, and VM gateway support.
- `CoreWLAN.framework` and `CoreLocation.framework`: Wi-Fi SSID and network-aware behavior.
- `ServiceManagement.framework`: privileged helper installation/management.
- `CloudKit.framework`: iCloud-backed sync features, likely Ponte/DDNS/profile-related state.
- `JavaScriptCore.framework` and `WebKit.framework`: scripting/editor/web-dashboard style functionality.
- `CoreData.framework`: persisted traffic/rule/domain data.
- `CFNetwork.framework` and `Security.framework`: proxy/network/TLS/certificate operations.

The Dashboard app links to `QuickLookUI.framework`, which fits archive and request detail inspection.

## Persistent Models

Compiled Core Data model names reveal these local stores:

- `SGTrafficStatRecord`: traffic statistics with policy, upload, download, interface, host, path, total, and request count fields.
- `SGMRuleCounterRecord`: rule hit counters with rule, count, and update time fields.
- `SGDomainSetEntry`: domain-set entries indexed by value.

These are good candidates for a legal clone's next features: local SQLite/Core Data traffic summaries, rule hit counts, and compiled domain-set cache.

## UI/Feature Surface From Resources

Localized NIB/string resource names expose a broad feature surface:

- Capture: request summary capture, HTTP body capture, filters, capture limits, Apple/crash-tracker hiding, MITM override during capture.
- Proxy editing: HTTP, HTTPS/TLS, SOCKS5, SSH, Shadowsocks, ShadowTLS, VMess, Snell, Trojan-like credential fields, WireGuard, Hysteria, TUIC, WebSocket, ALPN, SNI, certificate pinning, proxy chain, QUIC blocking, port hopping, network interface binding, IPv4/IPv6 preference.
- Groups: select, URL test/benchmarking, SSID group, policy selection, group tolerance.
- Rules: DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-WILDCARD, DOMAIN-SET, URL-REGEX, IP-CIDR, IP-CIDR6, GEOIP, IP-ASN, SRC-IP, IN-PORT, DEST-PORT, PROCESS-NAME, DEVICE-NAME, PROTOCOL, USER-AGENT, SUBNET, HOSTNAME-TYPE, logical rules, external rulesets.
- DNS: encrypted DNS, DoH, DoQ, HTTP/3 DNS, local DNS mapping, `/etc/hosts` import, specific DNS servers, DDNS, local mapping override for proxied requests.
- MITM: CA certificate creation/import/install, host list, HTTP/2 MITM, QUIC blocking for MITM hosts, server certificate verification options, iOS simulator certificate export.
- Rewrite/mapping: URL rewrite, map remote, map local, header add/delete/replace/regex replace, body rewrite/custom responses.
- Modules/external resources: module management, updates, linked sections, external proxy/ruleset style resources.
- Network takeover: system proxy, Enhanced Mode, LAN HTTP/SOCKS5 proxy, Gateway Mode, VM Gateway, DHCP server, DNS hijack, IPv6 RA override, device takeover, per-device control.
- Ponte: private cross-device network, NAT traversal, relay access, diagnostics, iCloud device sharing.
- Activity/diagnostics: active connections, events, processes, devices, traffic, DNS, route, external IP, Internet latency, diagnostic report upload, spindump, memory report.
- Automation/API: HTTP API, Web Dashboard, browser control, shell export commands.
- License/update: license management, deactivation, update subscription status, Sparkle updates.

## Architecture Takeaways For blaze

The current blaze implementation covers the lowest-risk, highest-leverage profile inspection layer:

- Profile parser for common sections.
- Proxy and group inventory.
- Basic rule decision engine.
- TCP endpoint probes.
- Local direct HTTP/CONNECT proxy listener with request logging.
- Sanitized export.
- Native macOS UI.

The metadata analysis suggests a practical roadmap:

1. Add more rule types: `DOMAIN-WILDCARD`, `DOMAIN-SET`, `URL-REGEX`, `DEST-PORT`, `SRC-IP`, `PROTOCOL`, `PROCESS-NAME`.
2. Add local persistent stores for rule hit counters and endpoint probe history.
3. Add DNS tools: local mapping editor, encrypted DNS URL validator, `/etc/hosts` importer.
4. Add module/external resource parser with update metadata, without executing third-party scripts.
5. Add policy-driven forwarding to the local proxy so rule matches can select `DIRECT`, `REJECT`, or supported upstream HTTP/SOCKS policies.
6. Add a request archive/importer and traffic summary database.
7. Add SOCKS5 listener support using open protocols and original code.
8. Treat Network Extension/VM Gateway as a separate signed-extension project because it requires Apple entitlements and careful system permissions.

## Boundaries

I did not inspect or alter license validation logic. I did not produce offsets, patches, decrypted code, or bypass strategies. The analysis is suitable for building an original tool inspired by public behavior and package-level metadata, not for cracking Surge.
