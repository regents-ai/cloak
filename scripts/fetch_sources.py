# /// script
# requires-python = ">=3.12"
# ///
"""Fetch the pinned reference sources into reference/src/ and verify each pin.

Git sources are checked out at their pinned commit; npm sources are packed and
their tarball must match the recorded sha512 integrity; file sources are
downloaded from their pinned URL, once, after a free disk check, and must
match the recorded size and sha256. Any mismatch stops the run with a non-zero
exit.

With --check nothing is fetched: every source already on disk is verified
against its pin (the guest build runs this before it uses them).
"""

import base64
import hashlib
import json
import shutil
import subprocess
import sys
import urllib.request
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
    head = check_git(source, target)
    if source["full_history"]:
        tip = run("git", "rev-parse", "FETCH_HEAD", cwd=target)
        moved = "unchanged" if tip == source["commit"] else f"moved to {tip}"
        return f"{head} ({source['ref']} {moved})"
    return head


def check_git(source: dict, target: Path) -> str:
    head = run("git", "rev-parse", "HEAD", cwd=target)
    if head != source["commit"]:
        raise SystemExit(f"{source['name']}: HEAD {head} is not the pinned {source['commit']}")
    return head


def npm_tarball(source: dict, target: Path) -> Path:
    """The name `npm pack` gives the tarball: the package name without its
    "@", "/" as "-", then the version."""
    return target / f"{source['package'].lstrip('@').replace('/', '-')}-{source['version']}.tgz"


def fetch_npm(source: dict, target: Path) -> str:
    target.mkdir(parents=True, exist_ok=True)
    spec = f"{source['package']}@{source['version']}"
    run("npm", "pack", spec, "--json", cwd=target)
    return check_npm(source, target)


def check_npm(source: dict, target: Path) -> str:
    tarball = npm_tarball(source, target)
    digest = "sha512-" + base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode()
    if digest != source["integrity"]:
        raise SystemExit(f"{source['name']}: {tarball.name} is {digest}, pinned {source['integrity']}")
    return f"{source['package']}@{source['version']} {digest[:20]}..."


def file_path(source: dict, target: Path) -> Path:
    return target / source["url"].rsplit("/", 1)[1]


# Room kept free beyond a download.
DISK_HEADROOM = 1 << 30


def fetch_file(source: dict, target: Path) -> str:
    """Downloads to <file>.part and renames it only once its hash matches the
    pin; a mismatch is kept as <file>.bad and stops the run. A file already
    there is checked, not fetched again."""
    target.mkdir(parents=True, exist_ok=True)
    path = file_path(source, target)
    if path.exists():
        return check_file(source, target)
    free = shutil.disk_usage(target).free
    if free < source["size"] + DISK_HEADROOM:
        raise SystemExit(f"{source['name']}: {free} bytes free, {source['size']} needed plus {DISK_HEADROOM} spare")
    part = path.with_name(path.name + ".part")
    with urllib.request.urlopen(source["url"], timeout=60) as response, part.open("wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)
    digest = hashlib.sha256(part.read_bytes()).hexdigest()
    if digest != source["sha256"]:
        part.rename(path.with_name(path.name + ".bad"))
        raise SystemExit(f"{source['name']}: {path.name} is {digest}, pinned {source['sha256']}")
    part.rename(path)
    return check_file(source, target)


def check_file(source: dict, target: Path) -> str:
    path = file_path(source, target)
    if path.stat().st_size != source["size"]:
        raise SystemExit(f"{source['name']}: {path.name} is {path.stat().st_size} bytes, pinned {source['size']}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != source["sha256"]:
        raise SystemExit(f"{source['name']}: {path.name} is {digest}, pinned {source['sha256']}")
    return f"{path.name} {digest[:16]}..."


FETCH = {"git": fetch_git, "npm": fetch_npm, "file": fetch_file}
CHECK = {"git": check_git, "npm": check_npm, "file": check_file}


def main() -> None:
    action = CHECK if sys.argv[1:] == ["--check"] else FETCH
    if action is FETCH and sys.argv[1:]:
        raise SystemExit("usage: fetch_sources.py [--check]")
    for source in json.loads(SOURCES.read_text())["sources"]:
        target = DEST / source["name"]
        print(f"{source['name']:<22} {action[source['kind']](source, target)}")


if __name__ == "__main__":
    sys.exit(main())
