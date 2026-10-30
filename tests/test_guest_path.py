"""Functional checks of the whole rewrite path: the daemon's own rewrite code
in the guest, the guest adapter, the host supervisor and a worker. Each check
boots the guest once and runs a list of cases through the daemon's
Transcript.Rewrite; the guest prints one result per case.

    guest/build.sh
    (cd host && swift build -c release -j 2 && codesign -s - --entitlements cloak-host.entitlements -f .build/release/cloak-host)
    uv run --with pytest==8.4.2 pytest tests/test_guest_path.py

The checks with the fake worker cover every reply the daemon must refuse;
the checks with the real worker cover a real rewrite, cancellation and the
loss of the worker. The deadline check waits out the daemon's 90 seconds.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from drive_worker import request_body  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
WORKER = Path(os.environ.get("CLOAK_WORKER", ROOT / "worker/.xcode/Build/Products/Release/cloak-rewriter"))
FAKE = ROOT / "tests/fake_worker.py"
NAME = "standin"
FAILED = "rewriter failed; original prompt was not sent to the target model"
LONG = " ".join(
    f"On day {i} the travelling group walked along the river, counted the boats, "
    "wrote down the weather, and argued about where to sleep that night."
    for i in range(1, 240))


def case(name: str, text: str, cancel_after_ms: int = 0) -> dict:
    body = {"model": "target", "messages": [{"role": "user", "content": text}]}
    return {"name": name, "body": body, "cancel_after_ms": cancel_after_ms}


def boot(tmp_path: Path, cases: list[dict], worker: Path, during=None) -> dict[str, dict]:
    """Runs the cases in one guest boot and returns each case's result."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
         "--cases", cases_file, "--worker", worker, "--manifest", ROOT / "reference/models.json",
         "--name", NAME, "--dir", ROOT / "models" / NAME],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=os.environ | {"FAKE_WORKER_LOG": str(tmp_path)})
    try:
        if during:
            during(host)
        out, err = host.communicate(timeout=600)
    finally:
        host.kill()
    assert host.returncode == 0, err
    assert "cloak-guest: check exited 0" in out, out + err
    results = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    assert [r["name"] for r in results] == [c["name"] for c in cases]
    return {r["name"]: r for r in results}


def test_requests_reach_the_worker_unchanged_and_good_replies_come_back(tmp_path):
    texts = ["case:ok Hi there <friend> &   café, please list rivers"]
    results = boot(tmp_path, [case("ok", texts[0])], FAKE)
    assert results["ok"]["outcome"] == "rewritten"
    assert results["ok"]["texts"] == [t.upper() for t in texts]
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, texts)


@pytest.mark.parametrize("fault", [
    "fenced", "extra-field", "wrong-count", "length", "tool-call", "refusal",
    "status-500", "not-json", "oversized",
])
def test_the_daemon_refuses_every_bad_reply(tmp_path, fault):
    results = boot(tmp_path, [case(fault, f"case:{fault} please rewrite this"),
                              case("next", "case:ok and this")], FAKE)
    assert (results[fault]["outcome"], results[fault]["error"]) == ("stopped", FAILED)
    assert results["next"]["outcome"] == "rewritten"


def test_a_client_that_gives_up_cancels_the_rewrite(tmp_path):
    # The daemon reports a cut-off rewrite call as a plain failure; the cancel
    # file shows the cancel reached the worker.
    results = boot(tmp_path, [case("held", "case:hold wait", cancel_after_ms=500),
                              case("next", "case:ok and this")], FAKE)
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert results["held"]["seconds"] < 2
    assert (tmp_path / "1.cancel").exists()
    assert results["next"]["outcome"] == "rewritten"


def test_the_daemon_deadline_still_holds(tmp_path):
    results = boot(tmp_path, [case("held", "case:hold wait")], FAKE)
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert 89 < results["held"]["seconds"] < 95
    assert (tmp_path / "1.cancel").exists()


def test_a_lost_worker_fails_this_and_every_later_rewrite(tmp_path):
    results = boot(tmp_path, [case("exit", "case:exit now"), case("after", "case:ok and this")], FAKE)
    assert (results["exit"]["outcome"], results["exit"]["error"]) == ("stopped", FAILED)
    assert (results["after"]["outcome"], results["after"]["error"]) == ("stopped", FAILED)
    assert results["after"]["seconds"] < 1


def test_the_real_worker_rewrites_through_the_daemon(tmp_path):
    results = boot(tmp_path, [case("plain", "Hey, could you please tell me the three biggest rivers in Europe? Thanks!!")], WORKER)
    assert results["plain"]["outcome"] == "rewritten"
    assert len(results["plain"]["texts"]) == 1


def test_cancelling_frees_the_real_worker(tmp_path):
    # Uncancelled, this rewrite runs for about forty seconds on the stand-in.
    results = boot(tmp_path, [case("long", LONG, cancel_after_ms=2000),
                              case("plain", "Hey, could you please tell me the three biggest rivers in Europe? Thanks!!")], WORKER)
    assert (results["long"]["outcome"], results["long"]["error"]) == ("stopped", FAILED)
    assert results["long"]["seconds"] < 3
    assert results["plain"]["outcome"] == "rewritten"
    assert results["plain"]["seconds"] < 10


def test_losing_the_real_worker_mid_rewrite_fails_safely(tmp_path):
    def kill_worker_mid_rewrite(host):
        while not (pids := subprocess.run(["pgrep", "-P", str(host.pid)], capture_output=True, text=True).stdout.split()):
            time.sleep(0.1)
        # Model load, boot and the start of the long rewrite take well under this.
        time.sleep(8)
        subprocess.run(["kill", "-9", pids[0]], check=True)

    results = boot(tmp_path, [case("long", LONG), case("after", "what is two plus two")], WORKER,
                   during=kill_worker_mid_rewrite)
    assert (results["long"]["outcome"], results["long"]["error"]) == ("stopped", FAILED)
    assert results["long"]["seconds"] < 30
    assert (results["after"]["outcome"], results["after"]["error"]) == ("stopped", FAILED)
