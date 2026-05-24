# HevSocks5Tunnel Runtime

This directory is for local HEV dylibs used by the experimental `packetEngine=hev`
Packet Tunnel mode.

Generate the dylibs with:

```bash
scripts/dev/build-hev-socks5-tunnel-dylibs.sh
```

The script pins `heiher/hev-socks5-tunnel` at commit
`3ffa5b91ec08d631d08e35203063427ddf121318`, builds `make shared`, copies the
runtime libraries into `Vendor/HevSocks5Tunnel/macos-$(uname -m)`, and rewrites
Mach-O install names to `@loader_path` so the System Extension can load them
from `Contents/Frameworks`.

The generated dylibs are local build artifacts and are intentionally ignored by
Git.

## iOS / iPadOS

iOS App Extensions can't `dlopen` a dylib from the bundle, so the iPad target
links the static archive instead. Build it with:

```bash
scripts/dev/build-hev-socks5-tunnel-ios.sh
```

The script reuses the same upstream pin and runs upstream's `build-apple.sh`,
producing `Vendor/HevSocks5Tunnel/ios/HevSocks5Tunnel.xcframework` with iOS,
iOS Simulator, macOS and tvOS slices. Only the iOS slices are used by the
iPad target; the rest are leftover from upstream's script and harmless.
