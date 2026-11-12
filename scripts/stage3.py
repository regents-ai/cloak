# /// script
# requires-python = ">=3.12"
# dependencies = ["tokenizers==0.22.1"]
# ///
"""The stage 3 feasibility kit: one command per candidate, once its weights
are on disk, writes that candidate's stage 3 record (spec EVAL05, EVAL06 and
EVAL07; docs/evaluation-protocol.md).

    uv run scripts/stage3.py feasibility <name>
    uv run scripts/stage3.py eval01 <name>

`feasibility` boots the guest three times, one after another: the main run
(cold load, the cold first call, the 40 EVAL06 messages warm, the
conversation rebuilt after cache loss, the long inputs, a cancellation and
the call after it), the worker loss (the worker killed mid-rewrite, and the
call after it, served by the new worker the host starts), and the restart (a
fresh boot after the loss). `eval01` runs the daemon's 16
synthetic cases (EVAL01, the development screen) through the same path and
applies the daemon's own mechanical checks to each output.

Every call goes through the real path: the daemon's rewrite code in the
guest, the guest adapter, the host relay and the sandboxed worker, with the
copy-only tap (worker_tap.py) between the host and the worker. Each case
keeps its input, the daemon's result, every rewriter call it made (request
and raw reply, the worker's token counts and timings, the artifact and
configuration hashes) and why it stopped. Stopped cases stay in every
denominator.

Records go to evidence/stage3/<name>/<kind>-<UTC time>.json. A model other
than the lead or the challenger is a development stand-in: its record says
so and counts toward no gate in docs/plan.md.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import boot
import measures
from drive_worker import INSTALLED, SYSTEM_SHA256, go_json, system_message
from fetch_model import DEST, MODELS

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence/stage3"
GATE_MODELS = ("lead", "challenger")

# The fixed inputs, pinned before any candidate ran on them.
EVAL05 = ROOT / "reference/eval05-inputs.json"
EVAL05_SHA256 = "efd9c6ff8b7419edbd10f282392106994ed4bd4644b6366866539c8b807655cb"
# The cases decision 6's input limit forces, pinned on 12 November 2026,
# after the lead's first run: the limit's two sides, and the cancellation and
# worker loss inputs in place of EVAL05's, which the limit refuses.
EVAL05_CAP = ROOT / "reference/eval05-cap-inputs.json"
EVAL05_CAP_SHA256 = "bd9d4045da2b6aa863bf2ccb555b48e5d9875108728c1d0a94fea5d5463757e3"
EVAL06 = ROOT / "reference/eval06-messages.json"
EVAL06_SHA256 = "10136dd123899a17ba52b56bbe2a376ecf0f4e5f41d1a8a87e4207c1c8a5e50b"
EVAL06_MAX_TOKENS = 512

# The pinned daemon's rewrite code, and the battery EVAL01 runs.
DAEMON = ROOT / "reference/src/zkapi/zkapi-clientd"
DAEMON_SOURCES = {
    "internal/rewriter/rewriter.go": "ad5609c25a483adc19db15391df2b019cc20110796fe12e0d97d0a73df8b7067",
    "internal/rewriter/instruction_eval_test.go": "8581ba4116e7b843c1839928aff1fb657586d29e28b97cd2e88fa507fa52b8a2",
}
KIT_FILES = ("scripts/stage3.py", "scripts/boot.py", "scripts/measures.py", "scripts/worker_tap.py",
             "scripts/drive_worker.py", "guest/check/main.go", "guest/image/init", "guest/image/boot",
             "guest/daemon/zz_cloak_guest.go", "guest/daemon/rewriter.patch", "guest/daemon/server.patch",
             "guest/agent/main.go")

MAX_TOKENS = 16384
TEMPERATURE = 0
# Room the run needs beyond the model's files: the guest's 1 GiB and 4 GiB
# for the worker's cache and the rest of the path.
HEADROOM_BYTES = 5 << 30
# How long one boot may take before it is stopped and recorded as stopped:
# the cold load and tor's bootstrap (which the host gives at most 90 s), then
# the daemon's own deadline for every call it can make.
LOAD_ALLOWANCE_S = 900
BOOT_ALLOWANCE_S = 60

# tor's own line once it can build circuits, which the host waits for before
# it starts the guest (host/Sources/cloak-host/Tor.swift).
TOR_BOOTSTRAPPED = "Bootstrapped 100% (done)"

DEVELOPMENT_ONLY = ("Development stand-in, not a candidate. Proves the kit end to end; never evaluated "
                    "and never counted toward a gate in docs/plan.md.")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(8 << 20):
            h.update(block)
    return h.hexdigest()


def sha256_json(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def stop(message: str):
    raise SystemExit(f"stage3: {message}")


# Inputs.


def user(text: str) -> dict:
    """A client request with one user turn, as a local client sends it."""
    return {"messages": [{"role": "user", "content": text}]}


def long_text(inputs: dict, source: str, size: int) -> str:
    text = inputs[source][:size]
    if len(text.encode()) != size:
        stop(f"{source} is shorter than {size} bytes")
    return text


def feasibility_plan(inputs: dict, cap: dict, messages: list[dict]) -> list[dict]:
    """The three boots and their cases, in order. `group` names the measure a
    case belongs to; only name, body and cancel_after_ms reach the guest.
    Every EVAL05 long input runs, those over the input limit included; the
    cancellation and worker loss inputs are the cap cases' (EVAL05_CAP)."""
    probe = inputs["probe"]
    main = [{"name": "cold-probe", "group": "cold", "body": user(probe)}]
    main += [{"name": m["id"], "group": "eval06", "body": user(m["text"]), "message": m} for m in messages]
    history = inputs["history"]
    main.append({"name": history["id"], "group": "history", "body": {"messages": history["messages"]}})
    main += [{"name": x["id"], "group": "long", "body": user(long_text(inputs, x["source"], x["bytes"]))}
             for x in inputs["long"] + cap["long"]]
    cancel = cap["cancellation"]
    main.append({"name": cancel["id"], "group": "cancellation", "cancel_after_ms": cancel["cancel_after_ms"],
                 "body": user(long_text(inputs, cancel["source"], cancel["bytes"]))})
    main.append({"name": "after-cancel-probe", "group": "cancellation", "body": user(probe)})
    loss = cap["worker_loss"]
    kill = [
        {"name": "loss-before-probe", "group": "worker_loss", "body": user(probe)},
        {"name": loss["id"], "group": "worker_loss", "body": user(long_text(inputs, loss["source"], loss["bytes"])),
         "kill_after_ms": loss["kill_after_ms"]},
        {"name": "loss-after-probe", "group": "worker_loss", "body": user(probe)},
    ]
    restart = [{"name": f"restart-probe-{i}", "group": "restart", "body": user(probe)} for i in (1, 2, 3)]
    return [{"boot": "main", "cases": main}, {"boot": "worker_loss", "cases": kill},
            {"boot": "restart", "cases": restart}]


def guest_case(case: dict) -> dict:
    return {"name": case["name"], "body": case["body"], "cancel_after_ms": case.get("cancel_after_ms", 0)}


def time_limit(cases: list[dict]) -> float:
    calls = [texts for c in cases for texts in measures.expected_texts(c["body"])]
    return LOAD_ALLOWANCE_S + BOOT_ALLOWANCE_S + sum(measures.deadline_s(texts) for texts in calls)


def battery() -> list[dict]:
    """The daemon's 16 synthetic cases (reconstructionBattery), read from the
    pinned source by compiling a small test beside it with go test -overlay,
    which leaves the daemon's files untouched."""
    dump = '''package rewriter

import (
	"encoding/json"
	"os"
	"testing"
)

func TestStage3DumpBattery(t *testing.T) {
	type sample struct {
		Name   string   `json:"name"`
		Input  string   `json:"input"`
		Retain []string `json:"retain"`
		Avoid  []string `json:"avoid"`
	}
	out := []sample{}
	for _, s := range reconstructionBattery {
		out = append(out, sample{s.name, s.input, append([]string{}, s.retain...), append([]string{}, s.avoid...)})
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		t.Fatal(err)
	}
}
'''
    with tempfile.TemporaryDirectory(prefix="cloak-stage3-eval01-") as scratch:
        scratch = Path(scratch)
        (scratch / "dump_test.go").write_text(dump)
        target = DAEMON / "internal/rewriter/zz_stage3_dump_test.go"
        (scratch / "overlay.json").write_text(json.dumps({"Replace": {str(target): str(scratch / "dump_test.go")}}))
        env = {**os.environ, "GOPROXY": "off", "GOFLAGS": "-mod=readonly", "GOMAXPROCS": "2"}
        out = subprocess.run(
            ["nice", "go", "test", "-v", "-p", "2", "-count=1", "-run", "^TestStage3DumpBattery$",
             "-overlay", scratch / "overlay.json", "./internal/rewriter"],
            cwd=DAEMON, env=env, capture_output=True, text=True)
    if out.returncode != 0:
        stop(f"cannot read the daemon's battery:\n{out.stdout}{out.stderr}")
    samples = json.loads(next(line for line in out.stdout.splitlines() if line.startswith("[")))
    if len(samples) != 16:
        stop(f"the daemon's battery has {len(samples)} cases, not 16")
    return samples


def screen(sample: dict, text: str) -> dict:
    """The daemon's own mechanical checks (TestLiveInstructionEvaluation with
    the default instruction): every retained literal present as written, no
    avoided phrase in any case, and brevity named in the redundancy case."""
    lower = text.lower()
    missing = [r for r in sample["retain"] if r not in text]
    kept = [a for a in sample["avoid"] if a.lower() in lower]
    brevity = None
    if sample["name"] == "redundancy":
        brevity = any(word in lower for word in ("brief", "short", "concise"))
    return {"missing": missing, "kept": kept, "brevity_named": brevity,
            "passed": not missing and not kept and brevity is not False}


# Checks before any boot.


def pinned(name: str) -> dict:
    models = {m["name"]: m for m in json.loads(MODELS.read_text())["models"]}
    if name not in models:
        stop(f"no pinned model named {name} in reference/models.json")
    model = models[name]
    if "chat_template_context" not in model:
        stop(f"{name} has no frozen chat template settings; the worker loads no such model")
    return model


def preflight(model: dict, model_dir: Path) -> dict:
    """Everything the run depends on, checked before any boot. The worker
    checks every file's sha256 itself when it loads; here each must be
    present at its pinned size."""
    for entry in model["files"]:
        path = model_dir / entry["path"]
        if not path.is_file() or path.stat().st_size != entry["size"]:
            stop(f"{path} is missing or not its pinned size; fetch it with scripts/fetch_model.py")
    for path in (INSTALLED, boot.HOST, boot.TOR, boot.KERNEL, boot.INITRD):
        if not path.is_file():
            stop(f"{path} is not built (README, stage 2 commands)")
    if MODELS.read_bytes() not in INSTALLED.read_bytes():
        stop("the installed worker was built with other model pins; run worker/install.sh")
    for path, digest in ((EVAL05, EVAL05_SHA256), (EVAL05_CAP, EVAL05_CAP_SHA256), (EVAL06, EVAL06_SHA256)):
        if sha256_file(path) != digest:
            stop(f"{path} is not the pinned input set")
    for relative, digest in DAEMON_SOURCES.items():
        if sha256_file(DAEMON / relative) != digest:
            stop(f"{relative} is not the pinned daemon source; run scripts/fetch_sources.py")
    system_message()  # checks the instruction against its recorded sha256
    running = subprocess.run(["pgrep", "-x", "cloak-host"], capture_output=True, text=True).stdout.split()
    if running:
        stop(f"a guest is already running (cloak-host pid {', '.join(running)}); one boot at a time")
    available = available_memory()
    needed = model["total_bytes"] + HEADROOM_BYTES
    if available < needed:
        stop(f"{available / 2**30:.1f} GiB of memory is available and the run needs {needed / 2**30:.1f} GiB")
    return {"available_memory_bytes": available, "needed_memory_bytes": needed}


def available_memory() -> int:
    """Memory macOS can hand out without swapping: free, inactive,
    speculative and purgeable pages."""
    pages = boot.vm_stat()
    return int(sysctl("hw.pagesize")) * sum(
        pages[k] for k in ("pages_free", "pages_inactive", "pages_speculative", "pages_purgeable"))


def eval06_tokens(model_dir: Path, messages: list[dict]) -> dict[str, int]:
    """Each message's input tokens with the candidate's own tokenizer: the
    user message the daemon sends, without special tokens."""
    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
    counts = {m["id"]: len(tokenizer.encode(go_json({"texts": [m["text"]]}), add_special_tokens=False).ids)
              for m in messages}
    over = {k: v for k, v in counts.items() if v > EVAL06_MAX_TOKENS}
    if over:
        stop(f"EVAL06 messages over {EVAL06_MAX_TOKENS} tokens with this tokenizer: {over}")
    return counts


# What the record says about the run.


def artifact(model: dict) -> dict:
    files = "".join(f"{f['path']} {f['size']} {f['sha256']}\n" for f in model["files"])
    out = {"name": model["name"], "repo": model["repo"], "revision": model["revision"],
           "total_bytes": model["total_bytes"], "files_sha256": hashlib.sha256(files.encode()).hexdigest()}
    return {**out, "sha256": sha256_json(out)}


def configuration(model: dict) -> dict:
    out = {
        "system_message_sha256": SYSTEM_SHA256,
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "chat_template_context": model["chat_template_context"],
        "models_json_sha256": sha256_file(MODELS),
        "daemon_sources_sha256": DAEMON_SOURCES,
        "worker_sha256": sha256_file(INSTALLED),
        "host_sha256": sha256_file(boot.HOST),
        "tor_sha256": sha256_file(boot.TOR),
        "kernel_sha256": sha256_file(boot.KERNEL),
        "initrd_sha256": sha256_file(boot.INITRD),
        "guest": {"cpus": 2, "memory_bytes": 1 << 30},
    }
    return {**out, "sha256": sha256_json(out)}


def kit() -> dict:
    git = lambda *a: subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True).stdout.strip()  # noqa: E731
    return {"commit": git("rev-parse", "HEAD"), "uncommitted_changes": bool(git("status", "--porcelain")),
            "files_sha256": {f: sha256_file(ROOT / f) for f in KIT_FILES},
            "inputs_sha256": {"eval05": EVAL05_SHA256, "eval05_cap": EVAL05_CAP_SHA256, "eval06": EVAL06_SHA256}}


def sysctl(name: str) -> str:
    return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()


def machine() -> dict:
    """The Mac, without its name or serial number."""
    power = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
    return {
        "model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "memory_bytes": int(sysctl("hw.memsize")),
        "performance_cores": int(sysctl("hw.perflevel0.physicalcpu")),
        "efficiency_cores": int(sysctl("hw.perflevel1.physicalcpu") or 0),
        "macos": platform.mac_ver()[0],
        "macos_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
        "power_source": re.search(r"'([^']+)'", power)[1],
        "battery": re.findall(r"(\d+%; [^;]+)", power),
        "free_disk_bytes": shutil.disk_usage(DEST).free,
    }


def du_bytes(path: Path) -> int:
    return int(subprocess.run(["du", "-sk", path], capture_output=True, text=True, check=True).stdout.split()[0]) * 1024


def installed_size(model: dict, model_dir: Path) -> dict:
    parts = {"model_on_disk": du_bytes(model_dir), "worker_with_shaders": du_bytes(INSTALLED.parent),
             "host": du_bytes(boot.HOST), "tor": du_bytes(boot.TOR.parent), "guest_kernel": du_bytes(boot.KERNEL), "guest_initrd": du_bytes(boot.INITRD)}
    return {"model_pinned_bytes": model["total_bytes"], "on_disk_bytes": parts, "total_on_disk_bytes": sum(parts.values())}


MANUAL_STEPS = [
    ("sleep_and_wake", "Start `feasibility`, close the lid (or choose Sleep) during an EVAL06 call, wake after 60 s; "
     "note whether the call and the next ones finish, and attach the record of that run."),
    ("battery", "Run `feasibility` on battery with no other heavy apps, noting the battery percentage before and "
     "after and Activity Monitor's Energy column for cloak-rewriter."),
    ("declared_load", "State the ordinary Mac load the run had (apps open, other work running); the record holds "
     "only load average, memory and swap."),
    ("induced_memory_pressure", "Rerun with memory pressure raised to warning by other apps (Activity Monitor's "
     "Memory Pressure graph turns yellow); note swap and any stopped calls."),
    ("first_run_after_restart", "Run `feasibility` first thing after restarting the Mac, so the model is read "
     "from disk rather than the file cache; compare the cold load."),
]

NOT_MEASURED = [
    "The full stack: the guest runs the daemon's local API and has Pi in the reference wrapper, and the host "
    "runs tor for it on the public Tor network, but there is no cover traffic or payment vault yet, tor's own "
    "memory and CPU are not sampled, and this kit's calls come from the daemon's rewrite code, not from Pi; "
    "so 'with the full stack loaded' (stage 3's exit condition) is not met by any record from this kit.",
    "The daemon's full serve path: its payment vault is not deployed at the pinned commit; the kit drives the "
    "daemon's rewrite code as its client does before target inference (A11 stays open).",
    "Per-process GPU use: macOS gives it only to root; the record has the system-wide GPU utilisation.",
    "A 32 GB Mac: not tested (decision 2).",
]


def manual_steps() -> list[dict]:
    return [{"step": step, "how": how, "result": None} for step, how in MANUAL_STEPS]


# Turning one boot into its record.


def analyse(boot_name: str, cases: list[dict], run: boot.Boot, art: dict, conf: dict,
            tokenizer_counts: dict[str, int], extra: dict) -> dict:
    """One boot's cases, calls and resource figures."""
    worker = measures.worker_from_events(run.events) if run.events else None
    calls = worker.calls if worker else []
    split = measures.attribute([c["body"] for c in cases], calls)
    figures = dict(zip(map(id, calls), measures.worker_figures(run.worker_log, calls)))
    finished = {}
    for t, line in run.console:
        if line.startswith("{"):
            finished[json.loads(line)["name"]] = t
    out_cases = []
    for case, case_calls in zip(cases, split):
        result = run.results.get(case["name"])
        outcome = result and result["outcome"]
        reason = measures.stop_reason(outcome, case["body"], case_calls, case.get("cancel_after_ms", 0))
        record = {
            "name": case["name"], "group": case["group"], "body": case["body"],
            "cancel_after_ms": case.get("cancel_after_ms", 0),
            "outcome": outcome, "error": result and result.get("error"),
            "texts": result and result.get("texts"), "seconds": result and result["seconds"],
            "stop_reason": reason, "finished_ns": finished.get(case["name"]),
            "calls": [call_record(c, figures[id(c)], art, conf, run.started_ns) for c in case_calls],
        }
        if "message" in case:
            m = case["message"]
            record["eval06"] = {"style": m["style"], "input_tokens": tokenizer_counts[m["id"]],
                                "band": measures.band(tokenizer_counts[m["id"]]),
                                "input_bytes": len(m["text"].encode()),
                                "expected_output_bytes": m["expected_output_bytes"],
                                "output_bytes": len(record["texts"][0].encode()) if record["texts"] else None}
        out_cases.append(record)
    return {
        "boot": boot_name, "started_ns": run.started_ns, "ended_ns": run.ended_ns,
        "seconds": (run.ended_ns - run.started_ns) / 1e9, "host_exit_status": run.host_status,
        "stopped_over_time": run.over_time, "vm_pid_seen": run.vm_pid is not None,
        "worker": worker and {"processes": [{"pid": p.pid, "load_seconds": p.load_seconds,
                                             "spawn_ns": p.spawn_ns, "ready_ns": p.ready_ns,
                                             "exit_ns": p.exit_ns, "exit_status": p.exit_status}
                                            for p in worker.processes],
                              "cancels_after_answer": worker.cancels_after_answer},
        "tor": tor_start(run.host_stderr),
        "system_start": run.system_start, "system_end": run.system_end,
        "cases": out_cases, **extra,
        "console": [line for _, line in run.console if not line.startswith("{")],
        "host_stderr": "".join(line for _, line in run.host_stderr),
        "worker_log": run.worker_log, "samples": run.samples,
    }


def tor_start(host_stderr: list[tuple[int, str]]) -> dict:
    """When tor started (its first line in the host's log) and when it said
    it had bootstrapped; None for what the log never showed."""
    tor = [(t, line) for t, line in host_stderr if line.startswith("cloak-host: tor: ")]
    return {"started_ns": tor[0][0] if tor else None,
            "bootstrapped_ns": next((t for t, line in tor if TOR_BOOTSTRAPPED in line), None)}


def call_record(call: measures.Call, figures: dict | None, art: dict, conf: dict, origin: int) -> dict:
    parsed = None
    if call.status == 200 and call.reply:
        content = json.loads(call.reply)["choices"][0]["message"]["content"]
        try:
            parsed = json.loads(content).get("texts")
        except (json.JSONDecodeError, AttributeError):
            parsed = None
    return {
        "sent_seconds": (call.sent_ns - origin) / 1e9,
        "worker_seconds": call.worker_seconds,
        "cancel_seconds": [(t - call.sent_ns) / 1e9 for t in call.cancels_ns],
        "status": call.status, "finish_reason": call.finish_reason,
        "request": call.request, "reply": call.reply, "reply_base64": call.reply_base64,
        "reply_texts": parsed, "worker": figures,
        "artifact_sha256": art["sha256"], "configuration_sha256": conf["sha256"],
    }


def first_worker(boot_record: dict) -> dict:
    """The worker process the boot started with; empty when none was seen."""
    return boot_record["worker"]["processes"][0] if boot_record["worker"] else {}


def window_of(boot_record: dict, group: str) -> dict | None:
    """Resource figures while a group's cases ran: from the end of the case
    before the group's first (or the worker's ready) to the group's last end."""
    cases = boot_record["cases"]
    indices = [i for i, c in enumerate(cases) if c["group"] == group]
    if not indices or not boot_record["samples"]:
        return None
    previous = cases[indices[0] - 1]["finished_ns"] if indices[0] else None
    start = previous or first_worker(boot_record).get("ready_ns") or boot_record["started_ns"]
    end = cases[indices[-1]]["finished_ns"] or boot_record["ended_ns"]
    return measures.window(boot_record["samples"], start, end)


def path_overhead(cases: list[dict]) -> dict:
    """End-to-end time the daemon measured minus the worker's own time, for
    rewritten cases with one call: the guest, adapter, relay and tap."""
    gaps = sorted(c["seconds"] - c["calls"][0]["worker_seconds"] for c in cases
                  if c["stop_reason"] is None and len(c["calls"]) == 1)
    return {"cases": len(gaps), "p50_seconds": measures.percentile(gaps, 50) if gaps else None,
            "max_seconds": gaps[-1] if gaps else None}


def tokens_per_second(cases: list[dict]) -> dict:
    rates = sorted(f["generated_tokens"] / f["generate_seconds"] for c in cases for call in c["calls"]
                   if (f := call["worker"]) and f["generate_seconds"] > 0)
    prefill = sorted(f["prompt_tokens"] / f["prompt_seconds"] for c in cases for call in c["calls"]
                     if (f := call["worker"]) and f["prompt_seconds"] > 0)
    return {"generation_p50": measures.percentile(rates, 50) if rates else None,
            "prompt_p50": measures.percentile(prefill, 50) if prefill else None}


def summarise(boots: dict[str, dict], kills: list[dict]) -> dict:
    main, loss, restart = boots["main"], boots["worker_loss"], boots["restart"]
    group = lambda b, g: [c for c in b["cases"] if c["group"] == g]  # noqa: E731
    every = [c for b in boots.values() for c in b["cases"]]
    eval06 = group(main, "eval06")
    by_band = {}
    for name in ("1-128", "129-256", "257-512"):
        inside = [c for c in eval06 if c["eval06"]["band"] == name]
        by_band[name] = measures.latency(inside) if inside else None
    eval06_summary = measures.latency(eval06)
    ratios = sorted(c["eval06"]["output_bytes"] / c["eval06"]["expected_output_bytes"]
                    for c in eval06 if c["eval06"]["output_bytes"] is not None)
    brief = lambda c: {k: c[k] for k in ("name", "outcome", "stop_reason", "seconds")} | {  # noqa: E731
        "calls": [{k: call[k] for k in ("worker_seconds", "status", "finish_reason", "worker")} for call in c["calls"]]}
    cancel_case = next(c for c in group(main, "cancellation") if c["cancel_after_ms"])
    cancel_call = cancel_case["calls"][-1] if cancel_case["calls"] else None
    return {
        "eval06": {**eval06_summary, "meets_proposed_targets": measures.meets_targets(eval06_summary),
                   "targets": {"p50_seconds": measures.TARGET_P50_S, "p95_seconds": measures.TARGET_P95_S},
                   "by_band": by_band, "tokens_per_second": tokens_per_second(eval06),
                   "output_to_expected_bytes_p50": measures.percentile(ratios, 50) if ratios else None,
                   "window": window_of(main, "eval06")},
        "cold": {"load_seconds": first_worker(main).get("load_seconds"),
                 "load_includes": "the worker's sha256 check of every pinned file, then the model load",
                 "tor_bootstrap_seconds": tor_bootstrap_seconds(main),
                 "tor_bootstrap_includes": TOR_BOOTSTRAP_INCLUDES,
                 "first_call": brief(group(main, "cold")[0]),
                 "host_start_to_first_result_seconds": first_result_seconds(main),
                 "first_result_includes": FIRST_RESULT_INCLUDES,
                 "load_window": load_window(main)},
        "history": [brief(c) for c in group(main, "history")],
        "long": {"cases": [brief(c) | {"input_characters": len(c["body"]["messages"][0]["content"])}
                           for c in group(main, "long")],
                 "window": window_of(main, "long")},
        "cancellation": {
            "case": brief(cancel_case),
            "cancel_to_answer_seconds": (cancel_call["worker_seconds"] - cancel_call["cancel_seconds"][0])
            if cancel_call and cancel_call["cancel_seconds"] and cancel_call["worker_seconds"] is not None else None,
            "next_call": brief(group(main, "cancellation")[-1])},
        "worker_loss": {"kills": kills, "cases": [brief(c) for c in group(loss, "worker_loss")],
                        "host_exit_status": loss["host_exit_status"],
                        "worker_processes": [{k: p[k] for k in ("pid", "load_seconds", "exit_status")}
                                             for p in (loss["worker"] or {}).get("processes", [])]},
        "restart": {"load_seconds": first_worker(restart).get("load_seconds"),
                    "tor_bootstrap_seconds": tor_bootstrap_seconds(restart),
                    "host_start_to_first_result_seconds": first_result_seconds(restart),
                    "cases": [brief(c) for c in group(restart, "restart")]},
        "memory_cpu_gpu": {name: {"whole_boot": measures.window(b["samples"], b["started_ns"], b["ended_ns"])
                                  if b["samples"] else None} for name, b in boots.items()},
        "end_to_end": {"path_overhead": path_overhead(every),
                       "all_cases": measures.latency(every)},
    }


TOR_BOOTSTRAP_INCLUDES = ("tor's start, with the state it saved in its lasting folder on earlier starts (none "
                          "on its first), to its 'Bootstrapped 100% (done)' line; the host "
                          "starts tor once the worker is ready and the guest once tor has bootstrapped. None: tor "
                          "never bootstrapped, and the host stopped it at its 90 s limit or it exited")
FIRST_RESULT_INCLUDES = "the cold load, tor's bootstrap, the guest's boot and the first call"


def tor_bootstrap_seconds(boot_record: dict) -> float | None:
    tor = boot_record["tor"]
    return (tor["bootstrapped_ns"] - tor["started_ns"]) / 1e9 if tor["bootstrapped_ns"] else None


def first_result_seconds(boot_record: dict) -> float | None:
    ends = [c["finished_ns"] for c in boot_record["cases"] if c["finished_ns"]]
    return (min(ends) - boot_record["started_ns"]) / 1e9 if ends else None


def load_window(boot_record: dict) -> dict | None:
    w = first_worker(boot_record)
    if not w or not w["ready_ns"] or not boot_record["samples"]:
        return None
    return measures.window(boot_record["samples"], w["spawn_ns"], w["ready_ns"])


# Running.


def killer(cases: list[dict], kills: list[dict]):
    """The `during` hook for the worker-loss boot: once the case marked
    kill_after_ms has sent its request, wait that long and kill the worker
    (SIGKILL), noting when and whether its call was still open."""
    index = next(i for i, c in enumerate(cases) if "kill_after_ms" in c)
    after_ms = cases[index]["kill_after_ms"]
    requests_before = sum(len(measures.expected_texts(c["body"])) for c in cases[:index]) + 1

    def during(events: Path, host: subprocess.Popen):
        while host.poll() is None:
            lines = events_so_far(events)
            sent = [e for e in lines if e["kind"] == "in" and e["frame"] == "R"]
            if len(sent) >= requests_before:
                time.sleep(after_ms / 1000)
                pid = next(e["pid"] for e in lines if e["kind"] == "spawn")
                at = boot.clock()
                os.kill(pid, signal.SIGKILL)
                answered = any(e["kind"] == "out" and e["frame"] == "A" and e["t"] > sent[-1]["t"]
                               for e in events_so_far(events))
                kills.append({"case": cases[index]["name"], "pid": pid, "signal": "SIGKILL",
                              "after_request_seconds": (at - sent[-1]["t"]) / 1e9,
                              "call_was_open": not answered})
                return
            time.sleep(0.05)

    return during


def events_so_far(events: Path) -> list[dict]:
    """The tap's events written so far, leaving out a line still being written."""
    if not events.exists():
        return []
    text = events.read_text()
    return [json.loads(line) for line in text[:text.rfind("\n") + 1].splitlines()]


def wait_for_vm_exit(pid: int | None) -> None:
    """One guest at a time: the next boot starts only once this one's
    virtual machine process is gone."""
    deadline = time.monotonic() + 60
    while pid and boot.process_reading(pid) is not None and time.monotonic() < deadline:
        time.sleep(0.5)


def write_record(name: str, kind: str, record: dict) -> Path:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = EVIDENCE / name / f"{kind}-{stamp}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, ensure_ascii=False, indent=1) + "\n")
    return path


def header(kind: str, model: dict, model_dir: Path, checks: dict) -> dict:
    development = model["name"] not in GATE_MODELS
    return {
        "record": f"stage 3 {kind}",
        "model": model["name"],
        "development_only": development,
        "label": DEVELOPMENT_ONLY if development else
        "Candidate run. A gate passes only when this record is linked in its row in docs/plan.md.",
        "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kit": kit(), "machine": machine(), "preflight": checks,
        "artifact": artifact(model), "configuration": configuration(model),
        "model_dir": str(model_dir),
    }


def run_feasibility(name: str) -> Path:
    model = pinned(name)
    model_dir = DEST / name
    checks = preflight(model, model_dir)
    inputs = json.loads(EVAL05.read_text())
    cap = json.loads(EVAL05_CAP.read_text())
    messages = json.loads(EVAL06.read_text())["messages"]
    counts = eval06_tokens(model_dir, messages)
    record = header("feasibility", model, model_dir, checks)
    record["eval06_input_tokens"] = counts
    art, conf = record["artifact"], record["configuration"]
    boots, kills = {}, []
    for planned in feasibility_plan(inputs, cap, messages):
        cases, label = planned["cases"], planned["boot"]
        during = killer(cases, kills) if label == "worker_loss" else None
        limit = time_limit(cases)
        print(f"{label}: {len(cases)} cases, stopped after {limit / 60:.0f} min at most", flush=True)
        run = boot.run(label, [guest_case(c) for c in cases], INSTALLED, name, model_dir, limit, during)
        boots[label] = analyse(label, cases, run, art, conf, counts, {})
        wait_for_vm_exit(run.vm_pid)
    record["summary"] = summarise(boots, kills)
    record["installed_size"] = installed_size(model, model_dir)
    record["manual_steps"] = manual_steps()
    record["not_measured"] = NOT_MEASURED
    record["boots"] = boots
    path = write_record(name, "feasibility", record)
    print_feasibility(record, path)
    return path


def run_eval01(name: str) -> Path:
    model = pinned(name)
    model_dir = DEST / name
    checks = preflight(model, model_dir)
    samples = battery()
    record = header("eval01", model, model_dir, checks)
    record["about"] = ("EVAL01, the fast development screen: the daemon's 16 synthetic cases with its own "
                       "mechanical checks. Anyone may see these outputs; never a holdout, never a gate.")
    cases = [{"name": s["name"], "group": "eval01", "body": user(s["input"])} for s in samples]
    run = boot.run("eval01", [guest_case(c) for c in cases], INSTALLED, name, model_dir, time_limit(cases))
    analysed = analyse("eval01", cases, run, record["artifact"], record["configuration"], {}, {})
    for case, sample in zip(analysed["cases"], samples):
        case["screen"] = (screen(sample, case["texts"][0]) if case["stop_reason"] is None
                          else {"passed": False, "stopped": case["stop_reason"]})
        case["retain"], case["avoid"] = sample["retain"], sample["avoid"]
    wait_for_vm_exit(run.vm_pid)
    record["summary"] = {**measures.latency(analysed["cases"]),
                         "screen_passed": sum(c["screen"]["passed"] for c in analysed["cases"]),
                         "whole_boot": measures.window(run.samples, run.started_ns, run.ended_ns)
                         if run.samples else None}
    record["boots"] = {"eval01": analysed}
    path = write_record(name, "eval01", record)
    print_eval01(record, path)
    return path


# Printing.


def seconds(value: float | None) -> str:
    return "none (a stopped call holds that rank)" if value is None else f"{value:.2f} s"


def tor_seconds(value: float | None) -> str:
    return "never (Tor connections in that boot failed)" if value is None else f"{value:.2f} s"


def gib(value: int | None) -> str:
    return "not seen" if value is None else f"{value / 2**30:.2f} GiB"


def print_feasibility(record: dict, path: Path) -> None:
    s = record["summary"]
    e = s["eval06"]
    if record["development_only"]:
        print(f"\n{record['label']}")
    print(f"\nRecord: {path}")
    print(f"Cold load {seconds(s['cold']['load_seconds'])}; tor bootstrapped in {tor_seconds(s['cold']['tor_bootstrap_seconds'])}; "
          f"first result {seconds(s['cold']['host_start_to_first_result_seconds'])} after the host started")
    print(f"EVAL06: {e['rewritten']} of {e['cases']} rewritten; p50 {seconds(e['p50_seconds'])}, p95 {seconds(e['p95_seconds'])}; "
          f"proposed targets {'met' if e['meets_proposed_targets'] else 'not met'}")
    if e["stopped_by_reason"]:
        print(f"  stopped: {e['stopped_by_reason']}")
    for c in s["long"]["cases"]:
        print(f"Long {c['name']}: {c['outcome']}{' (' + c['stop_reason'] + ')' if c['stop_reason'] else ''} in {seconds(c['seconds'])}")
    for c in s["history"]:
        print(f"History {c['name']}: {c['outcome']} in {seconds(c['seconds'])} over {len(c['calls'])} calls")
    print(f"Cancellation: worker answered {seconds(s['cancellation']['cancel_to_answer_seconds'])} after the cancel; "
          f"next call {s['cancellation']['next_call']['outcome']} in {seconds(s['cancellation']['next_call']['seconds'])}")
    print(f"Worker loss: {[(c['name'], c['stop_reason'] or c['outcome']) for c in s['worker_loss']['cases']]}; "
          f"worker processes (exit status, load): "
          f"{[(p['exit_status'], seconds(p['load_seconds'])) for p in s['worker_loss']['worker_processes']]}")
    print(f"Restart: cold load {seconds(s['restart']['load_seconds'])}; "
          f"tor bootstrapped in {tor_seconds(s['restart']['tor_bootstrap_seconds'])}; "
          f"{[(c['name'], c['outcome']) for c in s['restart']['cases']]}")
    whole = s["memory_cpu_gpu"]["main"]["whole_boot"]
    if whole:
        print(f"Main boot peaks: worker {gib(whole['worker_peak_footprint_bytes'])}, guest VM {gib(whole['vm_peak_footprint_bytes'])}, "
              f"whole product {gib(whole['product_peak_footprint_bytes'])}; swap growth {whole['swap_growth_bytes'] / 2**20:.0f} MiB")
    a = s["end_to_end"]["all_cases"]
    print(f"All cases: {a['rewritten']} of {a['cases']} rewritten; stopped {a['stopped_by_reason']}")
    print(f"Installed on disk: {gib(record['installed_size']['total_on_disk_bytes'])}")
    print(f"Manual steps left for a person: {', '.join(m['step'] for m in record['manual_steps'])}")


def print_eval01(record: dict, path: Path) -> None:
    s = record["summary"]
    if record["development_only"]:
        print(f"\n{record['label']}")
    print(f"\nRecord: {path}")
    print(f"EVAL01: {s['rewritten']} of {s['cases']} rewritten, {s['screen_passed']} passed the daemon's screen; "
          f"p50 {seconds(s['p50_seconds'])}, p95 {seconds(s['p95_seconds'])}")
    for c in record["boots"]["eval01"]["cases"]:
        mark = "pass" if c["screen"]["passed"] else "fail"
        print(f"  {c['name']}: {mark} {c['stop_reason'] or ''} {c['screen'] if not c['screen']['passed'] else ''}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("kind", choices=("feasibility", "eval01"))
    parser.add_argument("name", help="a pinned model in reference/models.json, such as lead or challenger")
    args = parser.parse_args()
    # Stopped from outside (a watcher, a person): unwind, so each boot stops
    # its guest and removes its scratch files. No record is written.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("stage3: stopped from outside; no record written"))
    (run_feasibility if args.kind == "feasibility" else run_eval01)(args.name)


if __name__ == "__main__":
    main()
