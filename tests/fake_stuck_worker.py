"""A stand-in for the native worker that, the first time it is started,
breaks the protocol and then cannot be stopped, for the bounded-stop check.

The first one started answers its first request with a frame that is not an
answer, so the host loses it, then ignores being asked to stop and never
exits by itself: only a kill ends it. Every later one answers each request
with its texts in capitals. Each start and the moment the first one broke are
noted, with the process and the system's monotonic clock, as JSON lines in
FAKE_WORKER_LOG/events.jsonl.

The host starts it in place of the worker, through the launcher the check
writes, with the worker's arguments, which it ignores.
"""

import json
import os
import signal
import struct
import sys
import time
from pathlib import Path

LOG = Path(os.environ["FAKE_WORKER_LOG"]) / "events.jsonl"
IN, OUT = sys.stdin.buffer.raw, sys.stdout.buffer


def note(event: str) -> None:
    with LOG.open("a") as log:
        log.write(json.dumps({"event": event, "pid": os.getpid(), "at": time.monotonic()}) + "\n")


def send(kind: bytes, payload: bytes = b"") -> None:
    OUT.write(kind + struct.pack(">I", len(payload)) + payload)
    OUT.flush()


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


def main() -> None:
    first = not LOG.exists()
    note("start")
    send(b"Y")
    while frame := read_frame():
        kind, body = frame
        if kind == b"C":
            continue
        if first:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            note("stuck")
            send(b"X")
            while True:
                time.sleep(3600)
        texts = json.loads(json.loads(body)["messages"][1]["content"])["texts"]
        content = json.dumps({"texts": [t.upper() for t in texts]})
        completion = json.dumps({"object": "chat.completion", "choices": [{
            "index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": content}}]})
        send(b"A", struct.pack(">H", 200) + completion.encode())


if __name__ == "__main__":
    main()
