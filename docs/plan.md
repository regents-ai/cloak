# Plan and release gates

The contract is [spec-v0.4.md](spec-v0.4.md) (sha256
`8c6b4d5d66fca24383bd3282503e17289784f14df14345a5e15b7bffdac74aea`, received
30 October 2026). Work follows its section 12 in order. A gate passes only
with recorded evidence linked in its row; a failed or inconclusive check is
not a pass. Progress lives here.

## Stages

| Stage | Deliverable | Exit condition | State |
| --- | --- | --- | --- |
| 1. Freeze the experiment | Captured reference, the 16 cases, unchanged contract, candidate manifests, evaluation protocol | Exact assets, licences and primary settings known; unknowns recorded | In progress |
| 2. Build the local path | Minimal guest adapter and native MLX worker through the real daemon | Synthetic inputs, malformed replies, cancellation and worker loss keep the contract and stop safely | In progress |
| 3. Check feasibility early | Lead and challenger runs on a specified 48 GB Mac with the full stack loaded (no 32 GB machine; decision 2) | Input, deadline and memory risks measured before the large privacy evaluation | Kit ready, waiting for the weights |
| 4. Qualify the substitution | Separate fidelity and authored privacy holdouts; one pinned winner or an explicit no-pass | Protection, fidelity, statistical and usability gates pass | Not started |
| 5. Package the product | Signed full bundle, shared CLI and menu-bar supervisor, setup, recovery, updates | Clean-machine and full real-service tests pass | Not started |
| 6. Release at the planned home | Download, guide and evidence for supported configurations | A01 to A26 pass; claims and hardware scope match results | Not started |

Stage 2 builds and tests the path with a small model labelled as a
development stand-in, so it runs light on the development Mac (an M4 Max with
48 GB, macOS 27.0). The candidates' 16 GB weights are first loaded in stage 3,
after a free memory and disk check.

Mac skills by stage (rules in [AGENTS.md](../AGENTS.md)): stage 2's native
worker uses `macos-patterns`, `macos-build` and `write-swift`; stage 5 adds
`macos-auto-update`, `macos-release`, `macos-settings-ui` and
`macos-notch-ui`; stage 6 uses `macos-release`.

## Stage 1 so far

- The daemon is pinned at the post's commit and the spec's later snapshot,
  builds, and passes its own tests. Pi 1.3.0 is pinned by package hash.
- The rewriter contract is captured and identical at both pins:
  [rewriter-contract.md](../reference/rewriter-contract.md).
- The reference model, both candidates and their vendor checkpoints are pinned
  file by file: [models.md](../reference/models.md). Two provenance findings
  there need decision 1.
- The sandbox wrapper is reconstructed and is the Regents reference (Sean,
  29 October). A static program inside it bypasses Tor.
- Unknown and recorded as such: the reference's inference server,
  quantization and thinking setting; which payment deployment the post used.
- The evaluation protocol (EVAL01 to EVAL07) is frozen (Sean, 30 October).

## Stage 2 so far

- The native worker (`worker/`) loads a model only when every file matches
  the pins built into it, rewrites one request at a time, stops on a cancel,
  and stops on any protocol fault. It runs in Apple's App Sandbox with no
  network entitlement and reads files only in
  `~/Library/Application Support/Regents Cloak/models/`. 23 checks in
  `tests/test_worker.py` pass, including: a program signed with the worker's
  entitlements is refused a connection the same program makes unsandboxed,
  the installed worker carries exactly those entitlements, and the worker
  cannot read a folder outside the models folder.
- The guest (`guest/`) is a Debian trixie kernel and a small initramfs from a
  pinned snapshot, with no network device. Inside it, the daemon's own
  rewrite code (`internal/rewriter`, built from the pinned module) calls a
  guest adapter on its usual local address; the adapter forwards each request
  unchanged over one virtio socket with a per-boot token.
- The host (`host/`) boots the guest with Virtualization.framework, checks
  the token, relays to the worker, turns a dropped guest connection into a
  cancel, and treats a lost worker as a failure for this and every later
  rewrite.
- 18 checks in `tests/test_guest_path.py` pass: the request reaches the
  worker byte for byte; nine kinds of bad reply are refused by the daemon's
  code and the next rewrite still works; a client that gives up cancels the
  worker, even before the worker has its request; the daemon's 90-second
  deadline still holds; a lost worker (fake or real, killed mid-rewrite, or
  gone between rewrites) fails safely; the real worker rewrites through the
  whole path and is free again within seconds of a cancel.
- Every staged process (the worker's rewrite, the host's channel and
  connections, the boot files, the guest's boot) is named in the code and
  listed in [state-machines.md](state-machines.md).
- Claim limits. The daemon's full serve path cannot run: its payment vault is
  not deployed at the pinned commit, so the check drives the daemon's rewrite
  code directly, as its client does before target inference (A11 stays open).
  The sandbox confines reads within the person's home folder; system-wide
  readable places such as `/private/tmp` stay readable, as App Sandbox allows.
  The stand-in model is never evaluated: it sometimes fences
  its reply, which the daemon refuses, and sometimes answers instead of
  rewriting.

## Stage 3 so far

- The feasibility kit is ready: `uv run scripts/stage3.py feasibility <name>`
  writes one candidate's stage 3 record (EVAL05, EVAL06, EVAL07) to
  `evidence/stage3/<name>/`, and `uv run scripts/stage3.py eval01 <name>`
  runs the development screen. No candidate has run: the weights wait for
  Sean.
- Every call goes through the real path: the daemon's rewrite code in the
  guest, the adapter, the host relay and the sandboxed worker. A copy-only
  tap between the host and the worker (`scripts/worker_tap.py`) keeps each
  call's request, raw reply and timing without changing either side. Each
  case keeps its input, the daemon's result, every call it made, the
  artifact and configuration hashes, and why it stopped. Rejected,
  malformed, truncated, timed-out, cancelled and lost calls stay in every
  denominator; nothing is cut and no limit is lowered.
- The fixed inputs were written for this and pinned before any candidate ran:
  [eval06-messages.json](../reference/eval06-messages.json) (40 ordinary
  messages up to 512 input tokens, each with its expected output length;
  sha256 `10136dd123899a17ba52b56bbe2a376ecf0f4e5f41d1a8a87e4207c1c8a5e50b`)
  and [eval05-inputs.json](../reference/eval05-inputs.json) (the probe, long
  inputs from 4 KiB to 128 KiB and one byte over, a four-turn conversation
  rebuilt after cache loss, the cancellation and worker-loss inputs; sha256
  `efd9c6ff8b7419edbd10f282392106994ed4bd4644b6366866539c8b807655cb`).
- One `feasibility` run boots the guest three times in turn. The main run
  covers the cold load, the cold first call, the 40 EVAL06 messages warm, the
  rebuild after cache loss, the long inputs and outputs, and a cancellation
  and the call after it. Then the worker is killed mid-rewrite, then a
  restart. Every second it samples the memory and CPU of the worker, the
  guest's virtual machine and the host, plus swap, memory pressure and the
  system's GPU use. It also records the installed size and the end-to-end
  time per case.
- Needs a person, listed in each record with no result: sleep and wake
  during a call, a run on battery, the declared ordinary load, induced memory
  pressure, and the first run after the Mac restarts.
- Not measured by this kit: the full stack (the guest has no Pi, Tor, cover
  traffic or payment vault yet, so stage 3's exit condition stays unmet), the
  daemon's full serve path (A11), per-process GPU use (macOS gives it only to
  root), and a 32 GB Mac (decision 2).
- What a real run needs. Disk: the lead is 16,077,680,950 bytes and the
  challenger 15,373,590,134 (29.3 GiB together); with about 58 GiB free on
  11 November and 50 GiB kept free, neither fits until space is made.
  Memory: the kit refuses to boot unless the model's size plus 5 GiB is
  available (20.0 GiB for the lead, 19.3 GiB for the challenger); this
  shared Mac had about 13.8 GiB available on 11 November.

### Stand-in proof (development only)

These runs prove the kit works end to end on the development stand-in. The
stand-in is not a candidate: none of these figures is evaluated or counts
toward any gate, and the proposed targets are not judged on them.

Feasibility,
[feasibility-20261111T072322Z.json](../evidence/stage3/standin/feasibility-20261111T072322Z.json),
kit commit `5dc1d09`, 11 November, on AC power with other lanes working:

- Cold start: the worker loaded in 1.97 s, including its hash check of every
  pinned file; the first result came 2.69 s after the host started. After a
  restart: 1.86 s and 2.72 s, and all three probes were rewritten.
- EVAL06, 40 messages warm: 24 rewritten; 10 stopped malformed and 6
  truncated at the 16,384-token limit. Median 0.36 s; the 95th percentile is
  not reached, because a stopped call holds that rank. By input length:
  20 of 28 up to 128 tokens, 1 of 6 from 129 to 256, 3 of 6 from 257 to 512.
  Median speed: 287 tokens a second generated, 3,115 read.
- Long inputs, none rewritten: 4 KiB truncated (68.9 s); 16, 32 and 64 KiB
  malformed (17.4, 38.4, 5.0 s); 128 KiB stopped at the 90 s limit; one byte
  over 128 KiB refused before any call; the 16 KiB log truncated (76.8 s).
- History rebuilt after cache loss: stopped malformed on the fourth call,
  1.08 s.
- Cancellation: the worker answered 0.01 s after the cancel, and the next
  call was rewritten in 0.26 s.
- Worker killed 2.03 s into a call: that call and the next both ended as
  "worker lost", the host exited cleanly, and nothing restarted the worker
  within the boot.
- Memory: the worker peaked at 3.35 GiB, the guest's virtual machine at
  0.16 GiB and the host at 24 MB; 3.50 GiB in all. Swap fell by 272 MiB;
  memory pressure reached level 2; the system GPU averaged 95 %.
- Installed on disk: 1.70 GiB. The path itself (the time a case took less
  the worker's own time) added a median of 1 ms, at most 15 ms.
- All 57 cases: 30 rewritten; 14 malformed, 8 truncated, 1 timed out,
  1 cancelled, 2 worker lost, 1 over the input limit.
- The first run found two faults in the kit, fixed before this one: the
  worker's log lines were matched to calls on the wrong clock, and the
  guest's virtual machine was not found.
- For the candidates: the stand-in's runaway outputs reached the
  16,384-token limit in about 70 s. A slower candidate that runs away will
  hit the 90 s limit instead, so a stop for time there may mean a runaway,
  not a slow answer.

EVAL01 development screen,
[eval01-20261111T072816Z.json](../evidence/stage3/standin/eval01-20261111T072816Z.json),
kit commit `de16729`: 14 of the daemon's 16 cases rewritten, 2 stopped
malformed (privacy, spanish), and 9 passed the daemon's own checks. The
other five rewrites dropped something they had to keep: a number
(recommendations, bounds, ranking), a file path (conditional) or a word
(redundancy2). Median 0.21 s, slowest rewrite 0.54 s; the worker peaked at
2.04 GiB. An earlier run of the same kit logic gave the same results.

## Decisions

1. Candidate tokenizer and template files. Decided 30 October (Sean, 1a):
   each candidate uses its conversion's weights with the vendor's own
   tokenizer and chat template files at the pinned vendor revision, recorded
   in `models.json`. This fixes the lead's word-splitting mismatch and the
   challenger's old chat template without converting the weights ourselves.
2. The 32 GB Mac for stage 3 (spec HW01). Decided 30 October (Sean, 2c): no
   32 GB machine is tested. This departs from HW01 by Sean's ruling. Under
   HW03 the most this work can reach is a clearly limited 48 GB pilot; 32 GB
   support stays unmet and unavailable, and nothing may claim it.

## Gates

| ID | Test | State | Evidence |
| --- | --- | --- | --- |
| A01 | Reference integrity | Open: sources, wrapper (reconstructed), contract and model files pinned; reference inference settings and payment deployment unknown | [baseline](../reference/baseline.md), [contract](../reference/rewriter-contract.md), [models](../reference/models.md) |
| A02 | Clean Mac installation | Open | |
| A03 | GUI and CLI equivalence | Open | |
| A04 | Fidelity | Open | |
| A05 | Whole-agent containment | Open | |
| A06 | Complete routing | Open: the reference wrapper fails it (static program bypass) | [baseline](../reference/baseline.md#observed-behaviour-of-the-reconstruction) |
| A07 | Conversation isolation | Open | |
| A08 | Cover behaviour | Open | |
| A09 | Failure and pause | Open | |
| A10 | Local authority | Open | |
| A11 | Actual paid workflow | Open: no qualified deployment exists yet | |
| A12 | Financial interruption | Open | |
| A13 | Fresh-device recovery | Open | |
| A14 | Wrapper disclosure | Open | |
| A15 | Updates and rollback | Open | |
| A16 | Deletion and removal | Open | |
| A17 | Hardware | Open | |
| A18 | Usability | Open | |
| A19 | Claims | Open | |
| A20 | Unchanged rewrite API | Open: contract captured; the daemon's own rewrite code runs unchanged in the guest and refuses nine kinds of bad reply (stand-in model only) | [contract](../reference/rewriter-contract.md), `tests/test_guest_path.py` |
| A21 | Host–guest worker boundary | Open: one token-checked virtio socket, guest has no network device, host relays only rewrite frames, worker sandboxed with no network (development signing; stand-in model) | `host/`, `guest/`, `worker/cloak-rewriter.entitlements`, `tests/test_guest_path.py`, `tests/test_worker.py` |
| A22 | Authorship and linkability | Open | |
| A23 | Long and cold tasks | Open | |
| A24 | Artifact provenance | Open: files pinned; two conversion mismatches found | [models](../reference/models.md) |
| A25 | Single implementation | Open | |
| A26 | Performance claims | Open | |
