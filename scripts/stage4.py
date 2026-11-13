# /// script
# requires-python = ">=3.12"
# dependencies = ["tokenizers==0.22.1", "scikit-learn==1.9.1", "numpy==2.5.4", "scipy==1.18.1"]
# ///
"""The stage 4 kit: qualifying the substitution (spec section 11, EVAL02 to
EVAL04; docs/evaluation-protocol.md). Once a candidate's weights are on disk
and the holdouts are written and pinned:

    uv run scripts/stage4.py check EVAL02 <file>        # a set's checks and pin state
    uv run scripts/stage4.py pin EVAL02 <file>          # pin a holdout, once, before any run
    uv run scripts/stage4.py rewrite <name> EVAL02 <file>
    uv run scripts/stage4.py review <file> <record> <record>
    uv run scripts/stage4.py fidelity <file> --reference <record> --candidate <record> --key <key> --reviews <packet>
    uv run scripts/stage4.py privacy <file> --reference <record> --candidate <record>
    uv run scripts/stage4.py repeat <name> <file> [--runs 3]
    uv run scripts/stage4.py sample-size --from <fidelity score>

`rewrite` runs a set's texts, one user turn each, through the same real path
as stage 3 (the daemon's rewrite code in the guest, the adapter, the host
relay, the sandboxed worker and the copy-only tap) and keeps the same record
of every call. For EVAL03 it rewrites the tuning and evaluation partitions;
the attack learns from the training originals. `review` makes the blinded
EVAL02 review packet and its key. `fidelity` and `privacy` score one
candidate against the reference and write a content-free score. `repeat`
runs a development set several times to measure run-to-run variation.
`sample-size` gives the EVAL02 holdout size from development rates.

A record holding holdout text stays beside the holdout, outside this
repository (`<holdout folder>/records/<name>/`); development records go to
evidence/stage4/<name>/. Scores, which hold no text, go to
evidence/stage4/<candidate>/. A model not in stage3.GATE_MODELS, the
candidates, or any development set, is development only and counts toward
no gate.

In a development run `originals` may stand for an arm: the input text
unchanged. In a holdout run the reference arm must be the reference's own
record.
"""

import argparse
import hashlib
import json
import signal
import sys
import time
from pathlib import Path

import boot
import fidelity
import holdouts
import measures
import stage3
from fetch_model import DEST

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence/stage4"
KIT_FILES = ("scripts/stage4.py", "scripts/holdouts.py", "scripts/fidelity.py", "scripts/privacy.py",
             "scripts/parity.py")
DEVELOPMENT_ONLY = ("Development only, not evaluated: a development set or a development stand-in. Proves the "
                    "kit end to end; never counted toward a gate in docs/plan.md.")


def stamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, value) -> Path:
    fidelity.write_json(path, value)
    return path


def records_dir(data: dict, input_path: Path, name: str) -> Path:
    if data["kind"] == "holdout":
        return input_path.resolve().parent / "records" / name
    return EVIDENCE / name


def development(model: str, data: dict) -> bool:
    return model not in stage3.GATE_MODELS or data["kind"] == "development"


def header(kind: str, dataset: str, model: dict, model_dir: Path, checks: dict, data: dict, path: Path) -> dict:
    dev = development(model["name"], data)
    return {
        "record": f"stage 4 {kind}", "dataset": dataset, "model": model["name"],
        "development_only": dev,
        "label": DEVELOPMENT_ONLY if dev else
        "Candidate run on a pinned holdout. A gate passes only when its score is linked in docs/plan.md.",
        "input": {"path": str(path), "sha256": sha256(path), "kind": data["kind"], "label": data.get("label")},
        "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kit": {**stage3.kit(), "stage4_files_sha256": {f: stage3.sha256_file(ROOT / f) for f in KIT_FILES}},
        "machine": stage3.machine(), "preflight": checks,
        "artifact": stage3.artifact(model), "configuration": stage3.configuration(model),
        "model_dir": str(model_dir),
    }


def texts_to_rewrite(dataset: str, data: dict) -> list[tuple[str, str]]:
    if dataset == "EVAL02":
        return [(i["id"], i["text"]) for i in data["items"]]
    return [(o["id"], o["text"]) for o in data["originals"] if o["partition"] != "train"]


def one_boot(label: str, name: str, model: dict, model_dir: Path, pairs: list[tuple[str, str]]) -> dict:
    cases = [{"name": i, "group": label, "body": stage3.user(text)} for i, text in pairs]
    run = boot.run(label, [stage3.guest_case(c) for c in cases], stage3.worker(model), name, model_dir,
                   stage3.time_limit(cases))
    art, conf = stage3.artifact(model), stage3.configuration(model)
    analysed = stage3.analyse(label, cases, run, art, conf, {}, {})
    stage3.wait_for_vm_exit(run.vm_pid)
    analysed["summary"] = {**measures.latency(analysed["cases"]),
                           "whole_boot": measures.window(run.samples, run.started_ns, run.ended_ns)
                           if run.samples else None}
    return analysed


def prepared(name: str, dataset: str, path: Path) -> tuple[dict, dict, Path, dict]:
    data = holdouts.load(path, dataset)
    if data["kind"] == "holdout" and name not in stage3.GATE_MODELS:
        raise SystemExit(f"{name} is not a candidate; a holdout is rewritten only by "
                         f"{', '.join(stage3.GATE_MODELS)}")
    model = stage3.pinned(name)
    model_dir = DEST / name
    checks = stage3.preflight(model, model_dir)
    return data, model, model_dir, checks


def run_rewrite(name: str, dataset: str, path: Path) -> Path:
    data, model, model_dir, checks = prepared(name, dataset, path)
    record = header(dataset.lower(), dataset, model, model_dir, checks, data, path)
    analysed = one_boot(dataset.lower(), name, model, model_dir, texts_to_rewrite(dataset, data))
    record["summary"] = analysed["summary"]
    record["boots"] = {dataset.lower(): analysed}
    out = write(records_dir(data, path, name) / f"{dataset.lower()}-{stamp()}.json", record)
    s = record["summary"]
    if record["development_only"]:
        print(f"\n{record['label']}")
    print(f"\nRecord: {out}\n{dataset}: {s['rewritten']} of {s['cases']} rewritten; stopped {s['stopped_by_reason']}")
    return out


def run_repeat(name: str, path: Path, runs: int) -> Path:
    """The protocol's repeated runs: the same development items, `runs`
    boots in turn; any output that differs between runs is reported."""
    data, model, model_dir, checks = prepared(name, "EVAL02", path)
    if data["kind"] != "development":
        raise SystemExit("repeated runs use development items, never a holdout")
    record = header("repeat", "EVAL02", model, model_dir, checks, data, path)
    pairs = texts_to_rewrite("EVAL02", data)
    boots = {}
    for i in range(1, runs + 1):
        print(f"run {i} of {runs}: {len(pairs)} items", flush=True)
        boots[f"run-{i}"] = one_boot(f"repeat-{i}", name, model, model_dir, pairs)
    varied = []
    for item_id, _ in pairs:
        seen = [next(c for c in b["cases"] if c["name"] == item_id) for b in boots.values()]
        results = [(c["stop_reason"], c["texts"][0] if c["stop_reason"] is None else None) for c in seen]
        if len(set(results)) > 1:
            varied.append({"item": item_id, "distinct_results": len(set(results)),
                           "stop_reasons": [r for r, _ in results]})
    record["summary"] = {"runs": runs, "items": len(pairs), "items_that_varied": len(varied), "varied": varied,
                         "per_run": {k: b["summary"] for k, b in boots.items()}}
    record["boots"] = boots
    out = write(EVIDENCE / name / f"repeat-{stamp()}.json", record)
    print(f"\n{record['label']}\n\nRecord: {out}\n{len(varied)} of {len(pairs)} items differed across {runs} runs")
    return out


def read_record(arg: str, data: dict, path: Path) -> tuple[str, dict | None]:
    """An arm: a run record, or `originals` in a development comparison."""
    if arg == "originals":
        if data["kind"] == "holdout":
            raise SystemExit("on a holdout every arm is a run record; originals cannot stand in for one")
        return "originals", None
    record = json.loads(Path(arg).read_text())
    if record["input"]["sha256"] != sha256(path):
        raise SystemExit(f"{arg} was run on other inputs than {path}")
    return record["model"], record


def arm_header(name: str, record: dict | None, arg: str) -> dict:
    if record is None:
        return {"arm": name, "about": "the input text unchanged (development comparisons only)"}
    return {"arm": name, "record": arg, "record_sha256": sha256(Path(arg)),
            "development_only": record["development_only"],
            "artifact_sha256": record["artifact"]["sha256"], "configuration_sha256": record["configuration"]["sha256"]}


def check_arms(data: dict, reference: tuple[str, dict | None], candidate: tuple[str, dict | None]) -> None:
    if reference[0] == candidate[0]:
        raise SystemExit("the reference and the candidate are the same arm")
    if data["kind"] == "holdout":
        if reference[0] != "reference":
            raise SystemExit("on a holdout the reference arm is the reference's own record")
        if candidate[0] not in stage3.GATE_MODELS:
            raise SystemExit(f"on a holdout the candidate is one of {', '.join(stage3.GATE_MODELS)}")


def score_header(kind: str, data: dict, path: Path, arms: list[dict]) -> dict:
    dev = data["kind"] == "development" or any(a.get("development_only", True) for a in arms)
    return {"score": f"stage 4 {kind}", "development_only": dev,
            "label": DEVELOPMENT_ONLY if dev else "Candidate score on a pinned holdout.",
            "input": {"sha256": sha256(path), "kind": data["kind"], "label": data.get("label")},
            "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "kit": {"commit": stage3.kit()["commit"],
                    "files_sha256": {f: stage3.sha256_file(ROOT / f) for f in KIT_FILES}},
            "arms": arms}


def run_review(path: Path, records: list[str]) -> None:
    data = holdouts.load(path, "EVAL02")
    arms = {}
    for arg in records:
        name, record = read_record(arg, data, path)
        arms[name] = fidelity.arm_outputs(record, data)
    packet, key = fidelity.review_packet(data, arms)
    folder = path.resolve().parent / "records" if data["kind"] == "holdout" else EVIDENCE / "review"
    when = stamp()
    p = write(folder / f"review-packet-{when}.json", packet)
    k = write(folder / f"review-key-{when}.json", key)
    print(f"Packet for the reviewers ({len(packet['entries'])} outputs, arms hidden): {p}\n"
          f"Key, kept from the reviewers: {k}")


def run_fidelity(path: Path, reference: str, candidate: str, key: Path, reviews: Path) -> Path:
    data = holdouts.load(path, "EVAL02")
    ref, cand = read_record(reference, data, path), read_record(candidate, data, path)
    check_arms(data, ref, cand)
    answers = fidelity.adjudications(json.loads(reviews.read_text()), json.loads(key.read_text()))
    result = fidelity.compare(data, (ref[0], fidelity.arm_outputs(ref[1], data)),
                              (cand[0], fidelity.arm_outputs(cand[1], data)), answers)
    score = score_header("EVAL02 fidelity", data, path,
                         [arm_header(ref[0], ref[1], reference), arm_header(cand[0], cand[1], candidate)])
    score["reviews"] = {"packet_sha256": sha256(reviews), "key_sha256": sha256(key)}
    score.update(result)
    out = write(EVIDENCE / cand[0] / f"fidelity-{stamp()}.json", score)
    c = result["comparison"]
    if score["development_only"]:
        print(f"\n{score['label']}")
    print(f"\nScore: {out}\nEVAL02, {cand[0]} against {ref[0]}: {result['items']} items; "
          f"outcomes {result['outcomes']}")
    if "pairs" in result:
        print(f"Pairs {result['pairs']}; upper bound {c['upper_bound']:.4f}; comparison {c['verdict']}")
    else:
        print(f"Comparison {c['verdict']}: {c['reason']}")
    print(f"Candidate critical errors: {len(result['candidate_critical_errors'])}; "
          f"passes fidelity: {result['candidate_passes_fidelity']}")
    return out


def run_privacy(path: Path, reference: str, candidate: str) -> Path:
    import privacy

    data = holdouts.load(path, "EVAL03")
    ref, cand = read_record(reference, data, path), read_record(candidate, data, path)
    check_arms(data, ref, cand)
    arms = {ref[0]: privacy.arm_texts(ref[1], data), cand[0]: privacy.arm_texts(cand[1], data)}
    result = privacy.evaluate(data, arms, ref[0], cand[0])
    score = score_header("EVAL03 privacy", data, path,
                         [arm_header(ref[0], ref[1], reference), arm_header(cand[0], cand[1], candidate)])
    score["partitions"] = holdouts.eval03_report(data)
    score.update(result)
    out = write(EVIDENCE / cand[0] / f"privacy-{stamp()}.json", score)
    if score["development_only"]:
        print(f"\n{score['label']}")
    print(f"\nScore: {out}")
    for arm, value in result["arms"].items():
        a, l = value["attribution"], value["linkage"]
        print(f"{arm}: attribution {sum(w['successes'] for w in a['per_writer'].values())} of "
              f"{sum(w['items'] for w in a['per_writer'].values())}, linkage "
              f"{sum(w['successes'] for w in l['per_writer'].values())} of "
              f"{sum(w['pairs'] for w in l['per_writer'].values())} pairs; stopped {value['stopped']['evaluation']}")
    for measure, c in result["comparisons"].items():
        print(f"{measure}: mean difference {c['mean_difference']:+.3f}, upper bound {c['upper_bound']}, {c['verdict']}")
    print(f"Passes privacy: {result['candidate_passes_privacy']} ({result['not_run'][0]})")
    return out


def run_sample_size(score_path: Path) -> None:
    import parity

    score = json.loads(score_path.read_text())
    if "pairs" not in score:
        raise SystemExit("that fidelity score has no pairs (it is unresolved)")
    n = score["items"]
    p_b, p_c = score["pairs"]["candidate_only_failure"] / n, score["pairs"]["reference_only_failure"] / n
    result = parity.tango_sample_size(p_b, p_c)
    print(f"Development rates from {n} items: candidate only {p_b:.4f}, reference only {p_c:.4f}")
    if result["items"] is None:
        print(f"No holdout size: {result['reason']}")
    else:
        print(f"EVAL02 holdout: {result['items']} items gives power {result['power']:.3f} "
              f"at 97.5 % one-sided (protocol: at least 80 %)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("check", "pin"):
        p = sub.add_parser(command)
        p.add_argument("dataset", choices=("EVAL02", "EVAL03"))
        p.add_argument("file", type=Path)
    p = sub.add_parser("rewrite")
    p.add_argument("name")
    p.add_argument("dataset", choices=("EVAL02", "EVAL03"))
    p.add_argument("file", type=Path)
    p = sub.add_parser("repeat")
    p.add_argument("name")
    p.add_argument("file", type=Path)
    p.add_argument("--runs", type=int, default=3)
    p = sub.add_parser("review")
    p.add_argument("file", type=Path)
    p.add_argument("records", nargs="+")
    p = sub.add_parser("fidelity")
    p.add_argument("file", type=Path)
    p.add_argument("--reference", required=True)
    p.add_argument("--candidate", required=True)
    p.add_argument("--key", type=Path, required=True)
    p.add_argument("--reviews", type=Path, required=True)
    p = sub.add_parser("privacy")
    p.add_argument("file", type=Path)
    p.add_argument("--reference", required=True)
    p.add_argument("--candidate", required=True)
    p = sub.add_parser("sample-size")
    p.add_argument("--from", dest="score", type=Path, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("stage4: stopped from outside; no record written"))
    if args.command == "check":
        data = holdouts.load(args.file, args.dataset)
        print(f"{args.file}: {args.dataset} {data['kind']}, checks pass")
        if args.dataset == "EVAL03":
            print(json.dumps(holdouts.eval03_report(data), indent=1))
    elif args.command == "pin":
        print(json.dumps(holdouts.pin(args.file, args.dataset), indent=1))
    elif args.command == "rewrite":
        run_rewrite(args.name, args.dataset, args.file)
    elif args.command == "repeat":
        run_repeat(args.name, args.file, args.runs)
    elif args.command == "review":
        run_review(args.file, args.records)
    elif args.command == "fidelity":
        run_fidelity(args.file, args.reference, args.candidate, args.key, args.reviews)
    elif args.command == "privacy":
        run_privacy(args.file, args.reference, args.candidate)
    else:
        run_sample_size(args.score)


if __name__ == "__main__":
    main()
