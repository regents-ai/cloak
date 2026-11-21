# Trace sharing in NEAR Private AI, the receipt way

A reading for the Cloak chief, 21 November 2026, following Sean's decision 34 c. Part 1 of the brief, written before the build; section 7.1 records what was built, and the corrections of the fixing pass after it are marked "Read further" where they change this reading. Nothing was signed in, enrolled, keyed, uploaded or run of NEAR's or the commons'. All reading was of saved copies of public source and documents.

## Short answer

- **Can a client other than NEAR's Gateway complete the receipt route? Yes, as the source reads, with nothing from NEAR or the commons.** No step checks which app is asking: there is no app attestation, build signature, client id, allowlist or key that only the Gateway holds. The device key is one the client makes itself. The witness is open to anyone by design. The evidence route needs no `source_session` and none of the five named coding tools. Details and lines are in section 2.
- **It cannot be built as the brief describes it without Sean deciding three things first.** These come from how the route works, not from anything NEAR would have to grant:
  1. **The shared message cannot be end-to-end encrypted.** NEAR's receipt signs a hash of the exact bytes Cloak sends and gets back. Cloak seals every word in those bytes for the model's key. The commons' witness must hash and read those same bytes. So a sealed chat can only be shared as unreadable ciphertext. A readable shared chat means its message goes to NEAR without Cloak's end-to-end encryption, which is how NEAR's own Gateway app sends every request. That is more than "carry what the receipt route needs, and no more".
  2. **The unredacted chat goes to the commons before any "after" view exists.** The redaction is done by the commons' witness, so the full last request (which holds the whole chat) and its reply must be sent to it first. In production, the witness then sends part-redacted text, with names and other prose details still in it, to NEAR AI's own classifier model under the commons' key. (Read further: for a Cloak chat it sends none of the chat's words, which it takes out before it redacts, section 1.6.) "Nothing is sent without that press" needs two presses: one to send the chat to the witness, and one to share what comes back.
  3. **Cloak cannot use its own redactor.** The upload must be the witness's exact bytes, because the server checks their hash. The one redactor on this route is the commons' witness, and it is not deterministic only: it runs NEAR AI's prose classifier after its fixed rules.
- **One time limit also shapes the design.** The challenge lasts at most 15 minutes, and the upload must arrive before it runs out. A chat can only be shared within 15 minutes of the message that carried the challenge.
- **What I recommend.** Put decisions 1 and 2 (section 9) to Sean, and build only once both are answered. If both are yes, the simplest design is in section 7. Only a chat the person chooses to share sends one request unencrypted, and that request carries the whole chat so far. Every other NEAR request stays exactly as it is today.

## Sources

All copies are under `/tmp/cloak-build/near-traces-ref/`. The new ones for this reading were fetched with `gh api` from the public repositories, and the earlier ones anonymously.

| Name used below | Full path |
| --- | --- |
| `protocol/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-protocol/src/…` (MIT or Apache-2.0) |
| `contributor/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-contributor/src/…` (MIT or Apache-2.0) |
| `server/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-server/src/…` (AGPL; read only) |
| `ingest/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-ingest/src/bin/trace_commons_ingest_internal/…` (AGPL; read only) |
| `repo/…` | `/tmp/cloak-build/near-traces-ref/repo/…`, Trace Commons at commit `46aa4201fa7ebc122587a99b8d821a23953560a7` |
| `nearai/…` | `/tmp/cloak-build/near-traces-ref/nearai-docs/…`, NEAR AI's public docs at commit `4c1f716e1779780c76f31fe9cd21903500a5ca9d` |
| `cloud-api/…` | `/tmp/cloak-build/near-traces-ref/cloud-api/…`, NEAR AI's public `cloud-api` source at commit `c77cfb0347ba2cd7719a2308b53731ffe7720c82`, saved flat: `auth.rs` is `crates/api/src/routes/auth.rs`, `auth-service.rs` is `crates/services/src/auth/mod.rs`, `api-lib.rs` is `crates/api/src/lib.rs`, `routes-api.rs` is `crates/api/src/routes/api.rs`, `credit_transfers.rs` is `crates/api/src/routes/credit_transfers.rs` and `org-credentials.rs` is `crates/api/src/middleware/organization_credentials.rs` |
| `tc-terms.json`, `tc-privacy.txt` | `/tmp/cloak-build/near-traces-ref/…`, the live terms (version `2026-11-10-draft.2`, not in effect) and privacy page |
| Cloak paths | `/Users/sean/.t3/worktrees/cloak/t3-fbee151c-e032f46ed7cb9ba3/…`, this checkout at `0aafe59`. The later commits on `main` change none of the Cloak files cited here. |

These were newly fetched for this reading:

- `repo/docs/operator/invite-free-admission.md`
- `repo/docs/operator/native-admission-session.md`
- `repo/docs/operator/attested-inference.md`
- `repo/docs/operator/pilot-account-admission-cutover-2026-10.md`
- `repo/deploy/witness/README.md`
- four design notes from 4 and 5 September under `repo/docs/superpowers/specs/`
- `contributor/daemon/admission_setup.rs`
- `contributor/daemon/account_admission.rs`
- `contributor/daemon/approved_envelope.rs`
- `contributor/routing/receipt.rs`
- `contributor/routing/mod.rs`
- `contributor/witness/mod.rs`, `transport.rs`, `configuration.rs` and `verify.rs`
- `contributor-sources/routing/attested.rs`, `mod.rs` and `enriched.rs`
- `server/admission_evidence.rs`
- `server/witness_service/mod.rs`, `surface.rs`, `inference.rs` and `http.rs`
- `repo/macos/Sources/TraceCommonsApp/Views/AdmissionPreparationView.swift`
- `repo/macos/Sources/TCBridge/TCWitness.swift`
- `nearai/cloud/verification/cloud-api/response-signatures.mdx`
- `nearai/cloud/verification/reference/response-signature-verification.mdx`
- `nearai/cloud/guides/e2ee-chat-completions.mdx` (fetched again)

---

## 1. The receipt route end to end, as the Gateway does it

There are seven steps. Step 1 happens once, at setup. Steps 2 to 7 happen for each shared call.

### 1.1 An account and a device (once)

- The person signs in to NEAR AI in the browser. The device then enrols with the commons and becomes a tenant named `nearai-` plus 64 hex characters (`contributor/daemon/nearai_onboarding.rs:67-69`, `:116-132`). Section 3 has the detail.
- The device key is an Ed25519 key that the client makes and keeps itself (`contributor/identity.rs:65-75`).

### 1.2 An upload claim (before each challenge and each upload)

- `POST https://issuer.tracecommons.ai/v1/trace-upload-claim`, signed by the device key over the exact body. The headers are `x-trace-device-key-id` and `x-trace-device-signature` (`contributor/identity.rs:26-27`; `contributor/issuer_client.rs:153-162`).
- The answer is a short-lived bearer token. The consent scopes are stamped into it.

### 1.3 The challenge: which service, which call, what sign-in

- **Service:** the commons' ingest, `https://ingest.tracecommons.ai` (`contributor/channel.rs:102`).
- **Call:** `POST /v1/admission/challenge`, with the upload claim as bearer and no body (`contributor/daemon/admission_setup.rs:334-348`).
- **Sign-in needed:** an enrolled device's claim only. The server authenticates the claim, looks up the account's anchor and allows 10 challenges a minute per account (`ingest/admission.rs:1093-1113`).
- **Answer:** `{"binding": "tcad1:<account anchor>:<nonce>:<expiry>", "expires_at": …}`.
  - The anchor is 64 hex characters for this account. The nonce is 32 random bytes.
  - The expiry is at most 15 minutes away (`ingest/admission.rs:1114-1141`; the format is in `protocol/admission.rs:296-338`).
  - Only the binding's hash is stored, as a single-use challenge for this account (`ingest/admission.rs:1126-1137`).
- **The Gateway's checks:** it checks the binding's shape, that it is in the `near-` or `nearai-` namespace, and that the expiry matches and is no more than 15 minutes away (`contributor/daemon/admission_setup.rs:432-461`).

### 1.4 How it rides on the request to NEAR AI

- The binding goes inside the chat request's JSON body, as `metadata.trace_commons_admission` (key name in `protocol/admission.rs:8`).
- In the Gateway, the person picks a coding-tool session and presses Prepare. The daemon then registers the binding with its local proxy, IronWire, for that session's **next** request (`contributor/daemon/admission_setup.rs:249-397`; `repo/docs/operator/native-admission-session.md:3-7`). The proxy adds the field "after all upstream request transforms" (`protocol/admission.rs:296`).
- "Existing inference calls cannot be retroactively bound" (`native-admission-session.md:7`).
- The request is otherwise an ordinary NEAR AI Cloud request. The commons' code has no end-to-end encryption anywhere: a search of the saved source for NEAR's encryption headers finds none.

### 1.5 The receipt NEAR AI gives back

- **Where it comes from:** the completion's own `id` (or the `resp_…` id for the Responses API) is the key to a separate call:

  `GET {receipt endpoint}/signature/{id}?model={model}&signing_algo=ed25519`

  (`contributor/routing/receipt.rs:3-4`, `:339-366`; `nearai/cloud/verification/cloud-api/response-signatures.mdx:26-34`).
  - The endpoint is published by the commons at sign-up (`native-admission-session.md:22-29`).
  - NEAR's docs send the account's API key with it.
- **What it holds:** `text`, `signature`, `signing_address`, `signing_algo` and `signature_kind`.
- **What `text` says** (`response-signatures.mdx:43-48`):
  - For a `provider_tee` receipt, `text` is `<model>:<request_hash>:<response_hash>`, signed inside the model's enclave.
  - For a `gateway` receipt, it is `<request_hash>:<response_hash>`, signed by NEAR's gateway.
- **What the hashes cover.** They are SHA-256 of the **exact request-body bytes the client sent** and of the **exact response-body bytes**. NEAR's words: "Do not parse and re-serialize JSON, normalize whitespace … or reconstruct a streamed response" (`response-signatures.mdx:13-23`).
- **What this tells NEAR.** Fetching the receipt tells NEAR that this call is about to be contributed (`contributor/routing/receipt.rs:35-46`).

### 1.6 The witness: what it is and who runs it

- **What it is.** The commons' redaction service, run by the commons in an Intel TDX enclave on Phala's dstack (`repo/deploy/witness/README.md:1470-1471`, `:1518-1527`).
  - It "holds every raw transcript that passes through it", in memory only (`README.md:62-80`).
  - "The contributor pins the measurement before sending. A client that cannot verify must refuse to send" (`README.md:88-89`). The client gets the pin from the commons at sign-up, "a trust-on-first-use authority" (`native-admission-session.md:120-122`).
- **No sign-in.** "Both routes are unauthenticated -- deliberately" (`server/witness_service/http.rs:27-30`).
- **The call:** `POST /v1/witness/admission` (`server/witness_service/http.rs:145`, `:1087-1131`). The body has four parts (`contributor/witness/transport.rs:505-560`):
  - `raw_contribution`: the unredacted trace;
  - `granted_scopes` and `granted_uses`;
  - `inference_receipt`: the receipt from 1.5.
- **What it checks** (`server/admission_evidence.rs:267-360`; `server/witness_service/surface.rs:340-376`):
  1. The trace has exactly one event, and it is an HTTP exchange.
  2. The request and response bytes in it hash to the receipt.
  3. The receipt is Ed25519, from a pinned signer, for an accepted model, and at least a minimum size.
  4. The request body's `metadata.trace_commons_admission` parses and has not expired.
- **What it then does.**
  1. It trims the trace to that one call: the request body and the reply, with tool outcomes, times, token counts and the conversation id taken out (`server/admission_evidence.rs:405-455`).
  2. Read further: it then takes the request and reply bodies, and their headers, out of every HTTP exchange before it redacts, and out of the envelope again before it signs (`server/witness_service/mod.rs:1095`, `:1127`; `server/witness_service/inference.rs:1017-1073`). `/v1/witness/admission` reaches that code through `server/witness_service/http.rs:1088-1106` and `server/witness_service/surface.rs:340-372`. A Cloak trace is one HTTP exchange and nothing else, so neither the redactor nor the envelope gets any of the chat's words: what is shared is the trace's record of the call, not the conversation. The witness itself still receives the whole chat, to check it against the receipt.
  3. It redacts what is left. Production runs "`full-pipeline` with the NEAR AI classifier": a fixed-rule pass first, then NEAR AI's `openai/privacy-filter` model at `cloud-api.near.ai`, under the commons' own NEAR AI key. "sends partially-redacted text out of the enclave … prose PII is still present in what leaves" (`README.md:758-762`, `:765-768`, `:1523-1527`).
- **What it answers** (`server/witness_service/http.rs:1112-1130`; `server/admission_evidence.rs:456-495`):
  - the redacted envelope as the body;
  - a certificate and signature in `x-trace-witness-certificate` and `x-trace-witness-signature`;
  - the admission evidence in `x-trace-admission-evidence` and `x-trace-admission-signature`.

### 1.7 The upload, and what the server checks

- **The upload:** `POST /v1/traces` on the ingest, with the upload claim as bearer, the two witness headers and the two evidence headers. The body is the witness's envelope, byte for byte.
- **What the evidence is.** A JSON `AdmissionEvidence` (`protocol/admission.rs:152-184`) holding:
  - the account anchor;
  - the challenge's hash;
  - the provider signer and kind;
  - the model and the request size;
  - the request, response and receipt hashes;
  - **the hash of the envelope** (`artifact_sha256`);
  - the witness measurement and the redaction policy version;
  - when it was issued, and **an expiry equal to the challenge's** (`server/admission_evidence.rs:478`, `:485`).
- **The signature** is the witness's, over fixed, length-prefixed bytes (`protocol/admission.rs:240-293`).
- **The "claim"** in the brief is the upload claim from 1.2. It is the bearer on the challenge and on the upload.
- **What the server checks, in order** (`ingest/admission.rs:604-633`; `server/admission_evidence.rs:542-602`):
  1. the witness certificate verifies;
  2. the redaction policy version is allowed;
  3. the evidence signature is the pinned witness's;
  4. the provider signer is trusted;
  5. the model is accepted and the size is at least the minimum;
  6. the anchor is this account's;
  7. **the envelope's hash equals `artifact_sha256`**;
  8. the measurement and policy match;
  9. the evidence has not expired;
  10. the receipt identity is right.
- **Then the ledger** reserves the submission. A receipt and a challenge can each be used once. Budgets are counted per account and in total, and never refill (`repo/docs/operator/invite-free-admission.md:224-232`, `:671-673`).
- **Without the evidence headers,** a new upload from a `near-` or `nearai-` account is refused (`ingest/admission.rs:296-302`, `:544-556`).

---

## 2. Can a client other than the Gateway complete it?

### 2.1 What the source says: possible, nothing needed from NEAR or the commons

1. **No check of which app is asking.** A search of the saved server, ingest and client source finds no check on a user agent, client id, app attestation, team id or build signature. The only user agent is the commons' own payout client (`server/near_ai_transfer.rs:37`).
   - The device key is one the client generates (`contributor/identity.rs:65-75`). The server checks signatures against the key it enrolled, not against a list of apps.
2. **The NEAR AI sign-in has no client id.** The Gateway opens `https://cloud-platform.near.ai/v1/auth/{github|google}?frontend_callback=http://127.0.0.1:{port}{path}` (`contributor/daemon/nearai_credential/api.rs:406-430`). NEAR AI accepts any `127.0.0.1` callback on plain `http` (`:411-424`; `contributor/daemon/nearai_credential/loopback.rs:14-22`).
   - The Gateway's command-line tool hands sign-in to the Mac app only because of where it keeps the session in the keychain (`contributor/near_ai_login.rs:20-25`). The server does not ask for that.
3. **The witness takes requests from anyone** (`server/witness_service/http.rs:27-30`).
4. **The evidence route needs no `source_session` and no named adapter.** An upload "No `source_session`, a new submission, and offered evidence" goes to the evidence ledger (`ingest/admission.rs:324-351`, `:869-891`). The five named adapters (`protocol/trace_contribution.rs:217-225`) matter only on the other route.
5. **Nothing the Gateway holds is needed.** The challenge needs only the account's own claim, the receipt only the account's own NEAR AI key, and the witness nothing.

**Verdict on question 2: possible as the source reads, with nothing from NEAR or the commons.** Section 8 lists what the source cannot prove about production.

### 2.2 Why it still cannot be built as briefed

**(a) Cloak's end-to-end encryption and the receipt cannot both cover the words.**

- **What Cloak sends.** Every NEAR request goes out with `X-Encryption-Version: 2` and `X-Encrypt-All-Fields: true`. Every message's words are sealed for the model key that the proof checked (`guest/near/src/chat.rs:388-405`, `:456-492`). The body is built from the whole chat's messages (`app/Sources/CloakChat/Near.swift:182-193`).
- **What the receipt covers.** NEAR hashes "the exact request-body bytes" and "the exact response-body bytes" (`nearai/cloud/verification/cloud-api/response-signatures.mdx:13-23`). For `provider_tee`, those are "the bytes the model backend emitted" (`nearai/api-reference/openapi.json:25304`). With Cloak's encryption, both are ciphertext.
- **What the witness needs.** It hashes the request and response it is given and compares them with the receipt (`server/admission_evidence.rs:290-311`). It cannot open sealed fields, and nothing in the commons' code would.
- **So there are only two outcomes:**
  - The sealed message is shared, and the commons gets an unreadable trace. It would not pass review, and offering it would be misleading.
  - The message goes without Cloak's encryption, as NEAR's own Gateway app sends every request. NEAR's gateway then reads the words as well as the model's enclave. The gateway runs in its own enclave, which Cloak's proof already checks (`guest/near/src/verify.rs:178-202`).
- **One small change either way.** `metadata` must be allowed through: today the helper refuses any field outside its plain list (`guest/near/src/chat.rs:40-53`, `:487-488`). The binding holds no words of the person's.

**(b) The "after" is the witness's, and it needs the raw chat first.**

- The envelope the person would approve does not exist until the raw request (the whole chat so far) and the reply have been sent to the witness.
- In production, the witness sends part-redacted text to NEAR AI's classifier (section 1.6), though none of a Cloak chat's words, which it takes out first.
- The Gateway has the same order. Its witnessed review is an explicit step ("Explicit review only. Ordinary preview/card paths never call this", `contributor/submit.rs:1379`). Its prepare step needs a separate permission to export request bodies, plus a confirmation tick (`contributor/daemon/admission_setup.rs:236-259`; `repo/macos/Sources/TraceCommonsApp/Views/AdmissionPreparationView.swift:10-36`).

**(c) The redactor is the commons'.**

- The server refuses any envelope whose hash is not the one the witness signed (`server/admission_evidence.rs:478`, `:576-578`). A Cloak redactor could check the witness's output, as the Gateway's does (`contributor/submit.rs:1329`), but it could never produce the uploaded text.
- The witness's policy version is `ironclaw-deterministic-secret-path-v3+privacy-filter-near-ai-v2` (`README.md:1527`): fixed rules plus a model.

**(d) Fifteen minutes.**

- The evidence expires with the challenge (`server/admission_evidence.rs:485`, checked at `:588-590`), and the challenge is at most 15 minutes long (`ingest/admission.rs:1119`).
- All of it must fit in that window: the call, the receipt fetch, the witness (which can take minutes), the person's review and the upload.

---

## 3. The sign-in, the account, the terms and the choices

1. **NEAR AI sign-in, by browser hand-off. Cloak never sees a password.**
   - Cloak opens `https://cloud-platform.near.ai/v1/auth/github` or `…/google` with a `127.0.0.1` callback. The person signs in there.
   - NEAR AI sends the tokens back in the address's fragment. A small page from Cloak's own listener posts them back to a second address on the same listener (`contributor/daemon/nearai_credential/loopback.rs:4-12`).
   - A NEAR wallet sign-in is a separate path, where the wallet signs a login message (`contributor/daemon/nearai_credential/ceremony.rs:12-13`).
   - **What Cloak would then hold:** NEAR AI's refresh token and a short-lived session token. These can manage the account: list organizations and workspaces, mint API keys and read the balance (`contributor/daemon/nearai_credential/api.rs:563-700`, `:855-884`). Cloak needs them once, for enrolment, and should drop them straight after.
   - Cloak's entitlements are virtualization only, with no App Sandbox (`app/RegentsCloak.entitlements`), so a loopback listener needs no new entitlement.
2. **Enrolment.**
   - A production build calls `POST /v1/account/near-ai/provision/start`, then `…/finish`. The `/v2` routes are the staging build's (`contributor/daemon/nearai_onboarding.rs:71-86`). Section 1.2 of `docs/near-traces-incloak.md` named the `/v2` routes and is corrected with this note.
   - The NEAR AI session token goes in the body, never as an `Authorization` header. The client sends no account id (`:11-18`, `:39-41`).
   - The device signs a preimage that ties the nonce, the ceremony, its public key and a PKCE challenge together (`:22-31`, `:285`; the bytes are `protocol/onboarding.rs:232`).
   - **What the session token sent here is, and what its holder can do** (from `cloud-api/…` and the commons' server):
     - It is NEAR AI's access token: a signed token for the person's NEAR AI user, made at the browser sign-in together with a refresh session. It lasts one hour, and its refresh session seven days (`cloud-api/auth.rs:634-643`, `create_session(…, 1, 7 * 24)`; `cloud-api/auth-service.rs:84-99`). Every use checks that its session still stands, so a sign-out of that session ends it at once (`cloud-api/auth-service.rs:165-182`).
     - Until then, its holder can do as the person what NEAR AI's account pages do. It can make, change and revoke API keys in the person's workspaces and set their spending limits (`cloud-api/api-lib.rs:1898-1929`); a key made that way spends the person's credit on any model until it is revoked. It can move NEAR AI credit out of an organization the person owns (`cloud-api/credit_transfers.rs:41-50`, which takes the token as the owner, `cloud-api/org-credentials.rs:58-91`). It can create organizations, add members, and read the balance and usage (`cloud-api/routes-api.rs:52-87`), and list and revoke the person's sign-ins (`:89-95`).
     - It cannot read chats itself: NEAR AI's conversation routes take an API key only (`cloud-api/api-lib.rs:1784-1804`). A key it made could. Whether NEAR keeps Cloak's chat completions where such a key reads them is not established here.
     - Who holds it: the browser, for as long as the address shows it; Cloak's helper, from the sign-in until the enrolment's finish is sent; and the commons, which uses it once to ask NEAR AI whose it is (`GET /v1/users/me`) and by its own source never logs, stores or returns it (`server/near_ai_login.rs:21-26`, `:43-49`). Cloak's page takes it out of the address as it loads. The refresh token, which can make new access tokens for seven days (`cloud-api/routes-api.rs:96-105`), reaches Cloak's helper in the same address fragment and is not read (`guest/near/src/share.rs`, `fragment_token`).
     - Nothing in NEAR AI's source offers a narrower token: the sign-in makes one kind of session, with no scope to ask for (`cloud-api/auth.rs:634-643`). So Cloak asks for nothing narrower. The Gateway keeps the refresh token in the Mac's storage for later account reads (`contributor/daemon/nearai_credential/loopback.rs:53-58`); Cloak keeps neither token.
   - Result: a `nearai-…` tenant, an account access token and the device's key id (`:95-114`). The witness pin and the receipt endpoint come from what the commons publishes at sign-up (`:479-510`; `repo/docs/operator/native-admission-session.md:22-26`).
3. **Terms.**
   - The live document is `https://tracecommons.ai/legal/terms.json`: "NEAR AI Gateway App Terms of Service", version `2026-11-10-draft.2`, `in_effect: false` (`tc-terms.json`).
   - The Gateway shows the terms in full and unlocks the agree box only at the end. It hashes the bytes it showed and records the acceptance at `/v1/account/terms-acceptance` with the account session (`docs/near-traces-incloak.md` section 1.3).
   - The account session is a second browser sign-in with PKCE (`contributor/account_auth.rs:1-23`).
   - The terms are written for NEAR's app ("They govern your use of the NEAR AI Gateway desktop application, its command-line tools and the services reached through them", block 2). Their acceptable-use block forbids "fabricate, duplicate or manipulate sessions to earn credit" and "tamper with or bypass redaction" (block 31). A real Cloak NEAR call, witnessed as it is, does neither.
4. **Data uses.**
   - `debugging_evaluation` is always granted. `model_training` is needed for credit, and can be added later but never removed. `benchmark_only`, `ranking_training` and `public_attribution` are optional (`protocol/trace_contribution.rs:357-368`; `contributor/consent.rs:4-6`; `repo/docs/trace-commons.md:250-257`).
   - The Gateway also asks, on top, for permission to export request bodies, and for a tick per prepared session (`contributor/daemon/admission_setup.rs:236-248`).
5. **Can Cloak do all of it by browser hand-off?** Yes, for both sign-ins. Cloak types no password and stores no NEAR AI session after enrolment.
   - Kept in Cloak's keychain: the device key, and while it lasts, the account session for withdrawals and terms.
   - Each would be a new service, `sh.regents.cloak.traces`, beside `sh.regents.cloak.near`, which is left as it is.

---

## 4. What a shared chat costs the person

| What | To whom | When | Address |
| --- | --- | --- | --- |
| The shared message, unencrypted: the whole chat so far, and NEAR's reply | NEAR AI's gateway and model enclaves, under the person's NEAR key | When that message is sent | NEAR mode's route: Tor or direct, as today |
| The binding, `tcad1:<anchor>:<nonce>:<expiry>` | NEAR AI, inside that request | The same | The same |
| A claim request and a challenge request | The commons' issuer and ingest, under the person's commons account | Just before that message | Either route. The source has no rule about Tor (section 8). |
| The receipt fetch, which tells NEAR this call is being contributed (`contributor/routing/receipt.rs:35-46`) | NEAR AI | After the reply | NEAR mode's route |
| The raw last request and reply, unredacted | The commons' witness enclave, run for K&Z Partners LLC | At the first press (section 7) | Either route |
| Part-redacted text, with names and other prose details still in it; for a Cloak trace none of the chat's words, which the witness takes out first (section 1.6) | NEAR AI's `openai/privacy-filter` model, under the commons' key | Inside the witness's run (`README.md:758-762`) | Not Cloak's to choose |
| The witness's redacted envelope | The commons' ingest, kept by K&Z Partners LLC, the "Trace Licensor" (`tc-terms.json` block 2; `tc-privacy.txt:37`) | At the second press | Either route |
| The two browser sign-ins | NEAR AI, in the person's browser | Setup, and before a withdrawal | The browser's own. Cloak's Tor does not cover them. |

- **Whose account.** Uploads go under the commons account that enrolment tied to the person's NEAR AI login (`contributor/daemon/nearai_onboarding.rs:11-18`). The commons knows whose traces they are whatever the route.
- **Review.** Any trace that includes message text is rated at least Medium risk (`protocol/trace_contribution.rs:7272-7276`). Medium goes to quarantine "with zero immediate credit" until a person at the commons decides (`repo/docs/trace-commons.md:166-168`). Read further: a Cloak trace reaches the commons with no message text (section 1.6), so how it is rated is not established.
- **Credit.** Only for accepted traces, and only with `model_training` granted (`repo/docs/trace-commons.md:252-254`). It shows as pending, then settles as NEAR AI credit in the signed-in account: "sending alone earns nothing" (`tc-terms.json` block 21).
- **Taking it back.**
  - The call is `POST /v1/account/traces/{id}/withdraw`, with the account session (`contributor/withdraw.rs:3`, `:131-150`).
  - The content is deleted from active systems "within a reasonable time"; backups follow their cycle.
  - "Copies already distributed or licensed to third parties, including in a published export, benchmark or snapshot, cannot be recalled". Credit already recorded stays (block 18).

---

## 5. Redaction: embed the commons' crates, or write a Swift pass?

**Neither produces what is uploaded on this route.** The uploaded bytes must be the witness's (section 2.2 c), so the one redactor is the commons' witness.

What Cloak could still add is a check of the witness's output before showing it. The Gateway runs its own deterministic redactor over the returned envelope and refuses it if a secret shape survives (`contributor/submit.rs:1329`). For that check:

- **Embedding `trace-commons-protocol`** would be the commons' own rules, unchanged. Built without features, it makes no network calls and touches no keychain.
  - Cost: about 90 packages beyond what cloak-near has, and Rust edition 2024 (`docs/near-traces-incloak.md` section 2(a2)).
  - Trust: one more pinned outside crate in the NEAR helper.
- **A Swift pass** would be a second copy of thousands of lines of rules, which would drift from the witness.

**Recommendation:**

- First version: no redactor in Cloak. Show the witness's "after" exactly as it came, and upload exactly that.
- If Sean later wants a check on top, embed `trace-commons-protocol` unchanged in the NEAR helper, never a Swift copy.
- Cloak's rule "one redactor, deterministic, no fallback" cannot hold here as written: the one redactor is the commons', and it uses a model. That belongs in decision 2.

One more piece Cloak would need, whichever is chosen: a check of the witness enclave's Intel quote against the pin the commons publishes, before any raw text is sent to it (`README.md:88-89`). cloak-near already verifies Intel quotes with `dcap-qvl` (`guest/near/README.md:83`, "What `verify_intel` checks"). This would be a second pinned check of the same kind.

---

## 6. Licence: what may be copied

- The repository's `LICENSE` names its licences per crate. The client and protocol crates are MIT or Apache-2.0 and "may be embedded in proprietary software". The server crates are AGPL (`repo/LICENSE:3-45`).
- **`macos/` is not named in either list.** There is no licence file inside it (`/tmp/cloak-build/near-traces-ref/tree.txt` has none under `macos/`). The only other statement is the stale `repo/NOTICE` line "TraceCommons Server is distributed under MIT OR Apache-2.0".
- **So no file from `macos/` is copied,** although decision 34 said "you can copy that". Its screens are used for ideas only: the before-and-after review, the plain consent lines and the tick before Prepare. Cloak's own screens need nothing more from it.
- Code taken from the client crates, if any, keeps its MIT notice.

---

## 7. If Sean says yes: the smallest build

This assumes decision 1 a and decision 2 a (section 9). It follows the Gateway's own shape, "prepare the next call, then share it", and leaves out everything in section 4 of `docs/near-traces-incloak.md`.

1. **Share Traces**, a switch in the NEAR Wallet sheet, off at first. While it is off, nothing about sharing runs and every NEAR request is byte for byte what it is today.
   - Turning it on starts the NEAR AI sign-in in the browser. Enrolment, the terms and the data-use choices follow, each choice off at first except debugging, which cannot be turned off.
2. **One chat at a time.** On a NEAR chat, a share symbol readies that chat's **next** message.
   - That one message goes without Cloak's encryption and carries the binding. Like every NEAR request, it carries the whole chat so far, so all of the chat goes to NEAR unencrypted, not only the newest words. The chat says so before it is sent.
   - Every other NEAR message, in this chat or any other, stays sealed as today.
   - A chat that was never readied, or whose 15 minutes are over, shows the symbol switched off, with a few words saying why.
3. **Review**, after the answer comes back. Pressing it fetches the receipt, checks the witness, and sends the chat to the witness, as the sheet says beforehand.
   - The sheet then shows Before and After side by side, from the witness's answer.
4. **Share**, one press. It uploads exactly the envelope shown, with its four headers.
5. **Status**, one line on the chat: Sent, In review, Accepted, Not accepted or Withdrawn, as the commons' own status call answers it, and credit only when the answer shows some.
   - **Withdraw** opens the second browser sign-in when the session has run out.

Where it lives:

- The network steps join cloak-near, so that every call uses its existing direct-or-Tor connections and certificate checks: sign-in exchange, enrolment, claim, challenge, receipt, witness quote, witness, upload, status and withdraw.
- The device key and the account session are kept in the keychain under `sh.regents.cloak.traces`.
- One observable model with one named state goes into `docs/state-machines.md`.

Checks, against a stand-in server under a temporary folder:

- nothing goes to the witness or the ingest without its press;
- the uploaded body is byte for byte the envelope shown;
- a V, Token Inference or Local Llama chat, or an Agent task, cannot be readied or shared;
- with the switch off, a NEAR request is byte for byte today's.

**Size, honestly.** It is about ten new network calls against wire formats read from source and never seen live, plus a second enclave check and two browser sign-ins. It is a multi-day build. Its first real proof is a real share, which only Sean can make.

### 7.1 As built

Sean chose 1 a and 2 a (`docs/plan.md`, decisions 38 and 39), and the build follows the plan above, on branch `t3/near-trace-sharing`, checked only against stand-ins. Where it differs, or where the plan left a choice open:

- **Sign In is its own press.** Turning Share Traces on reads the commons' published capabilities and shows Sign In, a menu of GitHub and Google. Choosing one opens NEAR AI's sign-in in the browser; the browser hands the session back to a listener on this Mac's loopback address, at a return address with a random part of this sign-in's own, and Cloak enrols at once, then drops that session. Cancel stops the wait, and so does a ten-minute limit, which leaves "Timed out" with Try Again.
- **Sign Out** is in the Account row's menu. It asks first, saying traces already shared can no longer be withdrawn from Cloak, then forgets the account and its device key and returns to Sign In.
- **The issuer and the witness are fixed**, as NEAR's pins are: `issuer.tracecommons.ai`, and the witness at the direct Phala address the commons publishes today. Capabilities or an account naming others stop sharing with "Commons moved" until Cloak is updated. The witness's address has already moved once: the commons' settings of 13 November (version 8) name the `dstack-pha1-prod5` address, where the source at `46aa4201` still names a `dstack-pha-prod9` one (`contributor/channel.rs:104`).
- **The terms are a link, and no acceptance is recorded.** The Wallet's Terms row and the Share sheet open `https://tracecommons.ai/about/tnc/`. The Gateway also records an acceptance with the commons (`/v1/account/terms-acceptance`); Cloak does not (section 8, item 9).
- **The data-use choices** are Debugging, always granted, and Benchmarks, Ranking, Training and Attribution, each off until turned on. A chat readied carries the choices made at that moment.
- **The receipt is fetched as the answer comes back, not at Review.** The readied message goes through the same NEAR proof check and certificate pin as any NEAR message, only without Cloak's encryption, and the receipt is fetched straight after on a connection to the same pinned gateway. It is taken only when it is signed by the model key that proof found in the model's servers' quotes, over the model's name and the hashes of the exact bytes sent and received: it proves the model's server signed for those bytes, not what the model did with them. A chat whose receipt could not be had shows "No receipt", with Review off and Ready Again beside it.
- **Only the message after Ready goes readied.** One that stops before reaching NEAR leaves the chat readied; once one has gone, or may have, the chat's next message goes sealed. Share Traces is read at the press: off sends the ordinary sealed message whatever was readied.
- **Before is the chat as NEAR saw it,** one line each, who said it and then the words, with Exact under it showing the request's and the answer's bytes. After is the witness's envelope: it holds no chat words (section 1.6), so it does not read as messages and shows its bytes alone. Share uploads those bytes and no others, with the four headers, and only for the review on screen.
- **The witness's Intel quote is checked before anything goes to it.** It must pass against the pin the commons published at sign-in; one that does not stops Review with "Witness refused", and nothing is sent. Review waits up to 570 seconds for the witness. The check is of the enclave, not of the connection the chat goes on (section 8, item 13).
- **Two Gateway checks are not made.** Cloak does not check the witness's certificate itself, which the commons' ingest checks, and it does not run its own redactor over the envelope and refuse one in which a secret shape survives, which the Gateway does (section 5). The person sees After before Share either way.
- **Turning Share Traces off with Share or Withdraw under way** ends the step and leaves "Ended" in the Wallet's Share Traces section, saying it may have arrived. A trace whose upload was answered is kept with the account even then, so Withdraw is there when the switch comes back on.
- **Status is read at a trace's Refresh, for that trace alone,** and nothing is polled. Words: Sent, In review, Accepted, Not accepted, Withdrawn, the commons' own word for anything else, and credit when there is some.
- **Withdraw always tries.** Cloak does not track when the account session runs out. If the commons answers that the sign-in is no longer good, the trace's line says "Sign in again, then withdraw." with Sign In beside it, which signs in through the browser again and enrols with the same device key.
- **Every stop names its step** and, where it matters, says whether anything may have been sent, and Try Again or Ready Again is beside it where one helps.
- **The share control is never hidden.** It is dimmed while the switch is off, says "Sign in to share" before sign-in, and says "Time ran out" once a readied chat's 15 minutes are over, with Ready Again.
- **No crates were added** to cloak-near.

---

## 8. What is unproven

1. **Whether production runs this code.** The reading is of commit `46aa4201`. Whether account admission and the evidence ledger are switched on is set by the server's environment (`repo/docs/operator/invite-free-admission.md:417-439`).
2. **Which models the commons accepts.** `ACCEPTED_MODELS` and `MIN_REQUEST_BYTES` are set by the operator and published nowhere I found (`invite-free-admission.md:426-439`). If Cloak's one NEAR model, `Qwen/Qwen3.8-27B` (`app/Sources/CloakChat/Near.swift:143`), is not on the list, every share is refused with `admission_evidence_refused`.
3. **Which receipt kind Cloak's calls get.** Cloak sends no stream and `x-no-aliasing: true`, so NEAR should sign `provider_tee` receipts (`response-signatures.mdx:51`). A `gateway` receipt is refused unless the operator turned it on (`invite-free-admission.md:18-30`). Not seen live.
4. **How long NEAR keeps a receipt.** Not documented beyond "a short, bounded interval" for a 404 (`response-signatures.mdx:36`).
5. **Tor.** The source has no rule for or against it. A hosting provider in front of the commons could still block Tor exits.
6. **Whether a reviewer accepts a plain chat,** and whether it earns anything.
7. **Whether the commons' terms admit another app's calls.** The terms are a draft and name only NEAR's app. This is a plain reading, not a legal one.
8. **The witness's quote check from Cloak.** Its pin comes from the commons on first use. Whether Cloak's Intel checker fits the witness's dstack quote as it fits NEAR's is untried.
9. **Whether the commons takes a share with no terms acceptance recorded.** The Gateway records one; Cloak only links the terms (section 7.1).
10. **Whether the commons lets the same device key enrol again,** which Sign In does when a session has run out.
11. **Whether the witness's envelope reads as text.** After shows its bytes as UTF-8; where it is not, After shows a replacement mark, and Share still uploads the bytes exactly.
12. **Every wire format of section 7.1,** from the sign-in hand-off to withdraw, is read from source and checked only against stand-ins.
13. **The connection the chat goes to the witness on is not covered by the witness's check.** The quote proves that an enclave running the measured image holds the commons' signing address and saw Cloak's nonce. Its report data is `tcwitns1`, that address and the nonce, and no TLS key (`contributor/witness/verify.rs:173-180`, the tag at `contributor/witness/mod.rs:61-68`; Cloak checks the same). At the direct Phala address the commons publishes, Phala's dstack gateway, not the enclave, ends TLS (`repo/deploy/witness/README.md:141-143`); the custom address that would end it inside the enclave "is currently failing and is not ready for client discovery" (`:99-101`). So the chat goes on a connection checked only against Mozilla's roots, and Phala, or whoever holds a certificate for that address, can read it on its way. The Gateway has the same limit. Cloak adds no binding the protocol does not have.
14. **Another program on this Mac during the sign-in.** The return address carries a random part of the sign-in's own, and the page that collects the session is served only there, to a request naming the listener's own address, with a deposit from the listener's own origin. NEAR AI's source takes such an address (`cloud-api/auth.rs:29-87`, which refuses only a query, a fragment, `..`, `%25` and a user name; `cloud-api/api-lib.rs:1050-1065` allows `http://127.0.0.1` on any port); the Gateway uses a bare return address (`contributor/daemon/nearai_credential/loopback.rs:13-24`, `:36-38`). What is left: a program that can read the browser's address bar or history while the sign-in runs learns the random part, and could deposit its own NEAR AI session first, so that Cloak enrols an account the person does not own. Such a program could also read the person's own session from the same address. And whether NEAR AI's deployed sign-in takes a return address with a random part is untried: if it does not, every sign-in stops at NEAR AI's page.
15. **The NEAR AI session token can manage the person's NEAR AI account for an hour** (section 3, item 2): make API keys, change their spending limits and move credit. The commons is trusted, by its own source, to use it once and drop it.

---

## 9. Decisions only Sean can make

1. **How does a shared NEAR chat's message reach NEAR?** NEAR's receipt covers the exact bytes sent, and Cloak seals the words, so a sealed chat can only be shared as unreadable code.
   - a) Only a chat the person chooses to share sends its next message without Cloak's encryption, and that message carries the commons' challenge. Every other NEAR request stays sealed, byte for byte as today.
   - b) With Share Traces on, every NEAR message goes without encryption and carries a challenge. The commons learns the time of every NEAR message, and any chat can be shared within 15 minutes of its last answer.
   - c) Keep every NEAR message sealed and drop trace sharing in Cloak.

   Recommendation: **a**. Only what the person picks loses encryption, on one message that is about to go to the commons anyway. It is the Gateway's own "prepare the next call" design, and it is the easiest to reason about.
2. **Accept the commons' witness as the one redactor?** On this route the redaction is the witness's, not Cloak's. The raw chat is sent to the witness before the before-and-after view exists, and in production the witness passes part-redacted text, with names still in it, to NEAR AI's classifier under the commons' key.
   - a) Yes, in two presses: Review sends the chat to the witness and shows Before and After, then Share uploads exactly what was shown.
   - b) Yes, in one press: Share sends the chat to the witness and uploads its answer without showing it.
   - c) No, so no trace sharing in Cloak.

   Recommendation: **a**. It is the only form in which the person sees what is uploaded before it goes, and it matches the Gateway's own order.
