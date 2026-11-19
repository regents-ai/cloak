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
| `guest/` | The guest: adapter, the daemon's local API and rewrite check, the agent check (Pi in the wrapper), the sender (Development mode's way to a remote model), the door port and the runner (the owner's agent tasks, decision 12), kernel and root build |
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
grammars are built into the worker, so rebuild after `reference/models.json`,
`reference/rewrite-reply.gbnf` or `reference/details-reply.gbnf` changes:

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

Check the daemon's own cover traffic in the guest. Its destinations, rate
and concurrency live in one list, `reference/cover.json`, which the guest
image carries: a pool of 58 well-known pages, sixteen picked at random at
each start, at about three fetches a minute. Every check is against the
stand-in tor, so nothing is fetched. The first boots the image as built and
waits 200 seconds for its cover; each other check boots the guest with a
list of its own and waits past the daemon's first once-a-minute totals. The
agent and Tor checks above and below boot with an empty list laid over the
image's, so cover is off in them:

```bash
uv run --with pytest==8.4.2 pytest tests/test_cover_path.py
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

Check what a hostile agent in the sandbox can reach: the guest's loopback
services, the Tor port by hand, vsock, the guest's files, other ways out,
a process that tries to outlive its command, and another conversation's
files. Two boots, both against the stand-in tor: the first with cover off,
the second serving two conversations to the stand-in door
(`docs/plan.md`, "Escape checks"):

```bash
uv run --with pytest==8.4.2 pytest tests/test_escape_path.py
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

## Stage 5 commands

Stage 5 has started with a development build of the app's core: one
supervisor, run by a menu-bar app and by the `cloak` command. It runs the
small lead, Qwen 3.5 9B (`small-lead-gguf-grammar`), and has no sessions;
the daemon's own payment is not built. While the guest is up, its daemon
sends the reference's own cover traffic through Tor, background noise of
about three page fetches a minute from `reference/cover.json`. It needs a Mac with
Apple silicon whose graphics limit (Metal's recommended working set) holds
the model's 7 GiB with 1 GiB to spare, and whose memory holds all of
Cloak's 10 GiB with 4 GiB kept for macOS: a 16 GB Mac passes, an 8 GB one
does not, and one whose graphics limit cannot be read fails. The two needs
are `model_memory_gib` and `cloak_memory_gib` in `app/release.json`.
Running means tor is up, the worker is up or resting, a startup check sent
one rewrite through the guest, the daemon and the worker, and the guest's
sender is ready. The worker rests,
and the model leaves memory, once Cloak has reworded nothing for the time
chosen as Free memory in the Settings window (5 minutes until chosen, or 15
minutes, 1 hour or Never); the next request starts it again and waits a
few seconds longer. The Details window's Memory row shows what all of Cloak holds
now (the app, tor, the worker and the guest's virtual machine, by the
footprint Activity Monitor shows), read every 3 seconds while the window
is on screen; it says it can't be measured when any part cannot be read,
and the technical details, like `cloak status --json`, give each part's
figure.

With the guest, the host's tor and the worker built and installed (stage 2
commands), build `app/build/Regents Cloak.app`, with Sparkle.framework
inside, signed ad hoc and inside out, the app with the virtualization
entitlement, with a manifest that pins the guest, tor and the installed
worker (rebuild after reinstalling any of them):

```bash
app/build.sh
```

The app opens Paused in the menu bar, and never starts by itself. On the
first launch only, a Welcome window says what Cloak does and where it is,
and starts nothing. The menu's top shows the state, as a coloured dot and
in words, Starting or Stopping while it changes; when Cloak needs
attention, it says what went wrong and what to do, with a button for the
fix, or the way to it, when the app has one. The release and
build are at the menu's foot. `cloak` is inside the app; `cloak start`
opens the app if it isn't open:

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

"Settings…" in the menu (Command-comma) is the one place the app's
settings change; no link, script, app or agent can set one. General has
Launch at login (off until turned on; the app still opens Paused), Free
memory and, in a build with an update feed, Updates (below). Shortcut sets the quick prompt's keys, none until chosen; keys
without Command, Option or Control are refused, as is a shortcut macOS
won't take. Door sets the port Agents answer on (below), 8742 until
chosen: a number from 1024 to 65535 that nothing on this Mac listens on
when it is saved, used from the next Start, and always on 127.0.0.1 only.
Advanced shows exactly how the last start started tor and the worker, one
command a line, and this session's lines of Cloak's log, each with Copy,
and Restore Defaults, which puts these settings back and nothing else: not
the wallet, the chats or the model.

Updates come through Sparkle 2.8.1, and only to a build whose
`app/release.json` sets both `update_feed` and `update_key` (both empty
today, so no build has an updater; `app/build.sh` stops if only one is
set). Such a build has Check for Updates… in the menu, above Quit, and
Updates in General: Sparkle's own setting for checking once a day, off
until the person answers Sparkle's question on the second launch or turns
it on, and off again after Restore Defaults. A check goes straight from
the Mac to the feed's host, not through Tor, with a generic User-Agent,
and carries nothing from a chat. Sparkle takes an update only with a
signature it checks, and installs it once Cloak has quit through its
shutdown; the new app opens Paused. What a release needs is in
[docs/release.md](docs/release.md), item 7.

The quick prompt is a small box over whatever app is in front, opened and
closed by its shortcut; Escape closes it too. Return opens Chat with a new
chat whose message box holds what you wrote, as if typed there: nothing is
sent or reworded until you send it.

AppleScript can start and pause Cloak and show its windows, and nothing
else: no command takes text, changes a setting, sends, spends or touches
the wallet.

```bash
osascript -e 'tell application "Regents Cloak" to show chat'
```

The commands are `start`, `pause`, `show chat`, `show agents`, `show
details` and `show settings`; a start or pause that doesn't apply now
fails with the reason, as `cloak` would give it.

The app downloads the model, the small lead (5.4 GiB), while it is not
installed: the Details window, opened by Download Model in the menu, says
its size, its host (huggingface.co), and that this download goes straight
from this Mac to that host, which sees this Mac's address, unlike Cloak's
messages. Nothing downloads until Download is pressed, and the download
never starts Cloak. It fetches exactly the pinned files from the URLs
`scripts/fetch_model.py` uses, puts each in place only once its size and
sha256 match the pin, and carries on from where it stopped after a pause,
a quit, a crash or a lost network; Cancel removes what it fetched so far.
Download is disabled, with the reason beside it, when this Mac fails the
Mac check or the disk has less free than the rest of the model plus 1 GiB
(section 9a of [docs/state-machines.md](docs/state-machines.md)).
`uv run scripts/fetch_model.py small-lead-gguf-grammar` puts the same files
in the same place.

When a file is missing or not its pinned size, Start needs attention with
"The model isn't installed"; when the model's folder is not exactly the
pinned files (the worker checks every file's hash as it loads), with "The
model has changed": remove
`~/Library/Application Support/Regents Cloak/models/small-lead-gguf-grammar/`
(Show in Finder, in the menu, reveals it), download it again, and start
again.

"Chat" in the menu opens a Chat window. While Cloak is running, each
message is reworded on the Mac and shown beside the original, with the
words taken out and put in marked; the reworded text can be edited until
it is sent. An answer's formatting is drawn (headings, lists, code,
quotes, tables); its links show their address and never open, and its
images are never loaded. Each conversation, answers included, is kept as
one sealed file
in `~/Library/Application Support/Regents Cloak/conversations/`, with its
key in the login keychain. After a rebuild, the Mac asks once whether the
new build may use that key.

Send is Development mode (decision 10 in [docs/plan.md](docs/plan.md)),
marked as such at the top of Chat, and never part of a release: the
reworded text, after the conversation's earlier sent and answered turns,
goes from the guest's sender through Tor to a remote model at Boundless,
paid through MPP on Tempo from one wallet, so the provider can link every
chat. A tick in "Send Original", under the message box, sends that message
as written, with no rewording, still through Tor, and its Reworded light is
off; the tick is off at each launch, and apps sending through Agents
(below) are always reworded. Wallet, in Chat's toolbar, makes the wallet
when Create is pressed: its key is made in the guest and kept only in the
login keychain, this Mac only; the address to fund takes USDC.e on Tempo,
and the QR button beside Copy shows it as a code for a phone's wallet.
A small deposit, at the size the provider suggests (1 USDC.e), pays for chats and is topped up by
that much when it cannot pay for the next one; Close ends it with the
provider, which
refunds what is unspent, and Withdraw asks the network to close it and,
pressed again 15 minutes later, takes it back. The deposit's state is sealed in
`~/Library/Application Support/Regents Cloak/wallet/` under the
conversations' key. The key never reaches the log, the control socket,
`cloak status` or `cloak doctor`, and no message text does either; the log
has only why a request stopped.

A new conversation can be the agent's (decision 12, Development mode too):
before its first message, pick Agent under the message box. Each message
is then a task. The agent, Pi, works on it inside Cloak's sealed guest, in
the reference sandbox: it reaches the model only through Cloak, which
rewords the task on this Mac and sends it through Tor from the one wallet,
and its tools reach the web only through Tor. What its tools read goes to
the model as it is; only your own words are reworded. A task's card shows
it as written and as reworded, each step the agent takes, and its answer.
Stop ends a task and everything it started, as do Pause, Stop and Quit in
the menu; one that ended without an answer can be run again. Tasks in
different conversations run at the same time. The agent's work lives in
the guest's memory, so after Cloak starts again it does not remember a
conversation's earlier tasks, and the conversation says so.

While you write a message or a task, Cloak may suggest details it leaves
open (decision 13). Once the draft has four words or more and has rested
for about a second, the model on this Mac reads it and proposes up to four,
each a pill above the message box. Pressing one opens its picker: choices,
a span to narrow, colours, or a square between two pairs of opposite words,
and in each, Something else to type your own. Your first pick keeps the
details as they are until you send or empty the message. Each detail picked
is added under the message, after a blank line, as one line such as
`Budget: 1000–2500 USD`; details left alone add nothing. The draft goes
only to the model on this Mac, nothing is paid, and neither the draft nor
its details reach the log. It needs Cloak running, and a rewording never
waits for it.

"Agents" in the menu lets your other apps on this Mac send through Cloak,
in Development mode too, as to any server that speaks OpenAI's chat
format. While Cloak is running it answers at `http://127.0.0.1:8742/v1`,
or the port chosen in Settings, on 127.0.0.1 only; if another app holds
that port, Agents says so and nothing opens. Add gives an app a name and a pass, shown once with Copy;
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

Run the app's gate checks (the door end to end and as the guest's agent
meets it, with each conversation's turns checked against the pinned
daemon's own transcript, which needs Go and the daemon's source from the
stage 1 commands; every way a rewording stops sends nothing; the send path
with the deposit kept sealed; and whether this Mac holds the wallet):

```bash
swift test --package-path app
```

Run the sender's checks against stand-ins for Tor, the provider and the
network (Rust 1.97.1, which `guest/sender/rust-toolchain.toml` names; the
guest build uses the pinned Rust image instead):

```bash
(cd guest/sender && cargo test)
```

## Progress

Progress lives in [docs/plan.md](docs/plan.md).

## Rules

See [AGENTS.md](AGENTS.md). In short: one implementation, no fallbacks, no
weaker substitutes, and no claim beyond what a passed gate shows.
