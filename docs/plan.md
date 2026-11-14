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
| 3. Check feasibility early | Runs of each of the eight candidates (the lead, the challenger, decision 7's small pair, decision 8's GGUF pair on llama.cpp and decision 9's same pair under the reply grammar) on a specified 48 GB Mac with the full stack loaded (no 32 GB machine; decision 2) | Input, deadline and memory risks measured before the large privacy evaluation | Kit ready; the lead has two runs, the small lead and its GGUF one each, the other five candidates none |
| 4. Qualify the substitution | Separate fidelity and authored privacy holdouts; one pinned winner among the eight candidates or an explicit no-pass | Protection, fidelity, statistical and usability gates pass | Kit in progress: no holdout, reference run or candidate result yet; the confidence split for eight candidates is to be re-declared before any holdout opens (decisions 7 to 9) |
| 5. Package the product | Signed full bundle, shared CLI and menu-bar supervisor, setup, recovery, updates | Clean-machine and full real-service tests pass | In progress: a development build of the supervisor, the menu-bar app and `cloak`, on the stand-in only ("Stage 5 so far"); no signed full bundle, setup, recovery, updates, sessions, payment or cover |
| 6. Release at the planned home | Download, guide and evidence for supported configurations | A01 to A26 pass; claims and hardware scope match results | Not started |

Stage 2 builds and tests the path with a small model labelled as a
development stand-in, so it runs light on the development Mac (an M4 Max with
48 GB, macOS 27.0). The candidates' weights (about 16 GB each for the lead
and the challenger, 6 to 7 GB for the small pair) are first loaded in stage 3,
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
- The reference model, the four candidates and their vendor checkpoints are
  pinned file by file: [models.md](../reference/models.md). Decision 1 settled
  the provenance findings there: each candidate takes its tokenizer and chat
  template files from its vendor.
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
  rewrite code (`internal/rewriter`, built from the pinned module, with
  decision 6's input limit and deadline patched into a copy) calls a
  guest adapter on its usual local address; the adapter forwards each request
  unchanged over one virtio socket with a per-boot token.
- The host (`host/`) boots the guest with Virtualization.framework, checks
  the token, relays to the worker, turns a dropped guest connection into a
  cancel, and treats a lost worker as a failure for the rewrite it had (never
  sent again); once the lost worker has exited, it starts a new worker from
  the same program and pinned files for the next rewrite, so two workers
  never hold the model at once. A new worker that cannot start leaves every
  later rewrite failing. After loading, the worker gives MLX's cache back to
  the system before it takes a request.
- 23 checks in `tests/test_guest_path.py` pass: the request reaches the
  worker byte for byte; nine kinds of bad reply are refused by the daemon's
  code and the next rewrite still works; a client that gives up cancels the
  worker, even before the worker has its request; under decision 6, a short
  input keeps the 90-second base deadline, the longest input accepted
  (10,000 characters, two bytes each) is rewritten after 100 seconds and,
  when the worker holds it, stopped at its own 290, and one character more
  is refused at once, naming its length and the limit, with nothing sent to
  the worker; a lost worker (fake or real, killed mid-rewrite, or gone
  between rewrites) fails only the rewrite it had or the one that found it
  gone, and a new worker serves the next, started only once the lost one has
  exited, even when it is slow to exit; a new worker that cannot start
  fails every later rewrite; the real worker rewrites through the whole path
  and is free again within seconds of a cancel, also one 300 ms into the
  longest prompt accepted.
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
  files stay untouched, but for the two copies decision 6 patches) that
  builds the API exactly as the daemon's own
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
- The Tor port, `cloak-tor-port` as user `torport`, leads to tor on the Mac
  ("Tor out of the guest" below). In these checks the host's tor is a
  stand-in (`tests/fake_tor.py`) that records each SOCKS identity, as a
  short hash, and the destination asked for, then refuses. So each model
  request is rewritten, then stops at Tor route preparation with the daemon's
  own message: "no direct fallback was used".

Seven checks in `tests/test_agent_path.py` pass:

- Pi's new turn reaches the worker byte for byte as the daemon's rewrite
  request, and the task then stops at the Tor route.
- A continued conversation (`pi -c`) keeps its SOCKS identity; a new one
  gets another.
- A bad rewrite reply stops the task with the daemon's rewrite error before
  any model request, and the next task still runs.
- A lost worker stops its task the same way, and the next task runs on a
  new worker.
- A prompt over 10,000 characters (decision 6) stops its task with the
  daemon's message naming its length and the limit, with nothing sent to
  the worker, and the next task runs. Pi shows that message inside its own
  error line, after the status and the error's code
  (`413: {"code":"input_too_long","message":"This message is 10,001 characters long, ..."}`).
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

- **Cover traffic**: needs operator-chosen destinations. Not built, by
  instruction.
- **Payment vault, funding, wallets**: not deployed at the pinned commit
  (A11). Not built, by instruction.
- **The daemon's real `serve`** in place of the harness: needs the two above.
- **A real answer to Pi**: with Tor, a task passes its Tor route and stops
  at the wallet companion, so Pi's tools never run on a model's answer.

### Tor out of the guest (built 12 November 2026)

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
  socket, passes tor's answers back in the form tor gives on a network
  port (below), and copies both ways until either end closes. It takes no
  address
  from the guest; its one destination is tor. The host listens on no vsock
  port but this one and the rewrite relay's 8012.
- **tor**: started by the host after the worker and before the boot files,
  with no configuration file. Its settings are the reference's
  (`SocksPort … IsolateSOCKSAuth`, `Log notice stdout`), with the SOCKS port
  on a socket file instead of the Mac's loopback (since 14 November, below):
  `unix:<folder>/socks`, in a folder the host makes for each start in the
  person's temporary folder, owner-only (0700; tor refuses any other), and
  removes once tor has stopped. Nothing of tor's listens on the network.
  tor takes any user name and password, which it uses only to keep
  conversations apart, so that folder is what keeps others out. Its log
  goes to the host's standard error. The host is its owning process: a host that dies
  without stopping it ends it within about 15 seconds. The host never
  restarts it.
- **The host waits for tor's bootstrap** (decided 12 November): tor refuses
  every request at once until it has enough of the Tor network's directory
  and has built a circuit (about 9 seconds after it started in one check,
  7.4 s in another), so the host starts the guest only once tor says so,
  in its own log line "Bootstrapped 100% (done)". The host already reads
  tor's log to see its SOCKS port open and keeps reading for that line,
  waiting on it with one limit and no polling: 90 seconds from tor's
  start. tor itself never gives up; 90 s is the default of the Tor
  Project's own controller library, stem, whose `launch_tor` waits for the
  same line and says a tor with no saved state, as this one is on its first
  start, usually bootstraps "in 50 seconds or so"; later starts reuse the
  state tor saved ("tor keeps its state" below). A cold start is longer by
  tor's bootstrap, the secret boot files are written only after it, and a
  task at the start of a boot no longer stops at its Tor route. A tor
  that exits while bootstrapping ends the wait at once; one not done at
  90 s is stopped by the host. Either way the guest then starts with tor
  gone, so every Tor connection fails and each task stops at its Tor
  route, while rewrites, which need no Tor, still run. Nothing is retried,
  tor is not restarted, and nothing is routed another way.
- **One limit for the whole start** (12 November, after the bootstrap
  wait): the wait for tor's SOCKS port line had no limit, so a tor that
  hung before opening its port hung the host. The same 90 seconds from
  tor's start now covers the port line and the bootstrap line together:
  one thread reads tor's log from its start, and the host waits on it once.
  A tor whose port has not opened by then is stopped, and the host fails
  before the boot files are written ("cannot start Tor: its SOCKS port did
  not open within 90 seconds; stopped it"), as it fails when tor exits
  before its port opens.
- **Nothing reaches tor's port once tor has stopped** (12 November, the
  same day): tor's SOCKS port was then a free port on the Mac's loopback,
  so once tor had exited another program on the Mac could take it, and the relay
  still connected guest Tor traffic to it. The host now counts tor as
  stopped from tor's own exit (the process's termination notice) or from
  stopping it at the limit, and from then on the relay connects nothing to
  that port: each guest connection is closed without a byte, as when tor
  cannot be reached, and the relay's connections to tor still open then
  are shut. The relay checks and connects under one lock, so no connection
  starts after that moment. The guest sees what it saw before: the daemon's
  route check stops the task ("no direct fallback was used"). Left open:
  the moment between tor's exit and the system's notice of it, in which a
  program that took the port at once could still receive a connection.
  Since tor's port became a socket file (below), the host removes its
  folder once tor has stopped; only a program of the person's own could
  make the folder again and take the name, and it receives nothing either.
- **tor keeps its state** (12 November, after the two notes above): tor's
  folder was new for every boot, in the host's temporary folder, and
  removed when tor stopped, so every boot chose new entry guards and
  bootstrapped from nothing. Now tor's DataDirectory is one lasting folder
  the host is given (`--tor-data`, as it is given the model's folder and
  tor itself; the stage kits use `~/Library/Application Support/Regents
  Cloak/tor`, beside the models folder). The host creates it owner-only
  (0700, which tor requires) if it does not exist and never removes it, so
  tor keeps its entry guards from one run to the next, as the Tor Project
  recommends, and a later start bootstraps from the directory it saved.
  The first start is still stateless. Measured once on the public Tor
  network, with the pinned tor and the host's settings, each start stopped
  once bootstrapped: a first start on a new folder bootstrapped in 9.52 s,
  and a second on the same folder in 2.41 s, building its first circuit
  from the directory it had saved. tor locks the folder while it runs: a
  second host on the same folder starts a tor that opens its port, waits 5
  seconds, says another tor is running with the same data directory and
  exits with status 1, so that host's guest starts with tor gone and its
  tasks stop at their Tor route, as after any exit. Checked offline with
  the pinned tor, whose only way onto the network was a closed loopback
  port.
- **On a socket file, closed to the rest of the Mac** (14 November): tor's
  SOCKS port was on the Mac's loopback, so while tor ran any program on the
  Mac, of any user, could route its own traffic through it. It is now the
  socket file above, in an owner-only folder made for each start. The
  design had first put it on a socket file (12 November) and moved off
  one: there tor answers each SOCKS connection request in its 22-byte form
  (an IPv6 address, all zeros), where on a TCP port it answers in 10 (an
  IPv4 one, all zeros); torsocks reads 10, so 12 zero bytes came before
  every stream, and TLS through Tor failed ("wrong version number"). The
  live check found it, and both answers were captured from the pinned tor
  offline. Now the host's relay reads tor's answers to the greeting, the
  user name and password, and the request, and passes the request's
  answer on in the 10-byte form when its address is all zeros (both mean
  no address), and every other answer and byte unchanged, so the guest
  gets what it got from the TCP port. The guest, the daemon and torsocks
  are unchanged, and each conversation keeps its own SOCKS identity and so
  its own circuit. The daemon's own route check reads either form, by its
  address type (`internal/relay/socks5.go` at the pinned commit).
  Considered and not taken: tor 0.4.9.16 has no setting that requires a
  SOCKS password (`IsolateSOCKSAuth` only keeps different ones apart, and
  the guest's identities are its own), and a loopback port cannot be
  closed to other users' programs without a packet filter rule, which
  needs the administrator.
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
- **State and keys**: all of tor's state (its state file with the entry
  guards it chose, and the directory cache; a client tor keeps no long-term
  identity key, and its circuit keys live in its memory) is in its one
  lasting, owner-only folder, which the host never removes. tor's state
  passes from one boot to the next; the guest's does not, as each boot's
  guest makes new keys and Tor identities.
- **Fails closed**: with tor gone (exited, or stopped at the bootstrap
  limit) or unable to build a circuit, the daemon's own route check stops
  the task ("no direct fallback was used"), nothing reaches tor's freed
  socket, and nothing else in the guest has a way out.

Ten checks in `tests/test_tor_path.py` pass, with the stand-in model's
fake worker; development evidence only, so A06 stays open. Each gives the
host a scratch folder for tor's state, never the stage kits' folder:

- **Through Tor, and nothing else** (the only check that reaches the Tor
  network): with no wait of its own, as the host has waited for tor's
  bootstrap, Node under torsocks in the agent's sandbox fetches
  https://check.torproject.org/api/ip through Tor, which answers
  that the request came from Tor; a Pi task passes its Tor route check and
  stops at the next step not built, the wallet companion ("The wallet
  companion could not be reached"). In the same sandbox the reference's
  static A06 probe, run as the stage 1 routing check runs it, finds TCP and
  UDP DNS blocked; Node with torsocks removed and busybox's static `nc`, to
  an IPv4 and an IPv6 address, find the network unreachable; and
  `/proc/net/dev` lists only `lo`. The Pi task's destination
  (openrouter.ai:443) is mapped by this check's tor to
  check.torproject.org:443, so the exit connects there and the daemon closes
  the stream at once; no model provider is contacted.
- **The relay passes only a SOCKS5 greeting**, with a stand-in tor that
  records each connection: an HTTP request, a SOCKS4 request, a SOCKS5
  greeting offering only GSSAPI and one offering no method each get no byte
  back through the guest's Tor port, and the HTTP request none straight over
  vsock either; a SOCKS5 greeting is answered by tor both ways; vsock ports 22, 53, 80, 443, 1080, 8080 and
  9051 refuse the connection; the rewrite port closes a connection without
  its token. The stand-in tor saw exactly the two greetings.
- **A task started with the host passes its Tor route**: a stand-in tor
  that bootstraps 10 s after it starts and refuses every request until
  then, as tor does; the boot's first case, a Pi task, which reaches its Tor
  route within 2 s of the guest starting, passes it and stops at the wallet
  companion. Before the host waited, the same check stopped at the Tor
  route.
- **A tor that exits while bootstrapping stops the task**: the stand-in
  exits after opening its port, before bootstrapping; the host stops
  waiting at once, the Pi task stops with the daemon's Tor route message
  ("no direct fallback was used"), the relay logs that it cannot reach tor,
  and the stand-in saw nothing.
- **A tor that never bootstraps is stopped at the limit**: the host waits
  90 s, stops the stand-in and says so; the Pi task stops with the same
  message, the static probe finds TCP and DNS blocked, and the stand-in saw
  nothing.
- **A tor that cannot reach the network stops the task**: the pinned tor,
  whose only way onto the network is a closed port on the Mac's loopback,
  never bootstraps and is stopped at the limit; the Pi task stops with the
  same message and the Node request is refused.
- **A tor that never opens its port is stopped at the limit**: a stand-in
  that hangs before opening its port, and ends only on a signal; the host
  stops it between 90 and 120 seconds after it started, fails with exit
  status 2 and starts no guest, and the stand-in is not running afterwards.
  Before, the host was still waiting when the check gave up at 300 s.
- **Nothing reaches a tor's freed socket**: once the stand-in has exited
  and the host has removed its socket's folder, the check makes the folder
  again and takes the socket's name with a listener of its own, as any
  program of the person's could; the guest's Pi task then stops at its Tor
  route with the same message, its connection reached the host's relay,
  and the listener received no connection. Before (on the TCP port), the
  relay connected to the listener and sent it the SOCKS5 greeting.
- **Only this user can open tor's socket**: the pinned tor, whose only way
  onto the network is a closed loopback port; 3 s after it opens its SOCKS
  socket, the socket's folder belongs to the person and is 0700, the
  socket itself is open to no other user or group, and tor has no
  listening network socket and no UDP socket (`lsof`); once tor is stopped
  at the limit, the folder is gone. TLS through tor over that socket, by
  torsocks, is the first check's fetch.
- **A second start reuses tor's folder**: two boots in a row on one
  folder, with a stand-in tor that keeps a state file in its data folder as
  tor does: both starts are given the same folder, the second finds the
  state file the first wrote, and the folder is owner-only.

Known gaps:

- **tor's SOCKS socket serves the person's own programs**: while tor runs,
  another program the same person runs on the Mac can open the socket and
  route its own traffic through Tor, as it can open the control socket
  (MAC05); other users' programs cannot, and nothing listens on the
  network. Programs in an app sandbox are probably kept out of the
  person's temporary folder too; not checked. Before (to 14 November): any
  program on the Mac, of any user, could use tor's loopback port.

Open for Sean: tor on the Mac instead of in the guest; and whether tor on
the Mac gets its own confinement (it runs unconfined; Apple's App Sandbox
refused it as a bare program with no bundle identifier).

## Stage 3 so far

- The feasibility kit is ready: `uv run scripts/stage3.py feasibility <name>`
  writes one candidate's stage 3 record (EVAL05, EVAL06, EVAL07) to
  `evidence/stage3/<name>/`, and `uv run scripts/stage3.py eval01 <name>`
  runs the development screen. The candidates are the lead, the challenger,
  the small lead and the small challenger (decision 7). The lead has two
  feasibility runs (below); the other three have none.
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
- Decision 6's input limit forced new cases, which are in a second file,
  [eval05-cap-inputs.json](../reference/eval05-cap-inputs.json) (sha256
  `bd9d4045da2b6aa863bf2ccb555b48e5d9875108728c1d0a94fea5d5463757e3`),
  pinned in the kit beside EVAL05, which stays as it was. It was written on
  12 November after the lead's first run, so unlike EVAL05 it was not pinned
  before a candidate ran. It holds no new text, only the start of EVAL05's
  prose: the limit's two sides (10,000 and 10,001 characters), and
  cancellation and worker-loss inputs of 10,000 characters with EVAL05's
  timings. They replace EVAL05's 16,384-character ones, which the limit now
  refuses before any call, so they would cancel or kill nothing. EVAL05's
  own long inputs all still run; those over the limit are refused at once.
- One `feasibility` run boots the guest three times in turn. The main run
  covers the cold load, the cold first call, the 40 EVAL06 messages warm, the
  rebuild after cache loss, the long inputs and outputs, and a cancellation
  and the call after it. Then the worker is killed mid-rewrite, then a
  restart. Every second it samples the memory and CPU of every worker
  process alive (summed), the guest's virtual machine, the host and the
  host's tor, plus swap, memory pressure and the system's GPU use; the
  whole-product peak is the sum of all of them. Since 13 November it also
  keeps MLX's own memory figures (active, cache and peak) from the worker's
  log: after each load, before and after the worker clears MLX's cache, and
  after each rewrite. It also records the installed size and the end-to-end
  time per case.
- Since 12 November the host starts the guest only once tor has
  bootstrapped ("Tor out of the guest" above), so "first result after the
  host started" now holds the cold load, tor's bootstrap, the guest's boot
  and the first call. Each record gives tor's bootstrap as its own figure
  (from tor's first log line to its "Bootstrapped 100% (done)" line, or none
  when tor never got there), beside the cold load, which is the worker's
  alone and unchanged. No record before then has tor in its first result;
  in one kit boot with the fake worker, tor took 7.40 s and the first
  result came 8.59 s after the host started. tor now keeps its state in
  `~/Library/Application Support/Regents Cloak/tor` between boots, so only
  the first boot on that folder bootstraps from nothing; a record does not
  say whether its boot's tor had saved state.
- Needs a person, listed in each record with no result: sleep and wake
  during a call, a run on battery, the declared ordinary load, induced memory
  pressure, and the first run after the Mac restarts.
- Not measured by this kit: the full stack (the guest now runs the daemon's
  local API and carries Pi, and the host runs tor for it on the public Tor
  network, but there is no cover traffic or payment vault, and the kit's
  calls do not come from Pi, so stage 3's exit condition stays unmet), the
  daemon's full serve path (A11), per-process GPU use (macOS gives it only to
  root), and a 32 GB Mac (decision 2).
- What a real run needs. Disk: the lead is 16,077,680,950 bytes and the
  challenger 15,373,590,134 (29.3 GiB together); with about 58 GiB free on
  11 November and 50 GiB kept free, neither fits until space is made. The
  small lead is 5,973,260,772 bytes and the small challenger 6,773,361,970
  (11.9 GiB together); about 106 GiB was free on 13 November. Memory: the
  kit refuses to boot unless the model's size plus 5 GiB is available
  (20.0 GiB for the lead, 19.3 GiB for the challenger, 10.6 GiB for the
  small lead, 11.3 GiB for the small challenger); this shared Mac had about
  13.8 GiB available on 11 November.

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
median stands on a quiet Mac. Decision 6 has since settled the second: the
deadline grows with the input, which is capped at 10,000 characters.

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

### Lead candidate, second run (13 November 2026)

[feasibility-20261113T032834Z.json](../evidence/stage3/lead/feasibility-20261113T032834Z.json),
kit commit `8bf4381`, clean tree, by Sean's "go Cloak run 2". The same
artifact at the same pinned revision, fetched and verified again. The
preflight saw 24.4 GiB available against 20.0 GiB needed. A candidate
record, and the first with Tor in the path. It closes no gate: the five
hand-run steps are open, cover traffic and the payment vault are still
missing, and the Mac was neither on AC power nor at the declared load for
the whole run. The record says "Battery Power, 12%; discharging". The run
started by itself at 03:16Z when the one-minute load fell to 6.6; other
lanes then started work, and the load was 70 when it ended at 03:28Z. The
40 ordinary messages ran first, in the quiet part; the long inputs and the
fault cases ran in the busy part.

What it showed:

- Cold load 10.92 s; tor bootstrapped in 9.86 s; the first result came
  24.44 s after the host started. After a restart the cold load was 17.11 s,
  tor bootstrapped in 2.41 s from its saved state, and three probes were
  rewritten.
- EVAL06: 40 of 40 ordinary messages rewritten, none stopped. Median 2.81 s
  against a proposed 5 s; 95th percentile 13.78 s against a proposed 15 s.
  The proposed targets are met. By input size: up to 128 tokens, median
  2.66 s (28 messages); 129 to 256, 6.54 s (6); 257 to 512, 13.44 s (6).
  Generation ran at a median of 28.6 tokens a second (16.0 in the first
  run, on a busier Mac). Outputs were a median 1.05 times their expected
  length. The slowest message took 15.98 s.
- The four-turn conversation was rebuilt in 13.55 s over four calls.
- Long inputs: 4,096 characters of prose were rewritten in 53.68 s (1,028
  tokens generated in 45.47 s). 10,000 characters, the cap, stopped at its
  290 s deadline with 1,985 tokens generated in 256.09 s, about 7.8 tokens a
  second. That is under a third of the ordinary messages' rate, during the
  busy part of the run, so this does not show whether the deadline holds
  the cap on a quiet Mac. Every input over 10,000 characters was refused at
  once, as it should be.
- Cancellation: the cancelled call stopped in 3.00 s, the worker answered
  5.38 s after the cancel, and the next call was rewritten. The first run's
  fault is gone.
- Worker loss: the probe before was rewritten; the call during which the
  worker was killed reported the worker lost; the probe after it was
  rewritten by a new worker in the same boot, loaded in 14.71 s. The first
  run's fault is gone.
- Memory: the worker peaked at 18.11 GiB, the guest's virtual machine at
  0.56 GiB and the whole product at 18.74 GiB during the main boot; during
  the 40 ordinary messages the product peaked at 16.37 GiB. Swap did not
  grow.
- All cases: 49 of 59 rewritten; stopped: 7 over the input limit, 1 timed
  out, 1 cancelled, 1 worker lost, each the expected outcome except the
  timeout at the cap. Installed on disk: 15.12 GiB.

What it did not show: fidelity or privacy (stage 4), the challenger, the
five hand-run steps (sleep and wake, battery, declared load, induced memory
pressure, first run after a restart), per-process GPU use, the daemon's
full serve path, and anything on a 32 GB Mac.

To settle: whether 10,000 characters finish inside 290 s on a Mac that
stays quiet. At this run's quiet rate (28.6 tokens a second) the 1,985
tokens generated before the stop would have taken about 70 s, but the
whole output's length is not known, so this is an estimate, not a result.

The weights were deleted after the run, as Sean asked.

### Small lead, first run ("run 3", 13 November 2026)

[feasibility-20261113T222740Z.json](../evidence/stage3/small-lead/feasibility-20261113T222740Z.json),
kit commit `66c8420`, by Sean's "run a v3 version with the smaller ~10 gb
model" and "run it now". The artifact is `mlx-community/Qwen3.5-9B-4bit` at
the pinned revision (5,973,260,772 bytes). A candidate record under
decision 7. It closes no gate: the five hand-run steps are open, cover
traffic and the payment vault are missing, and the Mac was on AC power but
not at the declared load (one-minute load about 26).

What it showed:

- Memory, against decision 7's 10 GiB line: the whole product peaked at
  7.22 GiB in the main boot (worker 6.60 GiB, guest's virtual machine
  0.52 GiB, tor 0.02 GiB), never more than one worker alive. Swap did not
  grow. MLX held 4.69 GiB after the load and its cache was empty after the
  clear. Under the line and under the 9.3 GiB aim.
- EVAL06: 36 of 40 ordinary messages rewritten; 4 stopped malformed (the
  daemon refused the reply: two chatty messages, one plain, one literal SQL
  message; three of the four in the 257 to 512 token band). Median 1.08 s
  against a proposed 5 s. The 95th percentile is not reached, because a
  stopped call holds that rank, so the proposed targets are not met. The
  lead rewrote 40 of 40 in both its runs.
- Cold load 4.27 s; tor bootstrapped in 2.38 s from saved state; the first
  result came 8.56 s after the host started. After a restart the cold load
  was 3.35 s and three probes were rewritten.
- Long inputs: 4,096 characters rewritten in 2.64 s; 10,000 characters, the
  cap, in 5.80 s against a 290 s deadline. Whether those short rewrites
  kept what they had to keep is not judged here (stage 4, and EVAL01).
  Every input over the cap was refused at once.
- The four-turn conversation was rebuilt in 4.31 s over four calls.
- Cancellation and worker loss behaved as in the lead's second run; the
  replacement worker loaded in 3.31 s.
- All cases: 46 of 59 rewritten; stopped: 7 over the input limit, 4
  malformed, 1 cancelled, 1 worker lost. Installed on disk: 5.71 GiB.

To settle: why the four replies were malformed (the raw replies are in the
record), and the EVAL01 screen, which has not been run on this candidate.
A stopped message is a stopped task (spec DATA09), so 4 in 40 counts
against it whatever its speed.

The weights were deleted after the run.

### Small lead on llama.cpp, first run (14 November 2026)

[feasibility-20261114T001549Z.json](../evidence/stage3/small-lead-gguf/feasibility-20261114T001549Z.json),
kit commit `ad16508`, under decision 8. The artifact is
`unsloth/Qwen3.5-9B-GGUF`, `Qwen3.5-9B-Q4_K_M.gguf`, at the pinned revision,
on llama.cpp v1.0.0. A candidate record; it closes no gate, for the same
reasons as the MLX run above. On AC power, one-minute load 21 to 42.

- EVAL06: 27 of 40 ordinary messages rewritten; 13 stopped malformed
  (MLX: 36 of 40, 4 malformed). Median 1.06 s (MLX 1.08 s).
- Memory: the whole product peaked at 9.11 GiB (MLX 7.22 GiB): under the
  10 GiB line, over nothing, but only 0.19 GiB under the 9.3 GiB aim.
  llama.cpp held 5.28 GiB of weights and 4.75 GiB of Metal memory after
  the load; each rewrite's context is sized for the prompt plus the
  16,384-token output limit.
- Long inputs: 4,096 characters in 2.72 s, 10,000 in 5.16 s. The four-turn
  conversation stopped on its first call (malformed). Cancellation: the
  worker answered 0.93 s after the cancel and the next call was rewritten.
  Worker loss and restart behaved as on MLX.
- All cases: 36 of 59 rewritten; 14 malformed. Installed: 5.45 GiB.

What the malformed replies are, on both engines: the rewrite is there, but
the model closes the JSON wrongly, `"}]` or `"]` where the daemon needs
`"]}`. The daemon rightly refuses them. The 27B lead made no such slip in
80 messages. Constraining the reply to the daemon's JSON shape while
decoding (a grammar) would remove this class of failure without touching
the instruction; spec DATA04 allows it only as an explicit pinned part of
a candidate, and it does not replace the daemon's check. That is the next
experiment, as its own candidate entry.

The weights were deleted after the run.

### Memory on llama.cpp (14 November 2026)

The 9B's 9.11 GiB peak came at the end of its load, from one fault in the
hash check both workers share. Before loading, a worker reads every
pinned file 8 MiB at a time to check its sha256. Each block read stayed in
memory until the thread's autorelease pool was next emptied, and the llama
worker's start empties it only after the model has loaded: the whole file
was held beside the weights for the length of the load. The MLX worker
empties it when it starts waiting for its loader, before the weights
load. Hashing the stand-in's file in a program of its own, the old way
held all 1.20 GiB of it until the program's first wait, the new way none.
In the 9B's record every boot's highest sample falls at the end of a
worker's load
(9.10, 9.94 and 9.58 GiB for the worker; 10.63 GiB for the whole product
in the worker-loss boot, over the 10 GiB line), the worker's lifetime peak
reached 11.54 to 11.70 GiB, and after its rewrites it held 6.6 to 6.7 GiB.
Now each block is let go once hashed (`rewriter-kit`'s `ModelPin`, in
both workers).

On the stand-in (a 1.19 GiB file), one worker started on its own and given
one rewrite: 3.45 GiB at ready before, 2.24 GiB after; its lifetime peak
3.45 GiB before, 2.48 GiB after; 2.17 and 2.08 GiB once settled. The MLX
worker on its stand-in, after: 1.27 GiB at ready, 2.14 GiB lifetime peak.
The stage 4 repeat of the GGUF stand-in, three runs of 13 items each,
before
([repeat-20261114T005050Z.json](../evidence/stage4/standin-gguf/repeat-20261114T005050Z.json))
and after
([repeat-20261114T013607Z.json](../evidence/stage4/standin-gguf/repeat-20261114T013607Z.json)):
all 39 outcomes and texts the same byte for byte; the worker's lifetime
peak 3.45 GiB in each run before, 2.05 to 2.07 GiB after; the whole
product's sampled peak 3.25 to 3.42 GiB before, 2.58 to 2.64 GiB after.
The 9B was not run again (no candidate is downloaded in this change), so
its new figures are not measured; its load should now peak near its
rewrite level instead of about 5.3 GiB above it.

Found and left as they are:

- The system allocator keeps the large blocks llama.cpp frees after the
  load (one read buffer per tensor, the largest the 398 MiB output table)
  dirty and counted, about 0.4 GiB on the stand-in, because macOS 27.2
  clears them on free. Releasing memory on request does nothing for them.
  The allocator setting `MallocLargeCache=0` in the worker's environment
  gives them back (stand-in: 1.82 GiB at ready, 2.05 GiB lifetime peak),
  but it is not documented, so it is not used.
- The stand-in ties its input and output word tables, and llama.cpp keeps
  the input one on the CPU, so the table is held twice (398 MiB). Whether
  the 9B does the same is not checked. Changing it means changing the
  pinned llama.cpp.
- Each rewrite's context is the prompt plus the 16,384-token output limit,
  at 16-bit precision: about 12 KiB a token and 217 MiB in all on the
  stand-in; on the 9B, Metal memory rose 0.72 GiB from the load to its
  rewrites. A smaller limit or a quantized cache would cut it, but the
  first is the daemon's contract and the second changes the outputs.

### Small lead on llama.cpp with the reply grammar, first run (14 November 2026)

[feasibility-20261114T022608Z.json](../evidence/stage3/small-lead-gguf-grammar/feasibility-20261114T022608Z.json),
kit commit `d7f5b70`, under decisions 8 and 9: the same GGUF file as the run
above, decoded under `reference/rewrite-reply.gbnf`, with the hash-check
memory fix. A candidate record; it closes no gate (hand-run steps open, no
cover traffic or payment vault, the Mac on AC power but busy: one-minute
load about 30 at the start and 67 at the end).

- EVAL06: 39 of 40 ordinary messages rewritten, none malformed; 1 timed
  out (e06-37, 115 s: a runaway that ran to its deadline; the grammar
  lets white space between JSON tokens repeat without end). Median 1.09 s
  and 95th percentile 4.43 s against the proposed 5 s and 15 s: the
  proposed targets are met. Without the grammar: 27 of 40; MLX: 36 of 40.
- Memory: the whole product peaked at 6.74 GiB, in every boot under
  6.75 GiB (9.11 to 10.63 GiB before the fix; MLX 7.22 GiB). Under the
  10 GiB line and the 9.3 GiB aim.
- Long inputs: 4,096 characters in 3.74 s, 10,000 in 6.36 s. The four-turn
  conversation was rebuilt in 5.51 s over four calls. Cancellation: the
  worker answered 1.15 s after the cancel; the next call was rewritten.
  Worker loss and restart as before.
- All cases: 49 of 59 rewritten; stopped: 7 over the input limit, 1 timed
  out, 1 cancelled, 1 worker lost. Installed: 5.43 GiB.

To settle: the runaway. The grammar's white space between tokens is to be
removed (the daemon accepts the reply without it), which makes a new
grammar hash and so a new candidate configuration, to be run again.
Whether the rewrites keep what they must is still unjudged (EVAL01,
stage 4).

The weights were deleted after the run.

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

Feasibility with the memory fixes (cache cleared after load, a lost worker
waited for, every worker and tor sampled),
[feasibility-20261113T193557Z.json](../evidence/stage3/standin/feasibility-20261113T193557Z.json),
13 November, kit commit `2add247` with these changes not yet committed, on
battery (8 %) with the one-minute load rising from 27 to 177 as other lanes
worked. Development only. MLX held 0.99 GiB active and
0.78 GiB cached after the load, and 0 cached after the clear. The main
boot's worker peaked at 2.31 GiB, tor at 0.02 GiB and the whole product at
2.90 GiB; at most one worker was alive at any sample.

Feasibility on llama.cpp (decision 8), `standin-gguf`,
[feasibility-20261113T235334Z.json](../evidence/stage3/standin-gguf/feasibility-20261113T235334Z.json),
13 November, kit commit `6287726`, on battery with the load at 38 to 73.
Development only, and a different 4-bit file from the MLX stand-in's, so
its replies differ. Beside the MLX run above: EVAL06 38 of 40 rewritten
(1 malformed, 1 truncated) against 24, median 0.37 s against 2.43 s (0.36 s
in MLX's quieter first run); the main boot's worker peaked at 2.54 GiB
against 2.31 and the whole product at 3.27 GiB against 2.90. llama.cpp held
1.18 GiB after the load, and its Metal memory peaked at 1.52 GiB in a
rewrite. It finished the cancellation case (1.71 s) before its cancel and
the worker-loss case before its kill at 2 s, so neither was exercised here;
`tests/test_worker.py` covers both on this worker.

The same stand-in under the reply grammar (decision 9),
`standin-gguf-grammar`,
[feasibility-20261114T013222Z.json](../evidence/stage3/standin-gguf-grammar/feasibility-20261114T013222Z.json),
14 November, kit commit `2b99c7e` with the grammar not yet committed, on AC
power with the load at 38 to 80. Development only. Beside the run above:

- EVAL06 again 38 of 40 rewritten, each the same bytes as before, and none
  malformed; but the two failures both ran on to the 90 s limit. e06-36 ran
  away as before. e06-10, malformed before, now keeps its stray `]}` inside
  the text, closes it, then writes white space without end (seen in full on
  the worker alone, to the 16,384-token limit): the grammar turns a
  malformed reply into a runaway, which the time limit ends.
- The four-turn conversation, malformed before, is rewritten (1.71 s over
  four calls); all cases 50 of 59 rewritten against 49.
- Median 0.60 s against 0.37 s, and 108 tokens a second generated against
  134, on a busier machine. Side by side under one load, the other 38
  EVAL06 messages through both in turn, the grammar cost little: 116
  against 120 tokens a second, and a median ratio of 1.00 per message.
- The worker peaked at 2.52 GiB over its life against 3.45 GiB, from the
  memory fix ("Memory on llama.cpp" above), not the grammar; the whole
  product's sampled peak was 3.26 GiB against 3.27.

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

The protocol splits its 95 % confidence over two candidates, 97.5 % for
each bound, and the kit bounds at 97.5 %. Decision 7 makes four
candidates, so the split has to be re-declared before any holdout opens.

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
   up to the daemon's 10,000-character limit (decision 6; the kit refuses an
   item over it), kept outside this repository and pinned with `pin`. Its
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

## Stage 5 so far

- A development build of the app's core (13 November): one supervisor
  (`app/Sources/CloakSupervisor/`), driven by a menu-bar app,
  `Regents Cloak.app`, and by the `cloak` command, built by `app/build.sh`
  and signed ad hoc. Its states are the spec's six, as one state machine
  ([state-machines.md](state-machines.md), section 9). The host's parts
  (tor, the worker's channel, the relay, the guest) are now a library,
  `host/Sources/CloakHost/`, used by the supervisor and by `cloak-host`,
  whose command line is unchanged; every child it stops gets 10 seconds,
  then is killed.
- What exists: the checks of the Mac and of each installed part against
  the bundle's manifest; tor, the MLX worker and a check guest started in
  turn, each once the one before is up; a startup check that sends one
  rewrite through the guest, the daemon and the worker; tor and the worker
  watched; one shutdown; Needs attention with a reason code on any failure,
  with nothing restarted and no other route or model; Paused at every
  launch, after sleep and after a relaunch, and at login, which the Details
  window's Login switch turns on (off until then); `cloak status`, `start`,
  `pause`, `resume`, `stop`, `verify` and `doctor`, with versioned JSON
  (INS01, INS02), over an owner-only socket that checks the peer's user
  (MAC05). One model, named in the manifest: the stand-in, labelled as a
  development stand-in, with no picker.
- What does not exist yet: sessions (Running has no session guest; the
  check guest powers off once its check is done), payment, wallets, cover
  traffic, the OS-approval and funding states, setup and model download
  from the app, updates, recovery, a Developer ID signature and
  notarization, and clearing leftover boot files at launch.
- Live run on the development Mac, 13 November, stand-in only: from Paused,
  `cloak start` reached Running in about 6 s, the check's rewrite taking
  0.25 s through the real guest path; `pause` stopped tor and the worker;
  with the worker killed by its process number while Running, the app went
  to Needs attention (`worker_stopped`), stopped tor, and started nothing
  again; `resume` was refused there; `start`, then `stop` (Ready), `verify`
  and `doctor` passed; quitting stopped everything and removed the socket;
  a relaunch came back Paused; with the app closed, `cloak start` opened it
  and reached Running. Not shown: screenshots of the menu and the Details
  window (no screen-recording permission in the session that built it), a
  VoiceOver pass, and a live sleep and wake.

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
   reaches nothing. Built 12 November ("Tor out of the guest" above): tor
   runs on the Mac as the host's child, and the guest's Tor port is relayed
   to it. A06 stays open: the checks are development evidence on the
   stand-in, and the placement is Sean's to confirm.
6. The input limit and each rewrite call's deadline. Decided 12 November
   (Sean: "yes grow with the size, hard cap at 10,000 characters"). A user
   turn whose text parts total more than 10,000 characters is refused before
   any call, so the model never sees it, with a plain message giving the
   limit and the length received. A character is a Unicode scalar value (Go's
   `utf8.RuneCountInString`, Python's `len`): an accented letter or an emoji
   counts once, whatever its bytes. Each call gets 90 seconds plus 20 ms for
   each character it carries, for the whole call and for its response
   headers:

   | Characters | Deadline |
   | --- | --- |
   | 1,000 | 110 s |
   | 4,000 | 170 s |
   | 10,000 | 290 s |

   The two numbers, 90 s and 20 ms, are the worker's proposal and Sean's to
   change. They come from the lead's first run
   ([feasibility-20261112T142919Z.json](../evidence/stage3/lead/feasibility-20261112T142919Z.json)):
   its 4,096 characters of prose took 58.43 s (1,318 prompt tokens in
   7.68 s, 1,028 generated in 50.70 s), about 14.3 ms a character, so 10,000
   characters would need about 143 s and get about 2.0 times that. At the
   run's median rates over the 40 ordinary messages (16.0 tokens a second
   generated, 133.5 read), 10,000 characters would need about 181 s and get
   about 1.6 times that. Both assume time grows in proportion to length; the
   16,384-character call, cut at 90 s, had read 4,496 tokens in 24.47 s and
   generated 1,406 in 65.56 s, which fits. The base stays the reference's
   90 s, so a short input keeps close to the reference's deadline (100
   characters get 92 s). This departs from the spec by Sean's ruling, as
   decision 2 departs from HW01: spec section 7 bounds a user turn at
   128 KiB and a call at 90 seconds, A20 asks for the same limits, and
   section 11 ("Full-request feasibility") says not to lower the input limit
   to pass. 10,000 characters is at most 40,000 bytes, so
   the cap is below the reference's 128 KiB for every input: a turn the
   reference took, from 10,001 characters to 128 KiB, is now refused. The
   reply's limits (its strings at most 128 KiB, its body at most 1 MiB) are
   unchanged. The formula is in one place in the daemon
   (`guest/daemon/rewriter.patch`, applied to a copy of
   `internal/rewriter/rewriter.go` when the guest is built; the pinned source
   stays as fetched), and copied once for the kit's time limits
   (`scripts/measures.py`); `guest/daemon/server.patch` gives the refusal its
   own message on the daemon's local API, where every other rewrite failure
   keeps the daemon's. EVAL05 stays as pinned; the cases the cap forces are
   in [eval05-cap-inputs.json](../reference/eval05-cap-inputs.json) (stage
   3 above).
7. The small pair, and the memory line. Decided 13 November (Sean). Two
   smaller candidates join the lead and the challenger: the small lead,
   `mlx-community/Qwen3.5-9B-4bit`, and the small challenger,
   `mlx-community/gemma-4-12B-it-4bit`, each pinned with the vendor
   checkpoint it was made from in [models.json](../reference/models.json)
   and, under decision 1, using its conversion's weights with the vendor's
   own tokenizer and chat template files
   ([models.md](../reference/models.md)). This departs from spec section 1,
   which names exactly two candidates, by Sean's ruling, as decision 2
   departs from HW01; the spec file stays byte for byte as received (its
   sha256 is at the top of this file). The memory pass line is 10 GiB for
   the whole running product: the worker, the guest's virtual machine and
   the host together, as the stage 3 record's whole-product peak (since
   13 November that peak also counts tor and every worker alive at a
   sample). 9.3 GiB is the working aim. The lead's two runs peaked at 21.04
   and 18.74 GiB, before tor was sampled.
   Exactly one model still ships (A25 unchanged): the selection rule picks
   one of the four or none. Each small candidate faces stage 4 from scratch;
   nothing measured on the lead or the challenger counts for it. To settle
   before any holdout opens: the frozen protocol's confidence split assumes
   two candidates ("Two candidates are compared with the reference, so each
   bound is at 97.5 % (Bonferroni)"); with four it has to be re-declared.
   Until then the protocol and the stage 4 kit's statistics stay as frozen.
8. A second engine, for a measured choice. Decided 13 November (Sean: "use
   this: https://github.com/ggml-org/llama.cpp"). llama.cpp with Metal and a
   GGUF model is built as a second rewriter engine, the llama worker
   (`llama-worker/`), and measured beside the MLX worker on the same
   candidates through the same path: the same frames, command line,
   pinned-file check and sandbox, so the host and the kits start either one
   by its path, picked by the `engine` each model names in
   [models.json](../reference/models.json). Exactly one engine, model and
   configuration ships (A25 unchanged); when the choice is made, the other
   engine is deleted from the repository. This departs from spec section 1
   and MAC02, which name one MLX path, and from the one-implementation rule
   in [AGENTS.md](../AGENTS.md), by Sean's ruling and for the experiment
   only, as decision 2 departs from HW01; the spec file stays byte for byte
   as received. A GGUF quantization and an MLX 4-bit conversion are
   different artifacts, so each is its own candidate and faces stage 4 on
   its own: `small-lead-gguf` (Unsloth's Q4_K_M of `Qwen/Qwen3.5-9B`) and
   `small-challenger-gguf` (Google's own Q4_0 GGUF of Gemma 4 12B, from its
   quantization-aware-trained checkpoint, not the instruct weights its MLX
   twin came from; [models.md](../reference/models.md)). Nothing measured
   on an MLX twin counts for its GGUF one. llama.cpp is pinned at release
   v1.0.0 (commit `b1b770d9`) in [sources.json](../reference/sources.json)
   and built from that source; every llama.cpp setting that could change a
   result or the memory a rewrite takes is set in the worker
   (`llama-worker/Sources/CLlama/cloak_llama.cpp`). The confidence split
   decision 7 leaves to re-declare now covers six candidates, not four.
9. The reply grammar, as candidates of their own. Decided 14 November (the
   chief). Grammar-constrained decoding is tested as explicit pinned
   candidates on llama.cpp, as spec DATA04 allows, because both engines'
   small-model failures are slips in closing the JSON (stage 3 above). The
   grammar, [rewrite-reply.gbnf](../reference/rewrite-reply.gbnf), allows
   the replies the daemon's check accepts: `{"texts":[...]}` with as many
   texts as the request, any JSON white space, and any text the daemon
   takes, so it is no tighter on what a text may hold. It differs from the
   daemon only on the key, which must be written `"texts"`, once; the
   daemon also takes other letter cases, an escaped key and a repeated key.
   Each entry pins it by sha256 (`grammar` in
   [models.json](../reference/models.json)); it is built into the llama
   worker, which refuses a pin naming another, and the worker sets the
   number of texts from each request. Decoding stays greedy: llama.cpp's
   own grammar sampler only removes the tokens the grammar does not allow.
   The daemon's check is unchanged and still decides every reply, and
   nothing repairs one. The candidates are `small-lead-gguf-grammar` and
   `small-challenger-gguf-grammar`, each its twin's files under the
   grammar; each faces stage 4 on its own, as decision 8 has it, and the
   confidence split now covers eight candidates. `standin-gguf-grammar` is
   the development stand-in. MLX gets no grammar: the pinned mlx-swift-lm
   (`f5b0677f`) carries a grammar library (MLXGuidedGeneration, on
   xgrammar), but the MLX worker does not link it and nothing was built on
   it.

## Gates

| ID | Test | State | Evidence |
| --- | --- | --- | --- |
| A01 | Reference integrity | Open: sources, wrapper (reconstructed), contract and model files pinned; reference inference settings and payment deployment unknown | [baseline](../reference/baseline.md), [contract](../reference/rewriter-contract.md), [models](../reference/models.md) |
| A02 | Clean Mac installation | Open: only a development build exists (`app/build.sh`, signed ad hoc), which needs the guest, tor and worker built and installed by hand first; no setup, and no run on a clean Mac | `app/build.sh` |
| A03 | GUI and CLI equivalence | Open: the menu-bar app and `cloak` drive one supervisor, with the same manifest, states and reason codes (development build, stand-in only); no sessions or payment exist yet to be shared | `app/`, `app/Tests/CloakTests/` |
| A04 | Fidelity | Open: scoring kit built and proven on development data only; no holdout | `scripts/stage4.py`, `scripts/fidelity.py` |
| A05 | Whole-agent containment | Open | |
| A06 | Complete routing | Open: the reference wrapper fails it (static program bypass); in Cloak's guest, which has no network device and one relay to tor, the same static probe and a program without torsocks reach nothing (development evidence only, stand-in) | [baseline](../reference/baseline.md#observed-behaviour-of-the-reconstruction), `tests/test_tor_path.py` |
| A07 | Conversation isolation | Open | |
| A08 | Cover behaviour | Open | |
| A09 | Failure and pause | Open: in the app, a tor, worker or guest failure stops all work and ends in Needs attention with its reason, with nothing restarted and no other route or model; Pause and Quit stop everything, and a relaunch starts nothing (checks with stand-in processes, and a live run with one worker kill; development build, stand-in only); sleep pauses in the state machine's checks, but no live sleep and wake has been tried; no sessions, cover or payment yet to stop | [state machines](state-machines.md), `app/Tests/CloakTests/` |
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
| A20 | Unchanged rewrite API | Open: contract captured; the daemon's own rewrite code runs in the guest, unchanged but for Cloak's input limit and deadline (decision 6, a departure from the spec's limits by Sean's ruling), and refuses nine kinds of bad reply (stand-in model only) | [contract](../reference/rewriter-contract.md), `tests/test_guest_path.py` |
| A21 | Host–guest worker boundary | Open: one token-checked virtio socket, guest has no network device, host relays only rewrite frames, worker sandboxed with no network (development signing; stand-in model) | `host/`, `guest/`, `worker/cloak-rewriter.entitlements`, `tests/test_guest_path.py`, `tests/test_worker.py` |
| A22 | Authorship and linkability | Open: attack 1 and the sign-flip bound built and proven on synthetic development data only; attack 2 not built; no holdout | `scripts/stage4.py`, `scripts/privacy.py` |
| A23 | Long and cold tasks | Open | |
| A24 | Artifact provenance | Open: files pinned for the reference and all four candidates; each conversion's tokenizer or template differs from its vendor's, so each candidate takes those files from its vendor (decision 1) | [models](../reference/models.md) |
| A25 | Single implementation | Open: the app runs one model and one worker, named in its bundle's manifest (the stand-in until stage 4 picks a winner), with no picker, no switching by hardware and no fallback; the repository still holds two engines for decision 8's measurement | `app/release.json`, `app/manifest.py` |
| A26 | Performance claims | Open | |
