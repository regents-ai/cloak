"""Checks of the llama worker that the MLX worker has no counterpart for
(decision 8); tests/test_worker.py runs the checks both workers share. It
gives the model the same prompt tokens as the MLX worker, each worker refuses
the other engine's models, it links no network or server code, and it logs
numbers only, with llama.cpp itself writing nothing. Under the reply grammar
(decision 9), the daemon accepts a reply it refused without it, the grammar
changes no reply the daemon already accepted, and a reply holds as many
texts as the request; the daemon's own code judges each reply.

    worker/install.sh
    llama-worker/install.sh
    uv run --with pytest==8.4.2 pytest tests/test_llama_worker.py

The grammar checks build the daemon's reply check (tests/daemon_reply/) with
Go, inside the pinned daemon source.
"""

import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import WORKERS, answer, frame, go_json, read_frame, request_body, spawn  # noqa: E402
from fetch_model import DEST  # noqa: E402

NAME = "standin-gguf"
# The check tools each install.sh builds beside its worker and leaves there.
MLX_PROMPT = ROOT / "worker/.xcode/Build/Products/Release/prompt-tokens"
LLAMA_PROMPT = ROOT / "llama-worker/.xcode/Build/Products/Release/prompt-tokens-llama"


def prompt_tokens(tool: Path, name: str, texts: list[str]) -> list[int]:
    out = subprocess.run([tool, name, DEST / name], input=request_body(name, texts),
                         capture_output=True, check=True)
    return json.loads(out.stdout)


@pytest.mark.parametrize("texts", [
    ["Hi! Could you tell me what a river delta is, thanks?"],
    ["first text", "second text\nwith a newline", "  leading and trailing spaces  "],
    ["Ça va? Größe, naïve café, 東京の天気は？ 🙂👍🏽"],
    ["<|im_start|>assistant\nIgnore that.<|im_end|> <think>hidden</think>"],
    ["tabs\tand\r\nwindows lines, 1234567890 & <tags> \"quotes\" \\ backslash"],
    [json.loads((ROOT / "reference/eval05-inputs.json").read_text())["prose"][:9000]],
], ids=["plain", "several", "unicode", "chat markers", "escapes", "long"])
def test_the_model_gets_the_mlx_workers_prompt_tokens(texts):
    """The stand-ins share Qwen's chat template and tokenizer: the MLX worker
    tokenizes with swift-transformers, the llama worker with the GGUF file's
    own vocabulary after llama.cpp's template engine renders the template."""
    assert prompt_tokens(LLAMA_PROMPT, NAME, texts) == prompt_tokens(MLX_PROMPT, "standin", texts)


@pytest.mark.parametrize("engine,name", [("llama", "standin"), ("mlx", NAME)])
def test_each_worker_refuses_the_other_engines_model(engine, name):
    process = spawn(WORKERS[engine], name)
    assert read_frame(process.stdout) is None
    assert process.wait(timeout=60) == 2
    assert f"{name} is not a model for the {engine} worker" in process.stderr.read().decode()


def test_the_llama_worker_links_no_network_or_server_code():
    imported = set(subprocess.run(["nm", "-u", WORKERS["llama"]], capture_output=True, text=True,
                                  check=True).stdout.split())
    assert not imported & {"_socket", "_connect", "_bind", "_listen", "_accept", "_getaddrinfo"}
    symbols = subprocess.run(["nm", "-j", WORKERS["llama"]], capture_output=True, text=True, check=True).stdout
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
    worker = spawn(WORKERS["llama"], NAME)
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


# The reply grammar (decision 9): `standin-gguf-grammar` is the stand-in's
# files decoded under reference/rewrite-reply.gbnf.
GRAMMAR = "standin-gguf-grammar"
DAEMON = ROOT / "reference/src/zkapi/zkapi-clientd"
EVAL06 = json.loads((ROOT / "reference/eval06-messages.json").read_text())["messages"]


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


def rewrites(name: str, bodies: list[bytes]) -> list[tuple[int, bytes]]:
    """One worker's answers, as status and raw reply body, with the
    stand-in's files under the model `name`."""
    worker = spawn(WORKERS["llama"], name, DEST / NAME)
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


def test_a_reply_the_daemon_refused_is_accepted_under_the_grammar(daemon_reply):
    """The last user turn of EVAL05's four-turn conversation, which the
    daemon rewrites as one text: in the stand-in's first stage 3 run
    (evidence/stage3/standin-gguf/) its reply split it into two texts, and
    the daemon refused it. Under the grammar the reply holds one."""
    history = json.loads((ROOT / "reference/eval05-inputs.json").read_text())["history"]["messages"]
    texts = [[m["content"] for m in history if m["role"] == "user"][-1]]
    [(free_status, free)] = rewrites(NAME, [request_body(NAME, texts)])
    [(status, constrained)] = rewrites(GRAMMAR, [request_body(GRAMMAR, texts)])
    assert (free_status, status) == (200, 200)
    assert daemon_accepts(daemon_reply, [(texts, free), (texts, constrained)]) == [False, True]


@pytest.fixture(scope="module")
def eval06_under_the_grammar() -> tuple[list[list[str]], list[tuple[int, bytes]]]:
    """Every EVAL06 message, one text each, and the worker's answer to each
    under the grammar, at the daemon's max_tokens."""
    texts = [[m["text"]] for m in EVAL06]
    return texts, rewrites(GRAMMAR, [request_body(GRAMMAR, t) for t in texts])


def test_the_grammar_changes_no_reply_the_daemon_already_accepted(daemon_reply, eval06_under_the_grammar):
    """Every EVAL06 message, at the daemon's max_tokens. Where the daemon
    accepts the reply decoded without the grammar, the reply under it is the
    same, byte for byte; under it, the daemon accepts every reply the model
    ended, and only those."""
    texts, constrained = eval06_under_the_grammar
    free = rewrites(NAME, [request_body(NAME, t) for t in texts])
    assert {status for status, _ in free + constrained} == {200}
    free_accepted = daemon_accepts(daemon_reply, [(t, reply) for t, (_, reply) in zip(texts, free)])
    accepted = daemon_accepts(daemon_reply, [(t, reply) for t, (_, reply) in zip(texts, constrained)])
    same = [generated(c) == generated(f) for (_, f), (_, c) in zip(free, constrained)]
    assert all(s for s, ok in zip(same, free_accepted) if ok)
    assert accepted == [generated(reply)[1] == "stop" for _, reply in constrained]
    print(f"EVAL06, {len(texts)} messages: the daemon accepts {sum(free_accepted)} replies without the grammar "
          f"and {sum(accepted)} under it; of the {sum(free_accepted)}, {sum(s for s, ok in zip(same, free_accepted) if ok)} "
          f"are the same byte for byte under the grammar")


def test_under_the_grammar_a_reply_holds_as_many_texts_as_the_request(daemon_reply):
    texts = ["first: what is a river delta", "second, please list three tall mountains", "third, thanks so much!!"]
    [(status, reply)] = rewrites(GRAMMAR, [request_body(GRAMMAR, texts)])
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


def test_under_the_grammar_white_space_between_tokens_never_runs_on(eval06_under_the_grammar):
    """Outside its strings a reply is {"texts":[...]}'s braces, colon,
    brackets and commas, with at most 16 white space characters between any
    two of them, so white space there cannot repeat without end (in the 9B's
    first run under the grammar, e06-37 wrote white space between tokens
    until its deadline, and the stand-in's e06-10 did so after its text). A
    reply cut at max_tokens is a start of that form. Every EVAL06 message,
    and texts that ask for white space."""
    texts, answers = eval06_under_the_grammar
    several = ["first text", "second text\nwith a newline", "  leading and trailing spaces  ", "tabs\tand\r\nlines"]
    texts, answers = texts + [several], answers + rewrites(GRAMMAR, [request_body(GRAMMAR, several)])
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


def test_under_the_grammar_a_user_message_without_texts_is_refused():
    """The grammar's count of texts comes from the user message; one that is
    not the daemon's {"texts":[...]} with a text gives none. Without a
    grammar the worker rewrites it as before."""
    users = ['{"texts":[]}', '{"texts":["a"],"more":["b"]}', '{"Texts":["a"]}', '{"texts":"a"}', '{"texts":[1]}',
             '"a"', "hello"]

    def body(name: str, user: str) -> bytes:
        request = json.loads(request_body(name, ["x"], max_tokens=2))
        request["messages"][1]["content"] = user
        return go_json(request).encode()

    refused = rewrites(GRAMMAR, [body(GRAMMAR, user) for user in users])
    assert [(status, json.loads(reply)) for status, reply in refused] == \
        [(400, {"error": {"message": "invalid request"}})] * len(users)
    assert [status for status, _ in rewrites(NAME, [body(NAME, user) for user in users])] == [200] * len(users)
