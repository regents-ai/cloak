# Changelog

## Unreleased

- The app can open at login: one switch, Login, in the Details window,
  off until you turn it on, which adds the app to the system's login items
  (System Settings opens if it needs your approval there). The app opened
  at login is Paused, as at every launch, and starts nothing until Start.
  New check in `swift test --package-path app`.

- The app: Pause or Quit while the worker loads its model now takes effect
  at once; the worker is stopped there and then. Before, the app waited
  for the load to end first. Tor's bootstrap and the guest's boot already
  stopped at once. New check in `swift test --package-path app`.

- The app's Details window now comes to the front and takes the keyboard
  when it opens from the menu. Before, it could open behind the app in
  front, since a menu-bar app is never the app in front. While the window
  is open the app shows in the Dock; closing it (its close button,
  Command-W or Escape) makes it a menu-bar app again, still running.
  Checked with real clicks on the status item.

- Stage 3: the small lead on llama.cpp with the reply grammar (14 November)
  is recorded in evidence/stage3/small-lead-gguf-grammar/ and written up in
  docs/plan.md: 39 of 40 ordinary messages rewritten, none malformed, one
  runaway timed out; median 1.09 s; whole product 6.74 GiB. No gate closes
  on it. The weights were deleted afterwards.

- The app's guests now write their boot files, which hold the relay's
  channel token and the rewriter key while a guest starts, in a folder of
  the app's own, `control/boot/` in its Application Support folder, and
  each launch first removes every guest's folder a killed app left there,
  and nothing else; if it cannot, the app says it can't open. Before, they
  stayed in the temporary folder until the system cleared it.
  `cloak-host` still writes them in its temporary folder. New check in
  `swift test --package-path app`.

- `scripts/fetch_model.py`: a download cut short stops the run and keeps
  its `.part`; the next run asks the server for the rest only (an HTTP
  Range request), and starts the file again if the server sends it whole.
  Before, every run fetched each file from its first byte, and a
  connection the server closed early left a short file set aside as
  `.bad`. New `tests/test_fetch_model.py`, against a local server.

- `docs/state-machines.md`: the llama worker's one rewrite (section 1a),
  with its grammar step.

- Decision 9: the reply grammar, as candidates of their own. The llama
  worker can decode under a grammar, `reference/rewrite-reply.gbnf`,
  through llama.cpp's own grammar sampler: `{"texts":[...]}` with as many
  texts as the request holds, which the worker sets from each request, and
  any white space and text the daemon's check takes. It differs from the
  daemon only in taking the key spelled `"texts"`, once. Decoding stays
  greedy, the daemon's check is unchanged and nothing repairs a reply. A
  model entry pins the grammar by sha256 (`grammar` in
  `reference/models.json`); the worker is built with it and refuses any
  other; an MLX model's entry cannot carry one. New entries:
  `small-lead-gguf-grammar` and `small-challenger-gguf-grammar`, the
  GGUF pair's files under the grammar, which join the candidates (eight
  now), and `standin-gguf-grammar` for development. Records carry the
  grammar's pin in their configuration. Entries without a grammar decode
  as before, byte for byte. On the stand-in
  (`evidence/stage3/standin-gguf-grammar/`): the four-turn conversation
  the daemon refused is now accepted, and EVAL06 is again 38 of 40, each
  reply as before, with e06-10 now running on to the time limit instead of
  malformed. New checks: `tests/test_llama_worker.py` judges replies with
  the daemon's own check, built with Go from the pinned daemon source
  (`tests/daemon_reply/`), and `tests/test_worker.py` runs its checks on
  the llama worker under the grammar too.

- Both workers: the hash check before the model loads now lets go of each
  8 MiB block of a file once it is hashed. Before, the llama worker kept
  every block until its load had ended, so it held the model file beside
  the loaded weights: the 9B on llama.cpp peaked at 11.54 GiB over its
  life (whole product 9.11 GiB, and 10.63 GiB in the worker-loss boot,
  over the 10 GiB line) against 6.6 to 6.7 GiB after its rewrites. On the
  GGUF stand-in, the stage 4 repeat before and after
  (evidence/stage4/standin-gguf/) gives the same 39 outcomes and texts
  byte for byte, the worker's peak falls from 3.45 to 2.07 GiB and the
  whole product's from 3.42 to 2.64 GiB. The 9B was not run again.
  docs/plan.md ("Memory on llama.cpp") also records what was found and
  left: the allocator's hold on freed load buffers, the stand-in's word
  table held twice, and each rewrite's context.

- Stage 3: the small lead's first run on llama.cpp (14 November) is recorded
  in evidence/stage3/small-lead-gguf/ and written up in docs/plan.md: 27 of
  40 ordinary messages rewritten, 13 stopped malformed, whole product
  9.11 GiB. On both engines the malformed replies close the JSON wrongly.
  No gate closes on it. The weights were deleted afterwards.

- Stage 3: a development run of the GGUF stand-in on llama.cpp (decision
  8) is recorded in evidence/stage3/standin-gguf/ and set beside the MLX
  stand-in's latest run in docs/plan.md: 38 of 40 ordinary messages
  rewritten against 24, median 0.37 s, the whole product's peak 3.27 GiB
  against 2.90 GiB. Development only; it counts toward no gate.

- Stage 5 has started, with a development build of the app's core. One
  supervisor (`app/`) checks the Mac and every installed part against the
  bundle's manifest, starts tor, the worker and a check guest, watches tor
  and the worker, and stops everything through one shutdown. Its six states
  are one state machine (docs/state-machines.md, section 9). Any failure
  ends in Needs attention with a reason code, everything stopped and
  nothing restarted; every launch, sleep and relaunch leaves it Paused. A
  menu-bar app, `Regents Cloak.app`, and the `cloak` command (`status`,
  `start`, `pause`, `resume`, `stop`, `verify`, `doctor`, with versioned
  JSON) drive the same supervisor over an owner-only local socket. It runs
  only the development stand-in, labelled as such, and has no sessions,
  payment, wallet or cover. `app/build.sh` builds it, signed ad hoc. The
  host's parts are now a library (`host/Sources/CloakHost/`) used by the
  app and by `cloak-host`, whose command line is unchanged. A lost worker,
  a finished worker and tor now each get 10 seconds to exit before they are
  killed; before, the host waited for them without limit, so a worker that
  ignored being stopped hung it. New checks: the supervisor's state
  machine, its failures with stand-in processes, the JSON for each status
  and the socket's refusals (`swift test --package-path app`), and a lost
  worker that ignores being stopped (`tests/test_worker_stop.py`).

- Stage 3 kit: when the worker-loss boot's kill comes after the worker has
  already ended, the kit records the kill as not made (`killed: false`) and
  carries on; before, it stopped with an error and wrote no record. The
  GGUF stand-in found it: it rewrote the 10,000-character input, and the
  boot's last call, inside the 2 s before the pinned kill point, so the host
  had ended the worker. Each kill now notes `killed` beside
  `call_was_open`, and the printout shows both.

- Stage 3 and 4 kits: each model's `engine` picks its worker (decision
  8). `scripts/drive_worker.py` starts the installed worker of the model's
  engine (its `--worker` option is gone). The stage 3 kit checks, runs and
  sizes that worker, records the engine and its pinned source (llama.cpp's
  commit, or the mlx-swift and mlx-swift-lm revisions) in each record's
  configuration, and reads each engine's own memory lines: for the llama
  worker, the weights' size and llama.cpp's Metal memory after the load,
  and each rewrite's context size and Metal memory. A record's memory
  figures are named for its engine (`mlx` and `mlx_memory`, or `llama` and
  `llama_memory`). The GGUF pair joins the candidate list, so both kits
  take six. `tests/test_worker.py` runs every check on both workers, each
  with its stand-in (55 checks), its altered model folders now under
  `.checks/<model>/`. New `tests/test_llama_worker.py`: the llama worker
  gives the model the same prompt tokens as the MLX worker on six requests,
  chat markers in the text among them; each worker refuses the other
  engine's models; the llama worker links no network or server code; it
  logs numbers only, and llama.cpp writes nothing.

- Stage 2: the llama worker (decision 8). `llama-worker/` builds
  `cloak-rewriter-llama`, a drop-in for the MLX worker: the same frames,
  command line, replies and pinned-file check, signed into the App Sandbox
  with the MLX worker's entitlements and installed beside it by
  `llama-worker/install.sh`. It has no inference code of its own: llama.cpp,
  built from the pinned v1.0.0 source with Metal by
  `llama-worker/build-llama.sh` (llama.cpp's own CMake build, static, its
  shaders built in, without its server, tools or HTTP client), reads the one
  GGUF file into memory, renders the pinned vendor chat template with
  thinking off, and decodes greedily. Every llama.cpp setting that could
  change a result or the memory a rewrite takes is written out, and
  llama.cpp's GGML_ and LLAMA_ environment settings are cleared. Each
  rewrite gets a context of its own, sized for its prompt and every token
  it allows, so nothing carries over between rewrites. The prompt is read
  512 tokens at a time, with a check for a cancel before each chunk and each
  token; a second request while busy, a bad frame or the end of the channel
  stops the rewrite first, then the worker. It logs numbers only, among
  them the weights' size and llama.cpp's Metal memory; llama.cpp's own log
  is dropped but for errors while loading. The frames, the daemon's
  request, the replies and the model pins move from `worker/` into
  `rewriter-kit/`, one local package both workers use, and each worker
  refuses a model pinned for the other engine. Each install script also
  builds a check tool that prints the prompt tokens its worker gives the
  model.

- Stage 1: llama.cpp joins as a second rewriter engine, for a measured
  choice (decision 8, Sean, 13 November). llama.cpp release v1.0.0 (commit
  b1b770d9) is pinned in reference/sources.json, and three GGUF models are
  pinned file by file in reference/models.json: a development stand-in,
  `standin-gguf` (Unsloth's Q4_K_M of Qwen3.5-2B), and two candidates,
  `small-lead-gguf` (Unsloth's Q4_K_M of Qwen3.5-9B) and
  `small-challenger-gguf` (Google's own Q4_0 GGUF of Gemma 4 12B), each
  with the vendor chat template its MLX twin uses. Every model a worker runs
  now names its `engine`, `mlx` or `llama`. scripts/pin_models.py takes one
  file of a repository that holds several (`only`); rerun, it reproduces
  the file byte for byte. reference/models.md records sizes, licences and
  provenance: no vendor GGUF exists for the Qwen models, and Google's GGUF
  is a different checkpoint from the MLX conversion's. docs/plan.md records
  decision 8, a departure from spec section 1 and MAC02 for the experiment
  only: exactly one engine ships and the other is deleted. AGENTS.md's
  one-implementation rule names that exception.

- Stage 3: the small lead's first feasibility run ("run 3", 13 November) is
  recorded in evidence/stage3/small-lead/ and written up in docs/plan.md.
  The whole product peaked at 7.22 GiB against the 10 GiB line; 36 of 40
  ordinary messages were rewritten and 4 stopped malformed; median 1.08 s.
  No gate closes on it. The weights were deleted afterwards.

- Stage 2 and 3: memory. The worker gives MLX's cache back to the system
  after loading, before its first request (on the stand-in, 0.83 GB of
  loading leftovers), and logs MLX's own active, cache and peak memory, as
  numbers only, after the load and with each rewrite. The host now waits for
  a lost worker to exit before it starts the next one, so two workers never
  hold the model at once; the stage 3 kit's tap likewise exits only after
  its worker. The kit's samples add up every worker process alive, read the
  host's tor as its own figure, and count both in the whole-product peak;
  each record keeps MLX's figures per load and per call. The samples' shape
  changed outright (`workers` by pid, and `tor`, in place of `worker` and
  `worker_pid`). New checks: a lost worker has exited before its
  replacement starts; a terminated tap exits only after its worker; the
  sampler reads every worker alive and the host's tor; a window sums
  workers alive at once and counts tor. The stand-in's outputs are byte for
  byte the same before and after (13 development items, three runs each),
  and a stand-in feasibility run after the change peaked at 2.90 GiB for
  the whole product, development only.

- Stage 1: two smaller candidates join the lead and the challenger (decision
  7, Sean, 13 November): the small lead, `mlx-community/Qwen3.5-9B-4bit`,
  and the small challenger, `mlx-community/gemma-4-12B-it-4bit`, each pinned
  file by file in `reference/models.json` with the vendor checkpoint it was
  made from (`Qwen/Qwen3.5-9B`, `google/gemma-4-12B-it`) and, as decision 1
  says, taking its tokenizer and chat template files from that vendor. The
  six earlier entries are unchanged. `reference/models.md` records their
  sizes, licences and provenance findings. The stage 3 and stage 4 kits take
  the four candidates from one list, `GATE_MODELS` in `scripts/stage3.py`.
  `docs/plan.md` records decision 7, a departure from spec section 1, which
  names two candidates: the memory pass line is 10 GiB for the whole running
  product (9.3 GiB the aim), one model still ships, each small candidate
  faces stage 4 from scratch, and the protocol's confidence split, which
  assumes two candidates, must be re-declared before any holdout opens.

- The repository is private on GitHub at regents-ai/cloak; `AGENTS.md` now
  says agents commit and push to main, and that public release, signing
  keys and notarization remain Sean's.

- Stage 2: tor keeps its state between runs. Its data folder is no longer
  a new temporary folder removed when tor stops, which made every boot pick
  new entry guards and bootstrap from nothing; it is one lasting folder the
  host is given with the new `--tor-data` flag, created owner-only if
  missing and never removed, so tor keeps its entry guards as the Tor
  Project recommends and later starts bootstrap from what it saved (in one
  measurement, 9.52 s for a first start and 2.41 s for a second). The
  stage kits use `~/Library/Application Support/Regents Cloak/tor`; the
  checks pass scratch folders. A second host on the same folder gets a tor
  that exits after 5 seconds (tor's own lock), and its guest's tasks stop at
  their Tor route. New check: a second start reuses the folder and its
  state file. `docs/plan.md` also lists, as a known gap, that tor's SOCKS
  port serves every program on the Mac while tor runs, until Cloak is
  packaged as an app.

- Stage 2: the host's 90-second limit for tor now covers its whole start,
  counted from tor's start: the SOCKS port line as well as the bootstrap
  line, read on one thread with one wait. Before, the wait for the port had
  no limit, and a tor that hung before opening it hung the host; now that
  tor is stopped and the host fails before the guest starts, as when tor
  exits before its port opens. And once tor has stopped (it exited, or the
  host stopped it at the limit), the host's Tor relay connects nothing to
  its port, which another program on the Mac may then take: each guest
  connection is closed without a byte, and the relay's open connections to
  tor are shut. Before, the relay still connected guest Tor traffic to the
  freed port. The guest sees no change: the task stops at its Tor route
  ("no direct fallback was used"). Two new checks in
  `tests/test_tor_path.py`: a stand-in tor that never opens its port, and a
  listener that takes a stopped stand-in's port and receives nothing.

- Stage 2: the host starts the guest only once tor says it has bootstrapped
  ("Bootstrapped 100% (done)" in tor's own log), so a task at the start of a
  boot passes its Tor route; before, it stopped there, as tor refuses every
  request for its first seconds. A cold start is longer by tor's bootstrap
  (7.4 s in one run). A tor that exits while bootstrapping, or has not
  finished 90 seconds after it started (the default of the Tor Project's
  stem library for the same wait), is treated as gone: the host stops one
  still running, the guest starts, and every Tor connection fails; nothing
  is retried or routed another way. The stage 3 record gives tor's
  bootstrap as its own figure; the first result after the host started now
  includes it. Two new checks in `tests/test_tor_path.py` (a task started
  with the host; a tor that never bootstraps), the stopped-tor check now
  covers one that exits while bootstrapping, and the live check no longer
  waits for tor itself.

- Stage 2: the input limit and deadline of decision 6 (Sean, 12 November).
  A user turn of more than 10,000 characters (Unicode scalar values) is
  refused before any call, with a message giving its length and the limit;
  this replaces the 128 KiB input limit. Each rewrite call gets 90 seconds
  plus 20 ms a character (110 s at 1,000 characters, 290 s at 10,000) in
  place of a flat 90 seconds. The daemon's files are patched into copies at
  build time (`guest/daemon/rewriter.patch`, `guest/daemon/server.patch`);
  the pinned source is untouched. A departure from the spec's limits by
  Sean's ruling, recorded in `docs/plan.md` and
  `reference/rewriter-contract.md`. The stage 3 kit pins the new
  `reference/eval05-cap-inputs.json` beside EVAL05, which is unchanged, and
  sizes each boot's time limit by the new deadline; the stage 4 kit refuses
  a holdout text over the limit.
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
