# Packet Tunnel Development Notes

Blaze now includes a Network Extension system extension scaffold and an initial
transparent IPv4 packet engine:

- Host app bundle ID: `com.chenhuazhao.blaze`
- System extension bundle ID: `com.chenhuazhao.blaze.tunnel`
- Provider class: `PacketTunnelProvider`
- Network Extension type: `packet-tunnel-provider-systemextension`

The current tunnel installs a default IPv4 route. It supports transparent IPv4
TCP via the local SOCKS5 listener, DNS A fake-IP synthesis with
`198.18.0.0/15`, DNS over HTTPS fallback, AAAA suppression while IPv6
forwarding is incomplete, TCP inbound reassembly, basic outbound ACK tracking
and retransmission, idle flow cleanup, and a gated first-pass UDP relay path
through local SOCKS5 UDP ASSOCIATE.

Non-DNS UDP currently returns ICMP destination unreachable to make QUIC-capable
clients fall back to TCP because `enableUDPRelay` is kept `false` in the host
configuration. The UDP relay implementation can encapsulate IPv4 UDP payloads
into local SOCKS5 UDP ASSOCIATE and write responses back as IPv4 UDP packets,
but it should stay gated until upstream UDP support and route-aware fallback are
complete. Full Surge-style parity still needs production UDP relay, complete
IPv6 forwarding, richer connection lifecycle handling, and better runtime
diagnostics.

## Local build

```bash
./scripts/build-app.sh
```

The build creates:

```text
build/blaze.app
build/blaze.app/Contents/Library/SystemExtensions/com.chenhuazhao.blaze.tunnel.systemextension
```

Install to `/Applications`:

```bash
./scripts/build-app.sh --install
```

## Signing

The build script signs with ad-hoc identity by default:

```bash
BLAZE_SIGN_IDENTITY=- ./scripts/build-app.sh
```

For real local packet tunnel activation, use an Apple Developer signing identity and provisioning profiles that include:

- Host app: `com.apple.developer.system-extension.install`
- System extension: `com.apple.developer.networking.networkextension = packet-tunnel-provider-systemextension`

The entitlements templates are:

```text
Entitlements/Blaze.entitlements
Entitlements/BlazeTunnelExtension.entitlements
```

Ad-hoc signing is enough to verify the bundle layout and app UI, but macOS is expected to reject real Network Extension activation if the entitlement is not authorized by Apple.

### Developer ID notarization

Developer ID builds that contain a System Extension must be notarized before activation. The build script uses a secure timestamp automatically when `BLAZE_SIGN_IDENTITY` starts with `Developer ID Application:`.

Create a notarytool keychain profile once:

```bash
xcrun notarytool store-credentials blaze-notary \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id HYF3XBWBL2 \
  --password "APP_SPECIFIC_PASSWORD"
```

Then notarize and staple the built app:

```bash
BLAZE_NOTARY_PROFILE=blaze-notary ./scripts/notarize-app.sh build/blaze.app
```

After notarization succeeds, install the stapled app to `/Applications` before clicking `Install Extension`.

### Current signing result

The team `HYF3XBWBL2` can create the host app profile:

```text
Mac Team Provisioning Profile: com.chenhuazhao.blaze
com.apple.developer.system-extension.install = true
```

The Mac Development tunnel profile currently contains ordinary Network
Extension values only:

```text
Mac Team Provisioning Profile: com.chenhuazhao.blaze.tunnel
com.apple.developer.networking.networkextension = [
  app-proxy-provider,
  content-filter-provider,
  packet-tunnel-provider,
  dns-proxy,
  dns-settings,
  relay,
  url-filter-provider,
  hotspot-provider
]
```

That is not enough for the `.systemextension` bundle used here. Signing a
system extension with `packet-tunnel-provider` instead of
`packet-tunnel-provider-systemextension` can produce an app bundle that passes
`codesign --verify` but is rejected by macOS at launch/activation time. The
build script therefore requires the exact
`packet-tunnel-provider-systemextension` value before producing a restricted
system-extension build.

The Developer ID tunnel profile now contains:

```text
Blaze Tunnel Developer ID
com.apple.developer.networking.networkextension = [
  packet-tunnel-provider-systemextension,
  app-proxy-provider-systemextension,
  content-filter-provider-systemextension,
  dns-proxy-systemextension,
  dns-settings,
  relay,
  url-filter-provider,
  hotspot-provider
]
```

The local Mac registered for development is:

```text
Name: 陈华钊的Mac mini
UUID: 091F172A-DF57-509D-B2A2-FFA9AC532ABD
```

## Developer mode

For local System Extension iteration on a development Mac:

```bash
systemextensionsctl developer on
```

This reduces development friction, but it does not bypass Network Extension entitlement checks.

## UI flow

Open Blaze Settings, then use the Packet Tunnel section:

1. `Install Extension`
2. Approve in System Settings if prompted
3. `Install Config`
4. `Start Tunnel`

The current provider takes over IPv4 TCP and DNS. Keep Surge available while
testing Blaze so Codex and ChatGPT connectivity can recover if a tunnel build
regresses.
