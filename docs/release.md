# Release plan (skeleton)

First written 17 November 2026 at Sean's request; revised the same day
after a review he passed on. The rule the review set, which this plan now
follows: **the post's protections first, public claims after.** Packaging
and first-run work are needed, and do not stand in for them. Progress
still lives in [plan.md](plan.md).

Sizes are no longer given for anything that depends on a service outside
our control.

## The target

Vitalik's protected Pi workflow of 16 October
([the post](../reference/vitalik-post-2026-10-16.md)), with none of its
protections weakened, usable by someone who has never used Tor, Linux or
zkAPI. The proof is one demonstration: on a fresh Mac, the agent does a
real research task with tool calls and follow-ups, meets a hostile page,
makes several model calls, and finishes, while Cloak shows that nothing
left by a route it does not allow.

## Where Cloak is, said plainly

| The post asks for | Cloak today | Still to show |
|---|---|---|
| Agent in a sandbox | Works on one Mac: a guest with no network device | Escape attempts by a hostile agent |
| Tor for everything | Works for the daemon, the agent and its tools | Every process, DNS and helper, tried on purpose |
| A circuit per conversation | Built: each conversation has its own Tor identity | A check that two conversations never share one |
| Local rewording | Works; a failure sends nothing | The comparison with the reference on meaning and on what leaks |
| Payment that does not link chats | **Missing.** One wallet pays for every chat | All of it |
| Cover traffic | On: the guest runs the daemon's own cover, about three fetches a minute from a pool of 58 well-known pages Sean approved | Checked and measured on the real route; the sites have not agreed to automated visits |
| Easy install | Built from source by the chief | All of it |
| Review by someone else | None | All of it |

The model is the 9B one (`small-lead-gguf-grammar`), not the 27B one
looked at earlier. The whole app's memory has never been measured
together.

## Three stages

1. **Technical preview.** A few invited people. Tests install, the model
   download, the interface, whether tasks are useful, and recovery. The
   payment is wallet-linked and says so. No claim about privacy. On the
   public site only as a listed page at regents.sh/cloak, its text
   approved by Sean (19 November).
2. **Reference parity.** Private payment and cover traffic work, the
   gates below pass, and someone outside has reviewed it. This is the
   announcement.
3. **Broad launch.** People with no technical background install, fund,
   use, pause, update and recover it with no help. May come with stage 2;
   not assumed to.

## Who owns what (to be settled before payment goes into the guest)

Two daemons will run side by side: the post's, which rewords, and the
mainnet one, which pays. For each of these, one owner, written down and
checked: rewording; the conversation's Tor identity; leave to spend;
the provider's temporary key; the request that leaves. The risk is not
two daemons. It is a path between them that skips rewording or Tor.

**Settled 19 November (the chief's design; nothing built yet).** The Mac
keeps rewording and the conversation's Tor identity, as today. The
guest's sender is replaced by `cloak-pay`: the mainnet daemon with one
overlay file, as a guest user of its own, starting its companion as
upstream does. The post's daemon stays for cover traffic and the startup
check, and takes no part in a request.

| Item | One owner | Never holds | The check |
|---|---|---|---|
| Rewording | The Mac app (`Rewrite.swift` and the worker), called by Chat and the door | — | A stopped rewording sends nothing to `cloak-pay` |
| The conversation's Tor identity | The Mac app, passed with each request | — | The stand-in tor sees two conversations under two identities, and no payment traffic under either |
| Leave to spend | The Mac app: one queue; a deposit or withdrawal only on the owner's press | The provider's key | The agent, from its sandbox, gets no request served by any guest port |
| The provider's temporary key | `cloak-pay`, in memory only, a new key for every request | Text as written | Two requests carry two keys; none reaches the Mac |
| The request that leaves | `cloak-pay`, through the guest's tor port | — | The escape checks, and the identity check above |

Three things the mainnet daemon does not do, which the overlay and one
patch must: it answers any program on the guest's loopback with no pass
(so `cloak-pay` listens to the host only, over vsock); it sends every
stream, payment and chat alike, with no Tor identity (so the post's
identity code is carried over, the conversation's identity on the
request only and a fresh one for each payment connection); and a request
made while an earlier one settles can fail (so the Mac gives a turn only
when nothing is pending, and waits).

Kept safely, spelled out: the payment files live in one image file on
the Mac, attached to the guest as its only disk and opened there under a
key from the keychain, so they are encrypted at rest and written before
a request leaves, as upstream already journals. The signing key and the
note secret are in the guest, as the `cloak-pay` user; the agent's
sandbox cannot reach them, and what bounds a break of the guest is the
size of the deposit. The guest then has a disk, and the escape checks
are restated for it. Shapes not taken: the post's daemon in front of the
mainnet one (a new hop between two daemons, and text as written inside
the guest), and both programs on the Mac (untrusted code on the Mac with
a network).

Build order, each step ending in a running check, with stand-ins until
step 7: the overlay's front over vsock; the identity patch; holding
during settlement; the encrypted disk; the real companion and proving
keys with no network; the Mac side (a payer in place of the Tempo parts,
a new wallet sheet); the real service with no money; the first deposit
(Sean's own decision); the cutover, which deletes the sender, its host
half, the Tempo wallet parts and Development mode.

Sean's answers, 19 November:

- Send Original stays: a button "Send Original Text" in the message
  review area, and a checkbox "Never reword text. Reduces your privacy."
  With the box ticked Cloak departs from the post's "all prompts are
  locally rewritten", and says so. Read as Chat's own: what other apps
  and agents send through the door is always reworded.
- A deposit is the size the owner chooses, with a warning above $50 and
  a notice that mainnet fees for a deposit and a withdrawal come to
  about $3.50.
- Everyone may fund, but not while a deposit can be taken: "These
  contracts should never expire and take people's deposits, ever." The
  live vault's 30-day `claimExpired` and its pause are Open Anonymity's,
  in their contract. He also wants an address or ENS name, optionally
  given with the deposit, that may withdraw it. Neither can be had by
  changing Cloak; the way to them (ask upstream, or a vault and operator
  of Regents' own) is his open decision.
- The trial address's remainder stays where it is.
- Open: whether Chat's message goes ahead of a running task's requests.

Later the same day he settled these:

- The contract: "ok nvm, use zkAPI as normal. forget what I said. but the
  protocol should never take customer deposits, it shoul remain claimable
  / withdrawable by them". So Cloak uses the live vault and operator as
  they are, and no vault or operator of Regents' own is planned. The
  30-day `claimExpired` is still in that vault, so his wish is not met by
  it: until upstream changes it, Cloak's part is to show the day a
  deposit can be taken, to warn well ahead of it, and to keep Withdraw one
  press away (build step 6). Asking upstream to remove the expiry is a
  post under his name and waits for his own decision. The recovery
  address or ENS name is dropped with "forget what I said".
- The owner's Chat message goes ahead of a running task's requests in the
  one payment queue.
- No Anthropic-shaped address for now; again after private payment works.
- The Agents window shows what local apps send: each request's sender,
  model, stage and time. First built without any text; then, asked,
  he chose that a request opens to show what the app wrote and what
  Cloak sent instead, in memory only and gone when Cloak quits.
- Switches (his answers "1. a 2. a 3. a" and after): Cover traffic
  now; a Tor switch and a choice between zkAPI and the owner's own
  provider key after private payment and NEAR are in the app; Review,
  Saved chats and NEAR's proof freshness in Settings; and Cover, Tor and
  zkAPI shown on or off as pills under Chat's message box.
- NEAR's requests use the owner's own NEAR key, kept in the keychain;
  later each person brings their own. A key shared by all, run by
  Regents, is not planned.
- NEAR's enclave models are built now as a second, named mode, not after
  zkAPI is in the guest (decision 14 in [plan.md](plan.md)).

Sean's answers, 20 November:

- NEAR mode need not use Tor: "the Near mode of the app may or may not
  allow Tor to be used with it. it can be optionable only if it works,
  even if it is very slow". Tor is a switch inside NEAR mode, off until
  turned on; off, NEAR and Intel see the Mac's internet address.
- The list of NEAR server software Cloak accepts stays inside the app
  (`reference/near-pins.json`). When NEAR changes its servers, NEAR mode
  stops with the proof refused until the change is read and a Cloak
  update ships. To be counted over the next days and brought back if it
  is frequent; a list Regent signs and publishes, or accepting what NEAR
  itself signs, were the choices not taken.

## Gates for stage 2

Each is a check that runs, not a statement.

| Gate | What must be shown |
|---|---|
| Network escape | Pi, its tools, child processes, DNS and helpers reach nothing outside the allowed route |
| Conversation separation | Two conversations share neither a Tor identity nor a payment credential |
| Rewording | It happens on the Mac; a failure never sends the original |
| Payment | What the provider sees does not tie a chat to the funding wallet, under a stated threat model |
| Wallet recovery | A crash, restart, update or interrupted withdrawal loses no funds and spends nothing twice |
| Cover traffic | Real background requests go out by the required route, with measured timing and volume |
| Host and guest | A hostile agent cannot read wallet secrets, change the rewording rules, change the supervisor or read the Mac's files |
| Usefulness | Real tasks finish, not only probes |

## The work, in order

### P0

**1. Known faults** (was item 6). Under way. A deposit stuck opening,
the wallet sheet that spins, the message that comes back with its picks
as text. Each with a check that failed before. No acceptable build risks
money it could keep.

**2. zkAPI, whole, outside Cloak** (was item 3, first half). The exact
mainnet daemon, companion, keys and settings, in a container on this Mac
with Tor as its only way out: a small deposit, one paid request,
settlement, a withdrawal, and a restart in the middle of each. This
answers the open question first: whether Open Anonymity's service serves
a client that is not its own app. **Answered 17 November: it does.** A
$5 deposit, one paid request, its settlement, a restart and a full
withdrawal all passed, for about $3.57 in fees. Two more trips at $2
tried the edges: stops and crashes while a deposit was unmined, a request
unsettled and a withdrawal waiting all recovered, with nothing paid
twice. Two things for item 5 came out of them. A key for every request
means about 25 s a request and one at a time; a shared 60 s window is
fast and lets the provider link what shares it. And a request made while
an earlier one is still settling after a restart can fail instead of
waiting. Every deposit and transaction is Sean's own decision. If the service
refuses us, the item stops here and comes back to Sean; it is not
replaced by another way to pay.

**3. Cover traffic, the reference's own** (was item 4). Built 18
November, and on since 19 November. The guest's daemon runs the pinned
daemon's own cover (`zkapi-clientd/docs/COVER_TRAFFIC.md`): random
background HTTPS GETs through Tor, each worker on its own Tor identity,
no payment used. Its destinations, rate and concurrency live in one list,
`reference/cover.json`; an empty list would be cover off. The rate is
0.05 a second with 2 at once, inside the reference's ranges and below its
defaults of 5 a second and 4 at once; Sean kept it on 18 November. The
destinations are a pool of real, current, popular pages (Sean,
18 November), which may hold more than the sixteen the reference's
worker takes: at each start the guest picks sixteen of them at random and
gives those to the worker unchanged, until the next start, and the pages
themselves change over time. On 19 November Sean approved the pool: the
58 pages, on 32 sites, that answered a Tor visitor in one fetch each the
day before. Known limits: the sites have not agreed to automated visits;
the worker counts a page over 64 KiB as failed, and 48 of the 58 reached
that cap in the probe;
the same sixteen serve until the next start. Its checks against the
stand-in tor passed on 19 November and were then deleted (decision 15 in
[plan.md](plan.md)); nothing checks cover now. Still to do: a run on the real route, measured
against the policy. The goal,
corrected: **Cloak reproduces the reference's cover
traffic and claims nothing the reference does not.** Its own document says
it is background noise, not proven protection against traffic analysis,
and Cloak says the same.

**4. Escape and boundary checks.** The gates above for network escape,
conversation separation, and host and guest, written as checks that try
to break out. `tests/test_tor_path.py` covers the Tor port.
**19 November:** `tests/test_escape_path.py` now does, twelve attempts
in two guest boots, all passing; it found and closed one way for a
conversation to write its pass into another's folder. Not yet tried: the
guest's own sender and runner ports from inside the sandbox, payment
credentials (payment is not in the guest), and the Mac's files beyond
the guest having no disk or shared folder.

### P1

**5. zkAPI inside the guest** (item 3, second half). After 2 passes and
the ownership table is settled. The payment files kept on the Mac,
encrypted, written before a request leaves; the agent gets no way to
sign. "Kept safely" to be spelled out: encryption at rest, who may read
the keychain item, who may sign, how a half-written file is recovered,
backup. Then Development mode is removed, not kept beside it. A second
decision for Sean before users: whether a service with a 30-day expiry
and an operator who can pause it is fit for people to leave money in.

**6. Outside review** (was item 9). Scope written now; reviewers sought
now. Choosing and paying them is Sean's.

**7. Install, model download, first run** (were items 1, 2 and 5).
- Signed with a Developer ID and notarized; opens with the Mac's normal
  first-run questions and no bypass steps. One bundle, an update path
  that checks a signature, keeps the wallet's files and refuses to start
  if a new part fails its check.
- Exact hashes, where each dependency came from, a signed manifest and a
  build others can repeat. Bit-for-bit sameness is a target, not a gate.
- Model download in the app, resumable, checked. A direct download shows
  the Mac's address to the model host: said at install, approved there,
  and never mixed up with the route prompts take.
- First run in steps, in plain words.

**Signed updates (prepared 18 November, on since 19 November).** The app
carries Sparkle 2.8.1. `update_feed` in `app/release.json` names the
feed, `appcast.xml` on the main branch of `regents-ai/cloak-releases`,
and `update_key` the update key's public half; `app/build.sh` writes both
into every build, the development build included. The app has Check for
Updates… in its menu and an Updates switch in Settings, General (off
until the person answers Sparkle's question on the second launch, or
turns it on).

What Sean supplies and decides first:

1. An Apple Developer ID: the Developer ID Application certificate that
   signs the app and every part inside it, and the account that
   notarizes it. Sparkle also takes an update signed with the same
   Developer ID as the installed app, so a key can be changed; whoever
   holds the certificate can therefore make an update Cloak accepts, and
   it is guarded like the update key.
2. The update signing key: a pair made once with Sparkle's
   `generate_keys`. The public half goes into `update_key`. The private
   half signs every update, so where it lives is his choice: the
   keychain of the Mac that makes releases, an offline backup, or both.
   It never goes into the repository or within reach of an agent.
3. Where the feed and the downloads are hosted. The host sees each
   Mac's internet address at every check (at most once a day, and when
   someone presses Check for Updates…) and at every download, and
   nothing from a chat. Its address goes into `update_feed`, and must be
   HTTPS.

Sean's answers, 18 November:

- Developer ID: yes. Its private key was made that day, at Sean's word,
  inside the login keychain of this Mac (named "Regents Cloak Developer
  ID", RSA 2048), and never written to a file. The request file for
  Apple went to his Desktop for him to upload. He installed the
  certificate the same day: "Developer ID Application: Sean Brennan",
  Team ID 367G3Z7G3J, good until 18 December 2027, in the System
  keychain. Apple's public intermediate certificate (Developer ID
  Certification Authority, G2) was added to the login keychain, and the
  Mac then showed one valid signing identity. It is in his personal
  name. Sean is getting a D-U-N-S number for Regent Labs, Inc so that
  the public release is signed by the company; when that Apple account
  exists, a new key and certificate are made the same way and this one
  is used for nothing public (changed 19 November: it signs the friends'
  build, below). No backup of the key is kept, by his
  choice: it can be replaced at Apple. The notarization sign-in is still
  to come (saved 19 November as the keychain profile `cloak-notary`).
- The key: made that day with `generate_keys --account cloak`, on his
  decision, in the login keychain of this Mac. Its public half is
  `Dw2edhocMd1y+8c+Q5Lm0kG15miKI4TX+zj7tYuomjk=`. The private half is
  backed up, by Sean's own hand that day, as an entry in his Passwords
  app; the file used for the copy was deleted.
- Hosting: this repository, regents-ai/cloak, once it is public, which
  is its own decision. The feed will be
  `https://raw.githubusercontent.com/regents-ai/cloak/main/appcast.xml`
  and the downloads the repository's releases. Until then `update_feed`
  and `update_key` stay empty, since a private repository's feed cannot
  be read and a check would only fail. Replaced on 19 November, below.

Sean's answers, 19 November (friends' build):

- Close friends download Cloak, install it and test it.
- Their build is signed and notarized with the certificate in his own
  name, "Developer ID Application: Sean Brennan (367G3Z7G3J)".
- Updates are on in that build.
- The downloads and the feed live in `regents-ai/cloak-releases`, a new
  public repository that holds only signed builds. This replaces the
  plan to host them in this repository once it is public. The feed is
  `https://raw.githubusercontent.com/regents-ai/cloak-releases/main/appcast.xml`,
  and each download is a release there.
- The page at regents.sh/cloak will be a listed page, its text approved
  by him separately.

Then each release, by the chief alone, on this Mac:

1. Raise `release` in `app/release.json`, write that release's notes in
   `app/release-notes.md` (plain words, which go into the feed as they
   are: no link, image or page from elsewhere), and commit.
2. Run `app/release.sh`, from a clean tree. It builds the app with
   `app/build.sh` and the Developer ID, every part signed inside out
   with the hardened runtime and a secure timestamp; has Apple notarize
   the app and staples the ticket to it; packs it in a disk image, which
   is signed, notarized and stapled the same way; checks that Gatekeeper
   accepts both; and adds the release to the feed with Sparkle's
   `generate_appcast`, which signs the image with the private update key
   and writes its release, its build number (the commit count
   `app/build.sh` gives the bundle, which Sparkle compares to find a
   newer one), its notes, the file's address, its size and its
   signature, keeping the earlier releases. It uploads nothing, and
   leaves the image, the feed and the tag in `app/build/release/`.
3. Run `app/publish.sh`. It creates the release in
   `regents-ai/cloak-releases` with the image, then puts the feed on that
   repository's main branch, and waits until the public feed names the
   new release.
4. Check from a Mac with the previous release that it finds the update,
   takes it, and opens Paused.

Releases so far:

- 0.5.0 (164), 19 November 2026, from commit `e19db9e`. Apple accepted
  the app and the image; Gatekeeper accepts the image as downloaded from
  `https://github.com/regents-ai/cloak-releases/releases/latest/download/Regents-Cloak.dmg`,
  and the feed's signature of it matches the update key in the app. On
  Sean's Mac the signed build starts and rewords (`cloak verify`). Not
  yet shown: a first run on a Mac that never had Cloak.
- 0.5.1 (168), 20 November 2026, from commit `9774db9`: Llama Normal
  chats and the modes' new names (decision 17 in [plan.md](plan.md)).
  Apple accepted the app and the image; the image downloaded from the
  address above is the one built, byte for byte, and Gatekeeper accepts
  it; the feed keeps 0.5.0's entry beside the new one, and its
  signature of the new image matches the update key in the app. The
  update itself, shown once on Sean's Mac: a copy of the published
  0.5.0, opened from a folder of its own, found 0.5.1 through Check for
  Updates…, installed it and reopened Paused as 0.5.1 (168), still
  notarized. Not yet shown: a first run on a Mac that never had Cloak,
  and an update found by the daily check rather than the menu.
- Seen in that update: Sparkle's window shows a blank icon, because the
  app has none, and no notes, because the feed carries none (the notes
  are on the release's page only). The icon came with 0.5.2.
- 0.5.2 (170), 20 November 2026, from commit `dba9a91`: the app's icon
  and the install window (decision 18 in [plan.md](plan.md)). Apple
  accepted the app and the image; the image downloaded from the address
  above is the one built, byte for byte, and Gatekeeper accepts it; the
  feed keeps the two earlier entries. Opened as a double-click opens
  it, on Sean's Mac: one window with the app's icon, the arrow and
  Applications, its labels readable in the dark appearance. Not yet
  shown: the same window on a Mac in the light appearance, and with
  Finder's tab bar off.
- Seen on Sean's Mac only: macOS asked once whether to open the worker,
  as "(null)", because its sandbox folder there was made by ad hoc
  builds and the worker is now signed by a team. A Mac that only ever
  had released builds has no such folder and is not asked. Since
  20 November every build on Sean's Mac is signed with the same
  Developer ID (decision 16 in [plan.md](plan.md)), so it is not asked
  there again.

**8. Memory and speed, measured.** One table: the model and its
quantization; peak memory with the guest, tor, Pi, payment and the model
all active; cold and warm start; typical and worst rewording time; under
several tasks; after sleep and under memory pressure. 10 GB stays an aim
and is promised nowhere until this exists. The model is not swapped for
a smaller one to reach it.

**9. Many machines, many people.** At least ten installs on different
supported Macs, including a full disk, a broken download, sleep and
wake, and recovery. Three people is a smoke test only.

### P2

**10. Claims and the public home** (were items 7 and 8). A table of
every claim with the check behind it, published before any announcement.
Licence, history read before the repository opens, the page, the
announcement text: all Sean's.

## Standing limits

- No deposit and no movement of funds without Sean's own decision.
- zkAPI is not replaced by Boundless, plain API keys or any other
  payment in the public protected build to meet a date.
- No date is given for stage 2 until item 2 has passed.

## What could make this plan wrong

- Item 2 can fail for reasons that are not ours: the service calls
  itself unaudited, its keys come from one party, a deposit expires to
  the operator after 30 days, and the operator can pause it.
- Nobody but Sean has used Cloak.
- The whole app's memory is unmeasured.
