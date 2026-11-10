#!/bin/bash
# Builds a notarized build/MessageSearch-<version>.dmg.
#
# Uses the Apple account Xcode is signed in to: Xcode signs with the team's
# cloud-managed Developer ID certificate and submits to Apple's notary service,
# so no certificate or notary password has to be installed on this Mac. The
# signed-in account needs the Admin role (or Account Holder) on the team.
#
#   TEAM_ID=XXXXXXXXXX scripts/release.sh
#
# TEAM_ID defaults to the team of the local "Apple Development" certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
TEAM_ID="${TEAM_ID:-$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2}')}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# xcodebuild only exports from an archive, so wrap the built app in one.
ARCHIVE="$WORK/MessageSearch.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications"
cp -R "build/Message Search.app" "$ARCHIVE/Products/Applications/"
cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Message Search.app</string>
    <key>Architectures</key><array><string>arm64</string></array>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>SigningIdentity</key><string>Apple Development</string>
    <key>Team</key><string>$TEAM_ID</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>Message Search</string>
  <key>SchemeName</key><string>Message Search</string>
</dict></plist>
PLIST
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST

echo "Signing with Developer ID and uploading to the notary service…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/export.plist" \
    -exportPath "$WORK/upload" -allowProvisioningUpdates 2>&1 | grep -E "^error|^  |EXPORT" || true

echo "Waiting for Apple (usually a few minutes)…"
NOTARIZED="$WORK/notarized/Message Search.app"
for _ in $(seq 1 90); do
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" >/dev/null 2>&1 || true
    [ -d "$NOTARIZED" ] && break
    sleep 20
done
[ -d "$NOTARIZED" ] || { echo "Notarization did not finish; check Xcode's Organizer."; exit 1; }
spctl -a -vv "$NOTARIZED" 2>&1 | grep -q "Notarized Developer ID" || { echo "Gatekeeper did not accept the app."; exit 1; }

DMG="build/MessageSearch-$VERSION.dmg"
mkdir "$WORK/dmg"
cp -R "$NOTARIZED" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Message Search" -srcfolder "$WORK/dmg" -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG (notarized)"
