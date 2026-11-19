# cloak-near

Slices 1 to 3 of Cloak's NEAR mode: the check of NEAR AI Cloud's hardware
proof, its Intel quotes and Intel Trust Authority's verdict on its GPUs,
made before anything is sent, and the one chat request that follows a
passed check, encrypted to the model key the check established. It holds
no account: the caller gives the key for each request. It is not yet part
of the guest image, the build scripts or the app.

- `fetch_report` opens one TLS connection to `cloud-api.near.ai` through a
  SOCKS5 proxy (names resolved by the proxy, a SOCKS user name of the
  caller's for Tor stream isolation), with ordinary certificate checks
  against Mozilla's roots. It records the SHA-256 of the gateway
  certificate's SubjectPublicKeyInfo, and on that connection asks for one
  model's attestation report with a fresh 32-byte nonce, no Authorization
  header, `x-no-aliasing: true` and an uncompressed body of at most 4 MiB (about 245 KB an instance
  on 19 November).
- `fetch_collateral` fetches, through the same proxy, the Intel collateral
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
- `ask` sends one chat request, and is the only way to send one. In one
  call and in this order: the request is checked; a report is fetched under
  a fresh nonce; Intel's collateral is reused from `Kept` or fetched; the
  Intel quotes are verified; Intel Trust Authority's tokens are fetched
  from NEAR under the same nonce; Intel's keys are reused from `Kept` or
  fetched; the GPU side is verified; and only then, holding a `Proof` with
  both halves, is the request sent. There is no way to skip the GPU. A
  failed step ends the call with its `Stop` and nothing is sent. NEAR's
  gateway and Intel's servers each go through a route of the caller's
  (`Routes`), meant to be two Tor circuits.

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
- MRTD, RTMR0-2, MRCONFIGID and the RTMR3 events `app-id`, `key-provider`,
  `mr-kms` and `os-image-hash` equal one accepted set in
  `reference/near-pins.json`, every value alike.

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
  documented.

## The chat request

- **The connection.** A new TLS connection through the same proxy, with the
  ordinary certificate checks against Mozilla's roots, and accepted only if
  the SHA-256 of its certificate key equals the one seen when the report was
  fetched, the key the gateway's quote is tied to. The comparison is made
  after the handshake and before any byte of the request is written.
- **Kept between requests.** `Kept` holds Intel's collateral and Intel
  Trust Authority's key list. The caller chooses their age, at most a day.
  The collateral is fetched again when older, or when a report names a
  platform family it does not cover; the key list when older, or when a
  token names a key it does not hold (about 12 KB on 19 November). Intel's
  tokens are never kept: each request has its own, for its own nonce.
- **The request.** `POST /v1/chat/completions` with the key as a Bearer
  token, `X-Signing-Algo: ed25519`, `X-Client-Pub-Key`, `X-Model-Pub-Key`
  (the key the proof checked), `X-Encryption-Version: 2`,
  `X-Encrypt-All-Fields: true`, `x-no-aliasing: true` and
  `Accept-Encoding: identity`. Replies are not streamed: a request with
  `stream: true` is refused.
- **The key.** It is used only in the Authorization header. It is never
  kept or logged, and if NEAR's answer quotes it back, it is replaced before
  the answer goes into a `Stop`.
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
- the Tor exit's address.

## What Intel sees

From Cloak: the Tor exit's address and the timing of each collateral
fetch and each fetch of the key list. From NEAR's gateway, for each
request: the gateway's quote and runtime data (our nonce, the gateway's
key and TLS key fingerprint) and one model server's GPU evidence. Never the
prompt, the reply or the account key. Intel Trust Authority is an online
dependency through NEAR: when NEAR cannot get a token, nothing is sent.

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
  request. On 19 November `z-ai/glm-5.3-flash` had three servers in its
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
  run whose collateral came, the key list came on the same circuit.
  Nothing here retries on another circuit or goes around Tor, so `ask`
  stops when the circuit's exit cannot reach Intel and nothing is kept yet.
- **NEAR's call to Intel fails at times.** NEAR's gateway answered 502
  (`ITA upstream error: ITA transport error`) to 2 of 8 token requests for
  `z-ai/glm-5.3-flash` on 19 November; all 5 for `Qwen/Qwen3.8-27B` were
  answered.

## Dependencies

Each already in the tree through another crate; two are direct, both
permissively licensed and pinned by Cargo.lock: `ring` 0.17.14 (Apache-2.0
AND ISC), for PS384, and `base64` 0.23.1 (MIT OR Apache-2.0), for Intel's
tokens. No dependency was added for Intel Trust Authority.

## Pins

`reference/near-pins.json` says how they were obtained. When NEAR deploys a
new gateway or model image, its servers stop matching and every check is
refused until the pins are updated from a reviewed live report. On 19
November one model (`z-ai/glm-5.3-flash`) ran on three measured
configurations (two OS images, three compose files), and one machine served
two models, so the model sets are a list not tied to a model.

## Running it

    cargo build --locked
    cargo test --locked            # the gate checks, offline
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B --key-file FILE

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
- `src/gate.rs`: NEAR's published version 2 vectors open, do not open with
  one byte changed, and what this crate seals for NEAR's key opens with
  NEAR's secret. A stand-in for NEAR's gateway on this machine (a SOCKS5
  proxy, then a TLS server with a certificate from an authority made for the
  check alone, in `tests/fixtures/stand-in`) opens every sealed field of a
  request with the model's key and checks the headers; its sealed reply
  comes back in plain text; a reply with a changed or a plain field is
  refused; and a certificate key other than the pinned one is refused before
  any request byte reaches it.

The probe is for development. Without `--key-file` it makes only the
report GET, Intel's collateral GETs, the GET of Intel's tokens from NEAR
and the GET of Intel's key list, and prints each outcome, with timings, in
plain words; `--save DIR` keeps what it fetched, as `tests/fixtures` is
kept. With `--key-file` it reads the account key from FILE and makes one
chat request through `ask`, the message "ping", after the proof check. It
never prints the key.

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
