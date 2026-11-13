"""Checks of the stage 4 kit's own logic: the parity bounds and the sample
size, the input sets' checks and pins, the fidelity outcomes and blinded
review, the privacy attack's thresholds and denominators, and the rules on
which arms a holdout comparison accepts. No guest boots here; the kit's
stand-in runs do that.

    uv run --with pytest==8.4.2 --with scikit-learn==1.9.1 --with numpy==2.5.4 \
        --with scipy==1.18.1 --with tokenizers==0.22.1 pytest tests/test_stage4.py
"""

import copy
import itertools
import json
import math
import random
import sys
from fractions import Fraction
from pathlib import Path
from statistics import NormalDist

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import fidelity  # noqa: E402
import holdouts  # noqa: E402
import parity  # noqa: E402
import privacy  # noqa: E402
import stage4  # noqa: E402

DEV_FIDELITY = ROOT / "reference/stage4-dev-fidelity.json"
DEV_PRIVACY = ROOT / "reference/stage4-dev-privacy.json"
Z = NormalDist().inv_cdf(1 - float(parity.ALPHA))


# The parity bounds.


@pytest.mark.parametrize("n", [5, 40, 300])
def test_no_paired_failure_gives_a_positive_bound(n):
    assert parity.tango_upper(0, 0, n) == pytest.approx(Z * Z / (n + Z * Z))


@pytest.mark.parametrize("b,c,n", [(3, 9, 100), (10, 4, 60), (0, 5, 40), (7, 7, 200), (0, 12, 12)])
def test_the_tango_bound_is_where_the_score_reaches_minus_z(b, c, n):
    upper = parity.tango_upper(b, c, n)
    assert upper >= (b - c) / n
    if upper < 1:
        assert parity._tango_z(b, c, n, upper) == pytest.approx(-Z, abs=1e-6)


def test_a_candidate_as_good_as_the_reference_never_passes():
    assert all(parity.tango_upper(k, k, 500) > 0 for k in range(0, 60, 5))


def test_the_sign_flip_bound_is_the_kth_largest_subset_mean():
    rng = random.Random(4)
    for w in (6, 7, 9):
        d = [Fraction(rng.randint(-4, 4), rng.choice((2, 3, 4))) for _ in range(w)]
        means = sorted((sum(s) / len(s) for r in range(1, w + 1) for s in itertools.combinations(d, r)), reverse=True)
        assert parity.sign_flip_upper(d) == means[math.floor(parity.ALPHA * 2**w) - 1]


def test_fewer_than_six_writers_have_no_bound():
    assert parity.sign_flip_upper([Fraction(-1)] * 5) is None
    assert parity.verdict(None, tied_at_zero=False) == "unresolved"


def test_a_zero_bound_from_tied_writers_waits_for_a_ruling():
    assert parity.verdict(Fraction(0), tied_at_zero=True) == "unresolved"
    assert parity.verdict(Fraction(0), tied_at_zero=False) == "pass"
    assert parity.verdict(0.01, tied_at_zero=False) == "fail"


def test_the_exact_power_sums_every_passing_outcome():
    n, p_b, p_c = 30, 0.02, 0.3
    expected = sum(math.comb(n, b) * math.comb(n - b, c) * p_b**b * p_c**c * (1 - p_b - p_c) ** (n - b - c)
                   for b in range(n + 1) for c in range(n + 1 - b) if parity.tango_upper(b, c, n) <= 0)
    assert parity.tango_power(n, p_b, p_c) == pytest.approx(expected, rel=1e-9)


def test_the_sample_size_reaches_the_power_and_one_fewer_does_not():
    found = parity.tango_sample_size(0.02, 0.10)
    assert found["power"] >= parity.POWER
    assert parity.tango_power(found["items"] - 1, 0.02, 0.10) < parity.POWER
    assert parity.tango_sample_size(0.1, 0.1)["items"] is None


# The input sets and their pins.


@pytest.fixture
def pins(tmp_path, monkeypatch):
    path = tmp_path / "holdouts.json"
    path.write_text(json.dumps({"EVAL02": None, "EVAL03": None}))
    monkeypatch.setattr(holdouts, "PINS", path)
    return path


def as_holdout(tmp_path, source: Path) -> Path:
    data = json.loads(source.read_text())
    data["kind"] = "holdout"
    path = tmp_path / "outside" / source.name
    path.parent.mkdir()
    path.write_text(json.dumps(data))
    return path


def test_the_development_sets_pass_their_checks():
    assert holdouts.load(DEV_FIDELITY, "EVAL02")["kind"] == "development"
    assert holdouts.load(DEV_PRIVACY, "EVAL03")["kind"] == "development"


def test_a_holdout_runs_only_once_pinned_and_unchanged(tmp_path, pins):
    path = as_holdout(tmp_path, DEV_PRIVACY)
    with pytest.raises(SystemExit, match="no pin"):
        holdouts.load(path, "EVAL03")
    holdouts.pin(path, "EVAL03")
    assert holdouts.load(path, "EVAL03")["kind"] == "holdout"
    with pytest.raises(SystemExit, match="never replaced"):
        holdouts.pin(path, "EVAL03")
    path.write_text(path.read_text().replace("Cheers", "Thanks"))
    with pytest.raises(SystemExit, match="not the pinned"):
        holdouts.load(path, "EVAL03")


def test_a_holdout_inside_the_repository_is_refused(pins):
    data = json.loads(DEV_PRIVACY.read_text())
    data["kind"] = "holdout"
    inside = ROOT / "evidence" / "test-holdout-inside.json"
    inside.write_text(json.dumps(data))
    try:
        with pytest.raises(SystemExit, match="inside the repository"):
            holdouts.pin(inside, "EVAL03")
    finally:
        inside.unlink()


def test_a_fidelity_holdout_must_cover_every_category_and_three_languages():
    data = json.loads(DEV_FIDELITY.read_text())
    data["kind"] = "holdout"
    assert holdouts.check_eval02(data) == []
    data["items"] = [i for i in data["items"] if i["language"] == "en"]
    problems = holdouts.check_eval02(data)
    assert any("languages" in p for p in problems)
    assert any("multilingual" in p for p in problems)


def test_annotation_faults_are_found():
    data = json.loads(DEV_FIDELITY.read_text())
    item = data["items"][0]
    item["protected_spans"].append({"type": "number", "text": "99 kg"})
    item["relations"].append({"id": "r9", "type": "inequality", "statement": "x"})
    item["relations"].append({"id": "r9", "type": "feeling", "statement": "y"})
    problems = holdouts.check_eval02(data)
    assert len([p for p in problems if p.startswith(item["id"])]) == 4


def test_privacy_partitions_are_checked():
    data = json.loads(DEV_PRIVACY.read_text())
    split = copy.deepcopy(data)
    split["originals"][0]["partition"] = "tune"  # w1 s1 now spans two partitions
    assert any("split across partitions" in p for p in holdouts.check_eval03(split))
    unknown = copy.deepcopy(data)
    unknown["originals"] = [o for o in unknown["originals"] if not (o["writer"] == "w2" and o["partition"] == "train")]
    assert any("w2 has no training originals" in p for p in holdouts.check_eval03(unknown))
    one_session = copy.deepcopy(data)
    one_session["originals"] = [o for o in one_session["originals"] if not (o["writer"] == "w3" and o["session"] == "s5")]
    assert any("w3 has 1 evaluation session" in p for p in holdouts.check_eval03(one_session))


# Fidelity.


ITEM = {"id": "i", "language": "en", "text": "ship 3 boxes of 12.5 kg",
        "relations": [{"id": "r1", "type": "quantity and unit", "statement": "3 boxes"}],
        "protected_spans": [{"type": "number", "text": "12.5 kg"}]}


@pytest.mark.parametrize("out,review,expected", [
    ({"stop_reason": "malformed", "text": None}, None, "stopped"),
    ({"stop_reason": None, "text": "ship three boxes of 12.5 kilograms"}, None, "critical"),
    ({"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}, {"relations": {"r1": "reversed"}, "minor_error": False},
     "critical"),
    ({"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}, {"relations": {"r1": "kept"}, "minor_error": True},
     "minor"),
    ({"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}, {"relations": {"r1": "kept"}, "minor_error": False},
     "pass"),
    ({"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}, None, None),
])
def test_each_output_gets_its_outcome(out, review, expected):
    assert fidelity.outcome(ITEM, out, review)["outcome"] == expected


def test_the_review_hides_the_arm_and_skips_what_is_already_decided():
    data = {"dataset": "EVAL02", "items": [ITEM]}
    arms = {"reference": {"i": {"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}},
            "lead": {"i": {"stop_reason": None, "text": "ship 3 boxes of 12.5 kilograms"}},
            "challenger": {"i": {"stop_reason": "timed out", "text": None}}}
    packet, key = fidelity.review_packet(data, arms)
    assert len(packet["entries"]) == 1
    assert "arm" not in json.dumps(packet["entries"])
    entry = packet["entries"][0]
    assert key["key"][entry["id"]] == {"arm": "reference", "item": "i"}
    entry["relations"][0]["verdict"] = "kept"
    entry["minor_error"] = False
    assert fidelity.adjudications(packet, key) == {("reference", "i"): {"relations": {"r1": "kept"},
                                                                          "minor_error": False}}


def test_a_stop_is_harm_and_pairs_are_counted():
    items = [dict(ITEM, id=f"i{k}") for k in range(4)]
    ok = {"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}
    stopped = {"stop_reason": "timed out", "text": None}
    ref = {"i0": ok, "i1": ok, "i2": stopped, "i3": stopped}
    cand = {"i0": ok, "i1": stopped, "i2": ok, "i3": stopped}
    reviews = {(arm, f"i{k}"): {"relations": {"r1": "kept"}, "minor_error": False}
               for arm in ("reference", "lead") for k in range(4)}
    result = fidelity.compare({"items": items}, ("reference", ref), ("lead", cand), reviews)
    assert result["pairs"] == {"candidate_only_failure": 1, "reference_only_failure": 1, "both_fail": 1, "both_pass": 1}
    assert result["comparison"]["upper_bound"] == pytest.approx(parity.tango_upper(1, 1, 4))
    assert result["candidate_passes_fidelity"] is False


def test_an_unreviewed_output_leaves_the_comparison_unresolved():
    ok = {"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}
    result = fidelity.compare({"items": [ITEM]}, ("reference", {"i": ok}), ("lead", {"i": ok}), {})
    assert result["comparison"]["verdict"] == "unresolved"
    assert len(result["unreviewed"]) == 2


def test_a_candidate_critical_error_blocks_whatever_the_bound():
    items = [dict(ITEM, id=f"i{k}") for k in range(200)]
    ok = {"stop_reason": None, "text": "ship 3 boxes of 12.5 kg"}
    ref = {f"i{k}": ({"stop_reason": "timed out", "text": None} if k < 60 else ok) for k in range(200)}
    cand = {f"i{k}": ok for k in range(200)}
    cand["i199"] = {"stop_reason": None, "text": "ship 3 boxes of 12.5 kilograms"}
    reviews = {(arm, f"i{k}"): {"relations": {"r1": "kept"}, "minor_error": False}
               for arm in ("reference", "lead") for k in range(200)}
    result = fidelity.compare({"items": items}, ("reference", ref), ("lead", cand), reviews)
    assert result["comparison"]["verdict"] == "pass"
    assert [b["item"] for b in result["candidate_critical_errors"]] == ["i199"]
    assert result["candidate_passes_fidelity"] is False


# Privacy.


def test_the_threshold_allows_at_most_one_percent_above_it():
    negatives = [k / 1000 for k in range(1000)]
    tau = privacy.threshold(negatives)
    assert sum(n > tau for n in negatives) <= 10
    assert sum(n >= tau for n in negatives) > 10


def test_a_stopped_rewrite_counts_as_an_attack_success():
    data = json.loads(DEV_PRIVACY.read_text())
    attack = privacy.Attack(data)
    texts = privacy.arm_texts(None, data)
    whole = privacy.score_arm(attack, data, texts)
    stopped = dict(texts)
    for o in data["originals"]:
        if o["writer"] == "w4" and o["partition"] == "evaluation":
            stopped[o["id"]] = None
    partial = privacy.score_arm(attack, data, stopped)
    assert partial["attribution"]["per_writer"]["w4"] == {"successes": 4, "items": 4}
    assert partial["linkage"]["per_writer"]["w4"] == {"successes": 4, "pairs": 4}
    assert partial["stopped"]["evaluation"] == 4
    assert whole["attribution"]["per_writer"].keys() == partial["attribution"]["per_writer"].keys()


def test_the_attack_is_the_same_for_every_arm_and_privacy_never_passes_without_attack_two():
    data = json.loads(DEV_PRIVACY.read_text())
    originals = privacy.arm_texts(None, data)
    lowered = {k: v.lower() for k, v in originals.items()}
    result = privacy.evaluate(data, {"originals": originals, "lead": lowered}, "originals", "lead")
    assert set(result["arms"]) == {"originals", "lead"}
    assert set(result["comparisons"]) == {"attribution", "linkage"}
    assert result["candidate_passes_privacy"] is False


# Which arms a comparison accepts.


def test_a_holdout_compares_only_the_reference_with_a_candidate():
    holdout = {"kind": "holdout"}
    with pytest.raises(SystemExit):
        stage4.check_arms(holdout, ("originals", None), ("lead", {}))
    with pytest.raises(SystemExit):
        stage4.check_arms(holdout, ("reference", {}), ("standin", {}))
    with pytest.raises(SystemExit):
        stage4.read_record("originals", holdout, DEV_FIDELITY)
    for candidate in stage4.stage3.GATE_MODELS:
        stage4.check_arms(holdout, ("reference", {}), (candidate, {}))
    stage4.check_arms({"kind": "development"}, ("originals", None), ("standin", {}))


def test_a_holdout_is_never_rewritten_by_a_stand_in(tmp_path, pins):
    path = as_holdout(tmp_path, DEV_FIDELITY)
    holdouts.pin(path, "EVAL02")
    with pytest.raises(SystemExit, match="not a candidate"):
        stage4.prepared("standin", "EVAL02", path)
