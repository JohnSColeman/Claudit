#!/bin/zsh
# Builds Claudit.app (menu bar only, ad-hoc signed) into ./build
# Optional environment: UNIVERSAL=1 builds arm64 + x86_64; VERSION sets the app's version (default 0.1).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1}"
if [[ "${UNIVERSAL:-}" == "1" ]]; then
  # Build each architecture separately and join them with lipo: SwiftPM's combined --arch build is
  # unreliable on some Xcode versions.
  for arch in arm64 x86_64; do
    swift build -c release --product Claudit --triple "$arch-apple-macosx"
  done
  mkdir -p .build/universal
  BIN=".build/universal/Claudit"
  lipo -create -output "$BIN" .build/arm64-apple-macosx/release/Claudit .build/x86_64-apple-macosx/release/Claudit
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
