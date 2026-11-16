#!/bin/sh
# Builds Open Anonymity's mainnet zkAPI client programs for linux/arm64 into
# guest/build/: the daemon from reference/src/zkapi-mainnet as
# cloak-zkapi-clientd, its Rust wallet and prover companion zkapi-walletd as
# cloak-zkapi-walletd, and the protocol's own proof benchmark as
# cloak-zkapi-proof-bench, the instrument that measures one proof. The
# companion is the pinned zkapi-walletd source with its pinned protocol
# submodule, patched with the mainnet tree's companion.patch and
# protocol-transport.patch as the tree's scripts/prepare-zkapi.sh patches
# them. The trees are untrusted: each build runs in a Docker container that
# sees them read-only and nothing else of the Mac but guest/build/. Every
# pinned source is checked against its pin first. Two cores, low priority.
# Nothing here goes into the guest image yet.
set -eu
cd "$(dirname "$0")/../.."
repo=$PWD
out=$repo/guest/build
tree=$repo/reference/src/zkapi-mainnet
mkdir -p "$out"

PYTHONDONTWRITEBYTECODE=1 uv run scripts/fetch_sources.py --check

# The daemon, with the flags of the tree's zkapi-clientd/scripts/build-native.sh
# and no cgo; its modules and build cache in a Docker volume of its own.
docker run --rm --cpus 2 --memory 4g -v "$tree:/src:ro" -v cloak-zkapi-clientd-build:/cache -v "$out:/out" \
	-e GOOS=linux -e GOARCH=arm64 -e CGO_ENABLED=0 -e GOMAXPROCS=2 -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build \
	-w /src/zkapi-clientd \
	golang:1.27.4-trixie@sha256:b54b2639de8c1bfe538ec5ffc45f29b1932235ac5f6d63c059853646677112d9 \
	nice -n 10 go build -p 2 -trimpath -buildvcs=false -ldflags='-s -w -X main.version=cda02d83' -o /out/cloak-zkapi-clientd ./cmd/zkapi-clientd

# The companion and the benchmark: Rust, built --locked in guest/zkapi/Dockerfile
# from a fresh patched copy, with crates, copy and build in a Docker volume of
# their own between builds.
docker build --quiet --memory 1g -t cloak-zkapi-walletd-build guest/zkapi > /dev/null
docker run --rm --cpus 2 --memory 4g -v "$repo/reference/src/zkapi-walletd:/walletd:ro" \
	-v "$repo/reference/src/zkapi-walletd-protocol:/protocol:ro" -v "$tree/zkapi-clientd/internal/zkapi:/patches:ro" \
	-v cloak-zkapi-walletd-build:/cache -v "$out:/out" -e CARGO_HOME=/cache/cargo -e CARGO_TARGET_DIR=/cache/target \
	cloak-zkapi-walletd-build sh -euc '
		rm -rf /cache/src
		mkdir -p /cache/src/protocol
		git -c safe.directory="*" -C /walletd archive HEAD | tar -x -C /cache/src
		git -c safe.directory="*" -C /protocol archive HEAD | tar -x -C /cache/src/protocol
		cd /cache/src && git apply --check /patches/companion.patch && git apply /patches/companion.patch
		cd /cache/src/protocol && git apply --check /patches/protocol-transport.patch && git apply /patches/protocol-transport.patch
		nice -n 10 cargo build --quiet --release --locked -j 2 --manifest-path /cache/src/Cargo.toml --bin zkapi
		nice -n 10 cargo build --quiet --release --locked -j 2 --manifest-path /cache/src/protocol/rust/Cargo.toml -p zkapi-proof --example proof_bench
		cp /cache/target/release/zkapi /out/cloak-zkapi-walletd
		cp /cache/target/release/examples/proof_bench /out/cloak-zkapi-proof-bench'
