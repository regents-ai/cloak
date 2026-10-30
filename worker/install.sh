#!/bin/sh
# Builds the worker (two build jobs, low priority), signs it into the App
# Sandbox with cloak-rewriter.entitlements, and installs it with MLX's shader
# bundle in ~/Library/Application Support/Regents Cloak/worker/. The sandbox
# cannot start a program kept under ~/Documents, so the worker runs from there.
set -eu
cd "$(dirname "$0")"
nice -n 10 xcodebuild build -scheme cloak-rewriter -destination 'platform=macOS,arch=arm64' \
	-configuration Release -derivedDataPath .xcode -jobs 2 -quiet
built=.xcode/Build/Products/Release
codesign -s - --entitlements cloak-rewriter.entitlements -f "$built/cloak-rewriter"
target="$HOME/Library/Application Support/Regents Cloak/worker"
mkdir -p "$target"
ditto "$built/cloak-rewriter" "$target/cloak-rewriter"
ditto "$built/mlx-swift_Cmlx.bundle" "$target/mlx-swift_Cmlx.bundle"
echo "$target/cloak-rewriter"
