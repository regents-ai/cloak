# The guest's kernel and root come from pinned Debian packages: the base image
# by digest, packages from a fixed snapshot of the Debian archive. bash,
# bubblewrap, torsocks and the CA certificates are the reference wrapper's
# (reference/wrapper/sandbox).
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && echo 'deb http://snapshot.debian.org/archive/debian/20261028T000000Z trixie main' > /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends linux-image-arm64 busybox-static cpio xz-utils bubblewrap torsocks ca-certificates \
 && rm -rf /var/lib/apt/lists/*
