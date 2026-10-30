# Pinned models and their provenance (spec A24)

Every file of the reference model, both candidates and the vendor checkpoints
they were converted from is pinned by revision, size and sha256 in
[models.json](models.json). `uv run scripts/pin_models.py` rewrites that file
from the hub without downloading weights; a revision cannot change, so a run
that changes it means the hub served different bytes. Recorded 30 October 2026.

| Name | Repository @ revision | Weights | Licence | Made from |
| --- | --- | --- | --- | --- |
| reference | `Qwen/Qwen3.8-Flash-Next` @ `de4b8e4d` | 131 files, 360.0 GB, full precision | `qwen-community-1.0` (not Apache) | vendor |
| lead | `mlx-community/Qwen3.8-27B-4bit` @ `10c35caa` | 3 files, 16.05 GB, 4-bit affine, group 64 | apache-2.0 | `Qwen/Qwen3.8-27B` with mlx-vlm 0.6.8; vendor revision not stated |
| lead-base | `Qwen/Qwen3.8-27B` @ `1d4bf0f2` | 18 files, 55.6 GB | apache-2.0 | vendor; weights and tokenizer unchanged since upload on 13 Aug |
| challenger | `mlx-community/gemma-4-26b-a4b-it-4bit` @ `0d77464e` | 3 files, 15.34 GB, 4-bit affine, group 64, router layers 8-bit | apache-2.0 (Gemma 4 licence link) | `google/gemma-4-26B-A4B-it` @ `20da991a` (3 June) with a source build of mlx-vlm |
| challenger-base | `google/gemma-4-26B-A4B-it` @ `4d7ae498` | 2 files, 51.6 GB | apache-2.0 | vendor; weights unchanged since `20da991a` |

None is gated. Weight sizes are the files alone; the memory a running worker
needs is measured in stage 3 (spec HW02, EVAL07), not inferred from these.

## Findings

**The lead conversion splits words differently from Qwen's own tokenizer.**
Its `tokenizer.json` was re-saved during conversion. The word-splitting rule in
Qwen's file treats combining marks as part of a word (`[\p{L}\p{M}]+`); the
conversion's rule does not (`\p{L}+`). The vocabulary and merges are the same.
Text with combining marks, such as decomposed accents and most Indic and Thai
scripts, therefore reaches the model as different tokens from the ones it was
trained on. The chat template and generation settings match Qwen's.

**The challenger conversion carries Google's chat template from before a fix.**
It was converted from Google's 3 June revision. On 15 July Google fixed the
chat template ("null handling, reasoning preservation, turn-tag balance") and
on 20 July added a `response_template` to `tokenizer_config.json`. The weights
and `tokenizer.json` are unchanged by those commits, so the conversion's
weights still correspond to Google's current weights.

Both findings were decision 1 in [docs/plan.md](../docs/plan.md). Sean
decided on 30 October that each candidate uses its conversion's weights with
the vendor's own tokenizer and chat template files at the pinned vendor
revision.

## Configuration still to freeze per candidate

Each item becomes part of the candidate before the final holdout opens (spec
EVAL03) and cannot change afterwards without fresh evidence.

| Item | Lead | Challenger |
| --- | --- | --- |
| Weights | the 3 pinned files | the 3 pinned files |
| Tokenizer and chat template | the vendor's files from `lead-base` (decision 1) | the vendor's files from `challenger-base` (decision 1) |
| Thinking | off (spec DATA02 proposes non-thinking). The daemon request sets no thinking field and Qwen's template defaults to thinking on, so the worker sets it off as fixed configuration, not per request | to be read from the frozen template |
| Sampling | greedy, from the daemon's `temperature: 0` | greedy |
| Loader | one pinned MLX loader (spec MAC02); both conversions were made with mlx-vlm | same loader |

## Reference unknowns

The author ran `qwen3.8-flash-next` at `localhost:8012`, but the inference
server, quantization, thinking setting and any server-side sampling defaults
are unpublished. Qwen's `generation_config.json` for Flash-Next samples
(`temperature 1.0, top_k 20, top_p 0.95`); the daemon's `temperature: 0`
overrides the temperature on servers that honour it. Spec DATA02 says the
primary comparison uses the reference's actual settings, so these stay
**unknown** in [baseline.md](baseline.md) until reconstructed and recorded.
Full-precision weights are 360 GB, so the reference runs only on rented or
borrowed high-memory hardware, with approved synthetic fixtures only (spec
section 11).
