"""A stand-in for tor, for the checks that must not reach the Tor network.
The host starts it in place of tor, through the launcher the checks write,
with tor's arguments: like tor with --SocksPort unix:<path>, it listens on
that socket file and names it in tor's own ready line, and it takes its
owner from --__OwningControllerProcess.

On its SOCKS socket it plays tor with no way onto the Tor network: each
connection goes through the SOCKS5 steps (greeting, user name and password,
request) and is then refused with a general failure (or answered as
connected in the late start, below), never connected anywhere, in the form
tor answers on a socket file, with an IPv6 address of all zeros. Each
connection is noted when it ends, whichever step it reached, as one line of
FAKE_TOR_LOG/tor.jsonl: the identity it presented (the first 16 hex digits
of sha256(user, 0, password), or "none") and the destination it asked for
(null if it never asked).

It says it has bootstrapped in tor's own line ("Bootstrapped 100% (done):
Done") as FAKE_TOR_START says:

- ready: at once.
- late: LATE_S seconds after its port opened, as tor takes a while to fetch
  the Tor network's directory. From then on it answers each request as
  connected, though it connects nowhere, so the daemon's route check passes
  and closes the stream; before then it refuses, as tor does.
- never: never.
- exits: it exits right after its first bootstrap line, as a tor that stops
  while starting.
- hangs: it never opens its port or says anything, as a tor that hangs
  while starting, and does not watch its owner either: only a signal ends
  it. It writes its pid to FAKE_TOR_LOG/tor.pid, so a check can see whether
  it is still running.

Like tor, it keeps a state file in the folder it is given with
--DataDirectory: at each start it notes in FAKE_TOR_LOG/starts.jsonl that
folder and the state file it found there (null if none), then writes its
own. Like tor, it exits on SIGTERM, and, unless it hangs, once its owner has
gone.
"""

import hashlib
import json
import os
import select
import signal
import socket
import sys
import threading
import time
from pathlib import Path

LOG = Path(os.environ["FAKE_TOR_LOG"]) / "tor.jsonl"
START = os.environ["FAKE_TOR_START"]
# tor bootstrapped about 9 s after it started, in one check on the public
# Tor network (docs/plan.md, "Tor out of the guest").
LATE_S = 10
written = threading.Lock()
bootstrapped = threading.Event()


def argument(name: str) -> str:
    return sys.argv[sys.argv.index(name) + 1]


def read_exactly(conn: socket.socket, count: int) -> bytes | None:
    data = b""
    while len(data) < count:
        if not (block := conn.recv(count - len(data))):
            return None
        data += block
    return data


def steps(conn: socket.socket, attempt: dict) -> None:
    head = read_exactly(conn, 2)
    if head is None or head[0] != 5 or (methods := read_exactly(conn, head[1])) is None:
        return
    if 2 in methods:
        conn.sendall(b"\x05\x02")
        # RFC 1929: version 1, user, password.
        version = read_exactly(conn, 2)
        if version is None or version[0] != 1 or (user := read_exactly(conn, version[1])) is None:
            return
        size = read_exactly(conn, 1)
        if size is None or (password := read_exactly(conn, size[0])) is None:
            return
        attempt["identity"] = hashlib.sha256(user + b"\0" + password).hexdigest()[:16]
        conn.sendall(b"\x01\x00")
    else:
        conn.sendall(b"\x05\x00")
    # Request: version, command, reserved, address type, address, port.
    request = read_exactly(conn, 4)
    if request is None:
        return
    if request[3] == 1 and (address := read_exactly(conn, 4)) is not None:
        host = socket.inet_ntop(socket.AF_INET, address)
    elif request[3] == 3 and (size := read_exactly(conn, 1)) is not None and (name := read_exactly(conn, size[0])) is not None:
        host = name.decode()
    elif request[3] == 4 and (address := read_exactly(conn, 16)) is not None:
        host = f"[{socket.inet_ntop(socket.AF_INET6, address)}]"
    else:
        return
    if (port := read_exactly(conn, 2)) is None:
        return
    attempt["destination"] = f"{host}:{int.from_bytes(port, 'big')}"
    # Succeeded (late, once bootstrapped), with nothing connected; otherwise
    # a general failure.
    reply = 0 if START == "late" and bootstrapped.is_set() else 1
    conn.sendall(bytes([5, reply, 0, 4]) + bytes(18))


def answer(conn: socket.socket) -> None:
    attempt = {"identity": "none", "destination": None}
    try:
        conn.settimeout(30)
        steps(conn, attempt)
    except OSError:
        pass
    finally:
        conn.close()
        with written, LOG.open("a") as log:
            log.write(json.dumps(attempt) + "\n")


def serve(server: socket.socket) -> None:
    while True:
        conn, _ = server.accept()
        threading.Thread(target=answer, args=(conn,), daemon=True).start()


def bootstrap(after_s: float) -> None:
    time.sleep(after_s)
    bootstrapped.set()
    print("[notice] Bootstrapped 100% (done): Done", flush=True)


def main() -> None:
    state = Path(argument("--DataDirectory")) / "state"
    with (LOG.parent / "starts.jsonl").open("a") as starts:
        found = state.read_text() if state.exists() else None
        starts.write(json.dumps({"data": str(state.parent), "found": found, "pid": os.getpid()}) + "\n")
    state.write_text(f"stand-in {os.getpid()}")
    if START == "hangs":
        (LOG.parent / "tor.pid").write_text(str(os.getpid()))
        # SIGTERM, unhandled, ends it.
        signal.pause()
    owner = int(argument("--__OwningControllerProcess"))
    # unix:<path> IsolateSOCKSAuth
    listener = argument("--SocksPort").removeprefix("unix:").split()[0]
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(listener)
    server.listen()
    print(f"[notice] Opened Socks listener connection (ready) on {listener}", flush=True)
    print("[notice] Bootstrapped 0% (starting): Starting", flush=True)
    if START == "exits":
        return
    threading.Thread(target=serve, args=(server,), daemon=True).start()
    if START == "ready":
        bootstrap(0)
    elif START == "late":
        threading.Thread(target=bootstrap, args=(LATE_S,), daemon=True).start()
    owner_exit = select.kqueue()
    owner_exit.control([select.kevent(owner, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
    owner_exit.control(None, 1)


if __name__ == "__main__":
    main()
