# /// script
# requires-python = ">=3.12"
# ///
"""Write the app's manifest, Contents/Resources/manifest.json, for app/build.sh.

The manifest names the release and the build, the memory all of Cloak needs
beside its models (from app/release.json, in GiB there and in bytes here), the
model that rewords (`model`, from app/release.json), and every model that can
answer Local Llama chats (`answer_models`: each entry of reference/models.json
with `answers`, the least memory first, with its label, the memory it needs in
bytes, its context in tokens, and its files, their sizes and sha256 pins, and
the URL the app downloads each from, the one scripts/fetch_model.py uses: a
file marked `from` comes from that model's repository and revision). The model
that rewords must be one of them. It pins every part the supervisor runs by its
sha256, each in the bundle: the guest's kernel and root,
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

    def file(model: dict, entry: dict) -> dict:
        source = models[entry.get("from", model["name"])]
        return {"path": entry["path"], "size": entry["size"], "sha256": entry["sha256"],
                "url": url(source["repo"], source["revision"], entry["path"])}

    def answer_model(model: dict) -> dict:
        answers = model["answers"]
        return {
            "name": model["name"],
            "label": answers["label"],
            "memory": round(answers["memory_gib"] * 2**30),
            "context_tokens": answers["context_tokens"],
            "files": [file(model, entry) for entry in model["files"]],
        }

    answer_models = sorted((answer_model(m) for m in models.values() if "answers" in m), key=lambda m: m["memory"])
    if release["model"] not in [m["name"] for m in answer_models]:
        raise SystemExit(f"{release['model']}, the model that rewords, is not a model that answers in reference/models.json")
    manifest = {
        "release": release["release"],
        "build": build,
        "cloak_memory": round(release["cloak_memory_gib"] * 2**30),
        "model": release["model"],
        "answer_models": answer_models,
        "pins": [{"part": part, "path": path, "sha256": digest(resources / path)} for part, path in PARTS],
    }
    (resources / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
