#!/usr/bin/env bash
#
# Cross-compile the vendored eycorsican/leaf `leaf-ffi` crate for iOS device
# and simulator, then assemble a Leaf.xcframework that the iPad target links
# statically.
#
# Background: on macOS Blaze runs `leaf` as a subprocess (Contents/Resources/leaf).
# iOS sandboxes forbid fork/exec, so the iPad extension links `libleaf.a` and
# calls leaf::util::run_with_options through the C ABI exposed by leaf-ffi.
#
# Inputs:
#   $LEAF_SOURCE_DIR  — local clone of eycorsican/leaf containing leaf-ffi/.
#                       Defaults to .build/leaf if present, else
#                       /Users/.../Blaze/Vendor/Leaf/leaf (the macOS checkout).
#
# Outputs:
#   Vendor/Leaf/ios/Leaf.xcframework  (gitignored)
#
# The leaf-ffi Cargo.toml currently declares `crate-type = ["staticlib","dylib"]`.
# The dylib variant fails to link for iOS (missing iOS compiler-rt symbols),
# so we use `cargo rustc --crate-type staticlib` to suppress the dylib output.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${BLAZE_LEAF_BUILD_DIR:-$ROOT_DIR/.build/leaf}"
SOURCE_DIR="${LEAF_SOURCE_DIR:-}"
OUTPUT_DIR="$ROOT_DIR/Vendor/Leaf/ios"
XCFRAMEWORK="$OUTPUT_DIR/Leaf.xcframework"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

# Pick a source tree: explicit env > worktree-local clone > sibling main checkout.
if [[ -z "$SOURCE_DIR" ]]; then
    if [[ -d "$WORK_DIR/leaf-ffi" ]]; then
        SOURCE_DIR="$WORK_DIR"
    elif [[ -d "$ROOT_DIR/Vendor/Leaf/leaf/leaf-ffi" ]]; then
        SOURCE_DIR="$ROOT_DIR/Vendor/Leaf/leaf"
    elif [[ -d "$(dirname "$ROOT_DIR")/Blaze/Vendor/Leaf/leaf/leaf-ffi" ]]; then
        SOURCE_DIR="$(dirname "$ROOT_DIR")/Blaze/Vendor/Leaf/leaf"
    else
        echo "leaf source not found. Set LEAF_SOURCE_DIR or clone https://github.com/eycorsican/leaf to Vendor/Leaf/leaf" >&2
        exit 1
    fi
fi
echo "Using leaf source at: $SOURCE_DIR"

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    if ! rustup target list --installed | grep -q "^$target$"; then
        echo "Installing rust target $target"
        rustup target add "$target"
    fi
done

build_slice() {
    local target="$1"
    echo "Building leaf-ffi for $target (IPHONEOS_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET)"
    (
        cd "$SOURCE_DIR"
        IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            cargo rustc -p leaf-ffi --release --target "$target" --crate-type staticlib
    )
    local out="$SOURCE_DIR/target/$target/release/libleaf.a"
    [[ -f "$out" ]] || { echo "Expected $out not found" >&2; exit 1; }
    echo "  -> $out ($(du -h "$out" | awk '{print $1}'))"
}

build_slice aarch64-apple-ios
build_slice aarch64-apple-ios-sim

# Assemble the xcframework. Headers come from leaf-ffi/src/lib.rs's `cbindgen`
# binding — generate one on the fly so the Swift side can `import Leaf`.
HEADERS_DIR="$(mktemp -d)"
trap 'rm -rf "$HEADERS_DIR"' EXIT
mkdir -p "$HEADERS_DIR/Leaf"

# Hand-written umbrella header. The exported FFI surface is small enough
# (leaf_run_with_options, leaf_reload, leaf_shutdown, leaf_is_running) that
# transcribing it is more reliable than adding cbindgen to the build.
cat >"$HEADERS_DIR/Leaf/leaf.h" <<'HDR'
#ifndef LEAF_H
#define LEAF_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Start leaf with a multi-threaded runtime. Blocking — call from a detached
/// task / background thread on the Swift side. Returns ERR_OK (0) when leaf
/// shuts down cleanly; any other value is a startup failure (see leaf-ffi
/// src/lib.rs ERR_* constants).
int32_t leaf_run_with_options(uint16_t rt_id,
                              const char *config_path,
                              bool auto_reload,
                              bool multi_thread,
                              bool auto_threads,
                              int32_t threads,
                              int32_t stack_size);

/// Start leaf with a single-threaded runtime. Same blocking semantics.
int32_t leaf_run(uint16_t rt_id, const char *config_path);

/// Re-read the config file for rt_id without dropping connections. Returns
/// ERR_OK on success.
int32_t leaf_reload(uint16_t rt_id);

/// Ask the leaf runtime to exit. The blocking leaf_run* call returns shortly
/// after. Returns true on success.
bool leaf_shutdown(uint16_t rt_id);

#ifdef __cplusplus
}
#endif

#endif /* LEAF_H */
HDR

cat >"$HEADERS_DIR/Leaf/module.modulemap" <<'MOD'
module Leaf {
    umbrella header "leaf.h"
    export *
}
MOD

rm -rf "$XCFRAMEWORK"
mkdir -p "$OUTPUT_DIR"
xcodebuild -create-xcframework \
    -library "$SOURCE_DIR/target/aarch64-apple-ios/release/libleaf.a" -headers "$HEADERS_DIR" \
    -library "$SOURCE_DIR/target/aarch64-apple-ios-sim/release/libleaf.a" -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK"

LEAF_REV="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
cat >"$OUTPUT_DIR/VERSION" <<EOF
source=$SOURCE_DIR
commit=$LEAF_REV
ios_deployment_target=$DEPLOYMENT_TARGET
slices=aarch64-apple-ios, aarch64-apple-ios-sim
EOF

echo
echo "Done: $XCFRAMEWORK"
ls -la "$XCFRAMEWORK"
