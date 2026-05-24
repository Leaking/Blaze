# Leaf Runtime

This directory holds local build artifacts for the embedded
[eycorsican/leaf](https://github.com/eycorsican/leaf) runtime. None of it is
checked into git.

Layout:

```
Vendor/Leaf/
  leaf/        # Cloned source tree (`git clone https://github.com/eycorsican/leaf`)
  macos-arm64/ # `leaf` Mach-O binary used by the macOS app as a subprocess
  ios/         # Leaf.xcframework (libleaf.a + leaf.h) linked by the iOS extension
```

## macOS

Build the binary once:

```bash
cd Vendor/Leaf/leaf
cargo build -p leaf-cli --release
cp target/release/leaf ../macos-arm64/leaf
```

## iOS / iPadOS

The iOS App Extension cannot fork a leaf subprocess, so we link the static
library and call its C FFI directly. Build the xcframework with:

```bash
scripts/dev/build-leaf-ffi-ios.sh
```

The script cross-compiles `leaf-ffi` for `aarch64-apple-ios` and
`aarch64-apple-ios-sim` (with `IPHONEOS_DEPLOYMENT_TARGET=15.0`), then
assembles `Vendor/Leaf/ios/Leaf.xcframework` along with a hand-written umbrella
header (`leaf.h` / `module.modulemap`) so the Swift side can `import Leaf` and
call `leaf_run_with_options`, `leaf_reload`, `leaf_shutdown`.

If the script can't find a leaf source tree, set `LEAF_SOURCE_DIR=/path/to/leaf`.
