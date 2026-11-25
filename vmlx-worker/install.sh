#!/bin/sh
# Builds the pure-Swift vMLX Local Chat worker (cloak-worker-vmlx) in Release
# mode, signs it into the App Sandbox with cloak-vmlx.entitlements and the
# Developer ID named in app/release.json, and installs the binary plus its
# sibling mlx-swift_Cmlx.bundle (default.metallib) into
# ~/Library/Application Support/Regents Cloak/worker/.
set -eu
cd "$(dirname "$0")"

nice -n 10 swift build -c release -j 2
built=.build/release
identity=$(plutil -extract identity raw ../app/release.json)
codesign -s "$identity" -o runtime --timestamp \
	--entitlements cloak-vmlx.entitlements -f "$built/cloak-worker-vmlx"

target="$HOME/Library/Application Support/Regents Cloak/worker"
mkdir -p "$target"
ditto "$built/cloak-worker-vmlx" "$target/cloak-worker-vmlx"
ditto "$built/mlx-swift_Cmlx.bundle" "$target/mlx-swift_Cmlx.bundle"
echo "$target/cloak-worker-vmlx"
