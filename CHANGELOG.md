# Changelog

## Unreleased

- Stage 2: Tor's way out of the guest (decision 5). The host runs the Tor
  Project's tor 0.4.9.16 (macOS expert bundle 16.0.1, pinned by size and
  sha256 in `reference/sources.json`, unpacked and signed by the new
  `host/build.sh`) as its child, with the reference's settings, its SOCKS
  port on a free loopback port and its state in a private folder removed
  when it stops. The guest still has no network device: its Tor port,
  `cloak-tor-port`, carries each connection over vsock to the host, which
  passes only a SOCKS5 greeting on to tor and closes anything else. A Pi
  task now passes its Tor route and stops at the wallet companion, which is
  not built. A tor that stops or cannot reach the network stops the task.
  The agent check's route observer is gone; the checks use a stand-in tor
  (`tests/fake_tor.py`) instead. Four checks in `tests/test_tor_path.py`,
  one of them on the public Tor network. A first build put tor's SOCKS port
  on a socket file, where tor answers in a form torsocks misreads, and TLS
  through Tor failed; found by the live check and moved to loopback. The
  stage 3 and stage 4 kits now run tor on the public Tor network in each
  boot, and the stage 3 record keeps tor's hash and size.
- Stage 2: a worker that stops for a protocol fault (a second request while
  busy, an unknown or oversized frame, input cut inside a frame) now stops
  the rewrite in progress first, answers it as cancelled and exits with
  status 2; before, it exited mid-rewrite and crashed (exit status -11), as
  at shutdown before the fix below.
- Stage 2: a worker still rewriting when the host shuts down now stops that
  rewrite, answers it as cancelled and exits cleanly; before, it crashed
  (the lead's main boot ended with its worker at exit status -11).
- Stage 3: a stand-in feasibility run after the cancellation and worker loss
  fixes (development only, counted toward no gate) is in
  evidence/stage3/standin/; the probe after the killed worker is now
  rewritten by a new worker, and docs/plan.md records its figures.
- Stage 2: a cancel now stops the worker while it reads a long prompt; before,
  it waited for the whole prompt (217 s for 128 KiB on the lead), and the
  rewrites queued behind it ran out of time. A lost worker now fails only the
  rewrite it had, never sent again, and the host starts a new worker from the
  same program and pinned files for the next one; before, every later rewrite
  in that boot failed. A new worker that cannot start still fails every later
  rewrite. The stage 3 record lists each worker process in a boot.
- Stage 3: a stand-in feasibility run with Pi and the daemon's local API in
  the guest (development only, counted toward no gate) is in
  evidence/stage3/standin/; docs/plan.md records its figures.
- Stage 2: Pi 1.3.0 runs in the guest inside the reference wrapper
  (bubblewrap with torsocks) as its own user, talking to the daemon's own
  local API, which now runs in the guest and rewrites through the adapter.
  The guest still has no network device and no Tor: each model request is
  rewritten, then stops at Tor route preparation. The host gives the guest
  an entropy device, which only carries random bytes in. Six checks in
  `tests/test_agent_path.py` cover the rewrite, conversation isolation, a
  bad rewrite, a lost worker and what the sandbox can reach.
- Reference wrapper: the sandbox now puts Pi's provider file where Pi reads
  it (`~/.pi/agent/models.json`); before, Pi refused the `zkapi` provider.
- Stage 2: Node.js 24.22.2 for Pi in the guest is pinned by size and sha256 in
  `reference/sources.json`. `scripts/fetch_sources.py` downloads a pinned
  file once, after a free disk check, and keeps a mismatch aside; with
  `--check` it only verifies what is already on disk.
- Stage 4: the stand-in proof of the qualification kit (development only,
  counted toward no gate) is in evidence/stage4/, and docs/plan.md records
  what was built, how the kit reads the protocol, a conflict found in the
  protocol's sign-flip claim, and what only a person can supply.
- Stage 4: the qualification kit. `scripts/stage4.py` pins and checks the
  fidelity (EVAL02) and privacy (EVAL03) holdouts, rewrites a set through the
  stage 3 path, makes the blinded fidelity review, and scores a candidate
  against the reference under the frozen protocol: Tango's paired interval
  for fidelity, the exact writer sign-flip bound for attribution and
  linkage with the character n-gram attack, each at 97.5 % one-sided with no
  positive margin. It also measures run-to-run variation and sizes the
  fidelity holdout from development rates. Holdout text stays outside the
  repository; only pins and content-free scores are kept here. Added two
  development sets, never holdouts, and checks of the kit's logic.
- Stage 3: the feasibility kit. `scripts/stage3.py feasibility <name>` writes a
  candidate's stage 3 record (EVAL05, EVAL06, EVAL07) through the real path, and
  `scripts/stage3.py eval01 <name>` runs the development screen. Added the fixed
  synthetic EVAL05 inputs and EVAL06 messages, pinned by hash before any candidate
  ran, a copy-only tap that keeps each call's raw reply, and checks of the kit's
  logic. The stand-in proofs (feasibility and EVAL01, development only,
  counted toward no gate) are in evidence/stage3/standin/ and their figures
  in docs/plan.md.
- Stage 3 kit: times now use the clock the unified log uses, which keeps
  counting while the Mac sleeps, so the worker's own timings land on the
  right call; and the guest's virtual machine is found as the one that
  appeared after the host started, so its memory and CPU are recorded.
- Stage 3 kit: when it is stopped from outside, by a watcher or a person,
  it now stops its guest and its log reader and removes its scratch files,
  and writes no record.
- Progress lives in docs/plan.md; the `bd` instructions are gone from the readme
  and AGENTS.md.
- Adopted spec v0.4 in place of v0.3: a native Mac rewriter with a smaller
  model, six stages and gates A01 to A26. Plan, rules and readme follow it.
- Stage 1: captured the rewriter contract; it is identical at both daemon pins.
- Stage 1: pinned every file of the reference model, both candidates and their
  vendor checkpoints, with a script that records them without downloading
  weights. Found that the lead conversion splits words differently from Qwen's
  own tokenizer and that the challenger conversion has Google's chat template
  from before a fix.
- Stage 1: drafted the evaluation protocol.
- Stage 2: pinned a small development stand-in model (Qwen3.5 2B, 4-bit,
  same model code as the lead) for building the worker, and added a script that
  downloads a pinned model and checks every file. The stand-in is never
  evaluated and never ships.
- Stage 1: proposed values for the evaluation protocol's open items (attacks,
  intervals, confidence, sample size, repeat runs); they need sign-off.
- Recorded Sean's decisions of 30 October: candidates use their conversion's
  weights with the vendor's own tokenizer and chat template; no 32 GB Mac is
  tested, so 32 GB support stays unmet and at most a limited 48 GB pilot is
  possible.
- Stage 2: added the native rewrite worker. It loads a model only after every
  file matches its pin, applies the model's own chat template with the pinned
  settings, decodes greedily, runs one rewrite at a time, and answers in the
  shape the daemon reads. A cancel from the supervisor stops the rewrite; any
  protocol fault stops the worker. Twenty functional checks cover refusals,
  the token limit, cancellation, a second request while busy, bad frames and
  tampered model files.
- Stage 2: added the guest and the host. The guest is a minimal Linux image
  with no network device in which the daemon's own rewrite code calls a small
  adapter; the adapter forwards each request unchanged over one token-checked
  virtio socket to the host, which relays it to the worker. Sixteen checks
  drive the whole path: unchanged requests, nine kinds of bad reply refused,
  cancellation, the daemon's deadline, and a lost worker.
- Stage 2: the worker now runs in Apple's App Sandbox with no network and
  reads files only in ~/Library/Application Support/Regents Cloak/models/,
  where models are now downloaded. Its model pins are built into it, so the
  signed worker decides what it loads. worker/install.sh builds, signs and
  installs it. New checks show the network is refused and folders outside the
  models folder cannot be read.
- Decision 1 in the model pins: each candidate's file list now takes the
  vendor's tokenizer and chat template files from its vendor checkpoint, and
  the download script fetches each file from where it is pinned. Both
  candidates are pinned with thinking off. Re-recording from the hub changed
  no other byte.
- Froze the evaluation protocol with every proposed value, by Sean's sign-off
  of 30 October.
- Stage 2: named every staged process in the code and listed them in
  docs/state-machines.md. Doing so found and fixed three faults in the host:
  a worker that died between rewrites ended the host instead of failing the
  next rewrite; a client that gave up before the worker had its request lost
  its cancel, so the abandoned rewrite ran on and the next one failed at the
  daemon's deadline; and the secret boot files were written before the guest
  was checked, so a failed check would have left them on disk. The guest now
  waits for the adapter to say it is ready instead of polling for up to five
  seconds. Two new whole-path checks show the first two faults fixed.

- Started the repository for the Regents Cloak Mac app, with spec v0.3, the
  plan and gates A01 to A19.
- Stage 1: pinned the reference sources (the post's zkAPI daemon commit, the
  spec's later snapshot, Pi 1.3.0) with a fetch script that verifies every pin.
- Stage 1: rebuilt the daemon at the post's commit; its own checks pass.
- Stage 1: reconstructed the unpublished Pi sandbox wrapper and a Linux host to
  test it. Found that programs which skip torsocks reach the internet directly.
- Stage 1: the reconstruction is now the Regents reference, by Sean's ruling.
- Agent rules now require the macos-app-skills for all Mac app work, each
  mapped to the stage it serves and the spec limits that win over it.
- Stage 3: the lead candidate's first feasibility run is recorded (12 November).
  40 of 40 ordinary messages rewritten, median 5.17 s against a proposed 5 s;
  inputs of 16 KiB and more stopped at the 90 s limit; the worker peaked at
  20.50 GiB. No gate closes on it. The weights were deleted afterwards.
- Sean's rulings of 12 November recorded: the stage 4 kit's stricter readings
  stand, a zero privacy bound from no-difference writers is not a pass, and
  Tor leaves the guest the reference's way.
