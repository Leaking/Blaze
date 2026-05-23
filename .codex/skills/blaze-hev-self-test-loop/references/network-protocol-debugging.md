# Network Protocol Debugging Reference

Use this reference when Blaze HEV startup reaches networking behavior but does not produce clean connectivity. The goal is to avoid single-layer tunnel vision: a Google timeout can come from macOS extension lifecycle, TUN routes, FakeIP/DNS, lwIP TCP state, SOCKS5/CONNECT, upstream proxy selection, physical-interface pinning, MTU/MSS, or the remote node.

## Layer Map

Check layers in this order unless logs clearly point elsewhere:

1. **Distribution and lifecycle**: `spctl`, `codesign`, app build, bundled extension build, active extension build, `systemextensionsctl list`.
2. **macOS Network Extension**: provider started, tunnel connected, utun present, routes installed, excluded routes for upstream IPs.
3. **DNS and FakeIP**: DNS query count, FakeIP allocation, fake-IP TCP mapping, A/AAAA behavior, DoH reachability, local names bypass.
4. **Packet/TUN ingress**: packet counters, DNS packet count, TCP SYN count, unexpected drops, route loops.
5. **lwIP/TCP state**: SYN/SYN-ACK/ACK flow, retransmits, resets, FIN/close, pending write capacity, window pressure, idle deadline.
6. **SOCKS5/HTTP proxy layer**: CONNECT completion, SOCKS5 greeting/connect, full fetch body transfer, timeout boundary, backpressure.
7. **Upstream proxy layer**: Trojan handshake, TLS/SNI, selected policy, node latency, direct leak prevention, unsupported policy handling.
8. **Physical path**: interface binding, prohibited loopback/tunnel interfaces, Surge or other VPN ownership, system proxy state.
9. **Transport tuning**: MTU/MSS, QUIC/UDP suppression, TCP keepalive, connect timeout versus full transfer timeout.

## External Projects To Check

Prefer official repositories and docs. Use issue search for exact symptoms and source search for implementation patterns. Do not copy code unless license and integration risk are reviewed.

- **heiher/hev-socks5-tunnel**: closest C/lwIP socks5 tunnel reference for TUN-to-SOCKS behavior, lwIP integration, macOS/iOS portability, and SOCKS5 timing.
  - https://github.com/heiher/hev-socks5-tunnel
- **xjasonlyu/tun2socks**: gVisor-based tun2socks reference for TUN routing, TCP/IP stack behavior, DNS/UDP tradeoffs, and transparent proxy diagnostics.
  - https://github.com/xjasonlyu/tun2socks
- **google/gvisor**: mature userspace TCP/IP stack reference. Useful for packet state machine expectations, not a direct macOS System Extension embedding target.
  - https://github.com/google/gvisor
- **SagerNet/sing-box**: broad proxy/tun architecture reference for routing, DNS, FakeIP, TUN stack settings, interface selection, and lifecycle diagnostics.
  - https://github.com/SagerNet/sing-box
  - https://sing-box.sagernet.org
- **MetaCubeX/mihomo**: Clash.Meta-derived proxy core reference for rule/policy behavior, TUN mode, FakeIP, DNS hijack, and operational diagnostics.
  - https://github.com/MetaCubeX/mihomo
  - https://wiki.metacubex.one
- **XTLS/Xray-core**: V2Ray-family proxy core reference for outbound dialing, stream settings, DNS/routing interaction, and transparent proxy setups.
  - https://github.com/XTLS/Xray-core
  - https://xtls.github.io
- **v2fly/v2ray-core**: baseline V2Ray architecture reference for routing, DNS, inbound/outbound separation, and compatibility behavior.
  - https://github.com/v2fly/v2ray-core
- **shadowsocks/shadowsocks-rust**: high-quality Rust proxy implementation reference for SOCKS/HTTP local proxy handling, timeout behavior, TCP/UDP relay, and DNS interactions.
  - https://github.com/shadowsocks/shadowsocks-rust
- **apernet/hysteria**: QUIC-based proxy reference for unreliable/latent networks and diagnostics around remote path quality. Use mostly for network-quality comparison, not Blaze's current HEV TCP path.
  - https://github.com/apernet/hysteria

## How To Use External References

For each bug:

1. Write the observed symptom in protocol terms, such as `SOCKS5 CONNECT succeeds in 9s but SOCKS5 Fetch times out at 35s`, `fake-IP TCP mapping exists but no upstream bytes`, or `active extension build lags bundled build`.
2. Search the closest project first:
   - HEV/lwIP symptoms: `heiher/hev-socks5-tunnel`, then `xjasonlyu/tun2socks`.
   - TUN/DNS/FakeIP symptoms: `sing-box`, `mihomo`, then `Xray-core`.
   - TCP stack symptoms: `gVisor`, `tun2socks`, HEV lwIP.
   - SOCKS/HTTP local proxy symptoms: `shadowsocks-rust`, `sing-box`, `mihomo`.
3. Compare at least two sources when the first source suggests a broad fix.
4. Translate ideas into Blaze's architecture:
   - macOS app/System Extension split
   - Swift PacketTunnelProvider lifecycle
   - HEV C/lwIP bridge
   - local HTTP/SOCKS5 proxy and Trojan upstream
   - startup workflow and watchdog UI
5. Record the reference, useful pattern, rejected pattern, and resulting decision in `docs/hev-self-test-validation-log.md`.

## Protocol Heuristics

- A CONNECT pass without fetch pass usually means the proxy handshake is not enough evidence; inspect sustained byte flow, backpressure, close, and timeout boundaries.
- Browser partial success while curl fails can mean concurrency pressure, node slowness, TLS handshake slowness, user-agent/server behavior, or timeout selection. Compare packet counters and slow successful probes before changing TCP logic.
- Step 2 failures are not protocol failures. Fix app trust, notarization, active extension version, or user approval first.
- DNS pass with HTTP failure means split the path: DNS/FakeIP allocation, fake-IP reverse mapping, TCP SYN handling, SOCKS connect, upstream connect, then data relay.
- Repeated retransmits without resets point toward route loop, MTU/MSS, blackhole, window/backpressure, or upstream interface binding.
- Immediate resets point toward unsupported policy, proxy refusal, malformed SOCKS/Trojan framing, or lifecycle shutdown.
- If Surge was active recently, treat utun ownership, system proxy state, and DNS hijack as first-class suspects.
