# State machines

Every place in Cloak where something moves through stages, what those stages
are, and how the code holds them. Found in a read of every source file on
8 November 2026. Where a stage used to be implied by loose flags, timers or
the order of statements, it is now named in the code; the faults that
implication hid are listed with the checks that show them fixed. Since
19 November only the gate checks are kept (decision 15 in `docs/plan.md`);
where a fault's check was an ordinary unit check, it says so, and nothing
checks that fault now.

## 1. The worker's one rewrite (`llama-worker/Sources/cloak-rewriter-llama/Worker.swift`, `llama-worker/Sources/CLlama/cloak_llama.cpp`)

The worker (llama.cpp, decision 8) holds two states, `idle` and
`rewriting`, in one enum under one lock; the rewrite's steps are the order
of `cloak_engine_rewrite`, which returns how it ended.

```
idle --request--> rewriting --answer written--> idle

rewriting: request checked --> prompt rendered --> context made --> grammar made --> reading the prompt --> generating --> stop | length
           any step --> failed (template, context, grammar, prompt, generation): 500
           reading the prompt, generating --cancel--> cancelled: 499
```

- **request checked**: two requests for this model go on. The daemon's
  rewrite request, whose user message is the daemon's `{"texts":[...]}` with
  at least one text: the count of texts fixes the grammar's `texts` rule
  (decision 9). And Cloak's details request (decision 13), the same keys
  with the user message `{"draft":"..."}`, which decodes under Cloak's
  details grammar (`reference/details-reply.gbnf`) instead. Anything else is
  answered 400 and never reaches llama.cpp.
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
- **idle**: a cancel here is one that crossed the answer, and does nothing.
  The worker goes idle before it writes the answer, because the host sends
  its next request as soon as it has read this one.
- **End of the channel** (the host's shutdown closes it): a rewrite in
  progress is cancelled as above and answered 499; the worker exits 0 once
  that answer is written, or at once when idle.
- **Protocol fault** (a request while not idle, an unknown or oversized
  frame, input cut inside a frame): no frame is read after it; a rewrite in
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

Only the app's relay rests (`Resting`; `cloak-host`'s never does). Once no
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
stops the load at once. No check since 19 November.

The app's own requests (`answer(to:)`) take their turn with the
connections, each as one call:

```
waiting --its turn--> at the worker --answer--> finished
waiting, at the worker --its task cancelled--> cancelled
```

A details request (decision 13) gives way: the next request to arrive, the
app's or a connection's, cancels it as its task's cancel would, so a
rewrite waits behind it no longer than the worker takes to stop (one token,
or one 512-token chunk of the prompt). A rewrite never gives way. No check
since 19 November.

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
worker: Y once, then for each request: R in, A out; C may come in between;
        the end of input, or a frame it cannot take, ends the worker, after
        the A it owes
```

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
(section 9); `cloak-host` never lays one.
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
private temporary folder, readable only by the person. The stage 5 app
writes its guests' boot files in a folder of its own instead, each guest's
in `~/Library/Application Support/Regents Cloak/control/boot/cloak-<UUID>/`,
and its supervisor removes every such `cloak-<UUID>` folder there at launch,
before anything starts, and nothing else (section 9). A host killed at any
time leaves tor running for up to about 15 seconds, until tor sees its owner
gone and exits. The stage 3 kit stops a boot over its time limit this way.

## 6. The guest's boot (`guest/image/init`, then `guest/image/boot`)

```
root copied to tmpfs --> switched root --> mounts --> vsock and entropy modules --> loopback
  --> adapter ready --> Tor port ready --> daemon ready --> daemon checks --> workspace made
  --> agent cases --> power off
```

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
log offset noted --> case run as agent --> exited --> daemon log lines taken --> result printed
```

Before (12 November): the agent check also ran a route observer on the Tor
port, which refused each SOCKS connection and recorded what it read. The Tor
port is now `cloak-tor-port`, so the observer is gone; the checks' stand-in
tor (`tests/fake_tor.py`) does the same from the host, in the same steps
(greeting, password, request, refusal), recording what it read whichever
step the connection ends at. It says it has bootstrapped at once, later,
never, or exits first, as each check needs.

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

- **Preparing** takes each step only once the one before it is up: the
  checks (the Mac: Apple silicon, the model's memory within Metal's graphics
  limit less 1 GiB, and all of Cloak's within the memory less 4 GiB for
  macOS, both needs from the manifest, a graphics limit that cannot be read
  failing it; each installed part's SHA-256 against the bundle's
  manifest; the model's files and sizes, whose hashes the worker checks
  itself), then tor, started and bootstrapped, then the worker, started and
  ready, then a check guest, which sends one rewrite through the daemon, the
  relay and the worker and powers off. The first failure is the reason.
  A worker that exits before it is ready because the model folder is not
  exactly the pinned files (its exit status 3, section 1) is
  `model_changed`; any other is `worker_unavailable`.
- **Running** means tor is up, the worker is up or resting, and that check
  passed. No session guest is built yet: the guest is gone once the check
  ends.
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
  a guest is up waits for the next Start, and Chat says so under its
  message box ("Cover changes at the next Start.") while the two differ.
  Nothing else in the run depends on it.
- **Watches**: from its start until the run ends, tor exiting raises
  `tor_stopped`, and every worker exit the relay did not cause raises
  `worker_stopped`; a rest never does. The relay replaces no lost worker
  (section 3): a worker the relay loses is stopped, and its exit is the
  failure.
- **Stopping** is the one shutdown, for every destination: it cancels the
  preparation and the watches, waits for the preparation to end, then stops
  the guest, the worker and tor, in that order, each within its limit
  (section 2); a worker that rested is already gone, and one loading after a
  rest is stopped at once. An event from work being stopped (a watch seeing its part
  stopped, a late failure) does not apply, and is dropped. Each wait in
  the preparation ends when it is cancelled: tor's bootstrap, the guest's
  boot and check, and the worker's model load, whose worker is stopped
  there and then, so a pause or a quit takes effect at once in any step.
  Before (13 November): the worker's start was waited for until the model
  had loaded, so a pause or a quit during the load waited for it.
- **Needs attention** keeps its reason, and the failure's technical detail,
  until the next start. Nothing is started again, and no other route or
  model is tried (REF04).
- **Refused**: any command while Stopping (`busy`), and `resume` anywhere but
  Paused (`not_paused`). A refused command changes nothing.
- **Sleep** pauses, so a wake finds nothing running; a relaunch starts
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
  the state now, in the menu's words: Starting through Preparing, Stopping
  through Stopping, with "model unloaded" while Running and resting and
  "downloading model" while the download is under way; the dot's tooltip
  and VoiceOver say the same word. Before (18 November): the line kept the
  last settled state's word through a start or stop, which takes 8 to 13
  seconds. Once settled in Needs attention, the reason's title and remedy
  take the line's place, beside the one fix the menu can offer: Start Again
  for `tor_unavailable`, `tor_stopped`, `worker_unavailable`,
  `worker_stopped`, `guest_failed` and `check_failed`, Download Model… for
  `model_missing` (section 9a), Show in Finder for `model_changed`, which
  reveals the model's folder and changes nothing in it, and none for the
  rest. The menu is rebuilt each time it opens, and while it is open
  whenever the phase, the rest or the download changes.

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

## 9a. The model's download (`app/Sources/CloakSupervisor/ModelDownload.swift`)

Release plan item 7. `ModelDownload` is the one owner of the download's
state; the Details window, the menu and the chat window only read it and
press its buttons. Nothing downloads until Download is pressed, and the
download never starts Cloak.

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
```

- **What it fetches**: exactly the manifest's files, each at its pinned
  size and sha256, from the one URL the manifest gives it. `app/manifest.py`
  makes that URL from `reference/models.json`'s repository and revision with
  `scripts/fetch_model.py`'s own `url`, so the script and the app fetch from
  the same place. No other model, source or mirror.
- **Installed** means every file is a regular file of its pinned size, as
  the start check counts it (`Checks.isInPlace`, section 9); the worker
  still checks every sha256 itself as it loads.
- **Offered** in the Details window while some file is not in place, by a
  Download Model item in the menu then (the menu looks at the files again
  each time it opens), and in the chat window when the reason is
  `model_missing`. While Cloak needs attention for `model_missing`, the
  menu's header offers it as the failure's button, in the item's place
  (section 9). Before the button, the window says the size,
  the host, and that this download goes straight from this Mac to that
  host, which sees this Mac's address, unlike Cloak's messages.
- **Blocked**: Download and Continue are disabled, with the reason beside
  them, only when the download is certain to fail: this Mac fails the Mac
  check (section 9), or the models folder's volume has less free than the
  bytes still to fetch plus 1 GiB. Free space that cannot be read blocks
  nothing.
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
  files in place stay. Each waits for the work before it to end, so only
  one piece of work touches the files at a time. **Quit** ends the transfer
  with the app; the partial stays, and the next launch opens Stopped and
  fetches nothing until asked.

The download's checks were deleted on 19 November (decision 15 in
`docs/plan.md`); nothing checks what they checked now.

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
  presses), `Chat.opened` and `Chat.stop`. Each press of Send is sent
  (the Chat rule), so two presses pay twice and the second answer takes
  the first one's place. A message goes as written by one of two paths
  (decision 11): with Never reword ticked (`AppSettings.neverReword`), a
  written message is added without a reworded text and sent at once,
  never passing through being reworded; or Send Original Text on a
  reworded, open card drops its reworded text and sends it. Either way
  `Turn.reworded` is nil from then on. Send Original Text is sent on each
  press as Send is, so a press of it while the reworded text is still
  sending pays twice, and the turn is kept as sent as written. With Review
  off (`AppSettings.review`), a rewording that finishes, a new message's or
  a Reword's, sends the turn at once, as a press of Send would, through
  the same checks: one that cannot go stays reworded and open, saying why,
  so "reworded and open" is skipped only when the send can start.
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
  message and "not reworded yet" for a task.
- **The draft's details** (`Chat.picks`, `askingDetails`, `detailsAsk`).
  Resting, asking, shown, fixed.
- **The wallet** (`app/Sources/RegentsCloak/Wallet.swift`). Whether this
  Mac holds it is one value, `WalletPresence` in
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
  is no "opening". The app opens and closes it from one loop, in turn, so
  the two do not cross. A listener that fails after opening leaves the box
  passes in place until the next close. Each chat request it takes past
  the pass is listed (`requests`, newest first, at most 200, in memory
  only until Cloak quits) with one named stage: rewording, sending,
  answered, or stopped with the words it was answered with. `route` lists
  it and ends it; `complete` notes the model once the request is read and
  moves it to sending once every user message is reworded, so it shows as
  rewording while the provider's list of models is asked for too. One that
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

## Looked at, nothing to name

The worker's frame reader and model check, the boot file writer, the guest's
check harness, and the pin and source scripts run straight through, with no
state kept between steps.
