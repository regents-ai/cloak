"""Functional checks of the worker (decision 8 in docs/plan.md) over its
supervisor channel, with the stand-in `standin-gguf-grammar`, decoded under
the reply grammar (decision 9). Each check starts the installed, sandboxed
worker. It answers the daemon's rewrite request and nothing else, cancels,
stops on a protocol fault, refuses a model folder that is not exactly the
pinned files, runs in the sandbox with no network, links no network or
server code, and logs numbers only, with llama.cpp itself writing nothing.
Under the grammar the daemon accepts every reply the model ended and only
those, a reply holds as many texts as the request, and white space between
tokens never runs on; the daemon's own code judges each reply.

    llama-worker/install.sh
    uv run --with pytest==8.4.2 pytest tests/test_llama_worker.py

The model checks build their altered model folders once, from hard links and
small copies, under the models folder's `.checks/<model>/` (the only place the
sandboxed worker may read besides the models themselves) and reuse them. The
grammar checks build the daemon's reply check (tests/daemon_reply/) with Go,
inside the pinned daemon source.
"""

import base64
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import WORKER, answer, frame, go_json, read_frame, request_body, spawn  # noqa: E402
from fetch_model import DEST  # noqa: E402

NAME = "standin-gguf-grammar"
MODEL = DEST / NAME
# A small file of the stand-in that the model checks alter.
SMALL_FILE = "chat_template.jinja"
CHECKS = DEST / ".checks"
ENTITLEMENTS = ROOT / "llama-worker/cloak-rewriter.entitlements"
DAEMON = ROOT / "reference/src/zkapi/zkapi-clientd"
EVAL06 = json.loads((ROOT / "reference/eval06-messages.json").read_text())["messages"]


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


def prose() -> str:
    # The stand-in reads 128 KiB of prose for several seconds before it
    # writes a token.
    return json.loads((ROOT / "reference/eval05-inputs.json").read_text())["prose"][:128 << 10]


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


def test_cancel_stops_the_rewrite_while_it_reads_the_prompt(worker):
    # The cancel comes one second into reading the prompt.
    send(worker, b"R", request_body(NAME, [prose()]))
    time.sleep(1.0)
    cancelled = time.monotonic()
    send(worker, b"C")
    kind, payload = read_frame(worker.stdout)
    assert (kind, answer(payload)) == (b"A", (499, {"error": {"message": "cancelled"}}))
    assert time.monotonic() - cancelled < 2
    assert ask(worker, request_body(NAME, ["hello"], max_tokens=2))[0] == 200


@pytest.mark.parametrize("fault", ["second request", "unknown frame", "oversized frame", "input cut mid-frame"])
def test_a_protocol_fault_mid_rewrite_stops_the_rewrite_and_ends_the_worker(worker, fault):
    # Exiting while a rewrite runs tears down llama.cpp's GPU state under it,
    # so the rewrite in progress stops first, as when the channel closes. The
    # fault comes one second into reading the prompt.
    send(worker, b"R", request_body(NAME, [prose()]))
    time.sleep(1.0)
    worker.stdin.write({
        "second request": frame(b"R", request_body(NAME, ["hello"])),
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


def test_closing_the_channel_mid_rewrite_stops_the_rewrite_and_ends_the_worker(worker):
    # The host's shutdown closes the channel, here one second into reading
    # the prompt.
    send(worker, b"R", request_body(NAME, [prose()]))
    time.sleep(1.0)
    worker.stdin.close()
    closed = time.monotonic()
    assert worker.wait(timeout=30) == 0
    assert time.monotonic() - closed < 2
    kind, payload = read_frame(worker.stdout)
    assert (kind, answer(payload)) == (b"A", (499, {"error": {"message": "cancelled"}}))


def altered_model(case: str, alter) -> Path:
    """The stand-in's files with one alteration, built on first use: hard links
    for the large files, real copies of the small files."""
    target = CHECKS / NAME / case
    if not target.exists():
        building = CHECKS / NAME / f"{case}.building"
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
    """The worker's reason for refusing the model folder: it exits with
    status 3 before it is ready."""
    process = spawn(WORKER, NAME, directory)
    assert read_frame(process.stdout) is None
    assert process.wait(timeout=60) == 3
    return process.stderr.read().decode()


def test_an_extra_file_is_refused():
    model = altered_model("extra", lambda m: (m / "extra.json").write_text("{}"))
    assert "extra [\"extra.json\"]" in refused(model)


def test_a_changed_file_is_refused():
    def change(m: Path) -> None:
        small = m / SMALL_FILE
        small.write_text(small.read_text().replace("\n", " \n", 1))
    assert f"{SMALL_FILE} does not match the pin" in refused(altered_model("changed", change))


def test_a_missing_file_is_refused():
    model = altered_model("missing", lambda m: (m / SMALL_FILE).unlink())
    assert f"missing [\"{SMALL_FILE}\"]" in refused(model)


def test_a_linked_file_is_refused():
    def link(m: Path) -> None:
        (m / SMALL_FILE).unlink()
        (m / SMALL_FILE).symlink_to(MODEL / SMALL_FILE)
    assert f"{SMALL_FILE} is not a regular file" in refused(altered_model("linked", link))


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


def test_the_worker_links_no_network_or_server_code():
    imported = set(subprocess.run(["nm", "-u", WORKER], capture_output=True, text=True, check=True).stdout.split())
    assert not imported & {"_socket", "_connect", "_bind", "_listen", "_accept", "_getaddrinfo"}
    symbols = subprocess.run(["nm", "-j", WORKER], capture_output=True, text=True, check=True).stdout
    assert "httplib" not in symbols


NUMBERS_ONLY = [re.compile(p) for p in (
    rf"loaded {NAME}; weights \d+ bytes, Metal allocated \d+ bytes",
    r"rewrite (stop|length): \d+ prompt tokens in [\d.]+ s, \d+ generated in [\d.]+ s; "
    r"context \d+ tokens, Metal allocated \d+ bytes",
    r"rejected a request that is not the daemon's rewrite request",
    r"rewrite cancelled",
)]


def test_the_worker_logs_numbers_only_and_llama_cpp_writes_nothing():
    marker = "Quokka-Zanzibar-7319"
    stream = subprocess.Popen(
        ["/usr/bin/log", "stream", "--level", "info", "--style", "ndjson",
         "--predicate", 'process == "cloak-rewriter-llama"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    # The first line says the stream is filtering; it is listening from then on.
    stream.stdout.readline()
    worker = spawn(WORKER, NAME)
    try:
        assert read_frame(worker.stdout) == (b"Y", b"")
        for body in (request_body(NAME, [f"Please tell {marker} about rivers."], max_tokens=8),
                     request_body("other", [f"Please tell {marker} about rivers."], max_tokens=8)):
            worker.stdin.write(frame(b"R", body))
            worker.stdin.flush()
            answer(read_frame(worker.stdout)[1])
        worker.stdin.write(frame(b"R", request_body(NAME, [f"{marker} " * 3000])))
        worker.stdin.flush()
        time.sleep(0.5)
        worker.stdin.write(frame(b"C"))
        worker.stdin.flush()
        assert answer(read_frame(worker.stdout)[1])[0] == 499
        worker.stdin.close()
        assert worker.wait(timeout=30) == 0
        assert worker.stderr.read() == b""
    finally:
        worker.kill()
        # Lines are delivered a moment after they are written.
        time.sleep(2)
        stream.terminate()
    events = [json.loads(line) for line in stream.stdout if line.startswith("{")]
    assert not [e for e in events if marker in e["eventMessage"]]
    ours = [e["eventMessage"] for e in events if e.get("subsystem") == "sh.regents.cloak"]
    assert len(ours) == 4
    assert all(any(p.fullmatch(line) for p in NUMBERS_ONLY) for line in ours), ours


@pytest.fixture(scope="module")
def daemon_reply(tmp_path_factory) -> Path:
    """The daemon's own reply checks (tests/daemon_reply/main.go), built
    inside the pinned daemon module as guest/build.sh builds its check."""
    out = tmp_path_factory.mktemp("daemon-reply")
    (out / "overlay.json").write_text(json.dumps(
        {"Replace": {str(DAEMON / "cmd/cloak-daemon-reply/main.go"): str(ROOT / "tests/daemon_reply/main.go")}}))
    subprocess.run(["go", "build", "-p", "2", "-trimpath", "-overlay", out / "overlay.json",
                    "-o", out / "cloak-daemon-reply", "./cmd/cloak-daemon-reply"],
                   cwd=DAEMON, env=os.environ | {"CGO_ENABLED": "0"}, check=True)
    return out / "cloak-daemon-reply"


def daemon_accepts(tool: Path, cases: list[tuple[list[str], bytes]]) -> list[bool]:
    """Whether the daemon accepts each reply to a request for these texts."""
    lines = "".join(json.dumps({"texts": texts, "reply": base64.b64encode(reply).decode()}) + "\n"
                    for texts, reply in cases)
    verdicts = subprocess.run([tool], input=lines, capture_output=True, text=True, check=True).stdout.split()
    assert len(verdicts) == len(cases)
    return [verdict == "accepted" for verdict in verdicts]


def rewrites(bodies: list[bytes]) -> list[tuple[int, bytes]]:
    """One worker's answers, as status and raw reply body."""
    worker = spawn(WORKER, NAME)
    try:
        assert read_frame(worker.stdout) == (b"Y", b""), worker.stderr.read().decode()
        out = []
        for body in bodies:
            worker.stdin.write(frame(b"R", body))
            worker.stdin.flush()
            kind, payload = read_frame(worker.stdout)
            assert kind == b"A"
            out.append((int.from_bytes(payload[:2], "big"), payload[2:]))
        worker.stdin.close()
        assert worker.wait(timeout=30) == 0
    finally:
        worker.kill()
    return out


def generated(reply: bytes) -> tuple[bytes, str, int]:
    """What the model generated: the text, byte for byte, how it ended and
    its token count."""
    body = json.loads(reply)
    [choice] = body["choices"]
    return choice["message"]["content"].encode(), choice["finish_reason"], body["usage"]["completion_tokens"]


def test_the_daemon_accepts_the_reply_to_a_turn_it_once_refused(daemon_reply):
    """The last user turn of EVAL05's four-turn conversation, which the
    daemon rewrites as one text: decoded without the grammar, the
    stand-in's reply split it into two texts and the daemon refused it
    (evidence/stage3/standin-gguf/). Under the grammar the reply holds one."""
    history = json.loads((ROOT / "reference/eval05-inputs.json").read_text())["history"]["messages"]
    texts = [[m["content"] for m in history if m["role"] == "user"][-1]]
    [(status, reply)] = rewrites([request_body(NAME, texts)])
    assert status == 200
    assert daemon_accepts(daemon_reply, [(texts, reply)]) == [True]


@pytest.fixture(scope="module")
def eval06_answers() -> tuple[list[list[str]], list[tuple[int, bytes]]]:
    """Every EVAL06 message, one text each, and the worker's answer to each,
    at the daemon's max_tokens."""
    texts = [[m["text"]] for m in EVAL06]
    return texts, rewrites([request_body(NAME, t) for t in texts])


def test_the_daemon_accepts_every_reply_the_model_ended_and_only_those(daemon_reply, eval06_answers):
    """Every EVAL06 message, at the daemon's max_tokens."""
    texts, answers = eval06_answers
    assert {status for status, _ in answers} == {200}
    accepted = daemon_accepts(daemon_reply, [(t, reply) for t, (_, reply) in zip(texts, answers)])
    assert accepted == [generated(reply)[1] == "stop" for _, reply in answers]
    print(f"EVAL06, {len(texts)} messages: the daemon accepts {sum(accepted)} replies")


def test_a_reply_holds_as_many_texts_as_the_request(daemon_reply):
    texts = ["first: what is a river delta", "second, please list three tall mountains", "third, thanks so much!!"]
    [(status, reply)] = rewrites([request_body(NAME, texts)])
    assert (status, generated(reply)[1]) == (200, "stop")
    assert len(json.loads(generated(reply)[0])["texts"]) == 3
    assert daemon_accepts(daemon_reply, [(texts, reply)]) == [True]


def outside_strings(content: bytes) -> bytes:
    """A JSON text without its strings: the bytes outside them, quotes
    left out."""
    out, inside, escaped = bytearray(), False, False
    for byte in content:
        if escaped:
            escaped = False
        elif inside and byte == ord("\\"):
            escaped = True
        elif byte == ord('"'):
            inside = not inside
        elif not inside:
            out.append(byte)
    return bytes(out)


def test_white_space_between_tokens_never_runs_on(eval06_answers):
    """Outside its strings a reply is {"texts":[...]}'s braces, colon,
    brackets and commas, with at most 16 white space characters between any
    two of them, so white space there cannot repeat without end (in the 9B's
    first run under the grammar, e06-37 wrote white space between tokens
    until its deadline, and the stand-in's e06-10 did so after its text). A
    reply cut at max_tokens is a start of that form. Every EVAL06 message,
    and texts that ask for white space."""
    texts, answers = eval06_answers
    several = ["first text", "second text\nwith a newline", "  leading and trailing spaces  ", "tabs\tand\r\nlines"]
    texts, answers = texts + [several], answers + rewrites([request_body(NAME, several)])
    for sent, (status, reply) in zip(texts, answers):
        content, finish, _ = generated(reply)
        outside = outside_strings(content)
        tokens = re.sub(rb"[ \t\n\r]", b"", outside)
        form = b"{:[" + b"," * (len(sent) - 1) + b"]}"
        assert status == 200
        assert all(len(run) <= 16 for run in re.findall(rb"[ \t\n\r]+", outside)), content
        if finish == "stop":
            assert tokens == form, content
        else:
            assert form.startswith(tokens), content


def test_a_user_message_without_texts_is_refused():
    """The grammar's count of texts comes from the user message; one that is
    not the daemon's {"texts":[...]} with a text gives none."""
    users = ['{"texts":[]}', '{"texts":["a"],"more":["b"]}', '{"Texts":["a"]}', '{"texts":"a"}', '{"texts":[1]}',
             '"a"', "hello"]

    def body(user: str) -> bytes:
        request = json.loads(request_body(NAME, ["x"], max_tokens=2))
        request["messages"][1]["content"] = user
        return go_json(request).encode()

    refused = rewrites([body(user) for user in users])
    assert [(status, json.loads(reply)) for status, reply in refused] == \
        [(400, {"error": {"message": "invalid request"}})] * len(users)
