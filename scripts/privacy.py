"""EVAL03 privacy scoring with the protocol's first attack
(docs/evaluation-protocol.md, "Outcomes per item" and the parity rule;
spec EVAL03, EVAL04, A22).

Attack 1, the standard stylometry baseline: character 3- to 5-grams, a
linear classifier for known-author attribution and cosine similarity for
cross-session same-author linkage. Attack 2, the learned authorship
embedding, is not built (docs/plan.md, stage 4).

How the kit reads the protocol, fixed here before any holdout opens:

- Same data for every arm: the attack learns from the training partition's
  originals (each writer's known writing), and its one tuned setting, the
  classifier's regularisation, is chosen from a fixed budget of four by
  top-1 accuracy on the tuning partition's originals.
- Operating point: 1 % false positives on different-author pairs, the
  threshold set on the tuning partition as each arm wrote it, so every arm
  is judged at its own 1 %. An attribution succeeds when the true writer
  scores highest and above the threshold; a linkage when the pair's cosine
  similarity is above it.
- Sampling unit: the writer. Success rates are per writer: of their
  evaluation originals for attribution, of their cross-session pairs for
  linkage.
- A stopped rewrite counts as an attack success: it stays in every
  denominator, and stopping can never make an arm look more private
  (spec DATA09). Stops are reported separately.
- Each attack also runs on the originals, so a reader sees how much each
  arm removes.

Identifying content kept compared with the reference: each evaluation
original's identifying spans, matched ignoring case, kept by the candidate
where the reference removed them. Each is listed for a person to judge; a
confirmed critical candidate-specific disclosure blocks the candidate.
"""

import itertools
from fractions import Fraction

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression

import parity

NGRAMS = (3, 5)
C_BUDGET = (0.1, 1.0, 10.0, 100.0)
FALSE_POSITIVE_RATE = Fraction(1, 100)


def arm_texts(record: dict | None, data: dict) -> dict[str, str | None]:
    """Original id to the arm's text (None when stopped), for the tuning and
    evaluation partitions. None for the record is the originals."""
    rewritten = [o for o in data["originals"] if o["partition"] != "train"]
    if record is None:
        return {o["id"]: o["text"] for o in rewritten}
    cases = {c["name"]: c for b in record["boots"].values() for c in b["cases"]}
    missing = [o["id"] for o in rewritten if o["id"] not in cases]
    if missing:
        raise SystemExit(f"the record has no case for {missing}")
    return {o["id"]: cases[o["id"]]["texts"][0] if cases[o["id"]]["stop_reason"] is None else None
            for o in rewritten}


def threshold(negatives: list[float]) -> float:
    """The score a success must exceed so that at most 1 % of these
    different-author scores do: the (k+1)-th largest, k = floor(1 % of them)."""
    if not negatives:
        raise SystemExit("no different-author pairs to set a threshold on")
    ordered = sorted(negatives, reverse=True)
    allowed = int(FALSE_POSITIVE_RATE * len(ordered))
    return ordered[min(allowed, len(ordered) - 1)]


class Attack:
    """Attack 1, fitted once on the training originals and tuned once on the
    tuning originals; then applied unchanged to every arm."""

    def __init__(self, data: dict):
        train = [o for o in data["originals"] if o["partition"] == "train"]
        tune = [o for o in data["originals"] if o["partition"] == "tune"]
        self.vectorizer = TfidfVectorizer(analyzer="char", ngram_range=NGRAMS, sublinear_tf=True)
        x_train = self.vectorizer.fit_transform([o["text"] for o in train])
        y_train = [o["writer"] for o in train]
        x_tune = self.vectorizer.transform([o["text"] for o in tune])
        tried = []
        for c in C_BUDGET:
            model = LogisticRegression(C=c, max_iter=10000).fit(x_train, y_train)
            accuracy = float(np.mean(model.predict(x_tune) == np.array([o["writer"] for o in tune])))
            tried.append((accuracy, -c, c, model))
        best = max(tried, key=lambda t: t[:2])  # best accuracy; the stronger regularisation on a tie
        self.c, self.model = best[2], best[3]
        self.tuning = [{"C": c, "tuning_accuracy": a} for a, _, c, _ in tried]
        self.writers = list(self.model.classes_)

    def attribution_scores(self, texts: list[str]) -> np.ndarray:
        return self.model.predict_proba(self.vectorizer.transform(texts))

    def similarity(self, texts: list[str]) -> np.ndarray:
        x = self.vectorizer.transform(texts)
        return (x @ x.T).toarray()  # rows are unit length: this is the cosine


def score_arm(attack: Attack, data: dict, texts: dict[str, str | None]) -> dict:
    """One arm's attribution and linkage results, per writer."""
    tune = [o for o in data["originals"] if o["partition"] == "tune" and texts[o["id"]] is not None]
    evaluation = [o for o in data["originals"] if o["partition"] == "evaluation"]
    written = [o for o in evaluation if texts[o["id"]] is not None]
    index = {w: i for i, w in enumerate(attack.writers)}

    # Thresholds from the tuning partition as this arm wrote it.
    tune_scores = attack.attribution_scores([texts[o["id"]] for o in tune])
    attribution_tau = threshold([float(s) for o, row in zip(tune, tune_scores)
                                 for w, s in zip(attack.writers, row) if w != o["writer"]])
    tune_sim = attack.similarity([texts[o["id"]] for o in tune])
    linkage_tau = threshold([float(tune_sim[i, j]) for i, j in itertools.combinations(range(len(tune)), 2)
                             if tune[i]["writer"] != tune[j]["writer"]])

    # Attribution on the evaluation partition.
    attributed, top1 = {}, []
    if written:
        for o, row in zip(written, attack.attribution_scores([texts[o["id"]] for o in written])):
            top1.append(attack.writers[int(np.argmax(row))] == o["writer"])
            attributed[o["id"]] = top1[-1] and float(row[index[o["writer"]]]) > attribution_tau
    attribution: dict[str, list[int]] = {}
    for o in evaluation:
        success = attributed.get(o["id"], True)  # a stopped rewrite counts as a success
        counts = attribution.setdefault(o["writer"], [0, 0])
        counts[0] += success
        counts[1] += 1

    # Linkage: every cross-session pair within the evaluation partition.
    sim = attack.similarity([texts[o["id"]] for o in written]) if written else None
    position = {o["id"]: i for i, o in enumerate(written)}
    linkage: dict[str, list[int]] = {}
    different_author = [0, 0]
    for a, b in itertools.combinations(evaluation, 2):
        if a["session"] == b["session"] and a["writer"] == b["writer"]:
            continue
        stopped = a["id"] not in position or b["id"] not in position
        above = stopped or float(sim[position[a["id"]], position[b["id"]]]) > linkage_tau
        if a["writer"] == b["writer"]:
            counts = linkage.setdefault(a["writer"], [0, 0])
            counts[0] += above
            counts[1] += 1
        elif not stopped:
            different_author[0] += above
            different_author[1] += 1

    stopped_ids = sorted(o["id"] for o in evaluation if texts[o["id"]] is None)
    return {
        "stopped": {"tuning": sum(texts[o["id"]] is None for o in data["originals"] if o["partition"] == "tune"),
                    "evaluation": len(stopped_ids), "evaluation_ids": stopped_ids},
        "attribution": {"threshold": attribution_tau,
                        "per_writer": {w: {"successes": s, "items": n} for w, (s, n) in sorted(attribution.items())},
                        "top1_accuracy_unthresholded": sum(top1) / len(top1) if top1 else None},
        "linkage": {"threshold": linkage_tau,
                    "per_writer": {w: {"successes": s, "pairs": n} for w, (s, n) in sorted(linkage.items())},
                    "evaluation_false_positive_rate": different_author[0] / different_author[1]
                    if different_author[1] else None},
    }


def rates(arm: dict, measure: str) -> dict[str, Fraction]:
    unit = "items" if measure == "attribution" else "pairs"
    return {w: Fraction(v["successes"], v[unit]) for w, v in arm[measure]["per_writer"].items()}


def comparison(reference: dict, candidate: dict, measure: str) -> dict:
    ref, cand = rates(reference, measure), rates(candidate, measure)
    writers = sorted(ref)
    differences = [cand[w] - ref[w] for w in writers]
    upper = parity.sign_flip_upper(differences)
    tied = upper == 0 and any(d == 0 for d in differences)
    return {
        "harm": f"{measure} success at 1 % false positives",
        "method": "per-writer paired difference, exact sign-flip test inverted",
        "one_sided_confidence": 1 - float(parity.ALPHA), "writers": len(writers),
        "mean_difference": float(sum(differences) / len(differences)),
        "per_writer_difference": {w: float(d) for w, d in zip(writers, differences)},
        "upper_bound": None if upper is None else float(upper),
        "verdict": parity.verdict(upper, tied_at_zero=tied),
        **({"reason": "fewer than six writers: at 97.5 % the bound cannot exist"} if upper is None else {}),
        **({"reason": "the bound is zero only through writers with no difference; the protocol says such data "
                      "never passes, so it waits for a ruling"} if tied else {}),
    }


def identifying_content(data: dict, reference: dict[str, str | None], candidate: dict[str, str | None]) -> dict:
    """Identifying spans the candidate kept where the reference removed them,
    by original id and count only (no content)."""
    kept_by_candidate_only, totals = [], {"spans": 0, "reference_kept": 0, "candidate_kept": 0}
    for o in data["originals"]:
        if o["partition"] != "evaluation" or not o.get("identifying_spans"):
            continue
        ref_text, cand_text = reference[o["id"]], candidate[o["id"]]
        if ref_text is None or cand_text is None:
            continue
        ref_kept = {s for s in o["identifying_spans"] if s.casefold() in ref_text.casefold()}
        cand_kept = {s for s in o["identifying_spans"] if s.casefold() in cand_text.casefold()}
        totals["spans"] += len(o["identifying_spans"])
        totals["reference_kept"] += len(ref_kept)
        totals["candidate_kept"] += len(cand_kept)
        if cand_kept - ref_kept:
            kept_by_candidate_only.append({"original": o["id"], "spans": len(cand_kept - ref_kept)})
    return {**totals, "candidate_only": kept_by_candidate_only,
            "note": "Each candidate-only span needs a person to judge whether it is a critical disclosure; "
                    "a confirmed one blocks the candidate. Stopped rewrites are left out here."}


def evaluate(data: dict, arms: dict[str, dict[str, str | None]], reference: str, candidate: str) -> dict:
    """Attack 1 on the originals and on every arm, then the two required
    comparisons of the candidate with the reference. Content free."""
    attack = Attack(data)
    originals = arm_texts(None, data)
    scored = {"originals": score_arm(attack, data, originals)}
    for name, texts in arms.items():
        scored[name] = score_arm(attack, data, texts)
    out = {
        "attack": {"name": "character n-grams with a linear classifier and cosine similarity",
                   "ngrams": list(NGRAMS), "C_budget": list(C_BUDGET), "C_chosen": attack.c,
                   "tuning": attack.tuning, "false_positive_rate": float(FALSE_POSITIVE_RATE)},
        "arms": scored,
        "comparisons": {m: comparison(scored[reference], scored[candidate], m) for m in ("attribution", "linkage")},
        "identifying_content": identifying_content(data, arms[reference], arms[candidate]),
        "not_run": ["Attack 2, the learned authorship embedding: not built (docs/plan.md, stage 4). The "
                    "privacy gate needs both attacks, so no candidate can pass it on this record alone."],
    }
    out["candidate_passes_privacy"] = False  # attack 2 is not run
    return out
