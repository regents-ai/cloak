# Release plan (skeleton)

Written 17 November 2026 at Sean's request: what stands between today's
Cloak and a public release with an announcement. A skeleton, not a
commitment. Sizes are the chief's guesses in days of building, not
measured. Progress still lives in [plan.md](plan.md).

## Where Cloak is, said plainly

- It works on one Mac, Sean's, built from source by the chief. Nobody else
  has installed it or used it.
- Payment is Development mode: one wallet pays for every chat, so the
  provider can link them all. That is the opposite of what the 16 October
  post asks of payment.
- The claims rule holds for the announcement too: nothing is called
  protected or private beyond what a passed check shows.

## Two releases, not one

- **Early release.** Items 1, 2, 5, 6, 7 and 8. Usable by other people,
  labelled as Development mode, with its payment limit said in the app and
  in the announcement. Guess: 2 to 3 weeks.
- **Full release.** Adds items 3, 4 and 9. This is the one that can be
  measured against the post. Guess: 4 to 8 weeks more, and item 3 may fail
  for reasons outside our control.

## 1. An installable app

- **Goal.** Download, drag to Applications, open. No terminal, no
  developer tools.
- **Today.** `app/build.sh` builds it on this Mac, signed ad hoc. The
  worker installs from a second script. Building needs Docker, Go, Rust,
  Swift and CMake.
- **Work.** One bundle holding the app, the worker, tor, the kernel and
  the guest image. Developer ID signing with the virtualization
  entitlement, and Apple's notarization. A disk image to download. An
  update path that checks a signature. A reproducible build recipe, so the
  download can be checked against the source.
- **Done when.** A Mac that has never seen Cloak installs it from the
  download and reaches Running, with Gatekeeper raising nothing.
- **Unknown.** Whether the sandboxed worker still starts from inside a
  notarized bundle (today it must live outside `~/Documents`). Whether the
  guest image can be rebuilt bit for bit.
- **Sean's.** An Apple Developer account and its signing key; every
  release under it.
- **Size.** 4 to 6 days, plus Apple's turnaround.

## 2. The model, fetched by the app

- **Goal.** First launch downloads the model with progress, checks every
  file against its pin, and can be paused and resumed.
- **Today.** `scripts/fetch_model.py`, in a terminal.
- **Work.** The same download inside the app: size and free disk shown
  first, resume after a break, a mismatch refused and said plainly.
  Decide what the download goes through: direct to Hugging Face shows the
  Mac's address to the hub; through Tor it is slow for several GiB.
- **Done when.** A fresh install reaches Running with no terminal, and a
  download cut at any point carries on.
- **Unknown.** Which route; how long several GiB takes through Tor.
- **Size.** 2 to 3 days.

## 3. Private payment (zkAPI)

- **Goal.** Each chat is paid for without the provider being able to link
  it to the wallet or to the other chats.
- **Today.** Open Anonymity's mainnet programs build for the guest; one
  proof peaks at 129 to 165 MiB and takes about 3 s; under the daemon
  every connection goes through Tor. Not in the guest, never run
  together, no deposit made.
- **Work.** Both programs and their keys into the guest image. Their
  folder kept on the Mac, sealed, and written before a request leaves,
  since losing one file loses the deposit. Run to the point of deposit.
  A small real deposit (Sean's decision, with an amount). One paid
  request, one withdrawal. Then the app's wallet screen and the send path
  moved onto it, and Development mode removed, not kept beside it.
- **Done when.** A paid chat and a withdrawal both work from the sealed
  box, and a restart in the middle of each loses nothing.
- **Unknown, and serious.** Whether their service serves a client that is
  not their own app. Their own manifest says nothing is production-audited
  and the proving keys are a single-party development setup. A deposit
  expires to the operator after 30 days; the operator can pause deposits
  and withdrawals. The rewriter in the post's daemon and this payment
  daemon are different versions that must run side by side. Any of these
  can stop the item, and none is ours to fix.
- **Sean's.** Every deposit and every real transaction.
- **Size.** 8 to 15 days if nothing upstream blocks it. Could be never.

## 4. Cover traffic

- **Goal.** What the post asks: someone watching the connection cannot
  tell when a real message is sent.
- **Today.** Nothing built. No design chosen.
- **Work.** Read the post and the spec for exactly what is asked. Choose
  a shape (timing, volume, who pays for cover requests). Build it. A
  check that compares what an observer sees with and without a real
  message.
- **Done when.** That check passes, and the cost per day is known and
  shown.
- **Unknown.** Cost, since cover requests are paid. Whether it can be
  done honestly before item 3.
- **Size.** Not estimable until the design is chosen; the design itself
  is 2 to 3 days.

## 5. First run

- **Goal.** A new person gets from first launch to a first sent chat by
  following the screen.
- **Today.** The menu and the windows assume someone who already knows
  the parts.
- **Work.** One window, in steps: this Mac (Apple silicon, memory, disk),
  the model (item 2), the wallet, funding, a first message. Each step
  says what it does and what leaves the Mac. Every failure in plain
  words with one thing to do next.
- **Done when.** Three people who have never seen Cloak finish it
  without help.
- **Unknown.** Funding is the hard step for a newcomer: today it means
  sending funds to an address on a network they may not know.
- **Size.** 4 to 5 days, plus the three people.

## 6. Known faults

- **Goal.** No known way to lose money or get stuck.
- **Today.** Listed in [state-machines.md](state-machines.md), section 10.
- **Work, in order.** A deposit stuck opening after a crash: reproduce
  it with the stand-in network, then fix. The wallet sheet that spins
  after a failed keychain read. The details that ask what the draft
  already settles. The message that returns with its picked lines as
  text. Name the stages of a message card, a task card and the wallet as
  single values while doing so.
- **Done when.** Each has a check that failed before and passes after.
- **Unknown.** Faults nobody has hit yet; only one person has used it.
- **Size.** 4 to 6 days.

## 7. Honest claims

- **Goal.** Every sentence in the app, the site and the announcement is
  backed by a check that passed.
- **Today.** The rule is in `AGENTS.md`; no list of claims exists.
- **Work.** One table: each claim, the check behind it, the date it
  passed, and what is not claimed. The app's own words checked against
  it. The limits written where a user sees them, Development mode's
  first.
- **Done when.** The announcement draft has no sentence missing from the
  table.
- **Size.** 2 days, then kept current.

## 8. A public home

- **Goal.** A public repository, a licence, a page with the download and
  the limits, and the announcement.
- **Today.** Private repository, no licence, no page.
- **Work.** Choose a licence, checking it against every pinned source's
  own. Read the whole history for anything that should not be public
  before the repository opens (addresses, chat titles, notes). A short
  page. The announcement text.
- **Sean's.** All of it: the licence, opening the repository, the page
  under his name, the announcement's full text and where it is posted.
- **Size.** 2 to 3 days of preparation; the decisions are his.

## 9. Outside review

- **Goal.** Someone who did not build it tries to break the sealed box
  and the money path, and says what they found.
- **Today.** Only the chief and its helpers have reviewed it. That is not
  independent.
- **Work.** A written scope: the guest's isolation, the Tor route and
  what can skip it, the worker's sandbox, the door, the keychain use, the
  payment path. Find reviewers. Fix what they find. Publish the result
  with the release.
- **Unknown.** Who, how long, and what it costs.
- **Sean's.** Choosing reviewers and paying them.
- **Size.** Weeks of calendar time, mostly waiting.

## Order

1. Item 6, since it touches money already in use.
2. Items 1 and 2 together, then 5 on top of them.
3. Item 3 alongside, since it waits on others and on deposits.
4. Items 7 and 8 once 1, 2 and 5 work on a second Mac.
5. Item 9 as early as a reviewer can be found; it needs no release.
6. Item 4 after 3.

## What could make this plan wrong

- Nobody but Sean has used Cloak. The first outside users will find
  things this list does not have.
- Item 3 depends on a service that calls itself unaudited.
- Memory: the aim is 10 GB. It has not been measured on a Mac with less
  than this one has.
