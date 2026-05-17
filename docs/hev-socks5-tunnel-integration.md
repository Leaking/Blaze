# HEV Socks5 Tunnel Integration Notes

## Scope

This branch evaluates `heiher/hev-socks5-tunnel` as the first replacement
candidate for Blaze's handwritten `PacketTunnelEngine` TCP shim.

Reference repository:

- `https://github.com/heiher/hev-socks5-tunnel`
- researched commit: `3ffa5b91ec08d631d08e35203063427ddf121318`
- license: MIT

## Findings

HEV is a close technical match for Blaze:

- It is C/lwIP based and supports macOS/iOS builds.
- It exposes embeddable library entry points:
  `hev_socks5_tunnel_main_from_str`, `hev_socks5_tunnel_quit`, and
  `hev_socks5_tunnel_stats`.
- It can run with an externally supplied tunnel file descriptor. In that mode
  it does not create or configure its own utun interface.
- Its macOS tunnel read/write path expects utun-style frames: a 4-byte
  big-endian address-family header followed by the raw IP packet.
- It includes `mapdns`, which can synthesize fake IPv4 answers and restore
  domain names for SOCKS5 connect requests. That overlaps with Blaze's current
  fake-IP DNS strategy.

The main Apple platform constraint is that `NEPacketTunnelFlow` does not expose
a public file descriptor. Passing a private fd from NetworkExtension would be
fragile. The branch therefore uses a public API bridge:

1. Blaze still reads raw packets from `NEPacketTunnelFlow`.
2. `HevPacketTunnelEngine` writes those packets into one side of an
   `AF_UNIX/SOCK_DGRAM` socketpair with the 4-byte macOS utun header.
3. The other side of the socketpair is passed to HEV as `tun_fd`.
4. HEV output frames are read from the bridge, stripped back to raw IP packets,
   and written to `NEPacketTunnelFlow`.

This keeps the experiment inside public NetworkExtension APIs while giving HEV
a fd that behaves like packet-oriented utun I/O.

## Current Branch Implementation

- `packetEngine=native` remains the default and keeps the current TCP shim.
- `packetEngine=hev` starts the optional HEV engine.
- The HEV engine loads `libhev-socks5-tunnel.dylib` at runtime from the System
  Extension `Contents/Frameworks`, or from a configured
  `hevLibraryDirectory`.
- `scripts/dev/build-hev-socks5-tunnel-dylibs.sh` builds HEV shared libraries
  and rewrites install names for bundled loading.
- `scripts/build-app.sh` copies and signs local HEV dylibs when they exist under
  `Vendor/HevSocks5Tunnel/macos-arm64`.

## Test Plan

1. Build the HEV runtime:

   ```bash
   scripts/dev/build-hev-socks5-tunnel-dylibs.sh
   ```

2. Build and install Blaze as usual:

   ```bash
   ./scripts/build-app.sh --install
   ```

3. Install a Packet Tunnel configuration whose provider configuration includes:

   ```text
   packetEngine = hev
   ```

4. Start local SOCKS/HTTP listeners, then start the tunnel.

5. Watch diagnostics:

   - `packetsRead` should increment for input from `NEPacketTunnelFlow`.
   - `hevPacketsSentToTunnel` should increment for bridge input into HEV.
   - `hevPacketsReceivedFromTunnel` should increment for HEV output.
   - `hevBridgeWriteFailures` should stay at zero.
   - HEV stats should show non-zero tx/rx packet counters under real traffic.

## Risks

- The socketpair bridge is an extra packet copy in each direction. It is still a
  smaller risk than relying on private NetworkExtension internals.
- HEV's `quit` API is process-global, so this integration assumes one active
  HEV tunnel instance per provider process.
- The current branch uses runtime-loaded dylibs for fast research iteration.
  Production integration should prefer a pinned XCFramework or a fully vendored
  static build path.
- mapdns currently covers A records. IPv6 behavior needs focused testing before
  removing Blaze's IPv6 blackhole fallback.
- Real stability still requires System Extension runtime testing with signed
  entitlements; SwiftPM tests can only validate build and configuration logic.

## Recommendation

HEV is feasible enough for the next phase. The public `NEPacketTunnelFlow` to
socketpair bridge is the key enabling piece: it lets us exercise HEV inside the
Packet Tunnel/System Extension without private APIs. The next milestone should
be a signed local tunnel run that verifies TCP browsing, DNS fake-IP mapping,
UDP relay behavior, stop/start cleanup, and sleep/wake recovery.
