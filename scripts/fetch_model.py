# /// script
# requires-python = ">=3.12"
# ///
"""Download one pinned model from reference/models.json into
~/Library/Application Support/Regents Cloak/models/<name>/, the only place the
sandboxed worker may read.

Every file is fetched at the pinned revision and must match its recorded size
and sha256; a file already present and matching is kept. Any mismatch stops
the run with a non-zero exit and leaves the bad file in place as `<file>.bad`.
Check free disk space before fetching a candidate (about 16 GB each).
"""

import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "reference" / "models.json"
DEST = Path.home() / "Library/Application Support/Regents Cloak/models"
HUB = "https://huggingface.co"
CHUNK = 8 << 20


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(CHUNK):
            h.update(block)
    return h.hexdigest()


def fetch(repo: str, revision: str, entry: dict, target: Path) -> None:
    if target.exists() and target.stat().st_size == entry["size"] and digest(target) == entry["sha256"]:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    with urllib.request.urlopen(f"{HUB}/{repo}/resolve/{revision}/{entry['path']}", timeout=60) as r, partial.open("wb") as f:
        while block := r.read(CHUNK):
            f.write(block)
    if partial.stat().st_size != entry["size"] or digest(partial) != entry["sha256"]:
        partial.rename(target.with_name(target.name + ".bad"))
        raise SystemExit(f"{entry['path']}: bytes do not match the pin")
    partial.rename(target)


def main() -> None:
    name = sys.argv[1]
    model = next(m for m in json.loads(MODELS.read_text())["models"] if m["name"] == name)
    for entry in model["files"]:
        fetch(model["repo"], model["revision"], entry, DEST / name / entry["path"])
        print(f"{entry['path']} ok")


if __name__ == "__main__":
    main()
