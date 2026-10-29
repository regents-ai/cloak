# Plan and release gates

The contract is [spec-v0.3.md](spec-v0.3.md). Work follows its section 12 in
order. A gate passes only with recorded evidence linked in its row; a failed or
inconclusive check is not a pass. Tickets are in `bd`.

## Stages

| Stage | Deliverable | Exit condition | State |
| --- | --- | --- | --- |
| 1. Capture and reproduce | Pi and the reference daemon, model, routing and sandbox configuration | Reference tasks and stated limits documented and reproduced | In progress |
| 2. Automate the stack | Idempotent installer and one supervisor and CLI on the reference environment | Automation preserves versions, policies, behaviour and state | Not started |
| 3. Package for Mac | Signed app, Linux appliance, required assets, narrow local controls | Complete stack runs on a clean qualified Mac; platform changes pass comparison | Not started |
| 4. Simple interface | Menu bar, local session, funding and recovery, status, diagnostics | GUI and CLI share behaviour; novices complete the journey | Not started |
| 5. Qualify and release | Full real-service workflow and evidence package | A01 to A19 pass | Not started |

Mac skills by stage (rules in [AGENTS.md](../AGENTS.md)): stage 3 uses
`macos-patterns`, `macos-build`, `macos-auto-update`, `macos-release` and
`write-swift`; stage 4 adds `macos-settings-ui` and `macos-notch-ui`; stage 5
uses `macos-release` for the qualified release.

## Stage 1 so far

Recorded in [reference/baseline.md](../reference/baseline.md):

- The post's daemon commit is pinned and verified, builds, and passes its own
  tests. Pi 1.3.0 is pinned by package hash.
- The sandbox wrapper is unpublished, so it is reconstructed and tested. A
  statically linked program inside it reaches the internet directly, and
  torsocks runs programs unwrapped when its library fails to load.
- Blocked: the original wrapper and settings (unpublished), the rewriter model
  (needs about 70 GB of memory for weights alone; this Mac has 48 GB), and paid
  inference (no mainnet deployment of the protocol at either pin).

## Gates

| ID | Test | State | Evidence |
| --- | --- | --- | --- |
| A01 | Reproduce the reference | Open: partly recorded; wrapper, weights, payment deployment unknown | [baseline](../reference/baseline.md) |
| A02 | Clean Mac installation | Open | |
| A03 | GUI and CLI equivalence | Open | |
| A04 | Content and usefulness | Open | [tasks](../reference/tasks.md) |
| A05 | Whole-agent containment | Open | |
| A06 | Complete routing | Open: the reconstructed wrapper fails it (static program bypass) | [baseline](../reference/baseline.md#observed-behaviour-of-the-reconstruction) |
| A07 | Conversation isolation | Open | |
| A08 | Cover behaviour | Open | |
| A09 | Failure and pause | Open | |
| A10 | Local API authority | Open | |
| A11 | Paid operations | Open: no qualified deployment exists yet | |
| A12 | Financial interruption | Open | |
| A13 | Fresh-device recovery | Open | |
| A14 | Wrapper-created leaks | Open | |
| A15 | Update and rollback | Open | |
| A16 | Deletion and removal | Open | |
| A17 | Hardware and substitution | Open | |
| A18 | Usability | Open | |
| A19 | Honest claims | Open | |
