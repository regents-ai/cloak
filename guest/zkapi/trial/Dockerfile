# The two images of the zkAPI trial, from the guest image's pinned Debian base
# and archive snapshot. `tor` is the only way out. `zkapi` holds the mainnet
# daemon and its companion as guest/zkapi/build.sh built them, the four
# proving keys where the daemon looks for them (share/zkapi-clientd/proof-setup
# beside its bin/), the companion's libraries and CA certificates, socat to
# forward the daemon's loopback SOCKS address to tor, curl for the checks, and
# procps to see and stop the daemon. Build contexts: `bins` is guest/build and
# `setup` the protocol's setup/v2 (see build.sh).
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS base
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && echo 'deb http://snapshot.debian.org/archive/debian/20261028T000000Z trixie main' > /etc/apt/sources.list

FROM base AS tor
RUN apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends tor \
 && rm -rf /var/lib/apt/lists/*
COPY torrc /etc/tor/trial-torrc
USER debian-tor
CMD ["tor", "-f", "/etc/tor/trial-torrc"]

FROM base AS zkapi
RUN apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3t64 zlib1g libzstd1 libgcc-s1 socat curl procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=bins cloak-zkapi-clientd /opt/zkapi/bin/zkapi-clientd
COPY --from=bins cloak-zkapi-walletd /opt/zkapi/bin/zkapi-walletd
COPY --from=setup request.pk request.vk withdrawal.pk withdrawal.vk /opt/zkapi/share/zkapi-clientd/proof-setup/
COPY proofs.sh address.sh /opt/zkapi/trial/
ENV PATH=/opt/zkapi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD ["socat", "TCP-LISTEN:9050,bind=127.0.0.1,fork,reuseaddr", "TCP:172.31.250.2:9050"]
