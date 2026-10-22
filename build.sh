#!/bin/zsh
# Builds build/HoldToType.app against Homebrew's whisper-cpp (brew install whisper-cpp).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=local.holdtotype
APP=build/HoldToType.app
BREW=$(brew --prefix)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -import-objc-header Sources/WhisperBridge.h \
  -I "$BREW/include" -L "$BREW/lib" -lwhisper -lggml \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/HoldToType"

# codesign refuses bundles carrying Finder/iCloud extended attributes.
xattr -cr "$APP"

# Ad-hoc signature with an identifier-only designated requirement, so macOS privacy
# grants (Accessibility, Microphone) are tied to the bundle ID rather than to this exact build.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"

echo "Built $PWD/$APP"
