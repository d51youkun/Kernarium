#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source="$root/Andarium/Vendor/JitBridgeFFI"
build="$root/.build/andarium-pairing"
export CARGO_TARGET_DIR="$build/cargo"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
mkdir -p "$build"

cargo build --manifest-path "$source/Cargo.toml" --locked \
    --release --target aarch64-apple-ios
scratch=$(mktemp -d "$build/.package.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libjit_bridge_ffi.a" \
    -headers "$source/include" -output "$scratch/JitBridgeFFI.xcframework"
python3 - "$scratch/JitBridgeFFI.xcframework" "$build/JitBridgeFFI.xcframework" <<'PY'
import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
if destination.exists() or destination.is_symlink():
    destination.rename(source.parent / "previous.xcframework")
try:
    source.rename(destination)
except OSError:
    previous = source.parent / "previous.xcframework"
    if previous.exists():
        previous.rename(destination)
    raise
PY
