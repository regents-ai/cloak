# /// script
# requires-python = ">=3.12"
# ///
"""Fetch the pinned reference sources into reference/src/ and verify each pin.

Git sources are checked out at their pinned commit; npm sources are packed and
their tarball must match the recorded sha512 integrity. Any mismatch stops the
run with a non-zero exit.
"""

import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "reference" / "sources.json"
DEST = ROOT / "reference" / "src"


def run(*args: str, cwd: Path) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def fetch_git(source: dict, target: Path) -> str:
    if not (target / ".git").exists():
        target.mkdir(parents=True)
        run("git", "init", "-q", cwd=target)
        run("git", "remote", "add", "origin", source["url"], cwd=target)
    if source["full_history"]:
        run("git", "fetch", "-q", "origin", source["ref"], cwd=target)
    else:
        run("git", "fetch", "-q", "--depth", "1", "origin", source["commit"], cwd=target)
    run("git", "checkout", "-q", "--detach", source["commit"], cwd=target)
    head = run("git", "rev-parse", "HEAD", cwd=target)
    if head != source["commit"]:
        raise SystemExit(f"{source['name']}: HEAD {head} is not the pinned {source['commit']}")
    if source["full_history"]:
        tip = run("git", "rev-parse", "FETCH_HEAD", cwd=target)
        moved = "unchanged" if tip == source["commit"] else f"moved to {tip}"
        return f"{head} ({source['ref']} {moved})"
    return head


def fetch_npm(source: dict, target: Path) -> str:
    target.mkdir(parents=True, exist_ok=True)
    spec = f"{source['package']}@{source['version']}"
    tarball = target / json.loads(run("npm", "pack", spec, "--json", cwd=target))[0]["filename"]
    digest = "sha512-" + base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode()
    if digest != source["integrity"]:
        raise SystemExit(f"{source['name']}: {tarball.name} is {digest}, pinned {source['integrity']}")
    return f"{spec} {digest[:20]}..."


def main() -> None:
    for source in json.loads(SOURCES.read_text())["sources"]:
        target = DEST / source["name"]
        fetch = {"git": fetch_git, "npm": fetch_npm}[source["kind"]]
        print(f"{source['name']:<22} {fetch(source, target)}")


if __name__ == "__main__":
    sys.exit(main())
