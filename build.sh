#!/bin/bash
# Builds "Usage Stats.app" into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Usage Stats.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift -o "$BUILD/UsageStats"

swiftc -O make-icon.swift -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD/icon.png"
mkdir "$BUILD/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/UsageStats" "$APP/Contents/MacOS/UsageStats"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
