#!/bin/sh
# Draws the app's icon and the install window's picture (app/art.swift) and
# packs them as app/AppIcon.icns, with every size macOS asks an icon for,
# and app/install-window.tiff, with the picture at 1x and 2x. Both are
# committed; app/build.sh and app/release.sh only copy them.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift app/art.swift "$work"

set=$work/AppIcon.iconset
mkdir "$set"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$work/icon.png" --out "$set/icon_${size}x${size}.png" > /dev/null
	sips -z "$((size * 2))" "$((size * 2))" "$work/icon.png" --out "$set/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns -o app/AppIcon.icns "$set"
tiffutil -cathidpicheck "$work/install-window.png" "$work/install-window@2x.png" -out app/install-window.tiff
