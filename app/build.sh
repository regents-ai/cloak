#!/bin/sh
# Builds the development app, app/build/Regents Cloak.app: the menu-bar app
# and `cloak` (SwiftPM, release, two jobs, low priority, and one build at a
# time on this Mac through /tmp/cloak-build.lock), Sparkle.framework, the
# app's AppleScript dictionary (app/RegentsCloak.sdef), the guest from
# guest/build, tor and libevent from host/.build/tor, NEAR mode's helper
# cloak-near (built here from guest/near with cargo, two jobs, low priority,
# through the same lock; rustup takes the Rust version from
# guest/near/rust-toolchain.toml), and the manifest that pins them and the
# installed worker. The update feed and its public key
# from app/release.json go into Info.plist when both are set; with neither,
# the app has no updater. Signed ad hoc, inside out, the app with the
# virtualization entitlement; no Developer ID and no notarization. Needs
# rustup, and guest/build.sh, host/build.sh and llama-worker/install.sh to
# have run first.
set -eu
cd "$(dirname "$0")/.."

ls guest/build/Image guest/build/initrd.gz host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib > /dev/null
feed=$(plutil -extract update_feed raw app/release.json)
key=$(plutil -extract update_key raw app/release.json)
if [ -n "$feed$key" ] && { [ -z "$feed" ] || [ -z "$key" ]; }; then
	echo "app/release.json: set update_feed and update_key together, or leave both empty." >&2
	exit 1
fi

# The cd matters: rustup reads rust-toolchain.toml from the working folder.
(cd guest/near && lockf /tmp/cloak-build.lock nice -n 10 cargo build --locked --release -j 2 --bin cloak-near)
lockf /tmp/cloak-build.lock nice -n 10 swift build --package-path app -c release -j 2
bin=$(swift build --package-path app -c release --show-bin-path)

app="app/build/Regents Cloak.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/guest" "$app/Contents/Resources/tor" \
	"$app/Contents/Resources/near"
cp "$bin/RegentsCloak" "$bin/cloak" "$app/Contents/MacOS/"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM's run path is the binary's own folder; the framework is in Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/RegentsCloak"
cp app/RegentsCloak.sdef "$app/Contents/Resources/"
cp guest/build/Image guest/build/initrd.gz "$app/Contents/Resources/guest/"
cp host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$app/Contents/Resources/tor/"
cp guest/near/target/release/cloak-near "$app/Contents/Resources/near/"
# Signed before the manifest pins it: signing rewrites the file.
codesign -s - -f "$app/Contents/Resources/near/cloak-near"

build=$(git describe --always --dirty)
# The bundle's version is the commit count, a number that grows, which is
# how Sparkle tells a newer build; the manifest and the menu keep `build`.
version=$(git rev-list --count HEAD)
release=$(plutil -extract release raw app/release.json)
sed -e "s/RELEASE/$release/" -e "s/BUILD/$version/" app/Info.plist > "$app/Contents/Info.plist"
if [ -n "$feed" ]; then
	plutil -insert SUFeedURL -string "$feed" "$app/Contents/Info.plist"
	plutil -insert SUPublicEDKey -string "$key" "$app/Contents/Info.plist"
fi
PYTHONDONTWRITEBYTECODE=1 uv run app/manifest.py "$app/Contents/Resources" \
	"$HOME/Library/Application Support/Regents Cloak" "$build"

# Inside out, as Sparkle's documentation orders it for an app signed
# outside Xcode: its helpers, the framework, `cloak`, then the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
codesign -s - -f -o runtime "$sparkle/Versions/B/XPCServices/Installer.xpc"
codesign -s - -f -o runtime --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
codesign -s - -f -o runtime "$sparkle/Versions/B/Autoupdate"
codesign -s - -f -o runtime "$sparkle/Versions/B/Updater.app"
codesign -s - -f -o runtime "$sparkle"
codesign -s - -f "$app/Contents/MacOS/cloak"
codesign -s - -f --entitlements app/RegentsCloak.entitlements "$app"
codesign --verify --deep --strict "$app"
echo "$app"
