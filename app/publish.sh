#!/bin/sh
# Publishes what app/release.sh left in app/build/release/; the chief alone
# runs it. Creates the GitHub release <tag> in regents-ai/cloak-releases
# with the disk image and app/release-notes.md, then puts appcast.xml on
# that repository's main branch through the GitHub API, with no local
# clone: the release first, so the feed never names a missing file. Then
# waits until the public feed names the new release. The image is in the
# release twice: under its own name, which the feed gives, and as
# Regents-Cloak.dmg, so that one address always downloads the newest
# (releases/latest/download/Regents-Cloak.dmg, the page's Download button).
#
# Needs `gh` signed in with the right to write to regents-ai/cloak-releases,
# which must already hold a commit for the release's tag to point at.
set -eu
cd "$(dirname "$0")/.."

repo=regents-ai/cloak-releases
out=app/build/release
tag=$(cat "$out/tag")
# The tag is <release>-<build>, and the build is a number with no hyphen.
release=${tag%-*}
build=${tag##*-}

ln -f "$out/Regents-Cloak-$tag.dmg" "$out/Regents-Cloak.dmg"
gh release create "$tag" "$out/Regents-Cloak-$tag.dmg" "$out/Regents-Cloak.dmg" --repo "$repo" \
	--title "Regents Cloak $release ($build)" --notes-file app/release-notes.md

# Replacing the file needs its current sha; creating it needs none.
sha=$(gh api "repos/$repo/contents?ref=main" --jq '.[] | select(.name == "appcast.xml") | .sha')
gh api -X PUT "repos/$repo/contents/appcast.xml" --silent \
	-f message="Regents Cloak $release ($build)" \
	-f branch=main \
	-f content="$(base64 -i "$out/appcast.xml")" \
	${sha:+-f "sha=$sha"}

# raw.githubusercontent.com may serve its earlier copy for up to five
# minutes.
feed=$(plutil -extract update_feed raw app/release.json)
tries=0
until curl --silent --fail "$feed" | grep -qF "/releases/download/$tag/"; do
	tries=$((tries + 1))
	if [ "$tries" -ge 20 ]; then
		echo "$feed still does not name $tag after ten minutes." >&2
		exit 1
	fi
	sleep 30
done
echo "Published $tag; $feed names it."
