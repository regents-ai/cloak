"""A stand-in for tor, for the checks that must not reach the Tor network.
The host starts it in place of tor, through the launcher the checks write,
with tor's arguments: like tor with --SocksPort 127.0.0.1:auto, it listens
on a free loopback port and names it in tor's own ready line, and it takes
its owner from --__OwningControllerProcess.

On its SOCKS port it plays tor with no way onto the Tor network: each
connection goes through the SOCKS5 steps (greeting, user name and password,
request) and is then refused with a general failure, never connected
anywhere. Each connection is noted when it ends, whichever step it reached,
as one line of FAKE_TOR_LOG/tor.jsonl: the identity it presented (the first
16 hex digits of sha256(user, 0, password), or "none") and the destination it
asked for (null if it never asked).

With FAKE_TOR_EXIT=1 it exits as soon as it has said it is ready, as a tor
that stops after starting. Like tor, it exits on SIGTERM and once its owner
has gone.
"""

import hashlib
import json
import os
import select
import socket
import sys
import threading
from pathlib import Path

LOG = Path(os.environ["FAKE_TOR_LOG"]) / "tor.jsonl"
EXIT = os.environ["FAKE_TOR_EXIT"] == "1"
written = threading.Lock()


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
    # General failure: nothing is connected.
    conn.sendall(b"\x05\x01\x00\x01" + bytes(6))


def refuse(conn: socket.socket) -> None:
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
        threading.Thread(target=refuse, args=(conn,), daemon=True).start()


def main() -> None:
    owner = int(argument("--__OwningControllerProcess"))
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen()
    print(f"[notice] Opened Socks listener connection (ready) on 127.0.0.1:{server.getsockname()[1]}", flush=True)
    if EXIT:
        return
    threading.Thread(target=serve, args=(server,), daemon=True).start()
    owner_exit = select.kqueue()
    owner_exit.control([select.kevent(owner, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
    owner_exit.control(None, 1)


if __name__ == "__main__":
    main()
