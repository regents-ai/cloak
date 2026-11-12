#!/bin/sh
# Builds the host supervisor into host/.build/release/cloak-host, signed with
# the virtualization entitlement, and puts the pinned tor in host/.build/tor/:
# only tor and the libevent it loads, from the Tor Project's expert bundle,
# after every pinned source is checked against its pin. tor is signed again,
# ad hoc, because macOS kills the bundle's own copy at launch for an invalid
# signature. Two build jobs.
set -eu
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 uv run scripts/fetch_sources.py --check

(cd host && swift build -c release -j 2 && codesign -s - --entitlements cloak-host.entitlements -f .build/release/cloak-host)

mkdir -p host/.build/tor
tar -xzf reference/src/tor/tor-expert-bundle-macos-aarch64-16.0.1.tar.gz -C host/.build/tor \
	--strip-components 1 tor/tor tor/libevent-2.1.7.dylib
codesign -s - -f host/.build/tor/tor
host/.build/tor/tor --version
