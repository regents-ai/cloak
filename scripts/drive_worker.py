# /// script
# requires-python = ">=3.12"
# ///
"""Run the native worker directly and send it the daemon's rewrite request, or
a Local Llama conversation.

A development check of the worker on its own, before the guest and daemon are
in the path. The rewrite request is built the way the daemon builds it: the
system message is read from the pinned daemon source and must match the
recorded sha256, and the user message is Go-style JSON.

    uv run scripts/drive_worker.py --name standin-gguf-grammar "text one" "text two"

With --chat, each text is a message of one Local Llama chat, sent as the app
sends it: the conversation so far, each earlier answer included, in an L
frame. --stop-after stops the first answer that many seconds after it is
asked, as Stop does, then asks it again. --worker runs another build of the
worker, such as a check copy.

    uv run scripts/drive_worker.py --name small-lead-gguf-grammar --chat "first message" "second message"
"""

import argparse
import hashlib
import json
import re
import struct
import subprocess
import time
from pathlib import Path

from fetch_model import DEST

# Where llama-worker/install.sh puts the signed, sandboxed worker.
WORKER = DEST.parent / "worker" / "cloak-rewriter-llama"

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "reference/src/zkapi/zkapi-clientd/internal/rewriter/rewriter.go"
SYSTEM_SHA256 = "c95de591e464e6215df0544b7ef03486326ba45f095ea055d2f86e6daf91724b"


def system_message() -> str:
    source = SOURCE.read_text()
    instruction = re.search(r"const DefaultInstruction = `([^`]*)`", source)[1]
    contract = re.search(r"const responseContract = `([^`]*)`", source)[1]
    message = instruction + "\n\n" + contract
    if hashlib.sha256(message.encode()).hexdigest() != SYSTEM_SHA256:
        raise SystemExit("system message does not match the captured contract")
    return message


def go_json(value) -> str:
    """json.Marshal output: compact, non-ASCII kept, <, > and & escaped."""
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    for ch, esc in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), (" ", "\\u2028"), (" ", "\\u2029")):
        text = text.replace(ch, esc)
    return text


def request_body(name: str, texts: list[str], max_tokens: int = 16384) -> bytes:
    """The daemon's rewrite request for these texts, byte for byte."""
    return go_json({
        "max_tokens": max_tokens,
        "messages": [
            {"content": system_message(), "role": "system"},
            {"content": go_json({"texts": texts}), "role": "user"},
        ],
        "model": name,
        "stream": False,
        "temperature": 0,
    }).encode()


def conversation_body(messages: list[str]) -> bytes:
    """A Local Llama chat's request: the messages alternate user and
    assistant, the first and last from the user."""
    roles = ["user", "assistant"]
    return json.dumps(
        {"messages": [{"role": roles[i % 2], "content": text} for i, text in enumerate(messages)]},
        ensure_ascii=False).encode()


def frame(kind: bytes, payload: bytes = b"") -> bytes:
    return kind + struct.pack(">I", len(payload)) + payload


def read_frame(stream) -> tuple[bytes, bytes] | None:
    """The next frame, or None when the worker closed its channel."""
    header = stream.read(5)
    if len(header) != 5:
        return None
    (length,) = struct.unpack(">I", header[1:])
    return header[:1], stream.read(length)


def spawn(worker: str | Path, name: str, directory: Path | None = None) -> subprocess.Popen:
    return subprocess.Popen(
        [worker, "--name", name, "--dir", directory or DEST / name],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def answer(payload: bytes) -> tuple[int, dict]:
    (status,) = struct.unpack(">H", payload[:2])
    return status, json.loads(payload[2:])


def ask(worker: subprocess.Popen, kind: bytes, body: bytes, stop_after: float | None = None) -> tuple[int, dict]:
    """Sends one request and reads its answer; with stop_after, sends a cancel
    that many seconds after the request."""
    started = time.monotonic()
    worker.stdin.write(frame(kind, body))
    worker.stdin.flush()
    if stop_after is not None:
        time.sleep(stop_after)
        worker.stdin.write(frame(b"C"))
        worker.stdin.flush()
        print(f"stop sent after {stop_after:.1f} s")
    answered = read_frame(worker.stdout)
    if answered is None:
        raise SystemExit(f"worker ended: {worker.stderr.read().decode()}")
    status, reply = answer(answered[1])
    print(f"answer {answered[0]!r} status {status} after {time.monotonic() - started:.1f} s")
    return status, reply


def chat(worker: subprocess.Popen, messages: list[str], stop_after: float | None) -> None:
    """One Local Llama chat: each message asked with the conversation so far."""
    conversation: list[str] = []
    for number, message in enumerate(messages, start=1):
        conversation.append(message)
        print(f"\nmessage {number}: {message}")
        status, reply = ask(worker, b"L", conversation_body(conversation), stop_after if number == 1 else None)
        if status == 499:
            print("stopped; asking it again")
            status, reply = ask(worker, b"L", conversation_body(conversation))
        if status != 200:
            raise SystemExit(json.dumps(reply, ensure_ascii=False))
        text = reply["choices"][0]["message"]["content"]
        print(f"finish {reply['choices'][0]['finish_reason']}, usage {reply['usage']}")
        print(f"answer {number}: {text}")
        conversation.append(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--worker", type=Path, default=WORKER)
    parser.add_argument("--max-tokens", type=int, default=16384)
    parser.add_argument("--chat", action="store_true", help="send the texts as the messages of one Local Llama chat")
    parser.add_argument("--stop-after", type=float, help="with --chat, stop the first answer after this many seconds")
    parser.add_argument("texts", nargs="+")
    args = parser.parse_args()

    worker = spawn(args.worker, args.name)
    print(f"worker pid {worker.pid}")
    started = time.monotonic()
    if read_frame(worker.stdout) != (b"Y", b""):
        raise SystemExit(f"worker did not become ready: {worker.stderr.read().decode()}")
    print(f"ready after {time.monotonic() - started:.1f} s")

    if args.chat:
        chat(worker, args.texts, args.stop_after)
    else:
        _, reply = ask(worker, b"R", request_body(args.name, args.texts, args.max_tokens))
        print(json.dumps(reply, indent=2, ensure_ascii=False))
    worker.stdin.close()
    worker.wait()


if __name__ == "__main__":
    main()
