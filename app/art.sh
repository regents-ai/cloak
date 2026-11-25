#!/bin/sh
# Compiles the layered macOS 26/27 Liquid Glass app icon (app/AppIcon.icon)
# via actool into app/Assets.car + app/AppIcon.icns (Light, Dark, Clear, and
# Tinted variants), and draws the install window background (app/art.swift)
# into app/install-window.tiff. All generated files are committed; run
# app/art.sh again only when the artwork changes.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/icon-out"
swift app/art.swift "$work"

xcrun actool app/AppIcon.icon \
	--compile "$work/icon-out" \
	--output-format human-readable-text \
	--app-icon AppIcon \
	--output-partial-info-plist "$work/partial.plist" \
	--platform macosx \
	--minimum-deployment-target 26.0 \
	--target-device mac > /dev/null

cp "$work/icon-out/Assets.car" app/Assets.car
cp "$work/icon-out/AppIcon.icns" app/AppIcon.icns
tiffutil -cathidpicheck "$work/install-window.png" "$work/install-window@2x.png" -out app/install-window.tiff
