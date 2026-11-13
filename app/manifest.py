# /// script
# requires-python = ">=3.12"
# ///
"""Write the app's manifest, Contents/Resources/manifest.json, for app/build.sh.

The manifest names the release and the build, the one model (from
app/release.json; its files and sizes from reference/models.json), the memory
floor, and pins every part the supervisor runs by its sha256: the guest's
kernel and root, tor and libevent in the bundle, and the worker and its shader
library as worker/install.sh installed them in the Application Support folder.

    uv run app/manifest.py <Resources folder> <Application Support folder> <build>
"""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARTS = [
    ("kernel", "bundle", "guest/Image"),
    ("initrd", "bundle", "guest/initrd.gz"),
    ("tor", "bundle", "tor/tor"),
    ("libevent", "bundle", "tor/libevent-2.1.7.dylib"),
    ("worker", "support", "worker/cloak-rewriter"),
    ("shaders", "support", "worker/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(8 << 20):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    resources, support, build = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    release = json.loads((ROOT / "app/release.json").read_text())
    models = json.loads((ROOT / "reference/models.json").read_text())["models"]
    model = next(m for m in models if m["name"] == release["model"])
    places = {"bundle": resources, "support": support}
    manifest = {
        "release": release["release"],
        "build": build,
        "minimum_memory": release["minimum_memory_gib"] << 30,
        "model": {
            "name": model["name"],
            "label": release["model_label"],
            "files": [{"path": f["path"], "size": f["size"]} for f in model["files"]],
        },
        "pins": [{"part": part, "place": place, "path": path, "sha256": digest(places[place] / path)}
                 for part, place, path in PARTS],
    }
    (resources / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
