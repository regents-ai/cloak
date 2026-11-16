# The companion's build environment: the pinned Rust image guest/build.sh
# builds the sender in, plus what the companion's build needs and that image
# lacks, from the same fixed snapshot of the Debian archive as the guest
# image: pkg-config and OpenSSL's headers for openssl-sys (the protocol's
# zkapi-client takes reqwest with its default native TLS), and git to apply
# the mainnet tree's two patches as its scripts/prepare-zkapi.sh does.
FROM rust:1.97.1-slim-trixie@sha256:8e8cf8f7fd54a2d23d5a743b3a03f56e26b6c774276c33fa0595111704ebb15c
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && echo 'deb http://snapshot.debian.org/archive/debian/20261028T000000Z trixie main' > /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev git \
 && rm -rf /var/lib/apt/lists/*
