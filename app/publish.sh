#!/bin/sh
# Publishes what app/release.sh left in app/build/release/ directly to
# regents-ai/cloak Releases, tagging the exact source commit (`HEAD`) that
# produced the build. Attaches the signed/notarized disk images (versioned and
# unversioned Regents-Cloak.dmg for /releases/latest/download/), the Sparkle
# appcast.xml, SHA256SUMS.txt, and checksums.json atomically to the release
# with no auto-commits to main.
#
# Needs `gh` signed in with write access to regents-ai/cloak and HEAD already
# pushed to origin/main.
set -eu
cd "$(dirname "$0")/.."

repo=regents-ai/cloak
out=app/build/release
tag=$(cat "$out/tag")
commit=$(git rev-parse HEAD)
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
	"$out/appcast.xml" \
	"$out/SHA256SUMS.txt" \
	"$out/checksums.json" \
	--repo "$repo" \
	--target "$commit" \
	--title "Regents Cloak $release Beta ($build)" --notes-file "$notes_out"

feed=$(plutil -extract update_feed raw app/release.json)
tries=0
until curl --silent --fail --location "$feed" | grep -qF "/releases/download/$tag/"; do
	tries=$((tries + 1))
	if [ "$tries" -ge 20 ]; then
		echo "$feed still does not name $tag after ten minutes." >&2
		exit 1
	fi
	sleep 10
done
echo "Published $tag on $repo (commit ${commit}); $feed names it."
