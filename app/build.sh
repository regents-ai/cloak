#!/bin/sh
# Builds the app, app/build/Cloak.app: the menu-bar app and `cloak`
# (SwiftPM, release, two jobs, low priority, and one build at a time on
# this Mac through /tmp/cloak-build.lock), Sparkle.framework, the app's
# AppleScript dictionary (app/RegentsCloak.sdef), its icon (app/AppIcon.icns,
# drawn by app/art.sh), the guest from
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
#
#     app/build.sh                  builds Cloak.app (includes Inference Serving / Darkbloom)
#     app/build.sh no-darkbloom     builds without Darkbloom's window
#     app/build.sh dev              builds isolated Cloak Dev.app (sh.regents.cloak.dev,
#                                   separate Application Support, Keychain, port 8743, no Sparkle)
#     app/build.sh dev no-darkbloom builds isolated Cloak Dev.app without Darkbloom
set -eu
cd "$(dirname "$0")/.."

dev=""
darkbloom="-Xswiftc -DDARKBLOOM"
for arg in "$@"; do
	case "$arg" in
	""|darkbloom) darkbloom="-Xswiftc -DDARKBLOOM" ;;
	no-darkbloom) darkbloom="" ;;
	dev) dev="1" ;;
	*)
		echo "usage: app/build.sh [dev] [no-darkbloom]" >&2
		exit 2
		;;
	esac
done

identity=$(plutil -extract identity raw app/release.json)
sign() {
	codesign -s "$identity" -f -o runtime --timestamp "$@"
}

worker=llama-worker/.xcode/Build/Products/Release/cloak-rewriter-llama
vmlx_worker=vmlx-worker/.build/release/cloak-worker-vmlx
vmlx_bundle=vmlx-worker/.build/release/mlx-swift_Cmlx.bundle
ls guest/build/Image guest/build/initrd.gz host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$worker" > /dev/null

# The cd matters: rustup reads rust-toolchain.toml from the working folder.
(cd guest/near && lockf /tmp/cloak-build.lock nice -n 10 cargo build --locked --release -j 2 --bin cloak-near)
# Unquoted: two words or none.
# shellcheck disable=SC2086
lockf /tmp/cloak-build.lock nice -n 10 swift build --package-path app -c release -j 2 $darkbloom
bin=$(swift build --package-path app -c release --show-bin-path)

if [ -n "$dev" ]; then
	app="app/build/Cloak Dev.app"
else
	app="app/build/Cloak.app"
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/PlugIns" "$app/Contents/Resources/guest" \
	"$app/Contents/Resources/tor" "$app/Contents/Resources/near" "$app/Contents/Resources/worker"
cp "$bin/RegentsCloak" "$bin/cloak" "$app/Contents/MacOS/"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM's run path is the binary's own folder; the framework is in Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/RegentsCloak"
cp app/AppIcon.icns "$app/Contents/Resources/"
if [ -f app/Assets.car ]; then
	cp app/Assets.car "$app/Contents/Resources/"
fi
cp app/Credits.html "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# The dictionary names `show darkbloom` only where the app has the window.
if [ -n "$darkbloom" ]; then
	cp app/RegentsCloak.sdef "$app/Contents/Resources/"
else
	sed '/<command name="show darkbloom"/,/<\/command>/d' app/RegentsCloak.sdef > "$app/Contents/Resources/RegentsCloak.sdef"
fi
cp guest/build/Image guest/build/initrd.gz "$app/Contents/Resources/guest/"
cp host/.build/tor/tor host/.build/tor/libevent-2.1.7.dylib "$app/Contents/Resources/tor/"
cp guest/near/target/release/cloak-near "$app/Contents/Resources/near/"
# Signed into its sandbox by llama-worker/install.sh. The app copies it to
# its Application Support folder at each Start and runs it from there: the
# sandbox cannot start a program kept under ~/Documents or ~/Downloads.
ditto "$worker" "$app/Contents/Resources/worker/cloak-rewriter-llama"
if [ -f "$vmlx_worker" ] && [ -d "$vmlx_bundle" ]; then
	ditto "$vmlx_worker" "$app/Contents/Resources/worker/cloak-worker-vmlx"
	ditto "$vmlx_bundle" "$app/Contents/Resources/worker/mlx-swift_Cmlx.bundle"
	sign --entitlements vmlx-worker/cloak-vmlx.entitlements "$app/Contents/Resources/worker/cloak-worker-vmlx"
fi
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
if [ -n "$dev" ]; then
	plutil -replace CFBundleIdentifier -string "sh.regents.cloak.dev" "$app/Contents/Info.plist"
	plutil -replace CFBundleDisplayName -string "Cloak Dev" "$app/Contents/Info.plist"
	plutil -replace CFBundleName -string "Cloak Dev" "$app/Contents/Info.plist"
	plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "sh.regents.cloak.dev.action" "$app/Contents/Info.plist"
	plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes -json '["cloak-dev"]' "$app/Contents/Info.plist"
else
	plutil -insert SUFeedURL -string "$(plutil -extract update_feed raw app/release.json)" "$app/Contents/Info.plist"
	plutil -insert SUPublicEDKey -string "$(plutil -extract update_key raw app/release.json)" "$app/Contents/Info.plist"
fi

# Embed Control Center & Desktop WidgetKit extension (CloakWidgets.appex) in
# production builds only so Cloak Dev never registers duplicate system widgets.
if [ -z "$dev" ] && [ -f "$bin/CloakWidgets" ]; then
	appex="$app/Contents/PlugIns/CloakWidgets.appex"
	mkdir -p "$appex/Contents/MacOS"
	cp "$bin/CloakWidgets" "$appex/Contents/MacOS/CloakWidgets"
	sed -e "s/RELEASE/$release/" -e "s/BUILD/$version/" app/CloakWidgets.Info.plist > "$appex/Contents/Info.plist"
fi

# Extract App Intents metadata for Spotlight Actions, Shortcuts, Control Center & Widgets.
ai_tool="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
if [ -x "$ai_tool" ]; then
	ai_work=$(mktemp -d)
	ai_sdk="$(xcrun --show-sdk-path)"
	ai_xcode="$(xcodebuild -version | awk '/Build version/ {print $3}')"
	find app/Sources/RegentsCloak -name "*.swift" > "$ai_work/app-sources.txt"
	find app/.build -ipath "*release*RegentsCloak-p.build*" -name "*.swiftconstvalues" > "$ai_work/app-constvals.txt" 2>/dev/null || true
	if [ ! -s "$ai_work/app-constvals.txt" ]; then
		find app/.build -ipath "*release*" -name "*.swiftconstvalues" > "$ai_work/app-constvals.txt" 2>/dev/null || true
	fi
	if [ -s "$ai_work/app-constvals.txt" ]; then
		"$ai_tool" \
			--output "$app/Contents/Resources" \
			--toolchain-dir "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain" \
			--module-name RegentsCloak \
			--sdk-root "$ai_sdk" \
			--xcode-version "$ai_xcode" \
			--platform-family macOS \
			--deployment-target 26.0 \
			--target-triple arm64-apple-macos26.0 \
			--source-file-list "$ai_work/app-sources.txt" \
			--swift-const-vals-list "$ai_work/app-constvals.txt" \
			--no-app-shortcuts-localization \
			--force --quiet-warnings || true
	fi
	if [ -d "$app/Contents/PlugIns/CloakWidgets.appex" ]; then
		mkdir -p "$app/Contents/PlugIns/CloakWidgets.appex/Contents/Resources"
		find app/Sources/CloakWidgets -name "*.swift" > "$ai_work/widget-sources.txt"
		find app/.build -ipath "*release*CloakWidgets*" -name "*.swiftconstvalues" > "$ai_work/widget-constvals.txt" 2>/dev/null || true
		if [ -s "$ai_work/widget-constvals.txt" ]; then
			"$ai_tool" \
				--output "$app/Contents/PlugIns/CloakWidgets.appex/Contents/Resources" \
				--toolchain-dir "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain" \
				--module-name CloakWidgets \
				--sdk-root "$ai_sdk" \
				--xcode-version "$ai_xcode" \
				--platform-family macOS \
				--deployment-target 26.0 \
				--target-triple arm64-apple-macos26.0 \
				--source-file-list "$ai_work/widget-sources.txt" \
				--swift-const-vals-list "$ai_work/widget-constvals.txt" \
				--no-app-shortcuts-localization \
				--force --quiet-warnings || true
		fi
	fi
	rm -rf "$ai_work"
fi

PYTHONDONTWRITEBYTECODE=1 uv run app/manifest.py "$app/Contents/Resources" "$build"

# Inside out, as Sparkle's documentation orders it for an app signed
# outside Xcode: its helpers, the framework, the widget extension, `cloak`, then the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
if [ -d "$app/Contents/PlugIns/CloakWidgets.appex" ]; then
	sign --entitlements app/CloakWidgets.entitlements "$app/Contents/PlugIns/CloakWidgets.appex"
fi
sign "$app/Contents/MacOS/cloak"
# Embed the Developer ID provisioning profile in production builds when present
# so macOS authorizes the Data Protection Keychain with zero password prompts.
# Dev builds use a separate bundle ID (`sh.regents.cloak.dev`) and minimal
# virtualization-only entitlements so they stay completely isolated from production.
profile="${CLOAK_PROVISION_PROFILE:-app/RegentsCloak.provisionprofile}"
if [ -n "$dev" ]; then
	sign --entitlements app/RegentsCloak.dev.entitlements "$app"
elif [ -f "$profile" ]; then
	cp "$profile" "$app/Contents/embedded.provisionprofile"
	sign --entitlements app/RegentsCloak.profiled.entitlements "$app"
else
	sign --entitlements app/RegentsCloak.entitlements "$app"
fi
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
