# Regents Cloak — Engineering Build, Evaluation & Runbook

This runbook preserves the stage-by-stage repository layout, feasibility/qualification scripts (Stages 1–4), and detailed component commands for `regents-ai/cloak`.

- Product overview & user guide: [README.md](../README.md)
- Full `v0.2.0` code-level architecture map: [docs/tech-stack.md](tech-stack.md)
- Product specification & gates: [docs/spec-v0.4.md](spec-v0.4.md) · [docs/plan.md](plan.md)
- Release checklist: [docs/release.md](release.md)

## Repository Layout

| Path | Contents |
| --- | --- |
| `docs/spec-v0.4.md` | The product specification this repository builds |
| `docs/plan.md` | Stages, gates A01 to A26 and their evidence |
| `docs/tech-stack.md` | Complete `v0.2.0` mode & integration code-level reference |
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
| `vmlx-worker/` | Pure-Swift Apple MLX + JANGH2 + DSpark local chat worker (`cloak-worker-vmlx`) |
| `llama-worker/` | Native Metal `llama.cpp` worker (`cloak-rewriter-llama`) for prompt rephrasing and GGUF + LoRA chat |
| `rewriter-kit/` | Shared framed binary IPC protocol (`Frames`), multi-turn `Conversation`, and `Reply` parser |
| `host/` | Host library (`Tor`, `WorkerChannel`, `Relay`, `Guest`) and `cloak-host` helper |
| `app/` | macOS app (`RegentsCloak`, `CloakSupervisor`, `CloakChat`, `CloakDoor`, `CloakControl`, `CloakWidgets`, `cloak` CLI) and build/release scripts |
| `guest/` | Linux arm64 guest (`cloak-near`, `cloak-sender`, `cloak-pay`, `cloak-runner`, `Pi`, `Node.js`, LUKS2 `pay-disk`, kernel and initramfs build) |
| `evidence/stage3/` | Stage 3 records, one folder per model |
| `evidence/stage4/` | Stage 4 development records and every score, one folder per model |
| `tests/` | Functional checks, run with `uv run --with pytest` |
| `scripts/` | Repository scripts, run with `uv run` |

## Stage 1: Fetch & Pin Upstream Sources

Fetch pinned upstream sources into `reference/src/` (gitignored) and verify every pin:

```bash
uv run scripts/fetch_sources.py
uv run scripts/fetch_sources.py --check
```

Record pinned model file metadata from Hugging Face without downloading weights:

```bash
uv run scripts/pin_models.py
```

Download one pinned model into `~/Library/Application Support/Regents Cloak/models/<name>/` (resumable, SHA-256 verified):

```bash
uv run scripts/fetch_model.py small-lead-gguf-grammar
```

## Stage 2: Build Workers, Guest VM & Host Checks

Build and sandbox-sign the native `llama.cpp` worker (rebuilds `reference/src/llama.cpp` with Metal and installs into `~/Library/Application Support/Regents Cloak/worker/`):

```bash
llama-worker/install.sh
```

Exercise the worker directly with a rewrite or multi-turn chat:

```bash
uv run scripts/drive_worker.py --name small-lead-gguf-grammar "a text to rewrite"
uv run scripts/drive_worker.py --name small-lead-gguf-grammar --chat "My cat is called Miso." "What is my cat called?"
```

Build the Linux arm64 guest image (Docker, 2 cores) and host supervisor:

```bash
guest/build.sh
host/build.sh
```

Run guest/host isolation and transport tests:

```bash
uv run --with pytest==8.4.2 pytest tests/test_tor_path.py
uv run --with pytest==8.4.2 pytest tests/test_escape_path.py
sh guest/image/pay-disk-check.sh
uv run --with pytest==8.4.2 pytest tests/test_pay_disk.py
uv run --with pytest==8.4.2 pytest tests/test_pay_frames.py
sh guest/pay/check.sh
```

## Stage 3 & Stage 4: Rewriter Feasibility & Qualification

Feasibility & development screen (`EVAL05`, `EVAL06`, `EVAL07`, `EVAL01`):

```bash
uv run scripts/stage3.py feasibility small-lead-gguf-grammar
uv run scripts/stage3.py eval01 small-lead-gguf-grammar
```

Holdout qualification (`EVAL02` fidelity, `EVAL03` character n-gram privacy):

```bash
uv run scripts/stage4.py check EVAL02 <file>
uv run scripts/stage4.py pin EVAL02 <file>
uv run scripts/stage4.py rewrite small-lead-gguf-grammar EVAL02 <file>
uv run scripts/stage4.py rewrite small-lead-gguf-grammar EVAL03 <file>
uv run scripts/stage4.py review <file> <reference record> <candidate record>...
uv run scripts/stage4.py fidelity <file> --reference <record> --candidate <record> --key <key> --reviews <answers>
uv run scripts/stage4.py privacy <file> --reference <record> --candidate <record>
```

## App Build, CLI, AppleScript, Logs & Test Suites

Build `app/build/Cloak.app` (signed with Developer ID, hardened runtime, virtualization entitlement, bundled `cloak-near`, `cloak-worker-vmlx`, `cloak-rewriter-llama`, `tor`, guest kernel/initrd, `Sparkle.framework`, and embedded `app/RegentsCloak.provisionprofile` for Data Protection Keychain when present):

```bash
app/build.sh
```

Control the app via the bundled `cloak` CLI (speaks over owner-only Unix socket `~/Library/Application Support/Regents Cloak/control/cloak.sock`; never takes or prints prompt text or keys):

```bash
cloak="app/build/Cloak.app/Contents/MacOS/cloak"
"$cloak" doctor
"$cloak" start
"$cloak" status --json
"$cloak" pause
```

Supported CLI commands: `status`, `start`, `pause`, `resume`, `stop`, `verify`, `doctor`.

AppleScript commands (control & window focus only — never takes text, changes settings, sends, or touches wallets):

```bash
osascript -e 'tell application "Cloak" to show chat'
# Commands: start, pause, show chat, show agents, show details, show settings, show darkbloom
```

Inspect recent app logs and macOS crash reports (default 60 minutes):

```bash
app/log.sh 60
```

Run unit and integration test suites:

```bash
swift test --package-path app
(cd guest/near && cargo test --locked)
(cd guest/sender && cargo test)
sh guest/pay/check.sh
```

## Release & Publish

Requires a clean tree, Developer ID signing identity, Sparkle EdDSA update key (`cloak` in Keychain), Apple notary profile (`cloak-notary`), and authenticated `gh` CLI for `regents-ai/cloak-releases`. See [docs/release.md](docs/release.md).

```bash
app/release.sh
app/publish.sh
```
