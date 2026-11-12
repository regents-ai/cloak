"""EVAL02 fidelity scoring (docs/evaluation-protocol.md, "Outcomes per item"
and the parity rule; spec EVAL02, A04).

Per item and arm the outcome is one of:

- **stopped**: the daemon rejected the reply or the call timed out (any
  stop reason in the record). It stays in the denominator.
- **critical**: a protected span is not in the output as written (checked
  mechanically), or the blinded review found a required relation lost or
  reversed.
- **minor**: the review found a lesser meaning difference.
- **pass**: every span kept and the review found every relation kept.

Every output that keeps all its spans goes to the blinded review: the
protocol names no mechanical check of relations, so none is made here, and
reviewers see the original and one output at a time, never the arm.

Harm, for the required comparison, is a critical error or a stop: a stopped
item counts as a failure (protocol; spec DATA09), so a candidate cannot look
better by stopping on hard items. The pairs are tabulated, the upper bound
of candidate harm minus reference harm comes from Tango's interval, and any
critical error of the candidate's blocks it whatever the bound.
"""

import json
import secrets
from pathlib import Path

import parity

OUTCOMES = ("pass", "minor", "critical", "stopped")
RELATION_VERDICTS = ("kept", "lost", "reversed")


def arm_outputs(record: dict | None, data: dict) -> dict[str, dict]:
    """Item id to {stop_reason, text} for one arm. None is the originals:
    the input text unchanged, never stopped."""
    if record is None:
        return {i["id"]: {"stop_reason": None, "text": i["text"]} for i in data["items"]}
    cases = {c["name"]: c for b in record["boots"].values() for c in b["cases"]}
    missing = [i["id"] for i in data["items"] if i["id"] not in cases]
    if missing:
        raise SystemExit(f"the record has no case for {missing}")
    return {i["id"]: {"stop_reason": cases[i["id"]]["stop_reason"],
                      "text": cases[i["id"]]["texts"][0] if cases[i["id"]]["stop_reason"] is None else None}
            for i in data["items"]}


def missing_spans(item: dict, text: str) -> list[dict]:
    return [s for s in item.get("protected_spans") or [] if s["text"] not in text]


def review_packet(data: dict, arms: dict[str, dict[str, dict]]) -> tuple[dict, dict]:
    """The blinded review: every output that kept all its spans, in a random
    order under a random id. The packet goes to reviewers; the key, which
    maps each id to its arm, stays with whoever runs the scoring."""
    items = {i["id"]: i for i in data["items"]}
    entries = []
    for arm, outputs in arms.items():
        for item_id, out in outputs.items():
            item = items[item_id]
            if out["stop_reason"] is None and not missing_spans(item, out["text"]):
                entries.append((arm, item, out["text"]))
    secrets.SystemRandom().shuffle(entries)
    packet, key = [], {}
    for arm, item, text in entries:
        blind = secrets.token_hex(6)
        key[blind] = {"arm": arm, "item": item["id"]}
        packet.append({
            "id": blind, "language": item["language"], "original": item["text"], "output": text,
            "relations": [{"id": r["id"], "type": r["type"], "statement": r["statement"],
                           **({"inclusive": r["inclusive"]} if "inclusive" in r else {}),
                           "verdict": None} for r in item.get("relations") or []],
            "minor_error": None, "note": "",
        })
    instructions = ("For each entry, read the original and the output. For every relation set verdict to "
                    "kept, lost or reversed. Set minor_error to true when the output changes the meaning in a "
                    "lesser way that no relation covers, otherwise false. Leave id unchanged.")
    return ({"dataset": data["dataset"], "instructions": instructions, "entries": packet},
            {"dataset": data["dataset"], "key": key})


def adjudications(packet: dict, key: dict) -> dict[tuple[str, str], dict]:
    """The filled packet, unblinded: (arm, item) to the review's answers.
    An entry with any answer missing or not one of the allowed values is
    left out, so its item stays unreviewed."""
    out = {}
    for entry in packet["entries"]:
        verdicts = {r["id"]: r["verdict"] for r in entry["relations"]}
        if any(v not in RELATION_VERDICTS for v in verdicts.values()) or not isinstance(entry["minor_error"], bool):
            continue
        k = key["key"][entry["id"]]
        out[(k["arm"], k["item"])] = {"relations": verdicts, "minor_error": entry["minor_error"]}
    return out


def outcome(item: dict, out: dict, review: dict | None) -> dict:
    if out["stop_reason"] is not None:
        return {"outcome": "stopped", "stop_reason": out["stop_reason"]}
    lost = missing_spans(item, out["text"])
    if lost:
        return {"outcome": "critical", "spans_lost": [s["type"] for s in lost]}
    if review is None:
        return {"outcome": None, "unreviewed": True}
    broken = {r: v for r, v in review["relations"].items() if v != "kept"}
    if broken:
        return {"outcome": "critical", "relations": broken}
    return {"outcome": "minor" if review["minor_error"] else "pass"}


def harm(o: dict) -> bool:
    return o["outcome"] in ("critical", "stopped")


def compare(data: dict, reference: tuple[str, dict], candidate: tuple[str, dict],
            reviews: dict[tuple[str, str], dict]) -> dict:
    """The paired comparison of one candidate with the reference. Content
    free: item ids, outcomes and counts only."""
    (ref_name, ref_out), (cand_name, cand_out) = reference, candidate
    rows = []
    for item in data["items"]:
        r = outcome(item, ref_out[item["id"]], reviews.get((ref_name, item["id"])))
        c = outcome(item, cand_out[item["id"]], reviews.get((cand_name, item["id"])))
        rows.append({"item": item["id"], "reference": r, "candidate": c})
    unreviewed = [(row["item"], side) for row in rows for side in ("reference", "candidate")
                  if row[side].get("unreviewed")]
    n = len(rows)
    out = {"items": n, "per_item": rows,
           "unreviewed": [{"item": i, "arm": side} for i, side in unreviewed],
           "outcomes": {side: {o: sum(row[side]["outcome"] == o for row in rows) for o in OUTCOMES}
                        for side in ("reference", "candidate")}}
    out["cross_table"] = {f"reference {a} / candidate {b}": sum(
        row["reference"]["outcome"] == a and row["candidate"]["outcome"] == b for row in rows)
        for a in OUTCOMES for b in OUTCOMES}
    blockers = [{"item": row["item"], **{k: v for k, v in row["candidate"].items() if k != "outcome"},
                 "reference_also_critical": row["reference"]["outcome"] == "critical"}
                for row in rows if row["candidate"]["outcome"] == "critical"]
    out["candidate_critical_errors"] = blockers
    if unreviewed:
        out["comparison"] = {"verdict": "unresolved", "reason": f"{len(unreviewed)} outputs are not yet reviewed"}
        out["candidate_passes_fidelity"] = False
        return out
    b = sum(harm(row["candidate"]) and not harm(row["reference"]) for row in rows)
    c = sum(harm(row["reference"]) and not harm(row["candidate"]) for row in rows)
    both = sum(harm(row["candidate"]) and harm(row["reference"]) for row in rows)
    upper = parity.tango_upper(b, c, n)
    out["pairs"] = {"candidate_only_failure": b, "reference_only_failure": c, "both_fail": both,
                    "both_pass": n - b - c - both}
    out["comparison"] = {
        "harm": "critical error or stopped", "method": "Tango score interval, paired proportions",
        "one_sided_confidence": 1 - float(parity.ALPHA), "observed_difference": (b - c) / n,
        "upper_bound": upper, "verdict": parity.verdict(upper, tied_at_zero=False)}
    out["candidate_passes_fidelity"] = out["comparison"]["verdict"] == "pass" and not blockers
    return out


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
