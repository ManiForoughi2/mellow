#!/usr/bin/env bash
# Build oura_core as an iOS XCFramework the Mellow app can link.
#
# Produces a fat simulator static lib (arm64 + x86_64) and a device static lib
# (arm64), then bundles both — together with the C header — into
# build/OuraCore.xcframework. The Xcode project references that framework.
#
# Re-run this whenever the Rust core changes. It is also invoked automatically
# by the app's "Build Rust core" pre-build phase (see project.yml).
set -euo pipefail

cd "$(dirname "$0")"

# Make cargo available even when invoked from Xcode's stripped PATH.
if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi

LIB=liboura_core.a
OUT=build
XC="$OUT/OuraCore.xcframework"
FEATURES="cabi"

echo "▸ building device (aarch64-apple-ios)…"
cargo build --release --features "$FEATURES" --target aarch64-apple-ios

echo "▸ building simulator (aarch64-apple-ios-sim)…"
cargo build --release --features "$FEATURES" --target aarch64-apple-ios-sim

echo "▸ building simulator (x86_64-apple-ios)…"
cargo build --release --features "$FEATURES" --target x86_64-apple-ios

echo "▸ building Mac Catalyst (aarch64-apple-ios-macabi)…"
cargo build --release --features "$FEATURES" --target aarch64-apple-ios-macabi

echo "▸ building Mac Catalyst (x86_64-apple-ios-macabi)…"
cargo build --release --features "$FEATURES" --target x86_64-apple-ios-macabi

mkdir -p "$OUT/sim" "$OUT/device" "$OUT/catalyst" "$OUT/headers"

# Fat simulator lib (arm64 + x86_64). Device is arm64-only (one slice).
lipo -create \
  "target/aarch64-apple-ios-sim/release/$LIB" \
  "target/x86_64-apple-ios/release/$LIB" \
  -output "$OUT/sim/$LIB"
cp "target/aarch64-apple-ios/release/$LIB" "$OUT/device/$LIB"

# Fat Mac Catalyst lib (arm64 + x86_64).
lipo -create \
  "target/aarch64-apple-ios-macabi/release/$LIB" \
  "target/x86_64-apple-ios-macabi/release/$LIB" \
  -output "$OUT/catalyst/$LIB"

# Header + module map so Swift can `import OuraCore`.
cp include/oura_core.h "$OUT/headers/"
cat > "$OUT/headers/module.modulemap" <<'EOF'
module OuraCore {
    header "oura_core.h"
    export *
}
EOF

rm -rf "$XC"
xcodebuild -create-xcframework \
  -library "$OUT/device/$LIB"   -headers "$OUT/headers" \
  -library "$OUT/sim/$LIB"      -headers "$OUT/headers" \
  -library "$OUT/catalyst/$LIB" -headers "$OUT/headers" \
  -output "$XC"

echo "✓ built $XC"
