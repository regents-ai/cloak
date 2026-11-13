"""Checks of the llama worker that the MLX worker has no counterpart for
(decision 8); tests/test_worker.py runs the checks both workers share. It
gives the model the same prompt tokens as the MLX worker, each worker refuses
the other engine's models, it links no network or server code, and it logs
numbers only, with llama.cpp itself writing nothing.

    worker/install.sh
    llama-worker/install.sh
    uv run --with pytest==8.4.2 pytest tests/test_llama_worker.py
"""

import json
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import WORKERS, answer, frame, read_frame, request_body, spawn  # noqa: E402
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
