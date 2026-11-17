#!/bin/bash
# Runs inside the zkapi container before any daemon command: a direct
# connection out and a name lookup must both fail, and a fetch through
# 127.0.0.1:9050, the address the daemon is given, must come back from Tor.
# Prints each result as it happened; exits non-zero unless all three hold.
set -uo pipefail

echo "1. Direct HTTPS to 1.1.1.1, no proxy:"
if curl --silent --show-error --noproxy '*' --max-time 15 --output /dev/null https://1.1.1.1/; then
	echo "   connected: the container has a way out besides tor"
	exit 1
fi

echo "2. Name lookup of check.torproject.org:"
if getent hosts check.torproject.org; then
	echo "   resolved: the container has a resolver that reaches out"
	exit 1
fi
echo "   no answer"

echo "3. https://check.torproject.org/api/ip through 127.0.0.1:9050:"
answer=$(curl --silent --show-error --max-time 90 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip)
echo "   $answer"
case $answer in
*'"IsTor":true'*) ;;
*) exit 1 ;;
esac
