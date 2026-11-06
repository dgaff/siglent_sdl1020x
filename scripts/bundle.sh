#!/bin/bash
# Builds LoadLab.app (release, ad-hoc signed) into ./build/.
# Usage: scripts/bundle.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LoadLab
BIN="$(swift build -c release --show-bin-path)/LoadLab"
APP=build/LoadLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LoadLab"
VERSION="0.2.$(git rev-list --count HEAD 2>/dev/null || echo 0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LoadLab</string>
  <key>CFBundleDisplayName</key><string>LoadLab</string>
  <key>CFBundleIdentifier</key><string>local.loadlab.LoadLab</string>
  <key>CFBundleExecutable</key><string>LoadLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>LoadLab finds and controls Siglent SDL1000X electronic loads on your local network.</string>
  <key>NSBonjourServices</key><array><string>_scpi-raw._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/LoadLab.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/LoadLab.app"
fi
