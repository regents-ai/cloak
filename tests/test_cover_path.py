"""Functional checks of the daemon's own cover traffic in the guest
(zkapi-clientd/docs/COVER_TRAFFIC.md at the pinned commit). The host's tor is
the stand-in (fake_tor.py), which never reaches the network: it records each
SOCKS identity and destination and refuses it, so every cover request fails
at the route and nothing is fetched.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_cover_path.py

Each check boots the guest once with a cover list of its own in place of the
built image's /etc/cloak/cover.json (reference/cover.json): the built root,
then one more archive holding only that file, which the guest kernel unpacks
over it, as it unpacks the host's per-boot files
(host/Sources/CloakHost/BootFiles.swift). A guest whose daemon starts runs
one Pi task, whose model request stops at its Tor route, then waits 65
seconds in the sandbox, so the wait holds one of the daemon's once-a-minute
cover totals.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

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
CASES = [{"name": "task", "agent": {"prompt": "case:ok find the top 5 vegan restaurants in Tallinn", "continue": False}},
         {"name": "wait", "sandbox": ["/bin/sh", "-c", "sleep 65"]}]


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


def archive(path: str, data: bytes) -> bytes:
    """One file, root's and readable by all, then the trailer, as an
    uncompressed newc archive."""
    out = b""
    for inode, mode, name, body in [(1, 0o100444, path, data), (0, 0, "TRAILER!!!", b"")]:
        name = name.encode() + b"\0"
        fields = [inode, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name), 0]
        out += b"070701" + "".join(f"{field:08X}" for field in fields).encode() + name
        out += bytes(-len(out) % 4) + body
        out += bytes(-len(out) % 4)
    return out


def initrd(tmp_path: Path, cover: dict) -> Path:
    """The built root with this cover list laid over its own. The kernel
    skips zero bytes between archives, so the root is padded to the next
    4-byte boundary."""
    base = (ROOT / "guest/build/initrd.gz").read_bytes()
    path = tmp_path / "initrd"
    path.write_bytes(base + bytes(-len(base) % 4) + archive("etc/cloak/cover.json", json.dumps(cover).encode()))
    return path


def routes(tmp_path: Path) -> list[dict]:
    """Every connection the stand-in tor saw in the boot, in the order they
    ended."""
    log = tmp_path / "tor.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def boot(tmp_path: Path, cover: dict) -> tuple[str, dict[str, dict]]:
    """Boots the guest once with this cover list; its console and each case's result."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in CASES))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", initrd(tmp_path, cover),
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


def ran(out: str, results: dict[str, dict]) -> None:
    """The boot ran both cases, and the task reached its Tor route."""
    assert "cloak-guest: agent check exited 0" in out, out
    assert list(results) == [c["name"] for c in CASES]
    assert results["task"]["output"].strip() == TOR_STOP


def test_cover_goes_only_to_the_list_on_identities_of_its_own(tmp_path):
    out, results = boot(tmp_path, COVER)
    ran(out, results)
    seen = routes(tmp_path)
    # A connection cut off by the guest's power-off may end before it asks.
    asked = [r for r in seen if r["destination"] is not None]
    assert {r["destination"] for r in asked} <= COVER_DESTINATIONS | {CONVERSATION}
    conversation = {r["identity"] for r in asked if r["destination"] == CONVERSATION}
    cover = [r for r in asked if r["destination"] in COVER_DESTINATIONS]
    assert len(conversation) == 1 and "none" not in conversation
    assert cover
    identities = {r["identity"] for r in cover}
    assert "none" not in identities
    assert len(identities) <= COVER["concurrency"]
    assert not identities & conversation
    # No connection at all, asked or not, used any other identity.
    assert {r["identity"] for r in seen} - {"none"} <= identities | conversation
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
    out, results = boot(tmp_path, POOL)
    ran(out, results)
    asked = {r["destination"] for r in routes(tmp_path) if r["destination"] is not None}
    assert asked <= POOL_DESTINATIONS | {CONVERSATION}
    assert 0 < len(asked - {CONVERSATION}) <= 16


def test_an_empty_list_sends_no_cover(tmp_path):
    out, results = boot(tmp_path, COVER | {"urls": []})
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
    out, results = boot(tmp_path, cover)
    assert "cloak-guest: daemon did not start" in out, out
    assert results == {}
    assert routes(tmp_path) == []
