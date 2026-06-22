#!/usr/bin/env bash
# Render the WebM Quicklook app icon from SVG to all sizes the .appiconset wants.
#
#   - webm-icon.svg       — full design, used 64 px and up
#   - webm-icon-small.svg — no .WEBM badge, used at 16/32 px where the badge
#                           would just be a blob
#
# Re-run any time the SVGs change. Idempotent — overwrites the PNGs in place
# and leaves Contents.json alone (it's checked into git next to the PNGs).
set -euo pipefail
cd "$(dirname "$0")"

FULL=webm-icon.svg
SMALL=webm-icon-small.svg
OUT=../"Webm Quicklook"/Assets.xcassets/AppIcon.appiconset

mkdir -p "$OUT"
render() { rsvg-convert -w "$1" -h "$1" "$3" -o "$OUT/$2"; }

render 16   icon_16x16.png      "$SMALL"
render 32   icon_16x16@2x.png   "$SMALL"
render 32   icon_32x32.png      "$SMALL"
render 64   icon_32x32@2x.png   "$FULL"
render 128  icon_128x128.png    "$FULL"
render 256  icon_128x128@2x.png "$FULL"
render 256  icon_256x256.png    "$FULL"
render 512  icon_256x256@2x.png "$FULL"
render 512  icon_512x512.png    "$FULL"
render 1024 icon_512x512@2x.png "$FULL"

echo "✓ Rendered 10 PNGs into $OUT"
