#!/bin/bash
# Builds "build/Message Search.app": Rust core first, then the SwiftUI app.
set -euo pipefail
cd "$(dirname "$0")"

(cd core && cargo build --release)
swift build -c release

APP="build/Message Search.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# SwiftPM stamps the binary with the deployment target (macOS 14) as its SDK
# version. macOS reads that stamp to decide whether an app gets the current
# system design (Liquid Glass), so restamp it with the SDK actually used.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/MessageSearch" .build/release/MessageSearch
cp Info.plist "$APP/Contents/Info.plist"

# The icon is an Icon Composer document. Compile it into the layered icon
# macOS 26+ uses (Assets.car) plus a flat .icns for earlier systems.
mkdir -p "$APP/Contents/Resources"
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$(mktemp)" >/dev/null

# Sign with a real identity when there is one, so the Full Disk Access grant
# survives rebuilds (an ad-hoc signature changes with every build).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/^ *1\)/ {print $2}')}"
codesign --force --options runtime --entitlements MessageSearch.entitlements --sign "${IDENTITY:--}" "$APP"

echo "Built $APP"
