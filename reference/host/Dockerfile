# Stage 1 Linux reference host: the reconstructed reference stack on Debian
# trixie arm64, for recording its behaviour before any Mac packaging.
# Build context is reference/ after `uv run scripts/fetch_sources.py` and the
# binary builds described in reference/host/README.md.
FROM node:24-trixie-slim@sha256:54f84b4cf8432b21aaffd5d3ce8d41e12cea0d10d33c09d2f3c9879d49d6b446

RUN apt-get update \
  && apt-get install -y --no-install-recommends tor torsocks bubblewrap curl python3 ca-certificates procps \
  && rm -rf /var/lib/apt/lists/*

COPY src/pi/earendil-works-pi-coding-agent-1.3.0.tgz /tmp/pi.tgz
RUN npm install -g --ignore-scripts /tmp/pi.tgz && rm /tmp/pi.tgz

COPY src/bin/zkapi-clientd-concession-tor src/bin/probe /usr/local/bin/
COPY wrapper /opt/cloak/wrapper
COPY host/check-routing.sh /opt/cloak/check-routing.sh

RUN useradd --create-home agent
USER agent
WORKDIR /home/agent
ENV PATH=/opt/cloak/wrapper:$PATH
CMD ["/opt/cloak/check-routing.sh"]
