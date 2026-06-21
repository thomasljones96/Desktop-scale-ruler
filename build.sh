#!/bin/bash
# Build DesktopScaleRuler.app from main.swift — no Xcode project needed.
set -e

APP="DesktopScaleRuler"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/$APP.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

echo "Building $APP.app …"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
mkdir -p "$OUT/Contents/Resources"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DesktopScaleRuler</string>
  <key>CFBundleDisplayName</key><string>Desktop Scale Ruler</string>
  <key>CFBundleIdentifier</key><string>com.jalbar.desktopscaleruler</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>DesktopScaleRuler</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# app icon (optional — only if AppIcon.icns is present next to this script)
if [ -f "$DIR/AppIcon.icns" ]; then
  cp "$DIR/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi

swiftc -O -o "$OUT/Contents/MacOS/$APP" "$DIR/main.swift" -framework Cocoa

echo "Done -> $OUT"
echo "Open it with:  open \"$OUT\""
