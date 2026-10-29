#!/usr/bin/env bash
# Records what the reconstructed sandbox lets through. Starts Tor with the
# reference torrc, then runs each probe inside the same sandbox Pi runs in.
set -euo pipefail

mkdir -p "$HOME/tor" "$HOME/workspace"
tor -f /opt/cloak/wrapper/torrc --DataDirectory "$HOME/tor" --Log "notice file $HOME/tor/log" --RunAsDaemon 1
for _ in $(seq 120); do
  grep -q 'Bootstrapped 100%' "$HOME/tor/log" 2>/dev/null && break
  sleep 1
done
grep -q 'Bootstrapped 100%' "$HOME/tor/log" || { echo "tor did not bootstrap"; exit 1; }

echo "== versions"
echo "pi $(sandbox "$HOME/workspace" pi --version)"
dpkg-query -W -f '${Package} ${Version}\n' tor torsocks bubblewrap
zkapi-clientd-concession-tor version

echo "== dynamically linked tool (curl), TCP"
sandbox "$HOME/workspace" curl -sS --max-time 30 https://check.torproject.org/api/ip \
  | python3 -c 'import json, sys; print("tcp: connected, through Tor:", json.load(sys.stdin)["IsTor"])'

echo "== dynamically linked tool (python), UDP DNS"
sandbox "$HOME/workspace" python3 -c '
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    s.sendto(bytes.fromhex("123401000001000000000000076578616d706c6503636f6d0000010001"), ("1.1.1.1", 53))
    s.recv(512)
    print("udp dns: answered directly")
except OSError as e:
    print(f"udp dns: blocked ({e})")
'

echo "== statically linked program (probe)"
sandbox "$HOME/workspace" probe
