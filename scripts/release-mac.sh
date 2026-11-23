#!/bin/zsh
# Builds Pastebot Bridge for distribution outside the App Store: archives, signs with Developer ID,
# notarizes the app (through the Apple account signed in to Xcode), staples it, then packages,
# signs, notarizes and staples a DMG (through a notarytool keychain profile).
#   scripts/release-mac.sh [version]     → build/release/PastebotBridge-<version>.dmg
# NOTARY_PROFILE names the profile (default pastebot-bridge-notary), created once with:
#   xcrun notarytool store-credentials <name> --apple-id <apple id> --team-id <team id>
# The team ID comes from $DEVELOPMENT_TEAM or Config/Local.xcconfig; IDENTITY overrides the
# Developer ID certificate, which is otherwise the first one found for that team.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

VERSION=${1:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}
BUILD_NUMBER=$(date +%Y%m%d.%H%M)
OUT=build/release
ARCHIVE="$OUT/PastebotBridge-$VERSION.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/PastebotBridge-$VERSION.dmg"
NOTARY_PROFILE=${NOTARY_PROFILE:-pastebot-bridge-notary}
source scripts/team-id.sh
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' -v t="($TEAM_ID)" '/Developer ID Application/ && index($2, t) {print $2; exit}')}
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found for team $TEAM_ID." >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

fail() { grep -E "error:" "$1" | sort -u | head -20 || tail -20 "$1"; echo "$2 Full log: $1" >&2; exit 1; }

xcodegen generate --quiet
echo "Archiving $VERSION ($BUILD_NUMBER)…"
xcodebuild -project PastebotBridge.xcodeproj -scheme PastebotBridge -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive > "$OUT/archive.log" 2>&1 || fail "$OUT/archive.log" "Archive failed."

echo "Signing with Developer ID and submitting for notarization…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates \
  > "$OUT/notarize.log" 2>&1 || fail "$OUT/notarize.log" "Notarization upload failed."

echo "Waiting for Apple's notary service…"
for attempt in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
       > "$OUT/staple.log" 2>&1; then
    break
  fi
  if grep -qiE "invalid|rejected" "$OUT/staple.log"; then fail "$OUT/staple.log" "Notarization was rejected."; fi
  (( attempt == 60 )) && fail "$OUT/staple.log" "Timed out waiting for notarization."
  sleep 30
done

APP="$EXPORT/Pastebot Bridge.app"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

echo "Packaging $DMG…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pastebot Bridge $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait > "$OUT/notarize-dmg.log" 2>&1
grep -q "status: Accepted" "$OUT/notarize-dmg.log" || fail "$OUT/notarize-dmg.log" "DMG notarization failed."
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Done: $DMG"
