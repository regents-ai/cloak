# zkAPI trial

Open Anonymity's mainnet zkAPI daemon and its companion, run together outside
Cloak, in Docker on the Mac, with Tor as the only way out. No step here moves
money; funding, paid requests and withdrawals are not part of it.

## Design

- `cloak-zkapi-trial-closed` is a Docker network made with `--internal`: no
  route out.
- `cloak-zkapi-trial-tor` runs Debian's tor (`torrc`) on that network at
  172.31.250.2 and on Docker's usual bridge. Its one SOCKS port listens on
  172.31.250.2:9050 only, with `IsolateSOCKSAuth`, and accepts only the closed
  network.
- `cloak-zkapi-trial-zkapi` is on the closed network alone. The daemon takes
  only a numeric loopback SOCKS address (`internal/relay/relay.go:60-65`), so
  the container's main process is socat, forwarding 127.0.0.1:9050 to tor.
  The daemon is `/opt/zkapi/bin/zkapi-clientd`, the companion
  `/opt/zkapi/bin/zkapi-walletd` and the proving keys sit in
  `/opt/zkapi/share/zkapi-clientd/proof-setup`, where the daemon looks.
- The daemon's folder (`--config-dir /state`) is
  `~/Library/Application Support/Regents Cloak zkAPI Trial` on the Mac,
  owner-only. It holds the Ethereum key in hex
  (`funding/mainnet/address-funding.json`). Never print, copy or commit a file
  from it.

## Run

From the repository root:

1. `sh guest/zkapi/trial/build.sh` builds both images (needs
   `sh guest/zkapi/build.sh` first).
2. `sh guest/zkapi/trial/create.sh`, once: the network, the folder and both
   containers.
3. `sh guest/zkapi/trial/start.sh` starts both and proves, from inside the
   zkapi container, that a direct connection and a name lookup fail and that
   check.torproject.org sees Tor.
4. `docker exec cloak-zkapi-trial-zkapi zkapi-clientd --config-dir /state config --network mainnet --relay-url socks5://127.0.0.1:9050`
   saves the settings, starts the daemon and companion, makes the key, and
   stops at its first funding question: without a terminal it cannot ask.
5. `docker exec cloak-zkapi-trial-zkapi zkapi-clientd --config-dir /state serve`
   runs the startup checks and stops when it finds no deposit.
6. To ask for the address, keep a daemon up:
   `docker exec -t cloak-zkapi-trial-zkapi zkapi-clientd --config-dir /state config`
   waits at the deposit amount question. `-t` without `-i` gives it a terminal
   that nothing can type into. Never answer it. Then, from another terminal:
   `docker exec cloak-zkapi-trial-zkapi /opt/zkapi/trial/address.sh`.
7. `sh guest/zkapi/trial/stop.sh` stops the daemon and both containers.
   The containers and folder are kept, so step 3 starts them again.
