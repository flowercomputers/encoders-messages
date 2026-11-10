#!/bin/bash
# Builds the app and packs it into build/MessageSearch-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/MessageSearch-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/Message Search.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Message Search" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG"
