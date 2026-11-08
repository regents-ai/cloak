"""A stand-in for the native worker that answers each rewrite with a chosen
fault, for the guest path checks. It speaks the worker's frames and picks its
behaviour from the first text, "case:<name> ...". Every request body it
receives is saved to FAKE_WORKER_LOG/<n>.json, and every cancel it receives is
noted as FAKE_WORKER_LOG/<n>.cancel. It leaves each request unread for
FAKE_WORKER_READ_DELAY seconds once it starts arriving, so a check can have a
client give up while the host is still handing the request over. Like the
real worker, it ignores a cancel that arrives after its answer.

The host starts it in place of the worker, through the launcher the checks
write, with the worker's arguments, which it ignores.
"""

import json
import os
import select
import struct
import sys
import time
from pathlib import Path

LOG = Path(os.environ["FAKE_WORKER_LOG"])
READ_DELAY = float(os.environ["FAKE_WORKER_READ_DELAY"])
# Unbuffered input, so a select on it sees every frame that has arrived.
IN, OUT = sys.stdin.buffer.raw, sys.stdout.buffer


def send(kind: bytes, payload: bytes = b"") -> None:
    OUT.write(kind + struct.pack(">I", len(payload)) + payload)
    OUT.flush()


def answer(status: int, body: bytes) -> None:
    send(b"A", struct.pack(">H", status) + body)


def read_exactly(count: int) -> bytes:
    data = b""
    while len(data) < count and (block := IN.read(count - len(data))):
        data += block
    return data


def read_frame() -> tuple[bytes, bytes] | None:
    header = read_exactly(5)
    if len(header) < 5:
        return None
    (length,) = struct.unpack(">I", header[1:])
    return header[:1], read_exactly(length)


def completion(content: str, finish: str = "stop", **message) -> bytes:
    return json.dumps({
        "object": "chat.completion",
        "choices": [{"index": 0, "finish_reason": finish,
                     "message": {"role": "assistant", "content": content} | message}],
    }).encode()


def wait_for_cancel(seconds: float) -> bool:
    if select.select([IN], [], [], seconds)[0]:
        frame = read_frame()
        return frame is not None and frame[0] == b"C"
    return False


def next_request() -> tuple[bytes, bytes] | None:
    if READ_DELAY:
        select.select([IN], [], [])
        time.sleep(READ_DELAY)
    return read_frame()


def main() -> None:
    send(b"Y")
    count = 0
    while frame := next_request():
        kind, body = frame
        if kind == b"C":
            continue
        count += 1
        (LOG / f"{count}.json").write_bytes(body)
        texts = json.loads(json.loads(body)["messages"][1]["content"])["texts"]
        case = texts[0].split()[0].removeprefix("case:")
        rewritten = [t.upper() for t in texts]
        match case:
            case "ok":
                answer(200, completion(json.dumps({"texts": rewritten})))
            case "fenced":
                answer(200, completion("```json\n" + json.dumps({"texts": rewritten}) + "\n```"))
            case "extra-field":
                answer(200, completion(json.dumps({"texts": rewritten, "note": "x"})))
            case "wrong-count":
                answer(200, completion(json.dumps({"texts": rewritten + ["more"]})))
            case "length":
                answer(200, completion(json.dumps({"texts": rewritten}), finish="length"))
            case "tool-call":
                answer(200, completion(json.dumps({"texts": rewritten}),
                                       tool_calls=[{"id": "1", "type": "function", "function": {"name": "f", "arguments": "{}"}}]))
            case "refusal":
                answer(200, completion(json.dumps({"texts": rewritten}), refusal="no"))
            case "status-500":
                answer(500, b'{"error":{"message":"rewrite failed"}}')
            case "not-json":
                answer(200, b"not json")
            case "oversized":
                answer(200, completion(json.dumps({"texts": rewritten}) + " " * (1 << 20)))
            case "hold":
                # Waits for the cancel the daemon's deadline or a client causes.
                if wait_for_cancel(120):
                    (LOG / f"{count}.cancel").touch()
                answer(499, b'{"error":{"message":"cancelled"}}')
            case "exit":
                time.sleep(0.5)
                sys.exit(3)
            case "exit-after-answer":
                # Gone between rewrites: its input is closed before it answers,
                # so the host's next request meets a closed channel.
                os.close(IN.fileno())
                answer(200, completion(json.dumps({"texts": rewritten})))
                sys.exit(3)


if __name__ == "__main__":
    main()
