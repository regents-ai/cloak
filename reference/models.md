# Pinned models and their provenance (spec A24)

Every file of the reference model, the four candidates and the vendor
checkpoints they were converted from is pinned by revision, size and sha256 in
[models.json](models.json). `uv run scripts/pin_models.py` rewrites that file
from the hub without downloading weights; a revision cannot change, so a run
that changes it means the hub served different bytes. Recorded 30 October
2026; the small lead and small challenger (decision 7 in
[docs/plan.md](../docs/plan.md)) and their vendor checkpoints on 13 November
2026.

| Name | Repository @ revision | Weights | Licence | Made from |
| --- | --- | --- | --- | --- |
| reference | `Qwen/Qwen3.8-Flash-Next` @ `de4b8e4d` | 131 files, 360.0 GB, full precision | `qwen-community-1.0` (not Apache) | vendor |
| lead | `mlx-community/Qwen3.8-27B-4bit` @ `10c35caa` | 3 files, 16.05 GB, 4-bit affine, group 64 | apache-2.0 | `Qwen/Qwen3.8-27B` with mlx-vlm 0.6.8; vendor revision not stated |
| lead-base | `Qwen/Qwen3.8-27B` @ `1d4bf0f2` | 18 files, 55.6 GB | apache-2.0 | vendor; weights and tokenizer unchanged since upload on 13 Aug |
| challenger | `mlx-community/gemma-4-26b-a4b-it-4bit` @ `0d77464e` | 3 files, 15.34 GB, 4-bit affine, group 64, router layers 8-bit | apache-2.0 (Gemma 4 licence link) | `google/gemma-4-26B-A4B-it` @ `20da991a` (3 June) with a source build of mlx-vlm |
| challenger-base | `google/gemma-4-26B-A4B-it` @ `4d7ae498` | 2 files, 51.6 GB | apache-2.0 | vendor; weights unchanged since `20da991a` |
| small-lead | `mlx-community/Qwen3.5-9B-4bit` @ `8b2b98c0` | 2 files, 5.95 GB, 4-bit affine, group 64 | apache-2.0 | `Qwen/Qwen3.5-9B` with mlx-vlm 0.3.12; vendor revision not stated |
| small-lead-base | `Qwen/Qwen3.5-9B` @ `c2022362` | 4 files, 19.31 GB | apache-2.0 | vendor; weights and tokenizer unchanged since upload on 27 Feb |
| small-challenger | `mlx-community/gemma-4-12B-it-4bit` @ `73bcf090` | 2 files, 6.74 GB, 4-bit affine, group 64 | none stated (the weights are Google's, apache-2.0) | `google/gemma-4-12B-it` @ `5926caa4` (4 June), found by its configuration; the card names no source or tool |
| small-challenger-base | `google/gemma-4-12B-it` @ `43c9d014` | 1 file, 23.92 GB | apache-2.0 (Gemma 4 licence link) | vendor; weights unchanged since upload on 3 June |

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
revision. The small pair (decision 7) follow the same rule.

**The small lead conversion re-saved its tokenizer files, but splits words as
Qwen's does.** Its card says it was converted from `Qwen/Qwen3.5-9B` with
mlx-vlm 0.3.12; its card metadata names `Qwen/Qwen3.5-9B-Base`, copied from
Qwen's own card. Its `config.json` is Qwen's but for the quantization fields,
and its chat template is Qwen's as uploaded on 1 March (`ef3d031a`), the day
before the conversion. Its `tokenizer.json` was re-saved: the vocabulary,
merges, word-splitting rule and normalizer are Qwen's, so the lead's finding
does not recur, but it adds seven special tokens (ids 248070 to 248076, audio
and speech markers) that Qwen lists only in `tokenizer_config.json`. Its
`tokenizer_config.json` was rewritten by a newer transformers, without Qwen's
added tokens, special tokens or chat template, and it has no `merges.txt`.

**The small challenger conversion names no source and carries Google's
tokenizer from before a fix.** Its card states no source model, tool or
licence. Its `config.json` is Google's from 4 June (`5926caa4`) onward, plus
the quantization fields and the end-of-turn ids Google's
`generation_config.json` also lists; the conversion's last update was 8 June,
so it was made from `5926caa4`. As with the challenger, its chat template is
Google's from before the 15 July fix and its `tokenizer_config.json` lacks the
20 July `response_template`. Its `tokenizer.json` is Google's as it stood
until 30 October, when Google removed 239 merges so that 210 glitch tokens
can no longer be produced (`43c9d014`, "Remediate 210 glitch tokens"); the
vocabulary and ids are unchanged, and Google's weights are unchanged since
upload on 3 June.

In [models.json](models.json) each candidate lists those files under
`vendor_files`, and its file list takes them from the vendor entry (each
marked `from`) in place of the conversion's: for the lead and the small lead
`chat_template.jinja`, `merges.txt`, `tokenizer.json`, `tokenizer_config.json`
and `vocab.json` from `lead-base` and `small-lead-base`; for the challenger
and the small challenger `chat_template.jinja`, `tokenizer.json` and
`tokenizer_config.json` from `challenger-base` and `small-challenger-base`.
`scripts/fetch_model.py` downloads each file from where it is pinned, and the
worker checks the combined list like any other. That the combination loads
and rewrites is first shown when a candidate is downloaded in stage 3.

## Configuration still to freeze per candidate

Each item becomes part of the candidate before the final holdout opens (spec
EVAL03) and cannot change afterwards without fresh evidence.

| Item | Lead | Challenger | Small lead | Small challenger |
| --- | --- | --- | --- | --- |
| Weights | the 3 pinned files | the 3 pinned files | the 2 pinned files | the 2 pinned files |
| Tokenizer and chat template | the vendor's files from `lead-base` (decision 1), pinned | the vendor's files from `challenger-base` (decision 1), pinned | the vendor's files from `small-lead-base`, pinned | the vendor's files from `small-challenger-base`, pinned |
| Thinking | off, pinned as `enable_thinking: false` (spec DATA02 proposes non-thinking). The daemon request sets no thinking field and Qwen's template defaults to thinking on, so the worker sets it off as fixed configuration, not per request | off, pinned as `enable_thinking: false`. Google's template (pinned, `ae53464b`) already defaults to off; pinning it keeps the setting explicit | off, pinned as `enable_thinking: false`; Qwen's template defaults to thinking on, as for the lead | off, pinned as `enable_thinking: false`; Google's template defaults to off, as for the challenger |
| Sampling | greedy, from the daemon's `temperature: 0` | greedy | greedy | greedy |
| Loader | one pinned MLX loader (spec MAC02); both conversions were made with mlx-vlm | same loader | same loader; it has the model type `qwen3_5` | same loader; it has the model type `gemma4_unified` |

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
