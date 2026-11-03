#!/bin/sh
set -eu
SRC="/Users/ant/Desktop/Icons/Keys Icon/1024"
DEST="${SRCROOT}/Keys/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$DEST"
if [ -d "$SRC" ]; then
  cp -f "$SRC/KeysIcon-iOS-Default-1024@1x.png" "$DEST/Default-1024.png"
  cp -f "$SRC/KeysIcon-iOS-Dark-1024@1x.png" "$DEST/Dark-1024.png"
  cp -f "$SRC/KeysIcon-iOS-TintedLight-1024@1x.png" "$DEST/TintedLight-1024.png"
elif [ ! -f "$DEST/Default-1024.png" ]; then
  echo "error: Keys icon folder is missing at $SRC" >&2
  exit 1
fi
rm -f "$DEST/TintedDark-1024.png"
TOOLDIR="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$TOOLDIR"
TOOL="$TOOLDIR/flatten-icon"
if [ ! -x "$TOOL" ] || [ "${SRCROOT}/Scripts/FlattenIcon.swift" -nt "$TOOL" ]; then
  xcrun --sdk macosx swiftc -swift-version 5 -O -o "$TOOL" "${SRCROOT}/Scripts/FlattenIcon.swift"
fi
"$TOOL" "$DEST/Default-1024.png" "$DEST/Default-1024.png" FF0058
if [ -f "$DEST/Dark-1024.png" ]; then
  "$TOOL" "$DEST/Dark-1024.png" "$DEST/Dark-1024.png" FF0058
fi
if [ -f "$DEST/TintedLight-1024.png" ]; then
  "$TOOL" "$DEST/TintedLight-1024.png" "$DEST/TintedLight-1024.png" FF0058
fi
resize() {
  "$TOOL" --resize "$DEST/Default-1024.png" "$1" "$DEST/$2" FF0058
}
resize 40 Icon-20@2x.png
resize 60 Icon-20@3x.png
resize 58 Icon-29@2x.png
resize 87 Icon-29@3x.png
resize 80 Icon-40@2x.png
resize 120 Icon-40@3x.png
resize 120 Icon-60@2x.png
resize 180 Icon-60@3x.png
resize 20 Icon-20-ipad.png
resize 40 Icon-20@2x-ipad.png
resize 29 Icon-29-ipad.png
resize 58 Icon-29@2x-ipad.png
resize 40 Icon-40-ipad.png
resize 80 Icon-40@2x-ipad.png
resize 76 Icon-76.png
resize 152 Icon-76@2x.png
resize 167 Icon-83.5@2x.png
resize 16 Icon-mac-16.png
resize 32 Icon-mac-16@2x.png
resize 32 Icon-mac-32.png
resize 64 Icon-mac-32@2x.png
resize 128 Icon-mac-128.png
resize 256 Icon-mac-128@2x.png
resize 256 Icon-mac-256.png
resize 512 Icon-mac-256@2x.png
resize 512 Icon-mac-512.png
resize 1024 Icon-mac-512@2x.png
FONT="/Users/ant/Desktop/Templates/Asteria Application Template 1.0/Asteria/AsteriaPixel-Regular.ttf"
if [ -f "$FONT" ]; then
  cp -f "$FONT" "${SRCROOT}/Keys/AsteriaPixel-Regular.ttf"
fi
require() {
  info=$(sips -g hasAlpha -g pixelWidth -g pixelHeight "$1") || exit 1
  has=$(printf '%s\n' "$info" | awk '/hasAlpha/{print $2}')
  width=$(printf '%s\n' "$info" | awk '/pixelWidth/{print $2}')
  height=$(printf '%s\n' "$info" | awk '/pixelHeight/{print $2}')
  echo "opaque-icon $(basename "$1") ${width}x${height} alpha=${has}"
  if [ "$has" != "no" ] || [ "$width" != "$2" ] || [ "$height" != "$2" ]; then
    echo "error: $(basename "$1") is ${width}x${height} alpha=${has}, expected ${2}x${2} with no alpha" >&2
    exit 1
  fi
}
require "$DEST/Default-1024.png" 1024
require "$DEST/Icon-60@2x.png" 120
require "$DEST/Icon-76@2x.png" 152
if [ -f "$DEST/Dark-1024.png" ]; then
  require "$DEST/Dark-1024.png" 1024
fi
if [ -f "$DEST/TintedLight-1024.png" ]; then
  require "$DEST/TintedLight-1024.png" 1024
fi
