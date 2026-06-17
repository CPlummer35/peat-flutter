#!/usr/bin/env bash
# Build peat-ffi as a universal macOS dylib.
# Produces macos/Frameworks/libpeat_ffi.dylib (lipo of arm64 + x86_64).
#
# Requires: Xcode command-line tools, Rust macOS targets, protoc.
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
#
# Usage:
#   PEAT_WORKSPACE_DIR=/path/to/peat macos/build-rust.sh   # or: just build-macos
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PEAT_DIR="${PEAT_WORKSPACE_DIR:-"${SCRIPT_DIR}/../../peat"}"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
FEATURES="sync,bluetooth,lite-bridge"
MANIFEST="${PEAT_DIR}/Cargo.toml"

echo "==> Building peat-ffi for aarch64-apple-darwin"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    -p peat-ffi \
    --features "${FEATURES}" \
    --target aarch64-apple-darwin

echo "==> Building peat-ffi for x86_64-apple-darwin"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    -p peat-ffi \
    --features "${FEATURES}" \
    --target x86_64-apple-darwin

echo "==> Lipo-ing universal dylib"
mkdir -p "${FRAMEWORKS_DIR}"
lipo -create \
    "${PEAT_DIR}/target/aarch64-apple-darwin/release/libpeat_ffi.dylib" \
    "${PEAT_DIR}/target/x86_64-apple-darwin/release/libpeat_ffi.dylib" \
    -output "${FRAMEWORKS_DIR}/libpeat_ffi.dylib"

echo "==> Built ${FRAMEWORKS_DIR}/libpeat_ffi.dylib"
