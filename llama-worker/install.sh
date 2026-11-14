#!/bin/sh
# Builds llama.cpp (build-llama.sh), then the worker (two build jobs, low
# priority), signs it into the App Sandbox with cloak-rewriter.entitlements,
# and installs it in ~/Library/Application Support/Regents Cloak/worker/. The
# sandbox cannot start a program kept under ~/Documents, so the worker runs
# from there. The Metal shaders are built into the binary, so it is the one
# file installed.
set -eu
cd "$(dirname "$0")"
./build-llama.sh
nice -n 10 xcodebuild build -scheme cloak-rewriter-llama -destination 'platform=macOS,arch=arm64' \
	-configuration Release -derivedDataPath .xcode -jobs 2 -quiet
built=.xcode/Build/Products/Release
codesign -s - --entitlements cloak-rewriter.entitlements -f "$built/cloak-rewriter-llama"
target="$HOME/Library/Application Support/Regents Cloak/worker"
mkdir -p "$target"
ditto "$built/cloak-rewriter-llama" "$target/cloak-rewriter-llama"
echo "$target/cloak-rewriter-llama"
