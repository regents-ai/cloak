"""Cloak's cover list as the guest checks lay it over the built image: the
built root (guest/build/initrd.gz), then one more archive holding only
etc/cloak/cover.json, which the guest kernel unpacks over the root's own
copy of reference/cover.json, as it unpacks the host's per-boot files
(host/Sources/CloakHost/BootFiles.swift).
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The guest's root as guest/build.sh built it, with the shipped list inside.
BUILT = ROOT / "guest/build/initrd.gz"
# The list the image ships.
SHIPPED = json.loads((ROOT / "reference/cover.json").read_text())
# The shipped list with no URLs: cover off, the daemon's own cleared setting.
NO_COVER = SHIPPED | {"urls": []}


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
    base = BUILT.read_bytes()
    path = tmp_path / "initrd"
    path.write_bytes(base + bytes(-len(base) % 4) + archive("etc/cloak/cover.json", json.dumps(cover).encode()))
    return path
