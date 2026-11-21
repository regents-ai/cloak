"""The Mac's calls and reads to the guest's payer (docs/zkapi-mac-side.md,
section 1), through cloak-host --pay to cloak-pay with the real companion
on a blank payment disk made here: a read of the deposit, with and without
the chain, a call the payer allows, and calls it refuses. The stand-in tor
(fake_tor.py) notes each connection's SOCKS identity and destination and
refuses it, so nothing leaves the Mac, and every read of the chain fails.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_pay_frames.py

The payer's first read of its address makes its Ethereum key, here on the
temporary disk only.
"""

import json

import pytest
from guest_boot import Serving, wait_for

RPC = "ethereum-rpc.publicnode.com:443"


@pytest.fixture(scope="module")
def serving(tmp_path_factory):
    serving = Serving(tmp_path_factory.mktemp("pay-frames"))
    yield serving
    serving.close()


def answered(serving: Serving, frame: str, payload: dict) -> tuple[int, object]:
    """One exchange, which no H frame comes before: the answer's status and
    its body, read."""
    held, last = serving.exchange(frame, payload)
    assert held == [] and "answer" in last, (held, last)
    return last["answer"]["status"], json.loads(last["answer"]["body"])


def tried_the_chain(serving: Serving) -> None:
    """The chain was tried through tor, every time under an identity."""
    wait_for(lambda: any(r["destination"] == RPC for r in serving.routes()), 30, "the chain was never tried")
    assert all(r["identity"] != "none" for r in serving.routes() if r["destination"] == RPC), serving.routes()


def test_a_read_of_the_deposit_finds_no_note_on_a_new_disk(serving):
    assert answered(serving, "V", {"chain": False}) == (200, {"wallet": {"has_note": False, "pending_request": False}})


def test_a_read_of_the_chain_that_cannot_reach_it_fails_whole(serving):
    status, body = answered(serving, "V", {"chain": True})
    assert status == 502 and list(body) == ["error"], body
    tried_the_chain(serving)


def test_a_call_the_payer_allows_reaches_the_daemon(serving):
    # No saved quote: the daemon's own answer, after reading its
    # configuration from the companion and making the payer's key.
    assert answered(serving, "C", {"method": "GET", "path": "/admin/funding/quote", "body": ""}) == (200, None)


def test_the_withdrawal_read_tries_the_chain_through_tor_only(serving):
    status, body = answered(serving, "C", {"method": "GET", "path": "/admin/withdrawal", "body": ""})
    assert status == 502 and list(body) == ["error"], body
    tried_the_chain(serving)


@pytest.mark.parametrize("method, path", [
    ("GET", "/admin/funding/approve"),
    ("POST", "/v1/chat/completions"),
    ("GET", "/admin/status"),
    ("GET", "/admin/withdrawal?a=1"),
    ("DELETE", "/admin/withdrawal"),
])
def test_a_call_outside_the_payers_routes_is_answered_404(serving, method, path):
    assert answered(serving, "C", {"method": method, "path": path, "body": "{}"})[0] == 404
