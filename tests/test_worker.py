"""Functional checks of the native worker over its supervisor channel, with the
stand-in model. Each check starts the installed, sandboxed worker.

    worker/install.sh
    uv run --with pytest==8.4.2 pytest tests/test_worker.py

The model checks build their altered model folders once, from hard links and
small copies, under the models folder's `.checks/` (the only place the
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
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import INSTALLED, answer, frame, read_frame, request_body, spawn  # noqa: E402
from fetch_model import DEST  # noqa: E402

WORKER = INSTALLED
NAME = "standin"
MODEL = DEST / NAME
CHECKS = DEST / ".checks"
ENTITLEMENTS = ROOT / "worker/cloak-rewriter.entitlements"


@pytest.fixture
def worker():
    process = spawn(WORKER, NAME)
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


def test_rewrite_answers_one_assistant_message(worker):
    status, reply = ask(worker, request_body(NAME, ["Hi! Could you tell me what a river delta is, thanks?"]))
    assert status == 200
    assert reply["object"] == "chat.completion"
    assert reply["model"] == NAME
    [choice] = reply["choices"]
    assert choice["finish_reason"] == "stop"
    assert choice["message"]["role"] == "assistant"
    assert choice["message"]["content"]
    assert reply["usage"]["completion_tokens"] > 0


def test_rewrite_is_repeatable(worker):
    body = request_body(NAME, ["please list three tall mountains in Asia"])
    first, second = ask(worker, body)[1], ask(worker, body)[1]
    assert (first["choices"], first["usage"]) == (second["choices"], second["usage"])


def test_token_limit_ends_with_length(worker):
    status, reply = ask(worker, request_body(NAME, ["describe the water cycle in detail"], max_tokens=4))
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
def test_other_requests_are_refused_and_the_worker_keeps_serving(worker, change):
    good = request_body(NAME, ["what is the capital of Peru"], max_tokens=2)
    status, reply = ask(worker, json.dumps(change(json.loads(good))).encode())
    assert (status, reply) == (400, {"error": {"message": "invalid request"}})
    assert ask(worker, good)[0] == 200


def test_cancel_stops_the_rewrite(worker):
    texts = [f"Please write a long, friendly paragraph about the history of city number {i}." for i in range(40)]
    started = time.monotonic()
    send(worker, b"R", request_body(NAME, texts))
    time.sleep(1.0)
    send(worker, b"C")
    kind, payload = read_frame(worker.stdout)
    assert kind == b"A"
    assert answer(payload) == (499, {"error": {"message": "cancelled"}})
    assert time.monotonic() - started < 10
    assert ask(worker, request_body(NAME, ["hello"], max_tokens=2))[0] == 200


def test_second_request_while_busy_stops_the_worker(worker):
    body = request_body(NAME, ["tell me a long story about a lighthouse keeper"])
    send(worker, b"R", body)
    send(worker, b"R", body)
    assert read_frame(worker.stdout) is None
    assert worker.wait(timeout=30) == 2


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


def altered_model(case: str, alter) -> Path:
    """The stand-in's files with one alteration, built on first use: hard links
    for the weights, real copies of the small files."""
    target = CHECKS / case
    if not target.exists():
        building = CHECKS / f"{case}.building"
        # A run stopped part way leaves a half-built folder; build it afresh.
        shutil.rmtree(building, ignore_errors=True)
        building.mkdir(parents=True)
        for file in MODEL.iterdir():
            if file.stat().st_size > 1 << 20:
                os.link(file, building / file.name)
            else:
                shutil.copy(file, building / file.name)
        alter(building)
        building.rename(target)
    return target


def refused(directory: Path) -> str:
    process = spawn(WORKER, NAME, directory)
    assert read_frame(process.stdout) is None
    assert process.wait(timeout=60) == 2
    return process.stderr.read().decode()


def test_an_extra_file_is_refused():
    model = altered_model("extra", lambda m: (m / "extra.json").write_text("{}"))
    assert "extra [\"extra.json\"]" in refused(model)


def test_a_changed_file_is_refused():
    def change(m: Path) -> None:
        config = m / "config.json"
        config.write_text(config.read_text().replace("\n", " \n", 1))
    assert "config.json does not match the pin" in refused(altered_model("changed", change))


def test_a_missing_file_is_refused():
    model = altered_model("missing", lambda m: (m / "config.json").unlink())
    assert "missing [\"config.json\"]" in refused(model)


def test_a_linked_file_is_refused():
    def link(m: Path) -> None:
        (m / "config.json").unlink()
        (m / "config.json").symlink_to(MODEL / "config.json")
    assert "config.json is not a regular file" in refused(altered_model("linked", link))


def test_the_worker_cannot_read_a_model_outside_the_models_folder():
    # The repository's own copy of the pin list sits outside the models folder.
    assert f"cannot read {ROOT / 'reference'}" in refused(ROOT / "reference")


def test_the_worker_is_signed_into_the_sandbox_with_its_entitlements():
    signed = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", WORKER],
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
    """A program signed with the worker's entitlements cannot open a
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
