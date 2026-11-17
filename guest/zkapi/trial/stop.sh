#!/bin/sh
# Stops both containers and keeps them and the folder. A daemon command still
# running in the zkapi container is first asked to stop (SIGTERM, as Ctrl+C),
# and given up to 20 seconds to stop its companion and exit.
set -eu
if docker exec cloak-zkapi-trial-zkapi pkill -TERM -x zkapi-clientd; then
	tries=0
	while docker exec cloak-zkapi-trial-zkapi pgrep -x zkapi-clientd > /dev/null; do
		tries=$((tries + 1))
		test "$tries" -le 20 || { echo "zkapi-clientd did not stop within 20 seconds" >&2; exit 1; }
		sleep 1
	done
fi
docker stop cloak-zkapi-trial-zkapi cloak-zkapi-trial-tor > /dev/null
