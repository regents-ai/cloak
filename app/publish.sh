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

# Append release checksums and built-in macOS verification commands to the GitHub Release body.
dmg_sha256=$(plutil -extract dmg_sha256 raw "$out/checksums.json")
app_bin_sha256=$(plutil -extract app_binary_sha256 raw "$out/checksums.json")
cdhash=$(plutil -extract cdhash raw "$out/checksums.json")
team_id=$(plutil -extract team_id raw "$out/checksums.json")
notes_out="$out/release-notes-with-checksums.md"
{
	cat app/release-notes.md
	cat <<EOF

---

## Checksums & Verification

Compare these checksums against \`regents.sh/cloak/install\` and Cloak's **Settings → Status** pane:

- **DMG (\`Regents-Cloak-$tag.dmg\` / \`Regents-Cloak.dmg\`) SHA-256:**
  \`$dmg_sha256\`
- **Installed App Binary (\`Cloak.app/Contents/MacOS/RegentsCloak\`) SHA-256:**
  \`$app_bin_sha256\`
- **Apple Code Signature \`CDHash\`:** \`$cdhash\` (Team \`$team_id\`)

Verify independently using macOS built-in tools in Terminal:

\`\`\`sh
# 1. Verify downloaded DMG before opening
shasum -a 256 ~/Downloads/Regents-Cloak-$tag.dmg

# 2. Verify installed app binary after dragging to Applications
shasum -a 256 "/Applications/Cloak.app/Contents/MacOS/RegentsCloak"

# 3. Verify Apple Developer ID signature & CDHash (Team $team_id)
codesign -dvv --strict "/Applications/Cloak.app"

# 4. Verify Apple Notarization & Gatekeeper
spctl --assess --type execute -vv "/Applications/Cloak.app"
\`\`\`
EOF
} > "$notes_out"

gh release create "$tag" \
	"$out/Regents-Cloak-$tag.dmg" \
	"$out/Regents-Cloak.dmg" \
	"$out/SHA256SUMS.txt" \
	"$out/checksums.json" \
	--repo "$repo" \
	--title "Regents Cloak $release Beta ($build)" --notes-file "$notes_out"

# Update appcast.xml, SHA256SUMS.txt, and checksums.json on main branch.
upload_main_file() {
	local_path="$1"
	remote_name="$2"
	sha=$(gh api "repos/$repo/contents?ref=main" --jq ".[] | select(.name == \"$remote_name\") | .sha")
	gh api -X PUT "repos/$repo/contents/$remote_name" --silent \
		-f message="Regents Cloak $release ($build)" \
		-f branch=main \
		-f content="$(base64 -i "$local_path")" \
		${sha:+-f "sha=$sha"}
}
upload_main_file "$out/appcast.xml" "appcast.xml"
upload_main_file "$out/SHA256SUMS.txt" "SHA256SUMS.txt"
upload_main_file "$out/checksums.json" "checksums.json"

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
