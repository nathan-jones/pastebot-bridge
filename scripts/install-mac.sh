#!/bin/zsh
# Builds Pastebot Bridge (Release) and installs it to ~/Applications.
# Signed with your Apple Development certificate (automatic signing). If the menu bar window says it
# needs Full Disk Access after a reinstall, remove and re-add the app in that settings pane.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project PastebotBridge.xcodeproj -scheme PastebotBridge -configuration Release \
     -derivedDataPath build/dd-release -allowProvisioningUpdates build > build/install-mac.log 2>&1; then
  grep -E "error:" build/install-mac.log | sort -u || tail -20 build/install-mac.log
  echo "Build failed — not installing. Full log: build/install-mac.log" >&2
  exit 1
fi

APP="build/dd-release/Build/Products/Release/Pastebot Bridge.app"
DEST="$HOME/Applications/Pastebot Bridge.app"
pkill -x "Pastebot Bridge" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
sleep 1   # let the old instance finish quitting, or `open` can fail with -600
open "$DEST"
echo "Installed to $DEST"
