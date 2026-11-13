"""Functional checks of the agent path in the guest: Pi 1.3.0 inside the
reference wrapper (bubblewrap with torsocks), as its own user, talking to the
daemon's local API, whose rewrite goes through the guest adapter, the host
and a worker. The guest has no network device; its Tor port leads to the
host's tor, here the stand-in (fake_tor.py), which never reaches the network:
it records each SOCKS identity and destination and refuses it, so every
model request stops at Tor route preparation after its rewrite.

    worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_agent_path.py

Each check boots the guest once; the guest prints one result per case.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import WORKERS, request_body  # noqa: E402
from fetch_model import DEST  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
FAKE = ROOT / "tests/fake_worker.py"
FAKE_TOR = ROOT / "tests/fake_tor.py"
NAME = "standin"
TOR_STOP = ("Authenticated Tor route preparation failed before key acquisition. "
            "Check the configured Tor SOCKS listener; no direct fallback was used.")


def agent(name: str, prompt: str, keep: bool = False) -> dict:
    return {"name": name, "agent": {"prompt": prompt, "continue": keep}}


def sandbox(name: str, script: str) -> dict:
    return {"name": name, "sandbox": ["/bin/sh", "-c", script]}


def fake(tmp_path: Path) -> Path:
    launcher = tmp_path / "fake-worker"
    launcher.write_text(f'#!/bin/sh\nexport FAKE_WORKER_READ_DELAY=0\nexec "{sys.executable}" -I "{FAKE}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


def fake_tor(tmp_path: Path) -> Path:
    launcher = tmp_path / "fake-tor"
    launcher.write_text(f'#!/bin/sh\nexport FAKE_TOR_LOG="{tmp_path}" FAKE_TOR_START=ready\n'
                        f'exec "{sys.executable}" -I "{FAKE_TOR}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


def routes(tmp_path: Path) -> list[dict]:
    """Every connection the stand-in tor saw in the boot, in the order they
    ended; the cases run one after another."""
    log = tmp_path / "tor.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def boot(tmp_path: Path, cases: list[dict], worker: Path) -> dict[str, dict]:
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
         "--cases", cases_file, "--worker", worker, "--name", NAME, "--dir", DEST / NAME,
         "--tor", fake_tor(tmp_path), "--tor-data", tmp_path / "tor-data"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=os.environ | {"FAKE_WORKER_LOG": str(tmp_path)})
    try:
        out, err = host.communicate(timeout=900)
    finally:
        host.kill()
    assert host.returncode == 0, err
    assert "cloak-guest: agent check exited 0" in out, out + err
    results = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    assert [r["name"] for r in results] == [c["name"] for c in cases]
    return {r["name"]: r for r in results}


def test_pi_prompts_are_rewritten_then_stop_at_the_tor_route(tmp_path):
    prompts = ["case:ok find the top 5 vegan restaurants in Tallinn", "case:ok which are open on Sunday"]
    results = boot(tmp_path, [agent("first", prompts[0]), agent("second", prompts[1], keep=True)], fake(tmp_path))
    for n, (name, prompt) in enumerate(zip(["first", "second"], prompts), start=1):
        r = results[name]
        assert r["exit"] != 0
        assert r["output"].strip() == TOR_STOP
        # The new turn reaches the worker exactly as the daemon's rewrite asks.
        assert (tmp_path / f"{n}.json").read_bytes() == request_body(NAME, [prompt])
        assert any("status=200" in line for line in r["daemon"])
    assert [a["destination"] for a in routes(tmp_path)] == ["openrouter.ai:443"] * 2
    assert not (tmp_path / "3.json").exists()


def test_a_continued_conversation_keeps_its_identity_and_a_new_one_gets_its_own(tmp_path):
    boot(tmp_path, [agent("one", "case:ok first question"),
                    agent("one-more", "case:ok follow-up", keep=True),
                    agent("two", "case:ok unrelated question")], fake(tmp_path))
    one, one_more, two = [a["identity"] for a in routes(tmp_path)]
    assert one != "none"
    assert one_more == one
    assert two != one


def test_a_bad_rewrite_stops_the_task_and_the_next_one_still_runs(tmp_path):
    results = boot(tmp_path, [agent("bad", "case:fenced please"), agent("next", "case:ok and this")], fake(tmp_path))
    assert results["bad"]["exit"] != 0
    assert "rewrite" in results["bad"]["output"].lower()
    assert TOR_STOP not in results["bad"]["output"]
    assert results["next"]["output"].strip() == TOR_STOP


def test_a_lost_worker_stops_its_task_and_the_next_task_runs(tmp_path):
    results = boot(tmp_path, [agent("exit", "case:exit now"), agent("after", "case:ok and this")], fake(tmp_path))
    assert results["exit"]["exit"] != 0
    assert "rewrite" in results["exit"]["output"].lower()
    assert TOR_STOP not in results["exit"]["output"]
    assert results["after"]["output"].strip() == TOR_STOP


def test_a_prompt_over_the_input_limit_stops_its_task_with_the_length_and_the_limit(tmp_path):
    over = "case:ok " + "x" * (10_001 - len("case:ok "))
    results = boot(tmp_path, [agent("over", over), agent("next", "case:ok and this")], fake(tmp_path))
    assert results["over"]["exit"] != 0
    assert "10,001" in results["over"]["output"] and "10,000" in results["over"]["output"]
    assert TOR_STOP not in results["over"]["output"]
    assert results["next"]["output"].strip() == TOR_STOP
    # Nothing of the long prompt reached the worker.
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, ["case:ok and this"])
    assert not (tmp_path / "2.json").exists()


FETCH = ("node -e 'fetch(process.argv[1], {method: process.argv[2], signal: AbortSignal.timeout(5000)})"
         ".then(r => console.log(r.status), e => console.log(\"refused\", e.cause?.code ?? e.name))' ")


def test_the_sandbox_holds(tmp_path):
    results = boot(tmp_path, [
        sandbox("secrets", "ls /run/cloak /etc/cloak 2>&1; echo $?"),
        sandbox("processes", "ps -o comm"),
        sandbox("files", "touch /usr/probe 2>&1; touch /workspace/p /home/agent/p /tmp/p && echo written"),
        sandbox("devices", "cat /proc/net/dev"),
        sandbox("adapter", FETCH + "http://127.0.0.1:8012/v1/chat/completions POST"),
        sandbox("admin", FETCH + "http://127.0.0.1:8787/admin/status GET"),
        sandbox("outbound", FETCH + "https://93.184.215.14/ GET"),
        sandbox("bypass", "busybox nc -w 3 93.184.215.14 443 </dev/null 2>&1; echo $?"),
    ], fake(tmp_path))
    out = {name: r["output"] for name, r in results.items()}
    assert "No such file or directory" in out["secrets"] and out["secrets"].strip().endswith("1")
    assert "cloak-daemon" not in out["processes"] and "cloak-adapter" not in out["processes"]
    assert "Read-only file system" in out["files"] and "written" in out["files"]
    devices = [line.split(":")[0].strip() for line in out["devices"].splitlines()[2:]]
    assert devices == ["lo"]
    assert out["adapter"].strip() == "401"
    assert out["admin"].strip() == "401"
    # Node's connection goes to the Tor port and nowhere else; a static
    # program skips torsocks, finds no network device, and never reaches tor.
    assert "General SOCKS server failure" in out["outbound"] and "refused" in out["outbound"]
    assert "Network is unreachable" in out["bypass"]
    assert [a["destination"] for a in routes(tmp_path)] == ["93.184.215.14:443"]


def test_pi_with_the_real_worker(tmp_path):
    prompt = "Hey, could you please find me the three best vegan restaurants in Tallinn? Thanks!!"
    results = boot(tmp_path, [agent("pi", prompt)], WORKERS["mlx"])
    assert results["pi"]["output"].strip() == TOR_STOP
    assert [a["destination"] for a in routes(tmp_path)] == ["openrouter.ai:443"]
