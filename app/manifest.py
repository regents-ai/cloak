# /// script
# requires-python = ">=3.12"
# ///
"""Write the app's manifest, Contents/Resources/manifest.json, for app/build.sh.

The manifest names the release and the build, the one model (from
app/release.json; its files, their sizes and sha256 pins from
reference/models.json, and the URL the app downloads each from, the one
scripts/fetch_model.py uses: a file marked `from` comes from that model's
repository and revision), the memory the model and all of Cloak need (from
app/release.json, in GiB there and in bytes here), and pins every part the
supervisor runs by its sha256, each in the bundle: the guest's kernel and root,
tor and libevent, the worker as llama-worker/install.sh built and signed it,
which the app copies to its Application Support folder at each Start and runs
from there, and NEAR mode's helper, cloak-near, which the app checks against
its pin before each start of it.

    uv run app/manifest.py <Resources folder> <build>
"""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_model import url  # noqa: E402

PARTS = [
    ("kernel", "guest/Image"),
    ("initrd", "guest/initrd.gz"),
    ("tor", "tor/tor"),
    ("libevent", "tor/libevent-2.1.7.dylib"),
    ("worker", "worker/cloak-rewriter-llama"),
    ("near", "near/cloak-near"),
]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(8 << 20):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    resources, build = Path(sys.argv[1]), sys.argv[2]
    release = json.loads((ROOT / "app/release.json").read_text())
    models = {m["name"]: m for m in json.loads((ROOT / "reference/models.json").read_text())["models"]}
    model = models[release["model"]]

    def file(entry: dict) -> dict:
        source = models[entry.get("from", model["name"])]
        return {"path": entry["path"], "size": entry["size"], "sha256": entry["sha256"],
                "url": url(source["repo"], source["revision"], entry["path"])}

    manifest = {
        "release": release["release"],
        "build": build,
        "model_memory": round(release["model_memory_gib"] * 2**30),
        "cloak_memory": round(release["cloak_memory_gib"] * 2**30),
        "model": {
            "name": model["name"],
            "label": release["model_label"],
            "files": [file(entry) for entry in model["files"]],
        },
        "pins": [{"part": part, "path": path, "sha256": digest(resources / path)} for part, path in PARTS],
    }
    (resources / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
