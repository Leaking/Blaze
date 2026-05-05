# blaze

blaze is an original macOS SwiftUI app for inspecting Surge-style proxy profiles without using Surge code, trademarks, private binaries, or license bypass techniques.

## Public Feature Notes

Public Surge materials describe a product made of several major pieces:

- Local HTTP and SOCKS5 proxy servers with a forwarding policy engine.
- Proxy policies declared in `[Proxy]`, including HTTP, HTTPS, SOCKS5, SOCKS5-TLS, SSH, WireGuard, Shadowsocks, Snell, VMess, Trojan, Hysteria2, TUIC, and related protocols.
- Proxy groups such as manual select, URL test, fallback, load balancing, SSID, and newer smart groups.
- Rule-based routing over domain, keyword, CIDR, GEOIP, rule sets, and final fallback policies.
- A Dashboard for request logs, DNS cache, policy adjustment, and debugging.
- Enhanced Mode/VIF based traffic takeover on macOS via Apple's Network Extension framework in recent versions.
- HTTP manipulation features such as rewrite, map local/remote, header rewrite, scripting, MITM, and HTTP API controls.
- Surge Mac 6 moved to a maintenance update subscription model while keeping perpetual use of the last eligible version.

Installer metadata analysis is documented in [`docs/surge-installer-analysis.md`](docs/surge-installer-analysis.md).

Sources used:

- Official site: https://www.nssurge.com/
- Surge Manual, Components: https://manual.nssurge.com/overview/components.html
- Surge Manual, Proxy Policy: https://manual.nssurge.com/policy/proxy.html
- Surge Manual, Enhanced Mode: https://manual.nssurge.com/others/enhanced-mode.html
- Official Guidance, Understanding Surge: https://manual.nssurge.com/book/understanding-surge/en/
- Surge Mac 6 Knowledge Base: https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-mac-6
- Third-party overview: https://alternativeto.net/software/surge-for-mac/about/

## Implemented

- Native macOS SwiftUI shell with sidebar navigation.
- blaze product shell with Overview, Proxies, Rules, Rule Sets, Profiles, Traffic, DNS, Logs, and Settings work areas.
- Menu bar quick switch for connect/disconnect, auto-select, global policy selection, importing, and endpoint probes.
- Dashboard-style Overview with connection/system-proxy/takeover/profile status cards, top latency cards, diagnostics, traffic summary, setup progress, and network activity visualization.
- Editable profile source pane.
- Import of user-selected local profile text files.
- Import configuration dialog for URL, local file, and subscription workflows with validation preview.
- Local persistence for the last parsed profile, subscription URL, listener ports, and selected group policies.
- Local persistence for favorite proxy markers.
- Remote profile preview and import from user-pasted `http` or `https` URLs, including plain text and base64-wrapped profile bodies.
- Safe import summary for remote and local profiles, including source size and counts without exposing credentials.
- Unit-tested remote profile downloader using a local mock subscription endpoint.
- Parser for `[General]`, `[Proxy]`, `[Proxy Group]`, and `[Rule]`.
- Preservation warnings for unsupported sections such as `[MITM]`, `[Script]`, and rewrite sections.
- Validation warnings for rule types that are parsed but not matched by the local tester/proxy.
- Proxy list with protocol, host, port, and redacted credentials.
- Filterable proxy table with protocol tabs, region inference, latency/health indicators, favorite toggles, and a detail inspector with one-click global use.
- Proxy group list with member policies and parameters.
- Search filters for large proxy, group, and rule lists.
- Manual policy selection for proxy groups; selections are used by the local proxy when it starts.
- Latency-based auto selection for URL Test, Fallback, Load Balance, and Smart groups after endpoint probes.
- Rule list with source line, type, value, and policy.
- Rule category navigation and an inspector/editor surface for adding and removing common domain rules.
- Dedicated Rule Sets surface for downloading remote `RULE-SET` entries and reviewing import status.
- User-triggered `RULE-SET` downloader and expander for plain text rule lists.
- Route tester that follows local proxy order: `skip-proxy`/`bypass-tun`, downloaded `RULE-SET` expansions, then `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-WILDCARD`, `URL-REGEX`, `IP-CIDR`, `IP-CIDR6`, `DEST-PORT`, `FINAL`, and `MATCH`.
- TCP endpoint reachability and latency checks for parsed proxy endpoints.
- Local HTTP and SOCKS5 proxy listeners on `127.0.0.1` with plain HTTP forwarding, CONNECT tunneling, `skip-proxy`/`bypass-tun` direct bypass handling, rule-aware group resolution, HTTP/SOCKS5/Trojan upstream forwarding, `DIRECT`/`REJECT` handling, unsupported-upstream blocking, in-app request logging, and policy/rule hit counters.
- macOS `networksetup` integration for enabling or disabling Web Proxy, Secure Web Proxy, and SOCKS Firewall Proxy against the app's local listener ports, plus read-only detection of available network service names, current system proxy status, and copyable command output.
- Traffic, DNS, and Logs work areas for request activity, route diagnostics, DNS-related profile settings, and local proxy event review.
- Sanitized JSON export that redacts password, token, key, secret, certificate, and PSK-like fields.
- Unit tests for parsing, rule matching, redaction, and local HTTP forwarding.
- Release build script that creates and optionally installs `/Applications/blaze.app`.

## Importing Your Own Profile

Use one of these import paths:

1. Save the Surge-style text as a `.conf` or `.surgeconfig` file.
2. Open blaze.
3. Click `Import` in the toolbar and choose the file.
4. Check `Overview` for parse counts and warnings.
5. Open `Proxies` to verify nodes. Passwords and key-like values are hidden by default.
6. Open `Groups` to verify quoted policy names and group membership.
   Pick a policy from a group's `Selected` menu before starting the local proxy if you do not want the first group member.
   After running `Probe`, click `Apply Best Latency` to update auto-style groups to the fastest reachable measured node.
7. Open `Rules` and `Tester` to inspect routing decisions.
   Click `Download Rule Sets` if you want imported `RULE-SET` entries to participate in local proxy routing.
8. Use `Server` for the local HTTP/CONNECT and SOCKS5 listeners. They resolve the current profile's rules and selected group policies. Imported HTTP, SOCKS5, and Trojan nodes can be used as upstream forwarding policies; other encrypted/custom protocols are blocked instead of silently sent direct.
   The `macOS Proxy Setup` section can detect network service names, check whether the selected service currently points at blaze, apply or disable `networksetup` settings, and copy the same commands for manual review. Quick Stop leaves system proxy settings alone when they point at another local proxy service.

You can also paste the text into `Profile` and click `Parse Profile`.
`Parse Profile` and `Save Locally` store the current profile text and settings in this app's local preferences so the next launch restores them. `Clear Saved Data` removes those saved local preferences.

For subscription links, open `Profile`, paste the URL into `Remote Import`, and click `Preview` first if you only want a safe summary. Click `Download` when you want to place the profile into the editable source pane and parse it locally.

Notes for pasted subscription-style configs:

- `[Ponte]`, `[MITM]`, `[Script]`, rewrite, and module-like sections are preserved as unsupported sections and are not executed.
- `trojan, host, port, password=...` and positional Trojan passwords are parsed and redacted.
- `RULE-SET` entries are parsed for inventory and downloaded only when you click `Download Rule Sets`.
- `skip-proxy` and `bypass-tun` entries are used by local listeners for direct bypass matching, including hostnames, wildcard domains, IPv4 CIDR, and IPv6 CIDR.
- `encrypted-dns-server` values are parsed as General settings only; DNS hijack and encrypted DNS routing are not implemented.

## Not Implemented

- No commercial software cracking, license bypass, binary patching, or DRM circumvention.
- No private Surge app reverse engineering.
- No automatic harvesting of local Surge profiles or credentials.
- No Network Extension/VIF packet takeover.
- No MITM certificate installation or HTTPS decryption.
- No HTTP request capture database.
- No JavaScript rewrite engine.
- No full implementation of custom proxy protocols such as VMess, Hysteria2, TUIC, Snell, or Shadowsocks encryption. Trojan-over-TLS TCP CONNECT forwarding is implemented, but advanced Trojan extensions are not.
- No automatic macOS system proxy modification. The app runs `networksetup` only when you explicitly click `Apply`, `Disable`, or the quick-start buttons.
- Named policies that resolve to unsupported proxy nodes are blocked to avoid accidental direct traffic leaks.

## Commands

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh --install
open -a blaze
```
