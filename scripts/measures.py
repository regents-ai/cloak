"""The stage 3 kit's arithmetic: rebuilding calls from the tap's events,
matching them to the cases that made them, naming why a case stopped,
percentiles that keep stopped calls in the denominator, and figures over the
resource samples. No input or output here; `stage3.py` runs the path.

The daemon's limits are its own (reference/rewriter-contract.md): a newest
user turn of at most 128 KiB of text, 16,384 tokens and 90 seconds per call.
Nothing here lowers or truncates them.
"""

import json
import math
import re
from dataclasses import dataclass, field

MAX_TEXT = 128 << 10
DEADLINE_S = 90
TARGET_P50_S = 5
TARGET_P95_S = 15

STOP_REASONS = (
    "over the input limit",  # the daemon refused the input before any call
    "malformed",  # a reply came back and the daemon refused its content
    "truncated",  # the reply ended at the token limit
    "worker error",  # the worker answered with an error status
    "timed out",  # the daemon's 90-second deadline cancelled the call
    "cancelled",  # the client gave up on purpose (the cancellation check)
    "worker lost",  # the worker was gone, or went, before it answered
    "no result",  # the boot ended before the daemon reported the case
)


@dataclass
class Call:
    """One rewrite request as the worker saw it, from the tap's events."""

    sent_ns: int
    request: str
    cancels_ns: list[int] = field(default_factory=list)
    answered_ns: int | None = None
    status: int | None = None
    reply: str | None = None
    reply_base64: str | None = None

    @property
    def texts(self) -> list[str]:
        """The texts the daemon asked the rewriter to rewrite."""
        user = json.loads(self.request)["messages"][1]["content"]
        return json.loads(user)["texts"]

    @property
    def worker_seconds(self) -> float | None:
        return None if self.answered_ns is None else (self.answered_ns - self.sent_ns) / 1e9

    @property
    def finish_reason(self) -> str | None:
        if self.status != 200 or self.reply is None:
            return None
        return json.loads(self.reply)["choices"][0]["finish_reason"]


@dataclass
class Worker:
    """The worker's life in one boot, from the tap's events."""

    spawn_ns: int
    pid: int
    tap_pid: int
    ready_ns: int | None
    exit_ns: int | None
    exit_status: int | None
    calls: list[Call]
    cancels_after_answer: int

    @property
    def load_seconds(self) -> float | None:
        return None if self.ready_ns is None else (self.ready_ns - self.spawn_ns) / 1e9


def worker_from_events(events: list[dict]) -> Worker:
    """Rebuilds the worker's calls. A cancel that arrives with no call open is
    one that crossed the answer; it is counted, as the worker ignores it."""
    spawn = next(e for e in events if e["kind"] == "spawn")
    calls: list[Call] = []
    open_call: Call | None = None
    ready = exit_ns = exit_status = None
    crossing = 0
    for e in events:
        if e["kind"] == "in" and e["frame"] == "R":
            open_call = Call(sent_ns=e["t"], request=e["text"])
            calls.append(open_call)
        elif e["kind"] == "in" and e["frame"] == "C":
            if open_call is None:
                crossing += 1
            else:
                open_call.cancels_ns.append(e["t"])
        elif e["kind"] == "out" and e["frame"] == "Y":
            ready = e["t"]
        elif e["kind"] == "out" and e["frame"] == "A":
            open_call.answered_ns, open_call.status = e["t"], e["status"]
            open_call.reply, open_call.reply_base64 = e.get("text"), e.get("base64")
            open_call = None
        elif e["kind"] == "exit":
            exit_ns, exit_status = e["t"], e["status"]
    return Worker(spawn_ns=spawn["t"], pid=spawn["pid"], tap_pid=spawn["tap"], ready_ns=ready,
                  exit_ns=exit_ns, exit_status=exit_status, calls=calls, cancels_after_answer=crossing)


def expected_texts(body: dict) -> list[list[str]]:
    """The rewriter calls the daemon makes for this client request with a
    fresh transcript (no saved rewrites): one per user turn with text, in
    order, each carrying that turn alone, until a turn over the input limit
    stops the rewrite before its call. The kit sends plain string content."""
    calls = []
    for message in body["messages"]:
        if message["role"] != "user":
            continue
        text = message["content"]
        if not isinstance(text, str):
            raise ValueError("the kit sends only plain string content")
        if not text.strip():
            continue
        if len(text.encode()) > MAX_TEXT:
            break
        calls.append([text])
    return calls


def over_limit(body: dict) -> bool:
    return any(m["role"] == "user" and len(m["content"].encode()) > MAX_TEXT for m in body["messages"])


def attribute(bodies: list[dict], calls: list[Call]) -> list[list[Call]]:
    """Splits one boot's calls among its cases, in order. A case takes the
    next calls while they carry the texts it is expected to send; one that
    sent fewer (the worker was lost, so the host refused it) takes fewer."""
    out, position = [], 0
    for body in bodies:
        taken = []
        for texts in expected_texts(body):
            if position < len(calls) and calls[position].texts == texts:
                taken.append(calls[position])
                position += 1
            else:
                break
        out.append(taken)
    if position != len(calls):
        raise ValueError(f"{len(calls) - position} calls match no case")
    return out


def stop_reason(outcome: str | None, body: dict, calls: list[Call], cancel_after_ms: int) -> str | None:
    """Why a case stopped, from what the worker saw; None when it was
    rewritten. The daemon itself reports only that the rewrite failed, and
    nothing at all for a case the boot never reached (outcome None)."""
    if outcome == "rewritten":
        return None
    if outcome is None:
        return "no result"
    if not calls:
        return "over the input limit" if over_limit(body) else "worker lost"
    last = calls[-1]
    if last.answered_ns is None:
        return "worker lost"
    if last.cancels_ns:
        return "cancelled" if cancel_after_ms > 0 else "timed out"
    if last.status != 200:
        return "worker error"
    if last.finish_reason == "length":
        return "truncated"
    return "malformed"


def percentile(seconds: list[float | None], p: float) -> float | None:
    """Nearest-rank percentile (no interpolation). A stopped call is None and
    counts as slower than any finished call, so it stays in the denominator:
    when the rank falls on one, there is no figure to report (None)."""
    if not seconds:
        raise ValueError("no calls")
    ordered = sorted(seconds, key=lambda s: math.inf if s is None else s)
    return ordered[max(1, math.ceil(p / 100 * len(ordered))) - 1]


def latency(cases: list[dict]) -> dict:
    """Latency over cases that each carry `seconds` (as the daemon timed the
    rewrite) and `stop_reason`. Every case is in the denominator."""
    finished = [None if c["stop_reason"] else c["seconds"] for c in cases]
    reasons = {r: sum(c["stop_reason"] == r for c in cases) for r in STOP_REASONS}
    p50, p95 = percentile(finished, 50), percentile(finished, 95)
    done = [s for s in finished if s is not None]
    return {
        "cases": len(cases),
        "rewritten": len(done),
        "stopped": sum(reasons.values()),
        "stopped_by_reason": {r: n for r, n in reasons.items() if n},
        "p50_seconds": p50,
        "p95_seconds": p95,
        "slowest_rewritten_seconds": max(done) if done else None,
        "all_elapsed_p50_seconds": percentile([c["seconds"] for c in cases], 50),
        "all_elapsed_p95_seconds": percentile([c["seconds"] for c in cases], 95),
    }


def meets_targets(summary: dict) -> bool:
    """EVAL06's proposed targets: p50 at most 5 s and p95 at most 15 s."""
    p50, p95 = summary["p50_seconds"], summary["p95_seconds"]
    return p50 is not None and p95 is not None and p50 <= TARGET_P50_S and p95 <= TARGET_P95_S


def band(tokens: int) -> str:
    return "1-128" if tokens <= 128 else "129-256" if tokens <= 256 else "257-512"


def nearest(samples: list[dict], t: int) -> dict:
    return min(samples, key=lambda s: abs(s["t"] - t))


def window(samples: list[dict], start: int, end: int) -> dict:
    """Resource figures between two times: peak memory of each process seen,
    the peak of their sum, CPU seconds used, and the system's swap, pressure
    and GPU readings. CPU uses the samples nearest each end."""
    inside = [s for s in samples if start <= s["t"] <= end] or [nearest(samples, end)]
    first, last = nearest(samples, start), nearest(samples, end)
    processes = ("worker", "vm", "host")
    out = {"seconds": (end - start) / 1e9, "samples": len(inside)}
    for name in processes:
        seen = [s[name] for s in inside if s.get(name)]
        out[f"{name}_peak_footprint_bytes"] = max((p[0] for p in seen), default=None)
        if first.get(name) and last.get(name):
            out[f"{name}_cpu_seconds"] = (last[name][2] - first[name][2]) / 1e9
    out["product_peak_footprint_bytes"] = max(
        sum(s[name][0] for name in processes if s.get(name)) for s in inside)
    out["swap_used_start_bytes"], out["swap_used_end_bytes"] = first["swap_used"], last["swap_used"]
    out["swap_growth_bytes"] = last["swap_used"] - first["swap_used"]
    out["pressure_levels_seen"] = sorted({s["pressure"] for s in inside})
    out["lowest_free_percent"] = min(s["free_percent"] for s in inside)
    gpu = [s["gpu_percent"] for s in inside if s["gpu_percent"] is not None]
    out["system_gpu_percent_mean"] = sum(gpu) / len(gpu) if gpu else None
    out["system_gpu_percent_max"] = max(gpu) if gpu else None
    return out


_REWRITE_LINE = re.compile(
    r"rewrite (\w+): (\d+) prompt tokens in ([\d.]+) s, (\d+) generated in ([\d.]+) s")


def worker_figures(log: list[dict], calls: list[Call]) -> list[dict | None]:
    """The worker's own token counts and timings for each call, from its
    log line for that rewrite: the line written while the call was open (the
    last call sent before it). A call with no such line (rejected, failed or
    lost) has None."""
    figures: list[dict | None] = [None] * len(calls)
    for line in log:
        found = _REWRITE_LINE.fullmatch(line["message"])
        if not found:
            continue
        index = max((i for i, c in enumerate(calls) if c.sent_ns <= line["t"]), default=None)
        if index is None:
            raise ValueError("a rewrite was logged before any call was sent")
        figures[index] = {
            "stop": found[1],
            "prompt_tokens": int(found[2]),
            "prompt_seconds": float(found[3]),
            "generated_tokens": int(found[4]),
            "generate_seconds": float(found[5]),
        }
    return figures
