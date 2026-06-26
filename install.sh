#!/usr/bin/env bash
#
# Mellow - one-command build + install to a wired iPhone.
#
# What this does, end to end:
#   1. checks you have the tools (Xcode, xcodegen, rust)
#   2. generates the Xcode project from project.yml
#   3. builds the Rust core + the app, signed with YOUR Apple ID
#   4. installs Mellow.app onto the iPhone plugged into this Mac
#
# HOW A SCRIPT TURNS INTO AN APP ON YOUR PHONE (the honest version):
#   iOS will not run an app unless it's *code-signed* with an Apple Developer
#   certificate tied to your Apple ID, and installed onto a device in your
#   provisioning profile. This script can drive that, but it cannot invent a
#   signing identity for you. So two things are on you, once:
#     - a Mac with Xcode (this is a native build, there's no way around a Mac)
#     - an Apple ID added to Xcode (Settings > Accounts). A FREE Apple ID works;
#       you don't need the $99 paid program for a personal sideload, though
#       free-account apps expire after 7 days and must be rebuilt.
#   With those in place, this is genuinely one command. Plug in the phone, run it.
#
# The only path that removes the Mac requirement is TestFlight, which means
# distributing a build through Apple's review - a different thing from a personal
# sideload. Not what this script does.

set -euo pipefail

cd "$(dirname "$0")/Mellow"

say()  { printf "\033[1;33m▸ %s\033[0m\n" "$1"; }   # yellow, on brand
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# 1. tools
say "checking tools"
command -v xcodebuild >/dev/null || die "Xcode not found. Install Xcode from the App Store, then run: xcode-select --install"
command -v xcodegen   >/dev/null || die "xcodegen not found. Install it: brew install xcodegen"
command -v cargo      >/dev/null || die "Rust not found. Install it: https://rustup.rs  (then add the iOS targets below)"

# the Rust iOS targets the core builds for
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed 2>/dev/null | grep -q "$t" || {
    say "adding rust target $t"
    rustup target add "$t"
  }
done

# 2. project
say "generating Xcode project"
xcodegen generate

# 3. find a connected device
say "looking for a connected iPhone"
DEVICE_ID="$(xcrun xctrace list devices 2>/dev/null \
  | grep -iE "iPhone|iPad" \
  | grep -viE "Simulator" \
  | head -1 \
  | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')"

if [[ -z "${DEVICE_ID:-}" ]]; then
  cat <<'EOF'

No wired iPhone detected. Plug your iPhone into this Mac with a cable, unlock it,
and tap "Trust" if asked. Then run ./install.sh again.

(First time only: in Xcode, set your team under the Mellow target >
Signing & Capabilities, and add your Apple ID under Settings > Accounts.)
EOF
  exit 1
fi
say "found device $DEVICE_ID"

# 4. build (signed) + install
say "building Mellow (this also builds the Rust core)"
xcodebuild \
  -project Mellow.xcodeproj \
  -scheme Mellow \
  -configuration Release \
  -destination "id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  build

# locate the freshly built .app
APP_PATH="$(xcodebuild -project Mellow.xcodeproj -scheme Mellow -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR /{d=$3} / FULL_PRODUCT_NAME /{n=$3} END{print d"/"n}')"

[[ -d "$APP_PATH" ]] || die "build succeeded but couldn't find the .app at: $APP_PATH"

say "installing onto your iPhone"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

say "done - open Mellow on your iPhone"
echo "   (if it won't launch: Settings > General > VPN & Device Management > trust your developer cert)"
