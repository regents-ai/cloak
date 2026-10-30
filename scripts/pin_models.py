# /// script
# requires-python = ">=3.12"
# ///
"""Record every file of each pinned model in reference/models.json.

Each model is named by a Hugging Face repository and an exact revision. The
script reads that revision's file listing and writes each file's size and
sha256: the recorded hash for large (LFS) files, and a hash of the downloaded
bytes for small files such as the config, tokenizer and chat template. No
weight file is downloaded. A revision cannot change, so a second run that
changes models.json means the hub served different bytes.

A candidate with `vendor_files` (decision 1) takes those files from its vendor
checkpoint instead of its conversion: each listed file is recorded from the
vendor entry named in `from`, marked with that name, and replaces the
conversion's file of the same name. Everything else stays the conversion's.
"""

import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "reference" / "models.json"
HUB = "https://huggingface.co"


def get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def record(model: dict) -> dict:
    repo, revision = model["repo"], model["revision"]
    info = json.loads(get(f"{HUB}/api/models/{repo}/revision/{revision}?blobs=true"))
    if info["sha"] != revision:
        raise SystemExit(f"{repo}: hub answered revision {info['sha']}, pinned {revision}")
    files, small = [], {}
    for sibling in sorted(info["siblings"], key=lambda s: s["rfilename"]):
        path = sibling["rfilename"]
        if "lfs" in sibling:
            files.append({"path": path, "size": sibling["lfs"]["size"], "sha256": sibling["lfs"]["sha256"]})
            continue
        body = get(f"{HUB}/{repo}/resolve/{revision}/{path}")
        small[path] = body
        files.append({"path": path, "size": len(body), "sha256": hashlib.sha256(body).hexdigest()})
    card = info.get("cardData") or {}
    config = json.loads(small["config.json"]) if "config.json" in small else {}
    return model | {
        "last_modified": info["lastModified"],
        "gated": info["gated"],
        "license": card.get("license"),
        "license_name": card.get("license_name"),
        "base_model": card.get("base_model"),
        "library": info.get("library_name"),
        "architectures": config.get("architectures"),
        "quantization": config.get("quantization") or config.get("quantization_config"),
        "total_bytes": sum(f["size"] for f in files),
        "files": files,
    }


def compose(model: dict, recorded: dict[str, dict]) -> dict:
    vendor = model["vendor_files"]
    source = {f["path"]: f for f in recorded[vendor["from"]]["files"]}
    files = [f for f in model["files"] if f["path"] not in vendor["paths"]]
    files += [source[path] | {"from": vendor["from"]} for path in vendor["paths"]]
    files.sort(key=lambda f: f["path"])
    return model | {"total_bytes": sum(f["size"] for f in files), "files": files}


def main() -> None:
    manifest = json.loads(MODELS.read_text())
    keep = ("name", "role", "repo", "revision", "vendor_files", "chat_template_context")
    recorded = {m["name"]: record({k: m[k] for k in keep if k in m}) for m in manifest["models"]}
    manifest["models"] = [compose(m, recorded) if "vendor_files" in m else m for m in recorded.values()]
    MODELS.write_text(json.dumps(manifest, indent=2) + "\n")
    for m in manifest["models"]:
        print(f"{m['name']}: {m['repo']}@{m['revision'][:8]} {len(m['files'])} files, "
              f"{m['total_bytes'] / 1e9:.2f} GB, licence {m['license_name'] or m['license']}")


if __name__ == "__main__":
    main()
