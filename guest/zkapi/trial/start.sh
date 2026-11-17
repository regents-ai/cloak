#!/bin/sh
# Starts tor and waits up to three minutes for it to bootstrap, starts the
# zkapi container (its main process only forwards 127.0.0.1:9050 to tor's
# SOCKS port), then runs the closed-network proofs inside it. Daemon commands
# are run by hand afterwards (README.md).
set -eu
docker start cloak-zkapi-trial-tor > /dev/null
started=$(docker inspect --format '{{.State.StartedAt}}' cloak-zkapi-trial-tor)
tries=0
until docker logs --since "$started" cloak-zkapi-trial-tor 2>&1 | grep -q 'Bootstrapped 100%'; do
	tries=$((tries + 1))
	test "$tries" -le 90 || { echo "tor did not bootstrap within three minutes" >&2; exit 1; }
	sleep 2
done
docker start cloak-zkapi-trial-zkapi > /dev/null
docker exec cloak-zkapi-trial-zkapi /opt/zkapi/trial/proofs.sh
