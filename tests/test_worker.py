"""Functional checks of the native worker over its supervisor channel, with the
stand-in model. Each check starts a real worker from the built binary.

    uv run --with pytest==8.4.2 pytest tests/test_worker.py

CLOAK_WORKER names the binary; it defaults to the Release build.
"""

import json
import os
import shutil
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import answer, frame, read_frame, request_body, spawn  # noqa: E402

WORKER = Path(os.environ.get("CLOAK_WORKER", ROOT / "worker/.xcode/Build/Products/Release/cloak-rewriter"))
NAME = "standin"
MODEL = ROOT / "models" / NAME


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


def copy_model(target: Path) -> Path:
    """Hard links for the weights, real copies of the small files."""
    target.mkdir()
    for file in MODEL.iterdir():
        if file.stat().st_size > 1 << 20:
            os.link(file, target / file.name)
        else:
            shutil.copy(file, target / file.name)
    return target


def refused(directory: Path) -> str:
    process = spawn(WORKER, NAME, directory)
    assert read_frame(process.stdout) is None
    assert process.wait(timeout=60) == 2
    return process.stderr.read().decode()


def test_an_extra_file_is_refused(tmp_path):
    model = copy_model(tmp_path / "model")
    (model / "extra.json").write_text("{}")
    assert "extra [\"extra.json\"]" in refused(model)


def test_a_changed_file_is_refused(tmp_path):
    model = copy_model(tmp_path / "model")
    config = model / "config.json"
    config.write_text(config.read_text().replace("\n", " \n", 1))
    assert "config.json does not match the pin" in refused(model)


def test_a_missing_file_is_refused(tmp_path):
    model = copy_model(tmp_path / "model")
    (model / "config.json").unlink()
    assert "missing [\"config.json\"]" in refused(model)


def test_a_linked_file_is_refused(tmp_path):
    model = copy_model(tmp_path / "model")
    (model / "config.json").unlink()
    (model / "config.json").symlink_to(MODEL / "config.json")
    assert "config.json is not a regular file" in refused(model)
