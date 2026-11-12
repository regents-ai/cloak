"""The stage 4 input sets, their checks and their pins
(docs/evaluation-protocol.md, "Datasets"; spec EVAL02, EVAL03).

Two datasets, each one JSON file:

- EVAL02, fidelity: items, each with its text, the categories it covers,
  its language, the required meaning as relations and every protected span,
  all written before any model runs on it.
- EVAL03, privacy: originals, each with its writer, session, topic,
  partition (train, tune or evaluation) and the identifying content in it,
  assigned before any rewrite is made.

A file's `kind` is `holdout` or `development`. A holdout is written by a
person, kept outside this repository and pinned by its sha256 in
reference/holdouts.json before any model runs on it; the kit refuses an
unpinned or changed holdout, and a pin is never replaced. A development set
may be read by anyone and is never a holdout result.
"""

import hashlib
import json
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINS = ROOT / "reference/holdouts.json"
MAX_TEXT = 128 << 10  # the daemon's limit on one user turn

# Spec EVAL02's coverage list, one name each.
EVAL02_CATEGORIES = (
    "quantities", "units", "inequalities", "negation", "uncertainty", "conditional order", "missing context",
    "code", "quotations", "names and identifiers", "urls and paths", "exact-output rules", "multilingual",
    "long inputs",
)
# The protocol's annotation: relations of the required meaning, and spans.
RELATION_TYPES = ("quantity and unit", "inequality", "negation", "uncertainty", "condition and order",
                  "exclusion", "exact-output rule")
SPAN_TYPES = ("code", "quotation", "name", "identifier", "url", "path", "number")
PARTITIONS = ("train", "tune", "evaluation")
# Several languages (protocol, EVAL02 coverage): the kit reads "several" as three.
MIN_LANGUAGES = 3


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pins() -> dict:
    return json.loads(PINS.read_text())


def _checked(path: Path, dataset: str) -> dict:
    data = json.loads(path.read_text())
    if data.get("dataset") != dataset:
        raise SystemExit(f"{path} is not an {dataset} file")
    if data.get("kind") not in ("holdout", "development"):
        raise SystemExit(f"{path}: kind must be holdout or development")
    problems = (check_eval02 if dataset == "EVAL02" else check_eval03)(data)
    if problems:
        raise SystemExit(f"{path} has problems:\n- " + "\n- ".join(problems))
    if data["kind"] == "holdout" and ROOT in path.resolve().parents:
        raise SystemExit(f"{path} is inside the repository; a holdout stays outside it")
    return data


def load(path: Path, dataset: str) -> dict:
    """Reads and checks one input set. A holdout must match its pin."""
    data = _checked(path, dataset)
    if data["kind"] == "holdout":
        pin = pins()[dataset]
        if pin is None:
            raise SystemExit(f"{dataset} has no pin in {PINS}; pin it before any model runs on it")
        if sha256_file(path) != pin["sha256"]:
            raise SystemExit(f"{path} is not the pinned {dataset} holdout")
    return data


def pin(path: Path, dataset: str) -> dict:
    """Records a holdout's sha256 before any model runs on it. A pin is
    never replaced: a changed holdout is a new design (spec EVAL03)."""
    data = _checked(path, dataset)
    if data["kind"] != "holdout":
        raise SystemExit("only a holdout is pinned")
    all_pins = pins()
    if all_pins[dataset] is not None:
        raise SystemExit(f"{dataset} is already pinned ({all_pins[dataset]['sha256']}); a pin is never replaced")
    count = len(data["items"] if dataset == "EVAL02" else data["originals"])
    all_pins[dataset] = {"sha256": sha256_file(path), "bytes": path.stat().st_size, "entries": count,
                         "pinned_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    PINS.write_text(json.dumps(all_pins, indent=1) + "\n")
    return all_pins[dataset]


def _unique(entries: list[dict], what: str) -> list[str]:
    ids = [e.get("id") for e in entries]
    problems = [f"{what} without an id" for i in ids if not isinstance(i, str) or not i]
    problems += [f"{what} id {i} is used twice" for i in sorted({i for i in ids if ids.count(i) > 1})]
    return problems


def check_eval02(data: dict) -> list[str]:
    """Each item: a non-empty text within the daemon's limit, its language,
    categories from the coverage list, relations of the declared types, and
    protected spans of the declared types that occur in the text as written.
    A holdout must cover every category and several languages."""
    items = data.get("items")
    if not isinstance(items, list) or not items:
        return ["no items"]
    problems = _unique(items, "item")
    for item in items:
        name = item.get("id")
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            problems.append(f"{name}: no text")
            continue
        if len(text.encode()) > MAX_TEXT:
            problems.append(f"{name}: over the daemon's 128 KiB limit, which it refuses before any call")
        if not item.get("language"):
            problems.append(f"{name}: no language")
        unknown = set(item.get("categories") or []) - set(EVAL02_CATEGORIES)
        if not item.get("categories") or unknown:
            problems.append(f"{name}: categories must come from {EVAL02_CATEGORIES} (unknown: {sorted(unknown)})")
        relations = item.get("relations") or []
        problems += [f"{name}: {p}" for p in _unique(relations, "relation")]
        for r in relations:
            if r.get("type") not in RELATION_TYPES:
                problems.append(f"{name}: relation {r.get('id')} type must be one of {RELATION_TYPES}")
            if not r.get("statement"):
                problems.append(f"{name}: relation {r.get('id')} has no statement")
            if r.get("type") == "inequality" and not isinstance(r.get("inclusive"), bool):
                problems.append(f"{name}: inequality {r.get('id')} must say whether it is inclusive")
        spans = item.get("protected_spans") or []
        for s in spans:
            if s.get("type") not in SPAN_TYPES:
                problems.append(f"{name}: span type must be one of {SPAN_TYPES}")
            if not s.get("text") or s["text"] not in text:
                problems.append(f"{name}: protected span {s.get('text')!r} is not in the text as written")
        if not relations and not spans:
            problems.append(f"{name}: no relations and no protected spans to check")
    if data.get("kind") == "holdout":
        covered = {c for item in items for c in item.get("categories") or []}
        missing = [c for c in EVAL02_CATEGORIES if c not in covered]
        if missing:
            problems.append(f"categories not covered: {missing}")
        languages = {item.get("language") for item in items}
        if len(languages) < MIN_LANGUAGES:
            problems.append(f"{len(languages)} languages; the holdout needs at least {MIN_LANGUAGES}")
    return problems


def check_eval03(data: dict) -> list[str]:
    """Each original: a text within the limit, a writer, a session, a topic
    and a partition, with every original of one writer's session in one
    partition. Known-author attribution needs each evaluation writer in the
    training partition; cross-session linkage needs each evaluation writer
    in at least two evaluation sessions; the threshold needs at least two
    writers in the tuning partition."""
    originals = data.get("originals")
    if not isinstance(originals, list) or not originals:
        return ["no originals"]
    problems = _unique(originals, "original")
    session_partition: dict[tuple[str, str], str] = {}
    for o in originals:
        name = o.get("id")
        for field in ("writer", "session", "topic"):
            if not isinstance(o.get(field), str) or not o[field]:
                problems.append(f"{name}: no {field}")
        if o.get("partition") not in PARTITIONS:
            problems.append(f"{name}: partition must be one of {PARTITIONS}")
        text = o.get("text")
        if not isinstance(text, str) or not text.strip():
            problems.append(f"{name}: no text")
        elif len(text.encode()) > MAX_TEXT:
            problems.append(f"{name}: over the daemon's 128 KiB limit")
        for span in o.get("identifying_spans") or []:
            if not isinstance(text, str) or span.casefold() not in text.casefold():
                problems.append(f"{name}: identifying span {span!r} is not in the text")
        key = (o.get("writer"), o.get("session"))
        if session_partition.setdefault(key, o.get("partition")) != o.get("partition"):
            problems.append(f"writer {key[0]} session {key[1]} is split across partitions")
    if problems:
        return problems
    by_partition = {p: [o for o in originals if o["partition"] == p] for p in PARTITIONS}
    trained = {o["writer"] for o in by_partition["train"]}
    for writer in sorted({o["writer"] for o in by_partition["evaluation"]}):
        if writer not in trained:
            problems.append(f"evaluation writer {writer} has no training originals, so cannot be a known author")
        sessions = {o["session"] for o in by_partition["evaluation"] if o["writer"] == writer}
        if len(sessions) < 2:
            problems.append(f"evaluation writer {writer} has {len(sessions)} evaluation session; linkage needs two")
    for writer in sorted({o["writer"] for o in by_partition["tune"]} - trained):
        problems.append(f"tuning writer {writer} has no training originals")
    if len({o["writer"] for o in by_partition["tune"]}) < 2:
        problems.append("the tuning partition needs at least two writers to set a threshold")
    return problems


def eval03_report(data: dict) -> dict:
    """Counts a person checks before pinning: writers, sessions and
    originals per partition, and the topics each partition shares across
    writers (a topic only one writer covers lets an attack win on topic)."""
    out = {}
    for p in PARTITIONS:
        inside = [o for o in data["originals"] if o["partition"] == p]
        topics: dict[str, set] = {}
        for o in inside:
            topics.setdefault(o["topic"], set()).add(o["writer"])
        out[p] = {"originals": len(inside), "writers": len({o["writer"] for o in inside}),
                  "sessions": len({(o["writer"], o["session"]) for o in inside}),
                  "topics_with_one_writer": sorted(t for t, w in topics.items() if len(w) == 1)}
    return out
