#!/bin/sh
# Archive and export locally for the App Store. Uploads nothing. Run from a clean tree.
set -eu
cd "$(dirname "$0")/.."

PLATFORM="${1:-ios}"
VERSION="$(grep -m1 '"CURRENT_PROJECT_VERSION"' Keys.xcodeproj/project.xcproj | grep -oE '[0-9]+')"
echo "==> Asteria Keys 2.0 build $VERSION, platform $PLATFORM"

case "$PLATFORM" in
    ios) DESTINATION='generic/platform=iOS'; ARCHIVE="build/Keys-iOS.xcarchive"; EXPORT="build/export-ios" ;;
    mac) DESTINATION='generic/platform=macOS'; ARCHIVE="build/Keys-macOS.xcarchive"; EXPORT="build/export-mac" ;;
    *) echo "usage: tools/archive.sh [ios|mac]" >&2; exit 2 ;;
esac

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build

echo "==> Archive"
xcodebuild archive \
    -project Keys.xcodeproj \
    -scheme Keys \
    -configuration Release \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -derivedDataPath build/DerivedData

echo "==> Verify it is an app archive, not a generic one"
APP_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist")"
test -n "$APP_PATH"
echo "app: $APP_PATH"

echo "==> Export a local App Store build"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist Config/ExportOptions.plist \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates

echo "==> Export summary"
find "$EXPORT" -maxdepth 2 -type f -print | sed 's/^/  /'
echo "Archive and export finished. Nothing was uploaded."
