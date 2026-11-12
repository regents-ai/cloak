"""Functional checks of the guest's one way out (docs/plan.md, "Tor out of the
guest"): the guest has no network device, and its Tor port leads over vsock
to the host's Tor relay, which passes only a SOCKS5 greeting on, to tor's
SOCKS port.

    worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_tor_path.py

Only the first check sends anything off the Mac. It runs the Tor Project's
tor (from host/build.sh) on the public Tor network: tor's own connections to
build its circuits; one name lookup of check.torproject.org through Tor; one
HTTPS request through Tor to https://check.torproject.org/api/ip; and the
Tor route checks of one Pi task (one for each time Pi sends its request,
which it repeats after the wallet companion's error), whose destination
(openrouter.ai:443) this check's tor maps to check.torproject.org:443, so a
Tor exit opens a connection there that the daemon closes at once, sending
nothing, and no model provider is contacted. The other checks use the
stand-in tor (fake_tor.py), or tor whose only way onto the network is a
closed port on the Mac's loopback.

The host starts the guest only once tor has bootstrapped, or after it has
exited or been stopped at the host's 90-second limit. Each check boots the
guest once; the guest prints one result per case.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_model import DEST  # noqa: E402

HOST = ROOT / "host/.build/release/cloak-host"
TOR = ROOT / "host/.build/tor/tor"
FAKE = ROOT / "tests/fake_worker.py"
FAKE_TOR = ROOT / "tests/fake_tor.py"
NAME = "standin"
TOR_STOP = ("Authenticated Tor route preparation failed before key acquisition. "
            "Check the configured Tor SOCKS listener; no direct fallback was used.")
PROMPT = "case:ok find the top 5 vegan restaurants in Tallinn"


def agent(name: str, prompt: str) -> dict:
    return {"name": name, "agent": {"prompt": prompt, "continue": False}}


def sandbox(name: str, script: str) -> dict:
    return {"name": name, "sandbox": ["/bin/sh", "-c", script]}


def fetch(url: str, timeout_ms: int) -> str:
    """Node in the sandbox, so under torsocks: prints whether Tor carried the
    request, or why it failed. Node's https waits for as long as tor takes to
    answer, where Node's fetch gives up after its own 10-second connect
    limit."""
    return (f"node -e 'require(\"https\").get(\"{url}\", {{signal: AbortSignal.timeout({timeout_ms})}}, r => {{"
            "let body = \"\"; r.on(\"data\", d => body += d); r.on(\"end\", () => console.log(JSON.parse(body).IsTor))})"
            ".on(\"error\", e => console.log(\"refused\", e.code ?? e.name, e.message))'")


def launcher(tmp_path: Path, name: str, body: str) -> Path:
    path = tmp_path / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


def fake(tmp_path: Path) -> Path:
    return launcher(tmp_path, "fake-worker", f'export FAKE_WORKER_READ_DELAY=0\nexec "{sys.executable}" -I "{FAKE}" "$@"\n')


def fake_tor(tmp_path: Path, start: str) -> Path:
    """The stand-in tor, started as FAKE_TOR_START says (fake_tor.py)."""
    return launcher(tmp_path, "fake-tor", f'export FAKE_TOR_LOG="{tmp_path}" FAKE_TOR_START={start}\n'
                                          f'exec "{sys.executable}" -I "{FAKE_TOR}" "$@"\n')


def tor(tmp_path: Path, *settings: str) -> Path:
    """tor itself, with the host's settings and then these."""
    return launcher(tmp_path, "tor", f'exec "{TOR}" "$@" ' + " ".join(f'"{s}"' for s in settings) + "\n")


def routes(tmp_path: Path) -> list[dict]:
    log = tmp_path / "tor.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def boot(tmp_path: Path, cases: list[dict], tor_launcher: Path) -> tuple[dict[str, dict], str]:
    """Runs the cases in one guest boot; returns each case's result and the
    host's log."""
    cases_file = tmp_path / "cases.jsonl"
    cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
    host = subprocess.Popen(
        [HOST, "--kernel", ROOT / "guest/build/Image", "--initrd", ROOT / "guest/build/initrd.gz",
         "--cases", cases_file, "--worker", fake(tmp_path), "--name", NAME, "--dir", DEST / NAME,
         "--tor", tor_launcher],
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
    return {r["name"]: r for r in results}, err


def unreachable(output: str) -> bool:
    return "Network is unreachable" in output


def test_tor_carries_the_guest_and_a_program_that_skips_torsocks_reaches_nothing(tmp_path):
    # The host starts the guest only once tor has bootstrapped, so the
    # request through Tor is sent at once.
    results, err = boot(tmp_path, [
        sandbox("devices", "cat /proc/net/dev"),
        sandbox("through tor", fetch("https://check.torproject.org/api/ip", 60_000)),
        agent("pi", PROMPT),
        # The stage 1 routing check's static probe, run the same way: in the
        # agent's sandbox, with tor bootstrapped.
        sandbox("static probe", "cloak-routing-probe"),
        sandbox("no torsocks", "env -u LD_PRELOAD " + fetch("https://93.184.215.14/", 10_000)),
        sandbox("tcp ipv4", "busybox nc -w 3 93.184.215.14 443 </dev/null 2>&1; echo $?"),
        sandbox("tcp ipv6", "busybox nc -w 3 2606:2800:21f:cb07:6820:80da:af6b:8b2c 443 </dev/null 2>&1; echo $?"),
    ], tor(tmp_path, "--MapAddress", "openrouter.ai check.torproject.org"))
    out = {name: r["output"] for name, r in results.items()}
    assert [line.split(":")[0].strip() for line in out["devices"].splitlines()[2:]] == ["lo"]
    assert "Bootstrapped 100% (done)" in err
    assert out["through tor"].strip() == "true"
    # The Pi task passes Tor route preparation and stops at the next step that
    # is not built: the wallet companion.
    assert TOR_STOP not in out["pi"]
    assert "The wallet companion could not be reached" in out["pi"]
    assert "tcp: blocked" in out["static probe"] and "udp dns: blocked" in out["static probe"]
    assert out["no torsocks"].startswith("refused ENETUNREACH")
    assert unreachable(out["tcp ipv4"]) and unreachable(out["tcp ipv6"])


NC = "busybox nc -w 3 127.0.0.1 9050"


def test_the_relay_passes_only_a_socks5_greeting_and_no_other_port_answers(tmp_path):
    results, err = boot(tmp_path, [
        # Through the guest's Tor port, each held open for 2 s for an answer.
        sandbox("http", f"(printf 'GET / HTTP/1.0\\r\\n\\r\\n'; sleep 2) | {NC} | wc -c"),
        sandbox("socks4", f"(printf '\\004\\001\\001\\273\\135\\270\\327\\016\\000'; sleep 2) | {NC} | wc -c"),
        sandbox("socks5 gssapi only", f"(printf '\\005\\001\\001'; sleep 2) | {NC} | wc -c"),
        sandbox("socks5 no methods", f"(printf '\\005\\000'; sleep 2) | {NC} | wc -c"),
        sandbox("socks5", f"(printf '\\005\\001\\000'; sleep 2) | {NC} | od -An -tx1"),
        # Straight to the host over vsock, past the guest's Tor port.
        sandbox("vsock http", "cloak-vsock-probe 9050 'GET / HTTP/1.0\\r\\n\\r\\n'"),
        sandbox("vsock socks5", "cloak-vsock-probe 9050 '\\x05\\x01\\x00'"),
        sandbox("vsock other ports", "for port in 22 53 80 443 1080 8080 9051; do cloak-vsock-probe $port x; done"),
        sandbox("vsock rewrite port", "cloak-vsock-probe 8012 x"),
    ], fake_tor(tmp_path, "ready"))
    out = {name: r["output"] for name, r in results.items()}
    for name in ["http", "socks4", "socks5 gssapi only", "socks5 no methods"]:
        assert out[name].strip() == "0", name
    assert out["socks5"].split() == ["05", "00"]
    assert out["vsock http"].startswith("closed, no answer")
    assert out["vsock socks5"].strip() == "answered 0500"
    other = out["vsock other ports"].splitlines()
    assert len(other) == 7 and all(line.startswith("refused") for line in other)
    assert out["vsock rewrite port"].startswith("closed, no answer")
    assert err.count("refused a Tor port connection that did not open with a SOCKS5 greeting") == 5
    # tor saw the two greetings it should have, and nothing else.
    assert routes(tmp_path) == [{"identity": "none", "destination": None}] * 2


def test_a_task_started_with_the_host_passes_its_tor_route_once_tor_has_bootstrapped(tmp_path):
    # The stand-in bootstraps 10 s after its port opens and refuses every
    # request until then, as tor does; the Pi task is the boot's first, and
    # reaches its Tor route within 2 s of the host starting the guest.
    results, err = boot(tmp_path, [agent("pi", PROMPT)], fake_tor(tmp_path, "late"))
    assert TOR_STOP not in results["pi"]["output"]
    assert "The wallet companion could not be reached" in results["pi"]["output"]
    # Pi sends the request again after the companion's error, and each try
    # prepares the route again: every route the stand-in saw was this task's
    # conversation's.
    seen = routes(tmp_path)
    assert seen and {(r["identity"], r["destination"]) for r in seen} == {(seen[0]["identity"], "openrouter.ai:443")}
    assert seen[0]["identity"] != "none"


LIMIT = "tor did not bootstrap within 90 seconds; stopped it"


def test_a_tor_that_exits_while_bootstrapping_stops_the_task(tmp_path):
    results, err = boot(tmp_path, [agent("pi", PROMPT), sandbox("static probe", "cloak-routing-probe")],
                        fake_tor(tmp_path, "exits"))
    assert results["pi"]["output"].strip() == TOR_STOP
    assert "tcp: blocked" in results["static probe"]["output"]
    assert "tor exited with status 0" in err and "cannot reach tor" in err
    assert LIMIT not in err
    assert routes(tmp_path) == []


def test_a_tor_that_never_bootstraps_is_stopped_at_the_limit_and_the_task_stops(tmp_path):
    started = time.monotonic()
    results, err = boot(tmp_path, [agent("pi", PROMPT), sandbox("static probe", "cloak-routing-probe")],
                        fake_tor(tmp_path, "never"))
    assert time.monotonic() - started >= 90
    assert LIMIT in err and "cannot reach tor" in err
    assert results["pi"]["output"].strip() == TOR_STOP
    assert "tcp: blocked" in results["static probe"]["output"] and "udp dns: blocked" in results["static probe"]["output"]
    # Stopped before the guest started, the stand-in saw nothing.
    assert routes(tmp_path) == []


def test_a_tor_that_cannot_reach_the_network_stops_the_task(tmp_path):
    # tor's only way onto the network is a closed port on the Mac's loopback,
    # so it never bootstraps and the host stops it at the limit.
    results, err = boot(tmp_path, [agent("pi", PROMPT),
                                   sandbox("through tor", fetch("https://check.torproject.org/api/ip", 30_000))],
                        tor(tmp_path, "--Socks5Proxy", "127.0.0.1:1"))
    assert results["pi"]["output"].strip() == TOR_STOP
    assert any(line.startswith("refused ") for line in results["through tor"]["output"].splitlines())
    assert "The connection to the SOCKS5 proxy server at 127.0.0.1:1 just failed" in err
    assert "Bootstrapped 100%" not in err
    assert LIMIT in err and "cannot reach tor" in err
