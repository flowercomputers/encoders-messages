#!/bin/bash
# Builds "build/Message Search.app": Rust core first, then the SwiftUI app.
set -euo pipefail
cd "$(dirname "$0")"

(cd core && cargo build --release)
swift build -c release

APP="build/Message Search.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MessageSearch "$APP/Contents/MacOS/MessageSearch"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a real identity when there is one, so the Full Disk Access grant
# survives rebuilds (an ad-hoc signature changes with every build).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/^ *1\)/ {print $2}')}"
codesign --force --options runtime --entitlements MessageSearch.entitlements --sign "${IDENTITY:--}" "$APP"

echo "Built $APP"
