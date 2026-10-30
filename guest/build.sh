#!/bin/sh
# Builds the guest into guest/build/: the adapter, the daemon's rewrite check
# (compiled inside the pinned daemon module with an overlay, so the daemon's
# own files stay untouched), then the kernel and root from pinned Debian
# packages. Two cores, low priority.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
out=$repo/guest/build
module=$repo/reference/src/zkapi/zkapi-clientd
mkdir -p "$out"

export GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOMAXPROCS=2
(cd guest/adapter && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-adapter" .)
printf '{"Replace":{"%s/cmd/cloak-rewrite-check/main.go":"%s/guest/check/main.go"}}' "$module" "$repo" > "$out/overlay.json"
(cd "$module" && nice -n 10 go build -p 2 -trimpath -overlay "$out/overlay.json" -o "$out/cloak-rewrite-check" ./cmd/cloak-rewrite-check)

docker build --quiet --memory 1g -t cloak-guest-build guest/image > /dev/null
docker run --rm --cpus 2 --memory 1g -v "$out:/out" -v "$repo/guest/image:/src:ro" cloak-guest-build /src/build-initramfs.sh
