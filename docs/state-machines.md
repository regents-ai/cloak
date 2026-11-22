# State machines

Every place in Cloak where something moves through stages, what those stages
are, and how the code holds them. Found in a read of every source file on
8 November 2026. Where a stage used to be implied by loose flags, timers or
the order of statements, it is now named in the code; the faults that
implication hid are listed with the checks that show them fixed. Since
19 November only the gate checks are kept (decision 15 in `docs/plan.md`);
where a fault's check was an ordinary unit check, it says so, and nothing
checks that fault now.

## 1. The worker's one request (`llama-worker/Sources/cloak-rewriter-llama/Worker.swift`, `llama-worker/Sources/CLlama/cloak_llama.cpp`)

The worker (llama.cpp, decision 8) holds two states, `idle` and
`answering`, in one enum under one lock. A request is a rewrite or a
draft's details (an `R` frame), whose steps are the order of
`cloak_engine_rewrite`, or a Local Llama chat's next answer (an `L`
frame, section 4), whose steps are the order of `cloak_engine_answer`;
each returns how it ended.

```
idle --R or L--> answering --answer written--> idle

R: request checked --> prompt rendered --> context made --> grammar made --> reading the prompt --> generating --> stop | length
   any step --> failed (template, context, grammar, prompt, generation): 500
   reading the prompt, generating --cancel--> cancelled: 499
L: conversation checked --> prompt rendered --> fits the cap? --> context made --> sampler made --> reading the prompt --> generating --> answer parsed --> stop | length
   does not fit --> too long: 413, before any context is made
   any step --> failed (template, context, sampler, prompt, generation, parse, answer): 500
   reading the prompt, generating --cancel--> cancelled: 499
```

- **request checked**: two requests for this model go on. The daemon's
  rewrite request, whose user message is the daemon's `{"texts":[...]}` with
  at least one text: the count of texts fixes the grammar's `texts` rule
  (decision 9). And Cloak's details request (decision 13), the same keys
  with the user message `{"draft":"..."}`, which decodes under Cloak's
  details grammar (`reference/details-reply.gbnf`) instead. Anything else is
  answered 400 and never reaches llama.cpp, and so is every `R` to a model
  pinned with no grammar, one that only answers Local Llama chats
  (decision 21).
- **context made**: a context of the rewrite's own, sized for the prompt and
  `max_tokens`; nothing carries over from the rewrite before.
- **grammar made**: llama.cpp's grammar sampler over the pinned grammar plus
  the `texts` rule, or over the details grammar. It fails as `grammar` if it
  does not parse (code 0).
- **reading the prompt**, in chunks of 512 tokens, then **generating**, one
  token at a time: a cancel sets a flag that llama.cpp's loop reads before
  each chunk and each token, so the rewrite stops within one chunk or one
  token and is answered 499.
- **generating**: greedy's token when the grammar allows it, otherwise
  greedy's among the tokens it allows (llama.cpp's own rejection sampling).
  The grammar allows the end of the turn only once the reply is complete,
  and fails the rewrite as `grammar` (code 1) if it ever allows no token. It
  ends with `stop` at the end of the turn, or `length` at `max_tokens`
  tokens.
- **conversation checked** (`L` only): exactly `{"messages":[...]}`, each
  message exactly `role` and `content`, an odd count, the roles alternating
  `user` and `assistant` from `user`; anything else is answered 400, and so
  is every `L` to a model whose pin has no `answers`. An `L`
  frame never takes the rewrite or details path, whatever its messages say:
  a message reading `{"texts":["a"]}` is answered as a chat message.
- **prompt rendered** (`L`): the model's own chat template over the
  conversation, with no system message, and the template settings its pin
  holds (`chat_template_context`: Qwen's `enable_thinking` off; none for
  Inkling 2 Mini, so its template's own thinking effort).
- **fits the cap** (`L`): the prompt's tokens plus 4,096, the most one
  answer takes, must fit the model's `answers.context_tokens`: 19,456 for
  both models, the largest context a rewrite has
  been measured to take (a 10,000-character message, decision 6's limit:
  2,849 prompt tokens plus the daemon's 16,384, which llama.cpp rounds up
  to 19,456; `evidence/stage3/small-lead-gguf-grammar/feasibility-20261114T052945Z.json`),
  so a chat on the model that rewords never holds more memory than a
  rewrite. A conversation that does not fit is answered 413 and nothing is
  trimmed.
- **context made** (`L`): a context of its own, sized for the prompt and
  4,096 tokens.
- **sampler made** (`L`): llama.cpp's `common_sampler` from default
  parameters, as `llama-cli` and `llama-server` use with no flags: top-k
  40, top-p 0.95, min-p 0.05, temperature 0.8, then a draw with a random
  seed, and no grammar (the pinned GGUF carries no sampling settings of its
  own). It fails as `sampler` if llama.cpp cannot build it. The rewrite's
  greedy decoding is untouched.
- **generating** (`L`): ends with `stop` at the end of the turn, or
  `length` at 4,096 tokens. Cancel, the end of the channel and a protocol
  fault stop it as they stop a rewrite.
- **answer parsed** (`L`): llama.cpp's own reader of the model's template
  (`common_chat_session`, one path for every model) takes the reply apart
  and only its answer is kept: a model's thinking is dropped. Qwen, with
  thinking off, keeps its reply but for leading white space; Inkling 2
  Mini's answer blocks are kept, joined as they came. It fails as `parse` if
  the reader throws, and as `answer` when no answer text is left, as when a
  reply reaches 4,096 tokens still thinking.
- **idle**: a cancel here is one that crossed the answer, and does nothing.
  The worker goes idle before it writes the answer, because the host sends
  its next request as soon as it has read this one.
- **End of the channel** (the host's shutdown closes it): a request in
  progress is cancelled as above and answered 499; the worker exits 0 once
  that answer is written, or at once when idle.
- **Protocol fault** (a request while not idle, an unknown or oversized
  frame, input cut inside a frame): no frame is read after it; a request in
  progress is cancelled and answered 499 the same way, then the worker exits
  2.
- **Before ready**: the worker exits 3 when the model folder is not exactly
  the pinned files, and 2 when anything else stops it loading; the app tells
  the two apart (section 9).

Checks: none since 19 November (decision 15 in [plan.md](plan.md)).

The faults below were found on the first worker, on MLX (`worker/`,
deleted on 14 November 2026 when decision 8 chose llama.cpp). The same
checks run on this worker.

Before: a busy flag (an atomic) and a run record (a cancelled flag and the
generation) under a separate lock described the same state twice. No fault
was found, but the two could briefly disagree. Now one enum sits under one
lock.

Before (found in the lead candidate's first run, 12 November): a cancel while
preparing only set a flag, read once the model had read the whole prompt.
The model library stops its prompt reading between chunks only when the
task doing it is cancelled, and nothing cancelled it. The lead read a
128 KiB prompt for 217 s, 127 s past its cancel; the rewrites queued behind
it reached the worker after their own 90-second deadlines, and so did every
later one in that boot. Check: `test_cancel_stops_the_rewrite_while_it_reads_the_prompt`
(the stand-in answered 9.4 s after the cancel before the fix). Through the
guest, `test_a_client_that_gives_up_early_in_the_longest_prompt_frees_the_real_worker`
aims a cancel at the read, but since decision 6 the longest prompt the
daemon accepts is read in under a second, so that check no longer shows
where its cancel lands.

Before (the same run, whose main boot's worker ended at exit status -11):
the worker exited as soon as its channel closed, even mid-rewrite. Exiting
ran the model library's teardown, which released the GPU command encoder the
rewrite was still writing to, and the rewrite then crashed (SIGSEGV),
leaving a crash report. Check:
`test_closing_the_channel_mid_rewrite_stops_the_rewrite_and_ends_the_worker`
(exit status -11 and no answer before the fix).

Before (12 November, the same hazard): a protocol fault exited at once,
from the frame-reading thread or the request's hand-over, even mid-rewrite,
with the same crash. Check:
`test_a_protocol_fault_mid_rewrite_stops_the_rewrite_and_ends_the_worker`,
one case per fault (exit status -11 and no answer in all four before the
fix).

## 2. The host's channel to the worker (`host/Sources/CloakHost/WorkerChannel.swift`, `host/Sources/CloakHost/Child.swift`)

```
idle --send--> running --cancel--> cancelling
 ^                |                    |
 +----answer------+--------------------+
any fault --> lost (never ends)
```

- Starting is part of creating the channel: it returns only once the worker
  has signalled ready, so no caller can forget that step. A worker that ends,
  or sends anything else, first fails the start once it has exited, with how
  it exited (`NotReady`).
- `send` writes the whole request and moves to running in one step, so a
  cancel can never land inside a request's bytes.
- `answer` waits outside the lock, so a cancel can reach the worker meanwhile.
- A cancel in any state but running does nothing.
- A channel is one worker process; lost ends that channel, not the host's
  work. Becoming lost marks the worker lost and asks it to stop (SIGTERM);
  a cancel from then on finds it lost. The relay then waits for it to exit
  (section 3) before anything takes its place, so two workers never hold the
  model at once.

The worker and tor are each a child process (`Child`) with one way to wait
for a stop:

```
asked to stop --> exited within 10 s --> stopped
              --> still running at 10 s --> killed (SIGKILL) --> exited --> stopped
```

The wait is a task group racing the process's exit against a 10-second
sleep; whichever ends first cancels the other, so nothing polls. The same
wait ends a lost worker, a worker whose channel is closed at the end of a
run, and tor.

Before (13 November, stage 5): every one of those waits had no limit, and a
lost worker was waited for under the channel's lock. A worker that ignored
being stopped hung the host for good, with the relay's queue held. No check
since 19 November.

Before (13 November): becoming lost stopped the worker without waiting, so
the new worker could load while the old one still held the model's memory.
Check: `test_a_lost_worker_has_exited_before_its_replacement_starts`.

Before: an in-flight flag and a lost flag, with a separate "wait until ready"
call. Two faults:

- **A worker gone between rewrites ended the host.** Writing the next request
  to a worker that had died while idle raised SIGPIPE and killed the host,
  instead of marking the worker lost. The host now ignores SIGPIPE, so the
  failed write is the loss. Check:
  `test_a_worker_lost_between_rewrites_fails_only_the_next_rewrite` (host exited
  with signal 13 before the fix).
- **An early cancel was lost.** See section 3; part of the fix is here.

## 3. One guest connection (`host/Sources/CloakHost/Relay.swift`)

```
token --> request header --> request body --> handed to the worker
      --> watching for the guest to leave --> answer written --> closed
```

Each step reads with a 10-second limit; any failure closes the connection
without an answer. The watch turns the guest closing its end into a cancel.

A worker lost during the connection (gone mid-rewrite, or found gone when
its request is handed over) closes it without an answer; its request is
never sent again. What the relay sends requests to is one slot:

```
serving --no request for the rest time--> resting --a request's turn--> waking
waking --ready--> serving a new worker, or --cannot start--> none
serving --loss--> replacing --lost worker exited (section 2), afterLoss decided--> serving a new worker, or none
any but replacing or waking --finish--> finished
```

While replacing, no connection is served. What follows the lost worker is
the relay's owner's to decide (`afterLoss`): `cloak-host` starts a new
worker from the same program and pinned files; the app's supervisor
(section 9) starts none, because there a lost worker is a failure. With
none, every later connection closes without an answer, with no further
tries. `finish` (the end of a run) waits out a replacement first, so it ends
the worker that replacement started.

Only the app's relays rest (`Resting`; `cloak-host`'s never does). Once no
request has been at the worker or waiting for it for the time the
supervisor gives, counted from the last answer, the relay ends the worker
as `finish` does, and the model is out of memory. The next request, in its
turn, waits while a new worker, started as the first was, loads once the
one that rested has exited, so two never hold the model at once; then it is
served. Requests behind it keep their order, and one cancelled meanwhile is
never sent. A new worker that cannot start leaves none, as above. A worker
that exits by itself, idle or not, is a loss and never a rest: the relay
tells the supervisor of each rest and wake and of every exit it did not
cause (`Change`). `finish` while resting starts nothing, and while waking
stops the load at once. A relay made with `Relay(resting:)` starts as if
its worker had rested: no worker runs until the first request wakes one.
The app's supervisor uses one for Local Llama chats while no run is up,
and, while one is, for a chat whose chosen model is not the one that
rewords (section 9). No check since 19 November.

The app's own requests (`answer(to:as:yielding:)`) take their turn with
the connections, each as one call:

```
waiting --its turn--> at the worker --answer--> finished
waiting, at the worker --its task cancelled--> cancelled
```

A details request (decision 13) gives way: the next request to arrive, the
app's or a connection's, cancels it as its task's cancel would, so a
rewrite waits behind it no longer than the worker takes to stop (one token,
or one 512-token chunk of the prompt). A rewrite never gives way, and nor
does a Local Llama request, which waits its turn as a rewrite does: a
rewrite behind it waits for its whole answer and never cancels it.

Only the app's own requests can be a Local Llama conversation (`L`). A
guest connection's request is read only when its header is `R`, and it goes
to the worker as `R` and nothing else, so nothing a guest sends reaches the
worker as `L`. No check since 19 November.

Before: the host never replaced a lost worker, so every later rewrite in
that boot failed; only a new boot recovered. The spec asks that a worker
loss stop the affected work without fallback (REF04, A09); the new worker
is the same pinned program, so it is not a fallback, and the lost call is
not retried. Checks: `test_a_lost_worker_fails_its_rewrite_and_a_new_worker_serves_the_next`,
`test_a_worker_lost_between_rewrites_fails_only_the_next_rewrite`,
`test_a_new_worker_that_cannot_start_leaves_every_later_rewrite_failing`,
`test_losing_the_real_worker_mid_rewrite_fails_that_rewrite_and_a_new_worker_serves_the_next`.

Before: the watch started before the worker had the request. A guest that
left in that window (a request larger than the pipe to the worker, or one
that waited behind another) sent its cancel to a channel that was still idle,
so it was dropped. The abandoned rewrite ran to its end, and the next rewrite
waited behind it until the daemon's 90-second deadline failed it too. Now
the watch starts once the worker has the request; a guest that left earlier
is seen at once, because its socket is already readable. Check:
`test_a_client_that_gives_up_before_the_worker_has_its_request_cancels_it`
(no cancel reached the worker and the next rewrite failed before the fix).

## 4. The frames between host and worker (both sides)

```
worker: Y once, then for each request: R or L in, A out; C may come in
        between; the end of input, or a frame it cannot take, ends the
        worker, after the A it owes
```

- `R` carries a rewrite or a draft's details; `L` carries a Local Llama
  chat's conversation (section 1). Only the app sends `L`; the relay
  forwards a guest's request only as `R` (section 3).

- A cancel may cross the answer and arrive when the worker is idle; both
  sides treat that as nothing.
- The fake worker in `tests/fake_worker.py` follows the same rules. Before,
  it treated every frame as a request, so a crossing cancel would have
  crashed it. It also ran as a pair of processes (uv and Python), so "the
  worker is gone" could not be shown with it: the checks now start it as the
  host's own child, as the real worker is.

## 5. The host's life and the secret boot files (`host/Sources/cloak-host/main.swift`, `host/Sources/CloakHost/Guest.swift`)

Since stage 5, `host/` is a library, `CloakHost` (tor, the worker's
channel, the relay and the guest), with `cloak-host` a thin command over
it, whose command line, output and exit statuses are unchanged; the app's
supervisor (section 9) uses the same library.

```
worker ready --> guest checked --> waiting for tor --> boot files written --> guest starting
             --> boot files removed --> listening --> guest stopped --> worker finished --> Tor stopped
waiting for tor --> tor's SOCKS port never opened --> tor stopped --> failed
```

The boot files carry the per-boot channel token and rewriter key, and,
in the app when its owner's Cover setting is off as they are written, a
cover list with no URLs laid over the image's (`/etc/cloak/cover.json`),
the daemon's own cleared setting, so no cover worker starts in that guest
(section 9); `cloak-host` never lays one. A guest given a payment disk
(`cloak-host --disk`; the app gives none yet) has its image attached as its
only disk, and its boot files also carry the disk's key, readable by the
guest's root alone and removed there once the disk is open, and, for a new
image, the mark that has the guest make the disk (section 6c). The host
takes the image's path and the key from its caller; it makes neither.
"Worker finished" closes the worker's channel and waits for it to exit; a
busy worker first stops its rewrite (section 1), so the rewrite in progress
fails and is not sent again. "Worker finished" and "Tor stopped" each wait
at most 10 seconds before killing it (section 2). "Waiting for tor" is one wait, with one limit
of 90 seconds from tor's start, for both of tor's lines (section 7a): its
SOCKS port open, then its bootstrap. It ends when tor says it has
bootstrapped, when it exits, or at the limit, when the host stops it. If
tor's SOCKS port has not opened by then, the host fails there, with tor
stopped. Otherwise the guest starts, so no task starts before tor can
carry it; after an exit or the limit every Tor connection from the guest
fails (section 7a). Every way the host ends after the wait, a failure
included, stops tor. tor's folder is never removed: its state stays for
the next start (section 7a). The secret boot files are written only after
the wait.

Before (12 November, after the bootstrap wait): the wait for tor's SOCKS
port line had no limit, and only the bootstrap wait after it had one, so a
tor that hung before opening its port hung the host. Check:
`test_a_tor_that_never_opens_its_port_is_stopped_at_the_limit_and_the_host_fails`
(`tests/test_tor_path.py`; the host still waited at the check's 300-second
limit before the fix).

Before (12 November): the host waited only for tor's SOCKS port, and tor
refuses every request until it has bootstrapped (about 9 seconds), so a
task in a boot's first seconds stopped at its Tor route. Check:
`test_a_task_started_with_the_host_passes_its_tor_route_once_tor_has_bootstrapped`
(`tests/test_tor_path.py`; the task stopped at its Tor route before the
fix).

Before: they were written before the guest's configuration was checked, so a
failed check left them on disk, and their removal was written in two places.
Today's configuration is fixed, so that failure cannot be caused from
outside; the order was still wrong. Now they are written last, just before
the start, and removed in one place when the start ends, whether it worked
or not, or straight away if writing them fails.

Limit: a host killed during the start (under a second) leaves them in its
private temporary folder, readable only by the person, with a payment
disk's key among them when it has one. The stage 5 app
writes its guests' boot files in a folder of its own instead, each guest's
in `~/Library/Application Support/Regents Cloak/control/boot/cloak-<UUID>/`,
and its supervisor removes every such `cloak-<UUID>` folder there at launch,
before anything starts, and nothing else (section 9). A host killed at any
time leaves tor running for up to about 15 seconds, until tor sees its owner
gone and exits. The stage 3 kit stops a boot over its time limit this way.

## 6. The guest's boot (`guest/image/init`, then `guest/image/boot`)

```
root copied to tmpfs --> switched root --> mounts --> vsock, entropy and disk modules --> loopback
  --> payment disk open and payer ready, when the host gives a disk (sections 6c and 6d) --> adapter ready --> Tor port ready
  --> daemon ready --> daemon checks --> workspace made --> agent cases --> power off
```

The guest has no modprobe, so the kernel loads no module by itself: the
boot loads each, after the ones it needs, and a module that does not load
powers the guest off with a line naming it.

Before: "adapter ready" was guessed by scanning the kernel's socket table
every 0.1 seconds for up to 5 seconds, so a slow boot could fail for no
reason. Now the adapter prints one line, "ready", once it listens, and the
boot waits for that line; an adapter that exits first ends the wait at once.
The Tor port and the daemon are waited for the same way. Any of them
failing to start powers the guest off with a line saying which.

A guest that serves goes on after the agent cases (decision 12):

```
door port ready --> runner ready --> sender ready --> the runner or the sender ends --> power off
```

Each of the two notes its end as one line on a pipe the boot reads. The
boot is the guest's first process, so a stopped task's orphaned bubblewrap
ends there and would interrupt a blocking open of that pipe; it is opened
for reading and writing, which never blocks, and an interrupted read is
read again.

## 6b. One agent task (`guest/runner/main.go`, `host/Sources/CloakHost/Runner.swift`, `app/Sources/CloakSupervisor/AgentTasks.swift`)

```
connected --> request read within 10 s --> conversation claimed --> folders and wrapper copy made
  --> sandbox started --> lines passed on as they come --> exited --> wrapper copy removed
  --> conversation freed --> exit sent
```

A request that does not read or check is refused as invalid, and one for a
conversation with a task under way as busy; nothing runs for either. The
host closing the connection at any point kills the sandbox and everything
in it. In the app, a pause, stop or quit ends each task under way as
stopped before the guest is stopped.

## 6a. One agent case (`guest/agent/main.go`)

```
log offset noted --> case run as agent in the sandbox, or as the payer in its home --> exited
  --> daemon log lines taken --> result printed
```

A pay case runs a command as the payer's user (1009), outside the sandbox,
in its home, the payment disk (section 6c); the checks use it to write and
read stand-ins for the payer's files. A case that cannot start, as a pay
case does when no disk is mounted, prints why as its output.

Before (12 November): the agent check also ran a route observer on the Tor
port, which refused each SOCKS connection and recorded what it read. The Tor
port is now `cloak-tor-port`, so the observer is gone; the checks' stand-in
tor (`tests/fake_tor.py`) does the same from the host, in the same steps
(greeting, password, request, refusal), recording what it read whichever
step the connection ends at. It says it has bootstrapped at once, later,
never, or exits first, as each check needs.

## 6c. The payment disk (`guest/image/pay-disk`, `guest/image/boot`, `host/Sources/CloakHost/Guest.swift`)

```
key in the boot files --> new image: first 16 MiB blank --> LUKS2 made --> opened --> ext4 made
                          --> mounted --> given to the payer --> key's file removed --> open
                      --> made before: opened --> mounted --> key's file removed --> open
any step failing --> key's file removed --> one line saying why --> power off
```

The disk is the guest's only one, `/dev/vda`: an image file on the Mac,
encrypted with LUKS2 (cryptsetup, dm-crypt, AES-XTS) under the 32 bytes
the host gives, holding one ext4 filesystem mounted at
`/var/lib/cloak-pay`, the payer's home, its own and mode 0700. Under the
disk, that folder is root's and mode 0700, so a payer whose disk is not
mounted can keep nothing anywhere; there is no other place for its files.
The key goes to cryptsetup by file, never on a command line, and its file
is removed once the disk is open or has failed to; cryptsetup hands the
volume key to dm-crypt through the kernel keyring, as a key no program can
read back.

Only "new" formats, and only an image whose first 16 MiB, where LUKS2 keeps
both copies of its header and its keyslots, are all zero; an image that
fails to open is never formatted, and nothing falls back to a folder off
the disk. A wrong key, both header copies damaged, a damaged keyslot or a
damaged filesystem stops with cryptsetup's or mount's own reason and leaves
the image unchanged. One damaged header copy is rewritten from the other
as the disk opens, cryptsetup's own repair. Checks:
`guest/image/pay-disk-check.sh` (Docker, on loop devices) and
`tests/test_pay_disk.py` (the guest).

A guest killed at any moment leaves a disk that opens with every payment
file written before the kill, by three things in turn. The filesystem is
mounted `sync` (`guest/image/pay-disk`), so each write, rename and removal
is on the disk before it returns: the payer's programs write each file to
a temporary name and rename it into place, before the request it records
leaves, and the companion does so without an fsync of its own. ext4's
journal (made by `mke2fs -t ext4`) brings the filesystem back to a
consistent state at the next mount after any cut. And the host attaches the
image with `.full` synchronization (`Guest.swift`), so each flush the guest
sends, which dm-crypt passes down, is an F_FULLFSYNC of the image on the
Mac. The guest's power-off is itself a cut: the boot unmounts nothing.

The sandbox binds none of it: not the mount point, the raw disk, the
device-mapper nodes or control, nor `/sys`; it cannot make a device node;
and the key's file is gone before any case runs. Check: `tests/test_escape_path.py`.

## 6d. The payer (`guest/pay/zz_cloak_pay_linux.go`, `guest/image/boot`)

The boot starts the payer once the payment disk is open, and only then: a
guest with no disk starts none and boots as before.

```
payer's network namespace made, its loopback up --> payer's Tor port ready
  --> cloak-pay started as the payer's user --> its folder on the disk checked (0700)
  --> CONNECT proxy listening --> companion started --> companion answers (90 s)
  --> wallet read ("no note" or "a note") --> vsock port 8021 listening --> payer ready
any step failing --> the payer's log on the console --> power off
companion ends --> cloak-pay ends (status 1)
cloak-pay stopped (SIGTERM) --> companion stopped (SIGTERM, killed after 5 s) --> stopped
```

cloak-pay is the mainnet daemon (`zkapi-clientd`, pinned in
`reference/sources.json`) with its patched copies and Cloak's own files
(`guest/pay/`). Its companion is `/opt/zkapi/bin/zkapi-walletd`, the `zkapi`
program of `zkapi-walletd` built from its pins with the mainnet tree's two
companion patches and `guest/pay/companion-start.patch`, which removes the
companion's call to the service's `/health` at start: with it, a companion
that cannot reach the service stops before it starts, so a payer with no way
out could not even read its wallet; without it, whether the service takes
requests shows at the first one. Beside it, in
`/opt/zkapi/share/zkapi-clientd/proof-setup`, are the four proving keys from
the protocol's pinned `setup/v2`; cloak-pay checks them against its pinned
deployment's sha256s at every start. Both are root's and read-only in the
image; nothing is fetched at run time.

Everything the payer keeps is on the disk, in
`/var/lib/cloak-pay/.config/zkapi-clientd`, each folder 0700 and the
payer's: the companion's state under `zkapi/mainnet/<deployment>/` (its lock,
the deployment cloak-pay writes for it at the first start and checks at
each one after, the note once there is one) and the
funding records under `funding/mainnet/`. A second start on the same disk
reads that state and makes nothing again. The payer's log, which holds no
content, is `/run/cloak/pay.log`, in the guest's memory.

The payer has its own network namespace (`unshare -n`), whose loopback no
other program in the guest has: the companion listens there on
`127.0.0.1:8790`, cloak-pay's CONNECT proxy on a random port behind a
password, and the payer's own Tor port (`cloak-tor-port`, as `torport`) on
9050. The agent's sandbox and every other program are in the guest's own
namespace and reach none of the three. Each of the companion's routes also
needs the bridge token cloak-pay makes for it at each start. The companion's
only way out is the proxy, the proxy's is the payer's Tor port, and that
port's is vsock to the host's tor (section 7a). vsock is not split by
namespace, so cloak-pay's own vsock port, 8021, takes a connection from the
host (CID 2) alone.

One connection is one exchange, in the frames of `docs/zkapi-mac-side.md`,
section 1 (`serve` in `guest/pay/zz_cloak_pay.go`):

```
R that reads --> waiting for its turn (payTurns) --> its turn --> the hold (WaitSettled)
the hold, nothing unfinished --> key asked for --> A
the hold, automatic settlement under way or the wallet's settlement unfinished
  --H {"held": true}--> settling --nothing pending--> H {"held": false} --> key asked for --> A
R that does not read --> A 400, nothing sent
C, an allowed method and path --> the daemon's route, with the key and management token --> A
C, anything else --> A 404, nothing reached
V --> the wallet read --with "chain"--> the chain read at one block --> A 200
V, a read that fails --> A 502, no part of the deposit
any other first frame --> closed, no answer
host hangs up --> cancelled: out of the queue, or ended before its key is asked for
an H that cannot be written --> ended before its key is asked for
```

`C` and `V` take no turn. The allowed routes are `payRoutes`, the Mac's
sixteen, matched exactly, with no query. The management token and the
API's key are added in cloak-pay and kept only in memory; neither is in a
frame. A `V`'s wallet part is only `has_note`, `pending_request` and the
note's `note_id` and `expiry_ts`. Its chain part (`ReadChain`,
`guest/pay/zz_cloak_chain.go`) checks the RPC's network, reads the funding
address as `GET /admin/funding/address` does, which makes the payer's key
on the first read, then reads the block `eth_getBlockByNumber "latest"`
gives and every value at that block's number, over the daemon's own RPC
route through Tor. A hold that ends in an error or a hang-up sends no
`{"held": false}`.

Checks: `tests/test_pay_disk.py` (started on a new disk and again on the
state it left; none without a disk), `tests/test_pay_frames.py` (C and V
through the host, on a guest with no way out), `tests/test_escape_path.py`
(the sandbox reaches neither listener nor the payer's files, and a frame of
each kind to 8021 is not answered) and `guest/pay/check.sh` (Docker, no
network: the allowlist, the secrets, the deposit's keys, the one-block read
and the hold's frames, against stand-ins).

## 6e. One Venice request through the sender (`guest/sender/src/lib.rs`, `host/Sources/CloakHost/Sender.swift`)

Built 21 November 2026, with no caller in the app yet; the plan is
[venice.md](venice.md), Transport. In the guest:

```
connected --> turn (Y) --> request read (R) --> checked --> Tor connect as the chat's identity
  --> head handed on (L) --> body handed on as it arrives (P, zero or more) --> answer (A, ok)
request that does not read --> A stop (failed, its line and column only); nothing sent
checked: identity, origin, path, method or a header name refused --> A stop (failed); nothing sent
Tor refuses or builds no circuit --> A stop (tor_down); nothing sent
no head, or the answer breaks --> A stop (failed); the request may have reached Venice
the host stops reading --> next P write fails --> answer dropped, its Tor stream closed --> stop, which goes nowhere
180 s from connecting (REQUEST_LIMIT) --> answer dropped --> A stop (failed)
```

Checked means: `identity` is 64 hex digits; the URL's origin is exactly
`https://api.venice.ai`, with no user name or password, and its path
begins `/api/v1/`; the method is GET or POST; each header name is
`authorization`, `sign-in-with-x`, `payment-signature` or `content-type`.
No redirect is followed. The sender's destinations are now four, each
only through the guest's Tor port: the provider and Tempo's RPC for
Boundless's requests, as before; `api.venice.ai` for `venice`;
`mainnet.base.org` for `venice_funds`, on a fresh identity. `venice_sign`
and `venice_typed` reach nothing: they sign only a Venice sign-in and
only a USDC transfer on Base, and answer with one `A`.

On the Mac, `Sender.stream`:

```
connected --> Y read --> R written --> L read: head --> P read: a piece (repeated) --> A read: end --> closed
P before L, a second L, or any other frame --> failed --> closed
the sender closes before A --> failed --> closed
the stream's consumer ends it --> socket shut --> the read ends --> closed
```

No key, signature or header value reaches a stop's words or the log.
Checks in `guest/sender/tests/sender.rs`, against stand-ins for Tor,
Venice and Base: `venice_requests_leave_for_venices_api_alone_with_its_header_names`,
`the_signatures_are_the_known_vectors`,
`a_venice_answer_the_host_stops_taking_ends_its_request` and
`no_key_reaches_a_stop_or_the_log`; and
`aVeniceAnswerTheMacStopsReadingClosesItsConnection` in
`app/Tests/CloakTests/SendTests.swift`.

## 7. One request in the guest adapter (`guest/adapter/main.go`)

```
checked --> host connection --> request sent --> answer header --> reply copied
```

Go's request context carries the state: the daemon giving up closes the host
connection, which cancels the rewrite. No hidden flags; no change.

## 7a. Tor's way out (`host/Sources/CloakHost/Tor.swift`, `host/Sources/CloakHost/TorRelay.swift`, `guest/torport/main.go`)

Built 12 November to the design in [plan.md](plan.md) ("Tor out of the
guest"); the checks are `tests/test_tor_path.py`. Where the bytes go:

```
guest (no network device)                       | Mac: cloak-host              | Tor network
daemon route check, Pi under torsocks           |                              |
  --> 127.0.0.1:9050 (cloak-tor-port)           |                              |
  --> vsock port 9050 ------------------------> | Tor relay --socket file--> tor --> guard, relays, exit
a program that skips torsocks --> unreachable   |                              |
anything but a SOCKS5 greeting on 9050 -------> | closed, no byte              |
any other vsock port -------------------------> | refused                      |
```

A guest with the payment disk has a second `cloak-tor-port`, the payer's,
in the payer's own network namespace (section 6d): the companion's
connections go through cloak-pay's CONNECT proxy to it, then over vsock
port 9050 to the same relay.

tor's life, as the host's child:

```
socket folder made (new, owner-only) --> started on its lasting folder --> SOCKS socket open --> bootstrapping
  --> bootstrapped (100%) --> stopped; lasting folder kept, socket folder removed
exits before its port opens --> the host fails before the boot files are written
folder held by another tor --> its port opens, then it exits about 5 s later (exits while bootstrapping, below)
port not open 90 s after it started --> stopped by the host; the host fails before the boot files are written
bootstrapping --> every request refused at once; the host waits, and starts no guest
exits while bootstrapping --> the host stops waiting; every Tor connection fails; never restarted
not bootstrapped 90 s after it started --> stopped by the host; every Tor connection fails; never restarted
exits later --> every later Tor connection fails; never restarted
```

The host learns each step from tor's own log lines on its standard output,
read on one thread from tor's start: "Opened Socks listener connection
(ready)" and "Bootstrapped 100% (done)". It waits for both on one
semaphore with one 90-second limit from tor's start, no polling. 90 s is
the default of the Tor Project's controller library, stem, which waits for
the same line; tor itself never gives up. Checks (`tests/test_tor_path.py`):
`test_a_task_started_with_the_host_passes_its_tor_route_once_tor_has_bootstrapped`,
`test_a_tor_that_exits_while_bootstrapping_stops_the_task`,
`test_a_tor_that_never_bootstraps_is_stopped_at_the_limit_and_the_task_stops`,
`test_a_tor_that_cannot_reach_the_network_stops_the_task` and
`test_a_tor_that_never_opens_its_port_is_stopped_at_the_limit_and_the_host_fails`.

tor's folder lasts from one start to the next: the host is given it
(`--tor-data`; the stage kits use `~/Library/Application Support/Regents
Cloak/tor`), creates it owner-only if it does not exist, and never removes
it. tor keeps its state file, its entry guards and its directory cache
there, so a later start keeps the same entry guards and bootstraps from
what it saved. tor locks the folder while it runs; a second host's tor on
the same folder opens its port, waits 5 seconds, says another tor holds the
folder and exits with status 1, so that host's guest starts with tor gone
and every Tor connection fails, as after any exit. Check:
`test_a_second_start_reuses_tors_folder_and_its_state`.

Before (12 November): each start had a new folder in the host's temporary
folder, removed when tor stopped, so every boot chose new entry guards and
bootstrapped from nothing.

tor counts as stopped from its exit (its process's termination notice) or
from the host stopping it at the limit, whichever comes first. Its SOCKS
socket's name may then be another program's, so from that moment the relay
connects nothing to it, and its connections to tor still open are shut. The
check and the connection are made under one lock, together with the list of
open connections. tor's exit also removes its socket's folder, with the
socket tor leaves behind.

tor's SOCKS port is a socket file, `socks`, in a folder the host makes for
each start in the person's temporary folder (`mkdtemp`, so 0700 and new;
tor refuses a folder others can open). Nothing of tor's listens on the
network. Check:
`test_only_this_user_can_open_tors_socket_and_nothing_of_tors_listens_on_the_network`.
Before (to 14 November): it was a free port on the Mac's loopback, which
every program on the Mac, of any user, could use while tor ran.

One Tor relay connection:

```
accepted --> greeting read (10 s) --> greeting checked --> tor connected (only while tor has not stopped)
  --> greeting passed on --> tor's answers passed back --> copying both ways --> either end closes --> both closed
tor stops while copying --> both closed
any step failing, or tor stopped --> closed, without a byte from the host
```

Before (12 November, after the bootstrap wait): the relay connected to
tor's port whatever had become of tor, so after tor exited, a program that
took its freed port received the guest's Tor connections. Check, now on
the socket file: `test_a_program_that_takes_the_socket_of_a_tor_that_exited_receives_nothing`
(the listener received a connection and the SOCKS5 greeting before the
fix).

"tor's answers passed back": the relay reads tor's answer to the greeting,
to the user name and password when tor chose them, and to the request,
whose answer on a socket file carries an IPv6 address of all zeros (22
bytes) where on a network port it carries an IPv4 one (10 bytes). That
answer goes to the guest in the 10-byte form, as torsocks reads only 10;
every other answer and byte goes unchanged. Check: the TLS fetch through
torsocks in
`test_tor_carries_the_guest_and_a_program_that_skips_torsocks_reaches_nothing`
(the first socket-file design, 12 November, put 12 zero bytes before every
stream and failed it).

## 7b. One user turn's rewrite in the daemon (`guest/daemon/rewriter.patch`, `guest/daemon/server.patch`)

Cloak's input limit and deadline (decision 6 in [plan.md](plan.md)), patched
into copies of the daemon's `internal/rewriter/rewriter.go` and
`internal/server/server.go` when the guest is built:

```
turn selected --> characters counted --> over 10,000 --> refused, no call
                                     --> call sent (deadline 90 s + 20 ms a character) --> reply checked
call sent --> deadline passes --> call cancelled --> rewrite failed
```

The count is made once, when the turn is selected, and kept with it; the
call's deadline and its response-header limit are both taken from it, so
the two cannot disagree. A refused turn is its own error, which the local
API answers with status 413 and the plain message; every other failure
keeps the daemon's own answer. Before (the reference): 128 KiB counted in
bytes, refused as an ordinary rewrite failure, and a flat 90 s. Checks:
none since 19 November (decision 15 in [plan.md](plan.md)).

## 8. Files built in steps

- **Model downloads** (`scripts/fetch_model.py`): each file goes to
  `<file>.part`, is checked, then renamed; a mismatch is kept as `<file>.bad`.
  Any leftover makes the worker refuse the folder as holding extra files, so
  a broken download stops work instead of loading. A download cut short
  stops the run and keeps its `.part`; the next run asks for the rest with
  an HTTP Range request, and starts the file again when the server sends it
  whole (no check since 19 November). Before (13 November): the next run
  fetched every byte again, and a connection the server closed early left a
  short file that was set aside as `.bad`.
- **The app's model download** (section 9a): the same `<file>.part` beside
  each file, so either can continue what the other left. A partial is
  hashed again before it is continued, and one that does not match its pin
  is deleted, not kept. A file's partial goes only when it is renamed into
  place, deleted as a mismatch, or removed by Cancel; while it is there its
  file is not in place, so the start check says the model is missing, and
  the worker refuses any folder that is not exactly the pinned files.

## 9. The app's supervisor (`app/Sources/CloakSupervisor/Phase.swift`, `app/Sources/CloakSupervisor/Supervisor.swift`)

Stage 5's development build. The spec's six states (section 6) are one
enum, `Phase`; every transition is named by the event that causes it, in
`Phase.after`, and anything not listed there does not apply. The menu-bar
app and `cloak` send their commands to the same supervisor, the app through
its menu and `cloak` over the control socket.

```
launch, relaunch --> Paused
Paused, Ready, Needs attention --start--> Preparing (run)          Paused --resume--> Preparing (run)
Paused, Ready, Needs attention --verify--> Preparing (verify)
Preparing (verify) --start--> Preparing (run)
Preparing (run) --prepared--> Running
Preparing (verify) --prepared--> Stopping (to Ready)
Preparing, Running --failed(reason)--> Stopping (to Needs attention, reason)
Preparing, Running --pause, sleep--> Stopping (to Paused)
Preparing, Running --stop--> Stopping (to Ready)
Ready, Needs attention --pause--> Paused
any --quit--> Stopping (to quit) --stopped--> the app ends
Stopping (to Paused, Ready or Needs attention) --stopped--> that state
```

- **Preparing** first ends the worker up for Local Llama chats, if any,
  and waits for it to exit (below). It then takes each step only once the
  one before it is up: the checks (the Mac: Apple silicon, the memory of
  the model that rewords within Metal's graphics
  limit less 1 GiB, and all of Cloak's within the memory less 4 GiB for
  macOS, both needs from the manifest, a graphics limit that cannot be read
  failing it; each part in the bundle against its SHA-256 in the bundle's
  manifest; that model's files and sizes, whose hashes the worker checks
  itself), then the worker put where it runs,
  `worker/cloak-rewriter-llama` in the app's Application Support folder
  (its sandbox cannot start a program kept under `~/Documents` or
  `~/Downloads`): a file there that is missing or not the pinned one is
  replaced by a copy of the bundle's, written under a new name in the same
  folder and renamed over it, and the file is then checked against the pin
  (`part_missing` when it cannot be put there, `part_changed` when it does
  not match), then tor, started and bootstrapped, then the worker, started and
  ready, then the payment disk, attached with its key from the keychain
  (`PaymentDisk.attach`), then the guest, which sends one rewrite through
  the daemon, the relay and the worker and stays up, with its sender and
  payer: the check has passed once its console shows the result line,
  `check exited 0` and `sender ready`, in that order. The first failure is
  the reason. The checks all run, the `near` pin among them, so a changed
  NEAR helper stops a run that never uses it.
  A worker that exits before it is ready because the model folder is not
  exactly the pinned files (its exit status 3, section 1) is
  `model_changed`; any other is `worker_unavailable`.
- **Running** means tor is up, the worker is up or resting, that check
  passed, and the guest that made it is still up.
- **Resting**: while Running, the worker rests (section 3) once Cloak has
  reworded nothing for the time chosen as Free memory in the Settings window
  (5 minutes until chosen, 15 minutes, 1 hour, or Never, which keeps it),
  kept in the app's defaults and read each time that wait starts, so a
  change applies from then with no restart. The next request starts a new
  worker with the same program and arguments as the first. While it rests,
  the Model row says "unloaded", the Memory row's figure falls by the
  worker's, and the technical detail says the worker is resting in place of
  its process. A new worker that cannot start is
  `model_changed` or `worker_unavailable`, as at Preparing.
- **Cover**: the owner's Cover setting (`AppSettings.cover`, on until
  turned off) is read once per run, as the guest's boot files are written
  at Preparing; off, they lay a cover list with no URLs over the image's
  (section 5), and the guest's daemon starts no cover worker. The value
  read is `Supervisor.cover` from then until the shutdown starts stopping
  the run's parts, nil otherwise; the technical detail says which while
  Running. A change while
  a guest is up waits for the next Start, and Chat says so on the Cover
  toggle in its toolbar, a small clock on the symbol's corner and "Cover
  changes after Pause, then Start." at the end of its help and its
  VoiceOver hint, while the two differ.
  Nothing else in the run depends on it.
- **Watches**: from its start until the run ends, tor exiting raises
  `tor_stopped`, every worker exit the relay did not cause raises
  `worker_stopped`, and the guest ending raises `guest_failed`; a rest
  never does. The relay replaces no lost worker
  (section 3): a worker the relay loses is stopped, and its exit is the
  failure.
- **Stopping** is the one shutdown, for every destination: it cancels the
  preparation and the watches, ends the agent's tasks under way and the
  worker for Local Llama chats,
  waits for the preparation and that worker to end, then stops the guest,
  the worker and tor, in that order, each within its limit
  (section 2); a worker that rested is already gone, and one loading after a
  rest is stopped at once. An event from work being stopped (a watch seeing its part
  stopped, a late failure) does not apply, and is dropped. Each wait in
  the preparation ends when it is cancelled: tor's bootstrap, the guest's
  boot and check, and the worker's model load, whose worker is stopped
  there and then, so a pause or a quit takes effect at once in those
  steps. Three steps are not waits and run to their end first: the checks,
  the worker's copy into place, and the payment disk's key read, which
  lasts as long as a keychain question stays unanswered.
  Before (13 November): the worker's start was waited for until the model
  had loaded, so a pause or a quit during the load waited for it.
- **Needs attention** keeps its reason, and the failure's technical detail,
  until the next start. Nothing is started again, and no other route or
  model is tried (REF04).
- **Refused**: any command but quit while Stopping (`busy`); `verify`
  while starting to run or Running (`busy`); and `resume` while checking,
  Ready or Needs attention (`not_paused`). `resume` while starting to run
  or Running is accepted and changes nothing. A refused command changes
  nothing.
- **Sleep** pauses, so a wake finds no run; a worker up for Local Llama
  chats stays, and rests as ever, unless a run was up, whose shutdown ends
  it. A relaunch starts
  Paused, having started nothing, the one after an update included
  (Sparkle installs it once the app has quit through its shutdown). So does the launch at login, which is
  off unless the Settings window's Launch at login switch turns it on (a
  login item, through `SMAppService`): the app opens Paused and starts
  nothing until Start.
- **Commands**: each start keeps how it started tor and then the worker,
  each one's program and arguments read back from the process started, as
  each comes up; they stay once the run ends, and the next start begins
  them again. The Settings window's Advanced pane shows them, one line each.
- **Launch**: before anything starts, the supervisor makes its boot folder,
  `control/boot` in the app's Application Support folder, owner-only, and
  removes from it every guest's `cloak-<UUID>` folder a killed app left,
  with the channel token and rewriter key inside (section 5), and nothing
  else. If it cannot, the app says it can't open, and ends.
- **The menu's header** (`app/Sources/RegentsCloak/Menu.swift`) only reads
  the phase. Its dot is the state now: green Running, yellow Paused or
  Ready, red Needs attention, grey while Preparing or Stopping. Its line is
  the state now, in the words Details uses too: Starting through
  Preparing, Stopping through Stopping, with "model unloaded" while Running and resting and
  "downloading model" while the download is under way; the dot's tooltip
  and VoiceOver say the same word. Before (18 November): the line kept the
  last settled state's word through a start or stop, which takes 8 to 13
  seconds. Once settled in Needs attention, the reason's title and remedy
  take the line's place, beside its fix.
- **The fix for a failure** (`Fix`, `app/Sources/RegentsCloak/Fix.swift`)
  is one rule, which the menu's header, Details' reason, Chat's waiting
  row and the Wallet's Start row all read, with the download of the model
  that rewords as it last found the files (section 9a): Start Again for
  `tor_unavailable`, `tor_stopped`, `worker_unavailable`,
  `worker_stopped`, `guest_failed` and `check_failed`, and for
  `model_missing` once every file is in place; Download Model… for
  `model_missing` while some file is not; Show in Finder for
  `model_changed`, which reveals the model's folder and changes nothing in
  it; and none for `unsupported_hardware`, `part_missing` and
  `part_changed`. Details shows no button for the download, whose own
  section under the reason is its way on. Where the rule gives none, or
  gives Show in Finder, the waiting row and the Start row say the remedy
  in words. The menu's Start item is off while a start is certain to stop
  again: where the rule gives no fix, or gives the download. For
  `model_changed` it stays on, since the folder may have been put right by
  hand, which Cloak cannot see. The menu is rebuilt each time it opens,
  and while it is open whenever the phase, the rest or the download
  changes. Before (21 November): the menu held the fix alone, and read the
  reason kept from the last start without the files, so after a finished
  download it still offered Download Model…, which opened Details with
  nothing to press; Start stayed on for the three reasons with no fix;
  Details offered nothing; and Chat's waiting row and the Wallet's Start
  row offered Start for `model_changed` and every other reason. Now all
  four read the one rule.

- **Local Llama** (`Supervisor.answer`, `LocalLlama`) is no phase. A
  Local Llama chat's message goes to the model chosen for it (section 9c,
  decision 21) in an `L` frame (section 1). While Running, a message to the
  model that rewords takes its turn at the run's relay,
  in order with rewording, and never gives way (section 3); a worker
  failure then is the run's, as for any request. Every other message, and
  every one in the other settled
  phases, Paused, Ready and Needs attention, goes to a relay of the
  supervisor's own for that model (`Local`, made with `Relay(resting:)`,
  section 3); one sent while Preparing or Stopping waits for the phase to
  settle. There is one such relay at most: a message to another model than
  the one it is for ends it first (`endLocal`), and a message it had stops
  as interrupted. That
  relay's first message starts its worker: once the last local worker has
  exited, the Mac is checked for that model (`Manifest.answerCheck`: for a
  model other than the one that rewords, its memory is counted beside that
  one's, which a run keeps loaded) and the model's files are checked, the
  pinned worker is put where it runs and checked against its pin, as at
  Preparing, and the worker starts with the same program as a run's, given
  that model's name and folder, with no
  tor, no guest, no wallet and no NEAR key. It rests after Free memory's
  time, as a run's does, and the next message starts a new one. A worker
  that cannot start stops that message with its reason
  (`AnswerStop.failed`, with the same reasons as at Preparing); one that
  ends by itself stops the message it had as `worker_stopped`. Either way
  the relay is dropped, so the next message starts afresh, and the phase
  never changes: nothing here moves the app to Needs attention. A Start,
  and the shutdown, end that relay first, whatever its model, and wait for
  its worker to exit before anything else starts, so two workers never hold
  the model that rewords; a message it had stops as interrupted, and the
  chat says to ask again. While its worker is up or loading, the technical detail says
  so (`worker: process N, for Local Llama chats`), the Paused, Ready and
  Needs attention lines say only that worker runs, and the Memory row
  counts it, since it is one of the app's own processes. Nothing on this
  path makes a network request or touches the wallet, the door, NEAR or
  Tor.

What `cloak --json` prints for each phase (INS02):

| Phase | `state` | `status` | `next_action` |
|---|---|---|---|
| Paused | `paused` | `paused` | `start` |
| Preparing | `preparing` | `checking` | `wait` |
| Running | `running` | `running` | `pause` |
| Ready | `ready` | `ready` | `start` |
| Stopping | `stopping` | `paused`; `failed` or `unsupported_hardware` when it ends in Needs attention | `wait` |
| Needs attention | `needs_attention` | `unsupported_hardware` for that reason, else `failed` | `none` for `unsupported_hardware`, else `start` |

`needs_os_approval` and `needs_funding` are never printed: this build has no
step that needs the system's approval, and no payment. The reasons are
`unsupported_hardware`, `part_missing`, `part_changed`, `model_missing`,
`model_changed`, `tor_unavailable`, `tor_stopped`, `worker_unavailable`,
`worker_stopped`, `guest_failed` and `check_failed`.

The phase, supervisor, relay rest, control socket, menu header and settings
checks were deleted on 19 November (decision 15 in `docs/plan.md`); nothing
checks what they checked now.

## 9a. The models' downloads (`app/Sources/CloakSupervisor/ModelDownload.swift`)

Release plan item 7. Each model that answers Local Llama chats has a
`ModelDownload` of its own, the model that rewords among them (decision 21),
and each is the one owner of its download's state; the Details window, the
menu, the chat window and Settings' Local Llama pane only read it and press
its buttons. The downloads are independent: each fetches its own model's
files into its own folder, whatever the others are doing. Nothing downloads
until Download is pressed, and no download starts Cloak.

```
launch, refresh --> Installed when every file is in place, else Stopped
Stopped --start--> Downloading                  (not while blocked)
Downloading --every file in place--> Installed
Downloading --a file does not match its pin--> Stopped (mismatch)
Downloading, Retrying --network lost--> Waiting for network
Waiting for network --network back--> Downloading
Downloading --other failure, tries left--> Retrying --wait over--> Downloading
Downloading --other failure, no tries left--> Stopped (failed)
Downloading, Retrying, Waiting for network --pause--> Stopped (paused)
Stopped, Downloading, Retrying, Waiting for network --cancel--> Stopped, partials removed
any state --remove--> Stopped, the model's folder removed   (not the model that rewords)
```

- **What it fetches**: exactly the manifest's files for its model, each at
  its pinned size and sha256, from the one URL the manifest gives it.
  `app/manifest.py` makes that URL from `reference/models.json`'s repository
  and revision with `scripts/fetch_model.py`'s own `url`, so the script and
  the app fetch from the same place. No other source or mirror.
- **Installed** means every file is a regular file of its pinned size, as
  the start check counts it (`Checks.isInPlace`, section 9); the worker
  still checks every sha256 itself as it loads.
- **Offered**, for the model that rewords, in the Details window while some
  file is not in place, by a
  Download Model item in the menu then (the menu looks at the files again
  each time it opens), and in the chat window when the reason is
  `model_missing`. While Cloak needs attention for `model_missing`, the
  menu's header offers it as the failure's button, in the item's place,
  until every file is in place, when Start Again takes its place (`Fix`,
  section 9). Before the button, the window says the size,
  the host, and that this download goes straight from this Mac to that
  host, which sees this Mac's address, unlike Cloak's messages. Every
  model's download, that one's too, is offered in Settings' Local Llama
  pane (section 9c), whose note says the same of the host: a symbol to
  download or continue, a ring for its progress with Pause while under way,
  a symbol before the ring while it waits for the network or for its next
  try (its words, "Waiting for the network" or "Trying again", in the
  help and in what VoiceOver reads of the ring), and, for any model but
  the one that rewords, Remove. The pane reads every model's files and the
  free space again as it shows, as its window comes back to the front and
  as any model's download changes stage, and Download reads them again at
  its press.
- **Blocked**: Download and Continue are disabled, with the reason beside
  them, only when the download is certain to fail: this Mac fails the
  model's Mac check (`Manifest.answerCheck`, section 9), or the models
  folder's volume has less free than the bytes still to fetch plus 1 GiB.
  Free space that cannot be read blocks nothing. In the Local Llama pane,
  a model this Mac can't run has its row dimmed, its help saying why, in
  place of the words beside the button.
- **One file at a time**, in the manifest's order. Each streams into
  `<file>.part` beside its place with a running sha256. At its pinned size
  its size and sha256 are compared with the pin, and only a match is synced
  to disk and renamed into place. More bytes than the pin, or another hash,
  deletes the partial and stops as a mismatch; it is never tried again by
  itself, and the next Download fetches that file from its first byte.
- **Resume**: a partial left by a pause, a quit, a crash or a lost
  connection is hashed again from its first byte, then continued with
  `Range: bytes=<size>-`. A 206 must start where the partial ends; a 200 is
  the whole file, and the partial starts over; anything else ends the try.
- **Network**: the system's path (`NWPathMonitor`) is followed while the
  download is under way. A path going down stops the transfer and waits; a
  path coming back continues by itself, so a sleep and a wake are a loss
  and a return. A try that fails as a lost connection does while no path is
  up waits too. Neither counts as a failed try.
- **Tries**: any other failure (an error status, a system error, a
  connection cut short while a path is up, a partial that cannot be
  written) waits 2, 4, then 8 seconds before the next try, then stops as
  failed, with how the last try failed, until Continue. A try that added
  bytes starts the count again.
- **Pause** stops the transfer and keeps the partial. **Cancel**, once
  confirmed, stops it and removes the partials of the files not in place;
  files in place stay. **Remove**, once confirmed, and never for the model
  that rewords, which every Start needs, stops it and removes the model's
  folder, files in place and partials alike. Each waits for the work before
  it to end, so only one piece of work touches the files at a time.
  **Quit** ends the transfer with the app; the partial stays, and the next
  launch opens Stopped and fetches nothing until asked.

The download's checks were deleted on 19 November (decision 15 in
`docs/plan.md`); nothing checks what they checked now.

## 9b. NEAR mode (`app/Sources/CloakChat/Near.swift`, `app/Sources/RegentsCloak/NearMode.swift`)

A conversation whose first message went to NEAR (`Conversation.near`, true
from that message on and absent otherwise) sends each message as written
to NEAR AI Cloud through `cloak-near`, the helper in the app's bundle
(`guest/near/README.md`, "The helper"). It never goes to V's or Token
Inference's provider, and a V or Token Inference conversation never goes
to NEAR. What a new conversation is, is the mode picked under the message
box (`Chat.kind`, in memory only, V at each launch): one of four, V (paid
through zkAPI, section 9d), Token Inference (paid from the Tempo wallet;
`Conversation.token`, true from its first message on), NEAR Private AI
(this one) or Local Llama (section 9c). A saved conversation with none of
the three marks is V's. In V and Token Inference, a switch, Agent, makes
each message a task (`Chat.agentOn`, in memory only, off at each launch).
A conversation with no turn yet is the agent's while Agent is on and its
mode has one (`Kind.hasAgent`), and after that as its first turn is
(`Chat.isAgent`). The switch shows only while one of those two modes is
picked, and a change of mode leaves it as it is.

The helper's life is owned by the `Near` actor, which runs on a serial
queue of its own and blocks on the helper's pipes with no suspension
point, so lines go one at a time, in the order they came:

```
not started --first check or message, file matches its pin--> running
not started --file does not match, or cannot start--> not started (stop `helper`, nothing sent)
running --line written, answer line read--> running
running --write fails--> not started (stop `ended`, nothing sent)
running --output ends before the answer--> not started (stop `ended`; may be sent for a message)
running --answer line does not read--> not started (stop `helper`; may be sent for a message)
running --Quit--> ended (`stop()`, from any thread, a line under way or not)
```

A line that stopped is never written again; the next check or Send starts
a new helper as the first did, after the pin check. The key is read from
the keychain only as a message's line is built, and one that cannot be
read stops it with nothing written. `sent` is the helper's for its own
stops and the app's for its own: false while the helper never had the
whole line, true once it may have sent the request.

The check mark beside the Tor pill (`NearMode`) is one of: Tor needs
Cloak running (Tor on and no socket: `Supervisor.torSocket` is non-nil
only while Running); checking (`checking`, from when the checks under way
began until the last ends: a spinner and a timer); passed (`proof`: a
shield and its age, with when it passed and what it covered as help, and
"Next message checks again." added, the shield grey, once it is older
than the freshness chosen); or stopped (`checkStop`, its words, with
Check Again). A check
runs whenever a NEAR conversation is shown and whenever its route changes
(`.task(id:)` on `NearMode.route`: direct, or tor with its socket and the
launch's two names). A message that is answered sets `proof` to the check
it went on; one that stops where the helper keeps no check (`fetch`,
`refused`, `pin`, `reply`, `helper`, `ended`) clears `proof` and sets
`checkStop`.

A NEAR message card is written and sent at once (`Chat.submit`), then
answered or stopped (`NearMode.sendStop`, with whether it may have reached
NEAR): read off `Turn.answer`, `Chat.sending[turn]` and
`NearMode.sendStop`, as section 10's message card is. Send is off only
with no key kept (`NearMode.hasKey` false) or with Tor on while Cloak is
not running; every other press reaches the helper, behind any line under
way.

An answered message keeps, with its answer, the tokens NEAR counted for it
(`Turn.tokens`, read by `Near.ask` from the reply's `usage`:
`prompt_tokens` in, the message with the chat before it; `completion_tokens`
out, the answer), sealed with the conversation as its other fields are. A
reply with no `usage` that reads gives none, which stops nothing; no other
mode's turn has any. A later answer to the same turn replaces both. The
answer's mark (a numbered circle beside Answer) says them as its help; in
Wallet, one Tokens row says the conversation's totals
(`Conversation.tokens`), absent while no answer has counts. Counts only:
Cloak knows no NEAR price. Nothing sent to NEAR changes for this.

`app/Tests/CloakTests/NearTests.swift` checks that the `ask` line carries
exactly the freshness chosen, in seconds, and the route chosen, against a
stand-in helper pinned as the real one is. Nothing else here is under
test.

## 9c. A Local Llama chat (`app/Sources/RegentsCloak/Chat.swift`, `app/Sources/CloakSupervisor/Supervisor.swift`)

A conversation whose first message went to a model on this Mac
(`Conversation.llama`, true from that message on and absent otherwise, so
older saved chats read as before) asks each message as written, with the
conversation so far: each earlier message that has an answer, then that
answer, then the message asked. One answer at a time in a conversation:

```
written --Ask--> answering (Chat.answering[conversation]) --answer--> answered (Turn.answer)
answering --Stop, or ⌘.--> stopped
answering --a Start, Pause, Stop or quit ends the worker--> interrupted
answering --conversation and answer do not fit (413)--> too long
answering --worker cannot start, or ends--> failed (reason)
stopped, interrupted, failed --Ask Again, on the newest message--> answering
```

How each ended is `Chat.answerStops[turn]`, in memory only; a message saved
without an answer shows "Not answered" after a relaunch. Too long offers no
Ask Again, since it is certain to stop again: the chat says to start a new
one.

Each message goes to the model chosen in Settings' Local Llama pane
(`AppSettings.answerModel`, decision 21), read as the message is asked:
nil, the default and what Restore Defaults puts back, is the model that
rewords. The pane is listed only while another model fits this Mac or one
is chosen; its rows are the manifest's models that answer, smallest first,
with "Best for this Mac" under the last that fits. No other model ever
answers in the chosen one's place. Ask, and Ask Again, are off only where
asking is certain to stop (`Chat.llamaBlock`), with a line saying why and a
button to where it is fixed:

- the name chosen is not a model this release has: "Choose a model in
  Settings.", with Choose Model…, which opens the pane;
- this Mac fails the model's Mac check (`ModelDownload.fits`): "This Mac
  can't run the chosen model.", with Choose Model… for a model other than
  the one that rewords, and no button for that one, which no choice
  fixes;
- the model is not on this Mac (`ModelDownload.state` not installed):
  "Download the model to ask.", with Download Model… (Downloading Model…
  while it is under way), which opens Details for the model that rewords
  and the pane for another.

Cloak need not be running. There is no rewording, no details row, no
Review, no Send Original Text and no Tor switch. No deadline. No
check.

## 9d. V's payer, seen from the Mac (`app/Sources/CloakChat/Payer.swift`, `app/Sources/CloakChat/PayQueue.swift`, `app/Sources/CloakChat/Pay.swift`, `host/Sources/CloakHost/Pay.swift`, `app/Sources/RegentsCloak/VWallet.swift`)

V's money is owned by the payer in the guest (`guest/pay`, as user `pay`
on the payment disk, section 6c). The Mac holds a mirror (`Payer`), read
fresh each time; the frames, the routes and their bodies are in
`docs/zkapi-mac-side.md`, section 1. Its one named value, `Payer.state`,
is computed from one read and never stored:

| State | From the last read |
|---|---|
| `unread` | Cloak is not Running, or nothing read yet |
| `none` | no note in the wallet, funding and withdrawal at rest |
| `depositing(stage)` | funding phase `approval_pending`, `deposit_pending` or `confirming`, at stage `pending`, `fee_wait`, `finalizing` or `activating` |
| `withdrawing(phase)` | withdrawal phase `quoted`, `waiting_funds`, `withdrawal_pending` or `confirming`, or `waiting_settlement` with a saved destination |
| `taken` | a note in the wallet that the chain shows `closed` |
| `settling` | the wallet's `pending_request`, while no request of the Mac's is out |
| `ready` | a note, none of the above |
| `failed(fault)` | any phase or stage not named above |

The funding phase is checked first, then the withdrawal phase, then the
note. A state the Mac does not know is `failed`, and no follow call is
made for it.

One read (`refresh`) is a `V` with the chain, then `GET` of the funding
address, the withdrawal and the return, then the follow calls the read
allows, each with only what the payer saved: the deposit's amount while
funding is `deposit_pending` or `confirming`; the withdrawal's
destination and note while it is `withdrawal_pending` or `confirming`;
the send while the return is `return_pending`. A follow call never signs.
`follow` reads at once and again every 10 seconds while the state is
`depositing`, `withdrawing` or `settling`, a send is under way, or a
quote is under review and has not expired, one round at a time, in one
loop. Where the reads are is one value, `Payer.reads`:

```
idle --follow--> reading
reading --round ends, a read asked for meanwhile--> reading, at once
reading --round ends, still moving--> waiting (one Task.sleep of 10 s, in its own task, the nap)
reading --round ends, at rest--> idle
waiting --10 s, or follow, which cancels the nap--> reading
```

It runs at each change between Running and not, when the Wallet sheet
opens, on its Refresh, after each quote and each approve, on a read's
Try Again, and after each V Send or task. A call while a round is out
reads again as soon as that round ends; a call while the loop waits cuts
the wait short. A read that fails keeps `readStop`, clears the chain
read, and blocks nothing. Its row in the sheet says why, with Try Again
(a spinner in its place while a round is out), and stays until a read
works; Dismiss clears only a press's stop. While nothing has been read,
the sheet shows a spinner until a read stops.

A round's reads, and each of its follow calls, land only if no approve
was answered while they were out (`Payer.approved` counts the approves
answered). What they read may be older than what the approve set, so
they are dropped, and the read the approve asks for, which starts as
soon as the round ends, reads afresh. Reads and approves cannot be put in
order by waiting, since an approve is never held back and may take 11
minutes, and the payer's answers carry nothing to compare; the order in
which they land on the Mac is the sound one.

Beside the state, the expiry has a band (`Payer.band(at:)`): `far`;
`near`, within 10 days of it (`Payer.warning`); `due`, past it, when
anyone may send the deposit to the service's operator. The expiry is the
wallet's, or, while Cloak is paused, the one kept on the Mac
(`AppSettings.depositExpires`, written when the read one changes and
cleared when there is no note). The Wallet button in Chat's toolbar wears
a mark, orange while `near` and red once `due`, with the words as its
help.

Every money press goes through a review:

```
press (Deposit with an amount, Withdraw, Send Out with an address)
  --quote, a C frame--> review shown (Payer.review: the quote, its fee and how long it holds)
review --the review's button, quote unexpired--> approve, a C frame within 660 s --> following
review --the review's button, quote expired--> quoted again and shown, nothing approved
review --Cancel--> nothing approved
```

`Payer.confirm` is the only place an approve is sent from, and only for
the quote the review shows. Withdraw's destination is always the funding
address itself (decision 23a). Each press is sent; `working` counts
those under way, shown as a spinner, and blocks nothing. A press that
stops keeps why as one value, `Payer.stop`, set where the stop is
recorded, so its words are about it alone: `quote` (nothing was sent),
`approve` (a transaction may have been sent), or `unread` (Withdraw
pressed before the deposit was read: nothing was asked; its row carries
Try Again, and the next read clears it). Each press clears the last
stop, and Dismiss clears it. A button is off only where the chain,
read at the latest block, shows it certain to fail, with a few words
beside it: Deposit while the vault is paused or a note is `active`;
Withdraw while paused or no note is `active`; Send Out while the address
holds no ETH; the review's button while paused, or while the address
holds less than the quote needs (the total for a deposit, the fee for a
withdrawal). Return in the Amount box does what Deposit does, so nothing
while Deposit is off.

A V chat request (`Payer.send`, then `PayQueue.complete`) goes to the
model the owner picked in Wallet (`AppSettings.vModel`) while the service
lists it, otherwise to the listed model whose requests cost least at
most, the first such in the list. Send and Run in V are off only while
Cloak is not Running or the chain shows the deposit closed
(`Chat.Block`, `.closed`); with no deposit the request goes and the
payer answers 402, shown as "Deposit to send." or "Deposit to run." with
Wallet….

The queue (`PayQueue`) gives each chat request its turn: one `R` out at a
time; every waiting `owner` request (Chat's Send) before any waiting
`door` request (a V task's model requests and other apps', through the
door), in arrival order within each; a request out is never cancelled for
another. A request cancelled while it waits leaves the queue; one
cancelled while out closes its connection. One exchange:

```
sent --A--> answered
sent --{"held": true}--> held (PayQueue.held)
held --{"held": false}--> sending
held --180 s (PayLimit.hold)--> hung up: held too long, nothing sent or spent
sent, sending --600 s (PayLimit.answer)--> hung up: may have been charged
any --connection ends--> ended (unreachable if it ended while held)
any --caller cancelled--> hung up: cancelled
```

`C` and `V` frames never wait for a turn: 60 seconds for a read, quote
or follow call, 660 for an approve.

Checked by `app/Tests/CloakTests/PayTests.swift`, against a stand-in payer
on a socket pair: opening, reading and following send no quote and no
approve, and a follow sends only the saved body; an approve is sent only
by `confirm`, and an expired quote is quoted again instead; two presses
send two requests; one request is out at a time and the owner's go
first; a request out is not cut for another; a hold that goes quiet ends
at its limit with nothing sent; a phase the Mac does not know makes no
call; an `R` frame carries only the identity and the reworded body; a
rewording that stops sends no request through the door, and an app that
leaves before its request is sent is not charged, either way it is paid;
an approve's stop stays an approve's though a quote was pressed while it
was out; a call to
read now reads as soon as the round out ends and cuts the 10-second wait
short, one round at a time; and a round's read begun before an approve's
answer does not land over it.

## 9e. Darkbloom (`app/Sources/RegentsCloak/DarkbloomClient.swift`, `app/Sources/RegentsCloak/DarkbloomMode.swift`)

The Darkbloom window (`DarkbloomView`) shows one value,
`DarkbloomMode.state`, read from what Cloak holds in memory and never
stores: what it found of Darkbloom's runtime (`Runtime`), the control
service's last report (`snapshot`), Darkbloom's launchd job and route
(`setup`, read again with each report), and what the person's last press
led to (`failure`, `starting`, `asked`). Nothing runs until the window
first opens, Darkbloom is followed only while it is open (`open()`,
`close()`), and whatever Darkbloom serves goes on after it closes or Cloak
quits, as Darkbloom's own launchd job. Below macOS 27 the state is
`unsupported` and nothing runs.

The runtime, as Cloak finds it (`Darkbloom.find`: the file, its signature,
its release, the flags `start --help` lists, then whether the service in
`connection.json` answers for that release):

```
looking --no command line--> missing (Install)
looking --signature, release or report refused--> refused (Try Again)
looking --installed, no service answering for this release--> offline (Connect)
looking --service answers--> connected
missing --Install--> installing (steps 1 to 5) --ends well--> connecting
installing --installer fails--> missing, with its failure
installing --window closes--> installer stopped; looked for again at the next open
offline --Connect--> connecting (desktop ensure, then find again)
connecting --service answers--> connected
connecting --desktop ensure fails--> refused
connected --report stream breaks--> connecting --5 s, connection.json read again--> connected
connected --report from another release--> offline
connecting --no connection.json--> offline
```

Each report stream ends after Darkbloom's 30 snapshots and is opened again
at once. While connected, `state` is the first of these that holds:

```
a press failed                                  -> failed (its words; Darkbloom's reason in the note)
Cloak's Start under way (darkbloom start)       -> loading
a stop under way, or the service draining       -> stopping
the offered model downloading                   -> downloading (progress)
starting                                        -> loading
running: Only me's address listens, or a model serves loaded -> serving, else loading
stopped, Only me's job running                  -> loading
stopped                                         -> stopped with the model on this Mac, else no model
stale                                           -> failed (Status out of date)
any other report                                -> failed (Unknown state)
```

Stop applies, not Start, while Darkbloom serves or is set to (`isOn`: a
report of starting, running, draining or stale, or the job loaded). Start
is off only where it is certain to fail (`startBlock`), with its words
beside it: Not connected, Needs a newer Darkbloom (a flag Start passes is
not in `start --help`), No model fits, Model list unavailable, Download
first. Start runs `darkbloom start` with `--local` or, while Serve Network
is on, `--me-first`, and `--route this-mac --bind 127.0.0.1 --model <id>`;
it asks first when it would change a setup made outside Cloak (`changes`:
serving the network alone, an address open beyond this Mac, a route other
than this-mac). Stop, Download, Cancel (asked first) and Remove (asked
first, off while the model is loaded or serving) are actions sent to the
control service; each is followed by its id in the reports until it ends,
and one that ends failed or interrupted becomes the failure.

Serve Network (`alsoServe`, read from the job when the window opens):

```
off --switch on, not linked--> linking (code and page from Darkbloom; Continue in Browser)
linking --link succeeds--> on; Start again if Darkbloom serves
linking --link fails or is refused--> off
linking --switch off--> link cancelled, off
off <--switch--> on, linked: Start again if Darkbloom serves (asked first when it changes a setup made outside Cloak)
```

The switch is off with "Needs a newer Darkbloom" while `start --help`
doesn't list `--me-first`. The key is read from the service only for Show
Key or Copy Key and is forgotten when the window closes. A program Cloak
runs ends when it ends, heard from its own termination handler, and one
whose reader goes away first is stopped with all it started (its process
group), as Darkbloom's own app stops its installer. Nothing here is under
test.

## 10. Stages still implied (found 15 November 2026)

A second read, of everything built since section 9: the chat window, the
wallet, the door, the agent and the guest's sender. In each place below
the stage is not one named value; it is read off several fields. One fault
was found and fixed. The rest are listed so the next change to each names
its stages first.

- **One message card** (`app/Sources/RegentsCloak/Chat.swift`,
  `app/Sources/CloakChat/Conversation.swift`). Written, being reworded,
  reworded and open, sending, answered: read off `Turn.reworded`,
  `Turn.answer`, `Chat.rewording`, `Chat.sending[turn]` (with a count of
  presses), `Chat.opened`, `Chat.stops[conversation]` and
  `Chat.sendStops[turn]`. Each press of Send is sent
  (the Chat rule), so two presses pay twice and the second answer takes
  the first one's place. A message goes as written by one of two paths
  (decision 11): with Never reword ticked (`AppSettings.neverReword`), a
  written message is added without a reworded text and sent at once,
  never passing through being reworded; or Send Original Text on a
  reworded, open card drops its reworded text and sends it. Either way
  `Turn.reworded` is nil from then on. Send Original Text is sent on each
  press as Send is, so a press of it while the reworded text is still
  sending pays twice, and the turn is kept as sent as written. With Review
  off (`AppSettings.review`) at the press, a new message's rewording that
  finishes sends the turn at once, as a press of Send would, through the
  same checks: one that cannot go stays reworded and open, saying why, so
  "reworded and open" is skipped only when the send can start. Whether it
  goes is decided at the press and carried in the rewording
  (`Chat.Asked.new`'s `sends`). A card's
  Reword only rewords: its turn stays reworded and open, Review on or
  off. Review and Never reword are never both on: turning either on turns
  the other off (`AppSettings`). Why a turn's last send stopped is kept
  with the turn until its next press (`Chat.sendStops`, in memory only),
  a NEAR conversation's among them (section 9b); Dismiss hides its row
  only. A shrunk card with no answer whose last send stopped where the
  message may have gone, as that stop's own words say
  (`SendStop.Reason.mayHaveGone`), is marked "May have been sent", not
  "Not sent". A NEAR conversation's card is never reworded.
- **The one rewording** (`Chat.rewording`, `Chat.stops`). One at a time in
  all chats, since one model on this Mac rewords, and its chat's alone:
  only the cards of the chat it is in stay shut while it runs. A
  rewording that stops is kept with its conversation until dismissed or
  that conversation's next rewording: a card's own Reword says so on that
  card; a new message says so over the box, and its box as written, picks
  and all, goes back into the box only once its conversation is shown,
  after what the box holds then, if anything, so nothing in it is lost.
  Another V or Token Inference chat that would reword says so over its
  box, with Cancel, which cancels that rewording; NEAR, Local Llama and
  agent chats, and Never reword, are never held back, and New stays on.
  A first message's mode is the one chosen at its press while its chat is
  still empty. Before (21 November): the rewording, its stop and the
  message given back were the window's: while any chat reworded, every
  chat's box, New and a shrunk card's press were off with no reason
  shown; its stop and its message landed in whichever chat was showing
  when it ended, a NEAR chat included, where Return sends as written; and
  Review was read as it ended, so ticking Never reword meanwhile sent the
  reworded text with no press. Now each is its chat's, and the press
  decides.
- **One conversation on disk** (`Chat.update`, `Chat.unsaved`). Saved, each
  change sealed and written, or in memory only: a conversation changed
  while Saved chats is off (`AppSettings.savedChats`) joins `unsaved`, and
  nothing of it is written again until Cloak quits, even once the setting
  is on again; Delete takes it out and removes its file if it has one. A
  file written before stays as it was. Turning the setting off deletes
  nothing.
- **One task card** (`app/Sources/CloakChat/Agent.swift`,
  `app/Sources/RegentsCloak/ChatView.swift`). Running, reworded, stepping,
  answered, ended: read off `Agent.runs[conversation]`, `Agent.ran`,
  `Agent.ends[turn]` (in memory only), `Turn.reworded`, `Turn.steps` and
  `Turn.answer`. `Turn.steps == nil` is also what makes a turn a message
  and not a task, and `Turn.reworded == nil` means "goes as written" for a
  message and "not reworded yet" for a task. A task is under way from its
  press (`Agent.run`): its model comes first, inside the run, which for a
  V task means reading V's models through the payer; only then is the
  door's pass asked for and the task run in the guest. A Stop meanwhile
  ends it as stopped, and it never runs; a model that cannot be had ends
  it with why; Run shows as Stop from the press, so a second task in the
  chat cannot be pressed. Before (21 November): a V task's model was read
  before the run began, during which its card did not show, Run stayed
  on, and a second Run was dropped unseen. Now the card shows running
  from the press. `AgentTests.swift` checks that a task stopped, or whose
  model could not be had, before it runs is never run, and that a second
  run meanwhile is refused.
- **The draft's details** (`Chat.picks`, `askingDetails`, `detailsAsk`).
  Resting, asking, shown, fixed.
- **Token Inference's wallet** (`app/Sources/RegentsCloak/Wallet.swift`).
  V's is the payer's, with its own named state (section 9d). Whether this
  Mac holds Token Inference's is one value, `WalletPresence` in
  `app/Sources/CloakChat/Remote.swift`: looking, unreadable, absent,
  creating, held. Its reads are still off `look`, `working`, `stop` and
  `readStop`. Two reads under way are not ordered, so the older may land
  last.
- **The deposit** (`guest/sender/src/lib.rs`, `app/Sources/CloakChat/Remote.swift`).
  None, held, spent, close asked for, gone: off the sealed file's
  presence, `deposit > cumulative_amount`, and the network's `deposit` and
  `close_requested_at`. Whether its opening landed is the network's to
  say: Cloak does not read `opened`. A deposit is forgotten once the
  network shows none, unless the toolkit still marks it as opening
  (`pendingOpen`): an opening can land up to 25 seconds after it is signed
  (mpp 0.20.0, `src/client/tempo/session/channel_ops.rs`, line 38), and a
  record forgotten in that time would leave funds in a channel the Mac
  does not know. That one is the toolkit's to forget, when it next pays.
- **The door** (`app/Sources/CloakDoor/Door.swift`). `state` (closed,
  open, refused) beside `listener`, `access`, `boxes` and `serving`; there
  is no "opening". How a request is paid is set by its pass: an app's
  always through V's payer (`Payment.zkapi`, rank `door` in the queue,
  section 9d), and a box's as its task's chat pays, through the payer for
  a V task and from the Tempo wallet for a Token Inference one. The app opens and closes it in turn, each after the
  last has ended (`AppDelegate.turnDoor`), as Cloak starts and stops and
  at Agents' Try Again, so the two do not cross. A listener that fails after opening leaves the box
  passes in place until the next close. Each chat request it takes past
  the pass is listed (`requests`, newest first, at most 200, in memory
  only until Cloak quits) with one named stage: rewording, sending,
  answered, stopped with the words it was answered with, or left (its app
  went before its answer, with whether it was paid for; section 11, "One
  door connection"). `route` lists it, `prepare` notes the model once the
  request is read and moves it to sending once every user message is
  reworded, so it shows as rewording while the provider's list of models
  is asked for too, and `routing` ends it. One that
  falls off the end of the list while under way is no longer updated.
  Its texts (`AgentRequest.messages`: each user message with text, as
  written and as sent) are filled once, when the move to sending is noted,
  and only while the request is among the newest 20 (`Door.latest`, the
  ones the Agents window shows); each new request empties the one it
  pushes to 21st. So a request that stops before every message is
  reworded has none, one that stops after keeps them, and one pushed out
  of the newest 20 while still rewording never gets them. Never on disk
  or in the log.
- **What the door remembers of one app** (`app/Sources/CloakDoor/Asked.swift`).
  The identity and digests are kept before the rewording and the
  transcript after it, so a rewording that stops, or two requests from one
  app at once, leave them describing different requests. Each transcript
  entry carries its own digest, so no message is replayed wrongly or sent
  as written; at worst a message is reworded a second time.
- **The supervisor's parts** (`Supervisor.Stack`, `preparation`,
  `quitting`). Five optionals filled in order beside the named phase;
  every reader checks the phase first.
- **The startup check's console** (`app/Sources/CloakSupervisor/Verification.swift`).
  "check exited" then "sender ready", by the order of two lines.
- **A guest** (`host/Sources/CloakHost/Guest.swift`). Made, prepared,
  started, ended: off `machine`, `relays` and `ended`. The supervisor
  always prepares before it starts.

Before (15 November): the wallet had one "what stopped" for every request,
and any request that worked cleared it. Close and Withdraw each read the
wallet again when they end, so a Close or Withdraw that stopped showed its
reason only until that read came back. Now what a press stopped on stays
until the next press or until it is dismissed, and a read keeps its own.
No check: the wallet's screen is not under test.

Before (17 November): the sender took a kept deposit with `opened` false
for one whose opening might not have landed. It showed it from the record
alone, as pending, without asking the network; the app turned Send off
for it when the balance was under one deposit; and the sender stopped
such a send for want of funds before the toolkit could recover it. The
toolkit never keeps a deposit that way: one about to open is kept with
`opened` true and the challenge it answers in `pendingOpen` (mpp 0.20.0,
`src/client/tempo/session/mod.rs`, lines 4306 to 4325 and 1334 to 1349,
and `channel_ops.rs`, line 1183), and was already shown as the network
showed it. Now `opened` is not read. Every kept deposit is shown as the
network shows its channel: held once its opening landed, and gone, so
forgotten, while the network shows none, except one the toolkit still
marks as opening, which is kept in case it lands; the toolkit itself
forgets that one when it recovers it (`mod.rs`, lines 1766 to 1778). The balance is read before a
send only when the kept deposit has nothing left. What reaches the Mac
before a payment leaves is unchanged. `an_opening_deposit_is_shown_as_the_network_shows_it`
and `an_opening_deposit_is_left_to_the_toolkit_whatever_the_balance` in
`guest/sender/tests/sender.rs`, against stand-ins; the provider stand-in
asks for no payment, so the toolkit's own recovery is not under test.

Before (17 November): a keychain read of the wallet that failed left it
not yet looked for, and nothing asked again, so the wallet's sheet showed
its spinner until Cloak opened again. Now a read that fails is
unreadable, and the sheet says "Cloak couldn't read the wallet." with Try
Again, which reads again. `WalletPresenceTests.swift` checks how the
keychain's answers move the presence and that Create starts only where
there is no wallet; the sheet is not under test.

Before (17 November): a new message whose rewording stopped, or was
cancelled, went back into the box as it would have been sent: the draft
with a line for each detail picked, as text, and its pills gone. Now a
rewording is for a new message, with the box as it was written, or for a
turn asked again (`Chat.Asked`), and a new message's box gets back what
was typed and its picks as they were, still fixed, so no new details are
asked for. What is reworded and sent is unchanged. No check: `Chat` is in
the app's executable target, which is not under test, and a rewording
needs Cloak running, which a test cannot start.

Looked at and found sound: a start of tor that is cancelled once its port
is open returns a tor that has not bootstrapped, which the supervisor
treats as a failure and drops, since it is already stopping.

## 11. Stages still implied in the app (found 21 November 2026)

A third read, of every file under `app/Sources` and of the two branches
not yet merged (`t3/near-trace-sharing`, `t3/add-venice-provider`), for
every place a stage is read off several fields. Section 10's entries
still hold except where a line here says otherwise. Each entry gives what
holds the stage, then the faults found in it, each traced in the code
unless it says "likely". A fault fixed since says "Before (date): … Now
…"; the rest are not fixed. Only the payer's stops and reads, the task
card's start and the door's request whose app leaves have checks.

### The menu and the app's shell

- **The menu's header and items** (`app/Sources/RegentsCloak/Menu.swift`).
  The phase, `supervisor.resting` and the download's state. Before (21
  November): a reason kept from the last start was not read against the
  files, so after "The model isn't installed." and a finished download
  the header still offered Download Model…, which opened Details with
  nothing to press; Start stayed on for the reasons the header gave no fix
  for (`unsupported_hardware`, `part_missing`, `part_changed`), where it
  is certain to stop again; and Chat's `Waiting` row and the Wallet's
  `StartRow` offered Start for `model_changed` too. Now one rule (`Fix`,
  section 9) gives all of them the same fix, read against the files, and
  turns Start off where it is certain to stop again. The words follow the
  fix (`Reason.title(with:)`): after a finished download the line says
  "The model has downloaded." beside Start Again. A quit shows as any
  Stopping does.
- **Windows and the Dock icon** (`AppWindow.swift`, `Updates.swift`). Each
  window's optional, its visibility and the activation policy. Sparkle's
  window and a minimised window are not counted, so closing the last
  counted window takes Cloak out of the Dock under them.
- **The quick prompt** (`QuickPrompt.swift`, `Chat.compose`). Hidden,
  shown, handed to Chat. Return sets the mode to V with Agent off.
  Before (21 November): Return put its text in Chat's one message box
  over whatever was there, an empty Return included. Now an empty Return
  only shows Chat, and a Return with text starts a new chat with the text
  after what the box held, its picks as lines of its text, since a change
  of chat clears them; nothing in the box is lost.
- **The quick prompt's shortcut** (`QuickPrompt.swift`,
  `SettingsView.swift`). The saved shortcut, the hot key macOS holds, the
  refusal's words and the recorder's stage. Before (21 November):
  recording dropped every key in every Cloak window and took the first one
  with ⌘, ⌥ or ⌃ as the shortcut, wherever it was typed; and a refused new
  choice showed its words beside the old one, which still worked, without
  saying so. Now the recorder's stage is one value, idle or recording, and
  its button (`RecorderButton`) holds the keyboard while it records: only
  keys typed into it are taken, ⌘'s before the menus see them; Escape, a
  second press or the keyboard going elsewhere ends it with the old
  shortcut kept; and keys typed anywhere else go where they always go. A
  refused choice's words name it and say the old one is still the
  shortcut, or, when macOS had refused that one too, that neither works.
- **Launch and quit** (`RegentsCloakApp.swift`). The order of statements.
  A failure's alert may open behind other windows (likely). Windows stay
  usable through a quit's shutdown, and NEAR's helper, stopped first, is
  started again by a Send in those seconds (section 9b's "ended" is not a
  stage the code holds).
- **Review and Never reword** (`AppSettings.swift`). Turning Never reword
  on turns Review off; turning it off again leaves Review off.
- **Launch at login, Updates, the info note, the text box.** A view's copy
  of a system value, or one flag with a timer. Before (21 November): a
  login item macOS refused sprang the switch back with no words, and one
  waiting for approval opened System Settings by itself. Now the login
  item is one value, `LoginItem.Stage` (on, off, waiting for approval,
  refused), and beside the switch its words say which, with Open Login
  Items, macOS's own place to approve, add or remove it. The window coming
  back reads it again, and a refusal's words go.

### Settings, Details and Agents

- **The NEAR key's row** (`SettingsView.swift`, `NearMode.swift`).
  Before (21 November): read off `hasKey` (nil, false, true), `keyFailed`,
  the typed key, `replacing` and `removing`. "The keychain said no. Try
  again." had nothing that tried again; Replace had no way back to Saved;
  a save that failed had already emptied the field; and the Wallet's own
  read set the same `keyFailed`, so its failure showed in Settings as if
  a save had failed. Now the row's stage is one value (`KeyRow.Stage`:
  reading, unread, shown, replacing, saving, not saved, removing, not
  removed) beside the keychain's last answer, `NearMode.hasKey`, which a
  refused read, save or remove leaves as it was. A read that fails says
  "Couldn't check" with Try Again; a save that fails keeps what was
  typed and says so, Save being the retry; a remove that fails says so,
  the key still shown as saved; and Replace has Cancel. Each read's stop
  stays with whoever asked: the Wallet's shows in the Wallet, with its own
  Try Again.
- **One model's row** (`SettingsView.swift`). A face over
  `ModelDownload.State` (section 9a). Before (21 November): waiting for
  the network and trying again looked like downloading, and the free
  space was read as the pane appeared, so its words went stale. Now a
  symbol before the ring says which, its words in the help and what
  VoiceOver reads; and the pane reads the files and the free space again
  as it shows, as its window comes back and as any model's download
  changes stage, and Download reads them again at its press. A stopped
  row's free space is still not read again while another model downloads
  in front of it with nothing changing stage, so its words can lag that
  download until its own press.
- **Details' reason** (`Details.swift`). Before (21 November): showed the
  reason and its remedy with no button. Now Start Again or Show in Finder
  beside it, as the rule gives (`Fix`, section 9); for a missing model,
  the download's section under it is the way on.
- **The rewording model's download in Details** (`DownloadSection.swift`).
  Cancel's question says what has downloaded is deleted; files already in
  place stay (section 9a).
- **Agents** (`AgentsView.swift`). Before (21 November): the door's
  named state showed beside `problem`, and no line had a button: no Start
  while Cloak was not running, no way to the port while another app held
  it, no Try Again. Adding an app was read off `adding`, `name`, `pass`
  and `working`, and Cancel while it added (traced: the add ran on in a
  task the sheet did not hold) kept the app and never showed its pass, so
  nobody held it. An open request was a copy taken at the press and did
  not follow its stage. Now the door's line is one value read in one
  place (`DoorLine`): while Cloak isn't running, the Wallet's Start row,
  with Start or the start's own fix (`Fix`); while Cloak runs and the door
  isn't open yet, Opening; while another app holds the port the door
  takes next, so trying again is certain to fail, "Another app is using
  port N." with Change Port…, which opens Settings on its Door pane; for
  any other refusal, the door's words with Try Again, which opens the door
  again in turn with the app's own opens and closes
  (`AppDelegate.turnDoor`). The port is read again each time the window
  comes to the front. Adding is one value (`Adding`: naming, keeping,
  kept) that the window keeps: there is no Cancel while the app is kept,
  and its pass shows once it is; an Add that could not keep the app shows
  the door's words in the sheet. An open request is read from the door's
  list by its id each time the list changes, and says so once newer
  requests have pushed its texts out. Still: `problem` is a sentence, not
  a named value, so its line has no button; the door has no opening stage
  of its own (below), so a Try Again that fails again with the same words
  shows nothing new.
- **The log, Restore Defaults, the port field, Copy.** Before (21
  November): Copy Log before the read landed copied nothing over the
  clipboard; Restore Defaults also reset V's model, which the Wallet
  chooses; and no Copy in the app showed that it copied. Now Copy Log is
  offered only once there are lines read; Restore Defaults leaves V's
  model; and every Copy is one button (`CopyButton.swift`), whose symbol
  becomes a checkmark for a second and a half, named "Copied" and said
  by VoiceOver, cross-fading under Reduce Motion. A text read at the
  press that comes back empty, as the Darkbloom key's can, copies nothing
  and shows nothing.

### Chat

- **Opening the saved chats** (`Chat.Access`, named). Before (21
  November): Retry had no stage: two could run at once (traced: `open()`
  set nothing before its first wait, so a second Retry, or the window
  shown again, began a second open), and a retry that failed again showed
  nothing new. Now an open under way is a stage of `Access` (`opening`,
  the first time or again), during which a call does nothing; trying
  again shows a spinner in place of Try Again, and one that fails again
  says it was tried again and still couldn't open them. Locked has no way
  on: the key is gone, and nothing in Cloak brings it back.
- **The one rewording** (`Chat.rewording`, `stops`, the draft given back).
  Before (21 November): all three were the window's, not a chat's. While
  any chat reworded, every chat's box, New and a shrunk card's press were
  off with no reason shown. Its stop and its given-back message landed in
  the chat showing when it ended, a NEAR chat included, where Return sends
  as written. Review was read as the rewording ended (`Chat.reword`), so
  ticking Never reword meanwhile sent the reworded text with no press.
  Now each is its chat's, and the press decides (section 10).
- **The box's text and details** (`draft`, `picks`, `askingDetails`,
  `detailsAsk`). Section 10's four stages, and two more: the 1.2 second
  wait before asking, and fixed with nothing picked
  (`DetailPicks.swift`). One draft for every chat.
- **One message card.** As section 10. Before (21 November): `sendStop`
  was one for all chats (and `NearMode.sendStop` one for all NEAR chats),
  so a send in another chat cleared a card's stop, and a card whose send
  stopped with "may have reached" was later marked "Not sent". Now each
  turn keeps its own, and such a card is marked "May have been sent".
- **One task card.** As section 10. Before (21 November): a stage before
  it for a V task, the model list being read, during which nothing
  showed, Run stayed on and a second Run was dropped unseen (`Agent.run`'s
  guard). Now the task is under way from the press, its card shows
  running with Stop, and a Stop before it runs means it never runs.
  Before (21 November): "Agents says why" had no way to Agents. Now a
  task that couldn't reach Cloak has Agents… beside it, which opens the
  Agents window, where the door's line says why and carries its fix.
- **Saved or not, and disk problems** (`unsaved`, `problem`). One
  `problem` for all chats, cleared by any later save.
- **Sheets** (`showingWallet`, `showingModes`, `deleting`, `explaining`).
  Two flags for one sheet's place.
- **A delete** cancels the chat's rewording, answer and task before the
  file's removal, which can fail and keep the chat.

### The wallets

- **V's reads** (`Payer.reads`, `moving`, `readStop`). Idle, reading,
  waiting 10 seconds. Before (21 November): the stage was read off
  `Payer.following` and `readStop`. A first read that failed left the
  state unread: a spinner for good under a stop that said "Try again"
  with no button. Refresh, and the read a pause asks for, did nothing
  while the loop waited. An older read could land over an approve's
  answer, since traced in the code. The loop also ran while a quote was
  under review, and after each quote and each Try Again, which section 9d
  did not say. Now the stage is one value, `Payer.reads`, and section 9d
  says when the loop runs; a read that has stopped shows no spinner, and
  its row carries Try Again; a read asked for while the loop waits cuts
  the wait short, and one asked for during a round reads as soon as it
  ends; and a read lands only if no approve was answered while it was
  out. Checks: `aCallToReadNowCutsTheWaitShortOneRoundAtATime` and
  `aReadBegunBeforeAnApprovesAnswerDoesNotLandOverIt` in
  `app/Tests/CloakTests/PayTests.swift`.
- **V's quote** (`review`, `working`, `stop`). Asked, shown, expired,
  approving, approved, stopped, cancelled. A stop shows at the top of the
  sheet, not where the press was made. Before (21 November): what a stop
  had asked for was `stopAsk`, set at the press and shared, so a quote
  pressed while an approve was out made that approve's stop read "Nothing
  was sent."; and Withdraw stayed on with no note read, every press then
  stopping as "Failed", which hid the read's own stop. Now a stop is one
  value, `Payer.Stop`, carrying its own ask, set where it is recorded;
  Withdraw stays on, and with nothing read it stops as "Not read", with
  Try Again for the read. Check: `aStopIsAboutItsOwnPress`.
- **V's Amount field** (`text`, `wrong`). Before (21 November): Return
  quoted while Deposit was off, and the red line outlived the text it was
  about, hiding the warning over $50. Now Return does nothing while
  Deposit is off, and the red line goes as soon as the text changes. No
  check: the sheet is not under test.
- **V's failed and taken states.** Taken shows no button. Before (21
  November): Failed hid the address and Send Out. Now the address, On
  hand and Send Out… show in it whenever the funding is read. No check.
- **V's Send Out** (`returning.phase`). Not a case of `Payer.State`; a
  phase other than `return_pending` is not read.
- **V's model list** (`Payer.models`). Before (21 November): a read that
  failed spun for good. Now the row says "Couldn't load the list", with
  Try Again. No check.
- **Token Inference's wallet.** As section 10. One stop row for the press
  and the read, both cleared by Dismiss; Close and Withdraw are on before
  any read.
- **The deposit's file** (`Remote.swift`, `ConversationStore.key`). Sealed
  under the conversations' key, which is made anew when no conversation
  file exists: a deposit kept then can no longer be opened.

### The supervisor, the door, the tool

- **Preparing's steps and the run's parts.** Section 9, corrected above.
- **The run's worker.** Serving, resting, waking; waking is not shown.
  A Local Llama answer served at the run's relay has no limit, and a
  rewrite's limit runs while it queues behind one.
- **The payment disk on the Mac** (`PaymentDisk.swift`). Read off the
  image file, its first bytes and the keychain item. A disk with no key,
  or a key read refused, ends every Start as `guest_failed`, whose words
  are about memory.
- **One model download.** Section 9a holds. Two at once each read the
  free space alone.
- **The door opening.** `listener` is set while `state` still says closed
  or the last refusal: an opening stage section 10 says is not there. A
  box's pass needs the Mac's listener open, so a taken port ends every
  agent task as "No connection". Before (21 November): nothing led from
  there to the port. Now the task's card leads to Agents, whose line says
  the port is in use and leads to Settings' Door pane, then has Try Again
  (Agents, above).
- **One door connection** (`Door.serve`, `Door.routing`). Reading the
  head, admitted, reading the body, then one named stage (`Routing`):
  preparing, dropped, sending, unread, answered. Before (21 November):
  nothing read the connection while routing, so a request whose app had
  gone was still reworded, paid for and listed as answered. Now the
  connection is watched from the end of the body (`Link.ended`). The
  paying moment is the hand-off (`Door.send`): to `PayQueue.complete` for
  a request paid through zkAPI, to `Remote.complete` for one paid from the
  Tempo wallet. An app that leaves before it, while its request is read,
  checked, its provider's models asked for, reworded and, for the Tempo
  wallet, its wallet read, ends the request there: nothing more is
  reworded, sent or paid, and its line says Left, nothing paid. A request
  handed on is never cut for an app that leaves, since the payer gives no
  sign of when it asks for the key and one cut after may be charged, and
  the sender's exchange runs to its end: it goes on to its answer, and its
  line says Left, paid for, the answer unread; one that stops instead
  keeps its stop's words. A request still waiting its turn in `PayQueue`
  counts as handed on, though the payer has not seen it yet: the queue
  does not tell its caller when the turn comes. An app that shuts only its
  sending side while it waits for the answer counts as gone. Check:
  `anAppThatLeavesBeforeItsRequestIsSentIsNotCharged` in
  `app/Tests/CloakTests/PayTests.swift`, for both ways of paying.
- **One control command** (`ControlSocket.swift`, `Cloak.swift`). A
  command waiting through a quit is refused; `cloak start` overtaken by a
  pause exits 0; `cloak doctor` exits 0 with failed checks.

### Not yet merged

- **Trace sharing** (`TraceShare.swift`; that branch's own section 9f).
  Named up to "shared". Cancel and a second Sign In move the epoch
  without `interrupt()`, so a share or a withdrawal under way ends with
  no word, and the commons may hold a trace Cloak has no record of. A
  review cut short gets no notice. Deleting a chat leaves its shared
  traces with no Withdraw.
- **Venice** (`VeniceMode.swift`, `Chat.swift` on that branch; its own
  section 9f, which must be renumbered). `Chat.newVenice` does not read
  the Provider chosen, so with a Venice model picked and Provider back on
  Boundless, a new chat's first message still goes to Venice. A started
  chat's sheet reads the account of the new-chat setting. A list read
  that fails keeps the old list with no word. No notice has its way on.

## Looked at, nothing to name

The worker's frame reader and model check, the boot file writer, the guest's
check harness, and the pin and source scripts run straight through, with no
state kept between steps.
