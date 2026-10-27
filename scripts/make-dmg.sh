#!/bin/zsh
# Builds Sweep in Release and packages it as dist/Sweep-<version>.dmg with a styled
# Finder window (background, icon layout, volume icon) and an Applications shortcut.
#
# Signing: uses the first "Developer ID Application" identity in your keychain
#   (override with DEVELOPER_ID="Developer ID Application: Name (TEAMID)", or DEVELOPER_ID=none to skip).
# Notarizing: set NOTARY_PROFILE="sweep-notary"; create the profile once with
#   xcrun notarytool store-credentials sweep-notary --apple-id you@example.com --team-id TEAMID
# Background: drop your own scripts/dmg/background.png (+ background@2x.png, 660×400 pt)
#   to replace the generated one.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD=build
DIST=dist
ARCHIVE="$BUILD/Sweep.xcarchive"
VOLNAME="Sweep"

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  DEVELOPER_ID=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
[[ "$DEVELOPER_ID" == none ]] && DEVELOPER_ID=""

echo "› Archiving (Release)…"
rm -rf "$ARCHIVE"
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' archive -quiet

APP="$ARCHIVE/Products/Applications/Sweep.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/Sweep-$VERSION.dmg"

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "› Signing with $DEVELOPER_ID…"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --deep "$APP"
else
  echo "! No Developer ID — the DMG will only open on other Macs via right-click › Open."
fi

echo "› Staging…"
STAGING="$BUILD/dmg"
rm -rf "$STAGING" && mkdir -p "$STAGING/.background" "$DIST"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

BG_SRC="scripts/dmg"
if [[ ! -f "$BG_SRC/background.png" ]]; then
  BG_SRC="$BUILD/dmg-bg" && mkdir -p "$BG_SRC"
  swift scripts/dmg-background.swift "$BG_SRC"
fi
# Combine 1x + 2x into one HiDPI-aware TIFF so the window is sharp on Retina.
tiffutil -cathidpicheck "$BG_SRC/background.png" "$BG_SRC/background@2x.png" \
  -out "$STAGING/.background/background.tiff" 2>/dev/null

echo "› Building $DMG…"
RW="$BUILD/Sweep-rw.dmg"
rm -f "$RW" "$DMG"
# Detach any leftover mount from an interrupted run, or Finder styles the wrong window.
[[ -d "/Volumes/$VOLNAME" ]] && hdiutil detach "/Volumes/$VOLNAME" -force -quiet || true
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW" -quiet
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | sed -n 's|.*\(/Volumes/.*\)|\1|p')

# First run asks to let Terminal control Finder — allow it.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Sweep.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Volume icon (hdiutil drops .VolumeIcon.icns from -srcfolder, and Finder scripting wipes it, so add it last).
ICNS="$APP/Contents/Resources/AppIcon.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
  xcrun SetFile -a C "$MOUNT" || true
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"

if [[ -n "$DEVELOPER_ID" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "› Notarizing (this uploads the DMG to Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo "✓ $DMG"
