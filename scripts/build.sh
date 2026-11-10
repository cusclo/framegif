#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_dir="$PWD/build.noindex"
app="$build_dir/框选 GIF.app"
iconset="$build_dir/AppIcon.iconset"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
archive="$build_dir/FrameGIF-v${version}-macos-arm64.zip"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_dir/module-cache"

xcrun swiftc -O -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path "$build_dir/module-cache" \
  scripts/AppIcon.swift -o "$build_dir/make-icon"
"$build_dir/make-icon" "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

/bin/cp Info.plist "$app/Contents/Info.plist"
xcrun swiftc -O -parse-as-library -swift-version 5 -sdk "$sdk" -target arm64-apple-macos14.0 \
  -module-cache-path "$build_dir/module-cache" Sources/*.swift -o "$app/Contents/MacOS/WindowGIF"
/usr/bin/codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
printf '%s\n' "$archive"
