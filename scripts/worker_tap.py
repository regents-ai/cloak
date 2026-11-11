"""A copy-only tap between the host and the native worker, for the stage 3
kit. The host starts it in place of the worker; it starts the real, sandboxed
worker with the same arguments and copies every frame both ways unchanged,
noting each one with its time in an events file. That is how the kit keeps
each call's raw reply and the worker's own timing without changing the host,
the worker or their frames (worker/Sources/cloak-rewriter/Frames.swift).

    worker_tap.py <events file> <worker> <worker arguments...>

Each line of the events file is JSON with `t`, nanoseconds on the system's
CLOCK_MONOTONIC_RAW (the clock the unified log's mach timestamps use, which
keeps counting while the Mac sleeps), and `kind`: `spawn` (the worker's and
the tap's pids), `in` (a frame from the host), `out` (a frame from the
worker), `exit` (the worker's exit status) or `terminated`.
A frame's payload is kept whole: as text when it is UTF-8, otherwise in base64.

The worker's life is the tap's: when the worker exits, the tap closes its
output and exits, so the host sees the loss; when the host closes the tap's
input, the tap closes the worker's; when the host terminates the tap, the tap
terminates the worker.
"""

import base64
import json
import os
import signal
import struct
import subprocess
import sys
import threading
import time


def clock() -> int:
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)


def read_frame(stream) -> tuple[bytes, bytes, bytes] | None:
    """(kind, header, payload), or None at the end of the stream."""
    header = stream.read(5)
    if len(header) < 5:
        return None
    (length,) = struct.unpack(">I", header[1:])
    payload = stream.read(length)
    if len(payload) < length:
        return None
    return header[:1], header, payload


def payload_fields(payload: bytes) -> dict:
    try:
        return {"text": payload.decode("utf-8")}
    except UnicodeDecodeError:
        return {"base64": base64.b64encode(payload).decode("ascii")}


def main() -> None:
    events_path, worker, *arguments = sys.argv[1:]
    events = open(events_path, "ab", buffering=0)
    lock = threading.Lock()

    def note(kind: str, **fields) -> None:
        line = (json.dumps({"t": clock(), "kind": kind, **fields}) + "\n").encode()
        with lock:
            events.write(line)

    process = subprocess.Popen([worker, *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    note("spawn", pid=process.pid, tap=os.getpid())

    def terminated(signum, frame) -> None:
        note("terminated")
        process.terminate()
        os._exit(143)

    signal.signal(signal.SIGTERM, terminated)
    host_in, host_out = sys.stdin.buffer, sys.stdout.buffer

    def to_worker() -> None:
        while frame := read_frame(host_in):
            kind, header, payload = frame
            note("in", frame=kind.decode("latin-1"), bytes=len(payload), **payload_fields(payload))
            try:
                process.stdin.write(header + payload)
                process.stdin.flush()
            except BrokenPipeError:
                return
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass

    threading.Thread(target=to_worker, daemon=True).start()
    while frame := read_frame(process.stdout):
        kind, header, payload = frame
        fields = {}
        if kind == b"A":
            (status,) = struct.unpack(">H", payload[:2])
            fields = {"status": status, **payload_fields(payload[2:])}
        note("out", frame=kind.decode("latin-1"), bytes=len(payload), **fields)
        try:
            host_out.write(header + payload)
            host_out.flush()
        except BrokenPipeError:
            break
    status = process.wait()
    note("exit", status=status)
    os._exit(0)


if __name__ == "__main__":
    main()
