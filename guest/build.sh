#!/bin/sh
# Builds the guest into guest/build/: the adapter, the port program (the Tor
# port and the door port), the agent check, the agent's task runner, the two
# routing instruments (the stage 1 reference's static probe and a vsock
# probe), the daemon's rewrite check and the guest daemon (both
# compiled inside the pinned daemon module with an overlay, so the daemon's
# own files stay untouched, and both with Cloak's input limit and deadline,
# decision 6 in docs/plan.md, patched into copies of two of its files), the
# payer cloak-pay (compiled the same way inside the pinned mainnet daemon
# module), then the sender, then the payer's companion, then the kernel and
# root from pinned Debian packages, the pinned Pi package and Node.js runtime,
# the reference wrapper, the companion's proving keys and Cloak's cover list
# (reference/cover.json, the daemon's /etc/cloak/cover.json). Every pinned
# source is checked against its pin first. Two cores, low priority.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
out=$repo/guest/build
module=$repo/reference/src/zkapi/zkapi-clientd
mkdir -p "$out"

PYTHONDONTWRITEBYTECODE=1 uv run scripts/fetch_sources.py --check

export GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOMAXPROCS=2
(cd guest/adapter && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-adapter" .)
(cd guest/torport && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-port" .)
(cd guest/agent && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-agent-check" .)
(cd guest/runner && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-runner" .)
(cd guest/vsockprobe && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-vsock-probe" .)
(cd reference/host/probe && nice -n 10 go build -p 2 -trimpath -o "$out/cloak-routing-probe" .)
patch -s -o "$out/rewriter.go" "$module/internal/rewriter/rewriter.go" guest/daemon/rewriter.patch
patch -s -o "$out/server.go" "$module/internal/server/server.go" guest/daemon/server.patch
rewriter="\"$module/internal/rewriter/rewriter.go\":\"$out/rewriter.go\""
printf '{"Replace":{"%s/cmd/cloak-rewrite-check/main.go":"%s/guest/check/main.go",%s}}' "$module" "$repo" "$rewriter" > "$out/overlay.json"
(cd "$module" && nice -n 10 go build -p 2 -trimpath -overlay "$out/overlay.json" -o "$out/cloak-rewrite-check" ./cmd/cloak-rewrite-check)
# The daemon's build flags (docs/DEVELOPMENT.md at the pinned commit).
printf '{"Replace":{"%s/cmd/zkapi-clientd/zz_cloak_guest.go":"%s/guest/daemon/zz_cloak_guest.go",%s,"%s/internal/server/server.go":"%s/server.go"}}' \
	"$module" "$repo" "$rewriter" "$module" "$out" > "$out/daemon-overlay.json"
(cd "$module" && nice -n 10 go build -p 2 -trimpath -overlay "$out/daemon-overlay.json" \
	-ldflags="-X main.version=privacy-$(git rev-parse --short HEAD)-dev" -o "$out/cloak-daemon" ./cmd/zkapi-clientd)
# cloak-pay: the mainnet daemon with guest/pay's four files added by
# overlay, two to its command and the chain read and the price read to its
# zkapi package, and
# Tor as its only route patched into copies of three of its files
# (guest/pay/check.sh checks it). The guest starts it when the payment disk
# is open. The mainnet tree is untrusted (guest/zkapi/build.sh): this only
# compiles it, with cgo off (above) and without VCS stamping, which would run
# git in the tree.
mainnet=$repo/reference/src/zkapi-mainnet/zkapi-clientd
patch -s -o "$out/pay-relay.go" "$mainnet/internal/relay/relay.go" guest/pay/relay.patch
patch -s -o "$out/pay-socks5.go" "$mainnet/internal/relay/socks5.go" guest/pay/socks5.patch
patch -s -o "$out/pay-client.go" "$mainnet/internal/zkapi/client.go" guest/pay/client.patch
patch -s -o "$out/pay-return.go" "$mainnet/internal/zkapi/address_return.go" guest/pay/return.patch
printf '{"Replace":{"%s/cmd/zkapi-clientd/zz_cloak_pay.go":"%s/guest/pay/zz_cloak_pay.go","%s/cmd/zkapi-clientd/zz_cloak_pay_linux.go":"%s/guest/pay/zz_cloak_pay_linux.go","%s/internal/relay/relay.go":"%s/pay-relay.go","%s/internal/relay/socks5.go":"%s/pay-socks5.go","%s/internal/zkapi/client.go":"%s/pay-client.go","%s/internal/zkapi/address_return.go":"%s/pay-return.go","%s/internal/zkapi/zz_cloak_chain.go":"%s/guest/pay/zz_cloak_chain.go","%s/internal/zkapi/zz_cloak_prices.go":"%s/guest/pay/zz_cloak_prices.go"}}' \
	"$mainnet" "$repo" "$mainnet" "$repo" "$mainnet" "$out" "$mainnet" "$out" "$mainnet" "$out" "$mainnet" "$out" "$mainnet" "$repo" "$mainnet" "$repo" > "$out/pay-overlay.json"
(cd "$mainnet" && nice -n 10 go build -p 2 -trimpath -buildvcs=false -overlay "$out/pay-overlay.json" -o "$out/cloak-pay" ./cmd/zkapi-clientd)

# The sender (Development mode, decision 10 in docs/plan.md): Rust, built
# --locked in the pinned Rust image, whose toolchain is the one
# guest/sender/rust-toolchain.toml names, with its crates and build in a Docker
# volume of its own between builds.
docker run --rm --cpus 2 --memory 4g -v "$repo/guest/sender:/src:ro" -v cloak-sender-build:/cache -v "$out:/out" \
	-e CARGO_HOME=/cache/cargo -e CARGO_TARGET_DIR=/cache/target \
	rust:1.97.1-slim-trixie@sha256:8e8cf8f7fd54a2d23d5a743b3a03f56e26b6c774276c33fa0595111704ebb15c \
	sh -c 'nice -n 10 cargo build --quiet --release --locked -j 2 --manifest-path /src/Cargo.toml && cp /cache/target/release/cloak-sender /out/'

# The payer's companion, zkapi-walletd, as cloak-pay-walletd: the pinned
# zkapi-walletd source with its pinned protocol submodule, patched with the
# mainnet tree's companion.patch and protocol-transport.patch as the tree's
# scripts/prepare-zkapi.sh patches them, then with
# guest/pay/companion-start.patch. That one takes out the only network call
# the companion makes before it listens, a fetch of the protocol server's
# /health to see that it offers direct OpenRouter requests: the guest has no
# network at boot, and a request in that mode fails at the server anyway if
# the server stops offering it. Rust, in guest/zkapi/Dockerfile's image, with
# crates, copy and build in the trial's Docker volume between builds. The
# trees are untrusted: they are seen read-only, the crates are fetched
# first, which runs none of their code, and the build, which runs the tree's
# own build script, has no network.
docker build --quiet --memory 1g -t cloak-zkapi-walletd-build guest/zkapi > /dev/null
docker run --rm --cpus 2 --memory 4g -v "$repo/reference/src/zkapi-walletd:/walletd:ro" \
	-v "$repo/reference/src/zkapi-walletd-protocol:/protocol:ro" -v "$mainnet/internal/zkapi:/patches:ro" \
	-v "$repo/guest/pay:/pay:ro" -v cloak-zkapi-walletd-build:/cache -e CARGO_HOME=/cache/cargo \
	cloak-zkapi-walletd-build sh -euc '
		rm -rf /cache/src
		mkdir -p /cache/src/protocol
		git -c safe.directory="*" -C /walletd archive HEAD | tar -x -C /cache/src
		git -c safe.directory="*" -C /protocol archive HEAD | tar -x -C /cache/src/protocol
		cd /cache/src && git apply /patches/companion.patch && git apply /pay/companion-start.patch
		cd /cache/src/protocol && git apply /patches/protocol-transport.patch
		cargo fetch --quiet --locked --manifest-path /cache/src/Cargo.toml'
docker run --rm --network none --cpus 2 --memory 4g -v cloak-zkapi-walletd-build:/cache -v "$out:/out" \
	-e CARGO_HOME=/cache/cargo -e CARGO_TARGET_DIR=/cache/target cloak-zkapi-walletd-build sh -euc '
		nice -n 10 cargo build --quiet --release --locked --offline -j 2 --manifest-path /cache/src/Cargo.toml --bin zkapi
		cp /cache/target/release/zkapi /out/cloak-pay-walletd'

cp reference/cover.json "$out/cover.json"
docker build --quiet --memory 1g -t cloak-guest-build guest/image > /dev/null
docker run --rm --cpus 2 --memory 1g -v "$out:/out" -v "$repo/guest/image:/src:ro" \
	-v "$repo/reference/src/pi:/pi:ro" -v "$repo/reference/src/node:/node:ro" -v "$repo/reference/wrapper:/wrapper:ro" \
	-v "$repo/reference/src/zkapi-walletd-protocol/setup/v2:/proof-setup:ro" \
	cloak-guest-build /src/build-initramfs.sh
