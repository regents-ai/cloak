"""Functional checks of the whole rewrite path: the daemon's own rewrite code
in the guest, the guest adapter, the host supervisor and a worker. Each check
boots the guest once and runs a list of cases through the daemon's
Transcript.Rewrite; the guest prints one result per case.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_guest_path.py

The checks with the fake worker cover every reply the daemon must refuse,
the new worker the host starts after a loss, and the input limit and
deadline of decision 6 in docs/plan.md: an input over 10,000 characters is
refused before any call, and each call's deadline is 90 seconds plus 20 ms a
character, so the deadline checks wait out about 90 and 290 seconds. The
checks with the real worker cover a real rewrite, cancellation (while it
generates and early in the longest prompt the daemon accepts) and the loss
of the worker. The host's tor is the stand-in (fake_tor.py), which never
reaches the network; nothing here uses Tor.
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
from drive_worker import WORKER, request_body  # noqa: E402
from fetch_model import DEST  # noqa: E402
from measures import MAX_INPUT_CHARACTERS, deadline_s  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
FAKE = ROOT / "tests/fake_worker.py"
FAKE_TOR = ROOT / "tests/fake_tor.py"
NAME = "standin-gguf-grammar"
FAILED = "rewriter failed; original prompt was not sent to the target model"
# The stand-in rewrites this one cleanly.
PLAIN = "Hey, could you please tell me the three biggest rivers in Europe? Thanks!!"
# 120 text parts, 9,130 characters, within the daemon's input limit. The
# reply must hold all 120 texts, so the stand-in rewrites for about 12 s.
LONG = [{"type": "text", "text": f"Please write a long, friendly paragraph about the history of city number {i}."}
        for i in range(120)]


def case(name: str, content: str | list[dict], cancel_after_ms: int = 0) -> dict:
    body = {"model": "target", "messages": [{"role": "user", "content": content}]}
    return {"name": name, "body": body, "cancel_after_ms": cancel_after_ms}


def sized(start: str, characters: int, fill: str = "é") -> str:
    """A text of exactly this many characters. The default fill is two bytes
    a character, so a limit that counted bytes would show."""
    return start + fill * (characters - len(start))


def fake(tmp_path: Path, read_delay: float = 0, starts: int = 0) -> Path:
    """A launcher that runs the fake worker as the host's own child process,
    as the real worker is, so closing its channel ends are final. Each start
    is noted in `starts`; with `starts` set, a later start fails before the
    worker is ready."""
    refuse = f'[ "$(wc -l < "{tmp_path}/starts")" -le {starts} ] || exit 2\n' if starts else ""
    launcher = tmp_path / "fake-worker"
    launcher.write_text(f'#!/bin/sh\necho start >> "{tmp_path}/starts"\n{refuse}'
                        f'export FAKE_WORKER_READ_DELAY={read_delay}\n'
                        f'exec "{sys.executable}" -I "{FAKE}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


def starts(tmp_path: Path) -> int:
    return len((tmp_path / "starts").read_text().splitlines())


def fake_tor(tmp_path: Path) -> Path:
    """A launcher that runs the stand-in tor as the host's own child."""
    launcher = tmp_path / "fake-tor"
    launcher.write_text(f'#!/bin/sh\nexport FAKE_TOR_LOG="{tmp_path}" FAKE_TOR_START=ready\n'
                        f'exec "{sys.executable}" -I "{FAKE_TOR}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


def boot(tmp_path: Path, cases: list[dict], worker: Path, during=None) -> dict[str, dict]:
    """Runs the cases in one guest boot and returns each case's result."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
         "--cases", cases_file, "--worker", worker, "--name", NAME, "--dir", DEST / NAME,
         "--tor", fake_tor(tmp_path), "--tor-data", tmp_path / "tor-data"],
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
    results = boot(tmp_path, [case("ok", texts[0])], fake(tmp_path))
    assert results["ok"]["outcome"] == "rewritten"
    assert results["ok"]["texts"] == [t.upper() for t in texts]
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, texts)


@pytest.mark.parametrize("fault", [
    "fenced", "extra-field", "wrong-count", "length", "tool-call", "refusal",
    "status-500", "not-json", "oversized",
])
def test_the_daemon_refuses_every_bad_reply(tmp_path, fault):
    results = boot(tmp_path, [case(fault, f"case:{fault} please rewrite this"),
                              case("next", "case:ok and this")], fake(tmp_path))
    assert (results[fault]["outcome"], results[fault]["error"]) == ("stopped", FAILED)
    assert results["next"]["outcome"] == "rewritten"


def test_a_client_that_gives_up_cancels_the_rewrite(tmp_path):
    # The daemon reports a cut-off rewrite call as a plain failure; the cancel
    # file shows the cancel reached the worker.
    results = boot(tmp_path, [case("held", "case:hold wait", cancel_after_ms=500),
                              case("next", "case:ok and this")], fake(tmp_path))
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert results["held"]["seconds"] < 2
    assert (tmp_path / "1.cancel").exists()
    assert results["next"]["outcome"] == "rewritten"


def test_a_client_that_gives_up_before_the_worker_has_its_request_cancels_it(tmp_path):
    # This request is larger than the channel to the worker holds (each "<"
    # is seven bytes once the daemon and the request encode it, about 71 KB
    # in all), and the worker leaves it unread for two seconds, so the client
    # gives up while the host is still handing it over.
    held = sized("case:hold ", MAX_INPUT_CHARACTERS, fill="<")
    assert len(request_body(NAME, [held])) > 64 << 10
    results = boot(tmp_path, [case("held", held, cancel_after_ms=500),
                              case("next", "case:ok and this")], fake(tmp_path, read_delay=2))
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert (tmp_path / "1.cancel").exists()
    assert results["next"]["outcome"] == "rewritten"


def test_a_short_input_keeps_the_base_deadline(tmp_path):
    text = "case:hold wait"
    results = boot(tmp_path, [case("held", text)], fake(tmp_path))
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert deadline_s([text]) <= results["held"]["seconds"] < deadline_s([text]) + 3 < 94
    assert (tmp_path / "1.cancel").exists()


def test_the_longest_input_is_accepted_and_given_the_grown_deadline(tmp_path):
    # Both are exactly 10,000 characters, 19,990 bytes. The first is answered
    # after 100 seconds, past the base deadline; the second waits out its own
    # deadline, 290 seconds.
    slow = sized("case:slow ", MAX_INPUT_CHARACTERS)
    held = sized("case:hold ", MAX_INPUT_CHARACTERS)
    results = boot(tmp_path, [case("slow", slow), case("held", held)], fake(tmp_path))
    assert results["slow"]["outcome"] == "rewritten"
    assert results["slow"]["texts"] == [slow.upper()]
    assert 100 <= results["slow"]["seconds"] < 103
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, [slow])
    assert (results["held"]["outcome"], results["held"]["error"]) == ("stopped", FAILED)
    assert 289 < deadline_s([held]) <= results["held"]["seconds"] < deadline_s([held]) + 3
    assert (tmp_path / "2.json").read_bytes() == request_body(NAME, [held])
    assert (tmp_path / "2.cancel").exists()


def test_an_input_over_the_limit_is_refused_at_once(tmp_path):
    over = sized("case:ok ", MAX_INPUT_CHARACTERS + 1, fill="x")
    results = boot(tmp_path, [case("over", over), case("next", "case:ok and this")], fake(tmp_path))
    assert results["over"]["outcome"] == "stopped"
    assert results["over"]["seconds"] < 1
    # The message gives the length received and the limit.
    assert "10,001" in results["over"]["error"] and "10,000" in results["over"]["error"]
    assert results["next"]["outcome"] == "rewritten"
    # The worker's only request is the next one: nothing of the long input reached it.
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, ["case:ok and this"])
    assert not (tmp_path / "2.json").exists()


def test_a_lost_worker_fails_its_rewrite_and_a_new_worker_serves_the_next(tmp_path):
    results = boot(tmp_path, [case("exit", "case:exit now"), case("after", "case:ok and this")], fake(tmp_path))
    assert (results["exit"]["outcome"], results["exit"]["error"]) == ("stopped", FAILED)
    assert results["after"]["outcome"] == "rewritten"
    assert starts(tmp_path) == 2
    # The new worker's only request is the next one: the lost one is not sent again.
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, ["case:ok and this"])
    assert not (tmp_path / "2.json").exists()


def test_a_lost_worker_has_exited_before_its_replacement_starts(tmp_path):
    # The worker breaks the protocol, so the host loses it; once stopped it
    # takes two seconds to exit, and notes how many workers had started then.
    results = boot(tmp_path, [case("bad", "case:bad-frame now"), case("after", "case:ok and this")], fake(tmp_path))
    assert (results["bad"]["outcome"], results["bad"]["error"]) == ("stopped", FAILED)
    assert results["after"]["outcome"] == "rewritten"
    assert (tmp_path / "exited").read_text() == "1"
    assert starts(tmp_path) == 2


def test_a_worker_lost_between_rewrites_fails_only_the_next_rewrite(tmp_path):
    results = boot(tmp_path, [case("last", "case:exit-after-answer now"), case("after", "case:ok and this"),
                              case("later", "case:ok and this too")], fake(tmp_path))
    assert results["last"]["outcome"] == "rewritten"
    assert (results["after"]["outcome"], results["after"]["error"]) == ("stopped", FAILED)
    assert results["later"]["outcome"] == "rewritten"
    assert starts(tmp_path) == 2
    assert (tmp_path / "1.json").read_bytes() == request_body(NAME, ["case:ok and this too"])


def test_a_new_worker_that_cannot_start_leaves_every_later_rewrite_failing(tmp_path):
    results = boot(tmp_path, [case("exit", "case:exit now"), case("after", "case:ok and this"),
                              case("later", "case:ok and this too")], fake(tmp_path, starts=1))
    for name in ("exit", "after", "later"):
        assert (results[name]["outcome"], results[name]["error"]) == ("stopped", FAILED)
    assert results["later"]["seconds"] < 1
    assert starts(tmp_path) == 2  # one failed start, and no more tries


def test_the_real_worker_rewrites_through_the_daemon(tmp_path):
    results = boot(tmp_path, [case("plain", PLAIN)], WORKER)
    assert results["plain"]["outcome"] == "rewritten"
    assert len(results["plain"]["texts"]) == 1


def test_cancelling_frees_the_real_worker(tmp_path):
    # Uncancelled, this rewrite runs for about 12 seconds on the stand-in.
    results = boot(tmp_path, [case("long", LONG, cancel_after_ms=2000),
                              case("plain", PLAIN)], WORKER)
    assert (results["long"]["outcome"], results["long"]["error"]) == ("stopped", FAILED)
    assert results["long"]["seconds"] < 3
    assert results["plain"]["outcome"] == "rewritten"
    assert results["plain"]["seconds"] < 10


def test_a_client_that_gives_up_early_in_the_longest_prompt_frees_the_real_worker(tmp_path):
    # The longest prompt the daemon accepts, 10,000 characters of prose; the
    # client gives up 300 ms in, aiming at the stand-in's reading of it, which
    # takes under a second. Nothing here shows where the cancel landed;
    # tests/test_llama_worker.py checks a cancel one second into a long read
    # directly.
    prose = json.loads((ROOT / "reference/eval05-inputs.json").read_text())["prose"][:MAX_INPUT_CHARACTERS]
    results = boot(tmp_path, [case("long", prose, cancel_after_ms=300), case("plain", PLAIN)], WORKER)
    assert (results["long"]["outcome"], results["long"]["error"]) == ("stopped", FAILED)
    assert results["plain"]["outcome"] == "rewritten"
    assert results["plain"]["seconds"] < 5


def test_losing_the_real_worker_mid_rewrite_fails_that_rewrite_and_a_new_worker_serves_the_next(tmp_path):
    def kill_worker_mid_rewrite(host):
        while not (pids := subprocess.run(["pgrep", "-P", str(host.pid)], capture_output=True, text=True).stdout.split()):
            time.sleep(0.1)
        # Model load and boot take well under this, and the long rewrite,
        # about 12 seconds on the stand-in, is under way.
        time.sleep(8)
        subprocess.run(["kill", "-9", pids[0]], check=True)

    results = boot(tmp_path, [case("long", LONG), case("after", PLAIN)], WORKER, during=kill_worker_mid_rewrite)
    assert (results["long"]["outcome"], results["long"]["error"]) == ("stopped", FAILED)
    assert results["long"]["seconds"] < 30
    assert results["after"]["outcome"] == "rewritten"
