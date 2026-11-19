"""The payer's front from the agent's side (docs/plan.md, "Payment in the
guest: cloak-pay"): from the reference sandbox, the agent tries cloak-pay's
vsock port 8021 and the daemon's two loopback ports, 8787 (its local API) and
8790 (its companion's), and reaches nothing of cloak-pay. Its checks without
the guest are guest/pay/check.sh.

Not yet runnable: the guest does not start cloak-pay at boot, so every
attempt here would find nothing whether or not cloak-pay holds. To run it,
start cloak-pay in guest/image/boot after the daemon's lines, as its own user
and gated on its "ready" as the other services are:

    mkfifo /run/cloak/pay-ready
    su -s /bin/sh pay -c 'exec /usr/bin/cloak-pay' > /run/cloak/pay-ready 2> /run/cloak/pay.log &
    read -r ready < /run/cloak/pay-ready
    [ "$ready" = ready ] || { echo "cloak-guest: payer did not start"; cat /run/cloak/pay.log; poweroff -f; }

then take off the skip mark below and run

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_pay_path.py

8787 is the guest daemon's (the sender's path) until that path is removed,
so the check there is that cloak-pay adds no listener of its own: the
guest's table stays the three of test_escape_path.py.
"""

import json
from pathlib import Path

import pytest
from guest_boot import boot, fake_tor, routes, sandbox

pytestmark = pytest.mark.skip(reason="cloak-pay is not started at boot yet; the module docstring says how to run this")

# One whole request frame, as the Mac would send it: kind R, a four-byte
# big-endian length, then the payload (guest/pay/zz_cloak_pay.go).
PAYLOAD = json.dumps({"identity": "0123456789abcdef" * 4,
                      "body": json.dumps({"model": "stand-in/model",
                                          "messages": [{"role": "user", "content": "Hello."}]})}).encode()
FRAME = b"R" + len(PAYLOAD).to_bytes(4, "big") + PAYLOAD
# The guest's own loopback address, the host, and the address the Mac gives
# the guest.
CIDS = [1, 2, 3]


def escaped(data: bytes) -> str:
    """The bytes as Go escapes, which cloak-vsock-probe reads."""
    return "".join(f"\\x{byte:02x}" for byte in data)


def status(url: str) -> str:
    """curl with torsocks taken off: one POST's HTTP status, or 000 if
    nothing answered."""
    return f"env -u LD_PRELOAD curl -s -o /dev/null -w '%{{http_code}}\\n' --max-time 5 -X POST {url}"


ATTEMPTS = [
    sandbox("listeners", 'for t in tcp tcp6; do echo "== $t"; cat /proc/net/$t; done'),
    sandbox("companion port", status("http://127.0.0.1:8790/oa/v1/status")),
    sandbox("pay port", "; ".join(f"cloak-vsock-probe 8021 '{escaped(FRAME)}' {cid}" for cid in CIDS)),
]


@pytest.fixture(scope="module")
def attempts(tmp_path_factory) -> tuple[dict[str, str], list[dict]]:
    """Each attempt's output, and every connection the stand-in tor saw."""
    folder: Path = tmp_path_factory.mktemp("pay")
    results, _ = boot(folder, ATTEMPTS, fake_tor(folder, "ready"))
    return {name: r["output"] for name, r in results.items()}, routes(folder)


def test_cloak_pay_adds_no_loopback_listener(attempts):
    out, _ = attempts
    listening = set()
    for line in out["listeners"].splitlines():
        fields = line.split()
        # Local address and port in hex; state 0A is listening.
        if fields and fields[0].rstrip(":").isdigit() and fields[3] == "0A":
            address, port = fields[1].split(":")
            listening.add((address, int(port, 16)))
    assert listening == {("0100007F", 8012), ("0100007F", 8787), ("0100007F", 9050)}, out["listeners"]
    assert out["companion port"].split() == ["000"]


def test_the_sandbox_cannot_reach_cloak_pays_vsock_port(attempts):
    out, seen = attempts
    lines = out["pay port"].splitlines()
    assert len(lines) == len(CIDS), lines
    assert all(line.startswith(("refused", "closed, no answer")) for line in lines), lines
    # The frame started no payment: nothing reached tor.
    assert seen == []
