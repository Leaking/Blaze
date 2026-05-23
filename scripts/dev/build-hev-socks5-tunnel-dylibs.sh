#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEV_REPO_URL="${HEV_REPO_URL:-https://github.com/heiher/hev-socks5-tunnel.git}"
HEV_REF="${HEV_REF:-3ffa5b91ec08d631d08e35203063427ddf121318}"
WORK_DIR="${BLAZE_HEV_BUILD_DIR:-$ROOT_DIR/.build/hev-socks5-tunnel}"
ARCH_NAME="$(uname -m)"
OUTPUT_DIR="${BLAZE_HEV_OUTPUT_DIR:-$ROOT_DIR/Vendor/HevSocks5Tunnel/macos-$ARCH_NAME}"

if [[ ! -d "$WORK_DIR/.git" ]]; then
    rm -rf "$WORK_DIR"
    git clone --recursive "$HEV_REPO_URL" "$WORK_DIR"
fi

cd "$WORK_DIR"
git fetch --tags origin
git checkout "$HEV_REF"
git submodule update --init --recursive
make clean
make shared

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp bin/libhev-socks5-tunnel.so "$OUTPUT_DIR/libhev-socks5-tunnel.dylib"
cp third-part/yaml/bin/libyaml.so "$OUTPUT_DIR/libyaml.dylib"
cp third-part/lwip/bin/liblwip.so "$OUTPUT_DIR/liblwip.dylib"
cp third-part/hev-task-system/bin/libhev-task-system.so "$OUTPUT_DIR/libhev-task-system.dylib"

install_name_tool -id "@loader_path/libyaml.dylib" "$OUTPUT_DIR/libyaml.dylib"
install_name_tool -id "@loader_path/liblwip.dylib" "$OUTPUT_DIR/liblwip.dylib"
install_name_tool -id "@loader_path/libhev-task-system.dylib" "$OUTPUT_DIR/libhev-task-system.dylib"
install_name_tool \
    -id "@loader_path/libhev-socks5-tunnel.dylib" \
    -change "bin/libyaml.so" "@loader_path/libyaml.dylib" \
    -change "bin/liblwip.so" "@loader_path/liblwip.dylib" \
    -change "bin/libhev-task-system.so" "@loader_path/libhev-task-system.dylib" \
    "$OUTPUT_DIR/libhev-socks5-tunnel.dylib"

cat >"$OUTPUT_DIR/VERSION" <<EOF
repo=$HEV_REPO_URL
ref=$HEV_REF
commit=$(git rev-parse HEAD)
arch=$ARCH_NAME
EOF

echo "Built HEV dylibs in $OUTPUT_DIR"
