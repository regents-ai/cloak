# Changelog

## Unreleased

- **Local negotiated-crypto session log (zero telemetry)**: Capture actual negotiated TLS metadata (`tls_protocol`, `tls_cipher_suite`, `tls_key_exchange`) directly from `rustls::ClientConnection` in `guest/near` (`cloak-near`), emit on `ProofLine`, decode into `NearProof`, display hybrid PQ (`X25519MLKEM768`) vs. classical ECC transport live in NEAR Gateway Insights and chat proof tooltips, and support local-only inclusion in Redacted Diagnostic Reports.
- **Hybrid post-quantum TLS (`X25519MLKEM768`) in `cloak-near` and ML-DSA-65 release verification**: Switched `guest/near` (`cloak-near`) from `ring` to `aws-lc-rs` with `X25519MLKEM768` promoted to first preference in TLS 1.3 key exchange while retaining classical fallback groups. Added native Apple `CryptoKit` FIPS 204 `ML-DSA-65` release co-signature verification (`CloakControl.PostQuantumReleaseSignature`), `cloak verify-release` CLI subcommand, Keychain-backed `app/pq-release-sign.swift` signing helper, `app/build.sh` / `app/release.sh` / `app/publish.sh` release pipeline hooks, and **Settings → Status** ML-DSA-65 key fingerprint display.
- **Dead-simple onboarding, plain-English modes, and auto-start**: First launch now opens directly into **Local** mode with an inline onboarding card (`Download Recommended Local Model (<size>)`, auto-recommending fast 10.2 GB Inkling 2 Mini JANGH2 on 16 GB+ Macs when `cloak-worker-vmlx` is bundled, or RAM-tiered GGUF models) featuring inline progress and a 0.5-second interactive hover popover linking straight to the pinned HuggingFace repository. Modes are renamed to **Local**, **Private Cloud (NEAR)**, **Pay-Per-Prompt**, and **Paranoid (V)** with plain-English "Why crypto?" tooltips; pressing Send/Run while paused in Tor/V/Pay-Per-Prompt modes auto-starts Cloak inline; fixed Tor/zkAPI indicators are flat non-clickable status badges; **Connected Apps** (`cable.connector`, with a direct Funds shortcut) now lives cleanly inside Settings; Darkbloom is renamed **Inference Serving** in the menu bar and window title with official Darkbloom + Eigen Labs vector branding, an automatic **Update** button for older runtimes, and bulleted popover notes.
- **Unified Funds sheet, Venice default provider & Card / Apple Pay on-ramp**: Pay-Per-Prompt now defaults to **Venice (Base USDC)** with a dedicated Keychain wallet separate from Boundless/Tempo (`sh.regents.cloak.venice-wallet`), streaming answers, tolerant model-list decoding, and concurrent `cloak-sender` vsock connections. A single **Funds** sheet (hidden in Local mode) combines Pay-Per-Prompt, Paranoid (V), and Private Cloud (NEAR), preserves form inputs across review cancellation, and includes a non-custodial **Card / Apple Pay** checkout sheet for Base USDC and Ethereum ETH. Paranoid (V) deposits default to `$5`/`$10`/`$20` quick picks with live `TimelineView` expiry badges, macOS notifications at days 20/25/28, and an opt-in 3-day auto-withdraw toggle.
- **Simplified Settings**: General now holds ~5 everyday controls with a single 3-way **Prompt rewriting** picker (*Review before sending* / *Automatic* / *Off*); Cover traffic (also removed from Chat's toolbar), Free memory (15-minute default), NEAR hardware check freshness, Quick prompt shortcut, Connected Apps port, and Show all Venice tiers live in Advanced.
- **Dual Local Engines (`cloak-worker-vmlx` + `llama.cpp b12633`) & 44 MB Unfiltered LoRA**: Added a pure-Swift, zero-Python `cloak-worker-vmlx` worker (`osaurus-ai/vmlx-swift`, MIT) speaking Cloak's exact framed `WorkerChannel` protocol to run pinned `OsaurusAI/Inkling-2-Mini-JANGH2` (`10.2 GB`) at **~57–64 tok/s** and `~10.3 GiB` peak RAM on **16 GB+ Macs**. Bumped `llama-worker` to `llama.cpp b12633` (including merged `inkling2_loop` + PR `#32704` NVFP4 loop-pass scale fix), added RAM-tiered Unsloth `UD-Q3_K_XL` (`13.6 GB`) and Xylolabs Native `NVFP4-Q8_0` (`17.6 GB`) GGUFs, added an opt-in **Unfiltered (Uncensored)** toggle backed by AtomicChat's pinned 44 MB GGUF LoRA (`--lora`), bounded rewrite KV caches with static system-prompt prefix reuse, added mid-chunk `abort_callback`, added `Relay.restNow()` VRAM coordination on 16–24 GB Macs, and wired live `P`-frame answer streaming with a separate 8,192-token thinking budget (`422` thinking-limit stop).
- **Reliability, security, and Darkbloom monitoring**: Hardened `PayQueue` cancellation/error precedence, `DepositStore` compare-and-forget, `ConversationStore` sibling-file Keychain guard, `Door` per-app rewrite serialization & coalesced disk writes, `torport` half-close propagation, guest `RequireAPIKey` + per-conversation `torsocks` credentials + clean payment disk unmount, `.DS_Store` immunity and 1-click `Repair Model`, off-`@MainActor` VM boot preparation and memory polling, Darkbloom live monitor metrics and lifecycle fixes, plus fast pure-Swift `StateMachineTests`.
- The words every wallet uses. V's wallet says Balance, not On hand, and
  Transfer…, not Send Out…; a transfer takes an amount in ETH (Max for
  all of it, less the fee) and its review no longer counts down, asking
  to Update Fee only once the quote is 30 seconds old. Both wallets show
  Network and Asset, a transfer on its way is Pending, a press the
  balance can't cover says Insufficient balance, and what the service
  turns away is Declined. In Agents an app gets an API Key and the Base
  URL, the names the app itself asks for, where Cloak said Pass and
  Address, and an app that went away is Disconnected. In Settings,
  NEAR's Freshness is Hardware check and Help's Copy Words is Copy
  Prompt; a NEAR key turned down is Invalid key, and too many requests
  is Rate limited.
- Both wallets say what alone may be sent to their address, under the
  address and under its QR code: only ETH on Ethereum Mainnet for V's,
  only USDC.e on Tempo for Token Inference's. Cloak can't return anything
  else sent there.
- V's model list shows prices the way people know them: each model with
  its price for a million tokens, in and out, as Token Inference's list
  does. Before, each said "up to $1.00 a request", which is what is set
  aside while a request is out, not what it costs; that figure is now in
  the row's tooltip, for the picked model. The payer reads the prices in
  the guest, over Tor, from the same public list it reads the models'
  names from.
- Switching Cover does something at once. Switched while Cloak is
  running, from Chat's toolbar or Settings, Cloak restarts by itself with
  the new setting: the menu says Restarting, then Starting, with no stop
  at Paused. It waits while anything a restart would cut is under way (a
  message being reworded, sent or answered, an agent's task, a request
  from an app, a wallet press or money on its way), holds nothing back
  meanwhile, and says so beside the switch while it waits. Switched back
  first, nothing restarts. Before, a switch changed nothing until Pause,
  then Start. Restore Defaults says when it will restart Cloak for this.
- VoiceOver can switch Settings' switches. It read each one out and its
  press did nothing; the way the rows hid a switch's label had taken the
  press away. They look as before.
- A new port is used as soon as it is saved: the door moves to it and
  requests under way are not cut. Before, it waited for the next Start.
- Settings and Details read what can change outside them (the login
  item, the update setting, model files and free space) only when their
  own window comes back, not each time any note or other window of
  Cloak's opens or closes.
- Settings has four panes, not six. The quick prompt's shortcut and the
  port (the pane that was called Door) are now rows at the top of
  Advanced, under Shortcut and Agents, and each one's note says what it
  is for. Change Port… in Agents opens Advanced. Settings no longer says
  "door" anywhere but in the log's own lines.
- Tooltips have room round their words. macOS draws its own with the
  words hard against the border and gives no way to change that, so
  every tooltip in the app (56 in its windows, two in the menu) is now
  Cloak's own: the same words at the same size, with 10 points of room
  each side and 7 above and below. It comes up under a pointer that has
  been on a button for a second and is still, at once after another one,
  never under a pointer passing over or in a window behind another
  app's, and goes on any click, key or scroll. An info mark has none,
  since resting on it opens its note. Its first form, in build 268 for
  nine minutes, flickered and then ended the app on short words (a
  hosted SwiftUI box that never stopped resizing its panel); the box is
  now drawn and measured by hand.
- The door stops working for an app that has gone. While a request is
  read, checked and reworded its connection is watched; an app that
  leaves before the request is handed on to be paid ends it there, with
  nothing more reworded, sent or paid, and Agents lists it as Left. One
  already handed on runs to its answer, since cutting it then could still
  be charged, and is listed as Left, paid for. One money check added, for
  both ways of paying (41 pass).
- Agents says what stopped and carries the way on. Its status line has
  Start while Cloak isn't running, and, when the door can't open, the
  door's own named reason with Try Again (and Change Port… while another
  app holds the port). Adding an app always shows the pass it made, once.
  An open request follows the door's list. A task that couldn't reach
  Cloak has Agents… on its card. Opening the saved chats again runs one
  try at a time, with a spinner, and says when it failed again.
- Settings rows say what stopped and carry the way on. The NEAR key's
  row is one stage: a check that fails says "Couldn't check" with Try
  Again, a save that fails keeps what was typed and says so, a remove
  that fails keeps the key shown as saved, and Replace has Cancel; the
  Wallet's own check keeps its stop in the Wallet. A model's row shows
  when its download waits for the network or for its next try. The
  shortcut recorder takes only keys typed into it, and a choice macOS
  refuses says which shortcut still works. Launch at login says when
  macOS wants approval or refused, with Open Login Items. Restore
  Defaults leaves V's model, which the Wallet chooses. Every Copy shows a
  checkmark for a second and a half; Copy Log shows only once there is a
  log.
- Chat and the menu keep each stage with its own chat and its own press.
  A message's rewording belongs to the chat it was asked in: its result,
  its stop and its text given back no longer land in whichever chat is
  showing, and another chat can be written in meanwhile ("Another chat
  is rewording." with Cancel where a second rewording would wait).
  Whether a reworded message sends by itself is settled at the press, so
  ticking Never reword or Review while it rewords no longer sends it
  unasked. A send's stop stays with its own message; a NEAR message that
  may have left before the stop says "May have been sent". New Chat
  works whenever Chat is open. A task's card appears at the press, before
  the model is read. One rule (`Fix`) gives the menu, Details, Chat and
  the Wallet the same way on for a start that stopped: Start Again where
  it can work, Download Model… while the model's files are missing, Show
  in Finder when they have changed, none where Cloak can do nothing; the
  menu's Start is off where it is certain to stop again. After the
  model's download finishes the line says "The model has downloaded."
  beside Start Again, not "The model isn't installed." Three task checks
  added (40 pass).
- V's wallet says the truth about each press and each read. A press
  that stopped is one value with what it asked, so an approve's stop no
  longer reads "Nothing was sent." because a quote was pressed after it.
  A read that stops says why with Try Again and stays until a read works
  (no spinner for good after a first read fails); Refresh, and every
  other call to read, reads now, cutting the 10 second wait short; a read
  begun before an approve's answer no longer lands over it. Return in
  the Amount box does only what Deposit would; its red line goes as the
  text changes; the model list's failed read says so with Try Again; a
  failed wallet still shows its address and Send Out…; Withdraw pressed
  before the deposit was read stops as "Not read" with Try Again. Three
  payer checks added (37 pass).
- `docs/state-machines.md` has a new section 11: every place in the app
  where a stage is still read off several fields, the menu, each window
  and the two unmerged branches included, with the faults traced in
  each. Section 9 is corrected where the run had moved on: the guest
  stays up through Running, the payment disk is a step of Preparing, and
  which commands are refused where. No code changes.
- A place that says what is missing now carries the way on, after Sean's
  first try of V's wallet on 21 November. A wallet opened while Cloak is
  not running leads with Cloak's state and Start (Download Model… while
  the model is missing, a spinner while it starts), and reads itself as
  soon as Cloak runs; Refresh, Create, Close and Withdraw are not shown
  where they could do nothing. In a chat, "Create a wallet to send",
  "Add funds to send" and "Deposit closed" come with Wallet…, a stopped
  request the wallet fixes (no funds, a model that can't be used) with
  Wallet…, "Add your NEAR key to send" and a key NEAR refused with
  Settings…, and a NEAR chat that needs Tor with Start. Settings' Copy
  Commands shows only once there are commands to copy.
- V's quote shows where the press was made: Deposit's in place of the
  amount, Withdraw's and Send Out's in place of their buttons. It used
  to open as a section at the top of the sheet, out of sight of someone
  scrolled down to Deposit, so the press looked dead. While a quote
  holds, the sheet reads the chain every 10 seconds, so ETH arriving at
  the address turns the quote's button on without Refresh. While the
  address holds no ETH, Deposit's section says a deposit is paid in ETH
  from the address above and that Deposit shows how much.
- A wallet request that got no answer no longer says "The request may
  have been paid for": a read or a quote says nothing was sent, and an
  approve says it may have been sent and that the Wallet shows it once
  the chain does.
- Seen rendered from the app's own views, off screen; 34 checks pass.
- Release 0.6.0 prepared: the release number raised and the notes
  written for the friends' build (four kinds of chat and the Modes
  button; V and its deposit; Token Inference as Anon's new name; Local
  Llama while paused and its chosen model; the model as its own
  download; NEAR's token counts). Venice's screens and NEAR trace
  sharing are not in it.
  Built as 0.6.0 (247), then again as 0.6.0 (252) from commit `6ca8f9f`
  with the fixes from Sean's first try of V's wallet: signed, accepted
  by Apple, 151,990,597 bytes, running on his Mac, and held unpublished
  until decision 40 in `docs/plan.md` is settled.
- Rows that end in a round symbol button sit level: the label was a few
  points high and the row taller than its neighbours in NEAR Private
  AI's wallet (Key), Details (Modes), Settings' NEAR key and each
  model's row. The button now overhangs the line of text, as the info
  button always has, through one shared `overhanging()` (Darkbloom's
  window had its own copy, now gone). The baseline change made for the
  Key row on 21 November did nothing and is removed.
- V's deposit amount: the dollar sign sits against the figure typed,
  and the box grows with it, instead of the figure floating at the far
  end of a wide box.
- Both were found and checked by rendering the app's own views off
  screen while the Mac was locked.
- V's deposit Review says its fee and total in dollars too, as "Up to
  0.0126 ETH, about $19.86", at the quote's own rate (the dollars asked
  for over the ETH quoted for them). A real quote on 21 November put the
  fee on a 5 dollar deposit at about four times the deposit, which ETH
  alone does not make plain. A withdrawal and a send name no dollars and
  stay in ETH. Seen rendered from the app's own view, off screen.
- The menu's symbols: macOS 27 hides symbols in menus unless an item
  asks for them, and macOS 26 shows them. Cloak leaves that to the Mac,
  so its menu matches the Mac's own on each.
- Two small things seen on screen: V's wallet headed its first box
  "Address" over a row also named Address, and now heads it "Wallet",
  as Token Inference's does; and in NEAR Private AI's wallet "Key" sits
  level with "Saved" beside it.
- Darkbloom's window is out of every release until its makers allow it
  (decision 36): its menu item, window, `show darkbloom` and all of its
  code are compiled only by `app/build.sh darkbloom`, the build for this
  Mac. `app/build.sh` with nothing after it, which is what
  `app/release.sh` runs, builds the app without any of it, and leaves
  `show darkbloom` out of the AppleScript dictionary it copies in.
- Token Inference shows who it uses: Boundless's mark and Tempo's, drawn
  from each site's own icon, in three places. Under Chat's box while the
  new chat is Token Inference, and beside "USDC.e on Tempo" in its
  wallet, they are a button whose note says how the two are used
  (Boundless runs the model; Cloak pays it for each request in USDC.e on
  Tempo from the wallet on this Mac, with no account at Boundless and no
  key to keep) and links to Boundless's own post about it,
  boundless.network/news/mpp-payments. On the Modes page the marks sit
  at the top of the Token Inference column, with a line and the same
  link under it. The note button takes any mark now, an `info.circle`
  unless another is given.
- Fixed: a deposit, withdrawal or send quote's expiry is read in
  milliseconds, as the payer gives it. The Mac read it as seconds, so a
  quote would never have shown as run out, its countdown would have been
  wrong, and a stale quote would have been sent for approval and refused
  by the payer instead of being quoted again. Found by trying the payer
  against the real chain and service through the real tor with no
  deposit (step 7's first pass, in `docs/plan.md`).
- zkAPI step 6, the guest half: the guest's payer answers the Mac's
  frames, so a V chat's wallet has something real behind it.
  - `C`, a call to a money route: only the sixteen exact method and
    path pairs the Mac uses reach the daemon, with the key and the
    management token added by the payer itself; anything else is
    answered 404 before the daemon sees it. A call never waits for a
    chat request's turn.
  - `V`, a read of the deposit: whether there is a note, whether a
    settlement is unfinished, and the note's number and expiry, and
    nothing else of the companion's. With the chain asked for, every
    value is read at the one block `latest` gave (its number and time,
    the vault's pause, the funding address's balance, the note's status
    and expiry), through the daemon's own route over Tor
    (`guest/pay/zz_cloak_chain.go`). A read that fails answers 502 with
    no part of the deposit.
  - `H`, the hold: a held chat request hears held once and released
    once, just before its key is asked for; one not held hears neither.
    Hanging up during a hold cancels the request with nothing sent or
    spent.
  - Checks: sixteen in `guest/pay/zz_cloak_pay_test.go` against
    stand-ins, run ten times over with the race detector; in the real
    guest, `tests/test_pay_frames.py`, and whole `C` and `V` frames
    from the agent's sandbox in `tests/test_escape_path.py`, which get
    no answer.
  - Not proven: a read while the real companion settles, and the chain
    read against the deployed vault. Both wait for step 7.
- A reading, with nothing built: `docs/near-share.md` sets out how
  NEAR's trace sharing admits a chat on a NEAR AI receipt, from the
  commons' public source. An app other than NEAR's Gateway can
  complete it as the source reads. It needs two choices first
  (decisions 38 and 39 in `docs/plan.md`): the shared message cannot
  keep Cloak's end-to-end encryption, and the chat goes to the commons'
  witness for redaction before the person can see the result.
  `docs/near-traces-incloak.md` now names the production enrolment
  routes.
- Venice's carrying part, with no caller in the app yet. The guest's
  sender takes four new requests: `venice` (one request to Venice's
  API through Tor as the conversation's identity, its answer handed on
  as it arrives in frames `L`, `P` and `A`), `venice_sign` (signs a
  Venice sign-in and nothing else), `venice_typed` (signs a transfer of
  USDC on Base and nothing else) and `venice_funds` (reads the
  address's USDC on Base through Tor). The host's `Sender.stream`
  carries the answer to the Mac, and ending it closes Venice's Tor
  stream.
  - Before anything leaves: the address must be https to api.venice.ai
    under /api/v1/ with no user name; only four header names pass; GET
    or POST only; no redirect is followed. No key, signature or header
    value reaches a stop's words or the log.
  - Found against Venice's four saved real answers: a 402 that carries
    Venice's sign-in challenge is a refused key or sign-in, not a low
    balance, and now reads so.
  - Checked by the chief after the merge: the sender's 18 checks pass
    in the pinned Rust image with no network, the app's 33 checks pass,
    and the host builds. The guest image is not rebuilt yet.
  - Unproven until a key or money is used: a key sent from a Tor exit,
    Venice taking Cloak's signed sign-in, Base's public address through
    Tor, a $5 top-up settling, and what a cut stream is charged.
- NEAR Private AI answers show the tokens NEAR counted for them (the
  public page's "See where your tokens go"; the chief's choice of 20
  November 2026: counts only, never a price). A small mark at the end of
  an answer's title line says, in its tooltip and to VoiceOver, "1,204
  tokens in, 356 out"; the NEAR Wallet sheet has a "Tokens" row with the
  open chat's totals. The counts are NEAR's own, from the `usage` it
  returns with each answer, saved sealed with the chat. An answer whose
  reply has no counts shows none. Nothing sent to NEAR changed.
  - Checked by the chief after the merge: the app builds with no
    warnings and its 30 checks pass. Not yet seen on screen, and not yet
    seen against a real NEAR answer.
  - Known: a message sent twice keeps only its last answer's counts, so
    a chat's total can read low; "in" counts the whole chat again with
    each message, as NEAR counts it.
- A Darkbloom window (Sean, 20 November 2026, his pasted review of
  Layr-Labs/d-inference v0.10.16 and "add this as a new section to the
  app"). Held out of every release until Darkbloom's makers give written
  permission (`docs/release.md`, Standing limits); never yet run against
  the real Darkbloom, which is not installed on Sean's Mac.
  - "Darkbloom" in the menu, and `show darkbloom` in AppleScript, open a
    window that sets Darkbloom up, offers the one model that fits beside
    Cloak, starts and stops serving, shows the local address and key for
    other apps, and can also serve Darkbloom's network ("Serve Network",
    off at first, linked by a code entered on Darkbloom's own page).
    Nothing of Darkbloom's runs until the window first opens, and Cloak
    adds no login item.
  - Install fetches Darkbloom's own installer from api.darkbloom.dev at
    that moment and runs it, as Darkbloom's own app does. Before Cloak
    runs anything of Darkbloom's it checks the signature against
    Darkbloom's developer team with the system's own check, and takes
    release 0.10.16 or later only.
  - Start serves with the person's requests kept on this Mac and the
    address open to this Mac only (`--local --route this-mac --bind
    127.0.0.1`, or `--me-first` with Serve Network on). A setup made
    outside Cloak that Start would change is listed first, and Start
    asks. The window says what it can read of where requests go, and
    "Can't confirm" when it cannot.
  - Darkbloom needs macOS 27; on an older system the window says so and
    offers nothing else.
  - Checked by the chief after the merge: the app builds with no
    warnings and its 30 checks pass. The worker ran 46 checks against a
    stand-in control service and 7 process checks, none of them kept.
  - The licence (Eigen Labs, at v0.10.16), as it reads: section 1
    forbids using the software "to power, enable, or operate any
    service, platform, or product other than the Darkbloom platform"
    without written permission; section 6 gives no right to the name
    beyond attribution. Serving Darkbloom's own network is allowed.
- Four modes, and zkAPI step 6's Mac half (Sean, 20 November 2026:
  "25. a", "26. a" and his own design for decision 28). Not in Sean's
  running Cloak, and V cannot pay yet: the guest's payer does not answer
  the new frames until step 6's guest half is built.
  - Chat's modes are V, Token Inference, NEAR Private AI and Local
    Llama. V pays only through zkAPI, with ETH on Ethereum, each request
    with a new key. Token Inference is what V was until now: reworded on
    the Mac, sent through Tor, paid from the one USDC.e wallet on Tempo,
    with the line "The provider can link your chats, because one wallet
    pays for all of them." A saved chat stays the mode it began in; a
    chat saved before today reads as V.
  - Agent is a switch in V and in Token Inference, and an agent pays the
    way its chat pays. Other apps through the door pay from V's deposit,
    behind Chat's own requests.
  - V's wallet sheet: the payer's address with Copy and a code, ETH on
    hand, Send Out…, the deposit with its balance and expiry, Deposit,
    Withdraw (always to the payer's own address, decision 23) and the
    model. Every money press asks the payer for a quote and shows it;
    the review's button is the one place an approve is sent from, and an
    expired quote is quoted again and shown, never approved unseen. A
    money button is off only where the chain at the latest block read
    shows the press certain to fail, with why beside it.
  - Start opens Chat. A first-time owner sees the Modes page, four
    columns with what each mode needs and gives; Details opens it again.
    The old Welcome page is gone.
  - Each run's guest gets the payment disk: a 1 GB sparse image under
    the support folder's `pay/`, its key a new item in the login
    keychain (`sh.regents.cloak.paydisk`). The Mac holds the disk's key
    and no payment secret.
  - The Mac's end of the payer: `host/Sources/CloakHost/Pay.swift`
    (port 8021; frames `R`, `C`, `V`, `H`, `A`), `PayQueue` (one request
    out at a time, Chat's before the door's), `Payer` (the wallet's
    state from one read, never stored). The exact frames are in
    `docs/zkapi-mac-side.md`, section 1, which the guest half is built
    to.
  - Checked by the chief after the merge: the app and the host build,
    and 30 checks pass, nine of them new in
    `app/Tests/CloakTests/PayTests.swift` against a stand-in payer
    (money moves only on a press; opening, refreshing and following send
    no quote and no approve; one request out at a time in its order;
    nothing is sent before rewording; a hold that goes quiet ends with
    nothing sent).
  - Not yet seen on screen, and unproven against the real payer.
- Venice (venice.ai), first pass, with nothing on screen yet (Sean, 20
  November 2026, his pasted review and "make a new subagent, as before,
  that works on this"). `app/Sources/CloakChat/Venice.swift` and
  `VeniceWallet.swift` have no caller in the app: Venice's live model
  list with Venice's own tier names, the key check, a streamed chat that
  sends nothing when the chat's model is gone, swapped or at another
  tier, sixteen plain stops made from the status and documented codes
  alone, and the wallet route's sign-in and top-up messages (USDC on
  Base only) over a signer the caller gives. `docs/venice.md` is the
  plan for joining it to Token Inference once the four-mode work is
  merged, and the size of verified encryption, which is not built.
  - Checked: 7 checks in `app/Tests/CloakTests/VeniceTests.swift` (a
    moved model sends nothing; a chat carries exactly its fields; the
    key never reaches a stop's words; the wallet's messages match
    Venice's examples byte for byte), and 41 against a stand-in server.
  - Found by the chief on 20 November with the repository's own tor and
    no key: Venice's public model list answered 200 through Tor on three
    fresh circuits, and a chat with no key was answered 402 with
    Venice's payment challenge. A request with a key through Tor is
    untried.
  - Unproven until a key or money is used: Venice's real answers to a
    paid chat, the payment header's exact form, and whether stopping a
    message stops its charge.
- zkAPI step 5: the real companion and its proving keys are in the
  guest, and the payer starts when the payment disk opens (Sean, 20
  November 2026, "all of this work needs to be done asap"). No network,
  no money and no real key yet.
  - `guest/build.sh` builds the pinned companion (`zkapi-walletd` with
    its protocol submodule) in Docker as `cloak-pay-walletd`: crates
    fetched first, which runs none of its code, then compiled with no
    network. It and the four proving keys ship read-only in the image at
    `/opt/zkapi`, where the daemon looks. The image grows by 19.7 MB
    packed and 35.2 MB in memory; the payer at rest uses about 23 MB.
  - After "cloak-guest: payment disk open" the boot starts the payer in
    a network namespace of its own (`unshare -n`), with a Tor port of
    its own, and prints "cloak-guest: payer ready"; a payer that does
    not start ends the guest with its log on the console. The
    companion's port 8790 and the payer's own proxy are on a loopback
    the agent's sandbox does not have. With no disk, no payer starts and
    the boot is as before.
  - `cloak-pay` starts the companion as the daemon's own serve does,
    waits for it, logs "wallet: no note" or "wallet: a note", and has
    the daemon's `FundingHandler` wired in for step 6. If the companion
    ends, `cloak-pay` ends.
  - One change to upstream's companion, `guest/pay/companion-start.patch`:
    its call to the service's `/health` before it listens is taken out,
    since the guest has no network at boot and the call ended the
    companion. Whether the service takes requests now shows at the first
    request.
  - Checked on Sean's Mac in the real guest: `tests/test_pay_disk.py` 7
    passed (a new disk reads "no note"; after a kill and restart it
    reads "a note" with every file untouched; no disk starts no payer),
    `tests/test_escape_path.py` 14 passed (from the sandbox, three
    requests to the companion get no answer, the payer's port refuses
    all three addresses, its files cannot be read),
    `guest/image/pay-disk-check.sh` passed 10, `guest/pay/check.sh` ok,
    `tests/test_tor_path.py` 10 passed (one real-Tor fetch was reset on
    the first run and passed alone on the second).
  - `tests/test_pay_path.py` is removed: it was written to wait for the
    payer at boot, and its checks now run in `tests/test_escape_path.py`.
  - Known: nothing watches the payer after "ready", so if it stops later
    the guest keeps running; memory during a real proof in the 1 GiB
    guest is not measured (129 to 165 MiB in the 15 November trial); the
    companion's route through the payer's Tor port to the real service
    is untried (step 7).
- Local Llama answers from a model you choose, and Inkling 2 Mini is the
  second on the list (Sean, 20 November 2026, "20. a - build now", then
  "I want to urgently add in support for local mode to use the inkling
  mini model"). `reference/models.json` marks the entries that can
  answer (`answers`: label, memory, context): today's Qwen 3.5 9B, and
  `inkling-mini-gguf`, ggml-org's IQ4_NL file of Thinking Machines'
  Inkling 2 Mini (17.6 GB, checked file for file like today's). Settings
  has a "Local Llama" pane: a row for each model with its size, "Best
  for this Mac" under the largest that fits, rows that do not fit
  dimmed, and symbols to download, pause and remove. The chosen model
  runs in a second copy of the same worker beside the rewording one, so
  its memory is counted on top of Qwen's. No fallback: a chosen model
  that is missing, changed or too large stops the chat ("Choose a model
  in Settings." / "This Mac can't run the chosen model." / "Download
  the model to ask."), never another model's answer. Rewording is
  unchanged: Qwen 3.5 9B under the reply grammar, always.
  - An answer's thinking is told apart by llama.cpp's own reply parser
    and dropped: not shown, not saved. A reply with no answer in it is a
    failure, never an empty answer.
  - `app/release.json` loses `model_label` and `model_memory_gib`; the
    manifest carries `model` and `answer_models` from the pins.
  - Proven by hand on Sean's Mac with the new worker: Qwen rewords under
    the grammar (8 s with loading) and answers; Inkling 2 Mini loads in
    16.5 s, answered a two-message chat with no thinking in either
    answer (14.2 s and 3.6 s), and a rewrite sent to it is refused. With
    llama.cpp's own tool it ran at 36.5 tokens a second using 16.8 GB.
    Not yet seen: the new pane, and a Local Llama chat with Inkling in
    the app.
  - Known: Inkling thinks before every answer (365 tokens for a
    greeting), and nothing shows while it does; its thinking effort is
    still the template's default. A reply cut off while thinking shows
    "The model stopped." with advice about memory, which is wrong for
    that case. Counted beside Qwen it needs about 27 GiB, so a 32 GB Mac
    will most likely show it dimmed.
- llama.cpp moves from build b12556 to the head of its pull request
  32694, "Inkling 2 Mini" (commit `d7cb78c9`), which adds the model's
  looped architecture; no numbered build has it yet. The change was
  approved by a llama.cpp maintainer with all 28 of its checks passing
  when pinned, and it sits 22 commits after b12556 on master. Cloak
  moves to the first numbered build that holds the merge.
- zkAPI build step 4, the encrypted disk (stand-ins only; nothing in the
  running product changes, and the app attaches no disk until step 6).
  The host can attach one image file to the guest as its only disk,
  fully synced, with a 32-byte key in the boot files; the guest opens it
  with cryptsetup (LUKS2, AES-XTS), mounts ext4 with `sync` for the
  payer's user alone, and deletes the key file (`guest/image/pay-disk`).
  A blank image is formatted only when the host says it is new and its
  first 16 MiB are zero; a disk that does not open stops the guest with
  the reason and is never reformatted.
  - Checks, run by the chief on the real guest: `sh
    guest/image/pay-disk-check.sh` 10 of 10; `tests/test_pay_disk.py` 5
    passed (files survive a killed host; a wrong key, two damaged
    header copies and a used image called new each stop with the image
    unchanged; the image holds none of the plaintext);
    `tests/test_escape_path.py` 13 passed, with the sandbox's attempts
    on the payment files, the raw disk, the mapper nodes, the key file
    and the kernel's keys all failing; `sh guest/pay/check.sh` clean.
  - Not proven: a Mac power cut (a killed host cannot tell full sync
    from none, since macOS keeps the writes cached). Known: AES-XTS has
    no integrity check, so a tampered image garbles or fails to mount
    rather than being refused; one damaged header copy is repaired by
    cryptsetup on open, which changes the image; the key sits in a 0600
    boot file on the Mac for about a second at start.
- Symbols in place of words across the app (Sean, 20 November 2026:
  "In general I want the UI to be as minimal in text as possible, with
  text on tooltips and dropdown texts. The UI should be 'Apple'-like,
  with symbols and minimalism."; his "18. a" to the 22 changes listed
  for him). Reword and Send on a card are a pencil and an up arrow; Send
  Original Text and Never reword are in a drop-down beside Send; the
  three marks on a card, the Tor and zkAPI pills, Run Again, Ask Again,
  Check Again, Refresh, Copy, the NEAR key's Replace and Remove, and
  Agents' Add are symbols with their words as help and for VoiceOver;
  every explanation under a setting is behind an info button; the menu
  has a symbol beside each item; the empty chat's paragraph and the
  Local Llama line under the box are gone, their words in the Modes
  note; Welcome is the crown, one line and Done. Money buttons (Create,
  Close, Withdraw), dialog buttons, failures and the two Details phrases
  keep their words. New: `SymbolButton.swift`, `InfoButton.swift`.
- Anon is V (Sean, 20 November 2026: "rename in the app from Anon mode
  to V mode"), and Agent is a switch inside V, not a fourth mode (Sean:
  "I wanted 'V mode' to fully cover both the external requests ... as
  well as the internal agent in a box ... if a user is on V mode, then
  and only then they should also see 'Chat with local agent?'"). The
  mode switch has three segments, each its symbol, the chosen one its
  name too; in a new V chat a hammer pill beside it turns Agent on. It
  is named Agent, not "local agent", since a remote model does its
  thinking, and its help says so. Saved chats are untouched.
- Cover is one toggle in Chat's toolbar, in every mode (Sean,
  20 November 2026: "if the cover traffic toggle is on every mode, then
  it should be extracted out to somewhere else in the UI, and on by
  default"). It was on by default already. A clock sits on it while a
  change waits for Pause, then Start. Settings keeps its row.
- Review and Never reword are never both on: turning either on turns
  the other off, and they sit together in Settings, General (Sean,
  "17. a - but maybe if the auto send is toggled, it auto-toggles the
  other setting. and vis versa. so the two should be placed next to
  each other in settings"). A card's Reword only rewords: with Review
  off it used to send as well.
- The NEAR key's Remove asks first. "Preparing" is "Starting"
  everywhere, `cloak status` included. The Help words to copy no longer
  use a word Cloak does not claim.
- Seen on Sean's Mac, 20 November: the empty V chat with its switch,
  Agent pill and toolbar Cover; Settings, General; Agents; Details. Not
  yet seen: a card's symbols, the Wallet sheet, NEAR and Local Llama
  chats, the Modes note, the menu, Welcome, the Cover clock.
- The app is named "Cloak" on the Mac (Sean, 20 November 2026: "the
  name of the app should be 'Cloak', and the minimized app should say
  'Cloak - [view]'"). The bundle is `Cloak.app` and its menus, launch
  stops, status lines, `cloak` command and AppleScript dictionary say
  "Cloak". A minimized window reads "Cloak - Chat", "Cloak - Agents",
  "Cloak - Details" or "Cloak - Settings"; Agents, Details and Settings
  can now be minimized. Unchanged on purpose: the bundle identifier,
  the executable, the support folder "Regents Cloak", every keychain
  item, the download's file name, the update feed and its key. In code
  only: it compiles and its 14 checks pass, but no app has been built
  from it and none of it has been seen on screen. A tester who drags
  the new `Cloak.app` into Applications gets it beside the old
  "Regents Cloak.app"; a copy that updates itself keeps its old file
  name with "Cloak" in its menus. Nothing is done about either: no one
  is testing the app yet (Sean, 20 November 2026: "no one is testing
  the app yet, so dont worry about older versions").
- Details says what Running and Paused each mean, under Status (Sean,
  20 November 2026: "its pretty unclear what the difference is between
  the app being paused vs running", then "can it be a short phrase for
  each in 'Details'"): "Running: Tor is connected. Anon and Agent chats
  can send." and "Paused: Tor is off. Anon and Agent chats wait." Seen
  on Sean's Mac in both states.
- A log for testing on this Mac (Sean, 20 November 2026: "it seems to be
  crashing, can you add error logs or something?", then "no, just for
  local testings"; it had not crashed: the chief had closed it four
  times in twenty minutes to rebuild it). The app's state changes were
  written at a level the Mac's log drops within the hour; they are now
  kept, with "opened <release>" at launch and "quit" at a clean end.
  `app/log.sh [minutes]` prints them and the crash reports macOS has.
- Release 0.5.4 (179) published for invited testers, 20 November 2026
  (docs/release.md, "Releases so far").
- zkAPI payment, build order step 3: `cloak-pay` holds a request while
  an earlier one's settlement is unfinished (this run's or one an
  earlier run left), serves requests one at a time in order, drops a
  request whose host hangs up with nothing sent or spent, and ends
  cleanly on SIGTERM. Stand-ins only; the running product is unchanged.
  `docs/plan.md`, "Step 3, holding during settlement".
- The Wallet sheet says how the chat in front is paid for (Sean, 20
  November 2026: "for the wallet menu, is it applicable at all for the
  near ai and local modes? ... if local mode is selected , it should
  show in that menu for user awareness"). An Anon or Agent chat: the
  wallet, as before. A NEAR Private AI chat: that the owner's NEAR key
  pays, a link to cloud.near.ai, whether a key is saved, and Open
  Settings, which shows Settings on its NEAR pane (the pane shown now
  lives in `SettingsView.Selection`, so the app can choose it). A Local
  Llama chat: nothing to pay. The wallet is read only when the sheet
  shows it. A balance or deposit not read keeps its dash, and the
  pointer resting on it says why: "Start Cloak to load the wallet
  balance." (first built as words in the dash's place; Sean, the same
  day: "adding a phrase instead of a - is not good. it can be a dash
  with a mouseover tooltip"). The model
  picker's rows are "name: $in | $out" (his words: "these can be
  simplified to be 'model name: $price-in | $price-out'"); the prices
  are the provider's own list, read while Cloak runs. Seen on his Mac:
  the sheet in each of the three modes while Paused, and Open Settings
  landing on NEAR. Not seen: the picker's rows with prices, which need
  Cloak running.
- A hover on what can be clicked (Sean, 20 November 2026: "can you add
  subtle onhover effects to anything that is clickable? like hovering a
  chat thread here, there should be a visual indicator it is
  clickable"). One modifier (`Hover.swift`): a faint fill, 8% of the
  label colour, fading in 0.12 s, none while a control is off. On the
  rows of Chat's and Settings' sidebars (the size of the selection's
  highlight, none on the chosen row), the Agents window's rows that
  open, every borderless or plain button (Modes, the Dismiss crosses,
  Copy, Remove, the QR code, Clear Shortcut), the Cover, Tor and zkAPI
  pills and NEAR's Tor, and the details pills, chips and swatches. What
  macOS draws keeps its own look: push buttons, the round Send and Stop,
  toolbar buttons, switches, pickers, links and menus. The sidebar's
  three marks say what they are when the pointer rests on them: "Agent
  chat" (the hammer he asked about), "NEAR Private AI chat", "Local
  Llama chat". Seen on his Mac: a chat row, a Settings row and the Cover
  pill under the pointer. Release 0.5.4.
- Release 0.5.3 (172) published for invited testers, 20 November 2026
  (docs/release.md, "Releases so far").
- The app no longer ends by itself (20 November 2026). At 11:18:41 on
  Sean's Mac the published 0.5.2 was ended by macOS with SIGPIPE, forty
  seconds after a Start and with no crash report: the app writes to its
  worker's pipe and to the guest's connections with code that expects a
  write to a gone peer to fail, as `cloak-host` and the worker arrange
  by ignoring that signal, and the app never did. It now ignores it at
  launch. Tried: Start, two minutes Running, Pause, the same process
  throughout.
- The modes renamed, and a Modes button (decision 19, Sean's "13" of 20
  November 2026): Anon, NEAR Private AI, Local Llama and Agent. The
  button beside the switch opens on a press or a rest of the pointer and
  says where the first three come from, with links to Vitalik's, NEAR's
  and llama.cpp's posts on X. `LlamaNormal.swift` is `LocalLlama.swift`.
  What chats and the worker's frames hold is unchanged.
- Settings, General ends with Feedback and Help: a link to
  https://patchbay.help/regents.sh, and words to copy for an agent that
  posts there, naming the release.
- Chat's Cover, Tor and zkAPI pills are all buttons now, the dot changes
  with a short animation, and a pointer resting on one for a second
  shows what it controls (the app sets macOS's help delay to one
  second). Tor and zkAPI still cannot change; a press shows "Tor stays
  on in Anon chats for now." or "zkAPI payment isn't in this build yet."
  Cover's words say a change comes "after Pause, then Start", since
  "the next Start" read as reopening the app. Release 0.5.3.
- Release 0.5.2 (170) published for invited testers, 20 November 2026,
  with the icon and the install window; the image was opened on Sean's
  Mac and shows the app, the arrow and Applications (docs/release.md,
  "Releases so far").
- The app has an icon, and the disk image opens as an install window
  (decision 18, Sean's "11. a" of 20 November 2026). The icon is the
  design system's flat crown on a near-black tile, drawn by
  `app/art.swift` and committed as `app/AppIcon.icns`; `app/build.sh`
  copies it and `Info.plist` names it. `app/release.sh` now makes a
  writable image, mounts it out of Finder's sight, has
  `app/install-window.py` lay out the app, an arrow and Applications
  over `app/install-window.tiff`, and compresses that. Release 0.5.2.
- Release 0.5.1 (168) published for invited testers, 20 November 2026:
  Llama Normal chats and the modes' new names. The first update from
  one release to the next was tried on Sean's Mac and worked: the
  published 0.5.0 found 0.5.1, installed it and reopened Paused
  (docs/release.md, "Releases so far").
- Llama Normal chats, and the modes renamed (decision 17, Sean's "5. a"
  of 20 November 2026). A new chat's mode is one of Anon V, NEAR
  Privacy, Llama Normal and Agent. In a Llama Normal chat the model on
  the Mac answers each message as written, with the conversation so
  far, through llama.cpp's chat template and default sampling; nothing
  leaves the Mac, and it needs only the model downloaded, not Start, a
  wallet or Tor. The worker takes a new kind of frame, `L`, for a
  conversation, which only the app sends; the relay forwards a guest's
  request as `R` alone. While no run is up the supervisor starts the
  worker for the first message and ends it before a Start; during a run
  messages take their turn at the run's worker. A chat and its answer
  are capped at 19,456 tokens, the most a rewrite has been measured to
  take, and a chat that no longer fits says so. Answers arrive whole.
  `scripts/drive_worker.py` gains `--chat`, `--stop-after` and
  `--worker`.

- Every build on this Mac is signed with the Developer ID (decision 16,
  Sean's "8. a" of 20 November 2026): `llama-worker/install.sh` signs
  the worker so, into its sandbox, and `app/build.sh` signs every other
  part so, both under the hardened runtime and with a secure timestamp,
  with the identity `app/release.json` now names. `app/build.sh` takes
  no argument, its ad hoc branch is deleted, and it checks every build
  for the hardened runtime and a timestamp. macOS keeps the worker's
  sandbox folder for the team that signs it, so an ad hoc worker here
  would have had macOS ask again whether to open "(null)".

- The first release, 0.5.0 (164), made with `app/release.sh` and
  published with `app/publish.sh` on 19 November 2026 from commit
  `e19db9e`: Apple accepted the app and the disk image, Gatekeeper
  accepts the image as downloaded from `regents-ai/cloak-releases`, the
  feed's signature matches the update key in the app, and the signed
  build starts and rewords on Sean's Mac. The notary sign-in is saved as
  the keychain profile `cloak-notary`. `app/release.sh` now makes the
  image with `diskutil image create from`, since this macOS marks
  `hdiutil create` for removal. Not yet shown: a first run on a Mac that
  never had Cloak, and an update from one release to the next.

- A signed, notarized download of Regents Cloak, with updates, for the
  friends Sean invited (his answers of 19 November). `app/build.sh`
  takes one optional argument, a signing identity: with it, every part,
  tor, libevent, NEAR's helper and the worker included, is signed with
  that identity under the hardened runtime and with a secure timestamp,
  the worker into its sandbox, before the manifest pins it, and the
  build stops if any program in the bundle lacks either; with none, it
  signs ad hoc as before. `app/release.json` names the update feed,
  `appcast.xml` in the new public repository
  `regents-ai/cloak-releases`, and the update key's public half, so
  every build has an updater, and the app's allowance for a build with
  none is removed (`Updates`, the menu, Settings); the release is 0.5.0.
  `app/release.sh` builds with the Developer ID, has Apple notarize the
  app and then a disk image holding it, staples and checks both, and
  writes the feed with Sparkle's `generate_appcast`, keeping earlier
  releases and embedding `app/release-notes.md`; it uploads nothing.
  `app/publish.sh` creates the GitHub release with the image, under its
  own name and as `Regents-Cloak.dmg` so one address always downloads
  the newest, then puts the feed on that repository's main branch, and
  waits until the public feed names it. Neither script has been run
  yet. The technical preview carries Development mode, labelled, as
  stage 1 of `docs/release.md` says; decision 10 and the README now say
  "the public release" where they meant stage 2's.

- llama.cpp moves from release v1.0.0 to build b12556 (commit
  `50518b64`, 197 commits later, published 19 November 2026), at Sean's
  word to update to the latest. Of what changed, Cloak builds the fixes
  in Metal (an overflow in a matrix multiply's destination offset, a
  range argument), the faster grammar matching, the lighter chat
  template rendering and the context's cell bookkeeping. llama.cpp now
  marks `llama_decode` and `llama_batch_get_one` for removal, so the
  worker feeds the model through their replacements, `llama_process`
  and the `llama_batch_ext` calls, setting each token's position
  itself; the build has no warnings. Proven by hand on the small lead:
  a short pair of messages reworded in 1.0 s and a 576-token prompt,
  read in two pieces, in 3.7 s, both replies passing the grammar. No
  stage 3 or stage 4 score was re-run on the new build; those records
  stay as measured on v1.0.0.

- The rewording worker ships inside the app. `app/build.sh` copies the
  worker that `llama-worker/install.sh` built and signed into the
  bundle, and the manifest pins every part in the bundle, with no place
  for each. At each Start, once the checks pass, the app copies its
  worker to `~/Library/Application Support/Regents Cloak/worker/` when
  the file there is missing or not the pinned one (written under a new
  name, then renamed over it), checks it against the pin, and runs it
  from there, since the worker's sandbox cannot start a program kept
  under `~/Documents` or `~/Downloads`. Start no longer needs
  `llama-worker/install.sh` to have run on that Mac. This is the first
  step toward a build Sean's friends can download (his word, 19
  November).

- Settings: the four descriptions in the NEAR pane are rewritten as
  whole sentences that say what each setting is and does (where the key
  comes from, what Tor changes and costs, what the check is and what
  Freshness sets, what the check does not cover for the model). Every
  description under a setting, in every pane, can now be selected and
  copied.

- NEAR mode is in the Mac app. A new conversation can be NEAR's (Cloak,
  NEAR or Agent under the message box): each message goes as written to
  `Qwen/Qwen3.8-27B` on NEAR AI Cloud, paid by the owner's own NEAR key,
  once NEAR's hardware proof passes. `app/build.sh` builds the helper
  `cloak-near` from `guest/near`, signs it and puts it in the bundle,
  and the manifest pins it; the app checks that pin before each start
  of it (`CloakChat/Near.swift`, `RegentsCloak/NearMode.swift`). The
  key is typed in Settings, NEAR, kept in the login keychain and never
  shown again. Tor for NEAR is a switch, off until turned on, and needs
  Cloak running; Freshness chooses how long a passed check is used
  again (10 minutes until chosen). The check runs when a NEAR
  conversation shows, and its result is beside the Tor pill. Send is
  off only with no key saved or with Tor on while Cloak is not running.
  A message that stops says why and whether it may have reached NEAR;
  nothing then goes another way. One check, `NearTests`: the line to
  the helper carries the freshness and route chosen. Seen in the
  installed app with no key saved; no message has been sent from the
  app yet.

- `reference/near-pins.json` gains a fifth model set. On 20 November at
  about 02:07 UTC NEAR's gpu13 server for `Qwen/Qwen3.8-27B` began
  presenting the compose of the fourth set (but for its label and the
  compose's name line), so the app's first check was refused. The
  change was read, the set added, and a fresh keyless check passed.
  This is the second such change in one evening.

- NEAR mode: `cloak-near`, the helper the Mac app will start
  (`guest/near`, `src/bin/cloak-near.rs`, `src/helper.rs`). One request
  a line on standard input, one answer a line on standard output: a
  `check` fetches and checks the proof and sends nothing to the chat
  endpoint, with no account key; an `ask` checks, then sends. Each
  answer says whether the chat request may have reached NEAR. The route
  is direct, or tor's SOCKS socket file with an identity for NEAR and
  one for Intel. The account key comes only inside an `ask` line and is
  never kept, logged or quoted; NEAR's error text has the key replaced
  before it is cut short, not after. The proof age is now given with
  each `ask` and `check`; a new check for a model drops its kept proof
  first. A chat connection that could not be opened is its own stop,
  `connect`, with nothing sent. Live with Sean's key, 20 November,
  `Qwen/Qwen3.8-27B`: direct, a check in 3.5 s and two answers in 11.7
  and 3.1 s; through a tor on a socket file, a check in 24 s and two
  answers in 17 and 18 s. 31 offline checks pass. Not yet built into
  the app or signed.

- NEAR mode (`guest/near`): a direct route beside Tor (`Route::Direct`,
  the probe's `--direct`; NEAR and Intel then see the Mac's internet
  address), by Sean's word that NEAR mode need not use Tor. Through
  Tor, a connection that cannot be made is made again on a new circuit,
  three at most, before any byte of a request is written; NEAR's 502
  from its token endpoint is asked again, three asks at most. A model
  server is now pinned by the SHA-256 of its compose file without the
  digits of its own `INSTANCE_LABEL=gpu` label (exactly one label, one
  to four digits, or it is refused); MRCONFIGID must still equal the
  whole compose's hash, and the gateway's pin is unchanged.
  `reference/near-pins.json` gains a fourth model set, the server NEAR
  added on 19 November. The kept proof no longer holds a second copy
  of the gateway key hash. Live with Sean's key, three "ping"s on one
  check to each of two models: direct, six of six answered in 3 to 14
  s; through Tor, six of six, 43 and 49 s for the first of each and 3
  to 31 s after. 28 offline checks pass.

- NEAR mode: a passed proof is kept and used again for a chosen time, an
  hour at most, none by default (`guest/near`, `Kept::new(max_age,
  proof_age)`). A request under a kept proof still goes only on a
  connection showing the gateway key that proof checked, sealed for the
  model key it checked; the hardware was checked up to that long before,
  not at the moment of sending. Another gateway key or a reply that does
  not open forgets the proof. `Answered` says when its proof passed; the
  probe gains `--proof-age` and `--repeat`. Live through Tor with Sean's
  key (19 November): three "ping"s to `z-ai/glm-5.3-flash` on one check,
  43 s, 28 s and 24 s, so the check is about 15 s and the model's
  unstreamed answer the rest. Found the same evening: NEAR added a second
  `Qwen/Qwen3.8-27B` server whose compose file differs from a pinned one
  only by its server label and telemetry address, and it is refused;
  every server's compose carries its own label, so pinning whole compose
  hashes cannot last. And: every Intel fetch of one check shares one Tor
  circuit, so one bad exit fails the check; on ten separate circuits
  each, Intel's three hosts answered ten of ten.

- NEAR mode, first real requests with the GPU check on (19 November,
  through Tor, Sean's key, "ping"): one of six was answered and opened
  (`z-ai/glm-5.3-flash`, 3 servers and 8 GPUs checked, 71 s). The other
  five stopped before anything reached the chat endpoint: four because
  the Tor exit could not reach Intel's hosts, one on NEAR's own 502 from
  Intel Trust Authority. Too unreliable and too slow to put in the app
  as it is; next is keeping a passed proof for a set time, so Intel is
  asked once and not for every message.

- Checks cut to three things: money, break-outs and proof before sending
  (Sean, 19 November: "I want to delete many tests, the pace of
  development is too slow"). Deleted: `tests/test_llama_worker.py`,
  `tests/test_guest_path.py`, `tests/test_agent_path.py`,
  `tests/test_task_path.py`, `tests/test_cover_path.py`, the Go helpers
  `tests/daemon_reply` and `tests/daemon_transcript`, and the app's
  `DoorTests`, `DoorGuestTests`, `StoppedRewriteTests` and `Fixture.swift`
  (78 checks, 2,480 lines). Kept: the escape and Tor checks, the payment
  checks, the sender's, the app's send and wallet checks, and
  `guest/near`'s. No longer checked by anything: the model worker, the
  rewrite path through the guest, Pi's tasks, cover traffic, the app's
  door, and that a rewording which stops sends nothing. `AGENTS.md` and
  decision 15 in `docs/plan.md` carry the new rule.

- Chat: three pills under the message box, Cover, Tor and zkAPI, each
  showing on or off (Sean, 19 November). Cover is a switch, on until
  turned off; off, the next Start lays a cover list with no pages over
  the image's and the guest's daemon starts no cover worker, and Chat
  says "Cover changes at the next Start." while the run and the setting
  differ. Tor shows on and zkAPI off; neither can be changed yet ("Always
  on for now.", "Not available yet."): a Tor switch and a choice of
  payment come after private payment and NEAR are in the app, by his
  answers. Settings, General gains Cover traffic, Review (off, a
  reworded message is sent as soon as it is reworded) and Saved chats
  (off, chats started or continued are not written to disk and are gone
  when Cloak quits; chats already saved stay until deleted, and a chat
  touched while it was off stays unsaved until Cloak quits). Restore
  Defaults turns all three on. Seen on screen: the pills and the
  Settings pane; with Cover off at Start the app reported no cover
  worker. Not exercised: Review off, Saved chats off.

- NEAR mode: the GPU check moves to Intel's signed tokens, and NVIDIA's
  service is gone (`guest/near`, `gpu.rs`). NEAR's front server asks
  Intel Trust Authority for two tokens under our nonce; Cloak fetches
  them and Intel's key list through Tor and checks, itself: each
  token's signature, issuer and times; that the front server's quote in
  the token is over Intel's nonce and our own; that every GPU's
  evidence is under the hash of that same nonce; Intel's verdict; and
  each GPU's measurement, secure boot, debug and certificate claims.
  Said plainly in the README: the verdict covers the GPUs of one server
  NEAR picks, and nothing ties them to a server whose quote Cloak
  checked; evidence may be five minutes old; it rests on Intel's online
  service. Cloak still checks every Intel quote itself. Live through
  Tor, no key: six of seven runs passed with 8 GPUs each, 17 to 27
  seconds; one stopped because its Tor exit could not reach Intel.
  NEAR answered 502 to 2 of 8 token requests for one model. Nothing
  retries. Sixteen proof checks and four request checks pass.

- NEAR mode: the GPU check, built, and stopped by NVIDIA most of the
  time (`guest/near`, `gpu.rs`). Each server's NVIDIA evidence must name
  our nonce before it is posted to NVIDIA's service; the tokens that
  come back, the overall one and one for every GPU, are checked on this
  side: ES384 under a key NVIDIA lists, issuer, times, our nonce, the
  overall result, and each GPU's measurement, secure boot and debug
  claims. `ask` now needs both proofs before it sends, with no way
  around the GPU (`Proof { intel, gpu }`; `CpuOnlyProof` is gone). Eight
  more gate checks against a real set. Live through Tor on 19 November
  NVIDIA answered 403 on 7 of 8 circuits, before it looked at anything,
  so as built a request stops at NVIDIA most of the time; the one
  circuit let through passed every check, 8 GPUs, in about 2 seconds.
  Nothing retries or goes around Tor. The fixture's list of NVIDIA's
  public keys was fetched directly, not through Tor. The first real
  requests the same evening were made with the build before this one.

- NEAR mode, first real requests (19 November, with Sean's own key,
  handed over through the secure prompt and read only by the probe):
  through Tor, the proof passed and the encrypted word "ping" was
  answered 200 and every encrypted field of the reply opened, for
  `z-ai/glm-5.3-flash` (three servers, 32 seconds in all) and
  `Qwen/Qwen3.8-27B` (one server, 24 seconds, twice). So NEAR takes the
  version 2 encryption in all-fields mode for both, and a real reply
  opens. Three requests of a few hundred tokens were spent.

- NEAR mode: the request (`guest/near`, `ask`). One call, in one order:
  the request is checked, the proof fetched under a fresh nonce and
  verified, and only then the request sent, on a new connection taken
  only if its certificate key is the one the proof bound. Every message,
  tool and tool call is encrypted for the model's checked key (NEAR's
  version 2 scheme, all fields) with a client key made for that request;
  a request with a field NEAR would leave readable is refused, and so is
  a reply with a field that does not open. Not streamed yet. Four gate
  checks: NEAR's published vectors, a round trip with a stand-in server,
  a tampered or plain reply refused, another certificate key refused
  before a byte is written. Live through Tor with a deliberately invalid
  key and the word "ping": the proof passed and NEAR answered 401, as it
  should. Unproven until a real key exists: that a real reply opens and
  that NEAR takes all-fields mode. The stand-in's test certificate and
  its key are in `tests/fixtures/stand-in`; nothing trusts them. Not in
  the guest image or the app yet.

- NEAR mode, begun: the proof checker (`guest/near`, decision 14 in
  `docs/plan.md`). Through a SOCKS5 proxy it asks NEAR AI Cloud, with no
  account and no key, for one model's hardware report on one TLS
  connection, and Intel's collateral straight from Intel; then a pure
  check, for NEAR's front server and for every server of the model:
  Intel's TDX quote (`dcap-qvl` 0.7.1), `UpToDate` only, not debug, the
  quote tied to the server's key, its TLS key and our fresh nonce, the
  event log and compose file tied to the quote, the measurements equal
  to a set in `reference/near-pins.json`, one encryption key across all
  the model's servers and the same as the key each quote binds. Run live
  through Tor on 19 November for `Qwen/Qwen3.8-27B` (one server) and
  `z-ai/glm-5.3-flash` (three): every check passed. One gate check,
  offline against a saved real report: it passes, and is refused for
  another nonce, TLS key, pin, key, model name, an empty list and stale
  collateral. Not checked, and said so in its README: the GPU, the
  model's own software, where the images came from, replies. Not in the
  guest image or the app yet; sends no chat request.

- Agents: a request in Activity opens to show its texts (Sean, 19
  November, "1. b"). Each user message as the app wrote it and as Cloak
  sent it, with the changed words marked as Chat marks them; one that
  went unchanged is shown once. A stopped request's second text is
  headed Reworded, since it may not have left this Mac. Only the newest
  20 requests keep texts, in memory only, never on disk or in the log,
  and gone when Cloak quits; user messages only, never instructions,
  tools, tool results or answers. The section's footer says "Kept in
  memory only, and gone when Cloak quits." Seen on screen empty only.

- Agents: an Activity section (Sean, 19 November: "show what local apps
  are putting in"). The last 24 hours' count of chat requests and the
  share answered, then the latest 20: who sent each (an app, or Cloak's
  own agent), the model, how many messages went reworded, whether it is
  rewording, sending, answered or stopped and why, and how long it took.
  Up to 200 are held in memory until Cloak quits, never on disk or in the
  log, and never a message's text. What the door accepts, sends and
  answers is unchanged. Seen on screen empty only; no check was added.
  The release plan records his other answers of the day: zkAPI's live
  vault as it is, his Chat message ahead of a task's requests, no
  Anthropic-shaped address for now, and NEAR's enclave models built now.

- Chat: Send Original moves to the review area (decision 11 in
  `docs/plan.md`, Sean, 19 November). The tick under the message box is
  gone. Beside Send, where a reworded text waits, "Send Original Text"
  sends that message as written instead, and the turn is kept as one sent
  as written; Send stays the prominent button, and the new one is off
  only where sending is certain to stop, with the same words. Under them,
  and in Settings, General, a checkbox: "Never reword text. Reduces your
  privacy." Ticked, each Chat message is sent as written at once on Send,
  with no rewording and no review, and "Rewording is off. Messages go as
  you wrote them." stays under the message box; the waiting notice says
  "Start it to send" in place of "to reword". It is kept in the app's
  settings, off until ticked, and Restore Defaults turns it off. With it
  ticked Cloak departs from the post's "all prompts are locally
  rewritten" for Chat's own messages; the agent's tasks and what other
  apps send through the door are always reworded. The send checks are
  unchanged: what they build is the same.

- Gate checks only (decision 15 in `docs/plan.md`, Sean, 19 November):
  the ordinary unit checks are deleted, seventeen of the app's and four in
  `tests/` (`test_fetch_model.py`, `test_stage3.py`, `test_stage4.py`,
  `test_worker_stop.py`), with the stand-in only they used. The checks
  behind the stage 2 gates stay: the guest checks in `tests/`, the
  worker's, the app's door, stopped-rewording, send and wallet-presence
  checks, the payer's (`guest/pay/check.sh`) and the sender's. Nothing
  checks what the deleted ones did. The control channel no longer takes
  another socket, lock or user, and the model download no longer takes
  another folder, network watch, free-space reading or retry waits: only
  the deleted checks gave them. Nothing the app does changes.

- Payment in the guest begun: `cloak-pay`, the mainnet zkAPI daemon
  built with Cloak's front added and Tor as its only route
  (`guest/pay/`, release plan build steps 1 and 2). It serves the Mac
  only, one request per connection on the guest's vsock port 8021: in
  goes the reworded request with the conversation's Tor identity, out
  comes the answer. It opens no loopback port; the daemon's local API
  and admin routes never start. The conversation's identity goes on the
  model request only, and every payment connection gets a new one. It
  refuses to start on any route but Tor. Checked with stand-ins only:
  the mainnet code runs only inside the pinned Go image under Docker,
  with no network (`guest/pay/check.sh`), and once in a Linux container
  over real vsock, also with no network. On the Mac it is only compiled. Not started at boot: nothing in the running product changes,
  and the sender stays. The guest check from the agent's sandbox,
  `tests/test_pay_path.py`, is written and waits for the boot lines.
  The guest's vsock probe takes an optional address.

- Fixed: one conversation's agent could make its own next task write
  into another conversation's folder. The sandbox script no longer copies
  the task's settings file, pass inside, into the conversation's home
  before the sandbox starts (`reference/wrapper/sandbox`). The sandbox now
  gives Pi that file read-only where Pi reads it, and bubblewrap 0.12.0,
  the guest's, sets that up inside the sandbox's own root, where a link
  the agent leaves in its home cannot lead out. The pass is no longer
  left in the home either. A link planted that way now stops only the
  planting conversation's next task. Tried with the guest's bubblewrap
  package under Docker: the old script put one conversation's pass in the
  other's folder, the new one put nothing there. The escape check now
  expects the fix; its planted link moves the `.pi` folder aside, since a
  running task's settings file can no longer be deleted. The guest checks
  have not run on it yet.

- Escape checks, all passing on 19 November (`tests/test_escape_path.py`,
  release plan item 4). In two guest boots, a hostile agent in the
  sandbox tries the guest's loopback services without torsocks, the Tor
  port by hand with an identity of its own and a guessed one, the Mac's
  vsock ports, the guest's secrets, settings and programs, TCP to port
  53, UDP, IPv6, ping, abstract UNIX sockets, a process that tries to
  outlive its command, and another conversation's files. Found while
  writing them: the two lines the sandbox script ran before bubblewrap
  followed links the agent made, so one conversation's next task could
  write its pass into another conversation's folder; fixed the same day
  (the entry above). The guest checks' shared boot helpers move to
  `tests/guest_boot.py`. The stand-in door
  gains two scripted answers, `peek` and `plant`, and the door's own
  check (`DoorGuestTests`) expects them.

- Cover traffic is on (Sean, 19 November). `reference/cover.json` now
  holds the pool of 58 well-known pages, on 32 sites, that each answered
  a Tor visitor on 18 November, at the same rate: 0.05 a second, 2 at
  once, about three fetches a minute. Once the guest is rebuilt, every
  start of it, in the app and in the stage kits, sends cover through Tor
  to sixteen of them picked at random. Known limits: the sites have not
  agreed to automated visits; the worker counts a page over 64 KiB as
  failed, and 48 of the 58 reached that cap; the same sixteen serve until the next
  start. The agent and Tor checks, which list every connection the
  stand-in tor sees, now boot with an empty list laid over the image's
  (`tests/cover_list.py`, shared with the cover checks), and one new cover
  check boots the image as built and waits 200 seconds for its cover. The
  app's details now say cover runs. As the reference says, this is
  background noise, not proven protection against traffic analysis.

- Cover traffic: the list's addresses are now a pool of pages that may
  hold more than the sixteen the reference's worker takes (Sean,
  18 November: a changing mix of real, current, popular pages). At each
  start the guest's daemon picks sixteen of them at random and gives
  those to the worker unchanged; the same sixteen serve until the next
  start. A pool of sixteen or fewer is used whole, as before. Every
  address in the pool must pass the reference's own checks, picked or
  not, and none may be listed twice, or the daemon does not start. The
  picked addresses are not logged. The pool still ships empty, so cover
  stays off until Sean approves its pages. Four checks for the pool are
  added to `tests/test_cover_path.py`; the guest must be rebuilt.

- Cover traffic, the reference's own (release plan item 3). The guest's
  daemon now starts the pinned daemon's cover worker as its own serve
  does, from one list, `reference/cover.json`, that guest/build.sh puts
  in the image. The list names no destinations, which is Sean's choice
  to make, so cover is off; its rate is 0.05 a second with 2 at once,
  below the reference's defaults. A list the daemon cannot take stops the
  guest before any task. The once-a-minute totals go to the daemon's log
  in the guest. `tests/test_cover_path.py` checks it against the stand-in
  tor; the guest must be rebuilt. As the reference says, this is
  background noise, not proven protection against traffic analysis.

- The menu-bar icon is the 13-block Regents crown, drawn from the design
  system's master block for block, with a small badge at its lower
  corner for the state: play, pause, starting, stopping or needs
  attention (Sean, 18 November). The badge is large, over about a third
  of the crown, as he then asked.

- Signed updates prepared (Sparkle 2.8.1, as in Llama.app). Off until
  `app/release.json` names an update feed and a public update key, which
  are Sean's to supply; then the menu gains Check for Updates and
  Settings an Updates switch. An update is taken only with a valid
  signature and a press of Install, and Cloak opens Paused after it.
  The bundle's version is now the commit count, so builds can be told
  apart by number.

- Settings (decision 14, from Llama.app): a Settings window with Launch
  at login, Free memory, a shortcut for a quick prompt, the door's port,
  the commands Cloak started its parts with, this session's log and
  Restore Defaults; six AppleScript commands; Starting and Stopping in
  the menu's header; Show in Finder for a changed model. A stopped
  send's detail no longer goes into the readable log, as it can hold
  amounts.

- Menu and windows (decision 14, from Llama.app): a header with a state
  dot and one plain line, a failure and its fix in one place, the build
  at the foot of the menu, clearer causes and remedies for every
  failure, a one-time Welcome, and a QR code of the wallet's address.

- The app downloads its model (decision 14, from Llama.app; release plan
  item 7). Offered in Details, the menu and Chat when the files are
  missing, started only by the person, with the size, the host and the
  plain fact that the host sees this Mac's address. Resumable, checked
  against each pin before a file is put in place, paused by a lost
  network and continued when it returns. The manifest now carries each
  file's sha256 and address, so the app must be rebuilt.

- The Mac check and a Memory figure (decision 14, from Llama.app). The
  check asks Metal what this Mac's graphics will hold and keeps 4 GiB
  for macOS, in place of a flat 16 GB; `app/release.json` states what
  the model and all of Cloak need. The Details window shows what Cloak
  holds in memory now, and the technical details each part's share.

- The model leaves memory when idle (decision 14, the first idea taken
  from Llama.app). Once Cloak has reworded nothing for the time chosen as
  Free memory in the Details window (5 minutes until chosen; 15 minutes,
  1 hour or Never), the worker is ended and its memory is free; the next
  request starts a new one the same way and waits for it. A worker that
  ends by itself or cannot start again is still a failure, and nothing
  is tried again. The Details window says when the model is unloaded.

- zkAPI trial: two more trips at $2 on mainnet, on Sean's decision, with
  stops and crashes in the middle of a deposit, an unsettled request and
  a withdrawal. All recovered; nothing was paid or deposited twice.
  Found: a key for every request makes requests take about 25 s and go
  one at a time, and a request made while an earlier one settles after a
  restart can fail rather than wait. Figures in `docs/plan.md`.

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
