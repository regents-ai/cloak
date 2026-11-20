# Local answer models for Cloak: medium and large proposal

Research worker report, 20 Nov 2026. I wrote this when the chief said to stop, but every number below comes from runs that had already finished. Each section is marked **done**, **partial** or **not started**. The "Remaining work" list at the end is everything another worker needs to finish the job from this file alone.

Scratch evidence is in `/tmp/cloak-build/models-research/`. Nothing in the repository was changed. No model weights were downloaded. No Hugging Face token was used. All whichllm runs were inside Docker, and no research container is still running (checked with `docker ps` at the time of writing).

## Proposal at a glance

| Role | Tiers | Proposed | Runner-up |
|---|---|---|---|
| Small (today) | 16 GB and up | unsloth/Qwen3.5-9B-GGUF `Qwen3.5-9B-Q4_K_M.gguf` (kept) | n/a |
| 24 GB | 24 GB | small model only; no medium fits about 10 GiB at 15 tok/s or more | gemma-4-12b-it IQ4_XS (13.1 tok/s on M2, below the bar) |
| Medium | 32 GB and up | unsloth/gemma-4-26B-A4B-it-GGUF `UD-Q3_K_M` | unsloth/Qwen3.6-35B-A3B-GGUF `UD-Q3_K_M` |
| Large | 48 and 64 GB | unsloth/Qwen3.6-35B-A3B-GGUF `UD-Q5_K_M` | bartowski/Qwen3.8-27B-GGUF `Q3_K_M` |
| Watch | 32 GB and up | Inkling 2 Mini: **Cloak's pinned llama.cpp cannot load it**, and no released llama.cpp can yet | n/a |

---

## 1. Skills, tools and exact commands (done)

- Skills loaded: none were needed. This was research only, with no code change and no CLI built. I read `AGENTS.md`, the brief and the worker rules.
- whichllm **0.6.9** from PyPI, installed with uv **0.13.9** in `python:3.13-slim`.
  - Image digest: `sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90` (Python 3.13.18).
  - httpx 0.28.1, typer 0.29.2.
  - whichllm repo main head when read: `b29fa42c8250d52fd949b9ca9336db9b1124cc3b`.
- whichllm model index: built 2026-11-20T11:44:21Z, sha256 `1893c1df9856680c481fc037528dffedc6c97cbc99721ffb360c7b1dd8e57cd4`. Every run used this same index.
- Hugging Face: anonymous model API and tree API only, for lfs sha256 and sizes (scripts `/tmp/cloak-build/models-research/hf_info.py` and `/tmp/cloak-build/models-research/hf_tree.py`). The JSON is in `/tmp/cloak-build/models-research/hf/`. Config and template files were read as text.
- GitHub: `gh api` reads of llama.cpp (tags, PRs #32187, #32657, #32694, #32695, master Metal file) and the Unsloth llama.cpp fork release.
- Python only through `uv run --no-project python -I`.

### Container sandbox (identical for all four containers)

```
export DOCKER_CONFIG=/tmp/cloak-build/models-research/docker-config   # contains only {}
docker run --rm -i --name whichllm-research[-plan|-quant|-calib] \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --memory 3g \
  -v /tmp/cloak-build/models-research/out[-plan|-quant|-calib]:/out \
  python@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 \
  sh -s < /tmp/cloak-build/models-research/container[-plan|-quant|-calib].sh
```

- Inside the container: `pip install uv==0.13.9 && uv tool install whichllm==0.6.9`. No other folder of the Mac was mounted.
- I ran `uptime` before each container; the load was always under 40.
- whichllm `run`, `bench` and `report` were never used.

### whichllm commands

All rankings use: `--context-length 8192 --profile general --top 40 --json`. Apple Macs are simulated with `--gpu "Apple <chip>" --vram <GB>`. The full list is in `/tmp/cloak-build/models-research/out/commands.txt` (51 runs, every `.err` empty).

- **Hardware per tier:** 16 GB M1 and M4; 24 GB M2 and M4 Pro; 32 GB M4 and M2 Pro; 48 GB M4 Pro and M3 Max; 64 GB M4 Pro and M2 Max.
- **Views:**
  - `a-` plain
  - `q4-` adds `--quant Q4_K_M`
  - `b-` uses the brief's budget: `--vram-headroom 6 / 4.3333 / 6 / 4 --fit full-gpu` for 24 / 32 / 48 / 64 GB
  - `m-` uses the Metal-working-set budget (see section 6): `--vram-headroom 7.8 / 8.0667 / 8.8 / 9 --fit full-gpu`
  - `b15-` and `m15-` are the same budgets plus `--min-speed 15`
- **`/tmp/cloak-build/models-research/out-quant/`:**
  - `--quant Q3_K_M` on 32 GB M4, 48 GB M4 Pro and 64 GB M4 Pro
  - `--quant Q5_K_M` on 48 GB M4 Pro and 64 GB M4 Pro
- **`/tmp/cloak-build/models-research/out-calib/`:** `--gpu "Apple M4 Max" --vram 48 --quant Q4_K_M`
- **`/tmp/cloak-build/models-research/out-plan/`:**
  - `whichllm plan thinkingmachines/Inkling-2-Mini --context-length 8192 --quant Q4_K_M|Q3_K_M|Q8_0 --json`, plus a table version
  - `whichllm plan Qwen/Qwen3.6-35B-A3B --context-length 8192 --quant Q4_K_M --json`
- **Summaries:** `/tmp/cloak-build/models-research/summaries-all.txt`, built by `/tmp/cloak-build/models-research/summarize.py`.

### How whichllm estimates speed (read from its source, checked against its own output)

- **MoE:** tok/s = bandwidth × quant_eff × 0.82 / (file_bytes × max(active/total, floor)), where floor = 0.05 × max(1, bw/256), capped at 0.25. It reproduces whichllm's own Qwen3.6 UD-Q4_K_M rows exactly: 66.66 tok/s on M4 Pro and 35.52 on M4.
- **Dense GGUF:** seconds per token = size / (bw × 0.96 × 0.90) + 0.0024.
- **Confidence bands:**
  - high: 0.75–1.30×
  - medium: 0.60–1.60×
  - low: 0.35–2.00× (applies to every MoE on Apple)
- **Bandwidths used (GB/s):** M1 68.25, M2/M3 100, M4 120, M2 Pro 200, M4 Pro 273, M3/M2 Max 400, M4 Max 546.
- **Weakest chip per tier:**
  - 24 GB: M2/M3 (100)
  - 32 GB: M4 (120)
  - 48 GB: M4 Pro (273)
  - 64 GB: M4 Pro (273)

## 2. Tier table (done)

Memory is whichllm's estimate at 8k context, in GiB. Speed is tok/s on the weakest Mac of the tier, with the confidence band. Score is whichllm's general score.

| Tier | Budget (brief / Metal) | Proposed | File | Mem@8k | tok/s weakest | Score | Runner-up | File | Mem@8k | tok/s weakest | Score |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 16 GB | none | small only | | | | | | | | | |
| 24 GB | 10 / 8.2 | small only (Qwen3.5-9B Q4_K_M) | 5.29 GiB | 6.45 | 14.7 M2 [h 11.0–19.1] | 60.1 | gemma-4-12b-it IQ4_XS | 5.94 GiB | 7.11 | 13.1 M2 [h] | 65.9 |
| 32 GB | 17 / 13.27 | gemma-4-26B-A4B-it UD-Q3_K_M | 11.85 GiB | 13.07 | 26.2 M4 [l 9.2–52.5] | 71.3 | Qwen3.6-35B-A3B UD-Q3_K_M | 15.46 GiB | 16.82 | 35.5 M4 [l 12.4–71.0] | 74.0 |
| 48 GB | 30 / 27.2 | Qwen3.6-35B-A3B UD-Q5_K_M | 24.64 GiB | 26.00 | 52.7 M4 Pro [l 18.5–105.5] | 77.5 | Qwen3.8-27B Q3_K_M | 12.48 GiB | 14.45 | 16.9 M4 Pro [h 12.7–21.9] | 83.1 |
| 64 GB | 44 / 39 | Qwen3.6-35B-A3B UD-Q5_K_M (same file) | 24.64 GiB | 26.00 | 52.7 M4 Pro [l 18.5–105.5] | 77.5 | Qwen3.8-27B Q3_K_M (same file) | 12.48 GiB | 14.45 | 16.9 M4 Pro [h 12.7–21.9] | 83.1 |

Speeds on the stronger Mac of each tier:
- **Medium gemma:** 43.7 on M2 Pro (32 GB); 59.7 on M4 Pro.
- **Medium runner-up Qwen3.6 Q3:** 59.2 on M2 Pro; 80.8 on M4 Pro.
- **Large Qwen3.6 Q5:** 77.3 on 48 GB M3 Max.
- **Qwen3.8 Q3:** 12.5 on M2 Pro (32 GB).

**Why these picks:**
- **Medium:** the gemma is the only good-scoring model that fits under *both* budget readings at 32 GB with 15 tok/s or more. It is whichllm's #1 under the Metal reading on the 32 GB M4. Its chat template has a thinking switch that today's worker already turns off. As a mixture-of-experts model, it re-reads the conversation quickly, which matters because Cloak's worker reads the whole conversation again on every turn.
- **Medium runner-up:** whichllm's #1 under the brief's 17 GiB at 15 tok/s or more. It has almost no room to spare and is over the Metal reading.
- **Large:** it fits both readings at 48 GB. Even its low-end speed (18.5) clears 15. It uses the same template family as today's small model.
- **Large runner-up:** whichllm's top score with 15 tok/s or more at 48 and 64 GB. It is borderline on speed and dense, so it re-reads the conversation slowly. Because it is only 14.45 GiB, it would also "fit" 32 GB Macs, where it runs at 7.6 tok/s, so the app would have to tie it to 48 GB and up.

## 3. Model details (done)

Every file below is a single GGUF and is not gated. Each HF repo has a chat template (see section 6 for the per-file caveat). Sizes are bytes. The sha256 is the HF lfs value.

### 3.1 Small (kept): Qwen3.5-9B Q4_K_M

- **Repo:** `unsloth/Qwen3.5-9B-GGUF` @ `3885219b6810b007914f3a7950a8d1b469d598a5`
- **File:** `Qwen3.5-9B-Q4_K_M.gguf`
  - 5680522464 bytes
  - sha256 `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8`
- **Licence (HF):** `apache-2.0`
- **Base:** `Qwen/Qwen3.5-9B` @ `c202236235762e1c871ad0ccb60c8ee5ba337b9a`. 9,653,104,368 params, dense, arch `qwen35`, context 262144.
- **Quant:** Q4_K_M
- **whichllm:**
  - 16 GB M1: #3, 10.1 tok/s [h 7.6–13.2], score 59.0, mem 6.45 GiB
  - 16 GB M4: 17.5 [h 13.1–22.7]
  - 24 GB M2 (q4 view): #4, 14.7 [h 11.0–19.1], 60.1
  - Plain view on 16 GB picks Q5_K_M (M1 #3, 59.7) or Q6_K (M4 #3, 61.4)
  - Below 15 tok/s on M1 and M2/M3 by whichllm's estimate
- **Memory at Cloak's 19,456-token cap:** about 6.79 GiB

### 3.2 Medium, proposed: gemma-4-26B-A4B-it UD-Q3_K_M

- **Repo:** `unsloth/gemma-4-26B-A4B-it-GGUF` @ `c099eb48e663fd284577b04978a94ffccb261841`
- **File:** `gemma-4-26B-A4B-it-UD-Q3_K_M.gguf`
  - 12728497888 bytes
  - sha256 `811882f6df81c8ea204a5d382f196d6bd601245091786912d4c70df41cdfa052`
- **Licence (HF):**
  - `license_link` = `https://ai.google.dev/gemma/docs/gemma_4_license`, which redirects to `gemma.ai/resources/apache-2/` (Apache 2.0 text)
  - **Flag:** Google also publishes separate "Prohibited use" pages. I did not establish whether they apply to Gemma 4.
- **Base:** `google/gemma-4-26B-A4B-it` @ `4d7ae4984b7db7de8f8457170b3f1a419ee76d52`. 25,805,936,206 params, 3.8B active, 30 layers, 128 experts, arch `gemma4`, context 262144.
- **Quant:** Unsloth dynamic Q3_K_M
- **Thinking:** the template honours `enable_thinking`, so today's worker setting (False) works.
- **whichllm:**
  - 24 GB M2: plain-view #1, 21.9 [l 7.7–43.7], score 70.6 (over the brief's 10 GiB)
  - 24 GB M4 Pro: 59.7, 72.5
  - 32 GB M4: #1 under the Metal budget, 26.2 [l 9.2–52.5], 71.3; #3 in the Q3 view
  - 32 GB M2 Pro: 43.7, 72.5
  - 48 and 64 GB M4 Pro (Q3 view): #3, 59.7 [l 20.9–119.4], 72.5
- **Memory:** 13.07 GiB at 8k; about 13.29 GiB at Cloak's cap. That is 0.02 over the Metal reading of 13.27 and well under the brief's 17.
- **Other files in the same repo (same revision):**

| File | Bytes | sha256 |
|---|---|---|
| UD-Q4_K_M | 16947541728 | `f2c28b3dc4776931ac6f879e11f203dec637ea0f14267a86ec8f6165f63f293f` |
| UD-Q5_K_M | 21150365408 | `769d386a…0e80` (full value in `/tmp/cloak-build/models-research/hf/`) |
| UD-Q6_K | 23172478688 | `76bf3eee…85f0` |
| Q8_0 | 26859861728 | `5f7cbd0f…152c` |

### 3.3 Medium runner-up: Qwen3.6-35B-A3B UD-Q3_K_M

- **Repo:** `unsloth/Qwen3.6-35B-A3B-GGUF` @ `a483e9e6cbd595906af30beda3187c2663a1118c`
- **File:** `Qwen3.6-35B-A3B-UD-Q3_K_M.gguf`
  - 16600710112 bytes
  - sha256 `1b715841683f960bd9a49f008181bd910ee169b78d4cf465b6fde7f4d929ff99`
- **Licence (HF):** `apache-2.0` (the base repo's LICENSE file is Apache text)
- **Base:** `Qwen/Qwen3.6-35B-A3B` @ `345d467b117d1fd5eda9b879a5988de9ae5f47a7`. 35,951,822,704 params, 3.0B active, 40 layers, 256 experts with 8 active, arch `qwen35moe`, context 262144.
- **Quant:** Unsloth dynamic Q3_K_M
- **Thinking:** the template honours `enable_thinking`.
- **whichllm:**
  - 32 GB M4: 35.5 [l 12.4–71.0], score 74.0; #1 under the brief's 17 GiB with 15 tok/s or more
  - 32 GB M2 Pro: 59.2, 74.2
  - 48 and 64 GB M4 Pro: 80.8 [l 28.3–161.6], 74.2
- **Memory:** 16.82 GiB at 8k; about 17.04 GiB at Cloak's cap. That is 0.04 over the brief's 17 and well over the Metal reading of 13.27.

### 3.4 Large, proposed: Qwen3.6-35B-A3B UD-Q5_K_M

- **Repo:** same as 3.3, `unsloth/Qwen3.6-35B-A3B-GGUF` @ `a483e9e6cbd595906af30beda3187c2663a1118c`
- **File:** `Qwen3.6-35B-A3B-UD-Q5_K_M.gguf`
  - 26456194016 bytes
  - sha256 `c13ce26253ea334df472bd8fbd2d6da66d8a41195c17f6fcbf44c4d20ece0932`
- **Licence, base, params, arch, context:** as in 3.3
- **Quant:** Unsloth dynamic Q5_K_M
- **whichllm:**
  - 48 and 64 GB M4 Pro: 52.7 [l 18.5–105.5], score 77.5
  - 48 GB M3 Max: 77.3, 77.5
- **Memory:** 26.00 GiB at 8k; about 26.22 GiB at Cloak's cap. That fits both readings at 48 GB (30 / 27.2) and 64 GB.
- **Other files in the same repo:**

| File | Bytes | sha256 |
|---|---|---|
| UD-Q4_K_M | 22134528992 | `ac0e2c11…1a61` |
| UD-Q6_K | 29308320736 | `4fe53b14…f043` |
| Q8_0 | 36903140320 | `d1a39580…4a59` |

### 3.5 Large runner-up: Qwen3.8-27B Q3_K_M

- **Repo:** `bartowski/Qwen3.8-27B-GGUF` @ `87410e7b9a5c21e6ca70c0c9cc5237de909fe621`
- **File:** `Qwen_Qwen3.8-27B-Q3_K_M.gguf`
  - 13404051168 bytes
  - sha256 `14865aaef0b6c26a013538782d366443c7298b11d5df9f0fb829d34d1963f869`
  - **Remaining:** confirm the exact file name from `/tmp/cloak-build/models-research/hf/` tree JSON before pinning.
- **Licence (HF):**
  - `apache-2.0` tag; `license_link` none
  - **Flag:** confirm the base repo's LICENSE text.
- **Base:** `Qwen/Qwen3.8-27B` @ `37561816e66b5b9153b1b64c10968c18c1e6f4a0`. 27,781,427,952 params, dense, 64 layers, arch `qwen35`, context 262144.
- **Quant:** Q3_K_M
- **whichllm:**
  - 48 and 64 GB M4 Pro: #1 by score among models at 15 tok/s or more, 16.9 [h 12.7–21.9], score 83.1
  - 24 GB M2: 6.3, 68.5
  - 24 GB M4 Pro: 16.9, 83.1
  - 32 GB M4: 7.6 [h 5.7–9.9], 75.7
  - 32 GB M2 Pro: 12.5, 82.2
- **Memory:** 14.45 GiB at 8k; about 15.14 GiB at Cloak's cap.
- **Other files:**

| Repo | File | Bytes | sha256 |
|---|---|---|---|
| bartowski | Q4_K_M | 17442399968 | `880a52af…c673` |
| bartowski | Q5_K_M | 20923877088 | `9f0a899d…130f` |
| bartowski | Q6_K | 23860565728 | `539041d2…d33d` |
| bartowski | Q8_0 | 29116388960 | `a830e736…362d` |
| `ggml-org/Qwen3.8-27B-GGUF` @ `c1869413dece09109e55b7dcc2c77ef382b0d0bd` | Q4_K_M | 19403684480 | `d15d4b6d…48ee` |
| ggml-org (same revision) | Q8_0 | 28595763840 | `6bc9e722…c35a` |

### 3.6 Noted, not proposed

- **gpt-oss-20b**
  - Pins:
    - `unsloth/gpt-oss-20b-GGUF` @ `d449b42d93e1c2c7bda5312f5c25c8fb91dfa9b4`: Q8_0 12109567168 bytes, `bcd455d4034ec02f71a875b46cb17df44a97911d7258291973be4d21f98329f3`
    - `ggml-org/gpt-oss-20b-GGUF` @ `41e8a94d15d62070b36cf4553a0250717ecf46b8`: MXFP4 12109566624 bytes, `27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901`
    - Base `openai/gpt-oss-20b` @ `6cee5e81ee83917806bbde320786a8fb61efebee`: 20.9B params, 3.6B active, licence `apache-2.0`
  - whichllm: 21.2 tok/s on 32 GB M4 [l], score 68.0, mem 12.29.
  - Why not: its reasoning channel has no `enable_thinking` switch. With today's worker, the reasoning text would appear inside answers. It needs a worker change first.
- **K2-Horizon-MoVA-36B-A4B**
  - Pins: `IFM/K2-Horizon-MoVA-36B-A4B-GGUF` @ `00cce3151bdce384661cb33603853ccfe6209de9`
    - Q5_K_M 26439456096, `8f0d54bade503e800293885356ebd42334068a262176b3d32d7c06e7e0659707`
    - Q6_K 30765365856, `d37a53f1…8603`
  - whichllm: score 78.0, 41.2 tok/s [l 14.4–82.4], mem 27.10. See section 5.
- **gemma-4-12b-it**
  - Pins: `unsloth/gemma-4-12b-it-GGUF` @ `fc034cfff751157913579611efad8462ac1be606`
    - IQ4_XS 6375734080, `b0037d0e0de0290177045ca214b2a0fb1079d18bde57842b3ca32f5b0cd76774`
    - Q5_K_M 8413576000
    - Q3_K_S 5135014720
  - On the 24 GB M2:
    - IQ4_XS: 13.1 tok/s, score 65.9
    - Q3_K_S: 16.2 tok/s, score 62.5
    - Compare today's 9B: 60.1

## 4. llama.cpp pin and architecture evidence (done)

**The pin:** `reference/sources.json` pins llama.cpp tag `b12556`, commit `50518b64c6f2191a116d2760042f106c4b3387d7` (2026-11-19).

Evidence that each proposed architecture is in the pin (pinned `src/llama-arch.cpp`, `src/llama-model.cpp`, `src/models/`):

| Architecture | llama-arch.cpp | llama-model.cpp case | src/models file | Used by |
|---|---|---|---|---|
| `qwen35` | line 45 | QWEN35 361 | `qwen35.cpp` | Qwen3.5-9B, Qwen3.8-27B |
| `qwen35moe` | line 46 | QWEN35MOE 363 | `qwen35moe.cpp` | Qwen3.6-35B-A3B |
| `gemma4` | line 65 | GEMMA4 165 | `gemma4.cpp` | gemma-4-26B-A4B, gemma-4-12b |
| `gpt-oss` | line 138 | OPENAI_MOE 323 | `openai-moe.cpp` | gpt-oss-20b |
| `k2-horizon` | line 182 | K2_HORIZON 393 | `k2-horizon.cpp` | K2-Horizon |
| `inkling2` | line 186 | INKLING2 327 | `inkling2.cpp` | not Inkling 2 Mini's looped file; see Inkling section |

Worker facts that shaped the picks, read from `llama-worker/Sources/CLlama/cloak_llama.cpp` and `llama-worker/Sources/cloak-rewriter-llama/Worker.swift`:

- **Context:**
  - The cap is 19,456 tokens (4,096 for the answer plus 15,360 of conversation).
  - A fresh context is made for every answer, so the whole conversation is read again each turn.
- **Reasoning and template settings:**
  - `reasoning_format` is NONE, and special tokens are dropped from the output (`cloak_llama.cpp:150`, `:458`).
  - The template settings take booleans only (`:278`).
  - `reference/models.json` sets `enable_thinking` False.
- **Runtime:**
  - Everything runs on Metal (all layers on the Mac's graphics chip), and the weights are read fully into memory.
  - Flash attention is on, and the attention cache is f16.
- **NVFP4:** the pinned Metal backend leaves NVFP4 out of matrix multiply and get_rows (`ggml-metal-device.m:1532`, `:1992`). llama.cpp master `919794500475862f6768c353255469dc661cb734` (2026-11-20T19:54:57Z) leaves it out too.

## 5. whichllm's #1 per tier that I did not propose (done)

- **24 GB M2, plain view:** gemma-4-26B UD-Q3_K_M (score 70.6, 21.9 tok/s). Not proposed for 24 GB because it uses 13.07 GiB, over the brief's 10 GiB and the Metal 8.2.
  - #1 under the brief's budget: gemma-4-12b Q5_K_M, 10.0 tok/s.
  - #1 under the Metal budget: IQ4_XS, 13.1 tok/s.
  - Both are below 15.
  - With the 15 tok/s floor, #1 is gemma-4-12b Q3_K_S (16.2 tok/s, score 62.5). That is barely above today's 9B (60.1) and not worth a second pin.
- **24 GB M4 Pro:** Qwen3.8-27B Q3_K_M (83.1). Over budget.
- **32 GB M4:** Qwen3.8-27B Q3_K_M at 7.6 tok/s fails the speed bar.
- **32 GB M2 Pro:** ggml-org Qwen3.8-27B Q4_K_M at 8.7 tok/s fails the speed bar.
- **48 and 64 GB, plain view:** ggml-org Qwen3.8-27B Q8_0 (score 86.5–87.5). It runs 8.1 tok/s on M4 Pro and 11.7 on M3 Max and M2 Max, so it fails the bar.
  - 48 GB M4 Pro under the Metal budget: Qwen3.8-27B Q6_K (86.2, 9.7 tok/s). Fails the bar.
- **48 GB:** K2-Horizon Q5_K_M (78.0, mem 27.10). It sits 0.1 GiB under the Metal reading, its low-end speed is 14.4, and the model is newer and less known. Qwen3.6 Q5 is within 0.5 points.
- **64 GB:** K2 Q6_K or Qwen3.6 Q8_0 (78.3, 32.7 tok/s, mem 35.73). Only +0.8 over the large pick, so not worth a fourth pin.
- **gemma-4-26B-A4B-it-qat UD-Q4_K_XL** (mem 14.48): scores only 52.7–54.3 in whichllm. That looks like an index gap rather than a real quality drop. Unverified.

## 6. Unverified, unsure, surprises (done)

1. **Budgets.** macOS caps the graphics working set at about 2/3 of memory up to 32 GiB and 0.75 above. That gives 10.67 / 16 / 21.33 / 36 / 48 GiB on 16 / 24 / 32 / 48 / 64 GB Macs.
   - Taking off the 7 GiB rewording model leaves **8.2 / 13.27 / 27.2 / 39 GiB** for the 24 / 32 / 48 / 64 GB tiers.
   - That is lower than the brief's 10 / 17 / 30 / 44.
   - I could not verify whether this cap counts both worker processes together. If it does, the medium runner-up does not fit 32 GB. The medium proposal fits either way at 8k, and is 0.02 over at Cloak's full cap.
   - **Chief decides.**
2. **Cloak's chat cap is 19,456 tokens, not 8k.** The figures in section 3 add the extra attention cache. These are my computations from whichllm's shapes, not whichllm output.
3. **Today's small model is under 15 tok/s on M1 and M2/M3 Macs** by whichllm (10.1 and 14.7).
4. **Calibration.** whichllm's estimate for today's model on an M4 Max is about 69 tok/s. Cloak measured a median of 36.54 tok/s on an M4 Max 48 GB, with grammar-constrained short rewrites (`evidence/stage3/small-lead-gguf-grammar/feasibility-20261114T052945Z.json`).
   - So whichllm may read about 1.9× high for Cloak's use.
   - If that holds for the picks, the 32 GB medium would be about 14 tok/s and the large about 28 on the weakest Macs.
   - This is untested.
5. **Models released after my training cutoff.** Qwen3.6/3.8, gemma-4, K2-Horizon and Inkling are all after it. I relied only on the HF metadata, the configs and whichllm's index, not on my own knowledge.
6. **Templates per file.** The HF API returns one chat template per repo. I did not check each GGUF's header (that would need a weight download).
7. **Licence text.** Gemma's separate prohibited-use pages (point 3.2) and Qwen3.8's licence text are unconfirmed.
8. **Nobody measured these speeds on a Mac.** All speeds are whichllm estimates, with no third-party Apple measurements checked, except the Inkling search below.

---

## Inkling 2 Mini (done, except Q4 below is an estimate by design)

**Q1. GGUF repos.** Both are ungated and every file is a single GGUF. Neither repo is from the maker: Unsloth and ggml-org are well-known converters.

- **`unsloth/Inkling-2-Mini-GGUF`** @ `09451beb90e10d4d7a31742a213351433bcb771e`
  - Licence `apache-2.0`, arch `inkling2`, context 1048576, eos `<|content_model_end_sampling|>`
  - Also has dspark and mmproj files.

| File | Bytes | sha256 |
|---|---|---|
| UD-IQ1_S | 7764291776 | `c09c028b050c108624682baeb28ac6e0cdb936af021ac637c8c3609f923ea4b8` |
| UD-IQ1_M | 8024441024 | `544e0b2412ba2392272b0510b0c8f53a1ab872b73c2ba4f7488de0d5d61467d9` |
| UD-IQ2_XXS | 8486236352 | `4fe958f73a667d8082f911a4347e52bc34696a7816cf3d5b9f7c8a81d5c5ceaa` |
| UD-Q2_K_XL | 9138715328 | `20292e8142b69535ca88a5d04439d0fdeb4dc698d44c002dca706dcf92901441` |
| UD-IQ3_XXS | 11663309504 | `bd7ef0865adf119b5183e45e741c629bafa649769b33b5ebf689bb4bcc4690d6` |
| UD-Q3_K_XL | 13631778016 | `f72f396d1b479b14d76346df80baa449c8b1f399653bff38fa4764b359a40048` |
| UD-IQ4_XS | 15733755232 | `a861d21e7c6d7bc69d8cdcdfb9eb195fd37ef1cd2ab31499db61cd7d30d9b3a1` |
| UD-Q4_K_M | 16610543328 | `f90c5a4df44d335ac9f9eea2a15c31d6c5a377b1b3cd9ff7fc2cf123f3cdf7e1` |
| UD-Q4_K_XL | 17629759456 | `e62d463c135ffe283df8d94b279a96ca145ac128b52ce854478613045bf4de15` |
| UD-Q8_K_XL | 22867451616 | `dfb04bf37bee457f98800989dedf93ec442ede8636dbea9433992f1e527e9a41` |

- **`ggml-org/Inkling-2-Mini-GGUF`** @ `db61c5b492a6a034d986328d28274af0a439aa6c`
  - Licence field: **none (flag)**. Arch `inkling2_loop`.
  - Also has imatrix and mmproj files.

| File | Bytes | sha256 |
|---|---|---|
| BF16 | 52226509504 | `7074c9762e6769a608c7b23960a7fd2444880b1174a3910149749f6d01389aec` |
| IQ4_NL | 17627940768 | `cbdf3fa9dc50a4124977980f37da4f1fa764b0cfe800d275cd43d26ce2a81af4` |
| Q8_0 | 27820099264 | `d57542f8aea5d7639beba5fc4ae7f584754916f63ac5d5a69328c27f652f45da` |

- **Base:** `thinkingmachines/Inkling-2-Mini` @ `6e7c8248f75265bdd4fbab5273304243b5d8c2cb`
  - Licence `apache-2.0`, plus a "Model Acceptable Use Policy" link on the card (**flag**)
  - 26.4B total, 3.4B active, "5.4B effective active parameters per token"
  - 24 layers, of which the middle 12 run three times (48 layer visits); 8 of 128 experts; 1M context
  - The maker recommends Apple silicon with 32 GB or more.

**Q2. llama.cpp support. Cloak's pinned llama.cpp cannot load it.** No released llama.cpp can yet, so there is no "smallest version that can".

- **The pin:** `b12556` has `inkling2` (Inkling 1 and the non-looped 2), but has no `inkling2_loop` and no loop keys. I searched `llama-arch.cpp`, `llama-arch.h` and `llama-model.cpp` for `inkling2_loop` and `LOOP_CORE`: no matches.
- **The two converters wrote two different file formats:**
  - ggml-org's files need open PR **#32694** (new `inkling2_loop` arch; open, blocked).
  - Unsloth's files (block_count 48 with `loop.*` keys) need draft PR **#32695**.
  - Unsloth's guide also points to open PR **#32187**.
- **Latest release:** upstream b12590 (2026-11-20T19:02Z) predates both PRs.
- **Unsloth fork:** prebuild b12540-mix-c4017f9 has per-expert scales but no loop keys.
- **Related:** per-expert NVFP4 scales arrived in #32657, merged 2026-11-20, after Cloak's pin.
- **Mac caveat:** Unsloth's UD-Q8_K_XL keeps NVFP4 expert weights, which Metal does not run (neither the pin nor master). Those experts would fall back to the CPU on a Mac.

**Q3. How reasoning comes out through llama.cpp's template.**

- **Output shape:** the model writes
  - `<|message_model|><|content_thinking|>…<|end_message|>`, then
  - `<|message_model|><|content_text|>…<|end_message|>`, then
  - `<|content_model_end_sampling|>`
- **Parser:** the pinned parser `common/parsers/inkling.cpp` uses thinking start `<|content_thinking|>` and end `<|end_message|>`.
- **Effort control:**
  - Effort is a string or number mapped to 0.0–0.99 (default "high" = 0.9).
  - It is sent as a system line "Thinking effort level: N".
  - The maker says the minimum does not fully turn reasoning off.
- **Consequence for Cloak:** today's worker (no reasoning parsing, special tokens dropped, boolean-only template settings) would show the reasoning text inside answers. That needs a worker change.

**Q4. whichllm's index does not score it.**

- **What whichllm has:** `whichllm plan` knows the config: 26.4B (3.5B active), arch `inkling2loop`, Q4_K_M at 8k ≈ 18.10e9 bytes. It gives no quality score and no Apple speed.
- **My estimate (labelled; whichllm's MoE formula):** I used 5.4B effective active to account for the looping, and 3.5B as the no-loop upper bound. Memory is file size plus about 1.48 GiB at 8k.
  - **UD-Q3_K_XL** (about 14.2 GiB in use):
    - 17.6 tok/s on 32 GB M4 (27.2 without the loop)
    - 40.1 on M4 Pro
  - **UD-Q4_K_M** (about 16.9 GiB):
    - 15.9 on M4 (low band 5.6–31.8)
    - 36.2 on M4 Pro (12.7–72.4)
    - 13.3 on M2
  - **ggml IQ4_NL** (about 17.9 GiB): 13.6 on M4; 31.0 on M4 Pro
  - **ggml Q8_0** (about 27.4 GiB): 17.7 on M4 Pro
  - **UD-Q2_K_XL** (about 10.0 GiB): 23.7 on M4; 53.9 on M4 Pro
- **Where it would sit (from maker numbers, unverified):**
  - The maker's table rates it equal to Qwen3.8-27B (AA Index 20.1).
  - If that holds, a 3-bit file would sit at or near #1 at 32 GB, because it passes the speed bar where Qwen3.8 fails.
  - It would sit #1–2 at 48/64 GB.

**Q5. Measured tok/s on Apple silicon from anyone other than the maker:** none. I ran four web searches and found nothing. The SGLang cookbook says decode speed is roughly like Inkling-2-Small, but that was measured on GB300, not a Mac.

---

## Outside requests made (none contained a personal or project name)

- Anonymous fetches from GitHub (`gh api`), PyPI, Docker Hub and the Hugging Face API, made both inside and outside the containers.
- Web searches:
  - "Inkling 2 Mini tok/s Mac M4 llama.cpp GGUF"
  - "\"Inkling-2-Mini\" Apple silicon tokens per second MLX"
  - "Inkling 2 Mini Ollama MacBook speed tokens per second review"
  - "mlx-community Inkling-2-Mini"
- Page fetches:
  - `ai.google.dev/gemma/docs/gemma_4_license`, which redirects to `gemma.ai/resources/apache-2/`
  - the Unsloth Inkling notes at `unsloth.ai/docs/models/inkling-2-mini.md`

## Remaining work (for whoever finishes)

1. **Fill in the shortened sha256 values** in sections 3.2, 3.4 and 3.5 from `/tmp/cloak-build/models-research/hf/*.tree.json`. Only needed if the chief wants alternative quants pinned; the proposed and runner-up files already have full values.
2. **Confirm Qwen3.8 details:** the exact file name of the bartowski Qwen3.8-27B Q3_K_M (3.5), and the base repo's LICENSE text.
3. **Gemma terms:** decide whether Google's Gemma prohibited-use terms apply to Gemma 4. They would sit beside its Apache 2.0 licence.
4. **Chief decisions:**
   - which budget reading to use (section 6.1);
   - whether whichllm's speeds should be halved for Cloak (section 6.4).
5. **Inkling:** watch llama.cpp PRs #32694 and #32695. Once one merges and Cloak's pin moves past it, re-check:
   - which converter's file loads;
   - whether Unsloth's non-Q8 files carry NVFP4;
   - the GGUF `block_count`, which I inferred from PR code rather than read from a header.

   A worker change to handle reasoning output would also be needed before Inkling or gpt-oss could be used.
