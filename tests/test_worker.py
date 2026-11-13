"""Functional checks of the native workers over their supervisor channel, each
with its engine's stand-in model (decision 8): the MLX worker with `standin`,
the llama worker with `standin-gguf`. Each check starts the installed,
sandboxed worker.

    worker/install.sh
    llama-worker/install.sh
    uv run --with pytest==8.4.2 pytest tests/test_worker.py

The model checks build their altered model folders once, from hard links and
small copies, under the models folder's `.checks/<model>/` (the only place the
sandboxed worker may read besides the models themselves) and reuse them.
"""

import json
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import WORKERS, answer, frame, read_frame, request_body, spawn  # noqa: E402
from fetch_model import DEST  # noqa: E402

CHECKS = DEST / ".checks"
ENTITLEMENTS = ROOT / "worker/cloak-rewriter.entitlements"


@dataclass(frozen=True)
class Engine:
    worker: Path
    name: str
    # A small file of the stand-in that the tamper checks alter.
    small_file: str

    @property
    def model(self) -> Path:
        return DEST / self.name


ENGINES = {
    "mlx": Engine(WORKERS["mlx"], "standin", "config.json"),
    "llama": Engine(WORKERS["llama"], "standin-gguf", "chat_template.jinja"),
}


@pytest.fixture(params=ENGINES, scope="module")
def engine(request) -> Engine:
    return ENGINES[request.param]


@pytest.fixture
def worker(engine):
    process = spawn(engine.worker, engine.name)
    assert read_frame(process.stdout) == (b"Y", b""), process.stderr.read().decode()
    yield process
    process.kill()
    process.wait()


def send(process, kind: bytes, payload: bytes = b"") -> None:
    process.stdin.write(frame(kind, payload))
    process.stdin.flush()


def ask(process, body: bytes) -> tuple[int, dict]:
    send(process, b"R", body)
    kind, payload = read_frame(process.stdout)
    assert kind == b"A"
    return answer(payload)


def prose() -> str:
    # Each stand-in reads 128 KiB of prose for several seconds before it
    # writes a token.
    return json.loads((ROOT / "reference/eval05-inputs.json").read_text())["prose"][:128 << 10]


def test_rewrite_answers_one_assistant_message(engine, worker):
    status, reply = ask(worker, request_body(engine.name, ["Hi! Could you tell me what a river delta is, thanks?"]))
    assert status == 200
    assert reply["object"] == "chat.completion"
    assert reply["model"] == engine.name
    [choice] = reply["choices"]
    assert choice["finish_reason"] == "stop"
    assert choice["message"]["role"] == "assistant"
    assert choice["message"]["content"]
    assert reply["usage"]["completion_tokens"] > 0


def test_rewrite_is_repeatable(engine, worker):
    body = request_body(engine.name, ["please list three tall mountains in Asia"])
    first, second = ask(worker, body)[1], ask(worker, body)[1]
    assert (first["choices"], first["usage"]) == (second["choices"], second["usage"])


def test_token_limit_ends_with_length(engine, worker):
    status, reply = ask(worker, request_body(engine.name, ["describe the water cycle in detail"], max_tokens=4))
    assert status == 200
    assert reply["choices"][0]["finish_reason"] == "length"
    assert reply["usage"]["completion_tokens"] == 4


@pytest.mark.parametrize("change", [
    lambda r: r | {"stream": True},
    lambda r: r | {"temperature": 0.7},
    lambda r: r | {"max_tokens": 16385},
    lambda r: r | {"model": "other"},
    lambda r: r | {"tools": []},
    lambda r: r | {"messages": r["messages"][1:]},
    lambda r: r | {"messages": [r["messages"][1], r["messages"][0]]},
    lambda r: r | {"messages": [r["messages"][0], r["messages"][1] | {"name": "x"}]},
])
def test_other_requests_are_refused_and_the_worker_keeps_serving(engine, worker, change):
    good = request_body(engine.name, ["what is the capital of Peru"], max_tokens=2)
    status, reply = ask(worker, json.dumps(change(json.loads(good))).encode())
    assert (status, reply) == (400, {"error": {"message": "invalid request"}})
    assert ask(worker, good)[0] == 200


def test_cancel_stops_the_rewrite(engine, worker):
    texts = [f"Please write a long, friendly paragraph about the history of city number {i}." for i in range(40)]
    started = time.monotonic()
    send(worker, b"R", request_body(engine.name, texts))
    time.sleep(1.0)
    send(worker, b"C")
    kind, payload = read_frame(worker.stdout)
    assert kind == b"A"
    assert answer(payload) == (499, {"error": {"message": "cancelled"}})
    assert time.monotonic() - started < 10
    assert ask(worker, request_body(engine.name, ["hello"], max_tokens=2))[0] == 200


def test_cancel_stops_the_rewrite_while_it_reads_the_prompt(engine, worker):
    # The cancel comes one second into reading the prompt.
    send(worker, b"R", request_body(engine.name, [prose()]))
    time.sleep(1.0)
    cancelled = time.monotonic()
    send(worker, b"C")
    kind, payload = read_frame(worker.stdout)
    assert (kind, answer(payload)) == (b"A", (499, {"error": {"message": "cancelled"}}))
    assert time.monotonic() - cancelled < 2
    assert ask(worker, request_body(engine.name, ["hello"], max_tokens=2))[0] == 200


@pytest.mark.parametrize("fault", ["second request", "unknown frame", "oversized frame", "input cut mid-frame"])
def test_a_protocol_fault_mid_rewrite_stops_the_rewrite_and_ends_the_worker(engine, worker, fault):
    # Exiting while a rewrite runs tears down the model library's GPU state
    # under it, so the rewrite in progress stops first, as when the channel
    # closes. The fault comes one second into reading the prompt.
    send(worker, b"R", request_body(engine.name, [prose()]))
    time.sleep(1.0)
    worker.stdin.write({
        "second request": frame(b"R", request_body(engine.name, ["hello"])),
        "unknown frame": frame(b"X", b""),
        "oversized frame": b"R" + (1 << 20 | 1).to_bytes(4, "big"),
        "input cut mid-frame": b"R" + (256).to_bytes(4, "big") + b"{",
    }[fault])
    worker.stdin.flush()
    if fault == "input cut mid-frame":
        worker.stdin.close()
    faulted = time.monotonic()
    assert worker.wait(timeout=30) == 2
    assert time.monotonic() - faulted < 2
    kind, payload = read_frame(worker.stdout)
    assert (kind, answer(payload)) == (b"A", (499, {"error": {"message": "cancelled"}}))
    assert read_frame(worker.stdout) is None


def test_unknown_frame_stops_the_worker(worker):
    send(worker, b"X")
    assert read_frame(worker.stdout) is None
    assert worker.wait(timeout=30) == 2


def test_oversized_frame_stops_the_worker(worker):
    worker.stdin.write(b"R" + (1 << 20 | 1).to_bytes(4, "big"))
    worker.stdin.flush()
    assert read_frame(worker.stdout) is None
    assert worker.wait(timeout=30) == 2


def test_closing_the_channel_ends_the_worker(worker):
    worker.stdin.close()
    assert worker.wait(timeout=30) == 0


def test_closing_the_channel_mid_rewrite_stops_the_rewrite_and_ends_the_worker(engine, worker):
    # The host's shutdown closes the channel, here one second into reading
    # the prompt.
    send(worker, b"R", request_body(engine.name, [prose()]))
    time.sleep(1.0)
    worker.stdin.close()
    closed = time.monotonic()
    assert worker.wait(timeout=30) == 0
    assert time.monotonic() - closed < 2
    kind, payload = read_frame(worker.stdout)
    assert (kind, answer(payload)) == (b"A", (499, {"error": {"message": "cancelled"}}))


def altered_model(engine: Engine, case: str, alter) -> Path:
    """The stand-in's files with one alteration, built on first use: hard links
    for the large files, real copies of the small files."""
    target = CHECKS / engine.name / case
    if not target.exists():
        building = CHECKS / engine.name / f"{case}.building"
        # A run stopped part way leaves a half-built folder; build it afresh.
        shutil.rmtree(building, ignore_errors=True)
        building.mkdir(parents=True)
        for file in engine.model.iterdir():
            if file.stat().st_size > 1 << 20:
                os.link(file, building / file.name)
            else:
                shutil.copy(file, building / file.name)
        alter(building)
        building.rename(target)
    return target


def refused(engine: Engine, directory: Path) -> str:
    process = spawn(engine.worker, engine.name, directory)
    assert read_frame(process.stdout) is None
    assert process.wait(timeout=60) == 2
    return process.stderr.read().decode()


def test_an_extra_file_is_refused(engine):
    model = altered_model(engine, "extra", lambda m: (m / "extra.json").write_text("{}"))
    assert "extra [\"extra.json\"]" in refused(engine, model)


def test_a_changed_file_is_refused(engine):
    def change(m: Path) -> None:
        small = m / engine.small_file
        small.write_text(small.read_text().replace("\n", " \n", 1))
    assert f"{engine.small_file} does not match the pin" in refused(engine, altered_model(engine, "changed", change))


def test_a_missing_file_is_refused(engine):
    model = altered_model(engine, "missing", lambda m: (m / engine.small_file).unlink())
    assert f"missing [\"{engine.small_file}\"]" in refused(engine, model)


def test_a_linked_file_is_refused(engine):
    def link(m: Path) -> None:
        (m / engine.small_file).unlink()
        (m / engine.small_file).symlink_to(engine.model / engine.small_file)
    assert f"{engine.small_file} is not a regular file" in refused(engine, altered_model(engine, "linked", link))


def test_the_worker_cannot_read_a_model_outside_the_models_folder(engine):
    # The repository's own copy of the pin list sits outside the models folder.
    assert f"cannot read {ROOT / 'reference'}" in refused(engine, ROOT / "reference")


def test_the_worker_is_signed_into_the_sandbox_with_its_entitlements(engine):
    signed = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", engine.worker],
                            capture_output=True, check=True).stdout
    assert plistlib.loads(signed) == plistlib.loads(ENTITLEMENTS.read_bytes())


PROBE = r"""
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
int main(int argc, char **argv) {
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(atoi(argv[1]))};
    inet_pton(AF_INET, "127.0.0.1", &to.sin_addr);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0 || connect(s, (struct sockaddr *)&to, sizeof to) < 0) { puts(strerror(errno)); return 0; }
    puts("connected");
    return 0;
}
"""


def test_the_worker_entitlements_deny_the_network(tmp_path):
    """A program signed with the workers' entitlements cannot open a
    connection that the same program, unsandboxed, can."""
    (tmp_path / "probe.c").write_text(PROBE)
    (tmp_path / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "sh.regents.cloak.netprobe"}))
    probe = tmp_path / "probe"
    subprocess.run(["cc", "-o", probe, tmp_path / "probe.c",
                    "-Wl,-sectcreate,__TEXT,__info_plist," + str(tmp_path / "Info.plist")], check=True)
    with socket.create_server(("127.0.0.1", 0)) as server:
        port = str(server.getsockname()[1])
        subprocess.run(["codesign", "-s", "-", "-f", probe], check=True, capture_output=True)
        assert subprocess.run([probe, port], capture_output=True, text=True).stdout == "connected\n"
        subprocess.run(["codesign", "-s", "-", "-f", "--entitlements", ENTITLEMENTS, probe], check=True, capture_output=True)
        assert subprocess.run([probe, port], capture_output=True, text=True).stdout == "Operation not permitted\n"
