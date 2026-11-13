# State machines

Every place in Cloak where something moves through stages, what those stages
are, and how the code holds them. Found in a read of every source file on
8 November 2026. Where a stage used to be implied by loose flags, timers or
the order of statements, it is now named in the code; the faults that
implication hid are listed with the checks that show them fixed.

## 1. The worker's one rewrite (`worker/Sources/cloak-rewriter/Worker.swift`)

```
idle --request--> preparing --generation starts--> generating
 ^                    |                                |
 +------------- answer written ------------------------+
```

- **preparing**: the request's own task checks it, builds its prompt and has
  the model read the prompt, in chunks of 512 tokens. A cancel here cancels
  that task: the reading stops at the next chunk, or the generation stops
  the moment it starts. The answer is 499.
- **generating**: a cancel stops the generation; the answer is 499.
- **idle**: a cancel here is one that crossed the answer, and does nothing.
- The worker goes idle before it writes the answer, because the host sends
  its next request as soon as it has read this one.
- **End of the channel** (the host's shutdown closes it): a rewrite in
  progress is cancelled as above and answered 499; the worker exits 0 once
  that answer is written, or at once when idle.
- **Protocol fault** (a request while not idle, an unknown or oversized
  frame, input cut inside a frame): no frame is read after it; a rewrite in
  progress is cancelled and answered 499 the same way, then the worker exits
  2.

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
  has signalled ready, so no caller can forget that step.
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
being stopped hung the host for good, with the relay's queue held. Check:
`test_a_lost_worker_that_ignores_being_stopped_is_killed_before_its_replacement_starts`
(`tests/test_worker_stop.py`, with its own stand-in,
`tests/fake_stuck_worker.py`, which ignores SIGTERM).

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
serving --loss--> replacing --lost worker exited (section 2), afterLoss decided--> serving a new worker, or none
any but replacing --finish--> finished
```

While replacing, no connection is served. What follows the lost worker is
the relay's owner's to decide (`afterLoss`): `cloak-host` starts a new
worker from the same program and pinned files; the app's supervisor
(section 9) starts none, because there a lost worker is a failure. With
none, every later connection closes without an answer, with no further
tries. `finish` (the end of a run) waits out a replacement first, so it ends
the worker that replacement started.

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

The boot files carry the per-boot channel token and rewriter key.
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
starts its guest the same way and has the same limit; it does not clear
leftovers at launch yet. A host killed at any time leaves
tor running for up to about 15 seconds, until tor sees its owner gone and
exits. The stage 3 kit stops a boot over its time limit this way.

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
  --> vsock port 9050 ------------------------> | Tor relay --loopback port--> tor --> guard, relays, exit
a program that skips torsocks --> unreachable   |                              |
anything but a SOCKS5 greeting on 9050 -------> | closed, no byte              |
any other vsock port -------------------------> | refused                      |
```

tor's life, as the host's child:

```
started on its lasting folder --> SOCKS port open --> bootstrapping --> bootstrapped (100%) --> stopped; folder kept
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
port may then be another program's, so from that moment the relay connects
nothing to it, and its connections to tor still open are shut. The check
and the connection are made under one lock, together with the list of open
connections.

One Tor relay connection:

```
accepted --> greeting read (10 s) --> greeting checked --> tor connected (only while tor has not stopped)
  --> greeting passed on --> copying both ways --> either end closes --> both closed
tor stops while copying --> both closed
any step failing, or tor stopped --> closed, without a byte from the host
```

Before (12 November, after the bootstrap wait): the relay connected to
tor's port whatever had become of tor, so after tor exited, a program that
took its freed port received the guest's Tor connections. Check:
`test_a_program_that_takes_the_port_of_a_tor_that_exited_receives_nothing`
(the listener received a connection and the SOCKS5 greeting before the
fix).

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
`test_a_short_input_keeps_the_base_deadline`,
`test_the_longest_input_is_accepted_and_given_the_grown_deadline`,
`test_an_input_over_the_limit_is_refused_at_once` (`tests/test_guest_path.py`)
and `test_a_prompt_over_the_input_limit_stops_its_task_with_the_length_and_the_limit`
(`tests/test_agent_path.py`).

## 8. Files built in steps

- **Altered model folders for the worker checks** (`tests/test_worker.py`):
  built as `<case>.building`, then renamed. A run stopped part way left the
  half-built folder, and every later run failed until it was removed by hand.
  A leftover is now cleared before building.
- **Model downloads** (`scripts/fetch_model.py`): each file goes to
  `<file>.part`, is checked, then renamed; a mismatch is kept as `<file>.bad`.
  Any leftover makes the worker refuse the folder as holding extra files, so
  a broken download stops work instead of loading. No change.

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
  checks (the Mac; each installed part's SHA-256 against the bundle's
  manifest; the model's files and sizes, whose hashes the worker checks
  itself), then tor, started and bootstrapped, then the worker, started and
  ready, then a check guest, which sends one rewrite through the daemon, the
  relay and the worker and powers off. The first failure is the reason.
- **Running** means tor and the worker are up and that check passed. No
  session guest is built yet: the guest is gone once the check ends.
- **Watches**: from its start until the run ends, tor exiting raises
  `tor_stopped` and the worker exiting raises `worker_stopped`. The relay
  replaces no lost worker (section 3): a worker the relay loses is stopped,
  and its exit is the failure.
- **Stopping** is the one shutdown, for every destination: it cancels the
  preparation and the watches, waits for the preparation to end, then stops
  the guest, the worker and tor, in that order, each within its limit
  (section 2). An event from work being stopped (a watch seeing its part
  stopped, a late failure) does not apply, and is dropped.
- **Needs attention** keeps its reason, and the failure's technical detail,
  until the next start. Nothing is started again, and no other route or
  model is tried (REF04).
- **Refused**: any command while Stopping (`busy`), and `resume` anywhere but
  Paused (`not_paused`). A refused command changes nothing.
- **Sleep** pauses, so a wake finds nothing running; a relaunch starts
  Paused, having started nothing.

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
`tor_unavailable`, `tor_stopped`, `worker_unavailable`, `worker_stopped`,
`guest_failed` and `check_failed`.

Checks (`app/Tests/CloakTests/`): `PhaseTests.swift` (every failure from
Preparing or Running ends in Needs attention; nothing starts again unless
asked; sleep pauses; quit from every phase goes through the shutdown;
commands during a shutdown are refused), `SupervisorTests.swift` (stand-in
tor and worker processes: a guest, tor or worker failure ends in Needs
attention with everything stopped and nothing started again; a relaunch
comes back Paused; pausing while tor bootstraps stops it) and
`ControlTests.swift` (the JSON for each status; the socket answers only its
owner's well-formed requests).

## Looked at, nothing to name

The worker's frame reader and model check, the boot file writer, the guest's
check harness, and the pin and source scripts run straight through, with no
state kept between steps.
