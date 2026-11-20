"""How the guest checks boot the guest, shared by them: once, to run the
cases in one boot (cloak-agent-check prints one result per case), or
serving, as the app's guest does, with a stand-in for the app's door. The
host's worker is the stand-in (fake_worker.py) and its tor the stand-in
(fake_tor.py), but where a check names tor itself. Every boot has a payment
disk (guest/image/pay-disk), a new one in the boot's folder unless a check
gives its own.
"""

import json
import os
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from cover_list import NO_COVER, initrd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_model import DEST  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
FAKE = ROOT / "tests/fake_worker.py"
FAKE_TOR = ROOT / "tests/fake_tor.py"
NAME = "standin-gguf-grammar"
ANSWERS = json.loads((ROOT / "tests/door_answers.json").read_text())
MODEL = ANSWERS["model"]
UNPLANNED = (b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 2\r\n"
             b"Connection: close\r\n\r\n{}")


def sandbox(name: str, script: str) -> dict:
    return {"name": name, "sandbox": ["/bin/sh", "-c", script]}


def pay(name: str, script: str) -> dict:
    """A case run as the payer's user, outside the sandbox, in its home: the
    payment disk."""
    return {"name": name, "pay": ["/bin/sh", "-c", script]}


@dataclass
class Disk:
    """A boot's payment disk: an image file, and the 32 bytes it is
    encrypted under in a key file; new while the image is blank."""
    image: Path
    key: Path
    new: bool

    @classmethod
    def blank(cls, folder: Path, name: str = "pay-disk") -> "Disk":
        """A blank 64 MiB image, sparse, and a random key, in place of any
        made before under the name."""
        image, key = folder / f"{name}.img", folder / f"{name}.key"
        with image.open("wb") as file:
            file.truncate(64 << 20)
        key.write_bytes(secrets.token_bytes(32))
        return cls(image, key, True)

    def args(self) -> list:
        return ["--disk", self.image, "--disk-key", self.key, *(["--new-disk"] if self.new else [])]


# The payer's home, the payment disk's mount point, and the files the payer's
# programs keep there (docs/plan.md, "The encrypted disk"): the daemon's
# payment address, which holds its signing key, and the companion's note,
# which holds its note secret, and write-ahead journal.
PAY_HOME = "/var/lib/cloak-pay"
NOTE_DIR = ".config/zkapi-clientd/zkapi/mainnet/zkapi-native-eth-mainnet-note-bound-v1-fresh-20260930"
ADDRESS, NOTE, JOURNAL = (".config/zkapi-clientd/funding/mainnet/address-funding.json",
                          f"{NOTE_DIR}/note_state.json", f"{NOTE_DIR}/pending_journal.json")


def pay_files(marker: str) -> dict[str, str]:
    """Stand-ins for the payment files, each holding the marker, the
    journal in upstream's shape (zkapi-client's journal.rs at the pinned
    protocol commit)."""
    return {
        ADDRESS: json.dumps({"version": 1, "address": "0x0", "private_key": f"{marker}-signing-key", "phase": "ready"}),
        NOTE: json.dumps({"note_id": 7, "secret_s": f"{marker}-note-secret", "current_balance": 1000}),
        JOURNAL: json.dumps({"exists": True, "client_request_id": f"{marker}-request", "nullifier": "0x2",
                             "payload_hash": "0x3", "user_rerandomization": "0x1", "created_at_ms": 1}),
    }


def write_pay_files(name: str, files: dict[str, str]) -> dict:
    """A pay case that writes each file to a temporary name and renames it
    into place, as upstream writes them, with no fsync."""
    folders = sorted({str(Path(path).parent) for path in files})
    steps = [f"mkdir -p -m 0700 {' '.join(folders)}"]
    steps += [f"printf %s {shlex.quote(data)} > {path}.tmp && mv {path}.tmp {path}" for path, data in files.items()]
    return pay(name, " && ".join(steps))


def launcher(folder: Path, name: str, body: str) -> Path:
    path = folder / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


def fake(tmp_path: Path) -> Path:
    return launcher(tmp_path, "fake-worker", f'export FAKE_WORKER_READ_DELAY=0\nexec "{sys.executable}" -I "{FAKE}" "$@"\n')


def fake_tor(tmp_path: Path, start: str) -> Path:
    """The stand-in tor, started as FAKE_TOR_START says (fake_tor.py)."""
    return launcher(tmp_path, "fake-tor", f'export FAKE_TOR_LOG="{tmp_path}" FAKE_TOR_START={start}\n'
                                          f'exec "{sys.executable}" -I "{FAKE_TOR}" "$@"\n')


def routes(tmp_path: Path) -> list[dict]:
    """Every connection the stand-in tor saw, in the order they ended."""
    log = tmp_path / "tor.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def host(tmp_path: Path, cases: list[dict], tor_launcher: Path, disk: Disk | None = None) -> dict:
    """The host's command line and environment, to run the cases in one
    guest boot, with tor's lasting folder in tmp_path, and the disk given or
    a new one there. The guest boots with cover off, an empty cover list laid
    over the image's (cover_list.py), so the stand-in tor sees only what the
    cases cause."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    disk = disk or Disk.blank(tmp_path)
    return {"args": [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", initrd(tmp_path, NO_COVER),
                     "--cases", cases_file, "--worker", fake(tmp_path), "--name", NAME, "--dir", DEST / NAME,
                     "--tor", tor_launcher, "--tor-data", tmp_path / "tor-data", *disk.args()],
            "env": os.environ | {"FAKE_WORKER_LOG": str(tmp_path)}}


def run(tmp_path: Path, cases: list[dict], tor_launcher: Path, on_log: Callable[[str], None] = lambda line: None,
        disk: Disk | None = None, until: Callable[[str], bool] | None = None) -> tuple[str, str, int]:
    """Runs one guest boot; returns the guest's console, the host's log,
    each line of which also goes to on_log as it comes, and the host's exit
    status. With `until`, the host is killed (SIGKILL, which ends its guest
    with it, stopping nothing cleanly) as soon as `until` holds for the
    console."""
    console = tmp_path / "console"
    with console.open("w") as stdout:
        running = subprocess.Popen(**host(tmp_path, cases, tor_launcher, disk), stdout=stdout, stderr=subprocess.PIPE,
                                   text=True)
    lines = []

    def read() -> None:
        for line in running.stderr:
            lines.append(line)
            on_log(line)

    reader = threading.Thread(target=read)
    reader.start()
    try:
        if until is None:
            running.wait(timeout=900)
        else:
            wait_for(lambda: until(console.read_text()) or running.poll() is not None, 900, "the guest never got there")
    finally:
        running.kill()
        running.wait()
        reader.join()
    return console.read_text(), "".join(lines), running.returncode


def boot(tmp_path: Path, cases: list[dict], tor_launcher: Path, on_log: Callable[[str], None] = lambda line: None,
         disk: Disk | None = None) -> tuple[dict[str, dict], str]:
    """Runs the cases in one guest boot; returns each case's result and the
    host's log, each line of which also goes to on_log as it comes."""
    out, err, returncode = run(tmp_path, cases, tor_launcher, on_log, disk)
    assert returncode == 0, err
    assert "cloak-guest: agent check exited 0" in out, out + err
    results = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    assert [r["name"] for r in results] == [c["name"] for c in cases]
    return {r["name"]: r for r in results}, err


def box_pass() -> str:
    return "cloak-" + secrets.token_hex(32)


class StandInDoor:
    """The app's door as the agent meets it, on the Mac's end of the door
    port: one request per connection, answered with the next answer planned
    for its pass, from tests/door_answers.json. It keeps every request it
    reads, and every connection, with how many bytes it sent and when it
    closed, so a connection a tool opens and sends nothing on can be
    watched."""

    def __init__(self, path: str):
        self.plans: dict[str, list[str]] = {}
        self.requests: list[dict] = []
        self.connections: list[dict] = []
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(16)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.answer, args=(conn,), daemon=True).start()

    def answer(self, conn: socket.socket) -> None:
        connection = {"bytes": 0, "closed": None}
        with self.lock:
            self.connections.append(connection)
        try:
            data = b""
            while b"\r\n\r\n" not in data:
                if not (block := conn.recv(1 << 16)):
                    return
                data += block
                connection["bytes"] += len(block)
            head, _, body = data.partition(b"\r\n\r\n")
            line, *fields = head.decode().split("\r\n")
            headers = [tuple(field.split(": ", 1)) for field in fields]
            named = {name.lower(): value for name, value in headers}
            while len(body) < int(named.get("content-length", "0")):
                body += conn.recv(1 << 16)
            presented = named.get("authorization", "").removeprefix("Bearer ")
            with self.lock:
                self.requests.append({"line": line, "headers": headers, "body": body.decode(), "pass": presented})
                plan = self.plans.get(presented, [])
                planned = plan.pop(0) if plan else None
            conn.sendall(ANSWERS["answers"][planned]["response"].encode() if planned else UNPLANNED)
        finally:
            conn.close()
            connection["closed"] = time.monotonic()

    def asked(self, presented: str) -> list[dict]:
        with self.lock:
            return [r for r in self.requests if r["pass"] == presented]

    def silent(self) -> list[dict]:
        """The connections still open that have sent nothing."""
        with self.lock:
            return [c for c in self.connections if c["bytes"] == 0 and c["closed"] is None]

    def close(self) -> None:
        self.server.close()


class Serving:
    """A serving guest: cloak-host --serve with the stand-in door and tor,
    from the image as built (so with cover on), ready once the guest says
    its sender is. Closing it ends the guest, as the end of the host's
    standard input does."""

    def __init__(self, tmp_path: Path):
        cases = tmp_path / "cases.jsonl"
        cases.write_text("")
        self.tmp_path = tmp_path
        self.console: list[str] = []
        ready = threading.Event()
        # Socket files need a short path.
        self.sockets = Path(tempfile.mkdtemp(prefix="cloak-task-", dir="/tmp"))
        self.door = StandInDoor(str(self.sockets / "door"))
        self.runner = str(self.sockets / "runner")
        try:
            self.host = subprocess.Popen(
                [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
                 "--cases", cases, "--worker", fake(tmp_path), "--name", NAME, "--dir", DEST / NAME,
                 "--tor", fake_tor(tmp_path, "ready"), "--tor-data", tmp_path / "tor-data", *Disk.blank(tmp_path).args(),
                 "--serve", "--door", self.sockets / "door", "--runner", self.runner],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                env=os.environ | {"FAKE_WORKER_LOG": str(tmp_path)})
        except OSError:
            self.door.close()
            shutil.rmtree(self.sockets)
            raise

        def read() -> None:
            for line in self.host.stderr:
                self.console.append(line)
                if "cloak-guest: sender ready" in line:
                    ready.set()
            ready.set()

        self.reader = threading.Thread(target=read)
        self.reader.start()
        if not ready.wait(600) or self.host.poll() is not None:
            self.close()
            raise AssertionError("the guest did not serve:\n" + "".join(self.console))

    def start(self, request: dict) -> socket.socket:
        """Starts one task; its events are the lines read from the socket."""
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.runner)
        client.sendall((json.dumps(request) + "\n").encode())
        return client

    def run(self, request: dict, timeout_s: float = 600) -> list[dict]:
        client = self.start(request)
        client.settimeout(timeout_s)
        return events(client)

    def routes(self) -> list[dict]:
        return routes(self.tmp_path)

    def close(self) -> None:
        try:
            if self.host.poll() is None:
                self.host.stdin.close()
                self.host.wait(timeout=120)
        finally:
            self.host.kill()
            self.reader.join()
            self.door.close()
            shutil.rmtree(self.sockets)
        assert self.host.returncode == 0, "".join(self.console)


def events(client: socket.socket) -> list[dict]:
    """A task's events, until the host ends the connection."""
    with client, client.makefile("rb") as lines:
        return [json.loads(line) for line in lines]


def outputs(events: list[dict]) -> list[dict]:
    return [json.loads(e["output"]) for e in events if "output" in e]


def task(text: str, session: str, presented: str, model: str = MODEL) -> dict:
    return {"task": text, "session": session, "model": model, "pass": presented}


def wait_for(condition, timeout_s: float, what: str) -> None:
    deadline = time.monotonic() + timeout_s
    while not condition():
        assert time.monotonic() < deadline, what
        time.sleep(0.05)
