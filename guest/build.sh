#!/bin/sh
# Builds the guest into guest/build/: the adapter, the agent check, the
# daemon's rewrite check and the guest daemon (both compiled inside the pinned
# daemon module with an overlay, so the daemon's own files stay untouched),
# then the kernel and root from pinned Debian packages, the pinned Pi package
# and Node.js runtime, and the reference wrapper. Every pinned source is
# checked against its pin first. Two cores, low priority.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
out=$repo/guest/build
module=$repo/reference/src/zkapi/zkapi-clientd
mkdir -p "$out"

PYTHONDONTWRITEBYTECODE=1 uv run scripts/fetch_sources.py --check

export GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOMAXPROCS=2
(cd guest/adapter && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-adapter" .)
(cd guest/agent && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-agent-check" .)
printf '{"Replace":{"%s/cmd/cloak-rewrite-check/main.go":"%s/guest/check/main.go"}}' "$module" "$repo" > "$out/overlay.json"
(cd "$module" && nice -n 10 go build -p 2 -trimpath -overlay "$out/overlay.json" -o "$out/cloak-rewrite-check" ./cmd/cloak-rewrite-check)
# The daemon's build flags (docs/DEVELOPMENT.md at the pinned commit).
printf '{"Replace":{"%s/cmd/zkapi-clientd/zz_cloak_guest.go":"%s/guest/daemon/zz_cloak_guest.go"}}' "$module" "$repo" > "$out/daemon-overlay.json"
(cd "$module" && nice -n 10 go build -p 2 -trimpath -overlay "$out/daemon-overlay.json" \
	-ldflags="-X main.version=privacy-$(git rev-parse --short HEAD)-dev" -o "$out/cloak-daemon" ./cmd/zkapi-clientd)

docker build --quiet --memory 1g -t cloak-guest-build guest/image > /dev/null
docker run --rm --cpus 2 --memory 1g -v "$out:/out" -v "$repo/guest/image:/src:ro" \
	-v "$repo/reference/src/pi:/pi:ro" -v "$repo/reference/src/node:/node:ro" -v "$repo/reference/wrapper:/wrapper:ro" \
	cloak-guest-build /src/build-initramfs.sh
