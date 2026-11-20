#!/bin/sh
# Builds the app, app/build/Regents Cloak.app: the menu-bar app and `cloak`
# (SwiftPM, release, two jobs, low priority, and one build at a time on
# this Mac through /tmp/cloak-build.lock), Sparkle.framework, the app's
# AppleScript dictionary (app/RegentsCloak.sdef), the guest from
# guest/build, tor and libevent from host/.build/tor, NEAR mode's helper
# cloak-near (built here from guest/near with cargo, two jobs, low priority,
# through the same lock; rustup takes the Rust version from
# guest/near/rust-toolchain.toml), the worker as llama-worker/install.sh
# built and signed it, and the manifest that pins them all. The update feed
# and its public key go from app/release.json into Info.plist.
#
# Signed inside out, the app with the virtualization entitlement, every
# part with the Developer ID that app/release.json names (in the login
# keychain), under the hardened runtime and with a secure timestamp, as
# notarization requires: every build on this Mac is signed as a release is
# (decision 8a, 20 November 2026). Needs rustup, and guest/build.sh,
# host/build.sh and llama-worker/install.sh to have run first.
set -eu
cd "$(dirname "$0")/.."

identity=$(plutil -extract identity raw app/release.json)
sign() {
	codesign -s "$identity" -f -o runtime --timestamp "$@"
}

worker=llama-worker/.xcode/Build/Products/Release/cloak-rewriter-llama
ls guest/build/Image guest/build/initrd.gz host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$worker" > /dev/null

# The cd matters: rustup reads rust-toolchain.toml from the working folder.
(cd guest/near && lockf /tmp/cloak-build.lock nice -n 10 cargo build --locked --release -j 2 --bin cloak-near)
lockf /tmp/cloak-build.lock nice -n 10 swift build --package-path app -c release -j 2
bin=$(swift build --package-path app -c release --show-bin-path)

app="app/build/Regents Cloak.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/guest" "$app/Contents/Resources/tor" \
	"$app/Contents/Resources/near" "$app/Contents/Resources/worker"
cp "$bin/RegentsCloak" "$bin/cloak" "$app/Contents/MacOS/"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM's run path is the binary's own folder; the framework is in Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/RegentsCloak"
cp app/RegentsCloak.sdef "$app/Contents/Resources/"
cp guest/build/Image guest/build/initrd.gz "$app/Contents/Resources/guest/"
cp host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$app/Contents/Resources/tor/"
cp guest/near/target/release/cloak-near "$app/Contents/Resources/near/"
# Signed into its sandbox by llama-worker/install.sh. The app copies it to
# its Application Support folder at each Start and runs it from there: the
# sandbox cannot start a program kept under ~/Documents or ~/Downloads.
ditto "$worker" "$app/Contents/Resources/worker/cloak-rewriter-llama"
# Signed before the manifest pins them: signing rewrites the file. The
# worker is already signed so, into its sandbox, by llama-worker/install.sh.
sign "$app/Contents/Resources/near/cloak-near"
sign "$app/Contents/Resources/tor/libevent-2.1.7.dylib"
sign "$app/Contents/Resources/tor/tor"

build=$(git describe --always --dirty)
# The bundle's version is the commit count, a number that grows, which is
# how Sparkle tells a newer build; the manifest and the menu keep `build`.
version=$(git rev-list --count HEAD)
release=$(plutil -extract release raw app/release.json)
sed -e "s/RELEASE/$release/" -e "s/BUILD/$version/" app/Info.plist > "$app/Contents/Info.plist"
plutil -insert SUFeedURL -string "$(plutil -extract update_feed raw app/release.json)" "$app/Contents/Info.plist"
plutil -insert SUPublicEDKey -string "$(plutil -extract update_key raw app/release.json)" "$app/Contents/Info.plist"
PYTHONDONTWRITEBYTECODE=1 uv run app/manifest.py "$app/Contents/Resources" "$build"

# Inside out, as Sparkle's documentation orders it for an app signed
# outside Xcode: its helpers, the framework, `cloak`, then the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app/Contents/MacOS/cloak"
sign --entitlements app/RegentsCloak.entitlements "$app"
codesign --verify --deep --strict "$app"
# Apple's notary refuses a bundle with any program in it that lacks the
# hardened runtime or a secure timestamp; find one here instead.
find "$app" -type f -perm +111 | while IFS= read -r part; do
	details=$(codesign -dvv "$part" 2>&1)
	if ! printf '%s\n' "$details" | grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime' ||
		! printf '%s\n' "$details" | grep -q '^Timestamp='; then
		echo "$part: not signed with the hardened runtime and a secure timestamp." >&2
		exit 1
	fi
done
echo "$app"
