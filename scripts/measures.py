"""The stage 3 kit's arithmetic: rebuilding calls from the tap's events,
matching them to the cases that made them, naming why a case stopped,
percentiles that keep stopped calls in the denominator, and figures over the
resource samples. No input or output here; `stage3.py` runs the path.

The daemon's limits are its own (reference/rewriter-contract.md), with
Cloak's input limit and deadline by Sean's ruling (docs/plan.md, decision
6): a user turn of at most 10,000 characters (Unicode scalar values, which
Python's len counts), 16,384 tokens, and per call 90 seconds plus 20 ms for
each character. The deadline here is the daemon's formula, for the kit's
own time limits; nothing here lowers or truncates either limit.
"""

import json
import math
import re
from dataclasses import dataclass, field

MAX_INPUT_CHARACTERS = 10_000
BASE_DEADLINE_S = 90
DEADLINE_PER_CHARACTER_S = 0.020
TARGET_P50_S = 5
TARGET_P95_S = 15

STOP_REASONS = (
    "over the input limit",  # the daemon refused the input before any call
    "malformed",  # a reply came back and the daemon refused its content
    "truncated",  # the reply ended at the token limit
    "worker error",  # the worker answered with an error status
    "timed out",  # the daemon's deadline cancelled the call
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
class Process:
    """One worker process in a boot: the host starts one, and a new one after
    each loss."""

    spawn_ns: int
    pid: int
    tap_pid: int
    ready_ns: int | None = None
    exit_ns: int | None = None
    exit_status: int | None = None

    @property
    def load_seconds(self) -> float | None:
        return None if self.ready_ns is None else (self.ready_ns - self.spawn_ns) / 1e9


@dataclass
class Worker:
    """The worker's life in one boot, from the tap's events: each process the
    host started, in order, and every call across them."""

    processes: list[Process]
    calls: list[Call]
    cancels_after_answer: int


def worker_from_events(events: list[dict]) -> Worker:
    """Rebuilds the worker's processes and calls. A call open when a new
    process starts was lost with the old one, and stays unanswered. A cancel
    that arrives with no call open is one that crossed the answer; it is
    counted, as the worker ignores it."""
    processes: list[Process] = []
    calls: list[Call] = []
    open_call: Call | None = None
    crossing = 0
    for e in events:
        if e["kind"] == "spawn":
            processes.append(Process(spawn_ns=e["t"], pid=e["pid"], tap_pid=e["tap"]))
            open_call = None
        elif e["kind"] == "in" and e["frame"] == "R":
            open_call = Call(sent_ns=e["t"], request=e["text"])
            calls.append(open_call)
        elif e["kind"] == "in" and e["frame"] == "C":
            if open_call is None:
                crossing += 1
            else:
                open_call.cancels_ns.append(e["t"])
        elif e["kind"] == "out" and e["frame"] == "Y":
            processes[-1].ready_ns = e["t"]
        elif e["kind"] == "out" and e["frame"] == "A":
            open_call.answered_ns, open_call.status = e["t"], e["status"]
            open_call.reply, open_call.reply_base64 = e.get("text"), e.get("base64")
            open_call = None
        elif e["kind"] == "exit":
            processes[-1].exit_ns, processes[-1].exit_status = e["t"], e["status"]
    return Worker(processes=processes, calls=calls, cancels_after_answer=crossing)


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
        if len(text) > MAX_INPUT_CHARACTERS:
            break
        calls.append([text])
    return calls


def over_limit(body: dict) -> bool:
    return any(m["role"] == "user" and len(m["content"]) > MAX_INPUT_CHARACTERS for m in body["messages"])


def deadline_s(texts: list[str]) -> float:
    """The daemon's deadline for one call that rewrites these texts."""
    return BASE_DEADLINE_S + DEADLINE_PER_CHARACTER_S * sum(len(t) for t in texts)


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
    rewritten. The daemon itself reports only that the rewrite failed, or
    that the input was too long, and nothing at all for a case the boot
    never reached (outcome None)."""
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


def _workers_footprint(sample: dict) -> int:
    return sum(reading[0] for reading in sample["workers"].values())


def window(samples: list[dict], start: int, end: int) -> dict:
    """Resource figures between two times: peak memory of the workers (every
    worker alive at a sample, summed), the guest's virtual machine, the host
    and tor, the peak of the whole product's sum, CPU seconds used, and the
    system's swap, pressure and GPU readings. CPU uses the samples nearest
    each end; it is left out for a process missing at either end, and for the
    workers when those samples read different worker processes (a new worker
    after a loss)."""
    inside = [s for s in samples if start <= s["t"] <= end] or [nearest(samples, end)]
    first, last = nearest(samples, start), nearest(samples, end)
    out = {"seconds": (end - start) / 1e9, "samples": len(inside)}
    out["worker_peak_footprint_bytes"] = max((_workers_footprint(s) for s in inside if s["workers"]), default=None)
    out["workers_alive_max"] = max(len(s["workers"]) for s in inside)
    if first["workers"] and first["workers"].keys() == last["workers"].keys():
        out["worker_cpu_seconds"] = sum(last["workers"][pid][2] - first["workers"][pid][2]
                                        for pid in first["workers"]) / 1e9
    for name in ("vm", "host", "tor"):
        out[f"{name}_peak_footprint_bytes"] = max((s[name][0] for s in inside if s[name]), default=None)
        if first[name] and last[name]:
            out[f"{name}_cpu_seconds"] = (last[name][2] - first[name][2]) / 1e9
    out["product_peak_footprint_bytes"] = max(
        _workers_footprint(s) + sum(s[name][0] for name in ("vm", "host", "tor") if s[name]) for s in inside)
    out["swap_used_start_bytes"], out["swap_used_end_bytes"] = first["swap_used"], last["swap_used"]
    out["swap_growth_bytes"] = last["swap_used"] - first["swap_used"]
    out["pressure_levels_seen"] = sorted({s["pressure"] for s in inside})
    out["lowest_free_percent"] = min(s["free_percent"] for s in inside)
    gpu = [s["gpu_percent"] for s in inside if s["gpu_percent"] is not None]
    out["system_gpu_percent_mean"] = sum(gpu) / len(gpu) if gpu else None
    out["system_gpu_percent_max"] = max(gpu) if gpu else None
    return out


# The worker's own memory figures, as it logs them
# (llama-worker/Sources/cloak-rewriter-llama): the model's weights, the context
# a rewrite reserved, in tokens, and what the worker's Metal device holds
# allocated.
_METAL = r"Metal allocated (\d+) bytes"
_LOADED_LINE = re.compile(rf"loaded \S+; weights (\d+) bytes, {_METAL}")
_REWRITE_LINE = re.compile(
    rf"rewrite (\w+): (\d+) prompt tokens in ([\d.]+) s, (\d+) generated in ([\d.]+) s; "
    rf"context (\d+) tokens, {_METAL}")


def load_figures(log: list[dict], processes: list[Process]) -> list[dict | None]:
    """The worker's memory for each worker process once its model loaded, from
    its log line: the line written after the process started (the last one
    started before it). A process that never loaded has None."""
    figures: list[dict | None] = [None] * len(processes)
    for line in log:
        found = _LOADED_LINE.fullmatch(line["message"])
        if not found:
            continue
        index = max((i for i, p in enumerate(processes) if p.spawn_ns <= line["t"]), default=None)
        if index is None:
            raise ValueError("a load was logged before any worker started")
        figures[index] = {"weights_bytes": int(found[1]), "metal_allocated_bytes": int(found[2])}
    return figures


def worker_figures(log: list[dict], calls: list[Call]) -> list[dict | None]:
    """The worker's own token counts, timings and memory (under "llama") for
    each call, from its log line for that rewrite: the line written while
    the call was open (the last call sent before it). A call with no such
    line (rejected, failed or lost) has None."""
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
            "llama": {"context_tokens": int(found[6]), "metal_allocated_bytes": int(found[7])},
        }
    return figures
