#!/bin/sh
# Once: the closed network, the daemon's folder on the Mac (owner-only) and
# the two containers, created and not started. The network is --internal, so
# nothing on it has a route out. tor sits on it at 172.31.250.2 and on Docker's
# usual bridge; the zkapi container sits on it alone, at 172.31.250.3, with the
# folder as /state.
set -eu
state="$HOME/Library/Application Support/Regents Cloak zkAPI Trial"
mkdir -m 700 "$state"
docker network create --internal --subnet 172.31.250.0/24 cloak-zkapi-trial-closed
docker create --name cloak-zkapi-trial-tor --cpus 1 \
	--network cloak-zkapi-trial-closed --ip 172.31.250.2 cloak-zkapi-trial-tor
docker network connect bridge cloak-zkapi-trial-tor
docker create --name cloak-zkapi-trial-zkapi --init --cpus 2 \
	--network cloak-zkapi-trial-closed --ip 172.31.250.3 \
	-v "$state:/state" cloak-zkapi-trial-zkapi
