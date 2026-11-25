#!/bin/sh
# Checks cloak-pay with stand-ins only (zz_cloak_pay_test.go says what they
# are; nothing here reaches the network). The mainnet tree is untrusted, as
# in guest/zkapi/build.sh, so none of its code runs on the Mac. On the Mac,
# gofmt, go vet and the guest build as guest/build.sh makes it only read and
# compile it: no cgo, no VCS stamping (which runs git in the tree), no
# toolchain download, and GOFLAGS set here, so no -toolexec. The daemon's own
# tests of the package whose client the patch changes, and Cloak's tests, ten
# more times under the race detector, run its code, so they run in the
# pinned Go image: no network, the repository and the Mac's module cache
# read-only, the build cache in a Docker volume of its own, two cores, 4 GB,
# low priority. Patched copies go in a folder removed at the end.
set -eu
cd "$(dirname "$0")/../.."
repo=$PWD
module=reference/src/zkapi-mainnet/zkapi-clientd
image=golang:1.27.4-trixie@sha256:b54b2639de8c1bfe538ec5ffc45f29b1932235ac5f6d63c059853646677112d9
export GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0
work=$(mktemp -d /tmp/cloak-pay-check.XXXXXX)
trap 'rm -rf "$work"' EXIT

patch -s -o "$work/pay-relay.go" "$module/internal/relay/relay.go" guest/pay/relay.patch
patch -s -o "$work/pay-socks5.go" "$module/internal/relay/socks5.go" guest/pay/socks5.patch
patch -s -o "$work/pay-client.go" "$module/internal/zkapi/client.go" guest/pay/client.patch
patch -s -o "$work/pay-return.go" "$module/internal/zkapi/address_return.go" guest/pay/return.patch

# overlay <repository> <patched copies>: guest/build.sh's overlay less the
# start (whose init would end a test binary), with the repository and the
# copies where they are seen from, plus the tests, and less the relay
# package's own tests, which test the routes the patch removes.
overlay() {
	m=$1/$module
	printf '{"Replace":{"%s/cmd/zkapi-clientd/zz_cloak_pay.go":"%s/guest/pay/zz_cloak_pay.go","%s/cmd/zkapi-clientd/zz_cloak_pay_test.go":"%s/guest/pay/zz_cloak_pay_test.go","%s/internal/relay/relay.go":"%s/pay-relay.go","%s/internal/relay/socks5.go":"%s/pay-socks5.go","%s/internal/zkapi/client.go":"%s/pay-client.go","%s/internal/zkapi/address_return.go":"%s/pay-return.go","%s/internal/zkapi/zz_cloak_chain.go":"%s/guest/pay/zz_cloak_chain.go","%s/internal/zkapi/zz_cloak_prices.go":"%s/guest/pay/zz_cloak_prices.go","%s/internal/relay/relay_test.go":"","%s/internal/relay/socks5_test.go":"","%s/internal/relay/connect_test.go":""' \
		"$m" "$1" "$m" "$1" "$m" "$2" "$m" "$2" "$m" "$2" "$m" "$2" "$m" "$1" "$m" "$1" "$m" "$m" "$m"
}
{ overlay /src /work; printf '}}'; } > "$work/test-overlay.json"
# For vet, everything at once, the start included.
{ overlay "$repo" "$work"; printf ',"%s/%s/cmd/zkapi-clientd/zz_cloak_pay_linux.go":"%s/guest/pay/zz_cloak_pay_linux.go"}}' "$repo" "$module" "$repo"; } > "$work/vet-overlay.json"
printf '{"Replace":{"%s/%s/cmd/zkapi-clientd/zz_cloak_pay.go":"%s/guest/pay/zz_cloak_pay.go","%s/%s/cmd/zkapi-clientd/zz_cloak_pay_linux.go":"%s/guest/pay/zz_cloak_pay_linux.go","%s/%s/internal/relay/relay.go":"%s/pay-relay.go","%s/%s/internal/relay/socks5.go":"%s/pay-socks5.go","%s/%s/internal/zkapi/client.go":"%s/pay-client.go","%s/%s/internal/zkapi/address_return.go":"%s/pay-return.go","%s/%s/internal/zkapi/zz_cloak_chain.go":"%s/guest/pay/zz_cloak_chain.go","%s/%s/internal/zkapi/zz_cloak_prices.go":"%s/guest/pay/zz_cloak_prices.go"}}' \
	"$repo" "$module" "$repo" "$repo" "$module" "$repo" "$repo" "$module" "$work" "$repo" "$module" "$work" "$repo" "$module" "$work" "$repo" "$module" "$work" "$repo" "$module" "$repo" "$repo" "$module" "$repo" > "$work/pay-overlay.json"

unformatted=$(gofmt -l guest/pay/*.go "$work"/pay-*.go)
if [ -n "$unformatted" ]; then
	echo "gofmt: $unformatted"
	exit 1
fi
(cd "$module" && GOOS=linux GOARCH=arm64 go vet -overlay "$work/vet-overlay.json" ./cmd/zkapi-clientd ./internal/relay ./internal/zkapi)
(cd "$module" && GOOS=linux GOARCH=arm64 GOMAXPROCS=2 nice -n 10 go build -p 2 -trimpath -buildvcs=false \
	-overlay "$work/pay-overlay.json" -o "$work/cloak-pay" ./cmd/zkapi-clientd)
file "$work/cloak-pay"

docker run --rm --pull never --network none --cpus 2 --memory 4g \
	-v "$repo:/src:ro" -v "$work:/work:ro" -v "$(go env GOMODCACHE):/gomod:ro" -v cloak-pay-check:/cache \
	-e GOMODCACHE=/gomod -e GOCACHE=/cache/build -e GOFLAGS=-mod=readonly -e GOPROXY=off -e GOTOOLCHAIN=local -e GOMAXPROCS=2 \
	-w "/src/$module" "$image" nice -n 10 sh -ec '
		CGO_ENABLED=0 go test -p 2 -overlay /work/test-overlay.json -count=1 ./internal/zkapi
		CGO_ENABLED=0 go test -p 2 -overlay /work/test-overlay.json -count=1 -v -run CloakPay ./cmd/zkapi-clientd
		CGO_ENABLED=1 go test -p 2 -overlay /work/test-overlay.json -count=10 -race -run CloakPay ./cmd/zkapi-clientd'
