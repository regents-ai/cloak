"""The bounded stop of a lost worker, through the host and the guest: a
worker that breaks the protocol and then ignores being stopped is killed
once Child.exitLimit (10 seconds) has passed, and only then does its
replacement start and serve the next rewrite. The worker is the stand-in in
fake_stuck_worker.py; tor is the stand-in tor, which never reaches the
network.

    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_worker_stop.py
"""

import json
import os
import subprocess
import sys
from pathlib import Path

from test_guest_path import DEST, FAILED, HOST, NAME, ROOT, case, fake_tor

STUCK = ROOT / "tests/fake_stuck_worker.py"
LIMIT_S = 10


def stuck_worker(tmp_path: Path) -> Path:
    """A launcher that runs the stand-in as the host's own child process."""
    launcher = tmp_path / "stuck-worker"
    launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{STUCK}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


def running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_a_lost_worker_that_ignores_being_stopped_is_killed_before_its_replacement_starts(tmp_path):
    cases_file = tmp_path / "cases.jsonl"
    cases = [case("stuck", "case:stuck now"), case("after", "case:ok and this")]
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.run(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
         "--cases", cases_file, "--worker", stuck_worker(tmp_path), "--name", NAME, "--dir", DEST / NAME,
         "--tor", fake_tor(tmp_path), "--tor-data", tmp_path / "tor-data"],
        capture_output=True, text=True, timeout=600, env=os.environ | {"FAKE_WORKER_LOG": str(tmp_path)})
    assert host.returncode == 0, host.stderr
    results = {r["name"]: r for r in (json.loads(line) for line in host.stdout.splitlines() if line.startswith("{"))}
    assert (results["stuck"]["outcome"], results["stuck"]["error"]) == ("stopped", FAILED)
    assert results["after"]["outcome"] == "rewritten"
    assert results["after"]["texts"] == ["CASE:OK AND THIS"]

    assert f"the lost worker did not exit within {LIMIT_S} seconds of being stopped; killed it" in host.stderr
    events = [json.loads(line) for line in (tmp_path / "events.jsonl").read_text().splitlines()]
    starts = [e for e in events if e["event"] == "start"]
    (stuck,) = [e for e in events if e["event"] == "stuck"]
    assert len(starts) == 2 and stuck["pid"] == starts[0]["pid"]
    # The replacement started only once the lost worker had been given its
    # 10 seconds and killed, and the lost worker is gone.
    assert starts[1]["at"] - stuck["at"] >= LIMIT_S
    assert not running(starts[0]["pid"])
