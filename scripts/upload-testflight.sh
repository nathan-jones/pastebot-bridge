#!/bin/zsh
# Archives the iOS app and uploads it to App Store Connect for internal TestFlight testing.
# Uses the Apple account signed in to Xcode (Settings › Accounts). Each upload gets a timestamp
# build number, so it never collides with an earlier one.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
source scripts/team-id.sh

BUILD_NUMBER=$(date +%Y%m%d.%H%M)
ARCHIVE="build/testflight/PasteViewer-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="build/testflight/export-$BUILD_NUMBER"
mkdir -p build/testflight

cat > build/testflight/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodegen generate --quiet

echo "Archiving build $BUILD_NUMBER…"
if ! xcodebuild -project PastebotBridge.xcodeproj -scheme PasteViewer -configuration Release \
     -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
     -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
     archive > build/testflight/archive.log 2>&1; then
  grep -E "error:" build/testflight/archive.log | sort -u || tail -20 build/testflight/archive.log
  echo "Archive failed. Full log: build/testflight/archive.log" >&2
  exit 1
fi

echo "Uploading to App Store Connect…"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
     -exportOptionsPlist build/testflight/ExportOptions.plist -allowProvisioningUpdates \
     > build/testflight/upload.log 2>&1; then
  grep -iE "error" build/testflight/upload.log | sort -u | head -20 || tail -20 build/testflight/upload.log
  echo "Upload failed. Full log: build/testflight/upload.log" >&2
  exit 1
fi

echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect › TestFlight after processing (usually 5–15 min)."
