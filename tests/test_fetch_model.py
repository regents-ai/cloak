"""Functional checks of scripts/fetch_model.py's downloads against a local HTTP
server: a download cut short stops the run and resumes on the next, where it
stopped, with an HTTP Range request; a server that ignores the range sends
the whole file, which starts it again cleanly; and the size and sha256
checks still stand.

    uv run --with pytest==8.4.2 pytest tests/test_fetch_model.py
"""

import hashlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import fetch_model  # noqa: E402

DATA = bytes(range(256)) * 4096  # 1 MiB
ENTRY = {"path": "weights.bin", "size": len(DATA), "sha256": hashlib.sha256(DATA).hexdigest()}


class Hub:
    """Serves DATA at any path. `ranges` says whether it honours a Range
    request; `cut_at` closes the connection after that many bytes of the
    body. Each request's Range header, or None, is kept in `asked`."""

    def __init__(self, ranges: bool, cut_at: int | None = None):
        self.ranges, self.cut_at, self.asked = ranges, cut_at, []
        hub = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                asked = self.headers.get("Range")
                hub.asked.append(asked)
                start = int(asked.removeprefix("bytes=").removesuffix("-")) if asked and hub.ranges else 0
                body = DATA[start:]
                self.send_response(206 if start else 200)
                if start:
                    self.send_header("Content-Range", f"bytes {start}-{len(DATA) - 1}/{len(DATA)}")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body if hub.cut_at is None else body[:hub.cut_at])

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def hub(monkeypatch):
    servers = []

    def start(ranges: bool, cut_at: int | None = None) -> Hub:
        server = Hub(ranges, cut_at)
        servers.append(server)
        monkeypatch.setattr(fetch_model, "HUB", server.url)
        return server

    yield start
    for server in servers:
        server.close()


def fetch(target: Path) -> None:
    fetch_model.fetch("org/model", "0" * 40, ENTRY, target)


def test_a_download_cut_short_resumes_where_it_stopped(hub, tmp_path):
    target = tmp_path / "weights.bin"
    cut = hub(ranges=True, cut_at=300_000)
    with pytest.raises(SystemExit, match="cut short at 300000 of 1048576 bytes"):
        fetch(target)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["weights.bin.part"]
    assert (tmp_path / "weights.bin.part").read_bytes() == DATA[:300_000]
    assert cut.asked == [None]
    resumed = hub(ranges=True)
    fetch(target)
    assert resumed.asked == ["bytes=300000-"]
    assert target.read_bytes() == DATA
    assert sorted(p.name for p in tmp_path.iterdir()) == ["weights.bin"]


def test_a_server_that_ignores_the_range_starts_the_file_again(hub, tmp_path):
    target = tmp_path / "weights.bin"
    (tmp_path / "weights.bin.part").write_bytes(DATA[:300_000])
    whole = hub(ranges=False)
    fetch(target)
    assert whole.asked == ["bytes=300000-"]
    assert target.read_bytes() == DATA
    assert sorted(p.name for p in tmp_path.iterdir()) == ["weights.bin"]


def test_a_complete_part_is_checked_without_a_request(hub, tmp_path):
    target = tmp_path / "weights.bin"
    (tmp_path / "weights.bin.part").write_bytes(DATA)
    server = hub(ranges=True)
    fetch(target)
    assert server.asked == []
    assert target.read_bytes() == DATA


@pytest.mark.parametrize("part", [b"\0" * 300_000, DATA + b"\0"], ids=["wrong bytes", "too long"])
def test_a_part_that_does_not_match_the_pin_is_set_aside_as_bad(hub, tmp_path, part):
    target = tmp_path / "weights.bin"
    (tmp_path / "weights.bin.part").write_bytes(part)
    hub(ranges=True)
    with pytest.raises(SystemExit, match="bytes do not match the pin"):
        fetch(target)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["weights.bin.bad"]
    # The next run starts afresh.
    fetch(target)
    assert target.read_bytes() == DATA
