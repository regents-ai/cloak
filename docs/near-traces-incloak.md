# Share traces inside Cloak, done the way NEAR's Gateway does it

Second design for the Cloak chief, 20 Nov 2026. It follows Sean's decision 29 a: "copy their gateway mac app and do it the same way". Read only. No repository file was changed. Nothing was built, signed in, enrolled, keyed or submitted, and nothing of NEAR's was downloaded to run or run on this Mac. Three more source files of the commons' server were fetched anonymously to read (listed under Sources).

## Short answer

- **One new fact changes the plan. At the saved commit, the commons' server turns away a Cloak chat.** The setup in question is an account made with "Sign in with NEAR AI", which is the Gateway's no-invite setup. An upload from such an account must carry one of two things:
  - a session identity from one of five named coding tools: Codex, Claude Code, OpenCode, Cline or Gemini CLI;
  - a signed NEAR AI receipt for a call the commons set a challenge on.

  A Cloak chat honestly has neither. The server's refusal is `422 source_session_invalid` or `403 admission_refused` (`ingest/admission.rs:288-293`, `:337`, `:494-556`, `:869-896`; `protocol/trace_contribution.rs:217-225`).
- **The same refusal very likely meets Sean's try.** NEAR's own Gateway drops the session identity from any imported chat file by design (`sources/source/mod.rs:1839`; `sources/source/trajectory.rs:643`, `:705-711`). The try therefore tests exactly what Cloak's in-app sharing would meet. Its result decides whether there is anything to build.
- **If uploads are admitted (the try works, or NEAR opens a door for Cloak), the build is a hybrid.** A small Rust helper, `cloak-traces`, is built and started like `cloak-near`. It uses NEAR's own `trace-commons-protocol` crate, unchanged, for everything that must match NEAR byte for byte: building the trace, the whole redaction, the leftover-secret check, the terms document and the enrollment signature bytes. The few network steps are written in Cloak, on cloak-near's existing direct-or-Tor connection code. The secrets live in Cloak's own keychain items.
- **Not the Gateway's own library or NEAR's command-line tool, unchanged.** Three reasons:
  - It brings about 575 packages, including a local proxy for coding tools, a sandbox and file watchers.
  - Its keychain names are compiled in and would collide with a Gateway on the same Mac.
  - On a Mac, its NEAR AI sign-in only works inside NEAR's signed app (`contributor/near_ai_login.rs:19-24`).
- **Not a Swift rewrite.** The redaction is thousands of lines of rules that the server runs again on every upload. A second copy would drift.
- **What to build first, whatever happens: nothing.** The recommendation is to wait for Sean's try (decision 1).

## Sources

All saved copies are under `/tmp/cloak-build/near-traces-ref/`. Everything was fetched anonymously with a generic client name.

| Name used below | Full path |
| --- | --- |
| `protocol/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-protocol/src/…` (MIT or Apache-2.0) |
| `contributor/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-contributor/src/…` (MIT or Apache-2.0) |
| `sources/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-contributor-sources/src/…` (MIT or Apache-2.0) |
| `platform/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-contributor-platform/src/…` |
| `ingest/…` | `/tmp/cloak-build/near-traces-ref/repo/crates/trace-commons-ingest/src/bin/trace_commons_ingest_internal/…` (the server, AGPL; read only, never used in Cloak) |
| `repo/…` | `/tmp/cloak-build/near-traces-ref/repo/…`, the Trace Commons repository at commit `46aa4201fa7ebc122587a99b8d821a23953560a7` |
| `tc-terms.json`, `tc-tnc.txt`, `tc-privacy.txt` | `/tmp/cloak-build/near-traces-ref/…`, the live terms document and the privacy page |
| Cloak paths | `/Users/sean/Documents/regent/repos/cloak/…`, as on `main` today |

These three were newly fetched for this design: `ingest/admission.rs`, `ingest/inference_connection.rs` and `repo/crates/trace-commons-server/src/inference_connection.rs`.

---

## 1. What the Gateway does for sharing, step by step

In the Gateway, one Rust background service does every step. It runs inside the Mac app through a C library, and the Swift side only shows things (`repo/macos/Package.swift:1-120`; `repo/crates/trace-commons-contributor-ffi/include/trace_commons.h:1-140`). The order below is the order the Gateway takes. Each step says what Cloak would do.

### 1.1 Sign-in to NEAR AI

1. **Browser step.** The service opens near.ai in the default browser. The person can log in with the NEAR wallet, GitHub or Google (`contributor/channel.rs:121`; API host `https://cloud-platform.near.ai`, `:115`).
2. **The redirect comes back to the Mac.** It goes to a listener on `http://127.0.0.1` with a bare path: no query, no fragment, and never `[::1]` (`contributor/daemon/nearai_credential/loopback.rs:13-24`).
3. **The tokens arrive in the URL fragment.** A browser never sends a fragment to a server, so the listener answers with a small page whose script posts `location.hash` back to a second path on the same listener (`loopback.rs:4-11`).
4. **What comes back:** an `rt_` refresh token and a short-lived session JWT (`contributor/daemon/nearai_credential/mod.rs:11-12`).
5. **What the Gateway then does that sharing does not need.** It lists organisations and workspaces and mints an `sk-` key for its coding-tool proxy (`mod.rs:13-15`). It keeps the refresh token too, only to read the account balance (`mod.rs:22-31`).
6. **Where it is kept.** The keychain service is `trace-commons.near-ai.credentials`, in the data-protection keychain under NEAR's team access group `KXSWJN7WY8.ai.tracecommons.shell` (`contributor/channel.rs:96-97`; `platform/os_secret_store.rs:10-40`). A process without that signature gets `errSecMissingEntitlement` (`repo/docs/superpowers/specs/2026-09-15-macos-data-protection-keychain-design.md:1-140`).

**Cloak:** the same browser step and the same loopback bounce. The refresh token is only needed to mint a fresh JWT for enrollment (1.2), so Cloak does not keep it. Decision-free, but uncertain (see 7.6).

### 1.2 The device key and enrollment

1. **Device key.** An Ed25519 key pair, generated once with `ring` as PKCS8 (`contributor/identity.rs:65-75`). The Gateway stores it through its credential store, under `trace-commons.account.credentials` in the login keychain (`contributor/channel.rs:98`).
2. **Enrollment without an invite.**
   - Cloak sends `POST /v1/account/near-ai/provision/start/v2` to the commons (`https://ingest.tracecommons.ai`, `contributor/channel.rs:102`), then `…/finish/v2` (`contributor/daemon/nearai_onboarding.rs:80-86`).
   - The NEAR AI JWT goes in the request body, never as an `Authorization` header, so the commons can look it up. The client sends no account id, and there is no field for one (`nearai_onboarding.rs:11-17`, `:36-40`).
   - The commons returns a nonce. The device signs a preimage that ties the nonce to this ceremony, to the device's public key and to a PKCE challenge (`nearai_onboarding.rs:19-30`). The bytes come from `protocol/onboarding.rs:232` (`near_ai_provisioning_device_bytes`).
   - Result: a tenant in the commons' `near-` namespace, tied to that NEAR AI account (`ingest/admission.rs:231-245`).
3. **Every later upload asks for a claim first.**
   - Request: `POST https://issuer.tracecommons.ai/v1/trace-upload-claim` (`contributor/issuer_client.rs:153`).
   - It is signed by the device key over the exact body bytes, with headers `x-trace-device-key-id` and `x-trace-device-signature` and schema `ironclaw.trace_upload_claim_request.v1` (`contributor/identity.rs:24-28`).

**Cloak:** the same enrollment and the same claim, written as Cloak's own network calls. The signing bytes come from NEAR's protocol crate.

### 1.3 Terms

1. **Fetched live and anonymously, with proxies turned off.** The document is at `https://tracecommons.ai/legal/terms.json` (`contributor/channel.rs:112`; `contributor/terms.rs:1-24`, `:127`).
2. **Its shape.** Schema `trace_commons.terms.v1`, with version, effective date, `in_effect`, title and blocks (`protocol/terms.rs:17`). Today it is version `2026-11-10-draft.2`, `in_effect: false`, titled "NEAR AI Gateway App Terms of Service" (`tc-terms.json`). The web page says "These terms are a draft and are not yet in effect" (`tc-tnc.txt:5`).
3. **Shown in full, natively.** The agree checkbox only unlocks after the person scrolls to the end. The client hashes the exact bytes it showed (`repo/docs/superpowers/specs/2026-11-09-terms-scroll-acceptance-design.md:1-200`).
4. **Recorded.**
   - On the Mac: version and hash.
   - Then sent to `POST /v1/account/terms-acceptance` as `{terms_version, content_sha256, accepted_at}` (`protocol/terms.rs:11`, `:123`).
   - This needs the account session described in 1.11.
5. **When the version changes,** uploads are held until the new version is accepted (`contributor/daemon/terms_state.rs:1-12`).

**Cloak:** the same steps. The terms are named for NEAR's app, not Cloak; see section 6.

### 1.4 Data-use choices (consent)

1. **The scopes** are `debugging_evaluation`, `benchmark_only`, `ranking_training`, `model_training` and `public_attribution` (`protocol/trace_contribution.rs:357-368`).
2. **Debugging and evaluation are always on.** That is the floor (`contributor/consent.rs:1-6`). The terms say: "Debugging and evaluation of shared traces is always permitted" (`tc-terms.json` block 14).
3. **Credit needs `model_training`.** A trace sent without it earns no scoring award and is "withheld as `policy_mismatch`". Since late October it can be added afterwards, but never removed (`repo/docs/trace-commons.md:250-256`; `contributor/model_training_consent.rs:1-13`; endpoint `/v1/contributors/me/model-training-consent`).
4. **The choices are stamped into each trace** at upload as granted scopes, and they bind (`tc-terms.json` block 14).

**Cloak:** debugging stays on and fixed. One "Training" switch, off at first, says it is needed for credit (decision 4). Benchmarks, ranking and the public handle are left out.

### 1.5 Redaction: every rule and check, in order

All of this is in NEAR's protocol crate, so Cloak uses it unchanged.

1. **Build the trace from the turns.** `RawTraceContribution::from_capture_turns` takes the user text, the reply, tool calls and times (`protocol/trace_contribution.rs:1779-1790`, `:2064`). A trace built this way has no source session (`:2313`).
2. **Make the redactor.**
   - Cloak uses the deterministic redactor only (`protocol/trace_contribution.rs:4213`, `deterministic_only`). Its known paths are the home folder plus the working folder (`contributor/envelope.rs:172-181`).
   - The Gateway's old NEAR AI second scan is retired, and an add-on classifier exists only when set in the environment (`envelope.rs:56-100`). Cloak sets none.
3. **Canary self-test, once per batch.**
   - The redactor is run over NEAR's synthetic canary text (`protocol/trace_contribution.rs:2490-2494`).
   - The batch is refused if any email-shaped or path-shaped canary value survives (`contributor/envelope.rs:212-226`).
4. **Size check before redaction,** against 256 MiB (`contributor/envelope.rs:465-475`; constant in `protocol/trace_contribution.rs:41-148`).
5. **The text passes, in this order** (`protocol/trace_contribution.rs:4864-4900`):
   1. identity shapes;
   2. emails;
   3. generic paths;
   4. known paths;
   5. network and account shapes: IP address, internal host name, OS user name, phone;
   6. PEM blocks;
   7. named secret patterns, plus high-randomness strings next to a cue word;
   8. masking.

   Replacements are numbered placeholders such as `<PRIVATE_EMAIL_1>` and `<PRIVATE_LOCAL_PATH_1>`, or `[REDACTED]`.
6. **Metadata goes through the same passes.** A credential found in metadata refuses the whole trace rather than being masked (`protocol/trace_contribution.rs:5075-5360`; `contributor/envelope.rs:375-395`).
7. **Leftover-secret check.** The finished envelope is serialised and scanned again. Any secret shape refuses it (`contributor/envelope.rs:410-418`).
8. **Size check again** after redaction (`contributor/submit.rs:3118-3200`, `validate_local_envelope`).
9. **Risk tier.** `residual_risk` (`protocol/trace_contribution.rs:7236-7275`) works like this:
   - **High:** a flagged key, incomplete coverage, or a survivor.
   - **Medium:** anything found and removed, other than local paths, IP addresses, host names and OS user names (`:7180-7200`).
   - **Medium also:** **any trace whose message text is included** (`:7271-7275`).

   **So every Cloak chat is at least Medium.**

### 1.6 The before-and-after review

1. **The preview runs the same redaction** as the upload.
2. **The redacted envelope the person approves is written to disk** (file mode 0600), and the upload sends exactly those bytes (`trace_commons.h:1-140`; `contributor/daemon/approved_envelope.rs:1-60`; `contributor/daemon/preview.rs:1-50`).
3. **An approval is revoked** if the settings or the rules changed in between. A fingerprint of the inputs is compared (`approved_envelope.rs:1-60`).
4. **"Second look"** flags three cases: nothing was found, the result looks unsure, or the trace was trimmed to fit (`contributor/daemon/second_look.rs:1-56`).
5. **Unsure spans** are hints with positions only (`contributor/daemon/unsure_spans.rs:1-45`).

**Cloak:** the same rule. The review shows the chat before and after, and Share sends the bytes that were shown. Cloak keeps the approved bytes in memory for that one press instead of on disk, because sharing happens right away (see 1.7). Second look and unsure spans are left out of the first version. The removed-items count is shown instead.

### 1.7 The queue

The Gateway keeps a lasting queue because it records sessions in the background. A pending trace is dropped after 14 days without a decision, and that clock pauses while the service is unhealthy (`contributor/daemon/queue.rs:1-16`, `:3066`; terms block 17).

**Cloak:** no queue. A person picks one chat, reviews it and presses Share, and it goes then. A failed send stays marked Failed with a Retry, and nothing retries by itself.

### 1.8 The upload pass and the upload

The Gateway's pass is `submit_loaded` (`contributor/submit.rs:2086-2589`):

1. size gate;
2. already-sent check by session hash;
3. redactor;
4. canary;
5. raw trace;
6. size;
7. redaction and leftover check;
8. dry run if asked;
9. **mint the claim**;
10. stamp the granted scopes;
11. leftover check again;
12. size again;
13. hold for review;
14. **upload** to `POST /v1/traces`;
15. write a receipt.

The retry rule is three attempts, waiting 1 s and then 4 s. A 401 or 403 makes the client mint a fresh claim. A 429 is returned at once (`contributor/submit.rs:3397-3440`).

**The server's admission gate** sits in front of storage for accounts made by NEAR AI sign-in. This is the new finding:

1. It covers only `near-` and `nearai-` tenants. Accounts from an operator's invite keep the old path with no admission check (`ingest/admission.rs:494-511`).
2. **With account admission switched on,** the route depends on what the upload carries (`ingest/admission.rs:322-351`, `:869-896`):
   - With a `source_session`, the upload goes to the account ledger. There, a verified receipt admits it free, and an upload without one draws on a limited allowance.
   - Without a `source_session` but with evidence headers (`x-trace-admission-evidence` and `x-trace-admission-signature`, `protocol/admission.rs:6-7`), it goes to the evidence ledger.
   - Otherwise it is refused: `422 source_session_invalid`.
3. **With it off,** an upload with no evidence headers is refused: `403 admission_refused`, logged as `legacy_no_evidence_headers` (`ingest/admission.rs:288-302`, `:544-556`). The note there reads: "NEAR account bootstrap establishes identity, not invitation authority. Every new contribution on this path needs receipt-bound evidence."
4. **A `source_session` names its adapter, and only five are allowed:** `codex`, `claude-code`, `opencode`, `cline` and `gemini-cli` (`protocol/trace_contribution.rs:217-225`). Imported files never get one: "Imported attribution is not an identity" (`sources/source/mod.rs:1839`). The trajectory importer sets none (`sources/source/trajectory.rs:643`), and a test checks that a file claiming one loses it (`:705-711`).
5. **Evidence is a NEAR AI receipt for one real inference call.** The call's request carried a `trace_commons_admission` challenge in its metadata, a witness checked the receipt, and the trace is trimmed to that one call (`protocol/admission.rs:1-9`, `:154-184`; `contributor/submit.rs:75-108`, `:1399-1411`, `:1689-1700`). The Gateway gets this from its local proxy.

**Cloak:** the same pass, minus the queue, the dry-run flag and the witness. It is useful only if the gate in point 2 or 3 admits a Cloak chat. Today, on this reading, it does not.

### 1.9 Status and score

1. **The statuses:**
   - `submitted` (in, no verdict yet);
   - `accepted`;
   - `quarantined`, meaning held for review, which "is not a rejection";
   - `rejected`, `revoked`, `expired`, `purged`;
   - `awaiting_pii_backstop`.

   (`contributor/daemon/history.rs:27-40`; `repo/docs/trace-commons.md:155-170`.)
2. **The server re-scrubs and re-scores every upload.** Low-risk traces that pass are accepted. Medium and high go to quarantine "with zero immediate credit" until a reviewer decides (`repo/docs/trace-commons.md:162-168`). Given 1.5 step 9, **every chat would wait for a person's review.**
3. **Reading status back.** `POST /v1/contributors/me/submission-status` lists the client's own submission ids, with a device-signed status claim (`repo/docs/trace-commons.md:197-201`).
4. **A signed score attestation** exists at `/v1/contributors/me/score-attestation`, for collectors (`repo/docs/collector-integration.md:98-115`). Cloak does not need it.

### 1.10 Credit

1. Pending credit appears for `accepted` and `awaiting_pii_backstop` only. A reviewer who approves a quarantined trace sets points, by default `(0.5 + score)` clamped between 0.5 and 2.0 (`repo/docs/trace-commons.md:240-248`).
2. Settlement turns credit into NEAR AI credit in the signed-in account (`trace-commons.md:168-170`; terms block 21). "Sending alone earns nothing" (block 21).
3. Credit needs `model_training` (1.4 point 3).

**Cloak:** show pending and settled numbers from the status read.

### 1.11 Withdrawal

1. **The call** is `POST /v1/account/traces/{submission_id}/withdraw` (`contributor/withdraw.rs:131-140`).
2. **It needs an account session, not the device key.** A stolen device key must not be able to delete someone's history (`contributor/daemon/withdraw.rs:10-24`).
3. **The account session** is a second browser login with PKCE. A loopback listener on `127.0.0.1` serves exactly one request (`contributor/account_auth.rs:1-29`). The token is short-lived, and its rotation comes back in a response header that must be saved after every call (`contributor/withdraw.rs:125-131`).
4. **The confirmation text depends on how far the trace has gone** (`contributor/withdraw.rs:210-230`):
   - not yet in the commons;
   - in the commons;
   - already in a published export, which "cannot be recalled".
5. Settled credit stays, and pending credit is forfeited (`withdraw.rs:213-217`; terms block 18).

**Cloak:** the same call, the same three texts, and the same second login when withdrawing. The login is asked for only then.

### 1.12 What the Gateway keeps on the Mac

1. **Receipts:** submission id, session hash, source, time, status, and whether a person approved it (`contributor/config.rs:955-980`).
2. **A history cache with no local paths**, because "this is the surface most likely to be screenshotted" (`contributor/daemon/history.rs:1-15`).
3. **The approved envelopes,** at file mode 0600 (1.6).
4. **The terms version and hash** that were accepted (1.3).
5. **The keychain items** (1.1, 1.2).

**Cloak keeps:**
- for each shared chat, a small record inside the chat's existing encrypted record: submission id, status, credit figures and the time sent;
- the accepted terms version and hash, and the training choice, in settings;
- the device key in the keychain.

Cloak keeps no raw copy and no envelope.

---

## 2. The two ways to get it into Cloak

### 2(a) NEAR's own Rust crates

**a1. The Gateway's library, the contributor crate or NEAR's command-line tool, unchanged: not workable.**

- **Size.** NEAR's lock file lists 957 packages. The contributor crate and the library behind the Gateway each pull about 575, 17 of them from git (an over-count from the lock, which ignores target). The list includes:
  - the coding-tool proxy (`ironwire_*`);
  - a sandbox (`rts`);
  - file watchers, SQLite and keyring crates (`repo/crates/trace-commons-contributor/Cargo.toml`).
- **Keychain names are compiled in** (`contributor/channel.rs:96-100`), and the device key is stored through NEAR's config store (`contributor/identity.rs:65-75`).
  - Cloak would write into the Gateway's own item `trace-commons.account.credentials`. Sean is about to install the Gateway on this Mac, so the two would collide.
  - The NEAR AI item needs NEAR's team access group, which Cloak cannot be signed with (`platform/os_secret_store.rs:10-40`).
- **On a Mac, the tool's sign-in hands off to the Gateway app.** "The NEAR AI session lives in the app's keychain access group, and only the app is signed with it" (`contributor/near_ai_login.rs:19-24`). That means a second app, which Sean ruled out.
- **Its HTTP clients cannot reach Cloak's Tor.** Cloak's tor listens on a socket file, and NEAR's clients only read environment proxies, which support no socket file (`repo/crates/trace-commons-operator-client/src/client.rs:567-575`).
- **It reads coding-tool folders,** not Cloak chats. Its import route for others is a trajectory file (`contributor/cli.rs:184-186`, `:237-239`), which brings back the refusal in 1.8.

**a2. NEAR's `trace-commons-protocol` crate only, unchanged: recommended.**

- **What it gives Cloak, as is:**
  - the trace types and `from_capture_turns`;
  - `DeterministicTraceRedactor` with every pass in 1.5;
  - the canary text and values;
  - the leftover-secret labels;
  - the risk tier;
  - the terms document and acceptance types;
  - the enrollment signing bytes;
  - the consent scopes;
  - the admission refusal labels, so Cloak can name a refusal correctly (`protocol/admission.rs:11-80`).
- **What it pulls in.**
  - Its non-optional dependencies are 15 crates.io crates: `chrono`, `regex`, `ring`, `serde`, `serde_json`, `sha2`, `tokio`, `url`, `uuid`, `flate2` and a few small ones (`repo/crates/trace-commons-protocol/Cargo.toml`).
  - Built without features, as Cloak would, it makes no network calls and touches no keychain. `reqwest` arrives only with the two classifier features (`Cargo.toml`, `[features]`).
  - The full set is 184 packages in NEAR's lock, 21 of them for Windows or the web only. **About 90 are not already in cloak-near's 148**: regex, the ICU tables behind `url`, tokio, chrono and their small helpers. No git sources besides the protocol crate itself. Counted by `/tmp/cloak-build/near-traces-protocol-size.py`.
- **Toolchain.** The crate wants Rust 1.96 and edition 2024 (`repo/Cargo.toml:37-43`). Cloak's helper builds with 1.97.1 (`/Users/sean/Documents/regent/repos/cloak/guest/near/rust-toolchain.toml`).
- **Sandboxed helper.**
  - The crate needs no files beyond reading the home folder's path, no keychain and no network, so it suits a helper the app starts.
  - `redact_trace` is async, so the helper runs a one-thread tokio runtime just for that call. tokio is already a non-optional dependency of the crate.
- **Where it lives.** The recommendation is a second binary in the existing crate: `/Users/sean/Documents/regent/repos/cloak/guest/near/src/bin/cloak-traces.rs`, plus a `traces` module.
  - It then reuses, unchanged, `fetch::connect` (direct or Tor, new circuit per attempt), `fetch::request` (any method, headers and body) and Mozilla's roots (`/Users/sean/Documents/regent/repos/cloak/guest/near/src/fetch.rs:321`, `:336`, `:519`).
  - A separate crate would mean making those functions public, which is a change to cloak-near.
  - `app/build.sh` builds and signs it beside `cloak-near` (`/Users/sean/Documents/regent/repos/cloak/app/build.sh:32`).
- **How Cloak pins it.**
  - In `/Users/sean/Documents/regent/repos/cloak/guest/near/Cargo.toml`:

    ```toml
    trace-commons-protocol = { git = "https://github.com/TraceCommons/trace-commons", rev = "46aa4201fa7ebc122587a99b8d821a23953560a7", default-features = false }
    ```

  - In `/Users/sean/Documents/regent/repos/cloak/reference/sources.json`, an entry in the existing shape (`name`, `kind`, `url`, `ref`, `commit`, `full_history`, `role`):

    ```json
    {
      "name": "trace-commons",
      "kind": "git",
      "url": "https://github.com/TraceCommons/trace-commons.git",
      "ref": "main",
      "commit": "46aa4201fa7ebc122587a99b8d821a23953560a7",
      "full_history": false,
      "role": "NEAR's trace sharing. Cloak uses only the trace-commons-protocol crate (MIT or Apache-2.0), unchanged, for the trace, redaction, terms and enrollment bytes."
    }
    ```

- **How Cloak talks to it.** One JSON line in and one JSON line out per request, as with cloak-near (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Near.swift:180-200`). The requests are:
  - `sign-in` (opens nothing itself; returns the near.ai address and waits on the loopback);
  - `enroll`;
  - `terms`;
  - `review` (turns in; before and after text and the removed counts out);
  - `share` (the approved envelope out);
  - `status`;
  - `training`;
  - `account-sign-in`;
  - `withdraw`.

  Secrets come in on the line and rotated tokens go back on it (section 3).
- **What Cloak still writes itself, honestly:**
  - about 60 lines that mirror thin wrappers in NEAR's contributor crate: the canary loop (`contributor/envelope.rs:212-226`), the leftover check (`:410-418`), the size checks and the error labels;
  - the network calls: two sign-ins, provision start and finish, the claim, the upload, status, training, terms acceptance and withdraw.

  These are a small second copy, and they must be read against NEAR's on every pin bump.

### 2(b) The same steps written again in Swift

- **What would have to match NEAR byte for byte:**
  - every redaction pattern, in its order, with its numbered placeholders (`protocol/trace_contribution.rs:4194-4900`, plus the detectors in `protocol/trace_contribution/tool_output_detectors.rs`);
  - the envelope's exact JSON shape and schema strings (`:41-148`, `:244-283`);
  - the canary;
  - the risk tier;
  - the enrollment preimage (`protocol/onboarding.rs:232`);
  - the bytes signed for each claim;
  - the terms hash over the exact bytes fetched.
- **The drift risk is high.** The server re-runs redaction on every upload with its own suffix, `server-rescrub-v2` (`protocol/trace_contribution.rs:41-148`; `repo/docs/trace-commons.md:162-164`). NEAR changes the rules often; the pipeline is at version 3. A Swift copy that falls behind shows up as quarantines or rejections nobody can explain, or as a leak the server then has to catch.
- **Against Cloak's rule.** It is a second copy of someone else's logic when their code can be used as it is.

**Recommendation: 2(a2).** NEAR's protocol crate is used unchanged for everything that must match. A thin Cloak helper sits on cloak-near's existing connection code, and nothing of the Gateway's library is used.

---

## 3. Secrets and route

| Secret | Where in Cloak | Read by | Kept how long |
| --- | --- | --- | --- |
| NEAR AI refresh token (`rt_`) and session JWT | Nowhere at rest. The helper holds them in memory during sign-in and enrollment only. | Helper | Dropped after `enroll` |
| Device key (Ed25519, PKCS8) | Login keychain, service `sh.regents.cloak.traces`, account `device`, this device only. Same kind of item as `sh.regents.cloak.near` (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Near.swift:77-120`). | App; handed to the helper on each line, as the NEAR key is today (`Near.swift:180-200`) | Until "Share traces" is turned off and the device removed |
| Account session (withdrawal, terms acceptance) | Login keychain, service `sh.regents.cloak.traces`, account `account`, with its expiry | App; handed per call; the helper returns the rotated token, which the app writes back at once | Until it expires |

- **Why the login keychain.** Cloak has no keychain access group or provisioning profile. Its entitlements are virtualization only (`/Users/sean/Documents/regent/repos/cloak/app/RegentsCloak.entitlements`), and its keychain note explains why the data-protection keychain is not used (`/Users/sean/Documents/regent/repos/cloak/app/Sources/CloakChat/Keychain.swift:5-11`). Cloak's own service names cannot collide with the Gateway's.
- **Only the app reads the keychain.** The helper keeps nothing between lines, which matches how `cloak-near` gets the NEAR key.
- **The NEAR `sk-` key for chats is not touched.** Sharing never needs it.

**Route.**
- **Recommendation:** sharing follows the NEAR route setting. With Tor on for NEAR, every sharing call goes through Tor on its own circuit (its own SOCKS user name, as each route has in `/Users/sean/Documents/regent/repos/cloak/guest/near/src/lib.rs:73-81`). Otherwise it goes direct.
- **What Tor hides here.** Enrollment ties the device to the person's NEAR AI account (`contributor/daemon/nearai_onboarding.rs:11-17`), so the commons knows whose traces they are either way. Tor hides only the Mac's internet address. It also keeps the sharing calls from linking that address to the NEAR chat calls.
- **The two browser sign-ins run in the person's browser.** They do not go through Cloak's Tor, and the screens should not suggest they do.
- **Does the commons allow uploads through Tor? The source shows no rule either way.**
  - The admission gate counts limits per account (`protocol/admission.rs:31-34`) and logs no address (`ingest/admission.rs:140-144`).
  - Only a slice of the server was read. A hosting provider in front of it could still block Tor exit addresses. That is unproven (7.4).

---

## 4. What Cloak must NOT take from the Gateway

| Gateway part | Where | Why not |
| --- | --- | --- |
| The local proxy for coding tools ("Private AI"), and the `sk-` key it mints | `contributor/daemon/nearai_credential/mod.rs:11-15`; terms block 27: "Any program on your computer that can reach that service can send requests through it, charged to you" | Cloak talks to NEAR itself. A local port would be a new way in. |
| Watching other tools' session folders | `notify` in `repo/crates/trace-commons-contributor/Cargo.toml`; sources crate | Cloak shares only its own NEAR chats. |
| Automatic sharing: armed folders and standing policies | terms block 9 ("send automatically"); `contributor/config.rs:961-975` (`approved_unattended`) | Cloak shares one chat, picked by the person, after the person sees it before and after. |
| The fallback ladder: retired NEAR AI scan, add-on classifiers from the environment, witness route | `contributor/envelope.rs:56-100`; `repo/docs/trace-commons.md:536-560` | One redactor, deterministic, no switches. |
| The receipt-and-witness route | `contributor/submit.rs:1270-1305` | It needs Cloak's NEAR calls to carry the commons' challenge, a receipt per call, and a witness. Out of scope unless Sean asks (decision 2). |
| The 14-day queue, second look, unsure spans, insights, compute, red sandbox, referrals, public handle, payout links | `contributor/daemon/queue.rs:1-16`; `second_look.rs`; `unsure_spans.rs`; Cargo.toml | Not needed for one chat at a time. |
| Sparkle and the Gateway's own updater | `repo/macos/Package.swift` | Cloak has its own. |

---

## 5. The screens, kept minimal

The Stripe or Coinbase look: symbols on the surface, words in tooltips, titles and labels of one or two words. The words "private", "protected" and "equivalent" appear nowhere. They would appear only inside the name "NEAR Private AI", and that name is not needed here.

**The sharing state**, one name per state, stored in settings:

| State | Meaning | What the person sees |
| --- | --- | --- |
| `off` | Not set up, or turned off | Switch off |
| `signIn` | Waiting for the browser | Spinner beside the switch; tooltip "Finish in your browser" |
| `terms` | Signed in, terms not accepted for this version | Terms sheet |
| `uses` | Terms accepted, choices not saved | Uses sheet |
| `on` | Enrolled, ready | Switch on; Credit row shows |
| `failed` | Sign-in or enrollment failed | Switch off; `exclamationmark.circle` with the reason in its tooltip; Retry |

**The state of each chat**, one name per state, kept in the chat's record:

| State | Symbol on the chat row | Tooltip |
| --- | --- | --- |
| `none` | nothing | — |
| `sending` | progress ring | "Sending" |
| `submitted` | `clock` | "Sent. Waiting for a decision" |
| `inReview` (server `quarantined`) | `hourglass` | "In review. No credit until a reviewer decides" |
| `accepted` | `checkmark.circle` | "Accepted" plus the credit, for example "Accepted · 1.2 pending" |
| `rejected` | `xmark.circle` | "Not accepted" |
| `refused` | `nosign` | The server's own label, mapped to words: "Not admitted for this account" for the admission refusals |
| `failed` | `exclamationmark.triangle` | "Couldn't send. Retry from the menu" |
| `withdrawn` | `arrow.uturn.backward.circle` | "Withdrawn" |

**Screens and exact words**

1. **NEAR wallet sheet.** A row labelled **Share traces** with a switch, off at first. The tooltip on the label: "Share chosen NEAR chats with the Trace Commons". When on, a second row **Credit** shows `pending · settled` in NEAR AI credit, and its tooltip says "Credit comes after review". A `ellipsis.circle` menu on the row holds **Training** (the switch from screen 4) and **Sign out**.
2. **Sign-in.** Turning the switch on opens the browser at near.ai and shows the `signIn` state. There is no separate screen. Cancel by turning the switch off.
3. **Terms.** A sheet titled **Terms**:
   - The full text, drawn natively from the blocks.
   - The version and a **Draft** badge while `in_effect` is false.
   - A checkbox **I agree**, enabled only after scrolling to the end.
   - Buttons **Accept** and **Cancel**.
4. **Uses.** A sheet titled **Uses** with two rows:
   - **Debugging**, on and fixed, tooltip "Always allowed".
   - **Training**, a switch, off at first, tooltip "Needed for credit. Can be added later, not removed".
   - Button **Save**.
5. **Review.** Opened from a NEAR chat's menu item **Share**, with symbol `square.and.arrow.up`. The item shows only while the switch is on.
   - A sheet titled **Review**, with two columns headed **Before** and **After**.
   - Removed parts are highlighted in After.
   - A summary line of symbols with counts, for example `envelope 2`, `folder 1`, `key 1`, with words in tooltips: "Emails", "File paths", "Keys".
   - Buttons **Share** and **Cancel**.
   - A refusal (a canary failure, a leftover secret, too large) replaces the After column with one plain sentence. Share stays absent, because nothing can be sent.
6. **Status.** The symbol on each chat row, from the table above. Status is read when the wallet sheet opens and when a chat's menu opens. There is no timer.
7. **Withdraw.** The menu item **Withdraw**, with symbol `arrow.uturn.backward`, on a shared chat.
   - Without a current account session, it opens the second browser login first.
   - The confirmation is NEAR's text for that case (`contributor/withdraw.rs:210-230`): the title "Withdraw this trace?", NEAR's body sentences, and buttons **Withdraw** and **Cancel**.

Sharing is not an on-chain action. Even so, nothing blocks a second press: a repeat Share of the same chat goes to the server, which answers "already submitted" with the existing status (`repo/docs/collector-integration.md:89-92`).

---

## 6. Terms and permission

Block numbers count from 0 in `tc-terms.json`. Quoted from the live draft (`tc-terms.json`, version `2026-11-10-draft.2`, `in_effect: false`; page text `tc-tnc.txt`), and from the licence (`repo/LICENSE`).

1. **Who the terms cover.** "They govern your use of the NEAR AI Gateway desktop application, its command-line tools and the services reached through them (the "App")." (block 2)
   - *Plain reading:* the terms are written for NEAR's app. "The services reached through them" could include the commons' servers whichever app reaches them. They do not name or mention any other app.
2. **The licence to the app.** "The Trace Licensor grants you a license to install and use the App on computers you control… Open-source components are licensed under their own licenses, which prevail for those components." (block 34)
   - *Plain reading:* NEAR's open-source parts carry their own licence. The client crates' licence says: "These are licensed under either of: Apache License, Version 2.0 … MIT license … at your option. They may be embedded in proprietary software." (`repo/LICENSE:25-45`)
   - The server crates are AGPL (`repo/LICENSE:7-22`). Cloak uses none of them.
3. **Acceptable use.** "You must not use the App to … fabricate, duplicate or manipulate sessions to earn credit; tamper with or bypass redaction, the quality gates, consent choices or any security control; access the App's services, the Trace Licensor's systems, NEAR AI Cloud or other users' data without authorization … Ordinary documented use of the App … and your rights under open-source licenses are not affected." (block 31)
   - *Plain reading:* "without authorization" is not defined. The terms do not say whether a person's own sign-in counts as authorization when another app makes the calls.
   - Labelling a Cloak chat as a coding tool to pass the gate in 1.8 would be fabricating a session. Cloak must not do it.
4. **What the app does.** "The App records sessions from the coding tools you choose, redacts them and, when you decide, contributes them as traces." (block 8) A trace is "a redacted record of one agent session: the conversation, the tool calls and their results" (block 13).
   - *Plain reading:* the terms speak of coding tools and agent sessions. A chat is a conversation without tool calls.
5. **The person's warranty.** "You represent and warrant that you have all necessary rights and permissions to contribute your traces … No filter is perfect; you can review a trace before contributing it. You are responsible for what you contribute." (block 16)
6. **The Trace Commons Terms and Conditions.** These are named in block 31, but I found no separate document. The address the Gateway links as its terms, `https://tracecommons.ai/about/tnc/` (`contributor/channel.rs:110`), serves this same Gateway app text (`tc-tnc.txt:1-4`).
7. **The documented way for another platform.** It is to drive NEAR's own command-line tool with an operator's invite (`repo/docs/collector-integration.md:3-5`, `:23-34`). There is no documented route for another app to enroll its own users.
8. **The technical gate.** The server's list of five allowed source names (`protocol/trace_contribution.rs:217-225`) and its admission rules (`ingest/admission.rs:288-293`) are code only NEAR can change.

**Would Cloak need NEAR's or the commons' say-so?** No clause I found requires it, and none grants it. The licence lets Cloak use the protocol crate. The terms are a draft and are written for NEAR's app. In practice the server, as the source reads today, admits a Cloak chat from an account made by NEAR AI sign-in only if NEAR changes it or gives an invite. This is a plain reading, not a legal conclusion.

---

## 7. What is unproven, and what Sean's try should watch for

**Unproven**

1. **Whether production runs the code read here.** The admission rules were read at commit `46aa4201`. The deployed server may differ, and whether account admission is switched on is set by the server's environment (`ingest/admission.rs:33-45`). Either branch refuses an upload with no source and no evidence. A staging build is the exception (`ingest/admission.rs:481-484`, `:515-521`).
2. **Whether a chat, once admitted, is ever accepted.** It would be at least Medium (1.5 step 9), so a reviewer decides. Whether reviewers take a plain chat at all is unknown.
3. **Credit for a chat.** It depends on point 2, on Training being on, and on the gate's scoring of a conversation with no tool calls.
4. **Tor.** Whether the commons' hosts answer Tor exits.
5. **Enrollment from Cloak.** It is untried. The provision v2 body was read in the source, but no call was made.
6. **Whether the NEAR AI sign-in must be kept after enrollment.** It matters for re-enrolling, for credit or for the balance. The source suggests not for sharing, but this is unconfirmed.
7. **Whether the person signs in to the NEAR AI account that pays for their Cloak chats.** Credit lands in the sign-in account (terms block 21). Cloak cannot check that it matches the account behind the NEAR key in Cloak.

**What Sean should look at and report from the try through the Gateway**

1. **How the chat went in.** Was it an exported chat file in the "Exported traces" folder, or a chat made through the Gateway's own NEAR AI proxy? Only the first tests what Cloak would do. The second carries a receipt that Cloak's chats lack.
2. **The sign-in.** Which login he used (NEAR wallet, GitHub or Google), and whether the Gateway asked for an invite.
3. **The review screen.** What Before and After showed for the chat: which parts were removed, and whether any warning or "second look" appeared.
4. **The outcome right after Share, word for word.** "Sent", or an error. In particular, any words like "not admitted", "source session", "admission" or "limit". Exact text or a screenshot.
5. **The status a day later:** Sent, In review (quarantined), Accepted, Rejected or Not admitted.
6. **Credit.** Whether anything shows as pending, and whether Training was on.
7. **The terms version shown,** and whether it said draft.
8. **Whether the Gateway started a local proxy or edited any coding tool's settings** while he only shared one chat.
9. **Whether Tor was on on the Mac.** If he can, whether sharing still worked with a system VPN or Tor on.

---

## 8. Decisions only Sean can make

1. **Build in-app sharing now, or wait for the try?**
   - a) Build now, to the design above.
   - b) Wait until the try shows a chat file accepted or in review, not refused.

   Recommendation: **b**, because at the saved commit the server refuses a chat from an account made by NEAR AI sign-in, so a build now would likely meet the same refusal.
2. **If the try is refused, what next?**
   - a) Prepare a short request to NEAR and the commons, asking them to admit Cloak chats, for example by adding Cloak as a source or issuing invites. The text comes to Sean for approval as its own decision before anything is posted.
   - b) Drop trace sharing for now.
   - c) Ask for a design of the receipt route instead. Cloak's own NEAR calls would carry the commons' challenge, with a witness. It is much larger.

   Recommendation: **a**, because only NEAR can open the gate, and asking costs little.
3. **Which route should sharing take?**
   - a) Follow the NEAR route setting: Tor when NEAR is on Tor, otherwise direct.
   - b) Always direct.
   - c) Always Tor.

   Recommendation: **a**, because it matches what the person already chose for NEAR, and the commons knows the account anyway.
4. **Show the Training choice, which credit needs?**
   - a) Show it, off at first.
   - b) Show it, on at first.
   - c) Leave it out, so there is no credit.

   Recommendation: **a**, because credit needs it but training is a real use of the person's words, and it can be added later but not removed.
