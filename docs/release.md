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
   payment is wallet-linked and says so. No claim about privacy. Not on
   the public site as Regents Cloak.
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
the same sixteen serve until the next start. Checks against the stand-in
tor (`tests/test_cover_path.py`): nine passed on 19 November; one more,
which boots the image as built and sees its cover arrive, is written, to
be run on a rebuilt guest. Still to do: a run on the real route, measured
against the policy. The goal,
corrected: **Cloak reproduces the reference's cover
traffic and claims nothing the reference does not.** Its own document says
it is background noise, not proven protection against traffic analysis,
and Cloak says the same.

**4. Escape and boundary checks.** The gates above for network escape,
conversation separation, and host and guest, written as checks that try
to break out. Several exist in pieces (`tests/test_tor_path.py`,
`tests/test_agent_path.py`); none tries a hostile agent end to end.
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

**Signed updates, prepared (18 November).** The app carries Sparkle
2.8.1. `update_feed` and `update_key` in `app/release.json` are empty, so
the app has no updater and shows nothing about updates. With both set,
`app/build.sh` writes them into the bundle, and the app gets Check for
Updates… in its menu and an Updates switch in Settings, General (off
until the person answers Sparkle's question on the second launch, or
turns it on). With only one set, the build stops. They stay empty until
the stage 2 protections are in (Sean, 18 November, in plan.md).

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
  is used for nothing public. No backup of the key is kept, by his
  choice: it can be replaced at Apple. The notarization sign-in is still
  to come.
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
  be read and a check would only fail.

Then each release:

1. Raise `release` in `app/release.json`.
2. Build the app with `app/build.sh`, its parts signed inside out with
   the Developer ID in place of ad hoc, with the hardened runtime.
3. Notarize the app and staple the ticket to it.
4. Pack it in a zip or disk image.
5. Sign that file with the private update key (Sparkle's `sign_update`).
6. Upload it to the download host.
7. Add the release to the feed: its release, its build number (the
   commit count `app/build.sh` gives the bundle, which Sparkle compares
   to find a newer one), its notes written inside the feed (no link,
   image or page from elsewhere), the file's address, its size and its
   signature.
8. Publish the feed, then check from a Mac with the previous release
   that it finds the update, takes it, and opens Paused.

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
