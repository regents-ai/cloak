"""Functional checks of the owner's agent tasks in a serving guest (decision
12 in docs/plan.md): the guest's runner runs Pi 1.3.0 in the reference
wrapper (bubblewrap, then torsocks) as the agent user, Pi's model requests go
to the guest's door port and over vsock to the Mac, and everything else Pi
and its tools open goes through the guest's Tor port, which has no other way
out: the guest has no network device.

cloak-host --serve stands in for the app. With --door it carries each
door-port connection to a stand-in for the app's door here, which answers as
the door does, with the answers in tests/door_answers.json; with --runner it
takes the tasks. That file also holds Pi's two requests in the first check,
as captured on 14 November 2026. DoorGuestTests checks the real door against
both: it gives these answers, byte for byte but for the order of keys, and
takes these requests as Pi sends them; the first check here fails if Pi's
requests stop having those headers and fields. tor is the stand-in (fake_tor.py), which notes and refuses every
connection, so nothing leaves the Mac and no model is asked anything.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_task_path.py

Each check boots the guest once.
"""

import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

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


def launcher(folder: Path, name: str, body: str) -> Path:
    path = folder / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


def box_pass() -> str:
    return "cloak-" + secrets.token_hex(32)


class StandInDoor:
    """The app's door as the agent meets it, on the Mac's end of the door
    port: one request per connection, answered with the next answer planned
    for its pass. It keeps every request it reads, and every connection, with
    how many bytes it sent and when it closed, so a connection a tool opens
    and sends nothing on can be watched."""

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
    ready once the guest says its sender is. Closing it ends the guest, as
    the end of the host's standard input does."""

    def __init__(self, tmp_path: Path):
        cases = tmp_path / "cases.jsonl"
        cases.write_text("")
        worker = launcher(tmp_path, "fake-worker", f'export FAKE_WORKER_READ_DELAY=0\nexec "{sys.executable}" -I "{FAKE}" "$@"\n')
        tor = launcher(tmp_path, "fake-tor", f'export FAKE_TOR_LOG="{tmp_path}" FAKE_TOR_START=ready\n'
                                             f'exec "{sys.executable}" -I "{FAKE_TOR}" "$@"\n')
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
                 "--cases", cases, "--worker", worker, "--name", NAME, "--dir", DEST / NAME,
                 "--tor", tor, "--tor-data", tmp_path / "tor-data",
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
        log = self.tmp_path / "tor.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

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


def test_pi_takes_the_doors_answers_and_runs_its_tool_through_tor(tmp_path):
    """One task: the door's answer is a tool call, Pi runs the tool in the
    sandbox, sends its result back, and ends with the door's final answer.
    In the tool, curl under torsocks reaches the Tor port and nothing else;
    without torsocks it reaches nothing."""
    serving = Serving(tmp_path)
    try:
        presented = box_pass()
        serving.door.plans[presented] = ["tool", "final"]
        started = time.monotonic()
        ran = serving.run(task("Run the checks, then say they ran.", "s-1", presented))
        took = time.monotonic() - started
    finally:
        serving.close()

    assert ran[-1] == {"exited": {"status": 0, "signalled": False}}, ran
    assert all(set(e) in ({"output"}, {"error"}, {"exited"}) for e in ran), ran
    seen = outputs(ran)
    assert seen[0]["type"] == "session"
    ended = [e for e in seen if e["type"] == "tool_execution_end"]
    assert [e["toolName"] for e in ended] == ["bash"]
    result = ended[0]["result"]["content"][0]["text"]
    finals = [e["message"] for e in seen if e["type"] == "message_end" and e["message"]["role"] == "assistant"]
    assert [part["text"] for part in finals[-1]["content"] if part["type"] == "text"] == ["The checks ran."]

    # The tool ran in the sandbox, as the agent user, in the conversation's workspace.
    assert "pid1 bwrap in /workspace as 1005" in result, result
    # Under torsocks, curl reached the Tor port, which refused it; without
    # torsocks it reached nothing, and the stand-in tor saw no more.
    torsocks = int(re.search(r"torsocks curl exit (\d+)", result).group(1))
    bypass = int(re.search(r"bypass curl exit (\d+)", result).group(1))
    assert torsocks != 0 and bypass != 0, result
    assert "Network is unreachable" in result, result
    assert [r["destination"] for r in serving.routes()].count("192.0.2.1:80") == 1, serving.routes()

    # Pi's two requests: the task, then the tool's result.
    asked = serving.door.asked(presented)
    assert [r["line"] for r in asked] == ["POST /v1/chat/completions HTTP/1.1"] * 2
    first, second = (json.loads(r["body"]) for r in asked)
    assert first["model"] == second["model"] == MODEL and first["stream"] is True
    assert "bash" in [t["function"]["name"] for t in first["tools"]]
    assert first["messages"][-1] == {"role": "user", "content": [{"type": "text", "text": "Run the checks, then say they ran."}]}
    replies = [m for m in second["messages"] if m["role"] == "tool"]
    assert [m["tool_call_id"] for m in replies] == ["call_tool"]
    assert "torsocks curl exit" in json.dumps(replies[0]["content"])
    # Pi sends what DoorGuestTests shows the door takes: its requests as
    # captured in tests/door_answers.json, with the same headers and fields.
    captured = ANSWERS["requests"]
    sent = [[name for name, _ in r["headers"] if name not in ("host", "content-type", "content-length", "authorization")]
            for r in asked]
    assert sent == [[name for name, _ in captured["headers"]]] * 2
    assert [set(first), set(second)] == [set(json.loads(captured["first"])), set(json.loads(captured["second"]))]

    memory = {name: int(kb) for name, kb in re.findall(r"^(MemTotal|MemFree|MemAvailable|Shmem):\s+(\d+) kB", result, re.M)}
    resident = re.findall(r"^/proc/\d+/status:Name:\s+(\S+)\n/proc/\d+/status:VmRSS:\s+(\d+) kB", result, re.M)
    print(json.dumps({"seconds": round(took, 1), "memory_kb": memory, "rss_kb": resident}))


def test_a_task_ends_with_its_connection_and_conversations_run_side_by_side(tmp_path):
    """A task whose tool holds two connections to the door, one of them from a
    process in a session of its own, ends with every process in its sandbox
    within seconds of its connection closing. While it runs, another task in
    its conversation is refused, a task in another conversation runs to its
    end, and requests that do not read are refused; after it, the
    conversation's next task continues its session."""
    serving = Serving(tmp_path)
    try:
        holding, other = box_pass(), box_pass()
        serving.door.plans[holding] = ["hold"]
        serving.door.plans[other] = ["final"]
        held = serving.start(task("Hold two connections.", "s-a", holding))
        # Its events are read as they come, as the app reads them.
        rest: list[dict] = []
        reader = threading.Thread(target=lambda: rest.extend(events(held)))
        reader.start()
        wait_for(lambda: len(serving.door.silent()) == 2, 600, "the tool did not hold its connections")
        connections = serving.door.silent()

        assert serving.run(task("Something else.", "s-a", holding)) == [{"failed": "busy"}]
        for refused in [task("Hi.", "../s-a", holding), task(" \n\ufeff", "s-b", holding),
                        task("Hi.", "s-b", "cloak-nope"), task("Hi.", "s-b", holding, model="a\nb")]:
            assert serving.run(refused) == [{"failed": "invalid"}], refused

        beside = serving.run(task("Say they ran.", "s-c", other))
        assert beside[-1] == {"exited": {"status": 0, "signalled": False}}, beside
        assert serving.door.silent() == connections

        held.shutdown(socket.SHUT_WR)
        ending = time.monotonic()
        wait_for(lambda: all(c["closed"] is not None for c in connections), 30, "the task's processes outlived it")
        took = max(c["closed"] for c in connections) - ending
        assert took < 5, took
        # Ended by its connection, the task has no exit to send.
        reader.join(30)
        assert not reader.is_alive()
        assert rest and all(set(e) in ({"output"}, {"error"}) for e in rest), rest

        serving.door.plans[holding] = ["final"]
        continued = serving.run(task("Now say they ran.", "s-a", holding))
        assert continued[-1] == {"exited": {"status": 0, "signalled": False}}, continued
        last = json.loads(serving.door.asked(holding)[-1]["body"])
        said = [part["text"] for m in last["messages"] if m["role"] == "user" for part in m["content"]]
        assert said[0] == "Hold two connections." and said[-1] == "Now say they ran.", said
    finally:
        serving.close()
    print(json.dumps({"held_closed_within_s": round(took, 2)}))
