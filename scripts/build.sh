#!/bin/bash
# Builds Peek.app (one universal binary for Apple silicon and Intel) and the Peek.dmg installer.
#
#   ./scripts/build.sh             build/Peek.app and build/Peek.dmg
#   ./scripts/build.sh --install   also copy Peek into /Applications and open it
#
# Signed and notarized release (needs an Apple Developer ID; removes the first-launch Gatekeeper prompt):
#   xcrun notarytool store-credentials peek          # once
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=peek ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP=build/Peek.app
VOL="Peek"

echo "Building Peek $VERSION"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Peek"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Peek"
cp Resources/Fonts/*.ttf Resources/Setup/*.jpg Resources/Sounds/*.wav "$APP/Contents/Resources/"

# App icon
IS=build/AppIcon.iconset; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$IS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.nickechols.peek</string>
<key>CFBundleName</key><string>Peek</string>
<key>CFBundleDisplayName</key><string>Peek</string>
<key>CFBundleExecutable</key><string>Peek</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Made by Nick Echols. Free and open source under the MIT License.</string>
<key>NSScreenCaptureUsageDescription</key><string>Peek captures your screen when you take a screenshot.</string>
</dict></plist>
PLIST

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$APP"
else
  codesign --force -s - "$APP"     # ad-hoc: runs anywhere, first launch asks for "Open Anyway"
fi

# Installer: Peek and an Applications shortcut on the sky background
STAGE=build/dmg
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck Resources/Installer/background.png Resources/Installer/background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ build/rw.dmg >/dev/null
DEV=$(hdiutil attach build/rw.dmg -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1}')

# Finder lays the window out (640 x 400 content, two icons on the calm band of sky).
osascript <<OSA || echo "Finder layout skipped; the installer still works."
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 140, 880, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Peek.app" of container window to {180, 196}
    set position of item "Applications" of container window to {460, 196}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

chmod -Rf go-w "/Volumes/$VOL" || true
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "/Volumes/$VOL" -force -quiet
hdiutil convert build/rw.dmg -format UDZO -imagekey zlib-level=9 -o build/Peek.dmg >/dev/null
rm -rf build/rw.dmg "$STAGE"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --timestamp -s "$DEVELOPER_ID" build/Peek.dmg
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit build/Peek.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple build/Peek.dmg
  fi
fi

echo "Done: $(pwd)/build/Peek.dmg"
if [ "${1:-}" = "--install" ]; then
  pkill -x Peek 2>/dev/null || true
  rm -rf /Applications/Peek.app
  ditto "$APP" /Applications/Peek.app
  open /Applications/Peek.app
fi
