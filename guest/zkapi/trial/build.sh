#!/bin/sh
# Builds the trial's two images from the programs guest/zkapi/build.sh made
# and the protocol's mainnet proving keys. Runs nothing from the source trees.
set -eu
cd "$(dirname "$0")/../../.."
for name in cloak-zkapi-clientd cloak-zkapi-walletd; do
	test -x "guest/build/$name" || { echo "guest/build/$name is missing: run sh guest/zkapi/build.sh" >&2; exit 1; }
done
for target in tor zkapi; do
	docker build --quiet --target "$target" -t "cloak-zkapi-trial-$target" \
		--build-context bins=guest/build \
		--build-context setup=reference/src/zkapi-walletd-protocol/setup/v2 \
		guest/zkapi/trial
done
