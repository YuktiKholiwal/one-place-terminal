#!/bin/bash
# Assembles OnePlaceTerminal.app from the SwiftPM binary.
set -euo pipefail
cd "$(dirname "$0")"

APP="OnePlaceTerminal.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OnePlace "$APP/Contents/MacOS/OnePlaceTerminal"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>OnePlaceTerminal</string>
    <key>CFBundleDisplayName</key>     <string>One Place</string>
    <key>CFBundleIdentifier</key>      <string>dev.recursive.oneplaceterminal</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>OnePlaceTerminal</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no ⌘-Tab entry. -->
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"
SIZE=$(du -sh "$APP" | cut -f1)
echo "built $APP ($SIZE)"
