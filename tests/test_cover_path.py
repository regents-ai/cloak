"""Functional checks of the daemon's own cover traffic in the guest
(zkapi-clientd/docs/COVER_TRAFFIC.md at the pinned commit). The host's tor is
the stand-in (fake_tor.py), which never reaches the network: it records each
SOCKS identity and destination and refuses it, so every cover request fails
at the route and nothing is fetched.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_cover_path.py

The first check boots the image as built, with the list it ships
(reference/cover.json, the image's /etc/cloak/cover.json). Each other check
boots the guest once with a cover list of its own laid over the image's
(cover_list.py). A guest whose daemon starts runs one Pi task, whose model
request stops at its Tor route, then waits in the sandbox: 65 seconds with a
list of the check's own, so the wait holds one of the daemon's once-a-minute
cover totals, and 200 seconds with the shipped list, whose 0.05 a second
then brings no cover at all about once in 22,000 boots (e^-10).
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

import pytest
from cover_list import BUILT, SHIPPED, initrd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_model import DEST  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
FAKE = ROOT / "tests/fake_worker.py"
FAKE_TOR = ROOT / "tests/fake_tor.py"
NAME = "standin-gguf-grammar"
TOR_STOP = ("Authenticated Tor route preparation failed before key acquisition. "
            "Check the configured Tor SOCKS listener; no direct fallback was used.")
CONVERSATION = "openrouter.ai:443"
# The reference's highest rate, so the waits hold hundreds of arrivals.
COVER = {"urls": ["https://cover-a.example/a.txt", "https://cover-b.example:443/b.json"],
         "rate": 5, "concurrency": 2}
COVER_DESTINATIONS = {"cover-a.example:443", "cover-b.example:443"}
# A pool of more than the daemon's 16, each on a host of its own.
POOL = COVER | {"urls": [f"https://pool-{n}.example/page.txt" for n in range(24)]}
POOL_DESTINATIONS = {f"pool-{n}.example:443" for n in range(24)}
# Every URL the daemon takes is on port 443 (cover.Config.Validate).
SHIPPED_DESTINATIONS = {f"{urlsplit(url).hostname}:443" for url in SHIPPED["urls"]}
TASK = {"name": "task", "agent": {"prompt": "case:ok find the top 5 vegan restaurants in Tallinn", "continue": False}}
CASES = [TASK, {"name": "wait", "sandbox": ["/bin/sh", "-c", "sleep 65"]}]
SHIPPED_CASES = [TASK, {"name": "wait", "sandbox": ["/bin/sh", "-c", "sleep 200"]}]


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
    ended."""
    log = tmp_path / "tor.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def boot(tmp_path: Path, root: Path, cases: list[dict] = CASES) -> tuple[str, dict[str, dict]]:
    """Boots the guest once from this root; its console and each case's result."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", root,
         "--cases", cases_file, "--worker", fake(tmp_path), "--name", NAME, "--dir", DEST / NAME,
         "--tor", fake_tor(tmp_path), "--tor-data", tmp_path / "tor-data"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=os.environ | {"FAKE_WORKER_LOG": str(tmp_path)})
    try:
        out, err = host.communicate(timeout=900)
    finally:
        host.kill()
    assert host.returncode == 0, err
    results = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    return out, {r["name"]: r for r in results}


def ran(out: str, results: dict[str, dict], cases: list[dict] = CASES) -> None:
    """The boot ran every case, and the task reached its Tor route."""
    assert "cloak-guest: agent check exited 0" in out, out
    assert list(results) == [c["name"] for c in cases]
    assert results["task"]["output"].strip() == TOR_STOP


def cover_routes(tmp_path: Path, destinations: set[str], concurrency: int) -> list[dict]:
    """The boot's cover connections, once checked: there are some, each asks
    for one of these destinations, they use no more identities than the
    concurrency and none of the conversation's, and no connection uses any
    other identity."""
    seen = routes(tmp_path)
    # A connection cut off by the guest's power-off may end before it asks.
    asked = [r for r in seen if r["destination"] is not None]
    assert {r["destination"] for r in asked} <= destinations | {CONVERSATION}
    conversation = {r["identity"] for r in asked if r["destination"] == CONVERSATION}
    cover = [r for r in asked if r["destination"] in destinations]
    assert len(conversation) == 1 and "none" not in conversation
    assert cover
    identities = {r["identity"] for r in cover}
    assert "none" not in identities
    assert len(identities) <= concurrency
    assert not identities & conversation
    # No connection at all, asked or not, used any other identity.
    assert {r["identity"] for r in seen} - {"none"} <= identities | conversation
    return cover


def test_the_image_as_built_sends_cover_to_its_own_list(tmp_path):
    out, results = boot(tmp_path, BUILT, SHIPPED_CASES)
    ran(out, results, SHIPPED_CASES)
    cover = cover_routes(tmp_path, SHIPPED_DESTINATIONS, SHIPPED["concurrency"])
    # The daemon was handed at most 16 of the pool's URLs.
    assert len({r["destination"] for r in cover}) <= 16


def test_cover_goes_only_to_the_list_on_identities_of_its_own(tmp_path):
    out, results = boot(tmp_path, initrd(tmp_path, COVER))
    ran(out, results)
    cover_routes(tmp_path, COVER_DESTINATIONS, COVER["concurrency"])
    # The daemon's totals line, in its log during the wait: every attempt
    # failed at the stand-in, and those not yet failed are still in flight.
    totals = [line.split("Cover totals: ")[1] for line in results["wait"]["daemon"] if "Cover totals: " in line]
    assert totals
    counts = {key: int(value) for key, value in (field.split("=") for field in totals[0].split())}
    assert counts["succeeded"] == 0 and counts["response_bytes"] == 0
    assert 0 < counts["attempted"] <= counts["failed"] + COVER["concurrency"]
    assert counts["failed"] <= counts["attempted"]


def test_a_pool_gives_the_daemon_at_most_sixteen_of_its_addresses(tmp_path):
    # The daemon itself refuses more than 16, so its start shows the pick.
    out, results = boot(tmp_path, initrd(tmp_path, POOL))
    ran(out, results)
    asked = {r["destination"] for r in routes(tmp_path) if r["destination"] is not None}
    assert asked <= POOL_DESTINATIONS | {CONVERSATION}
    assert 0 < len(asked - {CONVERSATION}) <= 16


def test_an_empty_list_sends_no_cover(tmp_path):
    out, results = boot(tmp_path, initrd(tmp_path, COVER | {"urls": []}))
    ran(out, results)
    assert [r["destination"] for r in routes(tmp_path)] == [CONVERSATION]


@pytest.mark.parametrize("cover", [
    COVER | {"urls": ["http://cover-a.example/a.txt"]},  # refused by the daemon's own validation
    COVER | {"rate": 6},  # over the daemon's own limit
    {"url": COVER["urls"], "rate": 5, "concurrency": 2},  # not the list's shape
    # The daemon's own validation refuses the 21st of 24, which a pick might skip.
    POOL | {"urls": POOL["urls"][:20] + ["http://pool-20.example/page.txt"] + POOL["urls"][21:]},
    POOL | {"urls": POOL["urls"] + POOL["urls"][3:4]},  # one address listed twice
    POOL | {"urls": POOL["urls"][:23] + ["https://pool-23.example/a.txt https://pool-24.example/b.txt"]},  # two in one entry
])
def test_a_list_the_daemon_cannot_take_stops_the_guest_before_any_task(tmp_path, cover):
    out, results = boot(tmp_path, initrd(tmp_path, cover))
    assert "cloak-guest: daemon did not start" in out, out
    assert results == {}
    assert routes(tmp_path) == []
