# Packet Tunnel Development Notes

Blaze now includes a minimal Network Extension system extension scaffold:

- Host app bundle ID: `com.chenhuazhao.blaze`
- System extension bundle ID: `com.chenhuazhao.blaze.tunnel`
- Provider class: `PacketTunnelProvider`
- Network Extension type: `packet-tunnel-provider-systemextension`

The scaffold intentionally does not install a default route yet. Starting it should create a provider lifecycle without taking over system traffic. Full Surge-style takeover still needs packet routing, DNS handling, and TCP/UDP forwarding.

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

### Current personal account result

The personal development team `HYF3XBWBL2` can create the host app profile:

```text
Mac Team Provisioning Profile: com.chenhuazhao.blaze
com.apple.developer.system-extension.install = true
```

The same team currently generates the tunnel profile with ordinary Network Extension values only:

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

That is not enough for the `.systemextension` bundle used here. Signing a system extension with `packet-tunnel-provider` instead of `packet-tunnel-provider-systemextension` can produce an app bundle that passes `codesign --verify` but is rejected by macOS at launch/activation time. The build script therefore requires the exact `packet-tunnel-provider-systemextension` value before producing a restricted system-extension build.

The local Mac registered for development is:

```text
Name: 陈华钊的Mac mini
UUID: 091F172A-DF57-509D-B2A2-FFA9AC532ABD
```

To continue with Surge-style enhanced mode, the developer team used for the tunnel bundle ID must be granted the `packet-tunnel-provider-systemextension` Network Extension entitlement by Apple. A standard `packet-tunnel-provider` profile is enough for an app-extension packet tunnel, but not for this System Extension path.

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

The current provider is a lifecycle scaffold. It should not become the default route until packet forwarding is implemented.
