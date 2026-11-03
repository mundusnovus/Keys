#!/bin/sh
# Project checks that do not need a person, a device, or an Apple account.
set -eu
cd "$(dirname "$0")/.."

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

echo "==> Tests (KeysKit rules)"
if xcodebuild test -project Keys.xcodeproj -scheme KeysTests -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath build/DerivedData 2>&1 | tail -6 | grep -q "TEST SUCCEEDED"; then
    ok "KeysKit tests"
else
    bad "KeysKit tests"
fi

echo "==> Both platforms build"
if xcodebuild -project Keys.xcodeproj -scheme Keys -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build >/tmp/keys-ios-check.log 2>&1; then
    ok "iOS Simulator build"
else
    bad "iOS Simulator build (see /tmp/keys-ios-check.log)"
fi
if xcodebuild -project Keys.xcodeproj -scheme Keys -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build >/tmp/keys-mac-check.log 2>&1; then
    ok "macOS build"
else
    bad "macOS build (see /tmp/keys-mac-check.log)"
fi

echo "==> Privacy manifest"
if [ -f Keys/PrivacyInfo.xcprivacy ] && grep -q "CA92.1" Keys/PrivacyInfo.xcprivacy; then
    ok "privacy manifest declares UserDefaults CA92.1"
else
    bad "privacy manifest missing or incomplete"
fi

echo "==> Entitlements"
if grep -q '\$(APS_ENVIRONMENT)' Keys/Keys.entitlements; then
    ok "push environment comes from the build configuration"
else
    bad "push environment is hard-coded"
fi

echo "==> Required Info.plist keys"
if /usr/libexec/PlistBuddy -c 'Print :ASTERIA_CLOUDKIT' Keys/Info.plist >/dev/null 2>&1; then
    ok "ASTERIA_CLOUDKIT is present"
else
    bad "ASTERIA_CLOUDKIT is missing"
fi
if /usr/libexec/PlistBuddy -c 'Print :NSFaceIDUsageDescription' Keys/Info.plist >/dev/null 2>&1; then
    ok "Face ID usage description is present"
else
    bad "Face ID usage description is missing"
fi

echo "==> Placeholders"
if grep -rnE "com\.yourcompany|technology\.asteria\.template|TODO|FIXME" Keys/*.swift KeysKit/*.swift KeysFill/* KeysFillMac/* 2>/dev/null; then
    bad "placeholder or TODO found"
else
    ok "no placeholders in sources"
fi

echo "==> Package noise"
if find . -maxdepth 2 -name Package.swift -print | grep -q .; then
    bad "a Package.swift sits beside the app; it can create a second scheme"
else
    ok "no package executable beside the app"
fi

echo "==> Build number"
VERSION="$(grep -m1 '"CURRENT_PROJECT_VERSION"' Keys.xcodeproj/project.xcproj | grep -oE '[0-9]+')"
if [ "${VERSION:-0}" -ge 3 ]; then
    ok "current project version is $VERSION"
else
    bad "current project version is ${VERSION:-0}; bump it for the next upload"
fi

echo "==> App icon"
if [ -f Keys/Assets.xcassets/AppIcon.appiconset/Default-1024.png ]; then
    ok "1024 app icon is present"
else
    bad "1024 app icon is missing"
fi

if [ "$fail" -ne 0 ]; then
    echo "One or more checks failed."
    exit 1
fi

echo "All checks passed."
