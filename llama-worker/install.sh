#!/bin/sh
# Builds llama.cpp (build-llama.sh), then the llama worker and its check tool
# prompt-tokens-llama (two build jobs, low priority), signs the worker into the
# App Sandbox with the MLX worker's entitlements,
# worker/cloak-rewriter.entitlements, and installs it beside that worker in
# ~/Library/Application Support/Regents Cloak/worker/. The Metal shaders are
# built into the binary, so it is the one file installed; the check tool stays
# in the build folder.
set -eu
cd "$(dirname "$0")"
./build-llama.sh
nice -n 10 xcodebuild build -scheme cloak-rewriter-llama-Package -destination 'platform=macOS,arch=arm64' \
	-configuration Release -derivedDataPath .xcode -jobs 2 -quiet
built=.xcode/Build/Products/Release
codesign -s - --entitlements ../worker/cloak-rewriter.entitlements -f "$built/cloak-rewriter-llama"
target="$HOME/Library/Application Support/Regents Cloak/worker"
mkdir -p "$target"
ditto "$built/cloak-rewriter-llama" "$target/cloak-rewriter-llama"
echo "$target/cloak-rewriter-llama"
