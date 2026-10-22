#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Cursor额度条.app"
MACOS="$APP/Contents/MacOS"
BIN="$MACOS/QuotaBar"

mkdir -p "$MACOS" "$APP/Contents/Resources"

swiftc -O \
  -o "$BIN" \
  "$ROOT/Sources/UsageClient.swift" \
  "$ROOT/Sources/OverlayBar.swift" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -framework Foundation
chmod +x "$BIN"
codesign --force --sign - "$APP" >/dev/null

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>QuotaBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.yanan.cursor-quota-bar</string>
  <key>CFBundleName</key>
  <string>Cursor额度条</string>
  <key>CFBundleDisplayName</key>
  <string>Cursor额度条</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "built $APP"
