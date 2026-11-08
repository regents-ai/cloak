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

- **preparing**: the request is being checked and its prompt built. A cancel
  here is kept and stops the generation the moment it starts.
- **generating**: a cancel stops the generation; the answer is 499.
- **idle**: a cancel here is one that crossed the answer, and does nothing.
  A request while not idle breaks the protocol and stops the worker.
- The worker goes idle before it writes the answer, because the host sends
  its next request as soon as it has read this one.

Before: a busy flag (an atomic) and a run record (a cancelled flag and the
generation) under a separate lock described the same state twice. No fault
was found, but the two could briefly disagree. Now one enum sits under one
lock.

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

Before: an in-flight flag and a lost flag, with a separate "wait until ready"
call. Two faults:

- **A worker gone between rewrites ended the host.** Writing the next request
  to a worker that had died while idle raised SIGPIPE and killed the host,
  instead of marking the worker lost. The host now ignores SIGPIPE, so the
  failed write is the loss. Check:
  `test_a_worker_lost_between_rewrites_fails_the_next_rewrite` (host exited
  with signal 13 before the fix).
- **An early cancel was lost.** See section 3; part of the fix is here.

## 3. One guest connection (`host/Sources/cloak-host/Relay.swift`)

```
token --> request header --> request body --> handed to the worker
      --> watching for the guest to leave --> answer written --> closed
```

Each step reads with a 10-second limit; any failure closes the connection
without an answer. The watch turns the guest closing its end into a cancel.

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
worker: Y once, then for each request: R in, A out; C may come in between
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

Before: they were written before the guest's configuration was checked, so a
failed check left them on disk, and their removal was written in two places.
Today's configuration is fixed, so that failure cannot be caused from
outside; the order was still wrong. Now they are written last, just before
the start, and removed in one place when the start ends, whether it worked
or not, or straight away if writing them fails.

Limit: a host killed during the start (under a second) leaves them in its
private temporary folder, readable only by the person. The stage 4 app,
which will run the host, owns that case.

## 6. The guest's boot (`guest/image/init`)

```
mounts --> vsock modules --> loopback --> adapter ready --> daemon checks --> power off
```

Before: "adapter ready" was guessed by scanning the kernel's socket table
every 0.1 seconds for up to 5 seconds, so a slow boot could fail for no
reason. Now the adapter prints one line, "ready", once it listens, and the
boot waits for that line; an adapter that exits first ends the wait at once.

## 7. One request in the guest adapter (`guest/adapter/main.go`)

```
checked --> host connection --> request sent --> answer header --> reply copied
```

Go's request context carries the state: the daemon giving up closes the host
connection, which cancels the rewrite. No hidden flags; no change.

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
