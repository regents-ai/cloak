# cloak-near

Slices 1 to 3 of Cloak's NEAR mode: the check of NEAR AI Cloud's hardware
proof, its Intel quotes and Intel Trust Authority's verdict on its GPUs,
made before anything is sent, and the chat requests that follow a passed
check, encrypted to the model key the check established. It holds
no account: the caller gives the key for each request. `cloak-near`, the
helper the Mac app starts for NEAR mode, runs it one line at a time (see
"The helper"). app/build.sh builds the helper, puts it in the app at
`Contents/Resources/near/cloak-near` and pins it in the app's manifest; the
app checks that pin before each start of it. The crate is not part of the
guest image.

- `fetch_report` opens one TLS connection to `cloud-api.near.ai` on the
  caller's route (see "Routes"), with ordinary certificate checks against
  Mozilla's roots. It records the SHA-256 of the gateway certificate's
  SubjectPublicKeyInfo, and on that connection asks for one model's
  attestation report with a fresh 32-byte nonce, no Authorization header,
  `x-no-aliasing: true` and an uncompressed body of at most 4 MiB (about
  245 KB an instance on 19 November).
- `fetch_collateral` fetches, on the caller's route, the Intel collateral
  the report's quotes need, straight from Intel's servers
  (`api.trustedservices.intel.com` and `certificates.trustedservices.intel.com`).
- `fetch_ita_tokens` asks NEAR's gateway, with no account key and under
  the report's nonce, for the tokens Intel Trust Authority signs on the
  gateway's quote and on one of the model's servers' GPUs
  (`/v1/attestation/ita-token`, `signing_algo=ed25519`,
  `include_tls_fingerprint=true`). `fetch_ita_keys` fetches the keys Intel
  signs them with from `portal.trustauthority.intel.com/certs`, a host
  pinned in the code: neither the tokens' `jku` nor NEAR's `jwks_url` is
  followed. Both use ordinary certificate checks.
- `verify_intel` is pure: report bytes, nonce, the key hash seen, the model
  name, the collateral, the pins and `now` in; an `IntelProof` or one
  `Refusal` out.
- `verify_gpu` is pure: NEAR's answer of Intel's tokens, the nonce, the
  model name, the `IntelProof`, Intel's key list, the pins and `now` in; a
  `GpuProof` or one `Refusal` out.
- `check` gives a proof that passed and sends nothing to the chat
  endpoint: one taken from `Kept` if it passed for the same model no
  longer ago than the proof age the caller gives with the call (see "Proof
  age" below), or else a new one: a report is fetched under a fresh nonce;
  Intel's collateral is reused from `Kept` or fetched; the Intel quotes
  are verified; Intel Trust Authority's tokens are fetched from NEAR under
  the same nonce; Intel's keys are reused from `Kept` or fetched; and the
  GPU side is verified. There is no way to skip the GPU.
- `ask` sends one chat request, and is the only way to send one. In one
  call and in this order: the request is checked; `check` gives a proof
  that passed; and only then, holding a `Proof` with both halves, is the
  request sent. A step that fails before sending ends the call with its
  `Stop` and nothing is sent; `Stop::sent` says whether the request may
  have reached NEAR. NEAR's gateway and Intel's servers each go through a
  route of the caller's (`Routes`).
- `ask_readied` sends the one message a person readied for trace sharing
  (docs/near-share.md, section 7): the same check of the request and the
  same proof as `ask`, then the request without NEAR's encryption, carrying
  the Trace Commons' admission binding as its one added field,
  `metadata.trace_commons_admission`, on a connection pinned to the gateway
  TLS key the proof checked. NEAR's signed receipt for the exchange is then
  fetched on another connection pinned the same way, and taken only when it
  is signed by the model key the same proof found in the model's servers'
  quotes. Every other request goes through `ask`, unchanged.
- `src/share.rs` holds trace sharing's other steps: the NEAR AI sign-in and
  enrolment, the admission challenge, the witness's review, the upload,
  and the status and withdrawal of what was shared (see "Trace sharing's
  lines").

## Routes

Each of the two routes, to NEAR's gateway and to Intel's servers, is one
of:

- **Tor** (`Route::Tor`): through Tor's SOCKS5 port, at a TCP address or
  at a socket file (`SocksAddr`; the Mac app's tor listens on a socket
  file), names resolved by Tor, with a SOCKS user name of the caller's,
  so that each route has a
  circuit of its own. NEAR and Intel see a Tor exit's address. When a
  connection cannot be made (the SOCKS step or the TLS handshake fails,
  before any byte of a request is written), it is made again on a new
  circuit, asked for by the caller's user name with the attempt's number
  appended (`abc-2`, then `abc-3`), three attempts at most; then the last
  failure stops the call. Each new connection starts again from the
  caller's own user name, so a circuit that failed is tried first again.
- **Direct** (`Route::Direct`): an ordinary connection to the host on port
  443, its name looked up by the Mac's system, each address it has tried
  in turn. NEAR and Intel see the Mac's internet address. One attempt:
  there is no other path to try.

Either way the same timeouts, certificate checks, key pin and HTTP follow.
No request is sent twice: a connection is tried again only before any byte
of a request is written on it, and a request once written, the chat request
included, is never tried again. One answer is asked for again: NEAR's
answer of Intel Trust Authority's tokens, when NEAR answers 502 (its own
call to Intel failed), up to three asks in all under the same nonce; no
other status is.

## What `verify_intel` checks

For the gateway and for every model entry:

- the Intel TDX quote, with `dcap-qvl` (pure-Rust crypto): Intel's
  certificate chains, revocation lists, the quoting enclave, the quote's
  signature, and all collateral in date at `now`;
- Intel's verdict on the platform and its quoting enclave is `UpToDate`,
  nothing older. NEAR's servers are multi-socket platforms whose
  certificates say they can add sockets, have their keys cached by Intel's
  registration service and run with SMT on; those three are accepted;
- not in debug mode (and the other TD attributes dcap-qvl refuses);
- the report data in the verified quote is SHA-256 of the server's Ed25519
  key and its TLS key's fingerprint, then our nonce. For the gateway the TLS
  key is the one seen on our connection, and the fingerprint it names must
  be that one too;
- the nonce sent back is ours;
- the event log replays to the quoted RTMR3, and MRCONFIGID is 01, the
  SHA-256 of the exact compose file, then 15 zero bytes;
- for the gateway: MRTD, RTMR0-2, MRCONFIGID and the RTMR3 events `app-id`,
  `key-provider`, `mr-kms` and `os-image-hash` equal one accepted gateway
  set in `reference/near-pins.json`, every value alike;
- for a model server: the same, but in place of MRCONFIGID, the SHA-256 of
  its compose file with its host's label dropped. Every model server's
  compose file names its host, `INSTANCE_LABEL=gpu04` on one and
  `INSTANCE_LABEL=gpu23` on another, so the whole file's hash would refuse
  every server NEAR adds. The label must appear exactly once, followed by
  one to four ASCII digits, or the server is refused; only those digits
  are dropped, from the exact text MRCONFIGID binds, so anything else in
  or after the label, or anywhere in the file, still has to match. A
  compose file with another telemetry address is another set.

And for the model list: it is not empty, every entry names the requested
model, every entry's `signing_public_key` is the `signing_address` its quote
binds, every entry holds the same key, and every instance id, read from
RTMR3, appears once.

Anything missing or malformed is refused.

## What `verify_gpu` checks

NEAR's answer holds the gateway's token and, for the model asked, one
token on one model server's GPUs. Both come from one request NEAR's gateway
makes to Intel on its own account: it takes a nonce from Intel (`val`,
`iat` and Intel's signature over them), makes a quote whose report data is
SHA-512 of that nonce and its runtime data, which holds our nonce, asks one
of the model's servers for its GPU evidence under SHA-256 of Intel's nonce,
and has Intel appraise the quote alone and the quote with the GPU evidence.

Every token must:

- name, in its header, `PS384` and a key Intel's key list holds as an RSA
  key for PS384, and its signature must verify with that key (ring);
- have `iss` equal to `https://portal.trustauthority.intel.com`;
- be valid at `now`: `nbf` and `iat` not after it, `exp` after it, with no
  leeway.

In each token, the TDX half (Intel's appraisal of the gateway's quote)
must have:

- Intel's nonce issued no later than the token and less than five minutes
  before `now`;
- report data equal to SHA-512 of Intel's nonce (`val`, then `iat`) and the
  gateway's runtime data, rebuilt here as compact JSON from the gateway key
  and TLS key the Intel check established and our nonce:
  `{"signing_algo":"ed25519","signing_address":…,"caller_nonce":…,"tls_cert_fingerprint":…}`;
- MRTD, RTMR0-2 and MRCONFIGID equal to one pinned gateway set. RTMR3 and
  its events are not compared: no event log goes to Intel, and each gateway
  machine's RTMR3 differs;
- Intel's verdict `attester_tcb_status` equal to `UpToDate`, and
  `tdx_is_debuggable` false.

There must be exactly one model token, labelled with the model asked, and
its GPU half must have `x-nvidia-ver` equal to `3.0`, the same Intel nonce
as its TDX half, `eat_nonce` equal to SHA-256 of that nonce, Intel's
verdict `x-nvidia-overall-att-result` true, and at least one GPU. Each GPU
must have:

- `eat_nonce` equal to SHA-256 of Intel's nonce;
- `measres` equal to `success`, `secboot` true and `dbgstat` `disabled`;
- `true` for `x-nvidia-gpu-arch-check`,
  `x-nvidia-gpu-attestation-report-cert-chain-fwid-match`,
  `x-nvidia-gpu-attestation-report-parsed`,
  `x-nvidia-gpu-attestation-report-nonce-match`,
  `x-nvidia-gpu-attestation-report-signature-verified`,
  `x-nvidia-gpu-driver-rim-fetched`, `x-nvidia-gpu-driver-rim-schema-validated`,
  `x-nvidia-gpu-driver-rim-signature-verified`,
  `x-nvidia-gpu-driver-rim-version-match`,
  `x-nvidia-gpu-driver-rim-measurements-available`,
  `x-nvidia-gpu-vbios-rim-fetched`, `x-nvidia-gpu-vbios-rim-schema-validated`,
  `x-nvidia-gpu-vbios-rim-signature-verified`,
  `x-nvidia-gpu-vbios-rim-version-match`,
  `x-nvidia-gpu-vbios-rim-measurements-available` and
  `x-nvidia-gpu-vbios-index-no-conflict`;
- for each of its attestation report's, driver's and firmware's
  certificate chains: `x-nvidia-cert-status` `valid`,
  `x-nvidia-cert-ocsp-status` `good`, and the OCSP answer valid and for the
  nonce asked.

The GPU claims are NVIDIA's appraisal policy (`NVGPURemotePolicyExample.json`
in github.com/NVIDIA/nvtrust), with secure boot and debugging added; in
this version of the claims the policy's three certificate claims are the
chain objects. All were present on every GPU on 19 November.
`x-nvidia-attestation-warning` (empty on every GPU seen), the TDX half's
`cvm_compliance_status` (`not_provided`: NEAR asks for no policy) and the
per-GPU `hwmodel`, driver and firmware versions are not read. Anything
missing, malformed or false is refused.

## What the GPU verdict rests on

- **Intel Trust Authority's signature and its key list.** The key list is
  trusted because it comes over TLS, with Mozilla's roots, from Intel's
  host; the certificate chain in the list (`x5c`) is not checked. On 19
  November the list held one RSA-3072 key, listed for PS384 and RS256.
- **Intel's verifier for NVIDIA GPUs** (each GPU's claims are issued by
  `LOCAL_GPU_VERIFIER`), which checks the GPUs' evidence against NVIDIA's
  certificates and reference values, and NVIDIA's revocation answers as
  that verifier saw them. Cloak does not see the GPU evidence itself.
- **The tie to our nonce.** Our nonce is in the gateway's runtime data, which
  a pinned gateway's quote commits to together with Intel's nonce; the GPU
  evidence was made under SHA-256 of the same Intel nonce. All of these are
  values in Intel's signed token, and every hash is recomputed here; NEAR's
  word is not taken for any link.
- **Freshness.** The GPU evidence was made after Intel issued its nonce,
  which must be less than five minutes old at `now`, by Cloak's clock
  against Intel's date. The GPU evidence may be older than our nonce: the
  gateway's quote, made after our nonce, can name an Intel nonce issued up
  to five minutes before, so one server's evidence could serve several
  requests in that time. How long Intel itself accepts its nonces is not
  documented. All of this holds at the moment the proof passes. A request
  sent under a kept proof (see "Proof age") goes on hardware checked up to
  the proof age before, up to an hour, not at the moment of sending:
  nothing about Intel's tokens, the five minutes included, is looked at
  again.

## The chat request

- **The connection.** A new TLS connection on the route to NEAR, with the
  ordinary certificate checks against Mozilla's roots, and accepted only if
  the SHA-256 of its certificate key equals the one seen when the report was
  fetched, the key the gateway's quote is tied to (for a kept proof, the
  report that proof was checked on). The comparison is made after the
  handshake and before any byte of the request is written. The request is
  written once; a connection that cannot be made is tried again through
  Tor before that (see "Routes"), and another certificate key is not. When
  it still cannot be made, the request stops (`Stop::Connect`) with no
  byte of it written.
- **Kept between requests.** `Kept` holds Intel's collateral and Intel
  Trust Authority's key list. The caller chooses their age, at most a day.
  The collateral is fetched again when older, or when a report names a
  platform family it does not cover; the key list when older, or when a
  token names a key it does not hold (about 12 KB on 19 November). Intel's
  tokens are never kept: each proof check fetches its own, for its own
  nonce.
- **Proof age.** `Kept` also holds, for each model, the proof of the last
  check made for it, when that check passed under a proof age above zero,
  with the gateway TLS key hash it was checked with and the second it
  passed. The caller gives the proof age with each call to `ask` or
  `check`, at most an hour; a longer one is refused before anything is
  fetched. Zero, the probe's default, uses and keeps no proof: every
  request fetches and checks its own. Within the proof age, a request for
  that model fetches and checks nothing and goes straight to sending under
  the kept proof, pinned to the TLS key it was checked with and sealed for
  the model key it checked. The limit: with a kept proof, the hardware was
  checked up to the proof age before, not at the moment of sending. A
  proof older than the call's proof age is not used, nor one whose second
  is after the clock's (the clock went back), and a proof kept for one
  model is never used for another. A new check takes the place of the
  model's kept proof, by its own proof when it passes and by nothing when
  it fails, so a proof is never used after a later check for the model
  failed. When the gateway shows another TLS key, or the reply does not
  open, the model's proof is forgotten and the next request checks afresh;
  nothing is tried again within the request. `Answered` says when the
  proof it was sent under passed.
- **The request.** `POST /v1/chat/completions` with the key as a Bearer
  token, `X-Signing-Algo: ed25519`, `X-Client-Pub-Key`, `X-Model-Pub-Key`
  (the key the proof checked), `X-Encryption-Version: 2`,
  `X-Encrypt-All-Fields: true`, `x-no-aliasing: true` and
  `Accept-Encoding: identity`. Replies are not streamed: a request with
  `stream: true` is refused.
- **The key.** It is used only in the Authorization header. It is never
  kept or logged, and if NEAR's answer quotes it back, it is replaced in the
  whole answer before the answer's start goes into a `Stop`, so no part of
  it is left where the start is cut.
- **Reply key.** A new one for every request, never kept.

## What is encrypted

NEAR's end-to-end encryption, version 2, in all-fields mode, as NEAR's guide
documents it: each field is sealed on its own with X25519 against the
model's key, HKDF-SHA256 and XChaCha20-Poly1305. Sealed for the model key
the proof checked:

- in each message: the content (a list of parts goes as its JSON), the
  name, `reasoning_content`, `reasoning`, `refusal`, and each tool call's
  function name and arguments. Text that happens to read as a JSON list goes
  as one text part, because NEAR's model server reads opened content that
  parses as a list as a list of parts;
- in each tool: its name, description and parameters (as their JSON);
- the function name in an object `tool_choice`.

In the reply, each choice's content, `reasoning_content`, `reasoning`,
`refusal` and each tool call's function name and arguments are opened with
the request's reply key. A field that does not open refuses the whole reply;
nothing is passed on in plain text.

Refused before anything is fetched, because NEAR's encryption would leave
them in plain text: any request field outside the messages, the tools, the
tool choice and the plain settings below (for example `response_format`,
`user`, `metadata`, `functions` or `logprobs`); any other message field
(such as `audio`); and tools other than functions, which have NEAR run a
tool itself. Refused in a reply: log probabilities, audio and the old
`function_call`, none of which the request can ask for.

NEAR's SDK, in all four of its languages, sends only version 3, which also
ties each sealed field to its place in the request and to the reply key.
Version 2 is not deprecated: NEAR's guide and its model server's
compatibility notes still describe it, and NEAR's gateway takes versions 1
to 3.

## What NEAR's gateway still sees

From the research, section 4.5:

- the account and key;
- the model, `X-Model-Pub-Key` and `X-Client-Pub-Key`;
- how many messages there are, their roles, and tool call ids;
- every field's length: a sealed field is its text plus 72 bytes, in hex;
- the settings sent in plain: `temperature`, `top_p`, `max_tokens`,
  `max_completion_tokens`, `n`, `seed`, `stop` (whose sequences are text),
  `presence_penalty`, `frequency_penalty`, `parallel_tool_calls` and
  `stream`;
- usage counts, response ids, finish reasons and timing;
- the Tor exit's address, or on the direct route the Mac's internet
  address.

## What Intel sees

From Cloak: the Tor exit's address (on the direct route, the Mac's
internet address) and the timing of each collateral fetch and each fetch
of the key list. From NEAR's gateway, for each
proof check: the gateway's quote and runtime data (our nonce, the gateway's
key and TLS key fingerprint) and one model server's GPU evidence. A request
sent under a kept proof causes none. Never the prompt, the reply or the
account key. Intel Trust Authority is an online dependency through NEAR:
when NEAR cannot get a token, no proof passes and nothing is sent, unless
a proof for the model is kept within its age.

## What it does not check

- **Which model server the GPUs are in.** NEAR's gateway picks one of the
  model's servers and passes only its GPU evidence to Intel. The GPU token
  carries the gateway's quote, not that server's, so nothing ties the GPUs
  to any of the report's instances, or to the machine whose quote holds
  the model key. The model label beside the token is NEAR's, outside
  Intel's signature, and how many GPUs there are is not compared with the
  report. Each GPU's `ueid` in Intel's token was its device certificate's
  serial number in the report's GPU evidence for the one `Qwen/Qwen3.8-27B`
  server on 19 November, so the GPUs could be matched to an instance's
  evidence; that evidence is outside the instance's quote, so the match
  would rest on NEAR's word, and it is not made.
- **The model's other servers.** One server's GPUs are appraised for each
  proof check. On 19 November `z-ai/glm-5.3-flash` had three servers in its
  report and one token on eight GPUs; `Qwen/Qwen3.8-27B` had one server and
  one token on eight GPUs.
- **That the GPUs and any Intel quote are one machine.** The GPUs, the
  gateway's quote and the model servers' quotes share only nonces.
- **The GPUs' firmware and driver against values of Cloak's own.** Intel's
  verifier compares them with NVIDIA's reference values and says whether
  they match; Cloak trusts that verdict, signed by a key Intel publishes.
- **The gateway's RTMR3 events in the token.** The gateway the token
  appraised has pinned firmware, kernel and compose file, but its
  `app-id`, `key-provider`, `mr-kms` and `os-image-hash` are not checked
  there (they are, in the report's quote).
- **The model workload.** A measured launcher fetches the model and its
  server after boot; they are not in the hardware measurement, and the
  launcher's own record (`compose_manager_attestation`) is not checked.
- **Where the images came from.** The pins are what NEAR's servers presented
  on 19 November 2026; NEAR publishes no signed list of expected values, and
  no container signatures are checked.
- **Who wrote a reply.** Version 2 replies are not tied to their sender:
  anyone who sees `X-Client-Pub-Key`, NEAR's gateway included, can seal a
  reply for it. NEAR's response signatures would tie a reply to the model,
  and they are not checked yet.
- **Streaming.** Refused for now. Real replies did open on 19 November 2026,
  for `z-ai/glm-5.3-flash` and `Qwen/Qwen3.8-27B` in all-fields mode, with
  the build before the GPU check; none has been sent since it was added.
- Also not checked: the OHTTP key's signature (Cloak will not use OHTTP), and
  NEAR's key service, which decides which machines get the model's key.

## Known and not solved

- **NVIDIA's own service refuses most Tor exits.** The GPU check first
  posted each server's evidence to NVIDIA's attestation service
  (`nras.attestation.nvidia.com`). On 19 November, through a tor started
  for the purpose, it answered 403 Forbidden (a "Your client does not have
  permission to get URL" page, before any check of the evidence) on 7 of 8
  circuits, to the evidence post and to its public key list alike. That
  route is gone; the GPU verdict now comes from Intel Trust Authority
  through NEAR.
- **Intel's hosts are often out of reach through Tor.** On 19 November
  many exits could not connect to Intel at all (Tor's SOCKS answer 4, host
  unreachable, with no answer from Intel):
  `portal.trustauthority.intel.com` on 9 of 13 circuits tried for it
  alone, `certificates.trustedservices.intel.com` on 4 of 4, and
  `api.trustedservices.intel.com` in 1 of 8 probe runs.
  Intel did not refuse any connection that reached it, and in every probe
  run whose collateral came, the key list came on the same circuit. Later
  that day, on ten separate circuits each, Intel's three hosts answered 10
  of 10. A connection that cannot be made is now tried on up to three
  circuits (see "Routes"); how often a check still stops this way has not
  been measured with this build.
- **NEAR's call to Intel fails at times.** NEAR's gateway answered 502
  (`ITA upstream error: ITA transport error`) to 2 of 8 token requests for
  `z-ai/glm-5.3-flash` on 19 November; all 5 for `Qwen/Qwen3.8-27B` were
  answered. A 502 is now asked again, up to three asks in all.
- **A second `Qwen/Qwen3.8-27B` server is not pinned.** On 19 November a
  report for `Qwen/Qwen3.8-27B` listed a new server (label `gpu04`) whose
  compose file differs from the pinned `gpu23` one in its label and its
  telemetry address. The only saved report with it has no fetch time, so
  it was not checked and not pinned: until it is, a report that lists that
  server is refused, naming its compose hash without the label.

## Dependencies

Each already in the tree through another crate; two are direct, both
permissively licensed and pinned by Cargo.lock: `ring` 0.17.14 (Apache-2.0
AND ISC), for PS384, and `base64` 0.23.1 (MIT OR Apache-2.0), for Intel's
tokens. No dependency was added for Intel Trust Authority, nor for trace
sharing: its device key and NEAR's receipts are Ed25519 through `ring`, and
its UUIDs and RFC 3339 times are made in `src/share.rs`.

## Pins

`reference/near-pins.json` says how they were obtained. When NEAR deploys a
new gateway or model image, its servers stop matching and every check is
refused until the pins are updated from a reviewed live report. On 19
November one model (`z-ai/glm-5.3-flash`) ran on three measured
configurations (two OS images, three compose files), and one machine served
two models, so the model sets are a list not tied to a model. A model set
pins the compose file without its host's label, so a new server whose
compose file differs from a pinned one only in the label's digits passes;
the gateway set pins the whole compose file through MRCONFIGID.

## The helper

`cloak-near` (`src/bin/cloak-near.rs`, its lines in `src/helper.rs`) is
the helper the Mac app starts for NEAR mode. It runs on the Mac, not in
the guest, and takes no arguments: the account key never goes on its
command line. It reads one request a line on standard input, each one JSON
object, and writes one answer a line on standard output for each, in
order. It takes one line at a time: the next is read once the last is
answered, so an `ask` holds the lines after it until NEAR replies (up to
five minutes) or it stops; an `enrol` waits for the person's sign-in in the
browser until it finishes or the Mac ends the helper, and a `review` waits
up to 570 seconds for the witness. It ends when standard input closes.
Nothing else goes to standard output; standard error gets only a failure
to read or write those two, never a key, a session, a message or a reply.

One `Kept` lasts as long as the helper: Intel's collateral and keys for an
hour, and a proof kept by one line can serve a later one (see "Proof
age"). The pins are compiled in from `reference/near-pins.json`, as the
probe's are.

### Requests

Every field is required, and any other field is refused.

- `request`: `check` or `ask`.
- `model`: the model's name on NEAR AI Cloud.
- `route`: `{"via":"direct"}` or
  `{"via":"tor","socket":PATH,"near_identity":NAME,"intel_identity":NAME}`.
  **Direct** is an ordinary connection from the Mac: NEAR and Intel see
  the Mac's internet address. **Tor** goes through tor's SOCKS port at the
  socket file PATH, NEAR's connections under the SOCKS user name
  `near_identity` and Intel's under `intel_identity`, so each has a
  circuit of its own (the SOCKS password is always `cloak`).
- `proof_age`: seconds, at most 3600. A proof kept for the model that
  passed no longer ago than this is used; 0 uses and keeps none.
- For `ask` only: `key`, the account key, and `body`, the OpenAI-shaped
  chat request, a JSON object for the same model, not streamed.

A `check` runs `check`: it finds a kept proof within the proof age, or
fetches and checks a new one, and sends nothing to the chat endpoint. It
needs no key, so the app can run it before the person types. An `ask`
runs `ask`: the same check, then the request.

    {"request":"check","model":"Qwen/Qwen3.8-27B","route":{"via":"tor","socket":"/var/folders/xy/abc123/T/cloak-tor.Ab12Cd/socks","near_identity":"5f0c9a1e","intel_identity":"b7d24e60"},"proof_age":600}
    {"request":"ask","model":"Qwen/Qwen3.8-27B","route":{"via":"direct"},"proof_age":600,"key":"sk-example","body":{"model":"Qwen/Qwen3.8-27B","messages":[{"role":"user","content":"ping"}]}}

### Answers

Every answer has `answer` and `sent`. `sent` says whether the chat request
may have reached NEAR: false when no byte of it was written (a `check`, or
a stop before sending), true once writing it began.

- `passed`, for a `check`: `sent` false and `proof`.
- `replied`, for an `ask`: `sent` true, `proof`, and `reply`, NEAR's chat
  completion with every encrypted field opened.
- `stopped`: `sent`, `stop` (the step that stopped, below), and `text`,
  the plain-English reason (`Stop`'s words); with `stop` `status`, also
  `code`, NEAR's HTTP status.

`proof` holds `passed_at`, when the proof passed, in seconds since 1970
(for a kept proof, during an earlier line: the hardware was checked then,
not when the request went); `model_servers`, how many of the model's
servers the Intel check covered; `gpus`, how many GPUs of one server Intel
Trust Authority passed; `model_key`, the model key the request is sealed
for; and `gateway_tls_key_sha256`, the SHA-256 of the gateway TLS key the
request's connection must show. Both keys are in hex.

| `stop` | Step | `sent` |
| --- | --- | --- |
| `line` | The line is not JSON, or not a request in this format | false |
| `request` | The request cannot go as given, or the proof age is over an hour | false |
| `fetch` | Fetching the report, Intel's collateral, Intel Trust Authority's tokens or Intel's keys | false |
| `refused` | The proof was refused | false |
| `connect` | The proof passed; the chat request's connection could not be made | false |
| `pin` | The proof passed; the gateway showed another TLS key | false |
| `send` | Writing the request or reading NEAR's answer failed: NEAR may have it | true |
| `status` | NEAR answered with a status other than 200 | true |
| `reply` | NEAR's reply was refused: a field did not open, or it is not the completion asked for | true |

A `line` stop never quotes the line. No answer holds the key: it goes only
into the request's Authorization header, and is replaced if NEAR's answer
quotes it back.

    {"answer":"passed","sent":false,"proof":{"passed_at":1795125440,"model_servers":1,"gpus":8,"model_key":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","gateway_tls_key_sha256":"ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"}}
    {"answer":"replied","sent":true,"proof":{"passed_at":1795125440,"model_servers":1,"gpus":8,"model_key":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","gateway_tls_key_sha256":"ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"},"reply":{"id":"chatcmpl-example","object":"chat.completion","created":1795125452,"model":"Qwen/Qwen3.8-27B","choices":[{"index":0,"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11}}}
    {"answer":"stopped","sent":false,"stop":"fetch","text":"fetching the proof: could not connect: Connection reset by peer (os error 54)"}
    {"answer":"stopped","sent":true,"stop":"status","code":401,"text":"NEAR answered 401: invalid key"}
    {"answer":"stopped","sent":false,"stop":"line","text":"the line is not JSON"}

### Trace sharing's lines

Trace sharing with NEAR's Trace Commons (docs/near-share.md, section 7)
adds eight lines. The Mac sends `readied` to the helper it chats through,
since it is a chat request, and the others to a second `cloak-near` of
their own. Each takes `route` as above: the commons, its issuer, its
witness and NEAR on the `near_identity` circuit, Intel on the
`intel_identity` one, every certificate checked against Mozilla's roots.
Every field is required, and any other field is refused.

- `listen` (`route`): reads the commons' capabilities
  (`GET https://ingest.tracecommons.ai/v1/account/near/provision/capabilities`),
  checks that they name the issuer and the witness this Cloak knows, the
  witness pin and the upload audience, and opens a listener on
  `127.0.0.1`, on a port the system picks.
  Answer `listening`: `sent` false, and `github` and `google`, the NEAR AI
  sign-in's address for each, for the Mac to open in the browser. A new
  `listen` closes the listener of the one before.
- `enrol` (`route`, `device_key`, the device key's 32-byte Ed25519 seed in
  standard base64): waits for the browser to come back from the sign-in to
  `/trace-commons/near-ai/callback`. The page served there, whose one
  script the page's Content-Security-Policy allows by its hash, posts the
  address's fragment, with a state value of this sign-in's own, to
  `/trace-commons/near-ai/deposit`, and takes the fragment out of the
  address. Only a request whose `Host` is the listener's own address, and a
  deposit whose `Origin` is too, is taken. The NEAR AI session token comes
  from the fragment, and its refresh token is never read. The commons'
  enrolment ceremony runs under a PKCE challenge with the device key's
  signature, and the session token is dropped once the finish is sent.
  Answer `enrolled`: `account`, which every later line carries back and
  none of which is secret (the tenant, the device key's id, the issuer's
  address, the upload audience and the witness pin as the commons published
  it); and `session`, the account session, a bearer for withdrawing, for
  the Mac to keep with the device key.
- `ready` (`route`, `device_key`, `account`, `scopes`): an upload claim
  from the issuer, its request signed by the device key, then the commons'
  admission challenge under that claim. Answer `admitted`:
  `binding`, and `expires_at` in seconds since 1970, at most 15 minutes on.
- `readied` (an `ask`'s fields, and `admission`, the binding): runs
  `ask_readied`. Answer `exchanged`: `sent` true; `proof` and `reply` as
  `replied` has them; `request` and `response`, the request body exactly as
  written and the reply body exactly as it came, in standard base64; and
  either `receipt`, NEAR's receipt for the two, or `no_receipt`, why there
  is none. A receipt is taken only as an Ed25519 signature by the model key
  the message's proof covers, of the model's name and the SHA-256 of the
  two bodies; it proves the model's server signed for those bytes, not
  what the model did with them. The reply stands either way.
- `review` (`route`, `account`, `scopes`; `exchange`, with
  `request`, `response` and `receipt` as `exchanged` gave them; and
  `version`, Cloak's version, which the trace names): fetches the witness's
  quote under a fresh nonce and checks it against the pin in `account`,
  with Intel's collateral for its platform family, kept or fetched: Intel's
  rules under the same policy as NEAR's servers, not in debug mode, report
  data of `tcwitns1`, the witness's signing address and the nonce, and one
  accepted set of registers. Only once it passes is the exchange sent to
  the witness, as one raw contribution, for redaction. Answer `reviewed`:
  `envelope`, the witness's answer exactly as it came, in standard base64;
  its four headers, `certificate`, `signature`, `evidence` and
  `evidence_signature`; and the `submission_id` the contribution was made
  with. The witness takes the exchange's request and reply bodies out
  before it redacts, so the envelope holds what the trace says of the chat,
  not its words.
- `upload` (`route`, `device_key`, `account`, `scopes`, and `envelope`,
  with `body` and the four headers as `reviewed` gave them): a new claim,
  then the envelope's bytes exactly, and no others, to `/v1/traces` with
  the four headers. Answer `uploaded`: `commons`, the commons' answer as it
  came, which must name the trace's `status`.
- `status` (`route`, `device_key`, `account`, and `submissions`, 1 to 100
  submission ids): a claim for the account's full grant, then the commons'
  status of each. Answer `reported`: `commons`, as it came.
- `withdraw` (`route`, `session`, `submission`): withdraws one submission
  under the account session. Answer `withdrawn`: `commons`, the commons'
  answer as it came, which says how far the trace had gone
  (`distribution_reach`), and `session` when the commons renewed the
  session.

`scopes` are the commons' consent scopes: `debugging_evaluation` always,
and any of `benchmark_only`, `ranking_training`, `model_training` and
`public_attribution`, each name once. The helper turns them into the uses
they grant itself, by the commons' own client's table, with
`aggregate_analytics` added.

The issuer (`issuer.tracecommons.ai`) and the witness (its direct Phala
address, `2904b99d74bc6ff9ffda211479b0a95cb9237a38-8088.dstack-pha1-prod5.phala.network`)
are fixed in `src/share.rs`, as NEAR's pins are. `listen`, and every line
that goes to the issuer or the witness, stops at `moved` when the
capabilities or the account name others: sharing stops until Cloak is
updated.

What the witness check covers, and what it does not: the quote proves the
witness's enclave runs the measured image and holds the signing address
the commons pins. Its report data ties no TLS key, and Phala's gateway,
not the enclave, ends TLS at that address, so the connection the chat goes
to the witness on is checked only against Mozilla's roots. Phala, or
whoever holds a certificate for that address, can read the chat on its way
to the witness (docs/near-share.md, section 8).

For these lines `sent` says whether the step's own request may have
reached its host. `readied` stops as `ask` does; the others stop at:

| `stop` | Step | `sent` |
| --- | --- | --- |
| `line` | The line is not JSON, or not a request in this format | false |
| `request` | The line cannot go as given | false |
| `signin` | The sign-in in the browser did not finish, or NEAR AI sent no session | false |
| `moved` | The commons names another issuer or witness than this Cloak knows | false |
| `fetch` | Reading the capabilities, the witness's quote or Intel's collateral for it | false |
| `claim` | The issuer gave no upload claim, so the step's own request was not sent | false |
| `refused` | The witness's enclave did not pass: nothing was sent to it | false |
| `connect` | The step's connection could not be made | false |
| `send` | Writing the step's request or reading its answer failed: the host may have it | true |
| `status` | The host answered with a status other than 200 to 299 | true |
| `reply` | The host's answer is not the one asked for | true |

No answer holds the device key, the NEAR AI session or a claim; only
`enrolled` and `withdrawn` hold the account session.

    {"request":"listen","route":{"via":"direct"}}
    {"answer":"listening","sent":false,"github":"https://cloud-platform.near.ai/v1/auth/github?frontend_callback=http%3A%2F%2F127.0.0.1%3A49235%2Ftrace-commons%2Fnear-ai%2Fcallback","google":"https://cloud-platform.near.ai/v1/auth/google?frontend_callback=http%3A%2F%2F127.0.0.1%3A49235%2Ftrace-commons%2Fnear-ai%2Fcallback"}
    {"answer":"stopped","sent":false,"stop":"refused","text":"the witness was refused: the witness's quote is not tied to its signing address and our nonce"}

## Running it

    cargo build --locked
    cargo build --locked --release --bin cloak-near   # the helper, for the Mac
    cargo test --locked            # the gate checks, offline
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B
    cargo run --locked --bin cloak-near-probe -- --direct --model Qwen/Qwen3.8-27B
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B --key-file FILE
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B --key-file FILE --proof-age 600 --repeat 3

The gate checks:

- `tests/proof.rs`: the Intel check against a saved live report; and the
  GPU check against one set fetched together through Tor by the probe's
  `--save` (`tests/fixtures/ita`): a report for `Qwen/Qwen3.8-27B`, its
  nonce, TLS key hash and collateral, NEAR's answer of Intel's tokens under
  the same nonce, and Intel's key list. The Intel side of that set is
  checked first, as `ask` does. The real set passes at its fetch time, and
  is refused for another nonce, a changed signature on either token, a key
  Intel does not list, a failed GPU claim, a revoked certificate, a false
  overall verdict, a missing GPU token, a token without its GPU half or
  with no GPU, GPU evidence under another nonce, an Intel nonce over five
  minutes old, an unpinned gateway and an expired token. Changes Intel's
  signature forbids are signed again with a key made for these checks alone
  (`tests/fixtures/ita/test-key.der`) and added to the key list; the real
  tokens signed again unchanged that way pass, so each refusal comes from
  its change.
- `src/verify.rs`: the host's label, on the real compose file of a pinned
  model server (`gpu23`). The same file with other label digits (`gpu04`,
  `gpu7`, `gpu1234`) gives the same pin; a label with letters or more
  than four digits, no label and two labels are refused; so are another
  telemetry address and one byte more before or after the label.
- `src/chat.rs`: the proof age. A passed proof is put in `Kept` by hand and
  `ask` is pointed at a proxy on this machine that closes every
  connection, so its `Stop` shows whether it went to fetch a new report or
  straight to sending. A proof within the age is sent under; one a second
  older than the age, one too old for a call with a shorter age, one whose
  second is after the clock's, one kept for another model and one whose
  new check failed are not, and a new report is fetched; under a proof age
  of zero nothing is used or kept; a proof age over an hour is refused
  before anything is fetched, with a proof kept or not.
- `src/helper.rs`: a `check` line with a proof kept for the model passes
  and opens no connection at all (the route's socket file counts every
  connection), while an `ask` line with the same kept proof goes to the
  chat request's connection, which is closed at once, and says nothing
  was sent.
- `tests/helper.rs`: the `cloak-near` binary itself, given an `ask` line
  and then a `check` line, through tor at a socket file whose listener
  closes every connection: both answers say the line stopped while
  fetching the proof, with `sent` false, and neither standard output nor
  standard error holds the key or the message's words.
- `src/gate.rs`: NEAR's published version 2 vectors open, do not open with
  one byte changed, and what this crate seals for NEAR's key opens with
  NEAR's secret. A stand-in for NEAR's gateway on this machine (a SOCKS5
  proxy, then a TLS server with a certificate from an authority made for the
  check alone, in `tests/fixtures/stand-in`) opens every sealed field of a
  request with the model's key and checks the headers; its sealed reply
  comes back in plain text; a reply with a changed or a plain field is
  refused; and a certificate key other than the pinned one is refused before
  any request byte reaches it.
- `src/share.rs`, against a stand-in for every host trace sharing reaches
  (`src/stand_in.rs`: a SOCKS5 proxy at a socket file in a folder of its
  own, then a TLS server for the commons' hosts and NEAR's gateway with a
  certificate from an authority made for these checks alone, in
  `tests/fixtures/share-stand-in`), which records every request. A witness
  whose quote does not pass gets nothing: the stand-in witness serves a
  real quote that is not a witness's (the gateway's, from the saved
  report), with Intel's real collateral for it held, and a `review` line
  stops at `refused` with `sent` false after one request, the attestation
  read; that quote passes Intel's own check at its fetch time and is
  refused for its report data, at a fixed time. The readied message goes
  only where its proof covers: with no proof it stops before any byte, on
  a gateway showing another key than its proof's it stops at `pin` with
  nothing written, and under its own proof it goes once, in plain text,
  with the commons' challenge. And the upload is the envelope shown, byte
  for byte: an envelope written as no encoder would write it again reaches
  the stand-in ingest exactly, under the claim the stand-in issuer gave for
  a request the device key signed, with the witness's four headers.

The probe is for development. It takes exactly one route: `--socks
HOST:PORT` (Tor's SOCKS5 port, one circuit for NEAR and one for Intel) or
`--direct` (no Tor: NEAR and Intel see the Mac's internet address), and
its first line says which. Without `--key-file` it makes only the
report GET, Intel's collateral GETs, the GET of Intel's tokens from NEAR
and the GET of Intel's key list, and prints each outcome, with timings, in
plain words; `--save DIR` keeps what it fetched, as `tests/fixtures` is
kept. With `--key-file` it reads the account key from FILE and makes one
chat request through `ask`, the message "ping", after the proof check. It
never prints the key. `--repeat N` makes N such requests with one `Kept`,
and `--proof-age SECONDS` (0 when not given) is the proof age it keeps a
passed proof for; for each request it says how long it took and how long
before the reply its proof passed.

No code is copied from NEAR, Intel, NVIDIA or anywhere else. NEAR's
MIT-licensed `inference-sdk` and its model server's source
(`inference-proxy`, which carries no licence file) were read; the SDK's
published version 2 vectors are copied, with its MIT licence, into
`tests/fixtures/near-inference-sdk`.
NEAR's `cloud-api` (PolyForm Strict) was read, to learn how its gateway
builds Intel's evidence; nothing is copied from it. Intel's
`trustauthority-client-for-go` and its token documentation, and NVIDIA's
`nvtrust` attestation SDK and appraisal policy, were read; the claim names
they document are used.
