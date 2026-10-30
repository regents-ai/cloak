# Evaluation protocol (draft)

Draft of the preregistration spec section 11 requires. It becomes binding
when it is committed with the word **Frozen** in place of **Draft** below,
before any final holdout is opened. After that, a change motivated by results
needs a fresh confirmatory design (spec EVAL03, EVAL04).

**Status: Draft, 30 October 2026.** Open items are marked *open*.

## What is compared

Three artifacts, each an exact pinned configuration from
[models.json](../reference/models.json) with its frozen settings from
[models.md](../reference/models.md):

| Arm | Artifact | Runs on |
| --- | --- | --- |
| R | the reference, `Qwen/Qwen3.8-Flash-Next`, at the reference's actual settings | high-memory reference hardware; synthetic fixtures only if rented |
| L | the lead, the Qwen3.8-27B 4-bit MLX conversion | each specified Mac |
| C | the challenger, the Gemma 4 26B-A4B 4-bit MLX conversion | each specified Mac |

Every call goes through the daemon's real request and reply checks
([rewriter-contract.md](../reference/rewriter-contract.md)): same instruction
bytes, `temperature 0`, `max_tokens 16384`, one call at a time. Each record
keeps the input, raw reply, parsed texts or the failure, elapsed time, and the
artifact and configuration hashes.

## Datasets

| ID | Purpose | Source | Who sees model outputs before freezing |
| --- | --- | --- | --- |
| EVAL01 | Fast development screen | the daemon's 16 synthetic cases, plus added development cases | anyone; never a holdout |
| EVAL02 | Fidelity holdout | new inputs written for this, annotated before any model runs on them | nobody until frozen |
| EVAL03 | Privacy holdout | permitted authored text from several writers, topics and sessions | nobody until frozen |

EVAL02 annotation, per input, before outputs exist: the required meaning as a
list of relations (quantity and unit, inequality and whether it is inclusive,
negation, uncertainty, condition and its order, exclusions, exact-output rules)
and every protected span (code, quotations, names, identifiers, URLs, paths,
written numbers). Coverage: each category in spec EVAL02, several languages,
and long inputs up to the 128 KiB limit.

EVAL03 split: originals are assigned to partitions by writer and session
before any rewrite is made, so every version of one original stays together.
Attack training and tuning use one partition; evaluation uses another.

## Outcomes per item

Fidelity (EVAL02), per item and arm: **pass**, **critical error** (a protected
span changed, or a required relation lost or reversed), **minor error**, or
**stopped** (the daemon rejected the reply, or the call timed out). Ambiguous
meaning differences go to blinded human review: reviewers see the original and
one output at a time, without the arm.

Pairs are tabulated as candidate-only failure, reference-only failure, both
fail, both pass. A stopped item counts as a failure for usefulness and is
reported separately (spec DATA09); it never leaves the denominator.

Privacy (EVAL03), per arm: known-author attribution accuracy, cross-session
same-author linkage, and identifying content kept compared with the reference.
At least two developed attacks with comparable budgets *(open: which)*, each
reported at a predeclared low false-positive rate *(open: the rate)*.

## Primary harm metrics and the parity rule

For each required comparison, harm difference is candidate harm minus
reference harm, paired by item. Required comparisons, for each candidate
against R:

1. Fidelity: critical-error rate on EVAL02.
2. Attribution: attack success on EVAL03 at the declared false-positive rate.
3. Linkage: same-author linkage success on EVAL03 at the declared rate.

A candidate passes a comparison only when the one-sided upper confidence bound
of its harm difference is at most zero. No positive margin. "No significant
difference" is not a pass. Separately, any confirmed critical
candidate-specific disclosure or fidelity error blocks the candidate.

Statistics:

- Sampling unit: the writer for EVAL03 and the original input for EVAL02;
  intervals account for several items from one writer or session (cluster
  bootstrap or a cluster-robust exact method) *(open: which)*.
- The interval method must stay valid with few or zero paired errors; a naive
  bootstrap that returns zero width on all-zero data is not acceptable.
  *(open: the method, for example an exact paired binomial bound.)*
- Confidence level *(open; proposed 95 % one-sided)*. Two candidates against
  the reference on three comparisons: multiplicity handled by Bonferroni
  across the two candidates *(open)*.
- Sample size fixed in advance from a power calculation on development data
  *(open)*; no adding data until a bound turns favourable.
- Repeated runs: each arm run at least three times on a development subset to
  measure run-to-run variation before the holdout *(open: the count)*.

## Selection rule

1. Only candidates passing every required comparison and every protection gate
   are eligible.
2. If both are eligible, choose by measured full-request responsiveness
   (EVAL06), then memory behaviour (EVAL07), then reliability (stopped rate).
3. If neither is eligible, no substitution ships (spec section 12).

## Feasibility and performance (stage 3)

Measured through the real daemon, guest adapter and worker, with the Linux
appliance and a declared ordinary Mac load running, on each specified Mac:

| ID | Measure | Target or rule |
| --- | --- | --- |
| EVAL05 | cold load, warm calls, history rebuild after cache loss, long outputs, cancellation, memory pressure, sleep and wake, restart | every rejected, malformed and timed-out call stays in the denominator; no truncation or lowered limits |
| EVAL06 | warm full rewrite latency on a fixed set of ordinary messages up to 512 input tokens | p50 at most 5 s and p95 at most 15 s; cold-load and longer buckets reported separately |
| EVAL07 | memory and pressure, swap growth, installed size, CPU and GPU use, battery, end-to-end latency | 32 GB viability judged from the whole running product, never from model allocations alone |

The 90-second daemon limit stays a safety ceiling, not a target. A candidate
that times out where the reference completes is not equivalent.
