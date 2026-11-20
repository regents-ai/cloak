#!/bin/sh
# Makes a release of Regents Cloak on this Mac; the chief alone runs it.
# Builds the app signed with the Developer ID (app/build.sh), has Apple
# notarize it and staples the ticket to it, packs it in a disk image that
# is signed, notarized and stapled the same way, and checks that
# Gatekeeper accepts both. Then writes the update feed with Sparkle's
# generate_appcast, which signs the image with the update key (in the
# login keychain under the account `cloak`; the Mac asks to allow it),
# embeds app/release-notes.md, and keeps the public feed's earlier
# releases. Leaves the image, appcast.xml and the tag in app/build/release/
# and uploads nothing: app/publish.sh does that.
#
# Needs a clean tree, the Developer ID in the keychain, the notary profile
# `cloak-notary` (saved once with `xcrun notarytool store-credentials`),
# and what app/build.sh needs.
set -eu
cd "$(dirname "$0")/.."

identity="Developer ID Application: Sean Brennan (367G3Z7G3J)"
downloads=https://github.com/regents-ai/cloak-releases/releases/download

if git status --porcelain | grep -qvx '?? app/.DS_Store'; then
	echo "A release is built from a clean tree. Commit or remove these first:" >&2
	git status --short >&2
	exit 1
fi

app/build.sh "$identity"
app="app/build/Regents Cloak.app"
release=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
tag="$release-$build"
generate_appcast=$(find app/.build/artifacts -type f -name generate_appcast -perm +111)
if [ ! -x "$generate_appcast" ]; then
	echo "Sparkle's generate_appcast should be under app/.build/artifacts exactly once." >&2
	exit 1
fi

out=app/build/release
work=app/build/notarize
rm -rf "$out" "$work"
mkdir -p "$out" "$work/image"

# Sends a file to Apple's notary service and waits for its answer. Stops
# unless that is Accepted, printing Apple's log of why. The answer is read
# from notarytool's report, whatever its exit status.
notarize() {
	xcrun notarytool submit "$1" --keychain-profile cloak-notary --wait --output-format plist > "$work/notary.plist" || true
	id=$(plutil -extract id raw "$work/notary.plist")
	status=$(plutil -extract status raw "$work/notary.plist")
	if [ "$status" != Accepted ]; then
		xcrun notarytool log "$id" --keychain-profile cloak-notary >&2
		echo "Apple's notary service answered $status for $1." >&2
		exit 1
	fi
}

ditto -c -k --keepParent "$app" "$work/Regents Cloak.zip"
notarize "$work/Regents Cloak.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

ditto "$app" "$work/image/Regents Cloak.app"
ln -s /Applications "$work/image/Applications"
dmg="$out/Regents-Cloak-$tag.dmg"
diskutil image create from --volumeName "Regents Cloak" --format UDZO "$work/image" "$dmg"
codesign -s "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
spctl --assess --type execute -v "$app"

# generate_appcast adds to the appcast.xml in the folder it is given, so
# the public feed goes there first. None yet (404) means this is the first
# release. --maximum-versions 0 keeps every earlier release in it.
feed=$(plutil -extract update_feed raw app/release.json)
code=$(curl --silent --show-error --location --output "$out/appcast.xml" --write-out '%{http_code}' "$feed")
case $code in
200) ;;
404) rm "$out/appcast.xml" ;;
*)
	echo "$feed answered $code." >&2
	exit 1
	;;
esac
# Release notes are read from a file named as the image; .txt is plain text.
cp app/release-notes.md "$out/Regents-Cloak-$tag.txt"
"$generate_appcast" --account cloak --embed-release-notes --maximum-versions 0 \
	--download-url-prefix "$downloads/$tag/" "$out"
rm "$out/Regents-Cloak-$tag.txt"
if ! grep -qF "$downloads/$tag/Regents-Cloak-$tag.dmg" "$out/appcast.xml"; then
	echo "generate_appcast left no entry for $tag in $out/appcast.xml." >&2
	exit 1
fi
printf '%s\n' "$tag" > "$out/tag"
rm -rf "$work"

echo "$dmg"
echo "$out/appcast.xml"
echo "$out/tag"
