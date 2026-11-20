#!/bin/sh
# Makes a release of Regents Cloak on this Mac; the chief alone runs it.
# Builds the app (app/build.sh, signed with the Developer ID), has Apple
# notarize it and staples the ticket to it, packs it in a disk image that
# is signed, notarized and stapled the same way, and checks that
# Gatekeeper accepts both. The image opens as a window with the app, an
# arrow and Applications (app/install-window.py lays it out over
# app/install-window.tiff, drawn by app/art.sh). Then writes the update feed with Sparkle's
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

identity=$(plutil -extract identity raw app/release.json)
downloads=https://github.com/regents-ai/cloak-releases/releases/download

if git status --porcelain | grep -qvx '?? app/.DS_Store'; then
	echo "A release is built from a clean tree. Commit or remove these first:" >&2
	git status --short >&2
	exit 1
fi

app/build.sh
app="app/build/Cloak.app"
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
mkdir -p "$out" "$work/volume"

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

ditto -c -k --keepParent "$app" "$work/Cloak.zip"
notarize "$work/Cloak.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# A writable image first, mounted where Finder does not show it: the
# window's layout names its picture by an alias that is only right when
# made on the volume itself. Then the compressed, read-only image from it.
diskutil image create blank --size "$(($(du -sm "$app" | cut -f1) + 60))m" --volumeName Cloak --fs APFS "$work/image.dmg"
diskutil image attach --nobrowse --mountPoint "$work/volume" "$work/image.dmg"
trap 'diskutil eject "$work/volume"' EXIT
ditto "$app" "$work/volume/Cloak.app"
ln -s /Applications "$work/volume/Applications"
mkdir "$work/volume/.background"
cp app/install-window.tiff "$work/volume/.background/"
PYTHONDONTWRITEBYTECODE=1 uv run app/install-window.py "$work/volume"
trap - EXIT
diskutil eject "$work/volume"
dmg="$out/Regents-Cloak-$tag.dmg"
diskutil image create from --format UDZO "$work/image.dmg" "$dmg"
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
