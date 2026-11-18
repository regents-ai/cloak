#!/bin/sh
# Builds the development app, app/build/Regents Cloak.app: the menu-bar app
# and `cloak` (SwiftPM, release, two jobs, low priority, and one build at a
# time on this Mac through /tmp/cloak-build.lock), the app's AppleScript
# dictionary (app/RegentsCloak.sdef), the guest from guest/build,
# tor and libevent from host/.build/tor, and the manifest that pins them and
# the installed worker. Signed ad hoc, the app with the virtualization
# entitlement; no Developer ID and no notarization. Needs guest/build.sh,
# host/build.sh and llama-worker/install.sh to have run first.
set -eu
cd "$(dirname "$0")/.."

ls guest/build/Image guest/build/initrd.gz host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib > /dev/null

lockf /tmp/cloak-build.lock nice -n 10 swift build --package-path app -c release -j 2
bin=$(swift build --package-path app -c release --show-bin-path)

app="app/build/Regents Cloak.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/guest" "$app/Contents/Resources/tor"
cp "$bin/RegentsCloak" "$bin/cloak" "$app/Contents/MacOS/"
cp app/RegentsCloak.sdef "$app/Contents/Resources/"
cp guest/build/Image guest/build/initrd.gz "$app/Contents/Resources/guest/"
cp host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$app/Contents/Resources/tor/"

build=$(git describe --always --dirty)
release=$(plutil -extract release raw app/release.json)
sed -e "s/RELEASE/$release/" -e "s/BUILD/$build/" app/Info.plist > "$app/Contents/Info.plist"
PYTHONDONTWRITEBYTECODE=1 uv run app/manifest.py "$app/Contents/Resources" \
	"$HOME/Library/Application Support/Regents Cloak" "$build"

codesign -s - -f "$app/Contents/MacOS/cloak"
codesign -s - -f --entitlements app/RegentsCloak.entitlements "$app"
codesign --verify --strict "$app"
echo "$app"
