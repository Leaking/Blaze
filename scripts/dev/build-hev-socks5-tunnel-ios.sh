#!/usr/bin/env bash
#
# Build HevSocks5Tunnel.xcframework (iOS device + simulator + macOS) from
# heiher/hev-socks5-tunnel.
#
# Upstream already ships build-apple.sh which produces the full xcframework
# (iOS/iOS sim/macOS/tvOS/tvOS sim). We invoke it as-is and copy the result
# into Vendor/HevSocks5Tunnel/ios/. The tvOS slices are wasted bytes for us
# but they're cheap and keep us aligned with upstream — if you want to trim
# them, fork build-apple.sh.
#
# The mac-only dylib build (scripts/dev/build-hev-socks5-tunnel-dylibs.sh)
# continues to exist for the existing macOS pipeline — it ships individual
# .dylib files loaded via dlopen, which is incompatible with iOS.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEV_REPO_URL="${HEV_REPO_URL:-https://github.com/heiher/hev-socks5-tunnel.git}"
HEV_REF="${HEV_REF:-3ffa5b91ec08d631d08e35203063427ddf121318}"
WORK_DIR="${BLAZE_HEV_BUILD_DIR:-$ROOT_DIR/.build/hev-socks5-tunnel}"
OUTPUT_DIR="$ROOT_DIR/Vendor/HevSocks5Tunnel/ios"
XCFRAMEWORK="$OUTPUT_DIR/HevSocks5Tunnel.xcframework"

if [[ ! -d "$WORK_DIR/.git" ]]; then
    rm -rf "$WORK_DIR"
    git clone --recursive "$HEV_REPO_URL" "$WORK_DIR"
fi

cd "$WORK_DIR"
git fetch --tags origin
git checkout "$HEV_REF"
git submodule update --init --recursive
make clean

bash build-apple.sh

mkdir -p "$OUTPUT_DIR"
rm -rf "$XCFRAMEWORK"
mv HevSocks5Tunnel.xcframework "$XCFRAMEWORK"

cat >"$OUTPUT_DIR/VERSION" <<EOF
repo=$HEV_REPO_URL
ref=$HEV_REF
commit=$(git rev-parse HEAD)
EOF

echo
echo "Done: $XCFRAMEWORK"
ls "$XCFRAMEWORK"
