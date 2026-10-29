# Stage 1 Linux reference host

A small Debian trixie arm64 image holding the reconstructed reference: Pi
1.3.0, the `zkapi-clientd` daemon built at the post's commit, Tor, torsocks,
bubblewrap and the wrapper in `reference/wrapper/`. It is for recording the
reference's behaviour only. The Mac app will not use Docker.

## Build and run

From the repository root:

```bash
uv run scripts/fetch_sources.py
( cd reference/src/zkapi/zkapi-clientd && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags="-X main.version=privacy-$(git rev-parse --short HEAD)-dev" \
    -o ../../bin/zkapi-clientd-concession-tor ./cmd/zkapi-clientd )
( cd reference/host/probe && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -o ../../src/bin/probe . )
docker build -t cloak-reference-host:stage1 -f reference/host/Dockerfile reference
docker run --rm --cpus 2 --memory 1g \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined cloak-reference-host:stage1
```

The three `--security-opt` flags let bubblewrap create its namespaces and mount
`/proc` inside Docker. They loosen the container, not the sandbox under test.

`check-routing.sh` starts Tor with the reference torrc and runs each probe in
the same sandbox Pi runs in. `probe/` is a statically linked program that
reports whether its own request reached the internet through Tor. It prints
true or false, never the address it came from.
