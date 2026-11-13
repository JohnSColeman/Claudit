#!/bin/zsh
# Builds Claudit.app (menu bar only, ad-hoc signed) into ./build
# Optional environment: UNIVERSAL=1 builds arm64 + x86_64; VERSION sets the app's version (default 0.1).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1}"
if [[ "${UNIVERSAL:-}" == "1" ]]; then
  swift build -c release --product Claudit --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/Claudit"
else
  swift build -c release --product Claudit
  BIN=".build/release/Claudit"
fi
APP="build/Claudit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Claudit"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.qbyteconsulting.Claudit</string>
  <key>CFBundleName</key><string>Claudit</string>
  <key>CFBundleExecutable</key><string>Claudit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP  (open it with: open $APP)"
