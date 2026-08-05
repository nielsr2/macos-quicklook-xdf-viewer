#!/usr/bin/env bash
#
# Rasterize design/AppIcon.svg into the macOS AppIcon.appiconset.
# Requires: rsvg-convert (brew install librsvg).
#
# Usage:  bash design/generate-appicon.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="design/AppIcon.svg"
OUT="Sources/XdfHostApp/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "error: rsvg-convert not found (brew install librsvg)" >&2
  exit 1
}

mkdir -p "$OUT"

# slot filename  ->  pixel size
render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$OUT/$2"; echo "  $2 (${1}px)"; }

echo "Rendering app icon from $SVG:"
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

echo "Done. 10 PNGs written to $OUT"
