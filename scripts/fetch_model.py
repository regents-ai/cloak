# /// script
# requires-python = ">=3.12"
# ///
"""Download one pinned model from reference/models.json into
~/Library/Application Support/Regents Cloak/models/<name>/, the only place the
sandboxed worker may read.

Every file is fetched at its pinned repository and revision (a candidate's
vendor tokenizer and template files from the vendor checkpoint) and must match
its recorded size and sha256; a file already present and matching is kept. Any mismatch stops
the run with a non-zero exit and leaves the bad file in place as `<file>.bad`.
A download goes to `<file>.part`. One cut short stops the run and keeps it,
and the next run asks the server for the rest only (an HTTP Range request),
or fetches the whole file again when the server sends it whole. Check free
disk space before fetching: a model needs its `total_bytes` in
reference/models.json.
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


def url(repo: str, revision: str, path: str) -> str:
    """Where a pinned file is fetched from; app/manifest.py gives the app's
    download the same URLs."""
    return f"{HUB}/{repo}/resolve/{revision}/{path}"


def fetch(repo: str, revision: str, entry: dict, target: Path) -> None:
    if target.exists() and target.stat().st_size == entry["size"] and digest(target) == entry["sha256"]:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    have = partial.stat().st_size if partial.exists() else 0
    if have < entry["size"]:
        remote = entry.get("remote_path", entry["path"])
        request = urllib.request.Request(url(repo, revision, remote),
                                         headers={"Range": f"bytes={have}-"} if have else {})
        # 206 is the rest of the file; 200 is all of it, from the start.
        with urllib.request.urlopen(request, timeout=60) as r, partial.open("ab" if r.status == 206 else "wb") as f:
            while block := r.read(CHUNK):
                f.write(block)
    have = partial.stat().st_size
    if have < entry["size"]:
        raise SystemExit(f"{entry['path']}: download cut short at {have} of {entry['size']} bytes; run again to resume")
    if have != entry["size"] or digest(partial) != entry["sha256"]:
        partial.rename(target.with_name(target.name + ".bad"))
        raise SystemExit(f"{entry['path']}: bytes do not match the pin")
    partial.rename(target)


def main() -> None:
    name = sys.argv[1]
    models = {m["name"]: m for m in json.loads(MODELS.read_text())["models"]}
    for entry in models[name]["files"]:
        # A file marked `from` is the vendor's (decision 1), fetched from there.
        source = models[entry.get("from", name)]
        fetch(source["repo"], source["revision"], entry, DEST / name / entry["path"])
        print(f"{entry['path']} ok")


if __name__ == "__main__":
    main()
