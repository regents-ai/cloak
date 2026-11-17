#!/bin/bash
# Runs inside the zkapi container while a daemon command is up: asks the
# daemon on its loopback listener for its funding address. The management
# token and the local API key reach curl on its standard input, never on a
# command line or in output. The answer is the address's public status.
set -euo pipefail
read -r token < /state/management-token
key=$(zkapi-clientd --config-dir /state config --api-key)
printf 'Authorization: Bearer %s\nX-OA-Management-Token: %s\n' "$key" "$token" |
	curl --silent --show-error --noproxy '*' --max-time 120 -H @- http://127.0.0.1:8787/admin/funding/address
echo
