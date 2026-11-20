#!/bin/sh
# Builds llama.cpp (build-llama.sh), then the worker (two build jobs, low
# priority), signs it into the App Sandbox with cloak-rewriter.entitlements
# and the Developer ID that app/release.json names, under the hardened
# runtime and with a secure timestamp, as every build on this Mac is signed
# (decision 8a, 20 November 2026): macOS keeps the worker's sandbox folder
# for the one team that signs it. Then installs it in ~/Library/Application Support/Regents Cloak/worker/ for
# the scripts and checks under scripts/ and tests/. The sandbox cannot start
# a program kept under ~/Documents, so they run it from there. The Metal
# shaders are built into the binary, so it is the one file installed.
# app/build.sh takes the signed build from .xcode into the app, which copies
# its own worker to the same place at each Start when the file there is not
# the one it pins.
set -eu
cd "$(dirname "$0")"
./build-llama.sh
nice -n 10 xcodebuild build -scheme cloak-rewriter-llama -destination 'platform=macOS,arch=arm64' \
	-configuration Release -derivedDataPath .xcode -jobs 2 -quiet
built=.xcode/Build/Products/Release
codesign -s "$(plutil -extract identity raw ../app/release.json)" -o runtime --timestamp \
	--entitlements cloak-rewriter.entitlements -f "$built/cloak-rewriter-llama"
target="$HOME/Library/Application Support/Regents Cloak/worker"
mkdir -p "$target"
ditto "$built/cloak-rewriter-llama" "$target/cloak-rewriter-llama"
echo "$target/cloak-rewriter-llama"
