# Share traces: how NEAR's trace sharing works, and the smallest sound checkbox for Cloak

Read by a helper for the Cloak chief on 20 November 2026 and kept here as the design to build from; spot-read by the chief, not checked line by line. The chief's choices on its section 8: the switch is built as designed (chats handed to NEAR's Gateway app, Cloak uploads nothing) once the four-mode work is merged, since Sean asked for it in decision 27; NEAR chats show tokens only (option a of question 2); question 4 was already answered by Sean (the page's line stays). The first real try is Sean's, asked of him as decision 29.

Research for the Cloak chief, 20 Nov 2026. Read only: no repository file changed, no build, no account, no sign-in, no key, no submission, and nothing of NEAR's downloaded or run.

## Short answer

- **Sean is partly right.** NEAR's own apps can share traces automatically, but only after the person turns sharing on. The NEAR AI Cloud service that Cloak's NEAR chats use shares nothing when it answers a request.
- **The documented way for another app to share** is to write each session as a file in a format called Letta Trajectory, into a folder the person adds to NEAR's Gateway Mac app under "Exported traces". The Gateway removes secrets, shows the trace before and after, waits for the person's approval every time, and uploads it with the person's own NEAR AI account.
- **Recommended design.** A "Share traces" switch in the NEAR wallet sheet, off at first. While it's on, a NEAR chat's menu offers "Share Trace", which writes that one chat into Cloak's traces folder. Cloak itself sends nothing over the network for sharing. The Gateway does the checking, the asking and the upload.
- **Two things are unproven until someone tries one real chat.** Nobody knows yet whether the commons accepts an ordinary chat (its terms and wording are about coding agents), or whether a chat earns any credit. Trying it needs a NEAR AI sign-in in the Gateway, and that is Sean's step.
- **"See where your tokens go".** In the Gateway this means a log on the Mac of each call's model, tokens and cost. Cloak already receives NEAR's token counts with every answer and throws them away. Keeping them and showing them is the smallest true version.

## Sources

Saved copies are under `/tmp/cloak-build/near-traces-ref/`. All were fetched anonymously.

| Name used below | What it is |
| --- | --- |
| `gateway-index.txt`, `gateway-your-data.txt`, `gateway-download.txt` | Text of gateway.near.ai and its "Your data" and download pages |
| `tc-tnc.txt` | The "NEAR AI Gateway App Terms of Service", version 2026-11-10-draft.2, marked `in_effect: false` (`tc-terms.json`) |
| `near-tos.txt`, `near-privacy.txt` | The NEAR AI Cloud terms and privacy policy |
| `repo/…` | The public Trace Commons repository, github.com/TraceCommons/trace-commons, at commit `46aa4201` |
| `nearai-docs/…` | github.com/nearai/docs at commit `4c1f716e` |
| Cloak paths | `/Users/sean/Documents/regent/repos/cloak/…`, read as they are on `main` today |

---

## 1. How a trace reaches the commons

**The route, step by step.** NEAR's Gateway app or NEAR's command-line tool does every step. Neither Cloak nor any other app does any of them.

1. **Sign-in.** The person signs in to a NEAR AI account in the browser. The address is `cloud-platform.near.ai/v1/auth/github`, and the sign-in returns to the app on a local address (`repo/crates/trace-commons-contributor/src/near_ai_login.rs:1-33`).
2. **Device key.** The app makes a signing key for this Mac and enrolls it with the commons' issuer at `issuer.tracecommons.ai` (`/v1/enroll`, `/v1/onboard`; `repo/docs/trace-commons.md:665-677`).
3. **Upload pass.** For each upload, the app asks the issuer for a short-lived signed pass: `POST https://issuer.tracecommons.ai/v1/trace-upload-claim` (`repo/docs/trace-commons.md:603-608`).
4. **Redaction.** The app removes secrets on the Mac, then wraps the trace in the commons' envelope (below).
5. **Upload.** The app sends it to `POST https://ingest.tracecommons.ai/v1/traces`. The production addresses are in `repo/crates/trace-commons-contributor/src/channel.rs:102-117`.

**The format.**
- **Envelope.** `ironclaw.trace_contribution.v1` carries:
  - the person's consent choices (policy version 2026-04-24);
  - the name of the redaction step, `ironclaw-deterministic-secret-path-v3`, to which the server adds `+server-rescrub-v2`;
  - the events: user message, assistant message, reasoning, tool call, tool result, and a few more;
  - a channel: web, cli, telegram, slack, routine or other.

  Sources: `repo/docs/trace-spec.md:113-133`, `:148`, `:228-229`.
- **Files from other apps.** These come in as Letta Trajectory v1:
  - a JSON array or JSON lines;
  - the first record is `{"role":"meta","source":…}`, where `source` is a lowercase slug of letters, digits and hyphens, at most 64 characters, with optional `model` and `cwd` (`repo/crates/trace-commons-contributor-sources/src/source/trajectory.rs:22-47`, `:115-130`);
  - each later record has the role user, assistant, reasoning, tool, system or observation, an RFC 3339 `timestamp`, and its content (`trajectory.rs:96-110`, `:72-78`);
  - one malformed record rejects the whole file (`trajectory.rs:1-8`);
  - system records are read but their text is dropped (`trajectory.rs:175-195`).

**What must be redacted, and what is proven.**
- **On the Mac**, the app:
  1. replaces known secret patterns;
  2. runs a high-entropy pass after cue words;
  3. runs a check that refuses to send if a token leaked;
  4. runs a canary check per batch.

  Placeholders keep separate items apart, for example `<PRIVATE_EMAIL_1>` (`repo/docs/trace-commons.md:94-121`; `repo/crates/trace-commons-contributor/README.md:294-330`).
- **The app sends no message text to any classifier.** An older optional NEAR AI scan was retired in November 2026 (`repo/docs/trace-commons.md:110-115`).
- **The server redacts again.** An optional server-side check for personal details in prose ships switched off (`repo/docs/operator/pii-backstop.md:1-17`).
- **Each trace gets a risk level** (`repo/docs/trace-spec.md:194-201`):
  - any trace that carries message text is at least "medium";
  - only "low"-risk accepted traces are eligible for consumer export.
- **Proofs.**
  - Each upload is signed with a pass bound to the enrolled device key.
  - Scores come back as a signed document (`/v1/contributors/me/score-attestation`; `repo/docs/collector-integration.md`).

**What "new" and "real work" mean in code** (`repo/docs/trace-commons.md:50-68`; `repo/docs/trace-spec.md:335-358`):
- **New (novelty).** Three checks: an exact-duplicate hash, then summary similarity, then nearest-neighbour distance between embeddings.
- **Real work (substance).** The commons scores the whole trace's "perplexity", meaning how surprising the text is, under the model `Qwen/Qwen3.8-27B` on NEAR AI. It scores in chunks, at most 16 (`repo/crates/trace-commons-gate-enclave/src/perplexity_near_ai.rs:4-11`).
- **Credit quality, version 3** (`repo/crates/trace-commons-server/src/credit_quality.rs:78-88`):
  - perplexity must be at least 1.5 and at most 13.73;
  - novelty must be at least 0.5;
  - pending points are round(10 × credit quality, 2) (`repo/docs/trace-commons.md:212-215`).

**How credit is granted, and to whom.**
- **Credit needs the training use.** The person must allow "model training"; without it the award is withheld as `policy_mismatch` (`repo/docs/trace-commons.md:252-254`).
- **Points settle as NEAR AI credit** in the account or organization the person picks in the app, checked by their NEAR AI sign-in (`repo/docs/superpowers/specs/2026-10-21-nearai-credit-payout-design.md`, decision D1).
- **The rate is not published.** It is set by the operator and is not in the repository (same file, D2).
- **The terms describe credit as usage credit only:** "not legal tender, not redeemable for cash, not transferable" (`tc-tnc.txt:43`).

**Can another app submit, and do the terms allow it?**
- **Documented route: hand files to NEAR's own app.**
  - The Gateway lets the person add "a folder of exported traces" (`gateway-download.txt:62`; `gateway-index.txt:39`).
  - In that folder, every direct `.json` or `.jsonl` file is read (`trajectory.rs:300-345`).
  - The folder's row says: "Exports here always wait for you; none is sent automatically." (`repo/crates/trace-commons-contributor/src/source_copy.rs:359-361`). The file watcher says the same: trajectory files "always wait for a person" (`repo/crates/trace-commons-contributor/src/daemon/watcher.rs:43-46`).
  - The command-line tool also takes trajectory files (`repo/README.md:500-547`).
- **An app talking to the commons directly is possible in code but not documented as a route.**
  - The client crates are MIT or Apache-2.0 and "may be embedded in proprietary software" (`repo/LICENSE:25-45`).
  - No document invites another app to enroll its own users, and none describes how.
- **Terms.**
  - The only terms found cover "the NEAR AI Gateway desktop application, its command-line tools and the services reached through them" (`tc-tnc.txt:23`). They neither invite nor forbid a third-party client.
  - Handing a file to the Gateway through its documented folder is "ordinary documented use of the App" (`tc-tnc.txt:52`).
  - The terms are a draft that is not yet in effect (`tc-terms.json`).
  - They refer to separate "Trace Commons Terms and Conditions" that I could not find; `/about/tnc` shows the Gateway terms.

## 2. Ordinary chats, or only coding sessions?

- **The format takes a plain chat:** a meta record, then user and assistant records, with no tools. NEAR's own agent, IronClaw, sends from web, Telegram and Slack channels too (`repo/docs/trace-spec.md:148`).
- **But everything around the format is about coding agents:**
  - the terms define a trace as "a redacted record of one agent session: the conversation, the tool calls and their results" (`tc-tnc.txt:34`);
  - the uses on offer are "Training coding models, building benchmarks and training evaluators" (`tc-tnc.txt:35`);
  - the Gateway says "A trace is the record your coding agent keeps from a session" (`gateway-index.txt:64`);
  - the consent wording in the app is framed around coding agents (`repo/crates/trace-commons-contributor/src/daemon/enroll.rs:22-50`).
- **Would a Cloak NEAR chat be accepted?**
  - Probably as a well-formed trace. Acceptance itself is unverified.
  - It would be "medium" risk at least, because it is all message text. Medium may be held for human review (`repo/docs/trace-spec.md:354`), though the same document says redaction alone is "not evidence against admission" (`:200`).
  - My own reasoning, unverified: the answers were written by Qwen3.8-27B, the same model that scores them. Its own text is unsurprising to it, so a chat may fall under the 1.5 perplexity floor and earn nothing. Only a real try settles this.
- **Would a Cloak Agent task be accepted?** The question doesn't arise. Agent runs only in V and Token Inference, never in NEAR mode (decision 26, `/Users/sean/Documents/regent/repos/cloak/docs/plan.md:3382-3388`). Cloak also keeps only each step's tool name and a short detail, not full tool results (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Conversation.swift:50-77`).

## 3. Does NEAR share anything automatically when it answers?

**Sean is partly right.**

- **NEAR's apps can share automatically after an opt-in.**
  - In the Gateway, each folder is set to "Ask each time", "Automatic" or "Never". Automatic sends older traces first, and only traces unchanged for 24 hours (`gateway-your-data.txt:23-24`).
  - IronClaw can run a sharing pass after each turn once its owner opts in (`repo/docs/trace-commons.md:410-415`).
  - Sharing is "off by default" (`repo/README.md:113-127`), and "Nothing is shared without your review" (`gateway-index.txt:64`).
- **NEAR AI Cloud, which Cloak's NEAR chats use, shares nothing when it answers.**
  - Its terms license customer data "solely for the purpose of providing the Services", and "NEAR AI will not use Customer Data to train any generative AI models" (`near-tos.txt:135-136`, section 10.2).
  - Requests can run without being stored (`nearai-docs/cloud/guides/stateless-responses.mdx:14-17`).
  - Its API description has no trace, sharing or consent option at all.
  - It does keep usage records: model, tokens, cost and times (`near-privacy.txt`; `nearai-docs/cloud/guides/usage-reporting.mdx:243-288`).
- **Today, nothing from a Cloak NEAR chat reaches the Trace Commons.** The plan says so: "Not taken: trace collection or upload" (`/Users/sean/Documents/regent/repos/cloak/docs/plan.md:3053-3066`).

## 4. "See where your tokens go"

- **In the Gateway**, this is the line on its front page (`gateway-index.txt:13`). It means:
  - a log on the Mac of "Each call's model, tokens and cost" (`gateway-index.txt:27-28`), stored per call with token counts and a cost figure (`repo/crates/trace-commons-contributor/src/routing/managed_history.rs:18`);
  - Insights: "Tokens, models and sessions by week, counted on your Mac" (`gateway-index.txt:62`).
- **The Gateway is strict about calling a list price a price, not a bill.** "'list price', 'would have cost', 'priced at' are honest; 'you spent', 'your bill', 'cost you' are not" (`repo/crates/trace-commons-contributor/src/pricing.rs:1-9`).
- **What Cloak already has.**
  - Every NEAR answer arrives as NEAR's full reply, including `usage` (prompt and completion tokens) and the response id (`/Users/sean/Documents/regent/repos/cloak/guest/near/README.md`, the answer format, around lines 469-500).
  - Cloak reads only the text and drops the rest (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Near.swift:180-207`, which uses `Remote.content(of:)`).
- **Smallest true version.** Keep NEAR's token counts on each answered turn. Show the model and the tokens on each message, behind a small symbol, and a total for the chat. It needs no new request and no guess.
- **Cost on top, two ways (Sean's decision 2):**
  - **Estimate.** Tokens × NEAR's published per-token price from `/v1/model/list`, labelled "list price". This is one public request now and then, on the same route as NEAR chats.
  - **Exact.** NEAR's `POST /v1/billing/costs` with the person's key, one extra request per message. That endpoint is marked deprecated and is moving (`nearai-docs/cloud/guides/usage-reporting.mdx:243-288`).

---

## 5. The design

### 5.1 Route

**Recommended: hand chats to the Gateway.**
- Cloak writes a NEAR chat the person picks as one Letta Trajectory file in Cloak's traces folder.
- The person adds that folder once in the Gateway as "Exported traces".
- From there the Gateway does what it already does for every outside file: removes secrets, shows the trace before and after redaction (`gateway-index.txt:50`), waits for approval every time (`source_copy.rs:361`), and uploads with the person's own sign-in and consent choices.

**Not chosen:**
- **Cloak uploads directly by embedding NEAR's client.** That means a second NEAR AI sign-in inside Cloak, device keys, accepting draft terms, and building the Rust redactor into a Swift app. It is weeks of work against an undocumented route.
- **Writing into the Gateway's own staging folder.** That is another app's private state.
- **Running NEAR's command-line tool from Cloak.** That is someone else's code running on the person's Mac, outside the person's view.

### 5.2 What leaves the Mac, and by which route

- **NEAR chats today** go from Cloak to the `cloak-near` helper. The helper checks the hardware proof and sends each request encrypted to the checked key. It goes direct by default, or through Tor when the person turns on Tor for NEAR (`/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/NearMode.swift:54-59`; `/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/AppSettings.swift:32-33`).
- **Sharing leaves by a different route.**
  - **Cloak sends nothing.** It writes a readable file on the Mac.
  - **The Gateway uploads**, from the Mac's own internet connection, to `issuer.tracecommons.ai` and `ingest.tracecommons.ai`, signed in to `cloud-platform.near.ai`.
  - **That route has no Tor setting.** The Gateway's terms fetch turns proxies off outright (`repo/crates/trace-commons-contributor/src/terms.rs:126-127`). I did not trace whether its uploads follow a system-wide proxy.
  - **So a person who uses Tor for NEAR shows their real internet address and their NEAR AI account when they share.**
- **What's in the file.** Exactly what NEAR received and answered, and nothing more:
  - for each answered turn, the message as sent (`Turn.sent`: the reworded text, or the original when the person chose to send it as written) and NEAR's answer;
  - this is the same rule Cloak already uses to build the request (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Remote.swift:354-363`);
  - never the original of a reworded message, no unanswered turn, no hardware proof, no key, no route.
- **Redaction.** Done by the Gateway, which shows the person the trace before and after. Cloak adds no redaction of its own: what the person sees in the Gateway is what goes.
- **Does the person see each trace before it goes?** Yes, every time. Files in an "Exported traces" folder are never sent unattended, whatever the person's folder rules say (`watcher.rs:43-46`; `source_copy.rs:359-361`).

The file Cloak writes, `<chat id>.json`:

```json
[
  {"role": "meta", "source": "cloak", "model": "Qwen/Qwen3.8-27B"},
  {"role": "user", "timestamp": "2026-11-20T09:14:03Z", "content": "…as sent…"},
  {"role": "assistant", "timestamp": "2026-11-20T09:14:03Z", "content": "…NEAR's answer…"}
]
```

- **No `cwd`.** A chat has no working folder.
- **Timestamps.** Cloak keeps no time per message (`Conversation.swift:10-19`, `:54-77`), so every record carries the chat's start time. This is honest about when the chat began and invents nothing. Inventing times would be close to what the terms forbid ("fabricate… sessions", `tc-tnc.txt:52`).

### 5.3 What it must never do, and how the design makes that hold

| Never | How |
| --- | --- |
| Share a V, Token Inference, Local Llama or Agent chat | "Share Trace" appears only on chats marked NEAR (`Conversation.near == true`), and the writer takes only those. V, Token Inference, Local Llama and Agent chats never carry that mark. |
| Share without the box on | The menu item exists only while the box is on. Turning the box off deletes Cloak's files (after asking, if there are any). |
| Share a chat from before the box was on, unless picked | Nothing writes a file except the person choosing "Share Trace" on that one chat. There is no "share all", no background pass, and nothing happens when the box is turned on. |
| Send anything itself | Cloak has no network code for sharing. Only the Gateway uploads, and only after the person approves in the Gateway. |
| Leave a readable copy where it travels | The folder is excluded from Time Machine and kept out of Spotlight. It is not in iCloud-synced Documents. |

### 5.4 Where it sits, the states, and the exact words

All of it is in the NEAR wallet sheet (`/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/WalletView.swift:141-167`, `NearPayment`) and the chat list's menu (`/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/ChatView.swift:103-105`). Symbols sit on the surface and words go in tooltips, following Sean's "symbols over words".

**NEAR wallet sheet: a second section below "Key".**

| State | What shows |
| --- | --- |
| Off (first state) | A toggle, **Share traces**, off. Footer: "Pick NEAR chats to hand to NEAR's [Gateway](https://gateway.near.ai) app, which can earn NEAR AI credit. The Gateway shows you each one before it's sent." |
| On, none handed over | The toggle, on. A row, **Folder**, reading "Traces", with two symbol buttons: `doc.on.doc` (tooltip "Copy Path") and `folder` (tooltip "Show in Finder"). Footer: "Add this folder to the Gateway as Exported traces, then choose Share Trace on a NEAR chat. A sent trace can be licensed to others, and withdrawing it can't recall copies already passed on." |
| On, some handed over | As above, plus a row, **Traces**, showing the count, for example "2". |
| Turning off with traces in the folder | A dialog titled "Remove 2 traces?" with the body "The copies in the traces folder are deleted. Traces the Gateway already sent stay with the Trace Commons until you withdraw them there." The buttons are **Remove Traces** (destructive) and **Cancel**, which keeps the box on. With no traces, the box turns off at once. |

**Chat list.** These only appear on NEAR chats, while the box is on.

| State | What shows |
| --- | --- |
| A NEAR chat with at least one answered message, not handed over | Its menu (right-click) gains **Share Trace**, which writes the file. Nothing else happens. |
| Handed over | The row shows the symbol `arrow.up.doc`, with the tooltip "Handed to the Gateway" and the accessibility label "Trace handed over". The menu shows **Remove Trace** in place of Share Trace. |
| The chat grew after it was handed over | No change. The file stays as it was, and Cloak doesn't rewrite it. A rewritten file counts as a new session in the Gateway (a file's identity is the hash of its bytes), so it would compete with the first as a near-duplicate. To share the longer chat, the person removes the trace and shares again. |
| Writing failed | An alert titled **Not saved**: "Couldn't save the trace. Check free space and try again." |

**Two notes on these words:**
- No copy says "private", "protected" or "equivalent".
- "Remove Trace" removes only Cloak's copy. The sheet's footer says that withdrawal happens in the Gateway, so nobody mistakes removal for withdrawal.

**Folder.** Cloak makes the folder `~/Library/Application Support/Regents Cloak/Traces`, with these settings:
- owner-only, like the chats folder;
- excluded from backups (`isExcludedFromBackup`);
- kept out of Spotlight. Which method works for a folder inside `~/Library` (a marker file, or a `.noindex` folder name) is for the builder to check; see section 7, item 9.

The Gateway may add folders through a file picker, and `~/Library` is hidden in pickers. "Copy Path" lets the person press ⇧⌘G in that picker and paste. This is the chief's choice; an alternative is in section 7.

## 6. The cost to the person

- **What a shared trace reveals.** The text of the person's NEAR messages, as sent, and NEAR's answers.
  - The Gateway removes secrets, emails, file paths and similar patterns. It doesn't remove ordinary personal facts written in prose, such as names, health or money.
  - The prose check on the server ships switched off (`repo/docs/operator/pii-backstop.md:1-17`).
  - The `source` field tells the commons the trace came from Cloak (`trajectory.rs:33-35`).
- **To whom.**
  - **K&Z Partners LLC (the "Trace Licensor")** receives and holds traces, and may license them to third parties, "including for a fee", within the person's consent choices (`tc-tnc.txt:23`, `:35`, `:54`).
  - **Possibly people at the commons.** Medium-risk traces may be held for human review (`repo/docs/trace-spec.md:354`).
  - **The trace is tied to the person's NEAR AI account and to the Mac's internet address at upload.**
- **For which uses.**
  - Debugging and evaluation are always allowed.
  - "Training coding models, building benchmarks and training evaluators" only if turned on (`tc-tnc.txt:35`).
  - **Earning credit requires turning model training on** (`repo/docs/trace-commons.md:252-254`).
- **Can it be taken back? Only partly.**
  - The person can withdraw a trace at any time in the Gateway.
  - The commons then deletes it from active systems "within a reasonable time", and from backups "on their normal cycle".
  - "Copies already distributed or licensed to third parties… cannot be recalled", and credit already recorded stays (`tc-tnc.txt:39`).
  - Uninstalling the Gateway is not withdrawal (`repo/README.md:428-431`).
  - A trace left undecided is dropped after 14 days without being sent (`tc-tnc.txt:38`).
- **On the Mac.** A handed-over chat sits unsealed in the traces folder until it's removed. Saved chats themselves stay sealed (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/ConversationStore.swift:5-9`).

## 7. Size of the work, files touched, and what I couldn't determine

**Sharing (export only): small, about 200 lines and a day with checks.**

| File | Change |
| --- | --- |
| `/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/AppSettings.swift` | One setting, `nearTraces`, off by default |
| `/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/WalletView.swift` | The second section in `NearPayment`: toggle, Folder, Traces, footer, dialog |
| `/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/NearTrace.swift` (new) | Builds the trajectory from a NEAR conversation using the same rule as `Remote.messages`; writes, lists and removes files; sets up the folder |
| `/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/ChatView.swift` | Share Trace and Remove Trace in the menu, the row symbol, the Not saved alert |
| CloakChat tests | After it works: the file has only answered turns and only the sent text, and nothing is written for a chat that isn't NEAR |
| `/Users/sean/Documents/regent/repos/cloak/README.md`, `/Users/sean/Documents/regent/repos/cloak/docs/state-machines.md` | Wherever they say what leaves the Mac |

**Tokens: about 80 more lines.**
- `/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Near.swift` and `/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Remote.swift`: read `usage` beside the content.
- `/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Conversation.swift`: optional token counts on a turn.
- `/Users/sean/Documents/regent/repos/cloak/app/Sources/RegentsCloak/NearMode.swift`: pass the counts on.
- The message view: show them.

**What I couldn't determine:**
1. **Whether the commons accepts a plain chat at all**, and whether it ends up medium-risk accepted or held for review.
2. **Whether a chat can earn credit.** The answers come from the same model that scores them, so they may fall below the 1.5 floor. The credit rate isn't published.
3. **How the Gateway adds a folder** (picker or typed path), and whether `~/Library/Application Support` is easy to reach from it.
4. **What the Gateway does if a file it already queued is deleted** from the folder.
5. **Whether the Gateway's uploads follow a system-wide proxy.** Only its terms fetch is known to refuse proxies.
6. **The separate "Trace Commons Terms and Conditions"** named in the Gateway terms: not found.
7. **Whether NEAR objects to an app other than a coding tool** using the Exported traces folder. The terms are a draft and silent on it.
8. **Where the Gateway's per-call cost figure comes from.** The service that writes it isn't in the public repository.
9. **The surest way to keep the traces folder out of Spotlight.** This is checked on the Mac at build time, on a test folder, never on the real Regents Cloak folder.

Items 1, 2 and 4 are settled by one real try: Sean signs in to the Gateway, adds the folder, shares one harmless NEAR chat, and watches what the Gateway and the commons report.

## 8. Decisions only Sean can make

**1. Build the "Share traces" box this way?**
- **What changes:** the Cloak Mac app (the NEAR wallet sheet and the chat list's menu), and the Cloak README. NEAR's Gateway does all the uploading, with the person's own NEAR AI account.
- **a)** Build it as designed: Cloak writes picked NEAR chats into a folder, and the Gateway asks before each one goes.
- **b)** Hold until a real try (decision 3) shows a Cloak chat is accepted and earns something.
- **c)** Build Cloak's own uploader instead. That means weeks of work, a second sign-in inside Cloak, and an undocumented route.
- **Recommendation: b.** The commons is built and worded for coding sessions, and a chat may earn nothing. One try first avoids shipping a box that leads nowhere. If you'd rather have it in place now, **a** is safe: nothing leaves without the Gateway asking.

**2. "See where your tokens go": what does Cloak show?**
- **What changes:** the Cloak Mac app's NEAR chats. Each message would show its tokens behind a small symbol, plus a total for the chat.
- **a)** Tokens only, from what NEAR already sends with each answer. No new request.
- **b)** Tokens plus an estimated "list price" from NEAR's public price list, which is an occasional extra public request.
- **c)** Tokens plus the exact charge from NEAR's billing, which is one extra request per message with your key, to an endpoint NEAR is retiring.
- **d)** Nothing for now.
- **Recommendation: a.** It is true, free, and matches the page's words. A price can come later without undoing anything.

**3. Who makes the first real try?**
- **What changes:** nothing in any repository. It needs a NEAR AI sign-in in NEAR's Gateway app on your Mac, and a choice of consent settings. Earning credit requires allowing model training.
- **a)** You sign in, add a test folder, and share one harmless NEAR chat that I prepare. I read what comes back.
- **b)** Skip the try and decide on what's written.
- **Recommendation: a.** It answers whether chats are accepted and whether they earn credit, and it takes a few minutes. Sign-in is yours to do.

**4. The public page's NEAR line ("…opt-in to earn NEAR AI Cloud inference credits for the traces you choose to share").**
- **What changes:** the Cloak page on regents.sh, which is owned by the Regents chief.
- **a)** Keep it as it is.
- **b)** Keep it, but only once the box ships and one real chat has earned credit.
- **c)** Soften it now to "and choose chats to share with NEAR's Trace Commons".
- **Recommendation: b.** Today no Cloak chat can be shared and none has earned credit. The words become true the day both happen.
