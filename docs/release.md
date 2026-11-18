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
| Cover traffic | **Missing.** The pinned daemon already has it, off | Turned on, checked, limits said |
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

**3. Cover traffic, the reference's own** (was item 4). The pinned
daemon in the guest already has it, off by default
(`zkapi-clientd/docs/COVER_TRAFFIC.md`): random background HTTPS GETs
through Tor, each worker on its own Tor identity, no payment used. The
work is to turn it on in Cloak's guest, check it against the stand-in
tor, and measure it. It needs destinations: one to sixteen small static
files someone has leave to poll. Whose they are is Sean's decision.
The goal, corrected: **Cloak reproduces the reference's cover traffic
and claims nothing the reference does not.** Its own document says it is
background noise, not proven protection against traffic analysis, and
Cloak says the same.

**4. Escape and boundary checks.** The gates above for network escape,
conversation separation, and host and guest, written as checks that try
to break out. Several exist in pieces (`tests/test_tor_path.py`,
`tests/test_agent_path.py`); none tries a hostile agent end to end.

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
