#!/bin/sh
# Build Keys for both platforms after a shared change. Unsigned only: it never uploads or registers anything.
set -eu
cd "$(dirname "$0")/.."

WHICH="${1:-all}"

build_ios() {
    echo "==> iOS Simulator (arm64)"
    xcodebuild -project Keys.xcodeproj -scheme Keys -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData \
        build
}

build_mac() {
    echo "==> macOS (arm64)"
    xcodebuild -project Keys.xcodeproj -scheme Keys -configuration Debug \
        -destination 'generic/platform=macOS' \
        -derivedDataPath build/DerivedData \
        build
}

case "$WHICH" in
    ios) build_ios ;;
    mac) build_mac ;;
    all) build_ios; build_mac ;;
    *) echo "usage: tools/build.sh [ios|mac|all]" >&2; exit 2 ;;
esac

echo "Build finished."
