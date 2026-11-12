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
(the stand-in answered 9.4 s after the cancel before the fix) and
`test_a_client_that_gives_up_while_the_real_worker_reads_a_long_prompt_frees_it`.

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

## 2. The host's channel to the worker (`host/Sources/cloak-host/WorkerChannel.swift`)

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
  work. The relay then starts a new worker on a new channel (section 3).

Before: an in-flight flag and a lost flag, with a separate "wait until ready"
call. Two faults:

- **A worker gone between rewrites ended the host.** Writing the next request
  to a worker that had died while idle raised SIGPIPE and killed the host,
  instead of marking the worker lost. The host now ignores SIGPIPE, so the
  failed write is the loss. Check:
  `test_a_worker_lost_between_rewrites_fails_only_the_next_rewrite` (host exited
  with signal 13 before the fix).
- **An early cancel was lost.** See section 3; part of the fix is here.

## 3. One guest connection (`host/Sources/cloak-host/Relay.swift`)

```
token --> request header --> request body --> handed to the worker
      --> watching for the guest to leave --> answer written --> closed
```

Each step reads with a 10-second limit; any failure closes the connection
without an answer. The watch turns the guest closing its end into a cancel.

A worker lost during the connection (gone mid-rewrite, or found gone when
its request is handed over) closes it without an answer; its request is
never sent again. Before the next connection, the relay starts a new
worker, from the same program and pinned files, holding the worker's lock
until it is ready so the host's shutdown waits for it and ends it. A new
worker that cannot start leaves none, with no further tries, and every later
connection closes without an answer.

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

## 5. The host's life and the secret boot files (`host/Sources/cloak-host/main.swift`)

```
worker ready --> guest checked --> boot files written --> guest starting
             --> boot files removed --> listening --> guest stopped --> worker finished
```

The boot files carry the per-boot channel token and rewriter key.
"Worker finished" closes the worker's channel and waits for it to exit; a
busy worker first stops its rewrite (section 1), so the rewrite in progress
fails and is not sent again.

Before: they were written before the guest's configuration was checked, so a
failed check left them on disk, and their removal was written in two places.
Today's configuration is fixed, so that failure cannot be caused from
outside; the order was still wrong. Now they are written last, just before
the start, and removed in one place when the start ends, whether it worked
or not, or straight away if writing them fails.

Limit: a host killed during the start (under a second) leaves them in its
private temporary folder, readable only by the person. The stage 4 app,
which will run the host, owns that case.

## 6. The guest's boot (`guest/image/init`, then `guest/image/boot`)

```
root copied to tmpfs --> switched root --> mounts --> vsock and entropy modules --> loopback
  --> adapter ready --> daemon ready --> daemon checks --> workspace made --> agent cases --> power off
```

Before: "adapter ready" was guessed by scanning the kernel's socket table
every 0.1 seconds for up to 5 seconds, so a slow boot could fail for no
reason. Now the adapter prints one line, "ready", once it listens, and the
boot waits for that line; an adapter that exits first ends the wait at once.
The daemon is waited for the same way. Either one failing to start powers
the guest off with a line saying which.

## 6a. One agent case (`guest/agent/main.go`)

```
log offset noted --> earlier route attempts cleared --> case run as agent --> exited
  --> route attempts taken --> daemon log lines taken --> result printed
```

The route observer refuses each SOCKS connection in steps (greeting,
password, request, refusal) and records what it read so far, whichever step
the connection ends at.

## 7. One request in the guest adapter (`guest/adapter/main.go`)

```
checked --> host connection --> request sent --> answer header --> reply copied
```

Go's request context carries the state: the daemon giving up closes the host
connection, which cancels the rewrite. No hidden flags; no change.

## 7a. Tor's way out (`host/Sources/cloak-host/Tor.swift`, `host/Sources/cloak-host/TorRelay.swift`, `guest/torport/main.go`)

Design of 12 November ([plan.md](plan.md), "Tor out of the guest"). Where
the bytes go:

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
started --> SOCKS socket open --> (bootstrapping, then circuits) --> stopped --> folder removed
exits before its socket opens --> the host fails before the boot files are written
exits later --> every later Tor connection fails; never restarted
```

One Tor relay connection:

```
accepted --> greeting read (10 s) --> greeting checked --> tor connected
  --> greeting passed on --> copying both ways --> either end closes --> both closed
any step failing --> closed, without a byte from the host
```

## 8. Files built in steps

- **Altered model folders for the worker checks** (`tests/test_worker.py`):
  built as `<case>.building`, then renamed. A run stopped part way left the
  half-built folder, and every later run failed until it was removed by hand.
  A leftover is now cleared before building.
- **Model downloads** (`scripts/fetch_model.py`): each file goes to
  `<file>.part`, is checked, then renamed; a mismatch is kept as `<file>.bad`.
  Any leftover makes the worker refuse the folder as holding extra files, so
  a broken download stops work instead of loading. No change.

## Looked at, nothing to name

The worker's frame reader and model check, the boot file writer, the guest's
check harness, and the pin and source scripts run straight through, with no
state kept between steps.
