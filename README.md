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
[docs/plan.md](docs/plan.md). The one build meant to leave this Mac is the
technical preview for invited testers ([docs/release.md](docs/release.md),
stage 1), which claims no protection; nothing here is the public release,
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
| `reference/eval05-inputs.json`, `eval06-messages.json` | The fixed synthetic inputs for stage 3, pinned by hash in `scripts/stage3.py` |
| `reference/holdouts.json` | The stage 4 holdouts' pins, recorded before any model runs on them |
| `reference/stage4-dev-fidelity.json`, `stage4-dev-privacy.json` | Development sets for the stage 4 kit; never holdouts |
| `reference/wrapper/` | The reconstructed Pi sandbox wrapper and its Tor settings |
| `reference/host/` | The Linux reference host used for stage 1 |
| `llama-worker/` | The native worker (decision 8), which rewords and answers Local Llama chats: Swift over llama.cpp, built from its pinned source with Metal, its sandbox entitlements and install script |
| `rewriter-kit/` | The worker's protocol and pins: the frames to and from the host, the daemon's request, a Local Llama conversation, the replies and the model pins |
| `host/` | The host library (tor, the worker's channel, the relay, the guest) and the `cloak-host` command the kits run |
| `app/` | Stage 5: the supervisor, the menu-bar app and the `cloak` command, as a development build, and the scripts that release them (Release, below) |
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
`~/Library/Application Support/Regents Cloak/worker/` for the scripts and
checks below (the sandbox cannot start a program kept under `~/Documents`).
`app/build.sh` takes the same signed build into the app, which puts its own
copy in that folder at each Start when the file there is not the one it
pins (Stage 5 commands, below). The model pins and the reply
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

Or send it a short Local Llama chat, each text one message, each sent with
the conversation so far as the app sends it; `--stop-after 2` stops the
first answer after two seconds, as Stop does, then asks it again, and
`--worker` runs another build of the worker, such as a check copy:

```bash
uv run scripts/drive_worker.py --name small-lead-gguf-grammar --chat "My cat is called Miso." "What is my cat called?"
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

The daemon's own cover traffic runs in the guest. Its destinations, rate
and concurrency live in one list, `reference/cover.json`, which the guest
image carries: a pool of 58 well-known pages, sixteen picked at random at
each start, at about three fetches a minute. The checks below boot with an
empty list laid over the image's, so cover is off in them.

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
about three page fetches a minute from `reference/cover.json`, unless Cover
traffic was off in Settings at Start: the guest's boot files then lay a
list with no URLs over that one, the daemon's own cleared setting, and no
cover worker starts in that run. It needs a Mac with
Apple silicon whose graphics limit (Metal's recommended working set) holds
the model's 7 GiB with 1 GiB to spare, and whose memory holds all of
Cloak's 10 GiB with 4 GiB kept for macOS: a 16 GB Mac passes, an 8 GB one
does not, and one whose graphics limit cannot be read fails. The two needs
are `model_memory_gib` and `cloak_memory_gib` in `app/release.json`.
Running means tor is up, the worker is up or resting, a startup check sent
one rewrite through the guest, the daemon and the worker, and the guest's
sender is ready. The worker rests,
and the model leaves memory, once it has had nothing to do for the time
chosen as Free memory in the Settings window (5 minutes until chosen, or 15
minutes, 1 hour or Never); the next request starts it again and waits a
few seconds longer. The Details window's Memory row shows what all of Cloak holds
now (the app, tor, the worker and the guest's virtual machine, by the
footprint Activity Monitor shows), read every 3 seconds while the window
is on screen; it says it can't be measured when any part cannot be read,
and the technical details, like `cloak status --json`, give each part's
figure. Under Status, Details
says what the two states mean: "Running: Tor is connected. Anon and Agent
chats can send." and "Paused: Tor is off. Anon and Agent chats wait."

With the guest, the host's tor and the worker built (stage 2 commands),
build `app/build/Regents Cloak.app`, with Sparkle.framework inside, signed
inside out with the Developer ID that `app/release.json` names, under the
hardened runtime (every build on this Mac is signed as a release is, since
20 November), the app with the virtualization entitlement, with
NEAR mode's helper `cloak-near`, which it builds from `guest/near` with
cargo (rustup takes the Rust version that `guest/near/rust-toolchain.toml`
names), with the worker as `llama-worker/install.sh` built and signed it,
and with a manifest that pins the guest, tor, the helper and the worker
(rebuild after rebuilding any of them). Every part the app runs is inside
it. The worker's sandbox cannot start a program kept under `~/Documents`
or `~/Downloads`, so at each Start, once the checks pass, the app copies
its worker to `~/Library/Application Support/Regents Cloak/worker/` when
the file there is missing or not the one it pins, checks the copy against
the pin, and runs the worker from there:

```bash
app/build.sh
```

Given the name of a signing identity in the keychain as its one argument,
`app/build.sh` signs every part with that identity instead, under the
hardened runtime and with a secure timestamp, tor, libevent and the
worker included, the worker into its sandbox. `app/release.sh` does that
with the Developer ID (Release, below).

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
(the startup check, then stop) and `doctor` (the Mac and every part in the
app against its pin). Each waits until its change has finished; `--json`
prints the versioned status with its reason and next action, and the exit
status is 1 when a command is refused, the app isn't open, or it needs
attention. `cloak` takes no task text and prints no prompt text or keys.
It talks to the app over a socket only the same user can reach, in
`~/Library/Application Support/Regents Cloak/control/`. A guest's boot
files, which hold its keys while it starts, are in `control/boot/`; each
launch first removes any that a killed app left there.

"Settings…" in the menu (Command-comma) is where the app's settings
change, and the one place but for Never reword, which Chat's review area
also has, Cover traffic, which Chat's Cover pill also turns on and off,
and Tor for NEAR, which Chat's Tor pill in a NEAR conversation also turns
on and off; no link, script, app or agent can set one. General has Launch
at login (off until turned on; the app still opens Paused), "Never reword
text. Reduces your privacy." (off until ticked; see Chat, below), Review
and Saved chats (on until turned off; see Chat, below), Cover traffic (on
until turned off; used from the next Start), Free
memory, Updates (below) and Feedback and Help: a link to Patchbay's board
for regents.sh, and words to copy for an agent that posts there. NEAR has the
NEAR key (a field and Save; once saved, Saved with Replace and Remove),
Tor (off until turned on), Freshness (10 minutes until chosen, or Every
message or 1 hour) and the model, Qwen3.8-27B, which can't be changed; see
NEAR mode, below. Shortcut sets the quick prompt's keys, none until chosen; keys
without Command, Option or Control are refused, as is a shortcut macOS
won't take. Door sets the port Agents answer on (below), 8742 until
chosen: a number from 1024 to 65535 that nothing on this Mac listens on
when it is saved, used from the next Start, and always on 127.0.0.1 only.
Advanced shows exactly how the last start started tor and the worker, one
command a line, and this session's lines of Cloak's log, each with Copy,
and Restore Defaults, which puts these settings back and nothing else: not
the wallet, the NEAR key, the chats or the model.

Updates come through Sparkle 2.8.1, from the feed and the update key's
public half in `app/release.json`: the feed is `appcast.xml` in the
public repository `regents-ai/cloak-releases`, which holds only signed
builds (Release, below). Every build, the development build included,
has Check for Updates… in the menu, above Quit, and Updates in General:
Sparkle's own setting for checking once a day, off
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
it is sent. With Review off (Settings, General), the box's button reads
Send, and each message is sent as soon as it is reworded, through the
same checks as Send: one that cannot go yet (no wallet, no funds) stays
open, saying why. Review does nothing while Never reword is ticked, and
the agent's tasks and the door never have this step. An answer's
formatting is drawn (headings, lists, code,
quotes, tables); its links show their address and never open, and its
images are never loaded. Each conversation, answers included, is kept as
one sealed file
in `~/Library/Application Support/Regents Cloak/conversations/`, with its
key in the login keychain. After a rebuild, the Mac asks once whether the
new build may use that key. With Saved chats off, a conversation started
or continued is no longer written, and is marked "Not saved" in the list
for as long as Cloak runs, even if Saved chats is turned on again: what was
said in it since Saved chats went off is gone when Cloak quits. A
conversation saved before keeps its file as it was; turning Saved chats
off deletes nothing, and Delete still removes a file.

Under the message box, three small pills show Cover, Tor and zkAPI, each
with a dot, filled while on. Cover turns cover traffic on and off, as in
Settings, and while Cloak is running with the other value it says "Cover
changes after Pause, then Start." Tor is always on and zkAPI is off, since
one wallet pays for everything; neither can be changed yet, and a press on
either says so. Resting the pointer on a pill for a second shows what it
controls. In a NEAR
conversation, one pill, Tor for NEAR (below), takes their place; in a
Local Llama conversation (below), one line: "The model on this Mac
answers. Nothing is sent."

Send is Development mode (decision 10 in [docs/plan.md](docs/plan.md)),
marked as such at the top of Chat (NEAR Private AI's or Local Llama's mark
takes its place in those conversations), and never part of the public release (the technical
preview for invited testers carries it, labelled;
[docs/release.md](docs/release.md), stage 1): the
reworded text, after the conversation's earlier sent and answered turns,
goes from the guest's sender through Tor to a remote model at Boundless,
paid through MPP on Tempo from one wallet, so the provider can link every
chat. Beside Send, "Send Original Text" sends that message as written
instead, still through Tor; its card then shows the Original alone and its
Reworded light is off. Under them, "Never reword text. Reduces your
privacy." (also in Settings, General) makes every Chat message go as
written at once on Send, with no rewording and no review; while it is
ticked, Chat says "Rewording is off" under the message box. It stays
ticked across launches until unticked or Restore Defaults. The agent's
tasks and apps sending through Agents (below) are always reworded. Wallet,
in Chat's toolbar, makes the wallet
when Create is pressed: its key is made in the guest and kept only in the
login keychain, this Mac only; the address to fund takes USDC.e on Tempo,
and the QR button beside Copy shows it as a code for a phone's wallet.
Its balance and deposit are read through the guest, so until Cloak has run
since it opened they show a dash, whose help says "Start Cloak to load the
wallet balance." (or "the deposit"): nothing leaves this Mac for the wallet
while Cloak is paused. The model picker shows each
model's price per million tokens as "in | out". In a NEAR Private AI
conversation, Wallet shows instead that your NEAR key pays, with
cloud.near.ai to sign up and add credit, whether a key is saved and Open
Settings, which opens Settings on NEAR; in a Local Llama conversation,
that there is nothing to pay. Neither uses the wallet.
A small deposit, at the size the provider suggests (1 USDC.e), pays for chats and is topped up by
that much when it cannot pay for the next one; Close ends it with the
provider, which
refunds what is unspent, and Withdraw asks the network to close it and,
pressed again 15 minutes later, takes it back. The deposit's state is sealed in
`~/Library/Application Support/Regents Cloak/wallet/` under the
conversations' key. The key never reaches the log, the control socket,
`cloak status` or `cloak doctor`, and no message text does either; the log
has only why a request stopped.

For testing on this Mac, `app/log.sh [minutes]` prints what the app wrote
to the Mac's log (60 minutes if not given) and the crash reports macOS has
for Cloak and its parts. The app writes "opened" with its release at
launch, each change of state (Start, Pause, a failure) and "quit" at a
clean end, so a run with no "quit" was ended some other way. These lines
carry no message text; the Mac keeps them for days, and the app's timing
lines only for a short while.

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

A new conversation can be NEAR's instead: before its first message, pick
NEAR Private AI under the message box (Anon, NEAR Private AI, Local Llama or
Agent; a new chat is Anon, Cloak's own, at each launch). Its messages then go as written, never reworded, to one
model on NEAR AI Cloud, `Qwen/Qwen3.8-27B`, paid by your own NEAR key, and
its later messages go there too. A Cloak conversation never goes to NEAR,
and a NEAR one never goes to the wallet's provider. Before a message
leaves, NEAR's hardware proof is checked: the Intel quotes of the model's
servers and Intel Trust Authority's verdict on one server's GPUs. The
helper that checks it and sends, `cloak-near` (see `guest/near`), is in
the app, started at the first check or message once its file matches its
pin. Showing a NEAR conversation runs the check; the line beside its Tor
pill says it is under way, when it passed and what it covered ("Checked 2
min ago: 1 server, 8 GPUs"), or why it stopped, with Check Again. A passed
check is used again for the Freshness chosen in Settings, and the line
says when the next message checks again. The Tor pill (off until turned
on) sends the check and the messages through Cloak's tor, NEAR's and
Intel's connections each under a name of their own made at each launch,
and needs Cloak running; off, NEAR and Intel see this Mac's internet
address. Send is off only with no NEAR key saved ("Add your NEAR key in
Settings.") or with Tor on while Cloak is not running ("Start Cloak to
send through Tor."). Limits, at the top, lists what the check does not
cover. A message that stops says why on its card, and whether it may have
reached NEAR, when sending again may be charged twice; nothing then goes
another way. The helper takes one line at a time, so an answer under way
holds later checks and messages; nothing cancels it but Quit, which ends
the helper at once. The NEAR key, typed in Settings, is kept only in the
login keychain, this Mac only, and never shown again; it is read only when
a message is sent and goes to the helper with that message alone, never to
the log or to disk. After a rebuild, the Mac asks again whether the new
build may use it. A NEAR conversation is kept like any other, marked in
the list by a chip icon.

Or pick Local Llama: the model on this Mac, the one that rewords, answers
each message itself, as you wrote it, with the conversation so far, through
llama.cpp and the model's own chat template, with no instructions added and
llama.cpp's default sampling. Nothing leaves the Mac: no wallet, no Tor, no
NEAR key, and nothing to pay. Its answers are simpler than a remote
model's. It needs only the model downloaded, not Start: while Cloak is
Paused, Ready or needs attention, the first message starts the worker by
itself, after the same checks of the Mac, the model's files and the worker
as a Start makes, and it rests after Free memory's time as in a run; while
Cloak is running, Local Llama messages wait their turn at the run's worker
with the rewording. Each answer arrives whole; while the model answers,
the chat says Working, with Stop (Command-period), and a message that
stopped or failed can be asked again. Start, Pause, Stop and Quit end the
worker an answer is on, and that message says to ask again. A chat and an
answer may take at most 19,456 tokens together, the most a rewrite has been
measured to take, with up to 4,096 tokens an answer; a chat that no longer
fits says it is too long for the model on this Mac, to start a new one, and
nothing is cut. Without the model, the chat says so and points to its
download. There is no rewording, no details, no Review and no Send Original
Text. A Local Llama conversation is kept like any other, marked in the
list by a laptop icon.

Modes, the info button beside the mode switch, opens when the pointer
rests on it or on a click. It says Anon is inspired by Vitalik's X post,
and that in NEAR Private AI and Local Llama, Cloak is an alternate client
to NEAR's and llama.cpp's own official ones. Each line links to its X
post.

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
requests and when it was last used are kept on disk, sealed in
`~/Library/Application Support/Regents Cloak/agents` under the
conversations' key. Agents' Activity shows the last 24 hours' count of chat
requests and the share answered, then the latest 20: who sent each (an app
or Cloak's own agent), the model, how many messages went reworded, whether
it is under way, answered or stopped and why, and how long it took. Once a
request's messages are reworded, its row opens a sheet with each of its
user messages' text as the app wrote it and as Cloak sent it, the newest
first, the changed words marked as in Chat; system prompts, tools, tool
results and the model's answers are not shown. Up to 200 requests are held
in memory until Cloak quits, never on disk, and only the latest 20 keep
their text. No request's text is ever logged or written to disk.

Run the app's checks (the send path with the deposit kept sealed, whether
this Mac holds the wallet, and that NEAR mode's line to its helper carries
the freshness and route chosen):

```bash
swift test --package-path app
```

Run the sender's checks against stand-ins for Tor, the provider and the
network (Rust 1.97.1, which `guest/sender/rust-toolchain.toml` names; the
guest build uses the pinned Rust image instead):

```bash
(cd guest/sender && cargo test)
```

## Release

Only the chief runs these, on this Mac. `app/release.sh` builds the app
signed with the Developer ID, has Apple notarize it, packs it in a disk
image that is signed and notarized too, and writes the update feed,
signed with the update key. It uploads nothing, and leaves the image,
`appcast.xml` and the tag in `app/build/release/`. It needs a clean tree,
the Developer ID ("Developer ID Application: Sean Brennan (367G3Z7G3J)")
and the update key (account `cloak`) in the keychain, and the notary
profile `cloak-notary`, saved once with `xcrun notarytool
store-credentials cloak-notary`. `app/publish.sh` then puts the image in
a release of `regents-ai/cloak-releases`, and the feed on that
repository's main branch. It needs `gh` signed in with the right to
write there. Each release's steps are in [docs/release.md](docs/release.md),
item 7.

```bash
app/release.sh
app/publish.sh
```

## Progress

Progress lives in [docs/plan.md](docs/plan.md).

## Rules

See [AGENTS.md](AGENTS.md). In short: one implementation, no fallbacks, no
weaker substitutes, and no claim beyond what a passed gate shows.
