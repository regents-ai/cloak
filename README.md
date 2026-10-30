# Regents Cloak

The private agent stack, ready to run.

Cloak is a signed Mac app that installs and operates the private-agent setup
Vitalik described on 16 October 2026: the Pi agent harness inside a bubblewrap
sandbox wrapped in torsocks, talking to a local zkAPI daemon that rewrites
prompts with a local model, gives each conversation its own Tor circuit, adds
cover traffic and pays through zkAPI. The goal is simpler installation and
everyday use with no weaker protection. Spec v0.4 runs the rewriter natively
on the Mac with a smaller model, tested as a controlled substitution for the
reference model.

The product contract is the spec, v0.4:
[docs/spec-v0.4.md](docs/spec-v0.4.md). Progress against its release gates
A01 to A26 is in [docs/plan.md](docs/plan.md).

## Status

Stage 2 of 6: build the local rewrite path, with a small stand-in model.
Stage 1 waits on the tokenizer decision and the evaluation sign-off. Nothing
here is a release,
and no protection is claimed as proven. A gate counts only when its evidence
is recorded in [docs/plan.md](docs/plan.md).

## Layout

| Path | Contents |
| --- | --- |
| `docs/spec-v0.4.md` | The product specification this repository builds |
| `docs/plan.md` | Stages, gates A01 to A26 and their evidence |
| `docs/evaluation-protocol.md` | How the candidates are compared with the reference |
| `reference/baseline.md` | REF01: the recorded reference stack, item by item |
| `reference/sources.json` | Pinned upstream sources (commits and package hashes) |
| `reference/rewriter-contract.md` | What the daemon sends the rewriter and accepts back |
| `reference/models.json`, `models.md` | Every file of the reference and candidate models, pinned by hash |
| `reference/tasks.md` | Representative reference tasks |
| `reference/wrapper/` | The reconstructed Pi sandbox wrapper and its Tor settings |
| `reference/host/` | The Linux reference host used for stage 1 |
| `worker/` | The native rewrite worker (Swift, MLX) |
| `tests/` | Functional checks, run with `uv run --with pytest` |
| `scripts/` | Repository scripts, run with `uv run` |
| `models/` | Model files fetched by `scripts/fetch_model.py` (ignored by git) |

## Stage 1 commands

Fetch the pinned upstream sources into `reference/src/` (ignored by git) and
verify every pin:

```bash
uv run scripts/fetch_sources.py
```

Record every file of the pinned models from Hugging Face, without downloading
weights (a change to `reference/models.json` afterwards means the hub served
different bytes):

```bash
uv run scripts/pin_models.py
```

Download one pinned model into `models/<name>/`, checking every file's size
and hash (the stand-in is 1.75 GB; each candidate is about 16 GB, so check free
disk first):

```bash
uv run scripts/fetch_model.py standin
```

## Stage 2 commands

Build the native worker (two build jobs, low priority; the first build needs
Apple's Metal toolchain, `xcodebuild -downloadComponent MetalToolchain`):

```bash
cd worker && nice -n 10 xcodebuild build -scheme cloak-rewriter -destination 'platform=macOS' -configuration Release -derivedDataPath .xcode -jobs 2
```

Send the worker one rewrite request built exactly as the daemon builds it:

```bash
uv run scripts/drive_worker.py --worker worker/.xcode/Build/Products/Release/cloak-rewriter --name standin "a text to rewrite"
```

Run the worker's functional checks against the stand-in model:

```bash
uv run --with pytest==8.4.2 pytest tests/test_worker.py
```

## Tickets

Work is tracked with `bd` in this repository: `bd ready` lists open work.

## Rules

See [AGENTS.md](AGENTS.md). In short: one implementation, no fallbacks, no
weaker substitutes, and no claim beyond what a passed gate shows.
