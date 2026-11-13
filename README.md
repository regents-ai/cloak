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

Stage 3 of 6: the feasibility kit is ready and waits for the candidates'
weights, which Sean decides when to fetch. The stage 4 qualification kit is
built and proven on development data only; its holdouts need people to
write them. Stages 1 and 2 stay open in
[docs/plan.md](docs/plan.md). Nothing here is a release, and no protection is
claimed as proven. A gate counts only when its evidence
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
| `reference/eval05-inputs.json`, `eval06-messages.json` | The fixed synthetic inputs for stage 3, pinned by hash in `scripts/stage3.py` |
| `reference/holdouts.json` | The stage 4 holdouts' pins, recorded before any model runs on them |
| `reference/stage4-dev-fidelity.json`, `stage4-dev-privacy.json` | Development sets for the stage 4 kit; never holdouts |
| `reference/wrapper/` | The reconstructed Pi sandbox wrapper and its Tor settings |
| `reference/host/` | The Linux reference host used for stage 1 |
| `worker/` | The native rewrite worker (Swift, MLX), its sandbox entitlements and install script |
| `llama-worker/` | The second rewrite worker (decision 8): Swift over llama.cpp, built from its pinned source with Metal, with the same sandbox and its own install script |
| `rewriter-kit/` | What both workers share: the frames to and from the host, the daemon's request, the replies and the model pins |
| `host/` | The host supervisor: boots the guest and relays its rewrites to the worker |
| `guest/` | The guest: adapter, the daemon's local API and rewrite check, the agent check (Pi in the wrapper), kernel and root build |
| `evidence/stage3/` | Stage 3 records, one folder per model |
| `evidence/stage4/` | Stage 4 development records and every score, one folder per model |
| `tests/` | Functional checks, run with `uv run --with pytest` |
| `scripts/` | Repository scripts, run with `uv run` |

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

Download one pinned model into
`~/Library/Application Support/Regents Cloak/models/<name>/`, the only folder
the sandboxed worker may read, checking every file's size and hash (a
model's size is its `total_bytes` in `reference/models.json`, so check free
disk first):

```bash
uv run scripts/fetch_model.py standin
```

## Stage 2 commands

Build the native worker (two build jobs, low priority; the first build needs
Apple's Metal toolchain, `xcodebuild -downloadComponent MetalToolchain`), sign
it into the App Sandbox with no network and reading only the models folder,
and install it in `~/Library/Application Support/Regents Cloak/worker/` (the
sandbox cannot start a program kept under `~/Documents`). The model pins are
built into the worker, so rebuild after `reference/models.json` changes:

```bash
worker/install.sh
```

The second worker (decision 8) runs GGUF models on llama.cpp. Build
llama.cpp from its pinned source (`reference/src/llama.cpp`, fetched above;
CMake comes through uv) with Metal, then the worker, signed with the same
entitlements and installed beside the first, and fetch its stand-in. Each
model a worker runs names its `engine` (`mlx` or `llama`) in
`reference/models.json`, and the kits start that engine's worker:

```bash
llama-worker/install.sh
uv run scripts/fetch_model.py standin-gguf
```

Send the installed worker one rewrite request built exactly as the daemon
builds it:

```bash
uv run scripts/drive_worker.py --name standin "a text to rewrite"
```

Run both workers' functional checks, each against its stand-in (`standin`
and `standin-gguf`), then the llama worker's own: the same prompt tokens as
the MLX worker, no network code linked, and numbers-only logs:

```bash
uv run --with pytest==8.4.2 pytest tests/test_worker.py
uv run --with pytest==8.4.2 pytest tests/test_llama_worker.py
```

Build the guest (Go cross-builds and a pinned Debian image in Docker, two
cores), then the host supervisor, signed with the virtualization
entitlement, with the pinned tor beside it (the Tor Project's own build,
fetched once by `uv run scripts/fetch_sources.py` and checked by its hash):

```bash
guest/build.sh
```

```bash
host/build.sh
```

Run the whole path: the daemon's own rewrite code in the guest, the adapter,
the host and a worker (one guest boot per check; two checks wait out the
daemon's deadline, which is 90 seconds plus 20 ms for each character, for
about 90 and 290 seconds):

```bash
uv run --with pytest==8.4.2 pytest tests/test_guest_path.py
```

Run Pi 1.3.0 in the guest, inside the reference wrapper, through the
daemon's local API (the host's tor is a stand-in that refuses every route,
so every task stops at the Tor route after its rewrite; one check uses the
real worker):

```bash
uv run --with pytest==8.4.2 pytest tests/test_agent_path.py
```

Check the guest's one way out, the Tor port relayed to the host's tor. The
host starts the guest only once tor has bootstrapped, or after tor exits or
is stopped at 90 seconds; a tor whose SOCKS port has not opened by then
fails the host. Once tor has stopped, nothing more is relayed to its port.
tor keeps its state (its entry guards and directory cache) in one lasting
folder the host is given with `--tor-data`: the stage kits use
`~/Library/Application Support/Regents Cloak/tor`, and the checks a scratch
folder of their own. The first check runs tor on the public Tor network
and fetches https://check.torproject.org/api/ip through it; the others
send nothing off the Mac, and three of them wait out that 90-second limit:

```bash
uv run --with pytest==8.4.2 pytest tests/test_tor_path.py
```

## Stage 3 commands

With the stage 2 parts built and a candidate's weights on disk (fetched only
when Sean decides), one command writes that candidate's feasibility record
(EVAL05, EVAL06 and EVAL07):

```bash
uv run scripts/stage3.py feasibility lead
```

It checks everything first (the pins, each model file's size, the inputs and
daemon sources by hash, that each EVAL06 message is 512 tokens or fewer with
the candidate's own tokenizer, that no other guest is running, and that the
model's size plus 5 GiB of memory is available), then boots the guest three
times in turn: the main run, the worker killed mid-rewrite, and a restart.
The record goes to `evidence/stage3/<name>/` with every call's input, raw
reply, timing and hashes. Steps that need a person (sleep and wake, battery,
the declared load, induced memory pressure, the first run after a restart)
are listed in the record with no result.

Run the development screen (EVAL01: the daemon's 16 synthetic cases and its
own checks) through the same path:

```bash
uv run scripts/stage3.py eval01 lead
```

The candidates are `lead`, `challenger`, `small-lead` and `small-challenger`
(decision 7 in `docs/plan.md` added the last two), and `small-lead-gguf` and
`small-challenger-gguf` on llama.cpp (decision 8). Any other model, such as
`standin` or `standin-gguf`, gets a record marked development only, which counts toward no
gate.

Run the kit's own checks:

```bash
uv run --with pytest==8.4.2 pytest tests/test_stage3.py
```

## Stage 4 commands

Stage 4 qualifies the substitution against the fidelity holdout (EVAL02)
and the privacy holdout (EVAL03) under the frozen protocol. The holdouts are
written by people, kept outside this repository, and pinned once before any
model runs on them:

```bash
uv run scripts/stage4.py check EVAL02 <file>
uv run scripts/stage4.py pin EVAL02 <file>
```

Rewrite a set through the same real path as stage 3. Records holding
holdout text stay beside the holdout, in `records/<name>/`; development
records go to `evidence/stage4/<name>/`:

```bash
uv run scripts/stage4.py rewrite lead EVAL02 <file>
uv run scripts/stage4.py rewrite lead EVAL03 <file>
```

Fidelity: make the blinded review packet (the outputs without their arm)
and its key, give the packet to the reviewers, then score a candidate
against the reference with their answers:

```bash
uv run scripts/stage4.py review <file> <reference record> <candidate record>...
uv run scripts/stage4.py fidelity <file> --reference <record> --candidate <record> --key <key> --reviews <answers>
```

Privacy, with the protocol's character n-gram attack:

```bash
uv run scripts/stage4.py privacy <file> --reference <record> --candidate <record>
```

Scores hold no text and go to `evidence/stage4/<candidate>/`. Also:
`repeat <name> <development file>` runs a development set three times to
measure run-to-run variation, and `sample-size --from <fidelity score>`
gives the EVAL02 holdout size from development rates. In a development
comparison `originals` may stand for an arm; on a holdout every arm is a run
record and only a candidate may rewrite it.

Run the kit's own checks:

```bash
uv run --with pytest==8.4.2 --with scikit-learn==1.9.1 --with numpy==2.5.4 \
    --with scipy==1.18.1 --with tokenizers==0.22.1 pytest tests/test_stage4.py
```

## Progress

Progress lives in [docs/plan.md](docs/plan.md).

## Rules

See [AGENTS.md](AGENTS.md). In short: one implementation, no fallbacks, no
weaker substitutes, and no claim beyond what a passed gate shows.
