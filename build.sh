#!/bin/bash
# Build ScalePlanRuler.app from main.swift — no Xcode project needed.
set -e

APP="ScalePlanRuler"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/$APP.app"

# Need the Swift compiler (ships with Xcode Command Line Tools).
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
  <key>CFBundleName</key><string>ScalePlanRuler</string>
  <key>CFBundleDisplayName</key><string>Scale Plan Ruler</string>
  <key>CFBundleIdentifier</key><string>com.jalbar.scaleplanruler</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ScalePlanRuler</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

swiftc -O -o "$OUT/Contents/MacOS/$APP" "$DIR/main.swift" -framework Cocoa

echo "Done -> $OUT"
echo "Open it with:  open \"$OUT\""
