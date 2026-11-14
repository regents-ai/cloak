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
write them. Stage 5 has started with a development build of the app's
core, running the small lead, and a Chat window that rewords messages and,
in a labelled Development mode (decision 10), sends the reworded text
through Tor to a remote model, paid from one wallet on the Mac. Stages 1
and 2 stay open in
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
| `llama-worker/` | The native rewrite worker (decision 8): Swift over llama.cpp, built from its pinned source with Metal, its sandbox entitlements and install script |
| `rewriter-kit/` | The worker's protocol and pins: the frames to and from the host, the daemon's request, the replies and the model pins |
| `host/` | The host library (tor, the worker's channel, the relay, the guest) and the `cloak-host` command the kits run |
| `app/` | Stage 5: the supervisor, the menu-bar app and the `cloak` command, as a development build |
| `guest/` | The guest: adapter, the daemon's local API and rewrite check, the agent check (Pi in the wrapper), the sender (Development mode's way to a remote model), kernel and root build |
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
disk first). A download cut short stops the run; running it again carries
on from where it stopped:

```bash
uv run scripts/fetch_model.py standin-gguf-grammar
```

## Stage 2 commands

Build the native worker, which runs GGUF models on llama.cpp (decision 8):
llama.cpp from its pinned source (`reference/src/llama.cpp`, fetched above;
CMake comes through uv) with Metal, then the worker (two build jobs, low
priority). It is signed into the App Sandbox with no network and reading
only the models folder, and installed in
`~/Library/Application Support/Regents Cloak/worker/` (the sandbox cannot
start a program kept under `~/Documents`). The model pins and the reply
grammar are built into the worker, so rebuild after `reference/models.json`
or `reference/rewrite-reply.gbnf` changes:

```bash
llama-worker/install.sh
```

Send the installed worker one rewrite request built exactly as the daemon
builds it:

```bash
uv run scripts/drive_worker.py --name standin-gguf-grammar "a text to rewrite"
```

Run the worker's functional checks against the stand-in
(`standin-gguf-grammar`, decoded under the reply grammar, decision 9): the
channel, cancellation, the model pins, the sandbox, no network code linked,
numbers-only logs, and its replies judged by the daemon's own check (built
with Go inside the pinned daemon source):

```bash
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
fails the host. tor's SOCKS port is a socket file in a folder only you can
open, made for each start; nothing of tor's listens on the network. Once
tor has stopped, nothing more is relayed to it.
tor keeps its state (its entry guards and directory cache) in one lasting
folder the host is given with `--tor-data`: the stage kits use
`~/Library/Application Support/Regents Cloak/tor`, and the checks a scratch
folder of their own. The first check runs tor on the public Tor network
and fetches https://check.torproject.org/api/ip through it; the others
send nothing off the Mac, and four of them wait out that 90-second limit:

```bash
uv run --with pytest==8.4.2 pytest tests/test_tor_path.py
```

## Stage 3 commands

With the stage 2 parts built and a candidate's weights on disk (fetched only
when Sean decides), one command writes that candidate's feasibility record
(EVAL05, EVAL06 and EVAL07):

```bash
uv run scripts/stage3.py feasibility small-lead-gguf-grammar
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
uv run scripts/stage3.py eval01 small-lead-gguf-grammar
```

The candidates are `small-lead-gguf-grammar` and
`small-challenger-gguf-grammar`: the small pair decision 7 in
`docs/plan.md` added, as GGUF files on llama.cpp (decision 8) under the
reply grammar (decision 9). Any other model, such as the stand-in
`standin-gguf-grammar`, gets a record marked development only, which counts
toward no gate.

Run the kit's own checks:

```bash
uv run --with pytest==8.4.2 pytest tests/test_stage3.py
```

## Stage 4 commands

Stage 4 qualifies the substitution against the fidelity holdout (EVAL02)
and the privacy holdout (EVAL03) under the evaluation protocol, a draft that
Sean freezes before any holdout opens. The holdouts are
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
uv run scripts/stage4.py rewrite small-lead-gguf-grammar EVAL02 <file>
uv run scripts/stage4.py rewrite small-lead-gguf-grammar EVAL03 <file>
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

## Stage 5 commands

Stage 5 has started with a development build of the app's core: one
supervisor, run by a menu-bar app and by the `cloak` command. It runs the
small lead, Qwen 3.5 9B (`small-lead-gguf-grammar`), needs a Mac with Apple
silicon and 16 GB of memory, and has no sessions or cover traffic; the
daemon's own payment is not built. Running means tor and the worker are up,
a startup check sent one rewrite through the guest, the daemon and the
worker, and the guest's sender is ready.

With the guest, the host's tor and the worker built and installed (stage 2
commands) and the small lead fetched (5.4 GiB):

```bash
uv run scripts/fetch_model.py small-lead-gguf-grammar
```

build `app/build/Regents Cloak.app`,
signed ad hoc with the virtualization entitlement, with a manifest that pins
the guest, tor and the installed worker (rebuild after reinstalling any of
them):

```bash
app/build.sh
```

The app opens Paused in the menu bar, and never starts by itself. `cloak`
is inside it; `cloak start` opens the app if it isn't open:

```bash
cloak="app/build/Regents Cloak.app/Contents/MacOS/cloak"
"$cloak" start
"$cloak" status --json
"$cloak" pause
"$cloak" doctor
```

The commands are `status`, `start`, `pause`, `resume`, `stop`, `verify`
(the startup check, then stop) and `doctor` (the Mac and every installed
part against its pin). Each waits until its change has finished; `--json`
prints the versioned status with its reason and next action, and the exit
status is 1 when a command is refused, the app isn't open, or it needs
attention. `cloak` takes no task text and prints no prompt text or keys.
It talks to the app over a socket only the same user can reach, in
`~/Library/Application Support/Regents Cloak/control/`. A guest's boot
files, which hold its keys while it starts, are in `control/boot/`; each
launch first removes any that a killed app left there.

The app does not download the model. When a file is missing or not its
pinned size it needs attention with "The model isn't installed"; when the
model's folder is not exactly the pinned files (the worker checks every
file's hash as it loads), with "The model has changed". Either way, remove
`~/Library/Application Support/Regents Cloak/models/small-lead-gguf-grammar/`,
fetch it again with the command above, and start again.

"Chat…" in the menu opens a Chat window. While Cloak is running, each
message is reworded on the Mac and shown beside the original, with the
words taken out and put in marked; the reworded text can be edited until
it is sent. Each conversation, answers included, is kept as one sealed file
in `~/Library/Application Support/Regents Cloak/conversations/`, with its
key in the login keychain. After a rebuild, the Mac asks once whether the
new build may use that key.

Send is Development mode (decision 10 in [docs/plan.md](docs/plan.md)),
marked as such at the top of Chat, and never part of a release: the
reworded text, after the conversation's earlier sent and answered turns,
goes from the guest's sender through Tor to a remote model at Boundless,
paid through MPP on Tempo from one wallet, so the provider can link every
chat. Wallet, in Chat's toolbar, makes the wallet when Create is pressed:
its key is made in the guest and kept only in the login keychain, this Mac
only; the address to fund takes USDC.e on Tempo. A small deposit, at the
size the provider suggests (1 USDC.e), pays for chats and is topped up by
that much when it cannot pay for the next one; Close ends it with the
provider, which
refunds what is unspent, and Withdraw asks the network to close it and,
pressed again 15 minutes later, takes it back. The deposit's state is sealed in
`~/Library/Application Support/Regents Cloak/wallet/` under the
conversations' key. The key never reaches the log, the control socket,
`cloak status` or `cloak doctor`, and no message text does either; the log
has only why a request stopped.

"Agents…" in the menu lets your other apps on this Mac send through Cloak,
in Development mode too, as to any server that speaks OpenAI's chat
format. While Cloak is running it answers at `http://127.0.0.1:8742/v1`,
on 127.0.0.1 only; if another app holds that port, Agents says so and
nothing opens. Add gives an app a name and a pass, shown once with Copy;
Remove ends the pass at once. Point the app at the address with the pass as
its key, for example with OpenAI's Python library:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8742/v1", api_key="<the pass>")
client.chat.completions.create(
    model="deepseek/deepseek-v4-flash-0731",
    messages=[{"role": "user", "content": "Say hello to the team."}],
)
```

Only `POST /v1/chat/completions` and `GET /v1/models` (the provider's own
list) answer, each with `Authorization: Bearer` and the pass; a request
from a web page (with an `Origin` header) is refused. Each user message's
text is reworded on this Mac first, as Chat and the pinned daemon do it:
earlier user messages go as reworded before, and a history that is not the
last one continued is reworded again, with a Tor identity of its own.
System and developer messages, tool definitions, tool calls and results,
the model's earlier answers, and images, audio and files go as the app
sends them. Refused before anything leaves: `n` other than 1, `store`,
images by link, stored files, roles and parts the provider does not take,
and a message over 10,000 characters. `stream: true` gets the whole answer
as one server-sent chunk, then `data: [DONE]`. Every stop comes back as
OpenAI's error shape with a plain message; pausing Cloak answers a request
under way with 503. Only each app's name, when it was added, its count of
requests and when it was last used are kept, sealed in
`~/Library/Application Support/Regents Cloak/agents` under the
conversations' key; no request's text is kept, shown or logged.

Run the supervisor's checks (state changes, stand-in tor and worker
processes, the control socket and its JSON, the boot files a killed app
left, the app's rewrite against the pinned daemon's code, which needs Go
and the daemon's source from the stage 1 commands, and the sealed
conversations):

```bash
swift test --package-path app
```

Run the sender's checks against stand-ins for Tor, the provider and the
network (Rust 1.97.1, which `guest/sender/rust-toolchain.toml` names; the
guest build uses the pinned Rust image instead):

```bash
(cd guest/sender && cargo test)
```

Check that a lost worker that ignores being stopped is killed 10 seconds
later, before a new one starts (through the guest, with the stand-in tor):

```bash
uv run --with pytest==8.4.2 pytest tests/test_worker_stop.py
```

## Progress

Progress lives in [docs/plan.md](docs/plan.md).

## Rules

See [AGENTS.md](AGENTS.md). In short: one implementation, no fallbacks, no
weaker substitutes, and no claim beyond what a passed gate shows.
