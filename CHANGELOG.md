# Changelog

## Unreleased

- zkAPI trial: the whole trip run on mainnet outside Cloak, through Tor
  only, on Sean's decision: a $5 deposit, one paid request answered, its
  settlement, a restart, and a withdrawal of the full balance. Open
  Anonymity's service serves this client. The trip cost about $3.57,
  nearly all network fees. `guest/zkapi/trial/drive.py` answers the
  daemon's questions only when a go file exists. Figures in
  `docs/plan.md`.

- Wallet and Chat: three faults from `docs/state-machines.md`, section 10.
  A deposit kept before its opening was known to land is shown as the
  network shows it, and a send is no longer stopped for want of funds
  before the payment toolkit can recover it. One the toolkit still marks
  as opening is no longer forgotten while the network shows none, since
  it may yet land. Send is not turned off while the wallet is still
  being looked for. A wallet the keychain could
  not read says so, with Try Again, where the sheet spun until Cloak opened
  again. A new message whose rewording stops or is cancelled goes back
  into the box as typed, with its picks as they were, where they came back
  as text. What is kept on the Mac before a payment leaves is unchanged.
  No money was moved.

- Docs: `docs/release.md`, a skeleton of what stands between today's
  Cloak and a public release, in nine items, with what is unknown in each.

- Guest: `guest/zkapi/build.sh` builds Open Anonymity's mainnet zkAPI
  daemon and its Rust companion for linux/arm64 from pinned source, each
  in Docker, into `guest/build/`; nothing goes into the guest image yet.
  The companion and its protocol are now pinned in
  `reference/sources.json`. The plan has what was measured: one proof
  peaks at 129 to 165 MiB and takes about 3 s on two cores, every outside
  connection goes through Tor once the daemon is set to it, and which
  files must be kept across a restart. No money was moved.

- Wallet: a Close or Withdraw that stops keeps its reason on screen until
  the next press or until it is dismissed. It showed only for the moment
  the wallet took to be read again. The places where a stage is still
  implied by several fields are listed in `docs/state-machines.md`,
  section 10.

- Plan: what paying through the mainnet zkAPI service takes, and its risks
  to a deposit.

- Reference: the source of Open Anonymity's mainnet zkAPI release line is
  pinned as `zkapi-mainnet` (research; nothing is built from it yet).

- Chat: an answer's formatting is drawn, where its Markdown showed as
  written, marks and all. Headings, bold, italic, struck and code words,
  code blocks (monospaced, scrolling sideways rather than wrapping), lists
  with one level of nesting, quotes, rules and simple tables, in chat and
  agent answers alike. A link shows its words and then its address, and
  never opens, since a click would open the browser outside Tor; an image
  is never loaded, its words and address shown instead; HTML shows as
  written. An answer now shows in full, where a long one scrolled inside
  its own box, and its text is selected a block at a time. The answer as
  saved is unchanged, and Original and Reworded are as they were.

- Plan: the agent's first real tasks and the details pills, as seen in the
  running app on 15 November.

- Plan: the zkAPI finding corrected. Open Anonymity runs a mainnet vault on
  the earlier circuit and a Sepolia vault on the current one; the pinned
  daemon matches neither.

- Chat: details while you write (decision 13). Once a message or task has
  four words or more and rests for about a second, the model on this Mac
  proposes up to four details it leaves open, as pills above the message
  box. A pill opens a picker: choices, a span, colours, or a square between
  two pairs of opposite words, each with Something else. Each detail picked
  is added under the message as a line, "Label: value"; the first pick keeps
  the details until the message is sent or emptied. The draft goes only to
  the model on this Mac, nothing is paid, and nothing of it is logged. A
  rewording never waits for details: one asked for meanwhile stops them.

- Chat: a new conversation can be the agent's (decision 12). Pick Agent
  under the message box before the first message; each message is then a
  task the agent works on inside Cloak's sealed guest. Its card shows the
  task as written and as reworded, each step the agent takes (Ran, Read,
  Edited, Wrote) and its answer. Stop ends it; one that ended without an
  answer can run again; tasks in different conversations run at once.
  After Cloak starts again the agent does not remember earlier tasks, and
  the conversation says so. The door's refusals now say "Try again" and
  name no address, since a task's card shows them too.

- The agent in the guest, plumbing (decision 12): Cloak can run Pi on a
  task inside the sealed guest, in the reference sandbox. Its model
  requests come to the door on the Mac through a new door port, reworded
  on this Mac and sent through Tor like any app's, each conversation with
  a pass of its own that works only from the guest; everything its tools
  open goes through the Tor port, and curl is in the guest for them.
  Stopping a task ends everything it started. No window uses it yet. A
  sender that hangs up before its turn now fails that send, where the
  app's next write could have ended the app.

- Wallet says less so a made wallet fits its sheet: Network and Token are
  one row, "USDC.e on Tempo"; the line that the provider takes it shows
  only when it no longer does; the Model box has no second "Model" above it.

- Windows, from pictures of them: Wallet is as tall as what it shows, and
  its form scrolls only past 640 points or past the room the Chat window
  leaves it, where it hung below Chat and left an empty band with no
  deposit open; Refresh, Done and Agents' Add line up with the boxes'
  right edge; Remove in Agents is as easy to hit as Copy; a shrunk unsent
  message's edge takes the accent colour under the pointer, since a press
  opens it; and VoiceOver reads Details' technical details as text, with
  their title still opening and closing them.

- Chat: a message reworded but not sent can still be finished after
  another is written. Its card shrinks and says "Not sent"; pressed
  anywhere, it opens again to be edited, reworded and sent, and the card
  open before it shrinks. One card is open in each chat at a time, a new
  message's first, and a card being reworded stays open until it is done.
  A message sent after later ones moves to the end of its chat, so the
  chat reads in the order things were sent and each request to the
  provider is the one before it plus more.

- Windows, from an accessibility read: Wallet opens tall enough to show
  everything for a made wallet with an open deposit, still inside a
  13-inch screen; in Agents each app's words read as text, with Remove a
  button of its own; a new app's pass shows in full, wrapping, with the
  address under it on the sheet's one left edge; Copy buttons are easier
  to hit; the new app's name field has a name for VoiceOver; and Chat's
  messages line up with the Development bar and the message box.

- Details: the login setting reads "Launch Cloak on startup" (Sean, 14
  November 2026), with one line under it saying Cloak opens paused.

- Chat: Send Original, a checkbox under the message box, sends that
  message as written, with no rewording, still through Tor; its card shows
  the Original alone and the Reworded light off, and Reword on it rewords
  it as usual. Off at each launch; a rewording that fails still never
  sends the original, and apps using Agents are always reworded (decision
  11 in docs/plan.md). The menu's Chat, Agents and Details lose their
  ellipsis, since each only opens a window. Two new checks: a message
  going as written is sent, and replayed, as written among reworded ones,
  and a chat holding one opens again as saved.

- Agents keeps each app's "last used" current, drawn again each minute,
  where a reopened window showed the time as it was when it was last
  drawn. docs/plan.md: the door in "Stage 5 so far", with what the daemon
  rewords, file by file, the checks and the live run on loopback up to
  the no-wallet stop; and the sender now posts the body the app built.

- Agents, from the menu: your other apps on this Mac send chat requests in
  OpenAI's shape to `http://127.0.0.1:8742/v1` while Cloak is running,
  each with a pass of its own, shown once when the app is added; Remove
  ends it at once. Each user message is reworded on this Mac as the pinned
  daemon does it, earlier ones replayed as reworded, before anything is
  sent from the one wallet; system messages, tools and tool results go as
  the app sends them. Only `POST /v1/chat/completions` and `GET
  /v1/models` answer; a web page, a missing or wrong pass, and requests
  the provider would refuse anyway are turned away first, each with
  OpenAI's error shape. Pausing answers a request under way with 503. Only
  each app's name, pass fingerprint, count and last use are kept, sealed;
  no request's text is kept, shown or logged. Nine new app checks, one
  against the daemon's own transcript.

- The app rewords a message of several text parts in one call, as the
  daemon does, under one 10,000-character cap and one deadline for them
  together (`Supervisor.rewrite`); Chat's messages are one text, as
  before. Its JSON reader can now write a message back as Go does for the
  daemon's digests. Two new checks: several texts are the daemon's request
  byte for byte, and they share the cap.

- The guest's sender posts the chat request the Mac built, as it is, and
  brings the provider's completion back as it came; the Mac reads the
  answer from it. It also gives the provider's list of models as it comes
  (`models`). Chat's sends are unchanged: the app builds their body,
  `{"model", "messages", "stream": false}`, and keeps only an answer that
  says something and finished by stopping or at its length, as the sender
  did.

- docs/plan.md: decision 10 (14 November), sending in a Development mode,
  and in "Stage 5 so far" its design, what goes out, its checks and its
  live proofs through Tor up to the first payment, with no money moved,
  and what the owner's funded wallet would prove next.

- Chat sends, in a Development mode marked at the top of the window with
  what it means: the provider can link your chats, because one wallet pays
  for all of them. The newest message has three lights (Reworded, Routed,
  and Unlinked, never good here) and Send, which is off, with words beside
  it, only where sending is certain to stop; every press is sent. The
  answer comes back into the conversation and is kept sealed with it, and
  a sent message can no longer be edited. Wallet, in Chat's toolbar:
  Create (the key made in the guest and kept only in the login keychain),
  the address to copy, the balance, the deposit with Close and Withdraw,
  and the model with its price, the cheapest by default. Running now also
  waits for the sender, and the guest stays up while Running. Ten new app
  checks.

- The host can start a guest that serves, connect to its sender and
  exchange one request with it, keeping each deposit change before the
  sender goes on (`Guest.prepare(serve:)`, `Guest.connect`,
  `Sender.exchange`). `cloak-host --serve` keeps such a guest up and passes
  one request per line of its input, for the live checks; the guest's
  console then goes to standard error.

- The guest's sender, Development mode's one way to a remote model
  (decision 10): `guest/sender/`, in Rust, paying through the official MPP
  toolkit (`mpp` 0.20.0, pinned in its lock file and in
  `reference/sources.json`, past both advisories on the crate). A guest
  asked to serve starts it after its checks, as a user of its own. Every
  connection it makes goes through the guest's Tor port, with a SOCKS user
  name for each conversation and names resolved by Tor. It sends only the
  reworded turns, with five headers and no user agent; it has every change
  to the deposit kept on the Mac before it goes on; and it stops in one of
  six named ways. `guest/build.sh` builds it in the pinned Rust image. Ten
  checks against stand-ins: `cargo test --manifest-path
  guest/sender/Cargo.toml`.

- Stage 5: the Chat window's second checks (14 November), written up in
  docs/plan.md: the build, the app's 43 tests, the worker's 35 and the
  guest path's 23 on this round's code; no sockets for the app while its
  startup check reworded through the relay; a test-time way to show the
  app light without changing the Mac (`-NSRequiresAquaSystemAppearance
  YES` at launch), with `docs/shots/chat-not-running-light.png`; and why
  the timing lines leave the log within minutes (info level, kept in
  memory only), left as they are. The live rewordings and the other
  on-screen checks wait for an unlocked screen.

- Chat keeps the end of a conversation in view, if it was in view, when the
  window shrinks: a conversation that fit the window lost its end as soon
  as the window became shorter than it. The same rule covers a
  conversation growing past the window, whose newest message was cut off
  the first time it stopped fitting, and choosing a longer conversation
  after a short one. Each conversation also has a scroll view of its own,
  so after reading one part way up, the next opens at its newest message
  instead of at the same height. Shown in a window of the same shape laid
  out offscreen (docs/plan.md, "Stage 5 so far"); not yet seen in the app,
  since the Mac's screen was locked.

- Chat marks the words taken out of the Original with a light red tint and
  a dotted red underline, in place of a red tint with a line struck
  through, which made an original with most of its words taken out hard to
  read. Words put in keep their green tint and solid underline. One mark
  means one thing at every length, so the panes never switch what a mark
  means. `docs/shots/removed-marks-before-light.png` and `-after-light.png`
  (and `-dark`) show the old and new marks on a message with 77 of its 91
  words taken out, drawn offscreen in a text view with the app's font and
  marks.

- The evaluation protocol is a draft, not frozen, in `docs/plan.md` and
  `README.md` too, as in `docs/evaluation-protocol.md` (Sean, 14 November:
  "don't freeze anything yet? this is still super active development"); Sean
  freezes it before any holdout opens. `docs/spec-v0.4.md` names the
  llama.cpp worker where it named the MLX one, in its decision summary and
  stage 2, since the engine is chosen; the plan keeps the spec's sha256 as
  received and says it is a working draft.

- `RewriteTests` builds the daemon's reply check for each use in a folder
  it then removes, where it left one folder in the temporary folder per
  run.

- Stage 5: the Chat window's first checks (14 November), written up in
  docs/plan.md, with three dark shots in `docs/shots/`: two real rewordings
  with the small lead (1.3 s and about 2 s), text wrapping at the default
  and smallest window sizes, a conversation back after a relaunch, Delete
  asking first and removing the file, no readable words in the sealed file,
  no sockets for the app while it was open but not started, and the
  keychain's prompt after a rebuild. The light appearance, the stopped and
  cancelled rewordings, the 10,000-character refusal on screen, an edit,
  and the worker's full checks wait for a cooler Mac. README.md says how
  to open Chat.

- A Chat window, from "Chat…" above Details… in the menu: conversations
  newest first on the left, titled by their first message, with New and
  Delete (which asks first); the conversation on the right, oldest first,
  and the box for the next message at the bottom. Return rewords the
  message, Shift-Return starts a new line. While it rewords, a spinner and
  the time so far, with Cancel (Escape). Then Original and Reworded side by
  side: words taken out tinted red and struck through, words put in tinted
  green and underlined, with a count of each. The newest Reworded can be
  edited, and the marks follow; Reword asks again from the original. Send
  is there but off, with "Sending isn't set up yet." Each turn is saved as
  a draft as soon as it is reworded or edited. Rewording works only while
  Cloak is running; otherwise the box says why, with a Start button. A
  rewording that stops says what happened and what to do, and a new
  message goes back into the box. Nothing in the window goes to the
  network. Details and Chat share one window helper (`AppWindow`).

- Sealed conversations (`app/Sources/CloakChat`): one file per
  conversation in `conversations/` beside the app's other folders, sealed
  with ChaCha20-Poly1305 (CryptoKit's combined form, a fresh nonce on every
  write, the conversation's id as authenticated data), written owner-only
  and atomically into an owner-only folder. Nothing is on disk unsealed,
  titles included. The one 256-bit key is a generic password in the login
  keychain, usable only on this Mac while it is unlocked, made on first use
  and never made over existing files: a missing key or a file that does not
  open is shown as such, and the files are left exactly as they are.
  `WordDiff` finds the words taken out and put in, by
  `CollectionDifference` over each text's words. `StoreTests` uses its own
  folder and keys, never the real ones.

- The app can reword a message itself (`Supervisor.rewrite`, `Rewrite`),
  only while Running, through the relay to the same worker the guest uses.
  The request is the pinned daemon's byte for byte: its system message
  (sha256 c95de591…724b), the texts as `{"texts":[...]}` in Go's JSON form,
  temperature 0, 16384 tokens and no thinking field. A reply counts only
  under the daemon's own rules, plus decision 6: at most 10,000 characters,
  refused before anything is sent, and 90 s + 20 ms per character to
  answer. Every other ending (timed out, refused, cancelled, the model
  stopped) gives no text, never the original. The app is stricter than the
  daemon in three places the worker never reaches: a reply that is not
  UTF-8, nested deeper than 128, or naming a field twice. The log has how
  each ended and how long it took, never the text.
  `app/Tests/CloakTests/RewriteTests.swift` checks the request and about 70
  replies against the daemon's own code (`tests/daemon_reply`, which now
  also prints the request it sent and the texts it took);
  `StoppedRewriteTests.swift` drives each stopped ending through a real
  relay to `tests/fake_worker.py`.

- The relay answers requests from the app itself (`Relay.answer(to:)`), in
  turn with the guest's connections on the same worker, one at a time, so
  the app's rewrite never overlaps a guest call. Cancelling one that is
  still waiting means it never reaches the worker; at the worker, the worker
  is told to stop. A worker lost on it is replaced as for a guest call.

- Stage 5: a live run of the app with the small lead (14 November),
  written up in docs/plan.md: Start reached Running in about 8 s from Paused
  (10 s with the app closed), three `cloak verify` runs each sent a real
  rewrite through the guest, the daemon and the worker, and the whole
  product peaked at 6.72 GiB. An extra file in the model's folder gave "The
  model has changed"; Quit from Running stopped everything within 4 s. The
  Details window shots in `docs/shots/` show the small lead, light and dark.

- Stage 3: the EVAL01 development screen on the small lead again, on the
  one-engine tree (14 November), recorded in
  evidence/stage3/small-lead-gguf-grammar/ and written up in docs/plan.md:
  the same 16 texts byte for byte as the first run, 9 of 16 passed, median
  0.82 s, whole product 6.67 GiB at its peak.

- `tests/test_guest_path.py`: the long rewrite that the cancel and the
  worker kill aim at is now one message of 120 short texts, which the
  stand-in on llama.cpp rewrites in about 12 s. The old long text took about
  1 s there, so both came after the rewrite had ended and the two checks
  failed.

- The app runs the small lead: its manifest names `small-lead-gguf-grammar`,
  shown as Qwen 3.5 9B, on a Mac with Apple silicon and at least 16 GB
  (it was the stand-in and 32 GB). Details shows the release and the model
  in plain words; the build moved to Technical details. A model folder that
  is not exactly the pinned files now needs attention with "The model has
  changed. Reinstall the model, then start again." (`model_changed`), where
  it said the model couldn't load and to start again. The app still does not
  download the model; README.md says how to fetch it and how to repair it.

- One engine (decision 8, 14 November): the MLX worker (`worker/`), its
  install script and `tests/test_worker.py` are deleted. The llama.cpp worker
  in `llama-worker/` is the only one, and every model it runs decodes under
  the reply grammar. `reference/models.json` keeps three models a worker
  runs, `small-lead-gguf-grammar`, `small-challenger-gguf-grammar` and the
  stand-in `standin-gguf-grammar`, with no `engine` field; the other
  candidates and the MLX conversions are deleted, and their records stay in
  `evidence/`. The worker exits with status 3 when the model folder is not
  exactly the pinned files. Its checks are one file,
  `tests/test_llama_worker.py`.

- Stage 3: the EVAL01 development screen on the small lead, both engines
  (14 November), recorded under evidence/stage3/ and written up in
  docs/plan.md: 9 of 16 on llama.cpp with the grammar, 10 of 16 on MLX,
  most misses exact-string ones. Engine choice: llama.cpp with the grammar.

- Stage 3: the small lead on llama.cpp under the bounded reply grammar
  (14 November) is recorded in evidence/stage3/small-lead-gguf-grammar/ and
  written up in docs/plan.md: 40 of 40 ordinary messages rewritten, median
  1.12 s, 95th percentile 3.28 s, whole product 6.79 GiB at its peak. A
  candidate record; it closes no gate.

- Stage 3: the stand-in under the bounded reply grammar (14 November) is
  recorded in evidence/stage3/standin-gguf-grammar/ and written up in
  docs/plan.md: 39 of 40 ordinary messages rewritten against 38 under the
  first grammar, e06-10 now rewritten in 0.69 s instead of running to its
  time limit, and e06-36 still a word runaway. Development only.

- `docs/plan.md`, "Stage 5 so far": removing the boot files a killed app
  left, at each launch, now stands under what exists; it still stood under
  what does not, though it was built on 13 November.

- Screenshots of the app in each of its states, in `docs/shots/`: the
  Details window light and dark, the menu and the status icon dark. The
  plan's "Stage 5 so far" records the pass behind them: the names VoiceOver
  reads, the menu's shortcuts, Pause and Quit during a start, and what is
  not shown yet (the Tab order with Keyboard navigation on, where Technical
  details likely cannot be reached).

- The app: VoiceOver can now open and close "Technical details" in the
  Details window. In the window's form, the disclosure offered VoiceOver no
  action to press.

- The reply grammar (decision 9) allows at most 16 white space characters
  at a time between JSON tokens, where it allowed any number, so a reply
  can no longer run on in white space until its deadline (the small lead's
  e06-37, the stand-in's e06-10). Removing the white space, as first
  planned, changed 35 of the stand-in's 40 EVAL06 replies and sent six into
  word runaways; bounded, 39 are the same bytes as without a grammar and
  e06-10 now closes its reply. New grammar hash in the three grammar
  entries of `reference/models.json`, so they are new configurations; the
  llama worker is rebuilt with it. New check in
  `tests/test_llama_worker.py`: no white space between tokens runs past 16.

- tor's SOCKS port is now a socket file in a folder only you can open,
  made for each start and removed once tor stops, for `cloak-host` and the
  app alike. Before, it was a port on the Mac's loopback, which any program
  on the Mac, of any user, could use to send its own traffic through Tor
  while tor ran. Nothing of tor's listens on the network now. The guest,
  the daemon and torsocks are unchanged, and each conversation still gets
  its own circuit: the host's relay passes tor's answers back in the form
  tor gives on a network port, which torsocks needs. Other programs you
  run yourself can still open the socket. New check in
  `tests/test_tor_path.py`.

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
  when it opens from the menu, chosen with the mouse or with Command-D in
  the open menu. Before, it could open behind the app in
  front, since a menu-bar app is never the app in front. While the window
  is open the app shows in the Dock; closing it (its close button,
  Command-W or Escape) makes it a menu-bar app again, still running.
  Checked with real clicks on the status item and real Command-D presses
  in its open menu.

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
