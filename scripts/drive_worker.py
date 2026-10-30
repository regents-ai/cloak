# /// script
# requires-python = ">=3.12"
# ///
"""Run the native worker directly and send it the daemon's rewrite request.

A development check of the worker on its own, before the guest and daemon are
in the path. The request is built the way the daemon builds it: the system
message is read from the pinned daemon source and must match the recorded
sha256, and the user message is Go-style JSON.

    uv run scripts/drive_worker.py --name standin "text one" "text two"
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

# Where worker/install.sh puts the signed, sandboxed worker.
INSTALLED = DEST.parent / "worker" / "cloak-rewriter"

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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", default=INSTALLED)
    parser.add_argument("--name", required=True)
    parser.add_argument("--max-tokens", type=int, default=16384)
    parser.add_argument("texts", nargs="+")
    args = parser.parse_args()

    worker = spawn(args.worker, args.name)
    started = time.monotonic()
    if read_frame(worker.stdout) != (b"Y", b""):
        raise SystemExit(f"worker did not become ready: {worker.stderr.read().decode()}")
    print(f"ready after {time.monotonic() - started:.1f} s")

    started = time.monotonic()
    worker.stdin.write(frame(b"R", request_body(args.name, args.texts, args.max_tokens)))
    worker.stdin.flush()
    kind, payload = read_frame(worker.stdout)
    status, reply = answer(payload)
    print(f"answer {kind!r} status {status} after {time.monotonic() - started:.1f} s")
    print(json.dumps(reply, indent=2, ensure_ascii=False))
    worker.stdin.close()
    worker.wait()


if __name__ == "__main__":
    main()
