#!/bin/sh
# Capture real screenshots from the DEBUG demo on a booted simulator.
# Usage: tools/screenshots-ios.sh [device name] [output folder]
set -eu
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17}"
OUT="${2:-AppStore/screenshots/iphone}"

UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F-]{36}' | head -1)"
if [ -z "$UDID" ]; then
    echo "Simulator not found: $DEVICE" >&2
    exit 1
fi

APP="build/DerivedData/Build/Products/Debug-iphonesimulator/Keys.app"
if [ ! -d "$APP" ]; then
    echo "Build first: tools/build.sh ios" >&2
    exit 1
fi

mkdir -p "$OUT"
echo "==> Booting $DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Install"
xcrun simctl install "$UDID" "$APP"

echo "==> Home (light)"
xcrun simctl ui "$UDID" appearance light
xcrun simctl launch --terminate-running-process "$UDID" technology.asteria.keys -demo -no-cloud
sleep 32
xcrun simctl io "$UDID" screenshot "$OUT/home-light.png"

echo "==> Item detail (light)"
xcrun simctl launch --terminate-running-process "$UDID" technology.asteria.keys -demo -no-cloud -open first
sleep 24
xcrun simctl io "$UDID" screenshot "$OUT/detail-light.png"

echo "==> Home (dark)"
xcrun simctl ui "$UDID" appearance dark
xcrun simctl launch --terminate-running-process "$UDID" technology.asteria.keys -demo -no-cloud dark
sleep 24
xcrun simctl io "$UDID" screenshot "$OUT/home-dark.png"

echo "Screenshots in $OUT"
