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
| 4. Qualify the substitution | Separate fidelity and authored privacy holdouts; one pinned winner or an explicit no-pass | Protection, fidelity, statistical and usability gates pass | Kit in progress: no holdout, reference run or candidate result yet |
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
  the pins built into it, rewrites one request at a time, stops on a cancel
  (also while it reads a long prompt), and stops on any protocol fault. When
  the host shuts down mid-rewrite, the worker stops that rewrite, which
  fails, and exits cleanly; a protocol fault mid-rewrite stops the rewrite
  the same way before the worker exits. It runs in Apple's App Sandbox with no
  network entitlement and reads files only in
  `~/Library/Application Support/Regents Cloak/models/`. 28 checks in
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
  cancel, and treats a lost worker as a failure for the rewrite it had (never
  sent again); it then starts a new worker from the same program and pinned
  files for the next rewrite. A new worker that cannot start leaves every
  later rewrite failing.
- 20 checks in `tests/test_guest_path.py` pass: the request reaches the
  worker byte for byte; nine kinds of bad reply are refused by the daemon's
  code and the next rewrite still works; a client that gives up cancels the
  worker, even before the worker has its request; the daemon's 90-second
  deadline still holds; a lost worker (fake or real, killed mid-rewrite, or
  gone between rewrites) fails only the rewrite it had or the one that found
  it gone, and a new worker serves the next; a new worker that cannot start
  fails every later rewrite; the real worker rewrites through the whole path
  and is free again within seconds of a cancel, also one that lands while it
  reads a 128 KiB prompt.
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

### Pi in the guest (12 November 2026)

What runs in the guest now, in boot order (all on the development
stand-in; nothing here counts toward a gate):

- `/init` copies the root onto a tmpfs and switches to it, because
  bubblewrap cannot pivot away from the kernel's initial ramfs.
- The adapter, as before, as user `adapter`.
- The daemon's own local API, `cloak-daemon`, as user `zkapi` on
  127.0.0.1:8787. It is the pinned `zkapi-clientd` built with one added file
  (`guest/daemon/zz_cloak_guest.go`, compiled in by overlay, so the daemon's
  files stay untouched) that builds the API exactly as the daemon's own
  `serve` does after setup: the default configuration, the rewriter at the
  adapter, Tor at `tor://127.0.0.1:9050`. It skips what needs the network or
  a wallet: funding, the wallet companion, the deployment check, cover
  traffic and the key-session monitors.
- The daemon's rewrite checks, as before.
- `cloak-agent-check` runs each agent case as user `agent`: Pi 1.3.0 inside
  the reference wrapper (`pi-paranoid`, so bubblewrap with torsocks), talking
  to the daemon. Plain commands can run in the same sandbox, to probe it.

Containment, as checked:

- Pi and every tool it starts run in one bubblewrap sandbox as an
  unprivileged user: `/usr` read-only, a private home and one workspace,
  their own process, IPC and host-name namespaces, and an empty environment
  apart from the wrapper's settings. The sandbox sees no `/run/cloak` (the
  channel token and rewriter key) and no `/etc/cloak`, and none of the
  daemon's or adapter's processes.
- torsocks preloads into Pi, so Node's connections go to the Tor port. Pi
  reaches the daemon only because the reference allows loopback
  (`AllowOutboundLocalhost 1`).
- The guest has no network device, unchanged: `/proc/net/dev` inside the
  sandbox lists only `lo`, and a static program, which skips torsocks, finds
  the network unreachable.
- The guest has no Tor. A route observer on the Tor port (part of the agent
  check, not of the path) records each SOCKS identity, as a short hash, and
  the destination asked for, then refuses. So each model request is
  rewritten, then stops at Tor route preparation with the daemon's own
  message: "no direct fallback was used".

Six checks in `tests/test_agent_path.py` pass:

- Pi's new turn reaches the worker byte for byte as the daemon's rewrite
  request, and the task then stops at the Tor route.
- A continued conversation (`pi -c`) keeps its SOCKS identity; a new one
  gets another.
- A bad rewrite reply stops the task with the daemon's rewrite error before
  any model request, and the next task still runs.
- A lost worker stops its task the same way, and the next task runs on a
  new worker.
- The sandbox holds, as above; the adapter and the daemon's status route
  both answer 401 without their keys.
- Pi with the real worker and the stand-in model, end to end to the Tor
  route.

Choices made overnight, without asking (Sean's brief of 12 November):

- **Node.js 24.22.2** (linux-arm64, pinned by sha256 in
  `reference/sources.json`, fetched once by `scripts/fetch_sources.py`). It
  is the version in the stage 1 reference host's pinned image, and Pi 1.3.0
  needs 22.19 or later. Pi's published bundle runs on Node alone. The hash
  matches nodejs.org's published list; its signature was not checked.
- **Wrapper correction**: the reconstructed `sandbox` copied Pi's provider
  file to a path Pi never reads, so Pi refused the `zkapi` provider. It now
  goes to `~/.pi/agent/models.json`. The stage 1 Linux host check ran only
  `pi --version`, which never reads it.
- **Entropy device**: the host now gives the guest a virtio entropy device.
  Without it the guest's random source never became ready and the daemon
  waited forever for its first key. It is a second channel into the guest
  and carries only random bytes from the Mac, one way.
- **torsocks script**: the guest carries Debian's torsocks script without its
  Debian-only block, which warns about libtorsocks missing for other
  architectures using dpkg tools the guest lacks. The guest has one
  architecture.
- **The guest daemon harness** instead of the daemon's `serve`: `serve`
  first funds a wallet and starts the wallet companion, which need the
  network and a payment vault; building those is out of bounds.

Missing for the full stack, and the next step for each:

- **Tor** in the guest (a pinned tor and its route to the Mac). Next: decide
  how Tor traffic leaves the guest without giving it a network device (the
  spec's A06 asks for enforced routing). Not built, by instruction.
- **Cover traffic**: needs Tor and operator-chosen destinations. Not built,
  by instruction.
- **Payment vault, funding, wallets**: not deployed at the pinned commit
  (A11). Not built, by instruction.
- **The daemon's real `serve`** in place of the harness: needs the two above.
- **A real answer to Pi**: every task stops at the Tor route, so Pi's tools
  never run on a model's answer.

### Tor out of the guest (design, 12 November 2026)

Decision 5: torsocks in front of the Tor Project's own `tor` on the public
Tor network; the guest keeps no network device, and its one way out is a
relay to the Tor port. What the spec asks of it
([spec-v0.4.md](spec-v0.4.md)):

- Routing, line 88: "Complete intended agent/tool traffic, DNS behavior and
  transport failure handling", and never "A proxy setting that leaves other
  processes or protocols able to connect directly". A06, line 396:
  "Main/auxiliary calls, tools, children, DNS and alternative connection
  paths cannot bypass the qualified route". NET05, line 287: "Installing
  torsocks alone is not accepted as proof that every possible process path
  is protected."
- Containment, line 90: "Actual sandbox policy, allowed files/ports and full
  harness process tree". MAC04, line 148: "Preserve bubblewrap/torsocks and
  the reference network restrictions for the complete agent process tree.
  … Disallowed TCP, DNS, IPv4/IPv6, UDP/QUIC and subprocess paths must
  fail." MAC03, line 146: "Restrict host–guest channels to the required
  operation."
- Failure: NET06, line 289, route loss must "stop new affected operations"
  and "Do not quietly restart the work through a different route"; REF04,
  line 75, no fall back to direct calls.
- Placement: Tor's location is "Reference network placement" (line 134), and
  "The guest remains the home of the qualified Pi workflow, daemon
  semantics, payment authority, Tor isolation, cover and sandbox policy.
  Exact placement changes from the captured reference are recorded and
  tested" (line 160).
- Pin and state: UPD01, line 325, puts "Tor/torsocks" in the signed
  manifest; NET08, line 293, "Do not merge or clone active session/wallet
  state".

Two ways keep the guest without a network device:

- **A. tor in the guest**, its relay connections carried out by the host.
  tor reaches an upstream proxy only over loopback TCP, which every guest
  process can reach too, the sandbox included. The host end would then be a
  way out to any address, unless it checked each one against Tor's current
  relay list or the guest filtered loopback by user; guest root would still
  have it.
- **B. tor on the Mac, as the host's child, with the guest's Tor port
  relayed to it.** The guest reaches only tor's SOCKS port, which is what
  every local program reaches in the reference. No guest process, root
  included, has a direct connection.

Chosen: **B**, as less mechanism and the stricter route. Its cost is
placement: tor runs on the Mac as the person's own process, outside the
guest, which departs from lines 134 and 160; it is recorded here, tested
below and put to Sean (questions below). The daemon in the guest still
gives each conversation its SOCKS identity, and tor's `IsolateSOCKSAuth`
still makes each one its own circuit, as in the reference.

How B works:

- **Guest**: `cloak-tor-port`, as its own user, listens where the
  reference's tor listens, 127.0.0.1:9050, so the daemon's
  `tor://127.0.0.1:9050` and the torsocks settings stay as they are. It
  carries each connection's bytes unchanged over vsock to the host's port
  9050.
- **Host relay**: reads each connection's first bytes within 10 seconds.
  Only a SOCKS5 greeting offering no authentication or a user name and
  password, which is what torsocks and the daemon send, goes on; anything
  else is closed without a byte. The relay then connects to tor's SOCKS
  socket and copies both ways until either end closes. It takes no address
  from the guest; its one destination is tor. The host listens on no vsock
  port but this one and the rewrite relay's 8012.
- **tor**: started by the host after the worker and before the boot files,
  with no configuration file. Its settings are the reference's
  (`SocksPort … IsolateSOCKSAuth`, `Log notice stdout`), with the SOCKS port
  on a socket file in a private per-boot folder instead of a TCP port, so it
  opens no listener on the Mac's network. Its log goes to the host's
  standard error. The host is its owning process: a host that dies without
  stopping it ends it within about 15 seconds. The host waits for tor's SOCKS
  socket, never for its bootstrap, and never restarts it. A task that needs
  Tor before tor has a circuit waits within the daemon's own 25-second route
  check.
- **What leaves the Mac**: tor's own connections to the Tor network, and,
  through Tor, only the streams the guest asks for.
- **Pin**: the Tor Project's macOS arm64 expert bundle 16.0.1, which carries
  tor 0.4.9.16 (the stage 1 reference host ran Debian's 0.4.9.15). It is
  pinned in `reference/sources.json` by size (19,005,562 bytes) and sha256
  (`0b7d022017c31e3f972d06465bcd7ac50feb66ac825547419a934914fe4bb156`, as in
  the Tor Project's signed-build hash list; the list's own signature was not
  checked, as this Mac has no GPG). `host/build.sh` checks the pin, takes
  only `tor` and its `libevent` from the bundle, and signs `tor` ad hoc,
  because macOS 27 kills the bundle's own copy at launch for an invalid
  signature.
- **State and keys**: all of tor's state (the directory cache, the guard
  choice; a client tor keeps no long-term identity key, and its circuit keys
  live in its memory) is in the per-boot folder, inside the host's private
  temporary folder, and is removed when the host stops tor. Nothing passes
  from one guest to the next.
- **Fails closed**: with tor gone or unable to build a circuit, the
  daemon's own route check stops the task ("no direct fallback was used"),
  and nothing else in the guest has a way out.

Checks planned, on the stand-in: a torsocks program reaches the Tor port and
a circuit is built; the reference's static A06 probe, run in the sandbox as
the stage 1 routing check runs it, reaches nothing; the guest lists only
`lo`; the relay closes everything that is not a SOCKS5 greeting, and no
other vsock port answers; a tor that stops, or that cannot reach the
network, stops the task.

Open for Sean: tor on the Mac instead of in the guest; a fresh guard each
boot, where Tor by default, and the reference's Debian tor, keep theirs; and
whether tor on the Mac gets its own confinement (it runs unconfined; Apple's
App Sandbox refused it as a bare program with no bundle identifier).

## Stage 3 so far

- The feasibility kit is ready: `uv run scripts/stage3.py feasibility <name>`
  writes one candidate's stage 3 record (EVAL05, EVAL06, EVAL07) to
  `evidence/stage3/<name>/`, and `uv run scripts/stage3.py eval01 <name>`
  runs the development screen. The lead candidate has one feasibility run
  ("Lead candidate, first run" below); the challenger has none.
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
- Not measured by this kit: the full stack (the guest now runs the daemon's
  local API and carries Pi, but has no Tor, cover traffic or payment vault,
  and the kit's calls do not come from Pi, so stage 3's exit condition stays
  unmet), the
  daemon's full serve path (A11), per-process GPU use (macOS gives it only to
  root), and a 32 GB Mac (decision 2).
- What a real run needs. Disk: the lead is 16,077,680,950 bytes and the
  challenger 15,373,590,134 (29.3 GiB together); with about 58 GiB free on
  11 November and 50 GiB kept free, neither fits until space is made.
  Memory: the kit refuses to boot unless the model's size plus 5 GiB is
  available (20.0 GiB for the lead, 19.3 GiB for the challenger); this
  shared Mac had about 13.8 GiB available on 11 November.

### Lead candidate, first run (12 November 2026)

[feasibility-20261112T142919Z.json](../evidence/stage3/lead/feasibility-20261112T142919Z.json),
kit commit `97f8605`, clean tree, on AC power, by Sean's "go Cloak run". The
artifact is `mlx-community/Qwen3.8-27B-4bit` at the pinned revision
(16,077,680,950 bytes, hashes in the record). The preflight saw 24.1 GiB
available against 20.0 GiB needed. This is a candidate record, not a
development one. It closes no gate: the five hand-run steps are open, the
Mac was not at the declared load (another lane was building and testing
during the run), and the full stack is still missing (no Tor, cover
traffic or payment vault).

What it showed:

- Cold load 12.65 s; the first result came 21.19 s after the host started.
  After a restart the cold load was 11.65 s and three probes were rewritten.
- EVAL06: 40 of 40 ordinary messages rewritten, none stopped. Median
  5.17 s against a proposed 5 s; 95th percentile 14.48 s against a proposed
  15 s. The median misses by 0.17 s, so the proposed targets are not met.
  By input size: up to 128 tokens, median 4.55 s (28 messages); 129 to 256,
  8.08 s (6); 257 to 512, 13.26 s (6). Generation ran at a median of 16.0
  tokens a second. Outputs were a median 1.05 times their expected length.
- The four-turn conversation was rebuilt after cache loss in 13.01 s over
  four calls.
- Long inputs: 4 KiB of prose was rewritten in 58.43 s. 16 KiB, 32 KiB,
  64 KiB and 128 KiB of prose and 16 KiB of literal text all stopped at the
  90 s limit. One byte over the input limit was refused in 0.01 s, as it
  should be. At 16 tokens a second, 90 s allows about 1,400 output tokens,
  so no input much past 4 KiB can finish inside the present limit.
- Cancellation: after the cancel the worker answered nothing more in that
  boot, and the next call stopped at the 90 s limit.
- Worker loss: the probe before was rewritten; the 16 KiB call during which
  the worker was killed reported the worker lost; so did the probe after
  it. The worker did not come back within that boot. A fresh boot did.
- Memory: the worker peaked at 20.50 GiB, the guest's virtual machine at
  0.50 GiB and the whole product at 21.04 GiB during the main boot; during
  the 40 ordinary messages alone the product peaked at 16.30 GiB. Swap grew
  by 5,345 MiB over the main boot and not at all during the ordinary
  messages, so the long inputs caused it.
- All cases: 47 of 57 rewritten; stopped: 5 timed out, 4 worker lost, 1 over
  the input limit. Installed on disk: 15.11 GiB.

What it did not show: fidelity or privacy (stage 4), the challenger, the
five hand-run steps (sleep and wake, battery, declared load, induced memory
pressure, first run after a restart), per-process GPU use, the daemon's
full serve path, and anything on a 32 GB Mac.

To settle before the next run, none changed here: whether a cancelled or
lost worker should be restarted within the same boot (today every later
call in that boot stops); what the limit for long inputs should be, since
90 s cannot hold them at this speed; and whether a 0.17 s miss on the
median stands on a quiet Mac.

Since this run (commit `d71605e`), a cancel stops the worker while it reads
the prompt, and a lost worker fails only its own call before a new one is
started; both faults above came from the old code, so this run's
cancellation and worker loss lines are not measures of the candidate, and
nor are the 128 KiB prose and 16 KiB literal inputs, which reached the
worker 4.3 s and 132 s late, behind timed-out calls it was still reading.
The main boot's worker crashed at power-off (exit status -11): it was still
on the cancellation case's rewrite, which it never answered, when the host
closed its channel. Since the shutdown fix of 12 November, a worker in that
position stops the rewrite, which fails, and exits cleanly.

The weights were deleted after the run, as Sean asked; a later run fetches
and verifies them again.

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

Feasibility again,
[feasibility-20261112T065257Z.json](../evidence/stage3/standin/feasibility-20261112T065257Z.json),
kit commit `d0716e9`, 12 November, with the daemon's local API and Pi now in
the guest (Pi idle; the kit's calls come from the daemon's rewrite code).
Development only, like the run above. The same 30 of 57 cases were
rewritten, with the same stops. Cold load 2.13 s, and the first result
came 3.85 s after the host started. The guest's virtual machine peaked at
0.54 GiB, up from 0.16 GiB, because its root is now about 75 MB compressed
and held in memory. The worker peaked at 3.46 GiB and the whole product at
4.14 GiB. Installed on disk: 1.76 GiB.

Feasibility after the cancellation and worker loss fixes,
[feasibility-20261112T151550Z.json](../evidence/stage3/standin/feasibility-20261112T151550Z.json),
kit commit `d71605e`, 12 November, on AC power with another lane testing.
Development only, like the runs above. One case changed, all others ended
as in the run above:

- Worker killed 2.03 s into a call: that call still ended as "worker
  lost" and was not sent again; the probe after it, which also ended as
  "worker lost" before, was rewritten in 1.88 s by a new worker the host
  started, of which 1.61 s was that worker's load. The first worker exited
  by the kill, the new one cleanly at power-off; the host exited cleanly.
- Cancellation as before: the worker answered 0.01 s after the cancel, and
  the next call was rewritten in 0.21 s. The stand-in reads this case's
  prompt in 1.2 s, so the cancel lands while it generates; a cancel while it
  reads a long prompt is shown by `tests/test_worker.py` and
  `tests/test_guest_path.py`, not by this run.
- All 57 cases: 31 rewritten; 14 malformed, 8 truncated, 1 timed out,
  1 cancelled, 1 worker lost, 1 over the input limit.
- Cold load 1.40 s, and the first result came 2.49 s after the host
  started. The worker peaked at 3.20 GiB and the whole product at 3.80 GiB.
  The path added a median of 1 ms; the most, 1.64 s, was the probe's wait
  for the new worker to load.

EVAL01 development screen,
[eval01-20261111T072816Z.json](../evidence/stage3/standin/eval01-20261111T072816Z.json),
kit commit `de16729`: 14 of the daemon's 16 cases rewritten, 2 stopped
malformed (privacy, spanish), and 9 passed the daemon's own checks. The
other five rewrites dropped something they had to keep: a number
(recommendations, bounds, ranking), a file path (conditional) or a word
(redundancy2). Median 0.21 s, slowest rewrite 0.54 s; the worker peaked at
2.04 GiB. An earlier run of the same kit logic gave the same results.

## Stage 4 so far

- The qualification kit is built: `uv run scripts/stage4.py`, with its
  measures in `scripts/holdouts.py`, `scripts/fidelity.py`,
  `scripts/privacy.py` and `scripts/parity.py` (commit `7deb2c6`). It runs a
  set's texts through the stage 3 path and keeps the same record of every
  call. No candidate has been judged and no gate has moved.
- Holdouts. Each is one JSON file a person writes, kept outside this
  repository. `check` tests it; `pin` records its sha256 in
  [holdouts.json](../reference/holdouts.json) once, before any model runs on
  it, and never replaces a pin. The kit refuses an unpinned or changed
  holdout, one inside the repository, a stand-in on a holdout, and any arm
  but the reference's own record as the reference. Records holding holdout
  text stay beside the holdout; only pins and content-free scores are kept
  here.
- EVAL02, fidelity. Per item: its text, language, the categories it covers
  (the spec's fourteen), the required meaning as relations and every
  protected span. A holdout must cover every category and at least three
  languages. Each output is stopped, critical (a protected span not kept as
  written, or a relation lost or reversed), minor or pass. Every output that
  keeps its spans goes to a blinded review: `review` writes a packet with
  each output under a random id, one at a time and without its arm, and a
  separate key. `fidelity` tabulates the pairs and the full cross-table,
  bounds candidate harm minus reference harm with Tango's score interval at
  97.5 % one-sided, and lists every candidate critical error, which blocks
  the candidate whatever the bound. An unreviewed output leaves the
  comparison unresolved.
- EVAL03, privacy. Per original: writer, session, topic, partition (train,
  tune or evaluation, by writer and session) and identifying spans.
  `privacy` runs attack 1 (character 3- to 5-grams, a linear classifier for
  attribution, cosine similarity for linkage) on the originals and on each
  arm, at 1 % false positives on different-author pairs, and bounds the
  per-writer difference with the exact sign-flip test at 97.5 % one-sided.
  It lists identifying spans the candidate kept where the reference did
  not, for a person to judge.
- `repeat` runs a development set several times and reports any output that
  differs; `sample-size` gives the EVAL02 holdout size at which a candidate
  with the development rates passes with probability at least 80 %, by
  exact sum over the paired outcomes.
- 35 checks in `tests/test_stage4.py` pass, including: Tango's bound is
  where the score statistic reaches the critical value and is
  z²/(n + z²) with no paired failure; a candidate as good as the reference
  never passes; the sign-flip bound equals the brute-force subset mean; the
  exact power equals a direct sum; pins, refusals and the blinded review
  behave as above.

### Stand-in proof (development only)

These runs prove the kit end to end on the development stand-in against
two development sets: [stage4-dev-fidelity.json](../reference/stage4-dev-fidelity.json)
(13 items written for the kit) and
[stage4-dev-privacy.json](../reference/stage4-dev-privacy.json) (60 synthetic
texts from six invented writers, made from templates). The comparator arm is
the unchanged originals, which a holdout never allows. None of these
figures is evaluated or counts toward any gate. All were run at kit commit
`7deb2c6`; the records' "uncommitted changes" flag is set only by Python's
bytecode folder and the proof's own new files, and every kit file hash in
them matches that commit.

- EVAL02, [eval02-20261112T050022Z.json](../evidence/stage4/standin/eval02-20261112T050022Z.json):
  9 of 13 rewritten, 4 stopped malformed (the exact-output, German, Spanish
  and long items); the worker peaked at 2.59 GiB.
- Review: [packet](../evidence/stage4/review/review-packet-20261112T050330Z.json),
  [key](../evidence/stage4/review/review-key-20261112T050330Z.json) and
  [answers](../evidence/stage4/review/review-answers-20261112T050330Z.json),
  19 outputs. The answers were filled by the kit's author, who wrote the
  items and could tell the originals apart: not a blinded review.
- Fidelity score, [fidelity-20261112T050330Z.json](../evidence/stage4/standin/fidelity-20261112T050330Z.json):
  stand-in 5 pass, 4 critical, 4 stopped. The critical errors: "12.5 kg" and
  "40 kg" written out as kilograms, a code span's backticks dropped, a
  quotation's marks dropped, and earlier context invented. Pairs: 8
  candidate-only failures, none reference-only; upper bound 0.823.
- Privacy, [eval03-20261112T050322Z.json](../evidence/stage4/standin/eval03-20261112T050322Z.json):
  25 of 36 rewritten, 9 malformed, 2 truncated. Score,
  [privacy-20261112T050331Z.json](../evidence/stage4/standin/privacy-20261112T050331Z.json):
  on the originals attack 1 attributed 24 of 24 and linked 18 of 24 pairs;
  on the stand-in 11 of 24 and 11 of 24, with 7 evaluation rewrites stopped
  and counted as successes. Synthetic text cannot satisfy EVAL03.
- Repeats, [repeat-20261112T050424Z.json](../evidence/stage4/standin/repeat-20261112T050424Z.json):
  three boots, no item's result differed.
- Sample size from the fidelity score: none, because the stand-in fails more
  than its comparator, as the protocol says.

### How the kit reads the protocol

The frozen protocol leaves these open; the kit fixes them in code before any
holdout exists. Sean confirmed them on 12 November (decision 3 below):

1. A stopped item counts as harm in both comparisons: a fidelity failure
   and an attack success. This keeps it in every denominator and stops a
   model looking better by stopping (spec DATA09).
2. Attack 1 learns from the training partition's originals for every arm;
   its one tuned setting is the classifier's regularisation, chosen from a
   budget of four by accuracy on the tuning originals. Each arm's threshold
   is set on its own rewrites of the tuning partition, so each is judged at
   its own 1 %. An attribution succeeds when the true writer scores highest
   and above the threshold.
3. "Several languages" is at least three; every output that keeps its spans
   is reviewed, not only ambiguous ones; any candidate critical error blocks
   the candidate (spec EVAL02, A04), with a note whether the reference also
   failed.

### Found in the protocol

The protocol says both intervals give a positive bound when no paired
errors are seen. That holds for Tango's interval. It does not hold for the
sign-flip bound as written: writers with no difference make the bound
exactly zero, which the parity rule would pass. The kit reports such a
bound as unresolved, never a pass, by Sean's ruling (decision 4).

### Not built, and why

- Attack 2, the learned authorship embedding. It needs a text encoder: one
  fetched from a model hub, or one trained from nothing with a large
  library added; neither was done. Without it the privacy gate cannot pass,
  and the score says so.
- A way to run the reference arm. The reference's inference server,
  quantization and thinking setting are unknown (A01), and it runs only on
  high-memory hardware. The scoring takes its record in the same format as
  a candidate's.
- The EVAL03 sample size. The protocol fixes the EVAL02 size from
  development rates; for EVAL03 it names no rule. At 97.5 % one-sided the
  sign-flip bound exists only from six evaluation writers.
- The 50 development items for the repeated runs. The two development sets
  here are for the proof; the protocol's set needs the reference too.

### Needs a person

1. The EVAL02 holdout: new texts annotated before any model runs on them,
   covering all fourteen categories and three or more languages, long inputs
   up to 128 KiB, kept outside this repository and pinned with `pin`. Its
   size comes from `sample-size` once the development rates exist.
2. The EVAL03 holdout: permitted authored text from several writers, topics
   and sessions, with partitions assigned by writer and session and the
   identifying spans marked, before any rewrite; at least six evaluation
   writers; and the permission that names where it may be processed.
3. Blinded reviewers for the fidelity packet, kept from the key.
4. The reference arm's records on both holdouts, at the reference's actual
   settings, on hardware approved for each set (rented hardware sees
   synthetic data only).
5. Development runs of every arm on the same development items, to fix the
   EVAL02 size and the repeat count before the holdouts open.
6. A statistician's confirmation of the readings above and of decision 4.
7. A person's judgment of each identifying span the candidate kept where
   the reference removed it.
8. The usability gate (A18): five first-time users through the full
   journey and an interruption exercise.

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
3. The stage 4 kit's readings of the protocol (stage 4, "How the kit reads
   the protocol"). Decided 12 November (Sean, 2a): the stricter readings
   stand as written there.
4. A sign-flip bound of exactly zero from writers with no difference.
   Decided 12 November (Sean, 3a): it is not a pass, matching the
   protocol's statement that data with no paired errors never passes.
5. How Tor's traffic leaves the guest. Decided 12 November (Sean: "use the
   reference - use open source tor node?"): follow the reference, torsocks
   in front of the standard open source `tor` on the public Tor network.
   The guest still gets no network device; its one way out is to be a
   single relay to the Tor port, so that a program which skips torsocks
   reaches nothing. Not built yet; A06 stays open until it is checked.

## Gates

| ID | Test | State | Evidence |
| --- | --- | --- | --- |
| A01 | Reference integrity | Open: sources, wrapper (reconstructed), contract and model files pinned; reference inference settings and payment deployment unknown | [baseline](../reference/baseline.md), [contract](../reference/rewriter-contract.md), [models](../reference/models.md) |
| A02 | Clean Mac installation | Open | |
| A03 | GUI and CLI equivalence | Open | |
| A04 | Fidelity | Open: scoring kit built and proven on development data only; no holdout | `scripts/stage4.py`, `scripts/fidelity.py` |
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
| A22 | Authorship and linkability | Open: attack 1 and the sign-flip bound built and proven on synthetic development data only; attack 2 not built; no holdout | `scripts/stage4.py`, `scripts/privacy.py` |
| A23 | Long and cold tasks | Open | |
| A24 | Artifact provenance | Open: files pinned; two conversion mismatches found | [models](../reference/models.md) |
| A25 | Single implementation | Open | |
| A26 | Performance claims | Open | |
