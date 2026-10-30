# Plan and release gates

The contract is [spec-v0.4.md](spec-v0.4.md) (sha256
`8c6b4d5d66fca24383bd3282503e17289784f14df14345a5e15b7bffdac74aea`, received
30 October 2026). Work follows its section 12 in order. A gate passes only
with recorded evidence linked in its row; a failed or inconclusive check is
not a pass. Tickets are in `bd`.

## Stages

| Stage | Deliverable | Exit condition | State |
| --- | --- | --- | --- |
| 1. Freeze the experiment | Captured reference, the 16 cases, unchanged contract, candidate manifests, evaluation protocol | Exact assets, licences and primary settings known; unknowns recorded | In progress |
| 2. Build the local path | Minimal guest adapter and native MLX worker through the real daemon | Synthetic inputs, malformed replies, cancellation and worker loss keep the contract and stop safely | In progress |
| 3. Check feasibility early | Lead and challenger runs on a specified 48 GB Mac with the full stack loaded (no 32 GB machine; decision 2) | Input, deadline and memory risks measured before the large privacy evaluation | Not started |
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
- Still to write: the evaluation protocol (EVAL01 to EVAL07).

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
- 16 checks in `tests/test_guest_path.py` pass: the request reaches the
  worker byte for byte; nine kinds of bad reply are refused by the daemon's
  code and the next rewrite still works; a client that gives up cancels the
  worker; the daemon's 90-second deadline still holds; a lost worker (fake or
  real, killed mid-rewrite) fails safely; the real worker rewrites through the
  whole path and is free again within seconds of a cancel.
- Claim limits. The daemon's full serve path cannot run: its payment vault is
  not deployed at the pinned commit, so the check drives the daemon's rewrite
  code directly, as its client does before target inference (A11 stays open).
  The sandbox confines reads within the person's home folder; system-wide
  readable places such as `/private/tmp` stay readable, as App Sandbox allows.
  The stand-in model is never evaluated: it sometimes fences
  its reply, which the daemon refuses, and sometimes answers instead of
  rewriting.

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
