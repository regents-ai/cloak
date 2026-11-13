"""Checks of the stage 3 kit's own logic: the tap copies frames unchanged and
notes them, calls are rebuilt and matched to their cases, every stopped case
keeps its reason and its place in each denominator, percentiles and resource
windows come out right, and a boot becomes a record with every call's input,
raw reply and hashes. No guest boots here; the kit's stand-in runs do that.

    uv run --with pytest==8.4.2 pytest tests/test_stage3.py
"""

import json
import os
import signal
import struct
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import boot  # noqa: E402
import measures  # noqa: E402
import stage3  # noqa: E402
from measures import Call  # noqa: E402

FAKE = ROOT / "tests/fake_worker.py"


def request(*texts: str) -> str:
    """A rewriter request as the daemon sends it, with these texts."""
    return json.dumps({"messages": [{"role": "system", "content": "instruction"},
                                    {"role": "user", "content": json.dumps({"texts": list(texts)})}]})


def reply(texts: list[str], finish: str = "stop") -> str:
    content = json.dumps({"texts": texts})
    return json.dumps({"choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": finish}]})


def user(text: str) -> dict:
    return {"messages": [{"role": "user", "content": text}]}


def answered(text: str, sent: int, took: int, status: int = 200, finish: str = "stop", cancels=()) -> Call:
    body = reply([text.upper()], finish) if status == 200 else json.dumps({"error": "x"})
    return Call(sent_ns=sent, request=request(text), cancels_ns=list(cancels), answered_ns=sent + took,
                status=status, reply=body)


# The tap.


def test_the_tap_copies_frames_both_ways_unchanged_and_notes_each(tmp_path):
    launcher = tmp_path / "fake-worker"
    launcher.write_text(f'#!/bin/sh\nexport FAKE_WORKER_LOG="{tmp_path}" FAKE_WORKER_READ_DELAY=0\n'
                        f'exec "{sys.executable}" -I "{FAKE}" "$@"\n')
    launcher.chmod(0o755)
    events = tmp_path / "events.jsonl"
    tap = subprocess.Popen([sys.executable, "-I", ROOT / "scripts/worker_tap.py", events, launcher, "--name", "x"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    body = request("case:ok café <b> & more").encode()
    assert tap.stdout.read(5) == b"Y\0\0\0\0"
    tap.stdin.write(b"R" + struct.pack(">I", len(body)) + body)
    tap.stdin.flush()
    header = tap.stdout.read(5)
    answer = tap.stdout.read(struct.unpack(">I", header[1:])[0])
    tap.stdin.close()
    assert tap.wait(timeout=10) == 0
    assert (tmp_path / "1.json").read_bytes() == body  # the worker got the request byte for byte
    noted = [json.loads(line) for line in events.read_text().splitlines()]
    assert [(e["kind"], e.get("frame")) for e in noted] == [
        ("spawn", None), ("out", "Y"), ("in", "R"), ("out", "A"), ("exit", None)]
    assert noted[2]["text"].encode() == body
    assert struct.pack(">H", noted[3]["status"]) + noted[3]["text"].encode() == answer  # the host got the reply as sent
    assert noted[4]["status"] == 0
    assert [e["t"] for e in noted] == sorted(e["t"] for e in noted)


def test_a_terminated_tap_exits_only_after_its_worker(tmp_path):
    launcher = tmp_path / "fake-worker"
    launcher.write_text(f'#!/bin/sh\necho start >> "{tmp_path}/starts"\n'
                        f'export FAKE_WORKER_LOG="{tmp_path}" FAKE_WORKER_READ_DELAY=0\n'
                        f'exec "{sys.executable}" -I "{FAKE}" "$@"\n')
    launcher.chmod(0o755)
    tap = subprocess.Popen([sys.executable, "-I", ROOT / "scripts/worker_tap.py", tmp_path / "events.jsonl",
                            launcher], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    assert tap.stdout.read(5) == b"Y\0\0\0\0"
    # This fake worker takes two seconds to exit once terminated.
    body = request("case:bad-frame now").encode()
    tap.stdin.write(b"R" + struct.pack(">I", len(body)) + body)
    tap.stdin.flush()
    assert tap.stdout.read(5) == b"X\0\0\0\0"
    tap.terminate()
    assert tap.wait(timeout=10) == 143
    assert (tmp_path / "exited").exists()


def test_the_sampler_reads_every_worker_alive_and_the_hosts_tor(tmp_path):
    tor = tmp_path / "tor"
    tor.symlink_to("/bin/sleep")
    # A stand-in host whose child is named tor, as the host's tor is.
    host = subprocess.Popen([sys.executable, "-I", "-c", "import subprocess, sys\n"
                             f"print(subprocess.Popen([{str(tor)!r}, '60']).pid, flush=True)\nsys.stdin.read()"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    tor_pid = int(host.stdout.readline())
    workers = [subprocess.Popen(["/bin/sleep", "60"]) for _ in range(2)]
    try:
        events = tmp_path / "events.jsonl"
        events.write_text("".join(json.dumps({"t": 0, "kind": "spawn", "pid": w.pid, "tap": 1}) + "\n"
                                  for w in workers))
        sampler = boot._Sampler(host.pid, events, boot.vm_processes())
        sampler.stop()  # samples taken here, one at a time
        both = sampler.sample()
        workers[0].kill()
        workers[0].wait()
        one = sampler.sample()
        assert set(both["workers"]) == {str(w.pid) for w in workers}
        assert set(one["workers"]) == {str(workers[1].pid)}
        assert sampler.tor_pid == tor_pid and both["tor"] and one["tor"]
    finally:
        for process in workers:
            process.kill()
            process.wait()
        os.kill(tor_pid, signal.SIGKILL)
        host.stdin.close()
        host.wait()


def test_a_payload_that_is_not_utf8_is_kept_whole_in_base64():
    import worker_tap

    assert worker_tap.payload_fields("é".encode()) == {"text": "é"}
    assert worker_tap.payload_fields(b"\xff\x00") == {"base64": "/wA="}


# Rebuilding calls and matching them to cases.


def test_calls_and_worker_processes_are_rebuilt_from_the_events():
    events = [
        {"t": 0, "kind": "spawn", "pid": 7, "tap": 6},
        {"t": 5, "kind": "out", "frame": "Y"},
        {"t": 10, "kind": "in", "frame": "R", "text": request("one")},
        {"t": 20, "kind": "out", "frame": "A", "status": 200, "text": reply(["ONE"])},
        {"t": 21, "kind": "in", "frame": "C"},  # crossed the answer: no call open
        {"t": 30, "kind": "in", "frame": "R", "text": request("two")},
        {"t": 31, "kind": "in", "frame": "C"},
        {"t": 40, "kind": "out", "frame": "A", "status": 499, "base64": "AA=="},
        {"t": 50, "kind": "in", "frame": "R", "text": request("three")},
        {"t": 60, "kind": "exit", "status": -9},
        # The host starts a new worker after the loss.
        {"t": 70, "kind": "spawn", "pid": 9, "tap": 8},
        {"t": 82, "kind": "out", "frame": "Y"},
        {"t": 90, "kind": "in", "frame": "R", "text": request("four")},
        {"t": 95, "kind": "out", "frame": "A", "status": 200, "text": reply(["FOUR"])},
        {"t": 99, "kind": "exit", "status": 0},
    ]
    worker = measures.worker_from_events(events)
    assert [(p.pid, p.load_seconds, p.exit_status) for p in worker.processes] == [(7, 5e-9, -9), (9, 12e-9, 0)]
    assert worker.cancels_after_answer == 1
    one, two, three, four = worker.calls
    assert (one.texts, one.status, one.finish_reason, one.worker_seconds) == (["one"], 200, "stop", 10e-9)
    assert (two.cancels_ns, two.status, two.reply, two.reply_base64) == ([31], 499, None, "AA==")
    assert (three.answered_ns, three.worker_seconds) == (None, None)  # lost with the first worker
    assert (four.texts, four.status, four.worker_seconds) == (["four"], 200, 5e-9)


def test_calls_are_split_among_cases_in_order_one_per_user_turn():
    history = {"messages": [{"role": "user", "content": "a"}, {"role": "assistant", "content": "x"},
                            {"role": "user", "content": " "}, {"role": "user", "content": "b"}]}
    over = user("z" * (measures.MAX_INPUT_CHARACTERS + 1))
    bodies = [user("probe"), history, over, user("probe")]
    calls = [answered(t, i * 10, 5) for i, t in enumerate(["probe", "a", "b", "probe"])]
    assert measures.attribute(bodies, calls) == [[calls[0]], [calls[1], calls[2]], [], [calls[3]]]
    # The limit counts characters, not bytes: two-byte characters up to it make a call.
    widest = "é" * measures.MAX_INPUT_CHARACTERS
    assert measures.expected_texts(user(widest)) == [[widest]]


def test_a_case_that_stopped_early_takes_only_the_calls_it_made():
    history = {"messages": [{"role": "user", "content": "a"}, {"role": "user", "content": "b"}]}
    calls = [answered("a", 0, 5, status=500), answered("next", 10, 5)]
    assert measures.attribute([history, user("next")], calls) == [[calls[0]], [calls[1]]]


def test_a_call_that_matches_no_case_is_an_error():
    with pytest.raises(ValueError):
        measures.attribute([user("one")], [answered("one", 0, 1), answered("stray", 2, 1)])


@pytest.mark.parametrize("outcome, body, calls, cancel_after_ms, reason", [
    ("rewritten", user("a"), [answered("a", 0, 1)], 0, None),
    (None, user("a"), [], 0, "no result"),
    ("stopped", user("z" * (measures.MAX_INPUT_CHARACTERS + 1)), [], 0, "over the input limit"),
    ("stopped", user("a"), [], 0, "worker lost"),
    ("stopped", user("a"), [Call(sent_ns=0, request=request("a"))], 0, "worker lost"),
    ("stopped", user("a"), [answered("a", 0, 9, status=499, cancels=[5])], 3000, "cancelled"),
    ("stopped", user("a"), [answered("a", 0, 9, status=499, cancels=[5])], 0, "timed out"),
    ("stopped", user("a"), [answered("a", 0, 1, status=500)], 0, "worker error"),
    ("stopped", user("a"), [answered("a", 0, 1, finish="length")], 0, "truncated"),
    ("stopped", user("a"), [answered("a", 0, 1)], 0, "malformed"),
])
def test_every_stopped_case_is_named_with_its_reason(outcome, body, calls, cancel_after_ms, reason):
    assert measures.stop_reason(outcome, body, calls, cancel_after_ms) == reason
    assert reason is None or reason in measures.STOP_REASONS


LOADED = ("loaded standin; MLX active 3000, cache 900, peak 3500 bytes; "
          "after the cache clear, MLX active 3000, cache 0, peak 3500 bytes")


def test_worker_log_lines_go_to_the_call_that_was_open():
    calls = [answered("a", 100, 50), answered("b", 200, 50), Call(sent_ns=300, request=request("c"))]
    log = [{"t": 90, "message": LOADED},
           {"t": 140, "message": "rewrite stop: 412 prompt tokens in 0.21 s, 55 generated in 0.63 s; "
                                 "MLX active 3100, cache 200, peak 3600 bytes"},
           {"t": 245, "message": "rewrite length: 9000 prompt tokens in 4.00 s, 16384 generated in 80.10 s; "
                                 "MLX active 3200, cache 700, peak 5000 bytes"}]
    first, second, third = measures.worker_figures("mlx", log, calls)
    assert first == {"stop": "stop", "prompt_tokens": 412, "prompt_seconds": 0.21,
                     "generated_tokens": 55, "generate_seconds": 0.63,
                     "mlx": {"active_bytes": 3100, "cache_bytes": 200, "peak_bytes": 3600}}
    assert (second["stop"], second["generated_tokens"], second["mlx"]["peak_bytes"], third) == (
        "length", 16384, 5000, None)


def test_each_worker_process_gets_the_mlx_memory_it_logged_after_loading():
    processes = [measures.Process(spawn_ns=0, pid=7, tap_pid=6), measures.Process(spawn_ns=100, pid=9, tap_pid=6),
                 measures.Process(spawn_ns=200, pid=11, tap_pid=6)]
    log = [{"t": 50, "message": LOADED},
           {"t": 150, "message": LOADED.replace("cache 900", "cache 40")}]  # the third never loaded
    first, second, third = measures.load_figures("mlx", log, processes)
    assert first == {"loaded": {"active_bytes": 3000, "cache_bytes": 900, "peak_bytes": 3500},
                     "after_cache_clear": {"active_bytes": 3000, "cache_bytes": 0, "peak_bytes": 3500}}
    assert (second["loaded"]["cache_bytes"], third) == (40, None)


def test_the_llama_worker_lines_give_llama_cpps_memory_and_the_mlx_lines_are_not_read():
    calls = [answered("a", 100, 50), answered("b", 200, 50)]
    processes = [measures.Process(spawn_ns=0, pid=7, tap_pid=6)]
    log = [{"t": 50, "message": "loaded standin-gguf; weights 1200000000 bytes, Metal allocated 1500000000 bytes"},
           {"t": 140, "message": "rewrite stop: 412 prompt tokens in 0.21 s, 55 generated in 0.63 s; "
                                 "context 16896 tokens, Metal allocated 1700000000 bytes"},
           {"t": 245, "message": "rewrite stop: 9 prompt tokens in 0.01 s, 2 generated in 0.02 s; "
                                 "MLX active 3200, cache 700, peak 5000 bytes"}]
    first, second = measures.worker_figures("llama", log, calls)
    assert first == {"stop": "stop", "prompt_tokens": 412, "prompt_seconds": 0.21,
                     "generated_tokens": 55, "generate_seconds": 0.63,
                     "llama": {"context_tokens": 16896, "metal_allocated_bytes": 1700000000}}
    assert second is None
    assert measures.load_figures("llama", log, processes) == [
        {"weights_bytes": 1200000000, "metal_allocated_bytes": 1500000000}]
    assert measures.load_figures("mlx", log, processes) == [None]


# Denominators and percentiles.


def test_percentiles_are_nearest_rank_and_a_stopped_call_is_slowest():
    assert measures.percentile([4.0, 1.0, 3.0, 2.0], 50) == 2.0
    assert measures.percentile([4.0, 1.0, 3.0, 2.0], 95) == 4.0
    assert measures.percentile([1.0, 2.0, None], 50) == 2.0
    assert measures.percentile([1.0, 2.0, None], 95) is None
    assert measures.percentile([0.5], 95) == 0.5
    with pytest.raises(ValueError):
        measures.percentile([], 50)


def test_latency_keeps_every_case_in_the_denominator():
    cases = ([{"seconds": float(s), "stop_reason": None} for s in range(1, 18)]
             + [{"seconds": 90.0, "stop_reason": "timed out"}, {"seconds": 0.1, "stop_reason": "malformed"},
                {"seconds": None, "stop_reason": "no result"}])
    summary = measures.latency(cases)
    assert (summary["cases"], summary["rewritten"], summary["stopped"]) == (20, 17, 3)
    assert summary["stopped_by_reason"] == {"malformed": 1, "timed out": 1, "no result": 1}
    assert summary["p50_seconds"] == 10.0  # rank 10 of 20, the stopped three counted as slowest
    assert summary["p95_seconds"] is None  # rank 19 falls on a stopped case
    assert summary["slowest_rewritten_seconds"] == 17.0
    assert summary["all_elapsed_p50_seconds"] == 9.0  # the malformed reply came back fastest
    assert not measures.meets_targets(summary)


def test_the_proposed_targets_need_both_figures_within_bounds():
    within = measures.latency([{"seconds": 1.0, "stop_reason": None}] * 19 + [{"seconds": 15.0, "stop_reason": None}])
    assert measures.meets_targets(within)
    slow = measures.latency([{"seconds": 5.1, "stop_reason": None}] * 20)
    assert not measures.meets_targets(slow)
    assert [measures.band(t) for t in (1, 128, 129, 256, 257, 512)] == [
        "1-128", "1-128", "129-256", "129-256", "257-512", "257-512"]


def sample(t, workers=None, vm=None, tor=None, swap=0, pressure=1, free=40, gpu=None):
    """One resource sample as the sampler takes it."""
    return {"t": t, "workers": workers or {}, "vm": vm, "host": [10, 10, t * 10], "tor": tor, "swap_used": swap,
            "pressure": pressure, "free_percent": free, "gpu_percent": gpu, "gpu_memory": None}


def test_a_resource_window_takes_peaks_cpu_and_swap_between_its_ends():
    samples = [sample(0, swap=100),
               sample(10, {"7": [500, 500, 1_000_000_000]}, [300, 300, 0], [20, 20, 0], 100, gpu=20),
               sample(20, {"7": [900, 900, 3_000_000_000]}, [200, 300, 0], [30, 30, 500_000_000], 160,
                      pressure=2, free=25, gpu=60),
               sample(30, {"7": [400, 900, 4_000_000_000]}, [100, 300, 0], [25, 30, 1_000_000_000], 150, gpu=40)]
    w = measures.window(samples, 10, 30)
    assert (w["samples"], w["worker_peak_footprint_bytes"], w["vm_peak_footprint_bytes"]) == (3, 900, 300)
    assert (w["worker_cpu_seconds"], w["workers_alive_max"]) == (3.0, 1)
    assert (w["tor_peak_footprint_bytes"], w["tor_cpu_seconds"]) == (30, 1.0)
    assert w["product_peak_footprint_bytes"] == 900 + 200 + 10 + 30  # tor is part of the product
    assert (w["swap_growth_bytes"], w["pressure_levels_seen"], w["lowest_free_percent"]) == (50, [1, 2], 25)
    assert (w["system_gpu_percent_mean"], w["system_gpu_percent_max"]) == (40, 60)


def test_workers_alive_at_once_are_summed():
    # A lost worker still exiting while its replacement loads: both count.
    samples = [sample(0, {"7": [500, 500, 0]}), sample(10, {"7": [450, 500, 0], "8": [300, 300, 0]}),
               sample(20, {"8": [600, 600, 0]})]
    w = measures.window(samples, 0, 20)
    assert (w["worker_peak_footprint_bytes"], w["workers_alive_max"]) == (750, 2)
    assert w["product_peak_footprint_bytes"] == 750 + 10


def test_a_window_across_a_new_worker_keeps_its_peak_but_no_cpu_figure():
    samples = [sample(0, {"7": [500, 500, 9_000_000_000]}), sample(10),
               sample(20, {"8": [300, 300, 1_000_000_000]})]
    w = measures.window(samples, 0, 20)
    assert w["worker_peak_footprint_bytes"] == 500
    assert "worker_cpu_seconds" not in w
    assert (w["host_cpu_seconds"], w["tor_peak_footprint_bytes"]) == (200 / 1e9, None)
    assert "tor_cpu_seconds" not in w


# The plan and the record.


def test_the_deadline_grows_with_the_input():
    # Decision 6: 90 seconds plus 20 ms for each character the call rewrites.
    sizes = (0, 1_000, 4_000, 10_000)
    assert [measures.deadline_s(["x" * n]) for n in sizes] == pytest.approx([90, 110, 170, 290])
    assert measures.deadline_s(["é" * 600, "y" * 400]) == pytest.approx(110)


def test_the_plan_uses_the_pinned_inputs_whole():
    inputs = json.loads(stage3.EVAL05.read_text())
    cap = json.loads(stage3.EVAL05_CAP.read_text())
    messages = json.loads(stage3.EVAL06.read_text())["messages"]
    plan = stage3.feasibility_plan(inputs, cap, messages)
    assert [b["boot"] for b in plan] == ["main", "worker_loss", "restart"]
    main = plan[0]["cases"]
    assert [c["group"] for c in main].count("eval06") == len(messages) == 40
    sizes = {c["name"]: len(c["body"]["messages"][0]["content"].encode()) for c in main if c["group"] == "long"}
    assert sizes == {x["id"]: x["bytes"] for x in inputs["long"] + cap["long"]}
    assert measures.over_limit(next(c for c in main if c["name"] == "prose-10001")["body"])
    assert not measures.over_limit(next(c for c in main if c["name"] == "prose-10000")["body"])
    assert [(c["name"], c["cancel_after_ms"]) for c in main if "cancel_after_ms" in c] == [
        ("cancel-prose-10000", 3000)]
    assert [(c["name"], c.get("kill_after_ms")) for c in plan[1]["cases"]] == [
        ("loss-before-probe", None), ("kill-prose-10000", 2000), ("loss-after-probe", None)]
    assert set(stage3.guest_case(main[0])) == {"name", "body", "cancel_after_ms"}
    # Every call the daemon can make gets its full deadline, grown with its
    # input, after the load allowance.
    allowances = stage3.LOAD_ALLOWANCE_S + stage3.BOOT_ALLOWANCE_S
    probe = 90 + 0.020 * len(inputs["probe"])
    assert stage3.time_limit(plan[2]["cases"]) == pytest.approx(allowances + 3 * probe)
    assert stage3.time_limit(plan[1]["cases"]) == pytest.approx(allowances + 2 * probe + 290)


def test_the_screen_applies_the_daemons_own_checks():
    sample = {"name": "redundancy", "retain": ["photosynthesis"], "avoid": ["pls", "quick brief"]}
    assert stage3.screen(sample, "Explain photosynthesis briefly.")["passed"]
    failed = stage3.screen(sample, "Give a Quick Brief overview of Photosynthesis, pls")
    assert (failed["missing"], failed["kept"], failed["brevity_named"], failed["passed"]) == (
        ["photosynthesis"], ["pls", "quick brief"], True, False)
    assert not stage3.screen(sample, "Explain photosynthesis.")["passed"]  # brevity not named
    plain = {"name": "exact", "retain": ["OK"], "avoid": []}
    assert stage3.screen(plain, "Return exactly OK.") == {
        "missing": [], "kept": [], "brevity_named": None, "passed": True}


ART = {"sha256": "a" * 64}
CONF = {"sha256": "c" * 64, "engine": "mlx"}


def fake_boot(cases: list[dict], calls: list[Call], results: dict, started: int = 0,
              losses: tuple[int, ...] = ()) -> boot.Boot:
    """A boot as boot.run returns it, rebuilt from calls and results. At each
    time in `losses` the worker is killed and the host starts a new one."""
    events = [{"t": started + 1, "kind": "spawn", "pid": 7, "tap": 6}, {"t": started + 2, "kind": "out", "frame": "Y"}]
    for pid, t in enumerate(losses, start=8):
        events += [{"t": t, "kind": "exit", "status": -9}, {"t": t + 1, "kind": "spawn", "pid": pid, "tap": 6},
                   {"t": t + 2, "kind": "out", "frame": "Y"}]
    for call in calls:
        events.append({"t": call.sent_ns, "kind": "in", "frame": "R", "text": call.request})
        events += [{"t": t, "kind": "in", "frame": "C"} for t in call.cancels_ns]
        if call.answered_ns is not None:
            events.append({"t": call.answered_ns, "kind": "out", "frame": "A", "status": call.status, "text": call.reply})
    events.sort(key=lambda e: e["t"])
    end = max(e["t"] for e in events) + 10
    # The host starts tor once the worker is ready, and the guest once tor
    # has bootstrapped.
    stderr = [(started + 2, "cloak-host: tor: Nov 12 12:00:00.000 [notice] Tor 0.4.9.16 running on Darwin\n"),
              (started + 2, "cloak-host: tor: Nov 12 12:00:00.000 [notice] Bootstrapped 0% (starting): Starting\n"),
              (started + 3, "cloak-host: tor: Nov 12 12:00:09.000 [notice] Bootstrapped 100% (done): Done\n")]
    console = [(started + 3, "cloak-guest: started")]
    console += [(r["_t"], json.dumps({k: v for k, v in r.items() if k != "_t"})) for r in results.values()]
    samples = [{"t": t, "workers": {"7": [100 + t, 100 + t, t * 1000]}, "vm": [50, 50, 0], "host": [5, 5, 0],
                "tor": [20, 20, 0], "swap_used": 0, "pressure": 1, "free_percent": 50, "gpu_percent": 10,
                "gpu_memory": 0}
               for t in range(started, end + 1, 5)]
    worker_log = [{"t": started + 2, "message": LOADED}]
    return boot.Boot(name="x", started_ns=started, ended_ns=end, host_status=0, over_time=False,
                     console=console, host_stderr=stderr, results={k: {kk: vv for kk, vv in v.items() if kk != "_t"}
                                                               for k, v in results.items()},
                     events=events, worker_log=worker_log, samples=samples, vm_pid=8, system_start={},
                     system_end={})


def result(name: str, outcome: str, seconds: float, t: int, texts=None) -> dict:
    out = {"name": name, "outcome": outcome, "seconds": seconds, "_t": t}
    if texts:
        out["texts"] = texts
    return out


def test_a_boot_becomes_a_record_with_every_call_and_its_hashes():
    cases = [{"name": "one", "group": "eval06", "body": user("one"),
              "message": {"id": "one", "style": "plain", "text": "one", "expected_output_bytes": 3}},
             {"name": "two", "group": "eval06", "body": user("two"),
              "message": {"id": "two", "style": "plain", "text": "two", "expected_output_bytes": 3}},
             {"name": "big", "group": "long", "body": user("z" * (measures.MAX_INPUT_CHARACTERS + 1))},
             {"name": "gone", "group": "long", "body": user("gone")}]
    calls = [answered("one", 10, 20), answered("two", 40, 20, finish="length")]
    results = {"one": result("one", "rewritten", 0.5, 31, ["ONE"]), "two": result("two", "stopped", 0.6, 61),
               "big": result("big", "stopped", 0.0, 62)}
    record = stage3.analyse("main", cases, fake_boot(cases, calls, results), ART, CONF, {"one": 4, "two": 300}, {})
    one, two, big, gone = record["cases"]
    assert [c["stop_reason"] for c in record["cases"]] == [None, "truncated", "over the input limit", "no result"]
    assert one["calls"][0]["request"] == calls[0].request and one["calls"][0]["reply"] == calls[0].reply
    assert one["calls"][0]["reply_texts"] == ["ONE"]
    assert {(c["artifact_sha256"], c["configuration_sha256"]) for c in one["calls"] + two["calls"]} == {
        (ART["sha256"], CONF["sha256"])}
    assert one["eval06"] == {"style": "plain", "input_tokens": 4, "band": "1-128", "input_bytes": 3,
                             "expected_output_bytes": 3, "output_bytes": 3}
    assert two["eval06"]["band"] == "257-512" and two["eval06"]["output_bytes"] is None
    assert (big["calls"], gone["outcome"], gone["seconds"]) == ([], None, None)
    assert [p["load_seconds"] for p in record["worker"]["processes"]] == [1e-9]
    assert record["worker"]["processes"][0]["mlx_memory"]["after_cache_clear"]["cache_bytes"] == 0
    assert record["tor"] == {"started_ns": 2, "bootstrapped_ns": 3}
    assert "Bootstrapped 100% (done)" in record["host_stderr"]
    assert measures.latency(record["cases"])["cases"] == 4


def test_tor_is_timed_from_its_first_line_to_its_bootstrap():
    host = (1, "cloak-host: the worker is ready\n")
    started = (5, "cloak-host: tor: [notice] Tor 0.4.9.16 running on Darwin\n")
    unreachable = (8, "cloak-host: cannot reach tor (Connection refused); closed a Tor port connection without an answer\n")
    done = (9, "cloak-host: tor: [notice] Bootstrapped 100% (done): Done\n")
    assert stage3.tor_start([host, started, unreachable, done]) == {"started_ns": 5, "bootstrapped_ns": 9}
    # Stopped at the host's limit, or exited first.
    assert stage3.tor_start([host, started, unreachable]) == {"started_ns": 5, "bootstrapped_ns": None}


def test_the_summary_counts_every_case_of_every_boot():
    inputs = json.loads(stage3.EVAL05.read_text())
    messages = json.loads(stage3.EVAL06.read_text())["messages"][:3]
    cap = json.loads(stage3.EVAL05_CAP.read_text())
    plan = {b["boot"]: b["cases"] for b in stage3.feasibility_plan(inputs, cap, messages)}
    plan["main"] = [c for c in plan["main"] if c["group"] != "long"]
    boots, start = {}, 0
    for name, cases in plan.items():
        calls, results, t, losses = [], {}, start + 10, []
        for case in cases:
            texts = [m["content"] for m in case["body"]["messages"] if m["role"] == "user"]
            if case.get("kill_after_ms"):
                calls.append(Call(sent_ns=t, request=request(texts[0])))
                results[case["name"]] = result(case["name"], "stopped", 2.0, t + 5)
                losses.append(t + 6)
            elif case.get("cancel_after_ms"):
                calls.append(answered(texts[0], t, 3000, status=499, cancels=[t + 2000]))
                results[case["name"]] = result(case["name"], "stopped", 3.0, t + 3001)
            else:
                for text in texts:
                    calls.append(answered(text, t, 4))
                    t += 5
                results[case["name"]] = result(case["name"], "rewritten", 1.0, t, [texts[-1].upper()])
            t += 3002
        counts = {m["id"]: 10 for m in messages}
        boots[name] = stage3.analyse(name, cases, fake_boot(cases, calls, results, start, tuple(losses)),
                                     ART, CONF, counts, {})
        start = t + 100
    summary = stage3.summarise(boots, [{"case": "kill-prose-10000", "call_was_open": True}], "mlx")
    assert summary["eval06"]["cases"] == 3 and summary["eval06"]["rewritten"] == 3
    assert summary["eval06"]["by_band"]["1-128"]["cases"] == 3 and summary["eval06"]["by_band"]["257-512"] is None
    assert summary["history"][0]["outcome"] == "rewritten" and len(summary["history"][0]["calls"]) == 4
    assert summary["cancellation"]["case"]["stop_reason"] == "cancelled"
    assert summary["cancellation"]["cancel_to_answer_seconds"] == pytest.approx(1000e-9)
    assert [c["stop_reason"] for c in summary["worker_loss"]["cases"]] == [None, "worker lost", None]
    assert summary["worker_loss"]["worker_processes"] == [{"pid": 7, "load_seconds": 1e-9, "exit_status": -9},
                                                          {"pid": 8, "load_seconds": 1e-9, "exit_status": None}]
    every = summary["end_to_end"]["all_cases"]
    assert every["cases"] == sum(len(c) for c in plan.values())
    assert every["stopped_by_reason"] == {"cancelled": 1, "worker lost": 1}
    assert summary["restart"]["load_seconds"] == 1e-9
    # tor's bootstrap is its own figure, apart from the worker's load.
    assert summary["cold"]["tor_bootstrap_seconds"] == summary["restart"]["tor_bootstrap_seconds"] == 1e-9
