# Plan and release gates

The contract is [spec-v0.4.md](spec-v0.4.md), received 30 October 2026
(sha256 `8c6b4d5d66fca24383bd3282503e17289784f14df14345a5e15b7bffdac74aea`
as received). It is a working draft, edited as the work changes: since
14 November its decision summary and stage 2 name the llama.cpp worker
where they named the MLX one (decision 8). Work follows its section 12 in
order. A gate passes only with recorded evidence linked in its row; a failed
or inconclusive check is not a pass. Progress lives here.

## Stages

| Stage | Deliverable | Exit condition | State |
| --- | --- | --- | --- |
| 1. Freeze the experiment | Captured reference, the 16 cases, unchanged contract, candidate manifests, evaluation protocol | Exact assets, licences and primary settings known; unknowns recorded | In progress: the evaluation protocol is a draft, frozen by Sean before any holdout opens |
| 2. Build the local path | Minimal guest adapter and native worker through the real daemon | Synthetic inputs, malformed replies, cancellation and worker loss keep the contract and stop safely | In progress |
| 3. Check feasibility early | Runs of each of the two candidates (decision 7's small pair, as GGUF files on llama.cpp under the reply grammar: decisions 8 and 9) on a specified 48 GB Mac with the full stack loaded (no 32 GB machine; decision 2) | Input, deadline and memory risks measured before the large privacy evaluation | Kit ready; the small lead has two feasibility runs and two EVAL01 screens, the small challenger none |
| 4. Qualify the substitution | Separate fidelity and authored privacy holdouts; one pinned winner of the two candidates or an explicit no-pass | Protection, fidelity, statistical and usability gates pass | Kit in progress: no holdout, reference run or candidate result yet; the confidence split is to be settled before any holdout opens (decisions 7 to 9) |
| 5. Package the product | Signed full bundle, shared CLI and menu-bar supervisor, setup, recovery, updates | Clean-machine and full real-service tests pass | In progress: a development build of the supervisor, the menu-bar app and `cloak`, running the small lead, with Chat sending in a Development mode only (decision 10; "Stage 5 so far"), and the daemon's own cover traffic in its guest (on since 19 November); a signed, notarized technical-preview build with updates, 0.5.0 (164), is published for invited testers since 19 November, and 0.5.1 (168), with Llama Normal chats, and 0.5.2 (170), with the icon and the install window, and 0.5.3, with the modes' new names and a fix for the app ending by itself, since 20 November ([release.md](release.md), stage 1 and item 7), all tried on the Mac that built them only, where the update from the first to the second worked; no setup, recovery, sessions or the daemon's own payment |
| 6. Release at the planned home | Download, guide and evidence for supported configurations | A01 to A26 pass; claims and hardware scope match results | Not started |

Stage 2 builds and tests the path with a small model labelled as a
development stand-in, so it runs light on the development Mac (an M4 Max with
48 GB, macOS 27.0). The candidates' weights (5.3 GiB for the small lead,
6.5 GiB for the small challenger) are first loaded in stage 3, after a free
memory and disk check.

Mac skills by stage (rules in [AGENTS.md](../AGENTS.md)): stage 2's native
worker uses `macos-patterns`, `macos-build` and `write-swift`; stage 5 adds
`macos-auto-update`, `macos-release`, `macos-settings-ui` and
`macos-notch-ui`; stage 6 uses `macos-release`.

## Stage 1 so far

- The daemon is pinned at the post's commit and the spec's later snapshot,
  builds, and passes its own tests. Pi 1.3.0 is pinned by package hash.
- The rewriter contract is captured and identical at both pins:
  [rewriter-contract.md](../reference/rewriter-contract.md).
- The reference model, the two candidates, the stand-in and the checkpoints
  they take files from are pinned file by file:
  [models.md](../reference/models.md). Decision 1 settled
  the provenance findings there: each candidate takes its tokenizer and chat
  template files from its vendor.
- The sandbox wrapper is reconstructed and is the Regents reference (Sean,
  29 October). A static program inside it bypasses Tor.
- Unknown and recorded as such: the reference's inference server,
  quantization and thinking setting; which payment deployment the post used.
- The evaluation protocol (EVAL01 to EVAL07) is a draft (Sean, 14 November:
  "don't freeze anything yet? this is still super active development"). It
  was marked frozen on 30 October; no holdout was opened under it. Sean
  freezes it before any holdout opens.

## Stage 2 so far

- The native worker (`llama-worker/`, on llama.cpp, decision 8; the first
  worker, on MLX, was deleted on 14 November) loads a model only when every
  file matches the pins built into it, rewrites one request at a time under
  the reply grammar, stops on a cancel (also while it reads a long prompt),
  and stops on any protocol fault. When the host shuts down mid-rewrite, the
  worker stops that rewrite, which fails, and exits cleanly; a protocol
  fault mid-rewrite stops the rewrite the same way before the worker exits.
  It runs in Apple's App Sandbox with no network entitlement and reads files
  only in
  `~/Library/Application Support/Regents Cloak/models/`. 35 checks in
  `tests/test_llama_worker.py` pass on the stand-in (14 November),
  including: a program signed with the worker's entitlements is refused a
  connection the same program makes unsandboxed, the installed worker
  carries exactly those entitlements, the worker cannot read a folder
  outside the models folder, and the daemon accepts every reply the model
  ended.
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
  later rewrite failing.
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
  The stand-in model is never evaluated; it is there to drive the path.

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
  adapter, Tor at `tor://127.0.0.1:9050`, and the daemon's own cover
  traffic from Cloak's one cover list ("Cover traffic in the guest" below).
  It skips what needs the network or a wallet: funding, the wallet
  companion, the deployment check and the key-session monitors.
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

- **Cover traffic**: built (below), and on since 19 November with the
  pool of pages Sean approved.
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

### Cover traffic in the guest (built 18 November 2026)

Release plan item 3. The guest's daemon runs the pinned daemon's own cover
traffic (`internal/cover`; `zkapi-clientd/docs/COVER_TRAFFIC.md`), started
the way the daemon's `serve` starts it (`startServeCover`), for as long as
the daemon's API runs, and closed and joined when the API ends. No pinned
file changed: the guest daemon's added file reads the settings and hands
them to the daemon's own validation and start.

- **One list**: `reference/cover.json`, `{"urls": [...], "rate": ...,
  "concurrency": ...}`, is the only place the destinations, rate and
  concurrency live. `guest/build.sh` puts it in the guest image as
  `/etc/cloak/cover.json`, root's and read-only; the agent's sandbox does
  not see `/etc/cloak`.
- **A pool, sixteen at a time**: the list's URLs are a pool, which may
  hold more than the sixteen the pinned worker takes. Each time the
  daemon starts, and only then, it picks sixteen distinct URLs from the
  pool at random, each as likely as any other, from the same source of
  randomness as the worker's own (Go's `crypto/rand`), and hands them to
  the worker unchanged. The same sixteen serve until the next start. A
  pool of sixteen or fewer is handed over whole, as before. The picked
  URLs are not logged, as the worker logs no destinations. The URLs
  name real, popular pages, so what is fetched from them changes as the
  pages themselves change (Sean, 18 November).
- **On, with a pool of 58 pages** (Sean, 19 November, below). A list
  with no URLs would be the daemon's own cleared setting, and no cover
  worker would start. That is the one switch.
- **Rate 0.05 a second (about three a minute), 2 at once**: inside the
  reference's ranges (0.01 to 5 a second, 1 to 8 at once) and below its
  defaults (5 a second, 4 at once), as a gentle start for whoever owns the
  files. At the daemon's 64 KiB cap per reply, that is at most about
  11 MiB of replies an hour, before Tor's own overhead. A changed cover
  default counts as a security-relevant change (UPD03): Sean kept these
  on 18 November and turned cover on at them on 19 November.
- **Anything else wrong stops the daemon**: a list that cannot be read,
  has another shape, or fails the daemon's own checks (HTTPS on port 443
  only, no credentials, query or fragment, public names, rate and
  concurrency in range, `tor://` only) stops the daemon before it listens.
  Every URL in the pool is put through those checks, one at a time,
  whether it is picked or not, so a bad URL anywhere stops the daemon at
  every start, not only at the starts that happen to pick it. So does a
  URL listed twice, which would make its site come up twice as often, and
  an entry holding a space, which the worker would read as two URLs.
  Its message is in `/run/cloak/daemon.log`, which the boot prints before
  the guest powers off. There is no other path.
- **Totals**: once a minute, the daemon's own line `Cover totals:
  attempted=... succeeded=... failed=... skipped=... response_bytes=...`
  goes to its log, `/run/cloak/daemon.log`. It prints a last one when the
  API ends, which in practice never happens, as the guest powers off
  without stopping the daemon. The app does not show these lines.

Sean, 18 November: the gentle rate stands (0.05 a second, two at once).
On destinations he asked for cover that is real and changing (popular
pages, subreddits, searches) and not a few files of our own. What bounds
that, found the same day: the pinned worker takes at most 16 addresses,
refuses any with a query, follows no redirect and reads at most 64 KiB;
and one fetch each through real Tor showed Reddit, Stack Overflow and the
New York Times refuse Tor visitors (403), while Wikipedia, Hacker News,
GitHub, the BBC, the Guardian, arXiv, DuckDuckGo, Lobsters, NPR and Open
Library answer. An HTTPS watcher sees the site's name, the size and the
timing, never the path or a search. Sean then chose the approach the same
day: a changing mix of real, current, popular pages, kept as a pool larger
than sixteen, with sixteen picked at random at each start (the pool, above).

Checks in `tests/test_cover_path.py`, all five passed on 18 November
against a guest built with this change, as did the thirty existing checks
in `tests/test_agent_path.py` and `tests/test_guest_path.py`. Each boots the guest against the stand-in
tor with a list of its own, laid over the image's file in one more boot
archive, as the host lays its per-boot files. A boot whose daemon starts
runs one Pi task and then waits 65 seconds.

- With two test destinations at the reference's highest rate, cover
  connections reach the stand-in. Each asks only for a listed host on
  port 443. The cover identities number no more than the concurrency, two,
  and none is the conversation's, and no connection uses any other
  identity. The daemon's totals line counts the attempts, all failed at the
  stand-in.
- With an empty list, the only connection is the conversation's.
- A list with a plain HTTP address, a rate over 5 or a misspelt field
  stops the daemon, and the guest powers off before any task, with nothing
  sent to tor.

Through the real tor, 19 November: 81 well-known pages were each asked
once as the worker asks (same headers, no redirect, 64 KiB read); 58
answered 200 or 206. With those 58 as a pool for one boot at the shipped
rate, two six-minute guest runs gave the daemon's own totals of 7 and 17
attempts (18 is the mean), nothing skipped, 0.4 and 1.0 MB read. Most
attempts are counted as failed, and that is the worker's rule, not a
fault: a page longer than 64 KiB is read to the cap and counted failed.
Sean approved those 58 on 19 November (below).

Four checks for the pool were added on 19 November, in the same file; all
nine passed that day on a guest built with the pool:

- With a pool of 24 test URLs, each on a host of its own, the daemon
  starts (it would refuse more than sixteen), every cover connection asks
  for one of the pool's hosts on port 443, and no more than sixteen
  distinct hosts are asked in the boot.
- A pool of 24 whose 21st URL is plain HTTP, one with a URL listed twice,
  and one with two URLs in one entry each stop the daemon, and the guest
  powers off before any task, with nothing sent to tor.

Before any guest boot, the daemon was built for the Mac from the same file,
with only the list's path and the tor port changed, and run against the
stand-in tor on a loopback port (18 November). With the two test
destinations at 5 a second and 2 at once, 326 connections arrived in 66
seconds, each to one of the two hosts on port 443, on exactly two
identities, and at the minute the daemon logged `Cover totals:
attempted=297 succeeded=0 failed=297 skipped=0 response_bytes=0`. With
the shipped list, and with an empty list at 5 a second, the daemon
started and nothing arrived in 12 seconds. A plain HTTP address, a rate
of 6, a misspelt field and a missing file each stopped the daemon before
it listened, with one plain line, and nothing arrived.

The pool was run the same way on 19 November, at 5 a second and 2 at
once, with 24 test URLs on hosts of their own. Two starts of 30 seconds
each brought 137 and 162 connections, each to exactly sixteen of the
pool's hosts on port 443, on two identities each; the two starts picked
different sixteens, sharing eleven. No pool host's name appeared in the
daemon's log. A pool of exactly sixteen brought all sixteen hosts and no
other, and an empty pool brought nothing. A plain HTTP URL at position 21
of 24, a query on the 24th, a URL listed twice, two URLs in one entry, an
entry with a leading space and an empty entry each stopped the daemon
before it listened, with one plain line, and nothing arrived.

**On, 19 November.** Sean's decision ("1. a"): cover on, with the pool
of 58 pages that answered a Tor visitor in the measurement above, at the
rate already in the list, 0.05 a second with 2 at once. They are the
list's URLs, each exactly as fetched then: all HTTPS, none with a query
or a space, none listed twice, on 32 sites. From the next guest build,
every start of the guest, in the app and in the stage kits (which run the
real tor), sends cover through Tor to sixteen of them. Known limits:

- The sites have not agreed to automated visits. The spec asks for
  destinations that permit the traffic (NET04); that is not shown.
- The worker counts a page longer than 64 KiB as failed: it reads to the
  cap and stops. 48 of the 58 reached the cap in the probe, so most
  attempts on this pool count as failed in the totals although the
  request went out.
- The same sixteen serve until the next start.

With cover on in the image, the checks that list every connection the
stand-in tor sees (`tests/test_agent_path.py`, `tests/test_tor_path.py`)
boot with an empty list laid over the image's, the same one-file archive
as the cover checks (`tests/cover_list.py`), so they assert what they
did; the Tor check on the public Tor network thereby still sends only
what it lists. The checks that list no connections
(`tests/test_guest_path.py`, `tests/test_task_path.py`) boot the image as
built, with cover on. One
more check in `tests/test_cover_path.py` boots the image as built, with
no list laid over it: cover connections arrive, each for one of the
list's sites on port 443, at most sixteen sites, on no more than two
identities and none the conversation's. Its Pi task is followed by a
200-second wait, so at 0.05 a second about one boot in 22,000 sees no
cover at all (e^-10). Passed on 19 November on the rebuilt guest.

What it is, in the reference's own words: background noise, not proven
protection against traffic analysis. It does not pad the model's
requests, hide when Cloak starts or stops, or make traffic constant, and
a global observer can still correlate traffic. Cloak claims no more.
Real pages have been fetched only in the measurement above; no schedule
or lifecycle has been checked against the policy on the real route, so
A08 stays open.

### Escape checks (19 November 2026)

All twelve passed on 19 November on a guest rebuilt with the fix below,
with every other guest check (65 in all). Before the fix, eleven passed
and the cross-conversation check failed, as it should have.

Release plan item 4 (`docs/release.md`): a hostile agent, running commands
as the agent in the reference sandbox, tries to get out.
`tests/test_escape_path.py` boots the guest twice. The first boot runs
each attempt as a plain command in the sandbox, with cover off and the
stand-in tor, so tor's log lists only what the attempts cause. The second
serves, with two conversations on the stand-in door's scripted answers,
two of them new (`peek` and `plant` in `tests/door_answers.json`). The
boot helpers the guest checks share now live in `tests/guest_boot.py`.
None of this has run yet: each line below is what the check expects, from
reading the code, and what should stop the attempt.

- **Loopback.** The sandbox shares the guest's network, so it sees what
  listens there: the Tor port (9050), the adapter (8012) and the daemon
  (8787), all on 127.0.0.1, and nothing on UDP.
- **The Tor port without torsocks.** A SOCKS5 request made by hand goes to
  tor for whatever destination it names, and tor's answer comes back: any
  program in the sandbox can use Tor this way. It can also pick its own
  identity, a guess at another's included. The daemon's identity is 32
  random bytes, which no guess finds. tor's log holds those three requests
  and nothing else.
- **The adapter** takes only a POST to its one route with the rewriter
  key, which the sandbox cannot read: 401 with no key and with Pi's key
  `local`, 405 for a GET, 404 for another path. Nothing reaches the worker.
- **The daemon**, read in its pinned code (`internal/server/server.go`):
  its two inference routes take any request from loopback, with or without
  a key, as Pi's do in the agent check; every other route takes only the
  daemon's own key, 32 random bytes made at its start and kept in memory.
  Pi's key `local` gets 401 on the status, funding address, deposit and
  withdrawal routes. The guest's daemon has no admin service, so even its
  own key reaches only the read-only status, and nothing over HTTP changes
  rewording, payment or settings. A tool can send a model request to the
  inference route itself; it goes the way Pi's goes, which in the guest
  stops before any payment ("The wallet companion could not be reached",
  `tests/test_tor_path.py`).
- **Vsock.** The Mac answers none of ports 8742 (the door, open only while
  the guest serves), 8020 and 8030.
- **Files.** The guest's secrets, its settings (`/etc/cloak`) and the
  tasks' copies of the wrapper (`/run/cloak-runner`) are not in the
  sandbox, and reading them fails. Writing to the guest's `/etc` files the
  sandbox binds, to the wrapper and to `/usr/bin` fails. A link in the
  workspace to the rewriter key leads nowhere inside the sandbox.
- **Other ways out.** TCP to port 53, UDP to port 443 (with torsocks and
  without), IPv6 and ping reach nothing: the guest has no network device.
  No abstract UNIX socket is open in the guest; such names belong to the
  network, which the sandbox shares.
- **A child that tries to stay.** A process in a session of its own that
  ignores hang-ups ends with its case: when the command ends, bubblewrap's
  first process in the sandbox ends, and every process in it with it.
- **Another conversation.** While s-b's task runs, s-a's tool cannot list
  s-b's folders or s-b's copy of the wrapper. It sees only its own copy,
  and finds its own pass and not s-b's. A link s-a's tool leaves in its
  home in place of `.pi` stops s-a's own next task before Pi starts, and
  s-b's tool then finds only its own pass.

**Found while writing them, and fixed the same day (19 November): one
conversation could write into another's files.** The sandbox script ran
two lines before bubblewrap, as the agent user and with the guest's whole
view: they made `.pi/agent` in the conversation's home and copied the
task's `models.json`, pass inside, into it. Both followed links, and
every conversation's folders belong to the agent user
(`guest/runner/main.go`, `agentFolder`). So a tool in s-a could put a
link to s-b's workspace in place of its home's `.pi`, and s-a's next task
wrote its `models.json`, s-a's pass inside, into s-b's workspace. The
same two lines could have overwritten s-b's own `models.json` in s-b's
home.

The fix deletes both lines (`reference/wrapper/sandbox`, the
reconstructed reference wrapper, which is Cloak's own file and carries no
pin; this is its second correction, after 12 November's). Nothing outside
the sandbox writes into the home any more. bubblewrap binds the task's
`models.json` read-only where Pi reads it (`~/.pi/agent/models.json`) and
makes that mount point inside the sandbox's own root. bubblewrap 0.12.0,
the guest's, resolves every path it sets up inside that root (openat2
with `RESOLVE_IN_ROOT`, its fix for GHSA-pxhw-h44j-8pfx) and refuses to
mount on a link, so a link the agent left in its home leads only to what
the sandbox already holds. The pass is no longer left in the home: only
the mount point stays there, an empty read-only file. The script still
makes the home itself when it is missing (the agent check's); no tool
can reach the folder that holds a home.

Tried on 19 November with the guest's own bubblewrap package
(0.12.0-1~deb13u1, in the guest build image under Docker, not in the
guest), laid out as the runner lays out two conversations: with the old
script the planted link put s-a's pass in s-b's workspace. With the new
one, s-a's next task stopped at bubblewrap's start and nothing appeared
in s-b's folders, for a link to s-b's workspace by its path, by a
relative path, through bubblewrap's own `/oldroot` and to s-b's home
`.pi/agent` (s-b's own file unchanged); a link in place of `models.json`
itself is refused too. A link to the sandbox's own `/tmp` works and stays
inside the sandbox.

What the check sees changes in one way: while a task runs, its tool
cannot remove `~/.pi`, because the mount point inside is busy. So `plant`
now moves the folder aside and leaves the link in its place, and the
check also expects s-a's next task to end with status 1 before Pi says
anything. Pi 1.3.0 in its JSON mode reads `models.json` once, at its
start; it reads it again only when an extension registers a provider
(Cloak's Pi has none) or in its interactive and RPC modes. No check sees
an overwrite of s-b's own file: before the fix, s-b's own next start
copied its own file back before Pi read it.

**Not tried, and why.**

- The guest's own sender and runner ports from the sandbox: these checks
  dial the Mac only. The probe takes any vsock address since 19
  November (an optional third argument), but the guest loads no vsock
  loopback module, so its own address is not expected to reach them;
  `tests/test_pay_path.py`, not yet run, tries that for `cloak-pay`'s
  port.
- TCP to port 53 under torsocks: the check uses busybox's `nc`, which skips
  torsocks, so tor's log stays exact.
- A new file in the sandbox's own `/etc`: bubblewrap builds the sandbox's
  root in memory, and whether it leaves that root writable was not looked
  up. A file made there would stay in that memory, so the checks write to
  the guest's own files instead.
- Abstract UNIX sockets are listed, not connected to.
- Already known: tools in every conversation use Tor with no identity of
  their own, so they share one, as in the reference (Stage 5, below).

### Payment in the guest: cloak-pay (begun 19 November 2026)

Build order steps 1 and 2 of the release plan (`docs/release.md`, "Who
owns what"): the front over vsock and the Tor identities, with stand-ins
only. Nothing in the running product changes. The guest image gains the
program and a user for it, but the boot does not start it, the sender
stays as it is, and no guest has been rebuilt with it.

**What is built.** `cloak-pay` is the pinned mainnet daemon
(`reference/src/zkapi-mainnet/zkapi-clientd`, never edited in place)
compiled with an overlay, the way `cloak-daemon` is: two files added to
its command package (`guest/pay/zz_cloak_pay.go`, and
`guest/pay/zz_cloak_pay_linux.go`, which builds only for Linux), and
copies of three of its files patched at build time (`guest/pay/*.patch`).
`guest/build.sh` builds it, and the image installs it as
`/usr/bin/cloak-pay`, with a guest user `pay` (1009) to run it as.

**The front.** It serves the host only, on the guest's vsock port 8021
(the sender's is 8020), one request to a connection, in the sender's
framing: a kind byte, a four-byte big-endian length, the payload.

    host:      R {"identity": "<64 hex>", "body": "<chat request, JSON>"}
    cloak-pay: A {"status": <HTTP status>, "body": "<answer, JSON>"}

The body is the Mac's request in OpenAI's chat shape, already reworded.
The identity is the conversation's Tor identity, checked as the sender
checks it (32 bytes in hex). No key and no wallet secret is in a frame.
The body goes through the daemon's own inference API
(`internal/server/server.go`), called in the process as a POST to
`/v1/chat/completions`, and the answer is what that API writes. A frame
that does not read, has another field, or carries no valid identity gets
status 400 and nothing leaves for it. A connection from any vsock address
but the host's (2) is closed with no answer. If the host hangs up first,
the request is cancelled, as the daemon's HTTP server cancels one whose
client goes away.

**No loopback listener.** The daemon's local API (127.0.0.1:8787), with
its keyless loopback inference and its admin routes, is never started.
`cloak-pay`'s start is an `init` function that runs before the daemon's
`main` and ends the process itself, so none of the daemon's commands runs:
not its local API, not its admin service, not its companion start or the
companion's CONNECT proxy. The inference API is built as the daemon's
own `serve` builds it, from the same relay client, wallet client, error
mapping and request log, but with bearer authentication on (its key made
at start and kept in memory), no admin handler, and nothing listening:
the front calls it directly. The daemon's session reporting and automatic
settlement run as upstream runs them.

**The Tor identities.** The patches make Tor the only route and carry over
the post's identity code (from `zkapi-clientd` at vbuterin/zkapi
`0fb263b0`, `internal/relay`):

- `relay.patch` (+43, −171 lines): a route must be `tor://` with a
  numeric loopback address and port, or the daemon does not start. Every
  connection goes through Tor's SOCKS port under an identity: the one
  its request carries, or a new one of 32 random bytes. The direct
  route, the Wisp relay and the default relay address are deleted.
- `socks5.patch` (+17, −4): the SOCKS greeting offers only user name and
  password (RFC 1929), the identity as the user name and `x` as the
  password, as upstream's identity code does. The method with no
  authentication is gone.
- `client.patch` (+16, −2): the conversation's identity reaches the
  wallet client under a key no dialer reads, and the client puts it on
  the inference request alone. Everything else a request causes, the
  model policy, the companion's settlement and RPC through the CONNECT
  proxy, gets a new identity for each connection.

`guest/pay/check.sh` runs the checks below but the vsock run. The
mainnet tree is untrusted, as in `guest/zkapi/build.sh`, and none of its
code runs on the Mac: there the script only formats, vets and compiles,
with cgo off, no VCS stamping (which runs git in the tree), no toolchain
download and its own `GOFLAGS`. Everything that runs the tree's code
runs in the pinned Go image of `guest/zkapi/build.sh`, with no network,
the repository and the Mac's Go module cache read-only, its build cache
in a Docker volume of its own (`cloak-pay-check`), two cores, 4 GB and
low priority. `guest/build.sh`'s new lines only compile, the same way.

**What each check showed (19 November; the tests in the pinned Go image,
as above).**

- **Two conversations, stand-ins only** (`zz_cloak_pay_test.go`). A
  stand-in for the guest's Tor port records each connection's
  authentication, user name and destination, and answers only the model
  policy and OpenRouter, itself, under a test certificate authority that
  is the only one the test trusts. A stand-in companion answers the
  daemon's status, lease and settlement calls. Two frames, under
  identities a and b, each got the canned answer. The two inferences
  reached Tor under a and then b. The four model policy fetches, and two
  connections the test made through the CONNECT proxy as the companion
  would, each reached Tor under an identity of its own, neither a nor b.
  Every connection offered only user name and password. The two requests
  carried two different provider keys, and the provider got each body as
  sent, less the `user` field the daemon drops. Four bad frames (an
  identity not hex, one too short, none, and an extra field) each got the
  400, and reached neither Tor nor the companion. The container's
  listening TCP sockets (`/proc/net/tcp` and `tcp6`) were the two
  stand-ins' before and after.
- **Three broken copies of the patches** (by hand, in the same image),
  each failing that check as it should: no identity on the inference
  (caught: the inferences arrived under new identities), the
  conversation's identity on the whole request (caught: the model policy
  arrived under it), and a greeting with no authentication (the stand-in
  refused it, and the request failed).
- The check ten times over under Go's race detector: passed.
- **Tor only.** An empty route, `socks5://`, `wss://`, a `tor://` route
  to an address not on loopback, and one with a user name: the daemon and
  the CONNECT proxy each refuse to start on every one.
- **The accept rule**, as a function: only address 2 is taken (0, 1, 3
  and the "any" address are not).
- **In Linux, over real vsock**, run once by hand and not in the script,
  as it needs the container's default system call filter lifted so a
  vsock socket can be opened. The guest build of `cloak-pay` in a Linux
  container with no network (Docker Desktop's Linux): it printed
  `ready`; the container's TCP and UDP tables were empty; the process
  held one socket, its vsock port; a whole frame sent
  from the container's own vsock address (1) was closed with no answer,
  and the process kept running. A control build that takes address 1 as
  the host answered the same frame: 502, `anonymous_access_failed`, as
  there is no companion. It refused any command-line argument.
- The daemon's own tests of the wallet client package pass with
  `client.patch`. gofmt and go vet (for the guest, tests included) are
  clean, and the guest build is a static linux/arm64 program.

**The guest check, written but not run.** `tests/test_pay_path.py`, from
the agent's sandbox: the loopback table stays the three of the escape
checks, nothing answers on 8790, and a whole frame to vsock port 8021
reaches nothing at address 1 (the guest's own), 2 (the Mac) or 3 (the
guest's, as the Mac gives it). It is marked skip: with nothing starting
`cloak-pay`, it would pass whether or not `cloak-pay` holds. Its
docstring gives the boot lines and the commands. 8787 there is the
guest daemon's, the sender's path, until that path is removed. The
probe (`guest/vsockprobe`) now takes the vsock address as an optional
third argument.

**Not built, or not shown.**

- The encrypted disk, the real companion and proving keys, the Mac side,
  removing the sender: later steps. Nothing
  starts the companion, so every request stops at the daemon's companion
  check, before a key is asked for (read in the code; the Linux run
  answered in 1 ms).
- The host's tor isolating by these user names: the stand-in only records
  them.
- A connection from the real Mac over vsock: the host's address could not
  be taken on the Mac or in the container.
- What fights the design: upstream starts its companion as an HTTP server
  on 127.0.0.1:8790 and gives it the daemon's CONNECT proxy on another
  loopback port. Each has a secret, but both would be listeners on the
  network the sandbox shares. Step 5 has to settle where they listen.
- The answer frame carries the status and body only, not the API's
  headers, `X-OA-Verification-Status` among them. A streamed answer
  arrives whole, in one frame, when the API returns. The daemon's own
  error messages, which name `zkapi-clientd config`, reach the host as
  they are.

**Step 3, holding during settlement (20 November 2026).** Stand-ins
only, as before; nothing in the running product changes.

- **One at a time, in order.** Requests reach the daemon's API one at a
  time, in the order their frames were read in full (`payTurns`, a queue
  in `zz_cloak_pay.go`): the guest's own guarantee, whatever the
  daemon's slots allow.
- **The hold** (`WaitSettled`, in `client.patch`). Before a request asks
  for its key it takes the daemon's request slot and reads the wallet.
  If the wallet reports a request whose settlement is unfinished, this
  run's or one an earlier run left in the wallet's journal, it asks the
  companion to settle until the companion says nothing is pending,
  waiting the daemon's settlement poll (5 s) after each "still pending".
  It asks for no key meanwhile. A wallet error from the hold fails the
  request (502); nothing is retried.
- **A hang-up.** A host that closes its connection cancels its request:
  waiting for its turn it leaves the queue, and held it asks nothing
  more, leaving the settlement to the journal. Nothing is sent or spent
  for it.
- **A stop.** `cloak-pay` ends on SIGTERM as the daemon's own serve
  ends: no new request is taken, one waiting is closed unanswered, one
  held or waiting for its key is answered 408 with nothing spent, a
  settlement under way is cut and left in the journal, which the next
  run's first request waits on. It logs "stopped" and exits 0 once every
  connection and the daemon's session reporting and automatic settlement
  have ended. The vsock listener is non-blocking, so closing it ends a
  waiting accept.
- **What the checks showed** (`sh guest/pay/check.sh`, the pinned image,
  no network; the companion and Tor are stand-ins). The next request is
  held until the earlier one's settlement is done, and asks for its key
  only then; a request is held for a settlement an earlier run left; a
  SIGTERM ends it as above; a held request whose host hangs up asks
  nothing more (behind automatic settlement and waiting for its turn,
  and in the settlement an earlier run left), each counted call by call
  against an exact list; three requests take their turns in order. The
  worker ran every check 300 times under the race detector with no
  failure, and broken copies (the hold removed, an extra status call
  after a settle call, a status call from a cancelled waiter, and the
  earlier three) each failed the check meant for them. The chief ran
  the script three times: clean.
- **A fault found in the check, not the program.** The daemon's session
  reporter reads the companion's status every 5 s on its own; the
  stand-in counted that as the request's, so one run in about seventy
  failed under the race detector. The stand-in now logs the reporter's
  rounds and takes them out of the count.
- **Left for later steps.** The Mac needs its own time limit and a
  "still settling" state to show (step 6). That the journal survives a
  restart is shown only with the stand-in (step 5). The hold's own
  settle failure reaches the host as a plain 502.

**Step 4, the encrypted disk (20 November 2026).** Stand-ins only; the
app attaches no disk until step 6. What it is, its checks and its known
limits are in CHANGELOG.md.

- **For step 5.** The payer's home is the disk (`/var/lib/cloak-pay`),
  so upstream's defaults land there: the daemon's
  `$HOME/.config/zkapi-clientd` and the companion's `zkapi/mainnet/…`
  folder (note secret, journal, archive, leases). Start `cloak-pay`
  after "cloak-guest: payment disk open". The disk is mounted `noexec`
  and the guest has no network, so the real companion and the proving
  keys ship read-only in the image. The companion's listener on
  127.0.0.1:8790 is reachable from the agent's sandbox, which shares
  the guest's network: settle that before `cloak-pay` starts at boot.
  The proving keys' size and the archive's growth are not yet known.
- **Left for later.** The disk is optional in the host until the app
  passes one (step 6). `docs/plan.md`'s escape checks list the disk
  attempts only here.

**Step 5, the real companion (20 November 2026).** Built by a worker,
checked by the chief in the real guest; what it is, its checks and its
known limits are in CHANGELOG.md. The payer runs in a network namespace
of its own, which settles the companion's listener. `tests/test_pay_path.py`,
named above as written but not run, is gone: its checks are in
`tests/test_escape_path.py`.

**Step 6, the Mac half (merged 21 November 2026).** Built by a worker on
`t3/zkapi-token-inference-mac`, read and checked by the chief; what it is
and its checks are in CHANGELOG.md. It carries decisions 25, 26 and 28:
four modes, Agent in V and Token Inference, Start opens Chat with the
Modes page. Where the worker corrected the design: a hold is two `H`
frames (held, then released); a Withdraw press does not stop new
requests (rule 11); the fee figure in dollars, the trial's times and the
30-day claim stay off screen; the three-day notice became a mark on the
Wallet button from ten days before the expiry; an empty amount on Send
Out sends everything. The chief kept "Cards aren't accepted." on the
Modes page, since "taken" already names a deposit anyone may claim.

**Step 6, the guest half (merged 21 November 2026).** Built by a worker on
`t3/guest-zkapi-step6-frames`, read by the chief against the Mac half and
the vault's source (`Types.sol`'s `Note` and `NoteStatus`, the vault's
own `paused`), and checked by the chief in the real guest; what it is and
its checks are in CHANGELOG.md. Where the daemon differs from what the
brief expected, with neither side changed: `GET /admin/withdrawal` reads
the chain first, so with no network it answers 502, not 200; the first
read of the deposit with the chain makes the payer's Ethereum key, as
`GET /admin/funding/address` does; with no network the whole read fails,
so the Mac's refresh shows a failure; and a hold that ends in an error
sends no second `H`, the answer or the hang-up being its end, which the
Mac already takes so. Not proven until step 7: a read of the deposit
while the real companion settles, and the chain read against the
deployed vault.

**Step 7, first pass (21 November 2026, the chief).** The payer in the
real guest, through the real tor, against the real chain and service, on
a blank payment disk in a temporary folder, with no deposit and nothing
approved (`/tmp/cloak-build/step7.py`; the answers are not kept in the
repository). What it showed:

- The guest serves 11 seconds after start. A read of the deposit with
  the chain takes about 3.5 seconds and gives one block's values
  (unpaused, balance 0); the address, withdrawal and leftover reads
  take 1.5 to 2 seconds each; the model list takes about 10 seconds.
- A chat request with no deposit is refused 402 `funding_required` in
  about 4 seconds, with no hold. The refusal is the payer's own.
- A deposit quote for $5 takes about 26 seconds to make and lives 30
  seconds from then. It asked 0.0032 ETH for the deposit and up to
  0.0026 ETH in network fees, so about $4 of fees on a $5 deposit at
  that hour's price. Sean is told this before step 8.
- One fault in the Mac half, fixed the same day: a quote's `expires_at`
  is in milliseconds, and the Mac read it as seconds, so a quote would
  never have shown as run out and its countdown would have been wrong.
- Every answer's shape matches what the Mac reads.

- **Seen in the app (21 November 2026, the chief, on Sean's Mac, with
  no deposit).** Started from Chat, V's wallet showed the payer's own
  address on Ethereum, 0 ETH on hand, Send Out off with "Nothing to
  send", and Deposit. A deposit of 5 dollars typed in and Deposit
  pressed brought the real service's quote into Review: 0.003172 ETH
  to deposit, a fee of up to 0.0126 ETH, 0.015772 ETH in all, "Needs
  0.015772 ETH more", and New Quote once its 30 seconds were over.
  Nothing was approved, and nothing could have been: the address holds
  nothing. The fee had been up to 0.002627 ETH on the same 5 dollars a
  few hours before (the first pass above), so it moves with Ethereum's
  fees and can be several times a small deposit. It is a ceiling, and
  that one was quoted at a peak: half an hour later a public node gave
  Ethereum's base fee as 0.36 gwei, with a median of 0.5 and a peak of
  5.9 over the three and a half hours before. The trial of 17 November
  had a ceiling of 0.0013 ETH and paid 0.00086. Review now says the fee
  and total in dollars too, so a peak is plain before anything is
  approved. Starting Cloak for this made the payment disk and the
  payer's address on this Mac, as any first Start does.
- **Still for step 7.** Memory in the guest during a real proof and the
  hold during a real settlement, both of which need a deposit, so they
  join step 8; and what happens when the payer ends after "ready".
- **For step 7, as first listed.** The companion's route through the payer's Tor port to
  the host's real tor; a call to the real service with no note,
  expecting 402; memory in the guest during a real proof; and what
  happens when the payer ends after "ready".

## Stage 3 so far

- The feasibility kit is ready: `uv run scripts/stage3.py feasibility <name>`
  writes one candidate's stage 3 record (EVAL05, EVAL06, EVAL07) to
  `evidence/stage3/<name>/`, and `uv run scripts/stage3.py eval01 <name>`
  runs the development screen. The candidates are the small lead and the
  small challenger as GGUF files on llama.cpp under the reply grammar
  (decisions 7 to 9). The small lead has two feasibility runs and two
  EVAL01 screens (below); the small challenger has none. The runs of the
  candidates deleted on 14 November (decision 8) stay below as history.
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
  whole-product peak is the sum of all of them. It also keeps the worker's
  own memory figures from its log: the weights and Metal's allocation after
  each load, and the context reserved and Metal's allocation after each
  rewrite. It also records the installed size and the end-to-end time per
  case.
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
- What a real run needs. Disk: the small lead is 5,693,338,202 bytes and
  the small challenger 7,008,055,140 (11.8 GiB together). Memory: the kit
  refuses to boot unless the model's size plus 5 GiB is available
  (10.3 GiB for the small lead, 11.5 GiB for the small challenger).

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

To settle: the runaway. The grammar's white space between tokens is now
at most 16 characters at a time (14 November; removing it, as first
planned, sent the stand-in into other runaways: "Stand-in proof" below),
which makes a new grammar hash and so a new candidate configuration, to be
run again.
Whether the rewrites keep what they must is still unjudged (EVAL01,
stage 4).

The weights were deleted after the run.

### Small lead on llama.cpp with the bounded reply grammar (14 November 2026)

[feasibility-20261114T052945Z.json](../evidence/stage3/small-lead-gguf-grammar/feasibility-20261114T052945Z.json),
kit commit `ec10834`: the same GGUF file, decoded under the grammar whose
white space between tokens is at most 16 characters at a time. A candidate
record; it closes no gate (hand-run steps open, no cover traffic or payment
vault, the Mac on AC power but busy: one-minute load about 30 at the start
and 41 at the end).

- EVAL06: 40 of 40 ordinary messages rewritten; none malformed, none timed
  out. Median 1.12 s and 95th percentile 3.28 s against the proposed 5 s
  and 15 s: the proposed targets are met. The first grammar: 39 of 40.
- Memory: the whole product peaked at 6.79 GiB, in the main boot; 6.74 GiB
  in the worker-loss boot and 6.69 GiB in the restart boot. Under the
  10 GiB line and the 9.3 GiB aim. No swap growth.
- Long inputs: 4,096 characters in 2.98 s, 10,000 in 5.22 s. The four-turn
  conversation was rebuilt in 4.07 s over four calls. Cancellation: the
  worker answered 1.32 s after the cancel; the next call was rewritten.
  Worker loss and restart as before.
- All cases: 50 of 59 rewritten; stopped: 7 over the input limit, 1
  cancelled, 1 worker lost, each as the case intends. Installed: 5.43 GiB.

One run: the stand-in still has a word runaway under this grammar (e06-36),
so a runaway on some other input is not ruled out, and the deadline stays
what stops one. Whether the rewrites keep what they must is still unjudged
(EVAL01, stage 4).

The weights were kept on disk for the EVAL01 screen.

### Small lead, the EVAL01 development screen on both engines (14 November 2026)

[llama.cpp with the grammar](../evidence/stage3/small-lead-gguf-grammar/eval01-20261114T053107Z.json)
and [MLX](../evidence/stage3/small-lead/eval01-20261114T053453Z.json), the
daemon's 16 synthetic cases, one run each. A development screen; it closes
no gate.

- llama.cpp with the grammar: 16 of 16 rewritten, 9 passed the daemon's
  screen; median 0.88 s, 95th percentile 1.37 s.
- MLX: 16 of 16 rewritten, 10 passed; median 0.65 s, 95th percentile 1.12 s.
- The screen looks for exact strings, and most misses are of that kind on
  both engines: "five" for "5", "three" for "3", "TODO" for "TODOs", the
  path kept without its backticks.
- Misses that change the request, read by hand:
  - both engines answer the Spanish request in English ("fotosíntesis"
    becomes "photosynthesis");
  - llama.cpp turns "4 laptops, maximum £900" into "a total cost of exactly
    £900 or less";
  - MLX turns the privacy question into an instruction to disable
    everything "except privacy preservation and skills", and "dinner
    options" into "dinner recipes".

Neither engine is ahead on what the rewrites keep. Engine choice
(decision 8): llama.cpp with the grammar, on reply shape (40 of 40 against
36 of 40) and memory (6.79 GiB against 7.22 GiB). The MLX worker and its
candidates are to be deleted. The changed requests above are the small
model's, not the engine's, and are stage 4's to judge.

Run again on llama.cpp with the grammar once the MLX worker was deleted
([record](../evidence/stage3/small-lead-gguf-grammar/eval01-20261114T062754Z.json),
14 November): the same 16 texts byte for byte, so the same 9 passed;
median 0.82 s, 95th percentile 1.18 s, whole product 6.67 GiB at its peak,
with load averages of 35 to 41 from other apps.

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
  reads a long prompt is shown by the worker's checks (now
  `tests/test_llama_worker.py`) and `tests/test_guest_path.py`, not by this
  run.
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
the worker's checks (now `tests/test_llama_worker.py`) cover both.

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

White space between tokens, bounded (14 November), against the runaway
(the small lead's e06-37 above, and e06-10 here). Each EVAL06 message
through the stand-in's worker alone, without a grammar and under each
candidate grammar:

- No white space between tokens, as first planned (`{"texts":[...]}`
  exactly): 35 of the 40 replies changed, since the stand-in writes the
  spaced form by itself, and six of them (e06-13, 29, 30, 31, 36 and 37)
  then ran to the 16,384-token limit repeating words. Not taken.
- At most 16 white space characters at a time, room for a line break and
  indentation (taken): 39 of the 40 replies are the same bytes as without
  a grammar, e06-36 included, which runs to the limit either way. e06-10
  stops after 66 tokens: its white space is cut at 16 characters, and the
  reply closes, with a stray `]}` and the start of a note inside its text;
  the daemon takes it, and EVAL01 would judge it. The longest run of white
  space in any other reply is 5 characters.

Every other runaway seen on the stand-in repeats words, which bounding
white space does not touch, and the grammar still allows any text the
daemon takes. `tests/test_llama_worker.py` checks that the daemon accepts
every reply the model ended and only those, and that no white space
between tokens runs past 16 characters.

The stand-in under the bounded grammar, `standin-gguf-grammar` again,
[feasibility-20261114T041104Z.json](../evidence/stage3/standin-gguf-grammar/feasibility-20261114T041104Z.json),
14 November, kit commit `3d1509d`, on AC power, the one-minute load 38
before and 31 after.
Development only. Beside the grammar's first run above:

- EVAL06 39 of 40 rewritten against 38, 39 of them the same bytes as
  there. e06-10 is rewritten in 0.69 s where it ran to its time limit
  (91.7 s), closing its reply with the stray `]}` and the start of a note
  inside its text, as on the worker alone. e06-36 still runs away in
  words: it reached the 16,384-token limit in 106 s (truncated), where on
  the busier machine it reached its time limit first (116.6 s).
- All cases 51 of 59 rewritten against 50; the other seven are over the
  input limit, as before. The four-turn conversation is rewritten (3.00 s
  over four calls).
- Median 0.37 s against 0.60 s, and 126 tokens a second generated against
  108, on a quieter machine; the worker's sampled peak 2.08 GiB against
  2.52, and the whole product's 2.66 GiB against 3.26.

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
- 35 checks in `tests/test_stage4.py` passed until they were deleted on
  19 November (decision 15), including: Tango's bound is where the score
  statistic reaches the critical value and is z²/(n + z²) with no paired
  failure; a candidate as good as the reference never passes; the
  sign-flip bound equals the brute-force subset mean; the exact power
  equals a direct sum; pins, refusals and the blinded review behave as
  above. Nothing checks the kit now.

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

The protocol leaves these open; the kit fixes them in code before any
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
  the bundle's manifest; tor, the worker and a check guest started in
  turn, each once the one before is up; a startup check that sends one
  rewrite through the guest, the daemon and the worker; tor and the worker
  watched; one shutdown; Needs attention with a reason code on any failure,
  with nothing restarted and no other route or model; Paused at every
  launch, after sleep and after a relaunch, and at login, which the Details
  window's Login switch turns on (off until then); the boot files a killed
  app left, removed at each launch (state-machines.md, section 9);
  `cloak status`, `start`,
  `pause`, `resume`, `stop`, `verify` and `doctor`, with versioned JSON
  (INS01, INS02), over an owner-only socket that checks the peer's user
  (MAC05). One model, named in the manifest, with no picker: the small
  lead, `small-lead-gguf-grammar`, shown as Qwen 3.5 9B, on a Mac with at
  least 16 GB (14 November; the stand-in before).
- What does not exist yet: sessions (Running has no session guest; the
  check guest stays up after its check only to run Development mode's
  sender, and its end is a failure), the daemon's own payment
  and wallets (Development mode's one wallet, decision 10, is not them),
  the OS-approval and funding states, setup and model download
  from the app, updates, recovery, and a Developer ID signature and
  notarization.
- Live run on the development Mac, 13 November, stand-in only: from Paused,
  `cloak start` reached Running in about 6 s, the check's rewrite taking
  0.25 s through the real guest path; `pause` stopped tor and the worker;
  with the worker killed by its process number while Running, the app went
  to Needs attention (`worker_stopped`), stopped tor, and started nothing
  again; `resume` was refused there; `start`, then `stop` (Ready), `verify`
  and `doctor` passed; quitting stopped everything and removed the socket;
  a relaunch came back Paused; with the app closed, `cloak start` opened it
  and reached Running. A live sleep and wake is not shown.
- App pass on the development Mac, 14 November, stand-in only: the menu and
  the Details window in each state (Paused, Preparing, Running, Needs
  attention with the worker killed by its process number, and Ready after a
  stop) are in [shots/](shots/), captured from the app's own windows only:
  the Details window light and dark, the menu and the status icon dark
  only, since they follow the Mac's menu bar and the Mac was not switched
  to light. Read through the accessibility tree, as VoiceOver reads it,
  every control has its name, the menu's items carry Command-S (Start),
  Command-P (Pause), Command-D (Details…) and Command-Q (Quit), and
  Technical details opens from VoiceOver. Command-D chosen in the open menu
  brings Details to the front; Escape and Command-W close it, and the app
  keeps running. Pause during the model load stopped everything in 0.05 s,
  and during the check guest's boot in 0.08 s; Quit during Preparing ended
  the app 0.05 s after it was chosen; each relaunch came back Paused. Not
  shown: the Tab order with the Mac's Keyboard navigation on (off on this
  Mac, where Tab reaches no control in Details, as on any Mac with it off),
  where Technical details cannot take the keyboard focus though the Login
  switch can, so Tab would likely pass it; a spoken VoiceOver run; and a
  live sleep and wake.
- Live run with the small lead on the development Mac, 14 November (load
  averages of 34 to 44 from other apps, on mains power): with the app
  closed, `cloak start` opened it and reached Running in 10.1 s; from
  Paused, Start reached Running in 8.5 s and 8.3 s, and from Needs
  attention in 7.9 s. Each startup check's rewrite took 0.67 to 0.92 s
  through the guest, the daemon and the worker. Three `cloak verify` runs
  passed, each one real rewrite (0.70 to 0.74 s), in 7.6 to 8.0 s each.
  The whole product peaked at 6.72 GiB (7,211,720,312 bytes: the worker
  6.12 GiB, the check guest's virtual machine 0.56 GiB, the app 0.03 GiB,
  tor 0.01 GiB) while starting, and held up to 5.58 GiB while Running once
  the check guest had powered off. With one extra file in the model's
  folder, Start ended in Needs attention in 2.3 to 2.7 s, "The model has
  changed. Reinstall the model, then start again." (`model_changed`), with
  tor stopped; with the file removed, Start reached Running. Quit from
  Running, chosen in the menu through accessibility, ended the app, tor
  and the worker within 4 s. The Details window in each state, light and
  dark, is in [shots/](shots/) again, now with the small lead, taken
  through accessibility actions on the app's own elements and the `cloak`
  command only. Not shown here: a file changed in place at its pinned size
  (the worker's checks show it, `tests/test_llama_worker.py`), and a 16 GB
  Mac.
- A Chat window, up to but not including sending (14 November): "Chat…" in
  the menu opens it. Each message is reworded on the Mac by the app itself
  (`Supervisor.rewrite`), only while Running, through the relay to the
  guest's worker and in turn with the guest's calls; the request is the
  pinned daemon's byte for byte, and a reply counts only under the daemon's
  rules, the 10,000-character cap and the deadline of decision 6.
  `app/Tests/CloakTests/RewriteTests.swift` proved both against the
  daemon's own code until it was deleted on 19 November (decision 15);
  nothing checks the app's request or its reply rules now. Original and Reworded show side by side with the words
  taken out and put in marked; the newest reworded text can be edited; Send
  is shown but off. Turns are kept as drafts, one sealed file per
  conversation in `conversations/`, with one key in the login keychain,
  usable on this Mac only while it is unlocked (the data protection
  keychain refuses an app signed ad hoc, -34018). No conversation text goes
  to the log, the socket, `cloak status` or `cloak doctor`. Nothing is sent.
- Checks so far, 14 November, on a build of the code just before its
  commit, which differs only in the arrow button sitting 4 points lower:
  two real rewordings with the small lead, a 105-word English message in
  1.3 s by the app's log and a Spanish one in about 2 s by the clock (the
  lead answered it in English). The text wrapped at each pane's width at
  the window's default size, 980 by 660 points, and at its smallest, 760 by
  512, in dark; a long chat followed its newest message as it grew. After
  Quit and a relaunch the conversation was back; Delete asked first and
  removed its file; `strings` on the sealed file found none of its words;
  and four samples of the app's sockets (`lsof -i`) during that launch,
  with Cloak not started, showed none. The first Chat opened made the key
  without a prompt; after a rebuild, which changes an ad hoc signature,
  opening Chat brought up the Mac's keychain prompt, which closed when the
  app quit. The dark shots are in [shots/](shots/). Not yet run, held while
  the development Mac was too hot: the light appearance (launching with
  `-AppleInterfaceStyle Light` left the app dark here), a stopped rewording
  on screen, a message over 10,000 characters, a cancel part way, a path
  with a number, an edit of a reworded text, a relaunch after a delete, a
  watch of the app's sockets while it rewords, `tests/test_llama_worker.py`
  and `app/build.sh` on the committed tree.
- Second checks, 14 November, on the code of this round's last change to
  the app (load averages of 26 to 104 from other apps). `app/build.sh`
  built it with no warnings; `swift test --package-path app` passed its 43
  tests; `tests/test_llama_worker.py` passed its 35 in 3 minutes and
  `tests/test_guest_path.py` its 23 in 9 minutes, each run alone. The
  Mac's screen was locked throughout. A locked screen hides the contents
  of the app's windows from accessibility and keeps the app from coming to
  the front, so nothing could be typed or pressed in Chat; the menu still
  answered, and the windows could still be captured by their number.
  - Sockets: from Paused, `cloak verify` reached Ready in 13.5 s, its
    startup check sending one real rewrite through the relay, the guest's
    daemon and the worker. 46 samples of the app's internet sockets (`lsof
    -i`), one every 0.25 s, found none, and one after found none; tor's
    SOCKS port is a Unix socket. A sample while Chat itself rewords waits
    for an unlocked screen.
  - Light: launching the app with the argument
    `-NSRequiresAquaSystemAppearance YES` shows its windows light for that
    run only, without changing the Mac's appearance or the app's code.
    [chat-not-running-light.png](shots/chat-not-running-light.png) is Chat,
    paused, from the final code, drawn as an inactive window since the
    locked screen kept it from the front.
  - Marks: the words taken out are now tinted a lighter red with a dotted
    underline, where they were struck through, so an original with most of
    its words taken out still reads easily; the words put in keep a green
    tint and a solid underline. The `removed-marks-*` shots in
    [shots/](shots/) show the old and new marks on a message with 77 of its
    91 words taken out, drawn offscreen in a text view with the app's font
    and marks.
  - The end in view: a window of the Chat window's shape (a split view;
    messages as cards of two of the app's own text boxes; a box below),
    laid out offscreen and resized by code. Before the change, a
    conversation that fit lost its end by 103 points when the window was
    dragged shorter than it; a conversation growing past the window had
    its newest message cut off by 63 points the first time it stopped
    fitting; and choosing a longer conversation after a short one, or any
    after reading one part way up, opened it at the top. After it, the end
    stayed in view in each case. A conversation read part way up stayed
    where it was as the window shrank and as a message was added, as before.
  - Logs: the rewording's timing lines are at the info level, which macOS
    keeps in memory only by default and does not write to disk, so they
    leave the log within minutes. They stay as they are: no conversation text is logged,
    and keeping them longer would mean writing them to disk.
  - Still to run on an unlocked screen: the four live rewordings, each
    timed (a path with a number, over 10,000 characters, a cancel part
    way, an edit after rewording with its marks following); a stopped
    rewording on screen; a delete, then a relaunch; a socket sample while
    Chat rewords; the new marks and the end in view in the app itself; and
    Chat in light with messages.
- Sending in a Development mode (decision 10), built 14 November and
  proven up to the first payment; no money has moved.
  - The sender, `guest/sender/`: a Rust program in the guest, paying with
    the official MPP toolkit, `mpp` 0.20.0 (pinned in Cargo.toml and
    Cargo.lock, built `--locked` in the pinned Rust image, and listed in
    `reference/sources.json`; past both advisories on the crate,
    GHSA-fxc9-7j2w-vx54, fixed in 0.8.0, and GHSA-8xhq-x7vw-8rcw, fixed in
    0.12.0). The guest starts it after the startup check, as a user of its
    own, and stays up while Running; the guest ending is a failure
    (`guest_failed`). The host connects to it on vsock port 8020, one
    request per connection, in frames of a kind byte, a four-byte length
    and the payload; it serves one connection at a time and gives each its
    turn before the request is built, so a request always carries the
    deposit as last kept.
  - Every connection it makes, to the provider and to the Tempo network,
    goes to the guest's Tor port, 127.0.0.1:9050, as SOCKS5 with names
    resolved by Tor, with no proxy from the environment, no redirect
    followed and 180 s per request. Each conversation has a SOCKS user name
    of its own (32 random bytes, in the app's memory only), so tor's
    IsolateSOCKSAuth gives it circuits of its own; reads of the network and
    the provider's lists each take a fresh one.
  - What goes out: the approved reworded text, after the conversation's
    earlier turns as sent and answered, as `{"model", "messages",
    "stream": false}` and nothing else: no instruction, no original. The
    app builds that body; the sender posts it as given and brings the
    provider's completion back as it came, and the app reads the answer
    from it (since the door, below). The headers of a send are exactly `accept: */*`, `accept-payment:
    tempo/session`, `content-length`, `content-type: application/json` and
    `host`; the paid request is the same with the toolkit's credential
    added (`authorization: Payment …`), which names the wallet and its
    deposit, so the provider can link every chat. No user agent.
  - The wallet: its key is made by the toolkit in the guest when the owner
    presses Create, and kept only in the login keychain (service
    `sh.regents.cloak.wallet`, its account the address, this device only;
    that attribute binds only in the data protection keychain, which
    refuses an app signed ad hoc, as for the conversations' key). It goes
    to the guest in memory, inside the request that signs, and is never in
    a boot file, the image, a log, a command line, the environment, the
    control socket, `cloak status` or `cloak doctor`. One wallet only; no
    spending cap.
  - The deposit: the toolkit opens one at the size the provider's challenge
    suggests, 1 USDC.e today, and tops it up by as much when it cannot pay
    for the next request. Its state is sealed on the Mac
    (`wallet/deposit`, ChaChaPoly under the conversations' key, owner
    only); each change is sent to the host and on disk before the toolkit
    goes on, so a deposit about to open is kept before its payment leaves.
    Close ends it with the provider (a cooperative close: one unpaid
    request with made-up text brings a session challenge, and the toolkit's
    final voucher closes it), which refunds what is unspent; Withdraw asks
    the network to close it and, pressed again after the 900 s grace
    period, takes it back, without the provider.
  - The app: Chat shows Development and the sentence "The provider can link
    your chats, because one wallet pays for all of them." at the top
    always. The newest unanswered message has three lights, Reworded (its
    reworded text is not blank), Routed (Cloak is running, so it goes
    through Tor) and Unlinked (never good here), and Send. Send is off,
    with words beside it, only where sending is certain to stop: nothing
    reworded, Cloak not running, no wallet, or no deposit to pay from and
    too little for a new one, as the network last showed the wallet. A
    press while one is under way is sent too. Once sent, the text can no
    longer be edited or reworded; the answer is kept sealed with its
    conversation. Wallet, in the toolbar: Create, the address to copy, the
    network and token with a check that the provider's own setup page
    still names Tempo's chain 4217 and USDC.e, the balance, the deposit
    held and spent, Close, Withdraw, and the model, with prices, defaulting
    to the cheapest, `deepseek/deepseek-v4-flash-0731` ($0.04 in, $0.21
    out per million tokens on 14 November). Stops in plain words: no funds,
    wallet refused, model unavailable, Tor down, no answer, failed, not
    running. No fallback: a stopped send is shown and nothing else is
    tried.
  - Not as asked: there is no Deposit size to choose. The toolkit sizes
    each deposit from the provider's suggestion, using its own default only
    when a challenge suggests none, and its one limit caps what a deposit
    pays in all, which would stop sends rather than make deposits smaller;
    so the screen shows the size held instead, and the least balance a
    first deposit needs (1 USDC.e).
  - Checks: `cargo test --manifest-path guest/sender/Cargo.toml`, 10
    tests against stand-ins for the Tor port, the provider and the
    network: the request and its exact headers and body, the answer back,
    each way a send stops and its code, an unfunded send stopping before
    anything reaches the provider, a deposit that can pay needing no
    balance, a Tor port that refuses, the wallet's view, a new key, each
    deposit change kept before the toolkit goes on, and the identities each
    connection uses. `swift test --package-path app`, 53 tests, among them
    the send path against a stand-in sender (the request built at its turn,
    the deposit sealed, each stop, a sender that goes away, a key that
    cannot be read) and the startup check waiting for the sender.
    `guest/build.sh`, `host/build.sh` and `app/build.sh` built it; the
    guest's paths still pass, each file run alone (load averages of 18 to
    45 from other apps): `tests/test_guest_path.py` 23 in 8 min 51 s,
    `tests/test_tor_path.py` 10 in 7 min 41 s and
    `tests/test_agent_path.py` 7 in 46 s.
  - Live, through the real tor from the guest, with a throwaway key never
    funded and gone with the run (`cloak-host --serve`, the stand-in
    worker; load averages near 22): the sender was ready 8.6 s after start;
    Create took 0.00 s; the wallet's view 2.77 s (balance 0, the setup page
    naming chain 4217 and USDC.e, 26 priced models, no deposit); an unfunded
    send stopped as no funds in 5.69 s, before anything reached the
    provider; and Close with a made-up deposit stopped in 3.43 s with "the
    deposit is not open on the network", after the provider's 402 had been
    read and its challenge parsed and checked, before anything was signed.
    The 402, read with curl through the same tor: HTTP/2 402,
    `application/problem+json`, three `Payment` challenges (USDC.e, MACH,
    OUSD; method tempo, intent session, chain 4217, escrow
    0x4d50…0000, suggested deposit 1000000, 1731 units per request for this
    model), `cache-control: no-store`, a link to the setup page and
    CloudFront's headers. Over the whole run, only tor had internet sockets
    (three relays); `cloak-host`, its children and the virtual machine's
    process had none, and the key was in neither the console nor the
    samples.
  - Not proven: a paid send, a deposit opened or topped up, an answer from
    the provider, Close and Withdraw on a real deposit, and the app's
    screens with these parts (the Mac's screen). They need the owner's
    funded wallet: start Cloak, open Chat, Wallet, press Create, copy the
    address, send it 2 USDC.e on Tempo (chain 4217; the deposit's 1 USDC.e
    and a few cents of network fees), press Refresh until the balance
    shows, then send a harmless message. The first send opens the deposit;
    Close afterwards refunds the rest. Tempo's test network, Moderato (chain
    42431), was not used: Boundless runs on Tempo's main network only, so a
    proof there needs a provider of its own on Moderato and test funds.
- The door (14 November), in Development mode: the owner's other apps on
  this Mac send chat requests in OpenAI's shape to
  `http://127.0.0.1:8742/v1`, each with a pass of its own, and each goes on
  as Chat's do, reworded on the Mac, then sent from the one wallet.
  "Agents…" in the menu opens Agents: the address, Open or why not, one
  sentence on what is reworded, the apps (name, added, requests, last used),
  Add (a name, then the pass shown once with Copy) and Remove (asked
  first). `app/Sources/CloakDoor/`.
  - The listener: Apple's Network framework (`NWListener`), open only while
    Running, on 127.0.0.1 and port 8742 only (a required local endpoint, no
    address reuse, local connections only); when another app holds the
    port, on 127.0.0.1 or on every address, it stays closed and Agents says
    so. A small strict HTTP/1.1 reader: one request per connection, a head
    of at most 16 KiB, a body of at most 4 MiB with `Content-Length` (no
    chunked bodies), the whole request within 30 s; `POST
    /v1/chat/completions` and `GET /v1/models` only, the latter the
    provider's list as it gives it.
  - Passes: "cloak-" and 32 random bytes in hex. Only each pass's SHA-256
    is kept, with the app's name, count and times, sealed with ChaChaPoly
    under the conversations' key (`agents`, owner only), and compared in
    constant time. A request with an `Origin` header, or `Sec-Fetch-Site:
    cross-site`, gets 403, and no response has CORS headers; no pass, a
    wrong one or a removed one gets 401, and nothing else happens. The
    pass is checked before the body is read.
  - What is reworded, as the pinned daemon does it (paths under
    `reference/src/zkapi/zkapi-clientd/internal/`): every message whose
    role is user, replayed as reworded before when the app's last request
    begins this one, else reworded alone, one call per message
    (`rewriter/transcript.go:44-137`; unknown user turns are never passed
    through, line 14). Its text is a string content or each non-blank text
    part; its images, audio and files, and a user message with no text, go
    as they are (`rewriter/rewriter.go:115-174`, rebuilt at 254-262). System
    and developer messages, the model's earlier answers with their tool
    calls, and tool results go as written (`rewriter/transcript.go:81-83`),
    as do the tool definitions and the other fields the daemon keeps
    (`server/server.go:171-245`). A history that is not the last one
    continued gets a new Tor identity (`zkapi/conversation.go:61-92`).
    What the door remembers is per app, in memory only: digests of the
    messages, and the user messages as reworded. The door's transcript
    gives the daemon's messages and asks the daemon's rewrites, byte for
    byte, on 16 requests in four conversations run through the daemon's own
    `Transcript` (`tests/daemon_transcript/main.go`): 13 taken by both, 3
    refused by both.
  - Stricter than the daemon, each refused before anything leaves: a role
    the provider does not take, a text part whose text is not a string,
    images by link and stored files, `n` other than 1 and `store`. The
    10,000-character cap counts one message's texts together (decision 6),
    413 with the daemon's words. `stream_options` is dropped and the
    request goes with `"stream": false`; `stream: true` gets the whole
    answer as one server-sent chunk, then `data: [DONE]`.
  - Sending: the app builds the body, and the sender now posts any body as
    given and brings the completion back as it came (`models` lists the
    provider's models), so system messages and tools can go; Chat's body is
    unchanged. The model must be in the provider's live list, read for each
    request through Tor (2 to 6 s here). Every stop is OpenAI's error
    shape: 401, 403, 400, 404 (no such model), 405, 411, 413, 415, 431,
    505, 402 (no wallet, no funds, wallet refused), 502 (the rewording or the
    provider failed), 503 (Tor down; Cloak paused or stopped), 504 (the
    rewording's deadline). No fallback: nothing is sent unless every user
    message was reworded.
  - Turns: the door's rewordings and Chat's go through the one relay, in
    the order asked, so neither starves the other. Pause, Stop and Quit
    close the door and end each request under way with 503; Quit waits for
    their answers.
  - Logs and disk: the log has each answer's status and time, and the
    rewording's time; no request's text is kept, shown or logged.
  - Checks: `swift test --package-path app`, 65 tests, nine of them the
    door's against stand-ins for the worker and the sender (passes, web
    pages, rewording then sending, earlier turns never sent as written,
    each stop, closing with a request under way, a taken port, and the
    daemon's transcript); `cargo test` in `guest/sender/`, 12;
    `tests/test_guest_path.py`, 23 in 8 min 51 s.
  - Live, on the development Mac with the small lead (load averages of 31
    to 199 from other apps; after six five-minute waits the run went on),
    through the real Tor and provider for the model list only, with no
    wallet in the keychain: Running in 9.5 s, the door listening on
    127.0.0.1:8742 only (`lsof`), the LAN address refused. Agents, driven
    by accessibility actions only, added an app and showed its pass once.
    With curl on loopback: no pass 401, a made-up pass 401, an `Origin`
    403 (each within 5 ms); the models 200 in 3.7 s, 26 listed; a harmless
    chat reworded on the Mac in 0.80 s, then 402 no wallet, 3.0 s in all;
    over the cap 413 in 5 ms, before any rewording; a made-up model 404 in
    2.2 s; `stream: true` reworded in 0.74 s, then 402. Pause during a
    request's model list answered 503 within 0.03 s, and during its
    rewording (9,776 characters, 1.9 s in) within 0.78 s, the rewording
    cancelled; after each, nothing listened and curl could not connect.
    Remove asked first; the removed app's pass then got 401. Agents counted
    8 requests for the app, and a window reopened 4 minutes after a
    request read "last used 4 minutes ago" (read through accessibility). Quit from Running closed the door within 2 ms.
    No request's text was in the app's log, in 4.2 million lines of the
    Mac's log over the run, or in Cloak's folder; the apps file is sealed.
    The first Add made the conversations' key in the login keychain, as
    Chat's first conversation would; this Mac had no conversations, so the
    run's key and apps file were removed afterwards.
  - Not proven: an answer through the door, and the no-funds stop live (the
    keychain has no wallet, and none was made: the stand-in proves it);
    Quit and Stop during a request live (the tests close the door the same
    way); Agents in light; a spoken VoiceOver run of Agents.
- The owner's agent in the guest (14 November, decision 12), plumbing
  first. A serving guest starts the door port (`cloak-port 8742`, the Tor
  port's program, as user `door`) and the runner (`guest/runner/`, vsock
  port 8030) before the sender; the runner or the sender ending ends the
  guest.
  - A task: the host sends the task text, the conversation's session id,
    the model and the conversation's pass in one frame. The runner makes
    the conversation's home and workspace under
    `/home/agent/conversations/`, a copy of the wrapper for this task whose
    `models.json` names the door (`http://127.0.0.1:8742/v1`) and carries
    the pass, and starts the reference sandbox as the agent user running
    `pi --provider cloak --model … --mode json --session-id …`, with the
    task on Pi's standard input, never a command line (INS03). Pi's lines
    come back as they are written, then how it exited. The host closing
    the connection kills the sandbox and everything in it. One task at a
    time in a conversation; conversations side by side.
  - The door: the host opens vsock port 8742 only when given a door, and
    the app's door serves each guest connection with the one HTTP reader,
    limits, deadline and rules it has for an app's. A box pass
    (`Door.pass(for:)`) works only from the guest, an app's pass only on
    the Mac's loopback.
  - What Pi 1.3.0 sends: the OpenAI library's headers, the user text as a
    list of text parts, `stream: true`, `stream_options`, `store: false`,
    `max_completion_tokens: 16384` and four tools (read, bash, edit,
    write). The door takes it as it is, and Pi carries out the tool calls
    in the door's one-chunk answer. Pi exits 0 when a model request fails;
    its last message's stop reason says so.
  - curl 8.14.1 is in the guest for the agent's tools (21.2 MB of the
    root; the root is now 240,227,840 bytes and `initrd.gz` 97,043,807).
    The guest stays at 1 GiB: with one task running a tool about 550 MiB
    was still available.
  - Checks, with no provider and no money: `swift test --package-path app`,
    79 (the task stream against a stand-in runner; passes on each side
    through the real door; the door's answers byte for byte those the kit's
    stand-in door replays, `tests/door_answers.json`);
    `tests/test_task_path.py`, 2 in about 4 s, through `cloak-host --serve
    --door --runner`: Pi in the sandbox runs the tool call the door hands
    back, curl under torsocks reaches the stand-in tor once and without
    torsocks reaches nothing, the result goes back and Pi ends on the final
    answer; a second task in a busy conversation is refused, another
    conversation runs meanwhile, closing a task closes what its tools held
    within 10 ms, and the next task continues the Pi session. The guest,
    agent and Tor path suites pass (23, 7, 10).
  - In Chat (14 November): a conversation is a chat or the agent's, fixed
    by its first message, chosen with a Chat and Agent control under the
    message box while the conversation is empty. A task is a turn with a
    list of steps (`Turn.steps`, absent in a chat, so saved chats open as
    they were); `CloakChat/Agent.swift` runs it and
    `CloakChat/PiEvent.swift` reads Pi's lines: a tool started is a step,
    the model's last message the answer, a refused request the door's own
    sentence. The card shows the task as written and, once a request of
    it has gone through, as the door reworded it (`Door.reworded(for:)`),
    the steps, the answer, Stop while it runs and Run Again on the newest
    one that did not finish. Run is held back only where a request is
    certain to stop (not running, no wallet, no funds as last seen), by
    the rule Send uses. How a task ended is in memory only; after a
    relaunch one without an answer reads "Not finished". `swift test
    --package-path app`, 91, twelve of them the agent's against a
    stand-in runner. Not built: tasks from the `cloak` command.
  - Seen in the running app on 15 November (build `28923f1`, Sean's go
    "go agent test", his wallet, three tasks in one conversation): a task
    that ran `uname -sr` in the guest and answered with the guest's
    kernel; a second that fetched check.torproject.org's address check
    with curl, which answered `IsTor: true`, and recalled the first task's
    command; a third, `sleep 300`, ended by Stop within seconds as
    Stopped, with Run Again, and Cloak stayed Running. Each showed its
    task as written and as reworded, and its step.
  - Not proven: the end-of-task save on Quit, several tasks against
    the memory line. Known: an answer's Markdown showed as written, marks
    and all (drawn since: "Answers drawn", below); Pi's OpenAI library
    retries a 5xx, so a request the provider was paid for and that then
    failed on the way back could be paid for twice; tools reach the guest's
    loopback services (the daemon's port, the Tor port, the door with their
    own conversation's pass); a conversation's files are held in guest
    memory with no limit; tool traffic shares one Tor circuit, as in the
    reference.
- zkAPI payment, the part Sean put second (14 November, "1. a and then
  b"), as found that day. Nothing can be paid yet: the pinned daemon's
  deployment files for mainnet and Sepolia both say `not_deployed` with no
  vault address (`zkapi-clientd/internal/zkapi/deployments/`), and the
  current README of github.com/ethereum/zkapi (main at `6fb229af`, 57
  commits past the pin) says "concession network manifests are undeployed
  and production proving keys are missing" and that its builds refuse both
  networks. The one live surface it names is the hosted app
  chat.openanonymity.ai, with an Ethereum wallet option; which vault that
  app pays into was not looked up. Deposits are native ETH into
  `ZkApiVault`; the server forwards to OpenRouter under the operator's
  key. The way forward is Sean's choice (wait and track, or run a
  deployment of our own, which is protected work).
  - Corrected 15 November: that finding looked only at the pinned daemon
    and main's README, and missed two live deployments run by Open
    Anonymity. Mainnet: vault `0x4386FDbdA35D995beB3BF8625118Ec5982ec81fe`,
    service `https://zkapi-mainnet.openanonymity.ai` (its `config.json`
    answers), on the earlier circuit `zkapi-v2-note-bound-v1`, served from
    the branch `release/zkapi-server-time-mainnet-20261106` of
    ethereum/zkapi (head `cda02d83`, 6 November). Sepolia: vault
    `0x67eb750d9c0d63a99684ac3f3e65f0c610276993`, service
    `https://zkapi-sepolia.openanonymity.ai/v0.4`, circuit
    `zkapi-v2-concession-v2` with development keys, in ethereum/zkapi main
    and already in `reference/src/zkapi-spec-snapshot`. The pinned daemon
    (vbuterin/zkapi `0fb263b0`, circuit `zkapi-v2-concession-v1`) matches
    neither, so using either means building the daemon from another
    commit. Not yet known: whether their service issues its temporary
    provider keys (`ephemeral_key_source: oa_org`) to a client that is not
    their own app.
  - Looked into the same day (Sean's "2. a": Sepolia first). The Sepolia
    service is behind one shared password, given out privately to a test
    group (`docs/testnet-auth.md` in the snapshot; header
    `X-ZKAPI-Testnet-Password` on every `/v2/*` call): a lease request
    without it answers 401. Cloak has no password, so nothing can be paid
    there until Open Anonymity gives one. The mainnet service has no such
    gate (an empty lease request answers 422, the body refused, not the
    caller). For Sepolia the daemon builds from the snapshot
    (`eac5f906`): its `rewriter.go` is the pinned one byte for byte, so
    `guest/daemon/rewriter.patch` applies; it needs the Rust companion
    `zkapi-walletd` built beside it, the development proving keys in
    `protocol/setup/v2-concession-dev` (about 9 MB, in the repository),
    and at least 0.001 test ETH. Inference goes straight to OpenRouter
    with the temporary key; their server sees only leases and settlement.
  - Mainnet instead (Sean, 15 November, "1. b"), surveyed from
    `reference/src/zkapi-mainnet` (`cda02d83`). Built and measured the
    same day, in the last point below.
    - That tree's daemon has no rewriter: no `internal/rewriter`, and
      neither of Cloak's patches applies. It cannot replace the guest's
      daemon; it would run beside it, for payment only, with the rewrite
      staying on the pinned daemon.
    - Payment needs a Rust companion, `zkapi-walletd`, built from another
      upstream commit (`20aa542`, cloned by the tree's
      `scripts/prepare-zkapi.sh`), natively for linux/arm64. Its memory
      while proving is measured below.
    - Routing: it takes `socks5://127.0.0.1:9050` for every outside
      connection, the Ethereum RPC and the companion's among them, and
      never goes direct when that fails. The companion's own Rust
      connections are read below.
    - Money, read from `protocol/contracts/src/ZkApiVault.sol` and
      `deployments/mainnet.json`: a deposit lasts 30 days
      (`note_ttl_seconds`); after that anyone may call `claimExpired`,
      which sends the note's whole deposit, spent or not, to the
      operator's treasury. The owner can pause deposits and the start of
      withdrawals, and change the treasury. The proving keys are a
      single-party development setup, and the manifest's own limits say
      nothing is production-audited and no funded inference or withdrawal
      is claimed. A request is capped at 50,000 gwei. The daemon's key is
      made in the guest and kept as hex in a file; an outside wallet
      funds its address, which pays the deposit and the gas.
    - Built and measured 15 November, with no money moved: `sh
      guest/zkapi/build.sh` checks every pin, then builds each program in
      Docker on two cores into `guest/build/`. The companion is
      `zkapi-walletd` (`20aa542`) with its protocol submodule (mingyech/zkapi
      `8b2d4e3`), both now pinned in `reference/sources.json`, patched with
      the tree's `companion.patch` and `protocol-transport.patch`. Rust
      lines below are in that patched source, as built.
      - The daemon builds without cgo (`CGO_ENABLED=0`, Go 1.27.4):
        `cloak-zkapi-clientd`, 9,502,880 bytes, static (`ls -l`, `file`).
        The companion needs OpenSSL. In the pinned Rust image alone,
        `cargo build --locked -p openssl-sys` stops at "Could not find
        directory of OpenSSL installation" and "pkg-config could not be
        found": the protocol's `zkapi-client` takes `reqwest` with its
        default native TLS. `guest/zkapi/Dockerfile` adds `pkg-config`,
        `libssl-dev` and `git` to that same image, from the guest image's
        Debian snapshot. `cloak-zkapi-walletd` is 21,528,400 bytes, not
        stripped, and needs `libssl.so.3`, `libcrypto.so.3`,
        `libgcc_s.so.1`, `libz`, `libzstd` and glibc (`ldd`, Debian glibc
        2.41). The guest would also need CA certificates: native TLS reads
        them from the system.
      - The proving keys come with the protocol source, in `setup/v2`:
        `request.pk` 5,935,783 bytes, `request.vk` 671, `withdrawal.pk`
        7,783,719, `withdrawal.vk` 735, 13.7 MB in all. Their SHA-256
        values match the four that `deployments/mainnet.json` pins and the
        daemon checks before it starts the companion (`shasum -a 256`;
        `deployments.go:143-173`). The mainnet tree's `protocol/setup/v2`
        holds the same four files. The service's `config.json` (one GET,
        3,818 bytes) has SHA-256 `95d784e5…`, the value built into the
        daemon (`deployments.go:128`), and is its embedded `mainnet.json`
        byte for byte.
      - One proof, measured with the protocol's own benchmark
        (`cloak-zkapi-proof-bench`, built by the same script). It made and
        verified real proofs for `zkapi-v2-note-bound-v1` with the mainnet
        proving keys, for a made-up note (chain 31337): a note the service
        accepts needs a deposit. Each case ran once in a fresh container,
        `docker run --network none --cpus 2 --memory 1g --memory-swap 1g
        -e RAYON_NUM_THREADS=2 … /setup CASE 1 0 1`, with peak memory from
        `/sys/fs/cgroup/memory.peak`. Request on a used note: 135,503,872
        bytes (129 MiB) at peak, key load 2.02 s, proof 0.82 s, 3.0 s in
        all. Request on a new note: 135,860,224 bytes (130 MiB), 2.05 s,
        0.80 s, 3.0 s. Withdrawal: 173,101,056 bytes (165 MiB), 2.59 s,
        0.98 s, 3.7 s. Proofs are 256 bytes; the circuits have 30,821 and
        35,969 constraints. No memory event at 1 GiB (`memory.events`), so
        2 and 4 GiB were not tried. The companion reads the key from disk
        for every proof (`wallet_v2.rs:224`) and proves on two threads
        unless `RAYON_NUM_THREADS` says otherwise (`main.rs:671-687`), so
        each paid request costs about 3 s of two cores before any network
        time. Its memory at rest was not measured: on start it calls the
        service's `/health` (`service.rs:1089-1112`), a request this
        survey did not make.
      - Outside connections. The daemon sends every one through
        `relay.NewClient` and its dialer (`internal/relay/relay.go:28-76`).
        With `relay_url` empty, the default, it dials direct; with
        `socks5://127.0.0.1:9050` (`zkapi-clientd config --relay-url`) every
        one goes through SOCKS5 with the host name sent to Tor and no
        fallback (`socks5.go:13-98`). Its other clients reach only its own
        loopback listener (`client.go:115`, `withdraw.go:265`,
        `fund.go:232`, `payment_quote.go:58`, `main.go:425`). The companion
        has no SOCKS support built in (`reqwest` 0.12.28 without its
        `socks` feature, no `tokio-socks`; `cargo tree -e features -i
        reqwest`), and none of its clients sets or clears a proxy, so each
        takes `HTTPS_PROXY` and `ALL_PROXY` from its environment. The
        daemon starts it with all of them set to its own loopback CONNECT
        proxy, password-guarded, with `NO_PROXY` empty
        (`companion.go:109-127`); that proxy dials through the same SOCKS5
        path, port 443 only, and refuses loopback and local addresses
        (`connect.go:51-109`). With the daemon's bridge token set, the
        companion refuses to start on any other proxy or with a bypass
        (`crates/zkapi-cli/src/main.rs:886-898`). Under the daemon nothing
        goes direct. Started without those variables, the companion would
        connect direct, so Cloak starts it only through the daemon.
      - The hosts: `zkapi-mainnet.openanonymity.ai`, the service and its
        indexer (`/health`, leases, tree paths, quotes, attestation;
        companion `service.rs`, `indexer.rs:35,52,81`);
        `verifier-production-20260917.openanonymity.ai`, which the
        companion sends each temporary key and its signatures to
        (`/submit_key`, `service.rs:2011`); `ethereum-rpc.publicnode.com`,
        Ethereum RPC from the daemon (`address_funding.go:524-554`) and the
        companion (`oa_native.rs:111-114`, `oa_withdrawal.rs:300-330`);
        `org-live.openanonymity.ai`, the pinned models
        (`model_budget.go:40`); `openrouter.ai`, the model list and the
        inference itself with the temporary key, from the daemon
        (`model_budget.go:145`, `client.go:280-288`). The relay
        `oa-1.refraction.network` is used only when set as `relay_url`. The
        companion runs Foundry's `cast` only in subcommands the daemon
        never calls (`main.rs:1578-1846`).
      - Files, all in one folder (`--config-dir`, else
        `ZKAPI_CLIENTD_CONFIG_DIR`, else `~/.config/zkapi-clientd`;
        `config.go:84-97`), to keep across a restart: `config.json`,
        `management-token`; `funding/mainnet/address-funding.json`, the
        Ethereum key in hex with the signed transactions and quotes
        (`address_funding_store.go:16-83`);
        `funding/mainnet/pending-deposit.json`, a new note's secret before
        it is active (`funding.go:41-77`); and in
        `zkapi/mainnet/zkapi-native-eth-mainnet-note-bound-v1-fresh-20260930/`
        the companion's `deployment-manifest.json`, `note_state.json` (the
        note's secret and balance, `note_state.rs:20-36`),
        `pending_journal.json`, `oa-issued-leases/`,
        `prepared_withdrawal.json`, `oa-withdrawal.json`, `retired/` and
        `archive/`. The locks `daemon.lock` and `.wallet.lock` need not
        be. Losing
        `note_state.json` loses the deposit to the treasury after 30 days.
        The keys are only read and can sit in the image, in
        `share/zkapi-clientd/proof-setup` beside the binary
        (`companion.go:56-62`).
      - The sequence, none of it run; money moves where marked.
        `zkapi-clientd config --network mainnet --relay-url
        socks5://127.0.0.1:9050` writes
        `config.json` (at a terminal it goes on to guided funding);
        `serve` starts the daemon and the companion. `GET
        /admin/funding/address` makes the key and gives its address. An
        outside wallet sends ETH to it (money). `POST /admin/funding/quote`
        with an amount; `POST /admin/funding/approve` with the quote's ID
        signs and sends `deposit()` with the ETH to the vault (money, on
        chain), waits for the receipt and has the companion make the note
        active (`/funding/api/deposit/confirm`). A paid request is `POST
        /v1/chat/completions` to the daemon: the companion proves and
        reserves against the note (`/oa/v1/lease`, the service's `POST
        /v2/openrouter/leases`; money, from the note), has the verifier
        check the temporary key, the daemon sends the inference to
        OpenRouter with it, and `/wallet/settle` takes the final charge
        from the note (money). To withdraw, `POST /admin/withdrawal/quote`
        with a destination and the note's ID, then `POST
        /admin/withdrawal/approve`: it proves the withdrawal
        (`/oa/v1/withdraw/prepare`), signs and sends the vault's withdraw
        with gas from the key's address (money, on chain) and confirms
        (`/oa/v1/withdraw/confirm`). `POST /admin/return/quote` and
        `/admin/return/approve` send the ETH left at the address to a
        destination (money, on chain). Every `/admin/*` call carries the
        `X-OA-Management-Token` header (`fund.go:239`).
    - Run 17 November, outside Cloak, up to the key and no further, with
      no money moved (Sean's "2. a" for the key). `guest/zkapi/trial/`
      builds two images from the guest image's Debian base and snapshot:
      `tor` (Debian's tor 0.4.9.11) and `zkapi` (the two programs above,
      the four proving keys in `share/zkapi-clientd/proof-setup`, hashes
      matching the manifest), with scripts to create, start and stop them.
      The zkapi container is only on a Docker network made with
      `--internal`, which has no default route; tor is on it and on Docker's
      bridge, its SOCKS port at 172.31.250.2:9050 open only to that network,
      with `IsolateSOCKSAuth`. The daemon takes no SOCKS address but a
      numeric loopback one (`relay.go:60-65`), so socat in the container
      forwards 127.0.0.1:9050 to tor. The daemon's folder is
      `~/Library/Application Support/Regents Cloak zkAPI Trial`, owner-only.
      - Before any daemon command, from the zkapi container, on both
        starts: direct HTTPS to 1.1.1.1 failed at once ("Could not connect
        to server"), a lookup of check.torproject.org got no answer, and
        check.torproject.org/api/ip through 127.0.0.1:9050 answered
        `"IsTor":true`.
      - `config --network mainnet --relay-url socks5://127.0.0.1:9050`,
        without a terminal, saved `config.json`, started the daemon and
        the companion, and read the wallet's withdrawal and address state
        (`GET /admin/withdrawal`, `GET /admin/funding/address`), which made
        the key: `funding/mainnet/address-funding.json`, 425 bytes, mode
        0600. It then stopped at its first question, the deposit amount:
        "setup needs an interactive terminal".
      - `serve` passed every startup gate, then stopped 1 to 2 s in at its
        funding check, which ends the daemon when there is no deposit
        (`configured_runtime.go:97-99`). Its lines: "Starting local API
        service", "zkAPI client cda02d83 listening at
        http://127.0.0.1:8787/v1 (zkapi); SOCKS5 proxy required", "zkAPI
        network: mainnet", then "Stopping local API service". The gates:
        the deployment manifest and the proving keys' hashes, checked
        before the companion starts (`companion.go:70-103`); the companion's
        start; its `/health` call to the service, which it makes before it
        listens (`zkapi-cli/src/main.rs:790`) and which needs the service to
        advertise `direct_openrouter`; and the daemon's check of the
        companion's chain, mode, bridge version, deployment and circuit
        (`client.go:215-240`). With `serve` gone, the address request found
        nothing listening.
      - So the address came from `config` run again at a terminal nothing
        can type into (`docker exec -t`, no `-i`): it waits at the deposit
        amount question with the daemon and companion up. `GET
        /admin/funding/address`, with the management token and local API
        key passed on standard input, answered address
        `0x407B8fE5DB23Ceb64894e0dfDf2CF3be86498bDd`, chain 1, balance 0,
        phase `ready`. SIGTERM ended it ("Stopped. Your saved configuration
        and wallet state are preserved"). With both containers stopped and
        started again, `serve` stopped the same way and the same request
        gave the same answer, byte for byte. No deposit or note file was
        written.
      - Memory at rest, 70 s idle at that question: `docker stats` 19.6
        MiB for the zkapi container (daemon, companion and socat), its
        cgroup 27.0 MiB (27.9 MiB peak since it started); resident sizes
        18.1 MiB for the daemon and 17.4 MiB for the companion, which share
        pages. The tor container: 22.0 MiB.
      - The service: no error naming a client, no attestation step, no
        version refusal. Its one reply in these steps is the `/health` the
        companion required; Ethereum RPC (chain ID and balance) also
        answered through Tor. Whether it serves this client stays open:
        leases and the verifier's `/submit_key` come only with a paid
        request.
      - tor's log at notice level, with its default SafeLogging, names no
        hosts, so the hosts reached are not recorded.
      - Seen in passing: the daemon's default key reuse window is 60 s,
        and its own line says the provider can link requests sharing a
        key; `config --key-reuse-window-seconds 0` gives each its own.
    - The whole trip, 17 November, with real ETH (Sean's "1" for a $5
      deposit; he sent 0.008200750 ETH to the address). Same two
      containers, Tor the only way out. The daemon's questions were
      answered by `guest/zkapi/trial/drive.py`, which gives a command a
      terminal and answers a question only when a go file exists.
      - Deposit: `config --usd 5` quoted 0.002770807 ETH and a fee of at
        most 0.0013 ETH; confirmed once; "Deposit confirmed. Private
        inference balance activated." about three minutes later.
      - **The service serves this client.** `serve`, then one
        `/v1/chat/completions` to `anthropic/claude-haiku-5.5` (its cap $1
        a request): HTTP 200 in 21.1 s, answered by OpenRouter. The window
        closed 60 s later and settlement followed by itself: "key session
        1 ended (settled); cost: 0.000000003 ETH; balance remaining:
        0.002770804 ETH", 85 s after the answer.
      - A restart between settlement and withdrawal: `serve` ended with
        SIGINT; `config --menu`, withdraw, started its own daemon and
        companion and found the balance.
      - Withdrawal of the full balance to the address itself: preparing
        took about 15 s; it asks again whenever the fee ceiling rises, so
        one answer is not enough. Stopped with SIGINT while it waited at
        that second question and run again: it had kept the destination
        and sent nothing. Submitted, then about seven minutes to
        "Withdrawal complete: 0.002770804 ETH", fee 0.001116308 ETH.
      - Cost of the trip: 0.001979138 ETH, about $3.57, nearly all of it
        the two network fees (deposit 0.000862827, withdrawal
        0.001116308). The address now holds 0.006221612 ETH; where it goes
        is Sean's to say.
    - Two more trips at $2 each, 17 to 18 November, to try the edges
      (Sean's "1. do some $2 rounds"). Every interruption recovered and no
      step paid or deposited twice.
      - Trip one, key reuse off, clean stops (SIGINT, then both
        containers stopped and started). Stopped as "Deposit transaction
        saved; waiting to be mined" showed: run again with nothing allowed
        to answer, it said "Resuming your saved deposit; no new deposit
        will be created" and confirmed. A model whose cap is above the
        balance (`anthropic/claude-fable-5.2`, $4.50 against $2): HTTP 402
        `funding_required`, nothing charged. `serve` stopped the instant an
        answer came ("automatic settlement result ready=false"): after
        both containers restarted, `serve` said "A previous inference is
        settling; new requests will wait automatically" and settled it 35
        s later. **Two requests sent in that half minute both failed,
        HTTP 502 `anonymous_access_failed`, after 34 and 42 s; they did
        not wait.** Nothing was charged for them. Containers stopped as
        "Withdrawal submitted" showed: run again, it finished the saved
        withdrawal without asking.
      - **With a key for every request, requests go one at a time.** Each
        new key waits for the last one's settlement ("request waiting
        reason=previous_key_settlement"), about 23 s of proof and
        settlement each: of two sent together, one took 23.7 s and the
        other 77.7 s. A lone request takes 23 to 25 s.
      - Trip two, the default 60 s key reuse, crashes (SIGKILL to the
        daemon and companion together). Killed as the deposit transaction
        was saved: run again, the deposit was found confirmed. Two
        requests together shared one key (22.9 and 26.1 s); a third inside
        the window took **3.9 s**. Killed with that key open and
        unsettled, then withdrawal at once: "Waiting for your previous
        inference to settle", then the quote, 0.001106562 ETH, the three
        requests having cost 0.000000007. Killed as "Withdrawal submitted"
        showed: run again, it finished without asking.
      - Cost: trip one 0.002054537 ETH (about $3.71), trip two 0.001544572
        (about $2.79), fees again nearly all of it. The address holds
        0.002622503 ETH, about $4.74: not enough for another trip.
      - What this means for Cloak: the choice between a key per request
        (unlinked, about 25 s each and strictly one at a time) and a
        shared window (fast, and the provider can link what shares a key)
        is the post's "payment that does not link chats" question in
        practice; an agent's task makes many model calls. And a request
        made while an earlier one is still settling after a restart can
        fail rather than wait, so Cloak must hold requests until the
        daemon reports the settlement done.
      - Sean's rulings, 18 November: a key for every request is the rule
        the protected mode is built around, at its cost in speed; the
        0.002622503 ETH stays at the trial address for later fees.
      - Still not tried: a kill in the middle of an answer being streamed;
        a second deposit while one is open; the 30-day expiry; the
        operator's pause.
- Details while writing (15 November, decision 13). While a message or a
  task is written in Chat, the one worker reads the draft and proposes up
  to four details it leaves open; what the owner picks is added to the
  message as lines.
  - The worker takes one more request: the daemon's keys, with the user
    message `{"draft":"..."}`, decoded under Cloak's own grammar,
    [details-reply.gbnf](../reference/details-reply.gbnf), which is part of
    no pin (`models.json` is unchanged). It allows `{"details":[...]}` with
    at most four, each `options` (two to six, and whether several can be
    picked), `range` (low, high, unit), `colors` (three to six, named, in
    hex) or `pad` (two pairs of opposite words), with every string bounded
    and no white space. The rewrite path is unchanged: three of the
    daemon's rewrite requests gave the same replies (text, finish, token
    counts) from the new worker and from one built from `88a5754`, the
    commit before.
  - In the app, `CloakSupervisor/Details.swift` holds Cloak's instruction,
    the request, a strict reading of the reply and
    `Supervisor.details(for:)`; `CloakSupervisor/DetailPicks.swift` what is
    picked and the message it makes; `RegentsCloak/DetailsRow.swift` the
    pills and pickers. A details request has 30 s and 1,024 tokens, is
    never sent over the 10,000-character limit, and gives way: the relay
    stops it when any later request arrives, a rewording, the door's or a
    guest connection (section 3 of
    [state-machines.md](state-machines.md)).
  - Chat asks once the draft has rested 1.2 s, has four words or more,
    Cloak runs and nothing is being reworded. A changed draft cancels the
    request and starts over; the first pick fixes the details until the
    message is submitted or emptied; showing another conversation clears
    them; a failed or empty answer shows nothing.
  - Checks: `swift test --package-path app`, 107 (16 new: the reader on all
    four kinds and 30 replies it refuses, the message from picks, the first
    pick, the four-word rule, the request's shape, the limit, a cancel, the
    deadline, and giving way, both ways, through a real relay to
    `tests/fake_worker.py`). The real small lead
    (`small-lead-gguf-grammar`), through the freshly built worker, on 12
    drafts: 2.5 to 3.8 s for a short draft with details, under 0.6 s for
    none, 6.6 s for a draft of 9,896 characters (2,889 prompt tokens), with
    the Mac's load average about 5; at about 20, 3.0 to 5.6 s, under 1 s and
    8.1 s, with the same details. Every reply passed the app's reader.
    "What is the capital of France?", the Safari login bug, ounces in a cup
    and a text to a partner got none;
    English, Spanish and Japanese drafts got details in their own language.
    A cancel 1 s in was answered 499 within 0.02 s, and the next request
    answered as usual.
  - Seen in the running app on 15 November (build `28923f1`, dark): four
    pills for "Plan a week in Japan with my kids" a few seconds after the
    draft rested, and the Pace pill's pad opening above it.
  - Not proven: a pick made in the running app and its line in the message
    sent; the other pickers, light, keyboard and VoiceOver; giving way to a real rewording in the app; the
    instruction beyond these 12 drafts. Known: greedy decoding still asks
    some things a draft settles (how many days, of "a week in Japan"), a
    label the model wants in three words can come out as two run together,
    and an odd detail slips in (a budget for a cover letter); a bedtime
    story of ten minutes got none.
- Answers drawn (15 November). An answer's Markdown, a chat's or an agent
  task's, is drawn rather than shown as written: headings (`####` and
  deeper drawn as `###`), bold, italic, struck and code words, fenced code
  (monospaced, scrolling sideways, its language dropped), bullet and
  numbered lists with one level of nesting (deeper items join that level),
  quotes, rules and pipe tables as a plain grid. A link shows its words,
  then its address in the secondary colour, and does not open, since a
  click would open the browser outside Tor; an image is never loaded, its
  words and address shown; HTML shows as written. A line the splitter
  does not understand belongs to a paragraph, so every answer draws. The
  answer as saved and sent, and Original and Reworded, are unchanged.
  - `CloakChat/Markdown.swift` splits the text into blocks line by line
    (not CommonMark); `RegentsCloak/AnswerText.swift` reads each block's
    spans with Foundation's `AttributedString(markdown:)`, inline only,
    once per answer text, and draws them. The answer is as tall as its
    text, where the box it replaces scrolled inside itself past 320
    points; text is selected a block at a time.
  - Checks: `swift test --package-path app`, 137 (30 new, on the
    splitter's blocks). Off-screen renders of every element in the
    chat's scroll view, light and dark, at two widths. A 21,000-character
    answer of 270 blocks, with the Mac's load about 30: split 1.4 ms and
    spans 11 ms, once; first layout 120 to 150 ms, against 20 to 40 ms for
    the box it replaces; laid out again at another width 16 to 19 ms,
    against 39 to 41 ms.
  - Not proven: the running app; VoiceOver (the headings, lists, code,
    quotes and tables are marked for it); the scroll wheel over a code
    block passing up and down to the chat.
- The app is named "Cloak" on the Mac (Sean, 20 November 2026). In code
  and committed; not yet built into an app or seen. See CHANGELOG.md.
  - Not proven: that the Dock shows the minimized label; that the app
    menu reads About, Hide and Quit Cloak; `tell application "Cloak"`;
    telling the Settings window from the others at run time;
    `app/release.sh` under its new names. The renamed app may raise the
    Mac's keychain question once; only Sean can answer it.
  - To do first: rebuild Sean's copy as `app/build/Cloak.app` when the
    Mac rests and Cloak is idle, restore Running, check the two labels.
- Local Llama's model list (decision 21): the design, not built.
  - The chosen answer model runs in a second process of the same worker
    binary, through the relay Local Llama already uses while paused. No
    change to frames, the host package, the guest or entitlements.
  - `reference/models.json`: an entry that can answer gains `"answers":
    {"label", "memory_gib", "context_tokens"}`; today's model gets one;
    a new model is a `-base` entry plus a GGUF entry with `only`,
    `vendor_files`, `chat_template_context`, `answers` and no `grammar`.
    `scripts/pin_models.py` keeps `"answers"`.
  - `ModelPin`: `grammar` optional, `answers` added, a pin needs
    `chat_template_context` and one of the two. The worker checks the
    grammar only when the pin has one, takes its context from the pin
    (`Worker.chatContext` goes), and refuses a pin without `answers`.
  - `app/release.json` and `app/manifest.py`: `model_label` and
    `model_memory_gib` go; the manifest carries `model` and
    `answer_models` (every entry with `answers`, smallest first); the
    build fails if `model` is not among them.
  - App: `Manifest.answerCheck(_:hardware:)` (the rewording model:
    today's check; any other: both models' memory counted). "Best for
    this Mac" is the last in the list that fits. One `ModelDownload` per
    answer model, with `remove()`. `Supervisor.answer(_:with:)` uses the
    run's relay only when Running and the model is the rewording one,
    else its own local relay for that model. `AppSettings.answerModel`
    (nil means the rewording model). A new Settings pane, "Local Llama":
    one row per model with its size, a "Best for this Mac" caption, rows
    that don't fit dimmed with a tooltip, download and remove symbols.
  - No fallback: a chosen model that is missing or changed stops the
    chat ("Choose a model in Settings." / "This Mac can't run the chosen
    model." / "Download the model to ask.").
  - Still mine to settle: both models in memory, or unload the rewording
    one (with both, 24 GB leaves about 10 GiB for an answer model, 32
    leaves 18, 64 leaves 50); measuring the large model's memory on a
    48 GB Mac with about 41 GB of disk free; the wait to load 20 to 40
    GB after each rest; single-file GGUF only; thinking text in answers;
    one download at a time; whether picking a model blocks the chat
    until it arrives; recording which model answered a turn; Restore
    Defaults.
  - Words to change with it: AGENTS.md's one-model rule, README.md's
    model passages, decision A25, `docs/state-machines.md` 9a and 9c.
  - The list is proposed, not chosen: a helper's report of 20 November
    is kept as [local-models-research.md](local-models-research.md),
    with each file's revision, size and checksum. I have not checked
    its numbers yet. It proposes: today's Qwen3.5-9B for every Mac and
    alone up to 24 GB; gemma-4-26B-A4B (Unsloth UD-Q3_K_M, 11.85 GiB)
    from 32 GB; Qwen3.6-35B-A3B (Unsloth UD-Q5_K_M, 24.64 GiB) from
    48 GB. Inkling 2 Mini cannot be loaded by the pinned llama.cpp
    (b12556) nor by any released one; support is in two unmerged
    llama.cpp changes, #32694 and #32695.
  - Two findings change the design above. macOS's limit on graphics
    memory leaves less than the fit table says (about 8.2, 13.3, 27.2
    and 39 GiB at 24, 32, 48 and 64 GB), and it is not known whether
    the limit counts both worker processes together. whichllm's speeds
    read about twice what Cloak measured for today's model (69 against
    36.5 words a second on an M4 Max), so each model is measured on a
    real Mac before it is listed.
- zkAPI steps 6 and 9, the design (Sean, 20 November 2026, of steps 4
  to 9: "all of this work needs to be done asap"). Kept as
  [zkapi-mac-side.md](zkapi-mac-side.md): the payer's states, the three
  new frames (`C` for an allowlisted money call, `V` for the wallet and
  one-block chain read, `H` for "held"), the one queue with the owner's
  message first, the sheet, who signs, and the cutover's deletion list.
  - The chief's choices on its section 7: the app switches at step 6,
    in place, and no release is published until step 8 passes (hard
    cutover; no second path beside it). A new key for every request
    stays (Sean, 18 November); looked at again after step 7 measures a
    real task. The third light goes at cutover; the pill's help says
    each request is paid with a new key. Withdraw and Deposit each open
    a review of amount, fee and destination, and its button signs. The
    expiry warning starts 10 days ahead.
  - Sean's answers the same day (decisions 23 and 24): a withdrawal
    goes back to Cloak's own funding address, with Send Out… to move it
    on; and the Tempo wallet is not deleted. So the design's section 5
    (the deletion list) no longer holds for the sender, its host half
    or the Tempo wallet parts, and its items 10 to 13 add the payer
    beside today's wallet, each for its own mode, never one in place of
    the other inside a mode.
  - Checked against source by the chief: `claimExpired` has no pause
    guard while `deposit` and `mutualClose` do, so a deposit that
    expires during a pause can be taken while its owner cannot
    withdraw; the daemon's default key window is 60 s and `cloak-pay`
    sets 0.
- Where this stopped, 20 November 2026 (Sean: "please reach a stopping
  point"): Sean's running copy is 0.5.4 built that afternoon, with the
  symbols, V, the Agent switch and the toolbar Cover, still named
  "Regents Cloak". Next, in order: the rebuild above; pictures of the
  views not yet seen and a VoiceOver pass; the model list; then a
  release to testers. Earlier releases need no care: no one is testing
  yet (Sean, the same day).

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
   departs from HW01; the spec's section 1 stays as received. The memory
   pass line is 10 GiB for the whole running product: the worker, the
   guest's virtual machine and the host together, as the stage 3 record's
   whole-product peak (since 13 November that peak also counts tor and
   every worker alive at a sample). 9.3 GiB is the working aim. The lead's two runs peaked at 21.04
   and 18.74 GiB, before tor was sampled.
   Exactly one model still ships (A25 unchanged): the selection rule picks
   one of the four or none. Each small candidate faces stage 4 from scratch;
   nothing measured on the lead or the challenger counts for it. To settle
   before any holdout opens: the protocol's confidence split assumes
   two candidates ("Two candidates are compared with the reference, so each
   bound is at 97.5 % (Bonferroni)"); with four it has to be re-declared.
   Until then the protocol and the stage 4 kit's statistics stay as written,
   and the protocol stays a draft until Sean freezes it.
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
   only, as decision 2 departs from HW01. A GGUF quantization and an MLX
   4-bit conversion are different artifacts, so each is its own candidate
   and faces stage 4 on its own: `small-lead-gguf` (Unsloth's Q4_K_M of `Qwen/Qwen3.5-9B`) and
   `small-challenger-gguf` (Google's own Q4_0 GGUF of Gemma 4 12B, from its
   quantization-aware-trained checkpoint, not the instruct weights its MLX
   twin came from; [models.md](../reference/models.md)). Nothing measured
   on an MLX twin counts for its GGUF one. llama.cpp is pinned in
   [sources.json](../reference/sources.json) and built from that source:
   at release v1.0.0 (commit `b1b770d9`) until 19 November 2026, when
   Sean asked for the latest, and at build b12556 (commit `50518b64`)
   since; the stage 3 and stage 4 records were measured on v1.0.0. Every
   llama.cpp setting that could change a result or the memory a rewrite
   takes is set in the worker
   (`llama-worker/Sources/CLlama/cloak_llama.cpp`). The confidence split
   decision 7 leaves to re-declare now covers six candidates, not four.
   The engine is chosen (14 November, the chief): llama.cpp with the reply
   grammar. The MLX worker and the other candidates were deleted on
   14 November 2026; their records stay as history. The spec's decision
   summary and stage 2 have named the llama.cpp worker since then.
9. The reply grammar, as candidates of their own. Decided 14 November (the
   chief). Grammar-constrained decoding is tested as explicit pinned
   candidates on llama.cpp, as spec DATA04 allows, because both engines'
   small-model failures are slips in closing the JSON (stage 3 above). The
   grammar, [rewrite-reply.gbnf](../reference/rewrite-reply.gbnf), allows
   the replies the daemon's check accepts: `{"texts":[...]}` with as many
   texts as the request, JSON white space of at most 16 characters between
   two tokens (14 November, against a runaway), and any text the daemon
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
10. Sending, in a Development mode. The owner's product decisions, dated
    14 November 2026 (Sean, through the chief). Send in the Chat window
    becomes real in a clearly labelled Development mode that is never part
    of a public release: the approved reworded text goes through Tor to a
    remote model at Boundless, paid from one wallet through the Machine
    Payments Protocol (MPP) on Tempo, and the answer comes back into the
    conversation. Cloak makes one wallet on the Mac and the owner funds it;
    there is no spending cap, the balance is the limit. The default remote
    model is a cheap open model, and it can be changed. The person sees
    Original and Reworded and presses Send on the reworded text. Three
    lights, Reworded, Routed and Unlinked: nothing is sent unless Reworded
    and Routed are good, and in Development mode Unlinked is not good,
    because one wallet pays for every chat and so links them all, which the
    screen says in plain words. This is not the spec's payment (the
    daemon's own, not built) and gives up conversation isolation (A07)
    while it is used; it departs from the spec by the owner's ruling, for
    development only, as decision 2 departs from HW01.
    - Read with the release plan, 19 November (the chief's reading, told
      to Sean the same day): the technical preview for invited testers
      ([release.md](release.md), stage 1: "The payment is wallet-linked
      and says so. No claim about privacy.") carries Development mode,
      labelled as it is here. "Public release" above is stage 2's, which
      never has it: the cutover deletes it.
11. Send Original, in Chat. Decided 14 November 2026 (Sean: "There should
    be a checkbox that says 'Send Original', and it does that without any
    rewords"). A checkbox under Chat's message box sends that message as
    written, with no rewording, still through Tor and from the one wallet;
    its card shows the Original alone and its Reworded light is not good.
    It is the owner's choice for each message, in Chat only, and off at
    each launch. It is never a fallback: a rewording that fails still sends
    nothing, and the original never goes in its place. The door for the
    owner's other apps (Agents) is unchanged and rewords every user message.
    This is the one exception to decision 10's "nothing is sent unless
    Reworded and Routed are good".
    - Changed, 19 November 2026 (Sean: "it should be in the message review
      area, a button that says 'Send Original Text', and a checkmark people
      can set that says 'Never reword text. Reduces your privacy.'"). The
      tick under the message box is gone, with no second way to it. Where
      a reworded text waits for Send, a second button, Send Original Text,
      sends that message as written instead: the turn keeps no reworded
      text, so it shows, and is sent again later, as a message sent as
      written. Send stays the prominent button; Send Original Text is off
      only where sending is certain to stop, with the same words as Send.
      Under them, a checkbox, "Never reword text. Reduces your privacy.",
      also in Settings, General, under the same words. It is a setting
      kept in the app's defaults: off until ticked, kept across launches,
      turned off by Restore Defaults, and set from nowhere else. Ticked, a
      message written in Chat is sent as written at once on Send, with no
      rewording and no review, and the model on this Mac is not asked to
      reword it; while it stays ticked, the line "Rewording is off.
      Messages go as you wrote them." sits under the message box. With the
      box ticked Cloak departs from the post's "all prompts are locally
      rewritten", for Chat's own messages only: the agent's tasks and what
      other apps send through the door are always reworded. A rewording
      that fails still sends nothing in its place.
12. The agent runs in the guest. Decided 14 November 2026 (Sean, "1. a and
    then b", choosing it first of the three parts of the post Cloak lacked;
    the design is the chief's). The post: "My agent harness is wrapped with
    a bwrap sandbox (also experimenting with MicroVM) and wrapped again
    with torsocks, so everything it does goes through Tor." The owner's
    task runs as Pi in the guest, inside the reference sandbox, so its
    tools go out only through the Tor port; its model requests come to the
    door on the Mac like any app's, reworded there and sent from the one
    wallet (Development mode, decision 10). Each agent conversation has a
    pass of its own, in memory only, accepted only from the guest and
    dropped when the door closes, and a folder and Pi session of its own in
    the guest, which last until the guest ends. Tool results go to the
    provider as written, as the pinned daemon sends them; only the owner's
    own messages are reworded. Not the spec's session (the daemon's payment
    is not built): it departs as decision 10 does, for development only.
13. Details while writing, like Feedforward. Sean asked for it on 15 November
    2026 with a video of it; the chief set the shape. While the owner writes in Chat, a chat's message or an
    agent's task, the one model on the Mac proposes up to four details the
    draft leaves open, as pills above the message box. What is picked is
    added to the message after a blank line, one `Label: value` line each;
    a detail left alone adds nothing. The draft goes only to the model on
    this Mac: nothing leaves it, nothing is paid, and neither the draft,
    the details nor the picks are logged. The worker takes this one request
    besides the daemon's, decoded under Cloak's own grammar
    ([details-reply.gbnf](../reference/details-reply.gbnf)), which is part
    of no pin. A details request never holds up a rewrite: any later
    request to the worker stops it. It is no rewrite stage and leaves the
    daemon's request, instruction, grammar and checks as they are.
14. Borrow from Llama.app, do not fork it. Decided 18 November 2026 (Sean,
    "1. a", after asking for a list of what Cloak could take from
    [ggml-org/Llama-macOS](https://github.com/ggml-org/Llama-macOS) and
    offering to fork it). Cloak keeps its own base. Ideas, and small
    pieces under its MIT licence with their notice, are taken one at a
    time: memory first, then the model download, then the menu. Not
    taken: its crash reporting to an outside service, update checks and
    model downloads that go straight to the internet unsaid, installing
    whatever engine is newest, and an agent that runs on the Mac itself.
    - Taken, 18 November: the model leaves memory when idle. The relay
      rests its worker once nothing has been asked of it for the time
      chosen as Free memory in the Details window (5 minutes until
      chosen; 15 minutes, 1 hour or Never), and the next request starts
      a new worker, as the first was started, and waits for it, about
      4 s on the 9B. Two workers never hold the model at once; a worker
      that ends by itself, or cannot start again, is the failure it was,
      and nothing is tried again
      ([state-machines.md](state-machines.md), sections 3 and 9). Seen
      in the running app (build `365a363`, 18 November): five minutes
      after the startup check the worker's process was gone, Cloak
      stayed Running and its detail said the worker was resting. The
      wake was covered by the relay's tests until they were deleted on
      19 November (decision 15), and has not been seen in the running
      app; the supervisor's part was never covered by a test, since a
      test cannot reach Running.
    - Taken, 18 November: the Mac check and a Memory figure. The check
      passes a Mac whose graphics limit, as Metal gives it, holds the
      model (7 GiB stated in `app/release.json`) with 1 GiB spare, and
      whose memory holds all of Cloak (10 GiB stated) with 4 GiB kept
      for macOS; a limit that cannot be read fails. Both stated figures
      are still to be measured again. The Details window has a Memory
      row: the footprint of the app, tor, the worker and the guest's
      virtual machine together, read every 3 s while the window shows,
      and no figure when a part cannot be read. The virtual machine's
      process is found through a macOS function that is not public
      (`responsibility_get_pid_responsible_for_pid`), as `scripts/boot.py`
      does. Not yet seen on screen.
    - Taken, 18 November: the model download, in the app (release plan
      item 7). When the model's files are missing, the Details window,
      the menu and Chat offer the download; nothing is fetched until
      the button is pressed, and the words beside it say the size, the
      host, and that the host sees this Mac's address, unlike Cloak's
      messages. Each pinned file streams into a `.part` file with a
      running sha256 and is renamed into place only when size and hash
      match its pin; a mismatch is deleted and said. A partial file is
      hashed again and continued by Range; a lost network waits and
      goes on by itself; other failures try again after 2, 4 and 8 s
      and then wait for Continue. Download is off only when the Mac
      fails its check or the disk lacks what is left plus 1 GiB. The
      worker still checks every pin at load
      ([state-machines.md](state-machines.md), section 9a). The request
      names a generic client, not the app. Not run: a whole real
      download, a real sleep and wake; not yet seen on screen. Left: a
      file of the right size and wrong hash still has to be removed by
      hand.
    - Taken, 18 November: the menu and windows. The menu is a standard
      menu-bar item with a header (the name, one small dot for the
      state, and a line of plain words under it), a failure shown in
      that line's place with its remedy and the one button that acts on
      it, and the release and build at the foot. Every reason has a
      hedged likely cause and one thing to do. A Welcome window shows
      once, starts nothing, and says what Cloak does and that
      Development mode pays from one wallet. The wallet sheet shows a
      QR code of the address beside Copy; nothing about the wallet
      itself changed. Not yet seen on screen.
    - Taken, 18 November: settings. A Settings window (Command-comma)
      with General (Launch at login, Free memory), Shortcut, Door (the
      port, 1024 to 65535, checked free on 127.0.0.1 when saved,
      applied at the next Start; loopback only, with no setting for
      any other address) and Advanced (the commands tor and the worker
      were started with, this session's log, Restore Defaults). No
      setting can be set from a link, the door, AppleScript or the
      guest. A quick prompt: a system-wide shortcut, none until chosen,
      opens a small box whose text becomes a new chat's draft; it sends
      nothing. Six AppleScript commands: start, pause, and show chat,
      agents, details and settings. The header says Starting and
      Stopping; a changed model has Show in Finder. Found and fixed:
      three log lines wrote a stopped send's detail, the payment
      toolkit's own words, which can hold amounts, as readable text;
      it is now kept out of the readable log. Not yet seen on screen.
    - Not taken, and why: a choice of context size, an overrides file
      and a model folder choice (one model and one configuration ship);
      sharing over a network (the door stays on this Mac); updates and
      a Homebrew install (they need a signing key and a public release,
      which are Sean's).
    - Already here, and not widened yet: the door (Agents, 14 November)
      gives other apps on the Mac an address in OpenAI's shape, each with
      a pass of its own. Sean's answer of 19 November: first confirm
      Cloak works as expected, then connect more local AI apps to it. The
      chief's question to him that day wrongly said only Cloak's own
      windows could use it.
    - Trace Commons (the "Near AI Gateway" Mac app,
      github.com/TraceCommons/trace-commons), read on 19 November at
      Sean's request. His answers that day: (1) NEAR AI Cloud's enclave
      models become a second, named mode after zkAPI is in the guest:
      NEAR-hosted open models only, the hardware proof checked before
      anything is sent, never a fallback; account and credit are his.
      (2) Five small things are taken as work passes them: a state shown
      as working only when proven; no Sparkle when Homebrew installed the
      app; a keychain item by team group, so no prompt after each update;
      a release script that refuses a half-built app; a quit that waits
      for a confirmed stop. Not taken: trace collection or upload, its
      local proxy and fallback ladder, a proof label shown after the
      reply, pins fetched unsigned.
    - Agents shows activity, 19 November, at Sean's word ("show what
      local apps are putting in", with two pictures of a proxy app's
      counts and live requests): each chat request's sender, model, stage
      and time, in memory only, never its text. Seen on screen empty.
    - NEAR is built now, not after zkAPI is in the guest (Sean, 19
      November: "keep implementing the 'NEAR AI Gateway' tab / or mode of
      using it"). Through Tor with no account that day: NEAR's own list
      (`/v1/model/list`) marks 17 of 63 models verifiable, 12 of them on
      its own servers (`providerType` `vllm`), the rest of the 17 on
      Chutes, Tinfoil or outside; one model's report
      (`/v1/attestation/report?model=Qwen%2FQwen3.8-27B&signing_algo=ed25519&nonce=`)
      answered 200 with the gateway's and the model's Intel quotes, an
      NVIDIA payload, event logs, and a signed key configuration for
      oblivious HTTP each. The earlier 400 was a model name NEAR does not
      have. Nothing verified yet.
    - NEAR's proof checker, 19 November (`guest/near`, with its README).
      Choices, the chief's: the accepted measurements ship with Cloak
      (`reference/near-pins.json`, taken from that day's live reports;
      NEAR publishes no signed list), so a new NEAR image stops the mode
      until the pins are renewed; a fresh report before every message;
      Intel's verdict `UpToDate` only, with three platform flags every
      NEAR server shows accepted (sockets can be added, keys cached by
      Intel's registration service, SMT on); the model's pins are one
      list, since one machine served two models and one model ran on
      three measured setups; a report of up to 4 MiB. Sean's: requests
      use the owner's own NEAR key. Live through Tor: both models passed
      every check, a report in 3 to 13 seconds, Intel's collateral in 8
      to 16, no refusals for rate. Next: the request itself, encrypted to
      the checked key (built the same day, `ask`; proven with a
      stand-in and NEAR's vectors, and live as far as NEAR's 401 to an
      invalid key; then, with his key the same evening, real replies
      from both models opened, 24 to 32 seconds a request with the
      proof. NEAR's own SDK sends
      version 3 of the encryption, which also ties the reply key into
      the request; Cloak sends version 2, the documented one, and moves
      to 3 outright once a live test shows it works); then the GPU check through NVIDIA's
      service (built the same day and required by `ask`; NVIDIA refused 7
      of 8 Tor circuits with 403, so the mode waits on another way to
      the GPU's verdict: Intel's token service behind NEAR's front
      server replaced it the same night: tied to our own nonce by
      checks Cloak makes, but covering one server NEAR picks, not tied
      to a server whose quote Cloak checked, and said so in the crate's
      README)
      service; then, 19 and 20 November: a passed proof kept for a chosen
      time, an hour at most; a new Tor circuit, three at most, when one
      cannot connect; a direct route, since Sean decided NEAR mode need
      not use Tor ("it can be optionable only if it works, even if it is
      very slow"); and a model server pinned by its compose file without
      its own label, after NEAR added a server whose compose differed
      from a pinned one only there and in its telemetry address. Live
      with his key, three "ping"s on one check to each model: direct, six
      of six answered, 3 to 14 seconds each; through Tor, six of six, 43
      and 49 seconds for the first of each (the check is 20 to 40 of
      it), 3 to 31 after. The servers NEAR shows changed within a day,
      so the shipped pins will need updating often; that is the open
      problem. Sean's answer, 20 November: the pins stay inside the app,
      NEAR mode stops with "Proof refused" until the change is read and
      an update ships, and the count comes back to him if it is often.
      The count so far: two changes on the evening of 19 November
      (about 00:45 and 02:07 UTC on the 20th), each one server moved to
      a compose already accepted but for its label, each read and
      pinned within minutes. Then the app, the same evening: NEAR is a
      third kind of conversation beside Cloak's and the agent's, the
      helper is built into the bundle and pinned in the manifest, the
      key is typed in Settings and kept in the keychain, Tor is a
      switch that is off until turned on and needs Cloak running, and
      the check's result is on screen before a message is written. On
      screen in the installed app with no key saved: the mark, Limits,
      the check passing direct, and Send off with "Add your NEAR key in
      Settings." Not yet shown: a message sent from the app, which
      waits for Sean to type his key there. From NEAR's own words,
      to be said on screen: the model's software is not in the
      measurement, a key ties every request to one account, and on 8
      November a flaw on one server exposed requests in progress.
    - NEAR without an account, through real Tor, 19 November: the model
      list (63 models) and the attestation report both answered 200 to a
      Tor visitor with no key. The report holds the gateway's Intel
      quote, event log, report data and request nonce, and a key
      configuration for oblivious HTTP with its own signature, so a check
      before sending and a request sealed to the enclave look possible.
      Not done: verifying the quote, asking for one model's report (the
      form tried was refused, 400), sign-up, payment, or any request.
    - Seen in the running app, build `7cdc1d2`, 18 November: the menu
      (header, dot, footer), the Details window and the Settings
      window's General pane. Measured there just after the startup
      check: 7.16 GB in all (the worker 6.23 GB, the guest's virtual
      machine 606 MB, the app 311 MB, tor 26 MB), against the stated
      7 GiB for the model and 10 GiB for all of Cloak; one reading, not
      the table release plan item 8 asks for. Not seen: the Welcome,
      the quick prompt, the QR code, a download, the Shortcut, Door and
      Advanced panes, a failure in the menu.
    - Signed updates, prepared 18 November (Sean first ruled they wait
      for stage 2, then the same day: "prepare the mac app signed
      updates now"). Sparkle 2.8.1, as Llama.app has it, is in the app
      and its bundle. `app/release.json` has an update feed and a
      public update key, both empty; with them empty the app has no
      updater and no update item. With both set: Check for Updates in
      the menu, an Updates switch in Settings that starts off, a check
      straight from this Mac under a generic client name, an update
      taken only with a valid signature and only when the person
      presses Install (the offer to install by itself is turned off),
      and the app opens Paused after it. No key was made and nothing
      was signed, notarized or published: those are Sean's
      ([release.md](release.md), item 7). Not run: a real feed, a real
      update. Changed 19 November: Sean's answers for the friends' build
      turn updates on, so the feed and the key are set and every build
      has the updater; the app's allowance for a build with none is
      removed.
    - Found on the way and left: the door's tests pick a free port, let
      it go and open the door on it, so another program sometimes takes
      it first and a run fails.
15. Gate checks only. Decided 19 November 2026. Sean: "Delete all tests
    from all repos, the code works now and it will work in the future. The
    tests were built by poor models, and we do not need that much." For
    Cloak he chose to delete the ordinary unit checks and keep the checks
    behind the gates ([release.md](release.md), "Gates for stage 2"). No
    ordinary unit checks are written from now on.
    - Deleted: in `app/Tests/CloakTests/`, the agent task, agent card,
      control socket, details, Markdown, memory budget, menu bar icon, menu
      header, model download, phase, QR code, relay rest, app rewrite,
      settings, supervisor, startup check and sealed conversation checks;
      in `tests/`, `test_fetch_model.py`, `test_stage3.py`,
      `test_stage4.py` and `test_worker_stop.py`, with
      `fake_stuck_worker.py`, the stand-in only the last used. With them
      went what only they used: the test target's reach into the app, the
      openings that let a check give the control channel its own socket,
      lock and user, and the model download its own folder, hardware,
      network watch, free-space reading and retry waits.
    - Kept then, by the gate each backs: the escape, Tor, agent, task,
      guest, worker, cover and payment checks in `tests/`,
      `guest/pay/check.sh`, the sender's Rust checks, and the app's door,
      stopped-rewording, send and wallet checks.
    - Cut again the same day. Sean: "I want to delete many tests, the pace
      of development is too slow", and he chose to keep only what guards
      money, break-outs and proof before sending. Deleted:
      `tests/test_llama_worker.py`, `tests/test_guest_path.py`,
      `tests/test_agent_path.py`, `tests/test_task_path.py`,
      `tests/test_cover_path.py`, the two Go helpers only they used
      (`tests/daemon_reply`, `tests/daemon_transcript`), and the app's
      `DoorTests`, `DoorGuestTests`, `StoppedRewriteTests` and their
      `Fixture.swift`. Earlier mentions of these files in this document
      are history.
    - Kept now: `tests/test_escape_path.py` and `tests/test_tor_path.py`
      (break-outs); `tests/test_pay_path.py`, `guest/pay/check.sh`, the
      sender's Rust checks, and the app's `SendTests` and
      `WalletPresenceTests` (money); `guest/near`'s checks (proof before
      sending). New checks are written only for those three things.
    - No longer checked by anything since this second cut: the worker's
      channel, cancel, model pins, sandbox and replies under the grammar;
      the rewrite path through the guest and its input limit and
      deadline; Pi's tasks through the daemon; cover traffic; the app's
      door, its passes for each app and conversation, and that a
      rewording which stops sends nothing.
    - What the deleted checks checked is no longer checked by anything: the
      app's phases and its supervisor with stand-in tor and worker, the
      relay's rest and wake, a details request giving way, the control
      socket and its JSON, the menu header and icon, settings, the QR code,
      the app's model download, the app's rewrite request and reply rules
      against the daemon's code, the sealed conversations, the agent's
      tasks and cards, the startup check, the stage 3 and stage 4 kits'
      own logic, `scripts/fetch_model.py`'s resume, and a lost worker that
      ignores being stopped. The stage 3 measurement kit
      (`scripts/stage3.py`) is unchanged.
16. Every build on this Mac is signed with the Developer ID. Decided
    20 November 2026 (Sean, "8. a"). macOS keeps the worker's sandbox
    folder for the one team that signs it: after the first Developer ID
    build ran here (19 November), an ad hoc worker would have had macOS
    ask Sean again, as "(null)", whether to open it. So
    `llama-worker/install.sh` and `app/build.sh` sign with the identity
    that `app/release.json` names, under the hardened runtime and with a
    secure timestamp, and take no other; the ad hoc branch is deleted.
    Only `app/release.sh` sends a build to Apple, and only
    `app/publish.sh` puts one where others can get it. A build needs the
    network, for Apple's timestamp, and the key in the login keychain.
    Tried the same day: the worker and the app rebuilt and signed so, and
    `cloak verify` passed with no question from macOS.
17. Llama Normal, and the modes' names. Decided 20 November 2026 (Sean,
    "5. a - make sure the UI can slide the modes between 'Anon V' 'NEAR
    Privacy' and 'Llama Normal'"; 5a was a chat type that is near-pure
    llama.cpp). A new chat's mode is picked on one segmented control:
    Anon V (Cloak's own chat: reworded, through Tor), NEAR Privacy, Llama
    Normal, Agent. The chief's readings, told to Sean the same day: Agent
    stays as the fourth position, since it is a kind of conversation and
    had nowhere else to start; a chat keeps the mode of its first message,
    since changing it would send what was said to the model on the Mac
    out to a remote one.
    - A Llama Normal message goes as written, with the conversation so
      far, to the one pinned model through the one worker (decision 8 and
      the single-implementation rule stand: no second model, loader or
      picker), by llama.cpp's chat template with no system message, no
      grammar and llama.cpp's default sampling. Rewording keeps its
      pinned greedy decoding. Nothing leaves the Mac, and no wallet, Tor,
      guest or NEAR key is involved.
    - It needs the model downloaded and nothing else. While no run is up,
      the first message starts the worker by itself after a run's own
      checks of the Mac, the model's files and the worker; a Start, Pause,
      Stop or Quit ends that worker first, so two never hold the model,
      and an answer under way says it was interrupted and can be asked
      again. While a run is up, messages take their turn at the run's
      worker with rewording. It is no phase, and a failure outside a run
      stops only that message.
    - The guest gains nothing: a conversation travels in a frame of its
      own kind (`L`) that only the app's side of the relay sends, and a
      guest's request is forwarded as a rewrite request (`R`) and nothing
      else, so neither is ever read as the other.
    - A chat and its answer take at most 19,456 tokens, the largest
      context a rewrite has been measured to take (decision 6's limit;
      `evidence/stage3/small-lead-gguf-grammar/feasibility-20261114T052945Z.json`),
      with up to 4,096 tokens an answer. A chat that no longer fits says
      so; nothing is trimmed.
    - A rewrite asked for during a run waits its turn behind a Llama
      Normal answer, and that wait counts against the rewrite's deadline
      (the chief's choice): the longest answer measured takes about a
      minute of the 90 seconds, and a clock that started only at the
      worker would be one more moving part for a rare case.
    - Answers arrive whole. Streaming is a later change of its own, with
      NEAR's.
    - Tried in the running app the same day, signed build: answered while
      Paused with `cloak status` naming the worker; a follow-up that
      needed the first answer; Start pressed mid-answer (Interrupted,
      then Ask Again answered during the run, one worker throughout);
      Stop. The helper showed with the real model that a rewrite gives
      the same output as before the change and that a message reading
      `{"texts":["a"]}` is answered as chat.
18. The app's icon, and the install window. Decided 20 November 2026
    (Sean, "10. a" to have one made from the crown, then "11. a" for the
    dark one of two pictures shown; and "make sure ... the download
    folder menu (for the drag action) [is] good"). The icon is the
    design system's flat crown, block for block, near-white on its
    near-black, on a tile in macOS proportions (`app/art.swift`,
    `app/AppIcon.icns`). The disk image opens as one window: the app, an
    arrow, Applications, with no toolbar or sidebar
    (`app/install-window.py` over `app/install-window.tiff`). Both
    pictures are committed and redrawn only by `app/art.sh`.
19. The modes' names again, and where they come from. Decided 20 November
    2026 (Sean, "13. in the app have: 'Anon' , 'NEAR Private AI' , 'Local
    Llama' , and have an info onhover + clickable , that has links to the
    vitalik x post, the Near X post ... and the llama x post ... for NEAR
    and Llama, say we are an alternate client to their own official
    clients."). Anon V is Anon, NEAR Privacy is NEAR Private AI, Llama
    Normal is Local Llama; Agent stays. "Private" in NEAR's name is his
    own word for the mode, used there and nowhere else. Beside the
    switch, a Modes button opens on a press, or after the pointer rests
    on it: Anon, "Inspired by Vitalik's X post about his preferred AI
    usage."; NEAR Private AI and Local Llama, each "Cloak is an alternate
    client to" NEAR's or llama.cpp's "own official one", with a link to
    their post. The links carry no share-tracking parts. What a saved
    chat holds and what the worker is sent keep their names (`near`,
    `llama`, the `L` frame), so chats already saved open as before.
20. Symbols over words; V, with Agent inside it; Cover in the toolbar.
    Decided 20 November 2026. Sean: "In general I want the UI to be as
    minimal in text as possible, with text on tooltips and dropdown
    texts. The UI should be 'Apple'-like, with symbols and minimalism.";
    "rename in the app from Anon mode to V mode"; "if a user is on V
    mode, then and only then they should also see 'Chat with local
    agent?'"; "if the cover traffic toggle is on every mode, then it
    should be extracted out to somewhere else in the UI, and on by
    default". Decision 19's Anon is V, and its fourth mode, Agent, is a
    switch shown only in a new V chat. The chief's own reading, not his
    words: buttons that move money or delete keep a word; the switch is
    named Agent, not "local agent", because a remote model does the
    agent's thinking. A saved chat keeps what it holds (`agent` or not).
21. Local Llama answers from a short list. Decided 20 November 2026
    (Sean, "20. a - build now", to: a short list of about three local
    models, each checked file for file as today's is; the app reads the
    Mac's memory, marks which fit and which is best, and downloads the
    one picked; rewording stays on the single tested model). This
    relaxes AGENTS.md's "exactly one model" for Local Llama answers
    only. No fallback: a chosen model that is missing or changed stops
    the chat and points to its download, never another model's answer.
    The list is chosen with whichllm's rankings
    (github.com/Andyyyy64/whichllm), run in a container that sees none
    of the Mac's files. Sean asked the same day about Inkling 2 Mini
    (Thinking Machines, released that day): a candidate for the large
    slot if Cloak's pinned llama.cpp can load it. Built the same day
    with two models, today's and Inkling 2 Mini, on llama.cpp's
    unmerged Inkling change; see CHANGELOG.md.
22. The public page and the film wait. Decided 20 November 2026 (Sean,
    "22. c - hold for now, as the app is undergoing changes. I need a
    release video when we are ready to share it"). regents.sh/cloak and
    the intro film keep "Anon" and four modes until he says; a release
    video is owed when the app is ready to share. His tagline of the
    same day ("Cloak your local AI. Always private, full anon is
    optional.") is with the Regents chief, with the film's last frame
    re-made for it.
23. A zkAPI withdrawal goes back to Cloak's own funding address.
    Decided 20 November 2026 (Sean, "23. a"): the whole balance returns
    to the address the guest holds, and a Send Out… button moves it on
    to any address later. Nothing is typed at the moment of withdrawing.
24. The USDC.e wallet stays, as a mode of its own; V always pays
    through zkAPI. Decided 20 November 2026 (Sean: "I think the USDC.e
    + boundless tempo inference needs to stay, as a different mode from
    'V mode' which I think should force use of the the zkAPI. So then
    there is another mode, called Token Inference (?), because that is
    the main draw, and it is useful to buy inference with only
    tokens"). This replaces "Development mode is removed, not kept
    beside it" and the cutover's deletion of the sender, its host half
    and the Tempo wallet parts. What it means:
    - Four modes: V, Token Inference (Sean, "25. a", the same day),
      NEAR Private AI, Local Llama.
    - The token mode is today's V path unchanged: reworded on the Mac,
      sent through Tor from the guest, cover traffic, paid from the one
      Tempo wallet. Its standing note is the one the Development bar
      carries now: the provider can link its chats, because one wallet
      pays for all of them.
    - V has one way to pay, zkAPI. Not a switch, and never the Tempo
      wallet when zkAPI cannot serve: a V chat that cannot pay stops.
    - The two are separate modes, not one path with a fallback. The
      guest keeps both programs, the sender and `cloak-pay`, each on its
      own port, and the escape checks cover both.
    - Nothing changes on screen until step 6 lands: until then V is
      still the Tempo path. At step 6 the Tempo path moves under the
      token mode and V takes the payer. Saved V chats stay V.
    - "Development" as a word, and its bar, still go at step 6.
25. The token mode is named Token Inference (Sean, "25. a", 20
    November 2026); see 24.
26. The Agent switch is in both V and Token Inference. Decided 20
    November 2026 (Sean, "26. a"). An agent task pays the way its chat
    pays: from a V chat through zkAPI, from a Token Inference chat from
    the Tempo wallet, where the provider can link its requests like the
    rest of that mode. The door keeps its Tempo path for those tasks.
    The chief's reading, told to Sean: other apps' requests through the
    door pay through zkAPI.
27. NEAR's line on regents.sh/cloak stays as Sean wrote it, and Cloak
    gets trace sharing. Decided 20 November 2026 (Sean, "27. a - that
    is part of what near does automatically, so we should have a
    checkbox option in the near wallet menu that shares traces or not.
    see https://gateway.near.ai/"). This reverses "Not taken: trace
    collection or upload" of 19 November. What gateway.near.ai says,
    read the same day: sharing is done by NEAR's Gateway Mac app, not
    by NEAR's service on its own; it reads the coding tools' session
    folders the person chooses, redacts on the Mac, shows each trace
    before and after, and sends the redacted trace to the Trace Commons
    (github.com/TraceCommons/trace-commons), where a trace accepted as
    new and real work earns credit in the person's NEAR AI account. How
    a Cloak chat could be shared the same way was read by a helper the
    same day: `docs/near-traces.md`. NEAR AI Cloud itself shares
    nothing when it answers. The documented way for another app is to
    write a picked chat as a file into a folder the person adds to
    the Gateway, which redacts, shows it, asks every time and uploads
    under the person's NEAR AI account, from the Mac's own address.
    The chief's choices: build that (a Share traces switch in the
    NEAR wallet sheet, off at first; Share Trace on a NEAR chat's
    menu; Cloak uploads nothing) and show each NEAR answer's tokens,
    both after step 6's Mac half is merged. Unproven until one real
    try, which is Sean's: whether a plain chat is accepted, and
    whether it earns anything.
28. Start opens Chat, and a first-time person sees a Modes page.
    Decided 20 November 2026 (Sean: "clicking 'Start' should
    automatically open Chat, and for a first time user, it can have a
    special page describing the different mode options, with different
    columns, the required tokens, and the features/benefits of that
    mode. and that page can be opened again from the Details menu").
    One page, one column per mode, replacing Welcome and the Modes
    note; reopened from Details and from Chat's Modes button. The
    AppleScript `start` does not open Chat. Built with step 6's Mac
    half.
29. Sean makes the first real try of sharing, and Cloak shares the
    way NEAR's Gateway does. Decided 20 November 2026 (Sean, "29. a -
    copy their gateway mac app and do it the same way"). The chief's
    reading, told to him: he tries one real, harmless NEAR chat
    through NEAR's Gateway app (a real exchange, never an invented
    one, since the Gateway's draft terms forbid fabricated sessions),
    from the folder `/Users/sean/Documents/Cloak Trace Test`; and
    Cloak does the sharing itself, inside the app, after the Gateway's
    own steps (strip, show before and after, ask, upload under the
    person's NEAR AI account), so nobody needs a second app. This
    replaces the chief's choice in decision 27 to hand files to the
    Gateway. A second read of NEAR's source for that build is with a
    helper; nothing is built until the try shows a plain chat is
    accepted and step 6's Mac half is merged.
    That second read is `docs/near-traces-incloak.md` (20 November).
    Its finding, spot-checked by the chief in NEAR's source at commit
    `46aa4201`: for an account made by NEAR AI sign-in, the commons'
    server takes an upload only with a session identity from one of
    five named coding tools (codex, claude-code, opencode, cline,
    gemini-cli; `trace_contribution.rs:217-225`) or a signed NEAR AI
    receipt for a call the commons set a challenge on
    (`ingest/admission.rs:286-293`). A Cloak chat honestly has
    neither, and a chat file imported by the Gateway never gets the
    first, so Sean's try would most likely be refused too. Nothing is
    built; the choice of what next is put to Sean as decision 34,
    which replaces the chief's question 30 (the steps of the try).
33. A real Venice trial, both steps: Sean's own Inference Only key
    with a $2 limit, given through the secret card, then a $5 top-up
    in USDC on Base to try the wallet route. Decided 21 November 2026
    (Sean, "33. a"). It waits on the carrying part and a caller in the
    app. Decisions 31 and 32 were answered the same day (below, after
    39).
34. Trace sharing is built the receipt way, in NEAR Private AI only.
    Decided 21 November 2026 (Sean, "34. c - you can do this easily.
    Make it 10x better than their version using our better llama.app
    skeleton. for Near mode only . you have their github for their
    macOS app for reference right? you can copy that"). Told to him:
    the Gateway's Mac app is public in TraceCommons/trace-commons
    under `macos/`, and its client crates are MIT or Apache-2.0;
    whether a client other than the Gateway can get the commons'
    challenge and a witnessed receipt is not yet known, and is the
    first thing the helper settles.
35. The NEAR line on regents.sh/cloak stays as it is (Sean, 21
    November 2026, "35. see #34"; the chief's reading: the sharing it
    promises is being built).
36. The Darkbloom window stays out of every release until Darkbloom's
    makers give permission; Sean is messaging them himself (21
    November 2026, "36. hold until I get permission, I am messaging
    them"). The chief drafts and sends nothing.
37. Darkbloom is tried for real on Sean's Mac, this Mac alone, no
    account: Install, Download, Start and Stop from Cloak's window,
    by the chief, reported after. Decided 21 November 2026 (Sean,
    "37. a"). It needs his Cloak rebuilt from main first, which waits
    for zkAPI step 6's guest half so the rebuild is one batch.
38. A shared NEAR chat's message reaches NEAR without Cloak's
    end-to-end encryption, and only that message: a chat the person
    readies sends its next message so, carrying the commons' challenge;
    every other NEAR message stays sealed, byte for byte as before.
    Decided 21 November 2026 (Sean, "38 a"). The reason is in
    `docs/near-share.md`: NEAR's receipt covers the exact bytes sent.
39. The commons' witness is the one redactor, in two presses: Review
    sends the chat to the witness and shows Before and After, then
    Share uploads exactly what was shown. Decided 21 November 2026
    (Sean, "39 a - we can still reword with Near. the user has 100%
    control over what is sent to near, including if rewording
    happens."). So sharing changes nothing about rewording: the shared
    message is reworded or not by the person's own Never Reword and
    Review settings, as any NEAR message is, and what goes to NEAR and
    then to the witness is what they sent. Nothing is copied from the
    Gateway's `macos/` folder: the repository's licence names no terms
    for it.
31. Venice is paid from the same wallet as Tempo: one key, one address,
    funded with USDC on Base for Venice. Decided 21 November 2026
    (Sean, "31. b"), against the chief's recommendation of a separate
    key; the cost he accepted is that Venice's payments and Tempo's
    share an address and so can be tied together. No second wallet key
    is made, and `sh.regents.cloak.venice-wallet` is not used.
32. Venice ships to friends without a question to Venice about its
    terms. Decided 21 November 2026 (Sean, "32. b"). Nothing is written
    or sent to Venice.

Two more sections asked for by Sean on 20 November 2026, each with a
helper in its own checkout and nothing merged yet: a Darkbloom serving
window (his pasted review of Layr-Labs/d-inference v0.10.16; brief
`/tmp/cloak-build/brief-darkbloom.md`), and Venice as a provider inside
Token Inference, by the owner's own key or by USDC on Base (his pasted
review; brief `/tmp/cloak-build/brief-venice.md`, first pass: the
client, its checks and a joining plan, no interface yet).

The Darkbloom window is merged (21 November 2026), read and checked by
the chief; what it is and the licence's words are in CHANGELOG.md. It is
in no release until Darkbloom's makers give written permission
(`docs/release.md`, Standing limits), and it has never run against the
real Darkbloom: nothing of Darkbloom's is installed on Sean's Mac.
Where the worker found Sean's pasted review wrong: Darkbloom's own
supervisor restarts and updates it (its launchd job has KeepAlive
false); `desktop ensure` installs a background agent that stays; the
key route answers null while no local address runs; a plain `darkbloom
start` serves both ways. A real try persists `~/.darkbloom`, a line in
`~/.zshrc`, login services and a model of several GB. Waiting on Sean:
whether to ask Darkbloom's makers for permission, and a real try on his
Mac.

Venice's first pass is merged (20 November 2026): the client and its
checks, with no caller, and `docs/venice.md`. Venice answers through
Tor for its public list and its payment challenge (the chief's try,
same day). The chief's choices: Venice is a provider inside Token
Inference, on that mode's route (reworded, from the guest's sender
through Tor); only models Venice calls Private or TEE are listed until
the owner turns on All tiers; a chat keeps its model and tier and stops
if either changes. The sender's Venice requests in the guest and the host's stream
are merged too (21 November 2026; CHANGELOG.md), with the head frame
named `L` since the payer uses `V`. Next, with the same helper: the
screens, per `docs/venice.md`. Waiting on Sean: which
wallet pays (a separate key is assumed), whether to ask Venice about
its terms (clauses 7.1, 7.3 and 12(d)), and a real try with his key and
about $5 of USDC on Base.

Release 0.6.0 (build 247, from commit `f9e4cad`) is built, signed and
accepted by Apple, and not published (21 November 2026). The image is
151,979,333 bytes, with no Darkbloom and no Venice screen in it, and its
feed entry is written; it is also the Cloak running on Sean's Mac. It
waits on one question put to him as decision 40: whether he makes the
first real deposit through V's own Deposit and Withdraw buttons before
friends get the link (step 8 of the build order in `docs/release.md`),
or friends get it first. The chief's own choices, told to him: Venice's
screens (branch `t3/add-venice-provider`, read by the chief and brought
to main's level rows and amount box) and NEAR trace sharing merge after
this release is out, not into it.

Sean began that first deposit himself on 21 November and met three dead
ends in V's wallet before any money moved: no Start where the wallet said
to start Cloak, a Refresh that did nothing, and a Deposit press whose
quote opened out of sight. Fixed the same day (CHANGELOG), and the build
made again as 0.6.0 (252) from commit `6ca8f9f`, 151,990,597 bytes,
signed, accepted by Apple and running on his Mac. Still unpublished. His
standing word from that day: every new build goes into his own Cloak
immediately.

NEAR trace sharing is built on branch `t3/near-trace-sharing` (21
November 2026), against stand-ins only: no sign-in, enrolment or upload
has been made. An independent reader found 14 things and the helper
fixed them; the chief ran its checks after (helper 34, app 40, no
warnings). What the reading of the commons' and NEAR AI's public source
settled, each of which Sean is told before a real share:

- The readied request carries the whole chat so far, not one message,
  without Cloak's end-to-end encryption. The chief reads this as inside
  decision 38, since sharing sends the whole chat to the commons anyway.
- The witness's hardware check does not cover the connection to it:
  Phala, which hosts the witness, ends that connection and can read the
  chat on its way. The commons' protocol has no binding to use.
- What is uploaded holds no chat words (`message_text_included` false),
  only a record of the call.
- The NEAR AI token the sign-in yields can, for up to an hour, make
  keys, set spend limits and move credits on the person's NEAR AI
  account. The chief's choice: Cloak ends that NEAR AI session itself
  as soon as enrolment is done, and says so if that fails.
- The issuer and the witness are fixed names inside Cloak; if the
  commons moves them, sharing stops until an update, as NEAR's pins do.

Put to Sean as decisions 41 (record acceptance of the commons' terms,
or keep the link) and 42 (the first real share). He answered both on 21
November: 41 a, keep only the Terms link; 42 a, make the first real
share, and "you can test it yourself", so the chief makes the presses in
Cloak. The sign-in in the browser stays his own press. It merges after
0.6.0 is out.

## Gates

| ID | Test | State | Evidence |
| --- | --- | --- | --- |
| A01 | Reference integrity | Open: sources, wrapper (reconstructed), contract and model files pinned; reference inference settings and payment deployment unknown | [baseline](../reference/baseline.md), [contract](../reference/rewriter-contract.md), [models](../reference/models.md) |
| A02 | Clean Mac installation | Open: a signed, notarized build exists (0.5.0, 19 November) and has run only on the Mac that built it; no run on a clean Mac | `app/build.sh` |
| A03 | GUI and CLI equivalence | Open: the menu-bar app and `cloak` drive one supervisor, with the same manifest, states and reason codes (development build, stand-in only); no sessions or payment exist yet to be shared; the checks of the shared states and of the control socket were deleted on 19 November (decision 15) | `app/` |
| A04 | Fidelity | Open: scoring kit built and proven on development data only; no holdout | `scripts/stage4.py`, `scripts/fidelity.py` |
| A05 | Whole-agent containment | Open | |
| A06 | Complete routing | Open: the reference wrapper fails it (static program bypass); in Cloak's guest, which has no network device and one relay to tor, the same static probe and a program without torsocks reach nothing (development evidence only, stand-in) | [baseline](../reference/baseline.md#observed-behaviour-of-the-reconstruction), `tests/test_tor_path.py` |
| A07 | Conversation isolation | Open | |
| A08 | Cover behaviour | Open: the guest's daemon runs the reference's own cover worker from one list, on since 19 November with a pool of 58 pages Sean approved, sixteen picked at each start; nine checks against the stand-in tor passed on 19 November, and the check of the image as built passed the same day; on the real route only two six-minute runs' totals were measured, so the schedule and lifecycle are not checked against the policy, and the sites have not agreed to automated visits (NET04) | `reference/cover.json`, [cover in the guest](#cover-traffic-in-the-guest-built-18-november-2026) |
| A09 | Failure and pause | Open: in the app, a tor, worker or guest failure stops all work and ends in Needs attention with its reason, with nothing restarted and no other route or model; Pause and Quit stop everything, and a relaunch starts nothing (shown by checks with stand-in processes until they were deleted on 19 November, decision 15, and by a live run with one worker kill; development build, stand-in only); sleep paused in the state machine's checks, deleted the same day, and no live sleep and wake has been tried; closing the door answers a request under way and sends nothing (its check was deleted on 19 November, decision 15); no sessions or payment yet to stop; cover runs in the guest's daemon and ends with the guest, which no check has watched | [state machines](state-machines.md), `app/Tests/CloakTests/` |
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
| A20 | Unchanged rewrite API | Open: contract captured; the daemon's own rewrite code runs in the guest, unchanged but for Cloak's input limit and deadline (decision 6, a departure from the spec's limits by Sean's ruling), and refuses nine kinds of bad reply (stand-in model only) | [contract](../reference/rewriter-contract.md) |
| A21 | Host–guest worker boundary | Open: one token-checked virtio socket, guest has no network device, host relays only rewrite frames, worker sandboxed with no network (development signing; stand-in model) | `host/`, `guest/`, `llama-worker/cloak-rewriter.entitlements` |
| A22 | Authorship and linkability | Open: attack 1 and the sign-flip bound built and proven on synthetic development data only; attack 2 not built; no holdout | `scripts/stage4.py`, `scripts/privacy.py` |
| A23 | Long and cold tasks | Open | |
| A24 | Artifact provenance | Open: files pinned for the reference, the two candidates and the stand-in; each candidate takes its tokenizer and chat template files from its vendor (decision 1) | [models](../reference/models.md) |
| A25 | Single implementation | Open: the app runs one model and one worker, named in its bundle's manifest (the small lead until stage 4 picks a winner or none), with no picker, no switching by hardware and no fallback; the repository holds one engine since 14 November (decision 8) | `app/release.json`, `app/manifest.py` |
| A26 | Performance claims | Open | |
