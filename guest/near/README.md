# cloak-near

Slices 1 to 3 of Cloak's NEAR mode: the check of NEAR AI Cloud's hardware
proof, Intel's side and NVIDIA's, made before anything is sent, and the one
chat request that follows a passed check, encrypted to the model key the
check established. It holds no account: the caller gives the key for each
request. It is not yet part of the guest image, the build scripts or the
app.

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
- `gpu_evidence` is pure: it reads each model entry's GPU evidence
  (`nvidia_payload`) and checks it was gathered under our nonce. Only what
  it returns can be posted.
- `fetch_gpu_verdict` posts one instance's evidence, unchanged, to NVIDIA's
  attestation service (`nras.attestation.nvidia.com/v3/attest/gpu`, version
  3, as NEAR's SDK uses) through the proxy, with no account key, and
  `fetch_nvidia_keys` fetches the list of keys NVIDIA signs its verdicts
  with, from `/.well-known/jwks.json` on the same host. Both use ordinary
  certificate checks and a generic user agent.
- `verify_intel` is pure: report bytes, nonce, the key hash seen, the model
  name, the collateral, the pins and `now` in; an `IntelProof` or one
  `Refusal` out.
- `verify_gpu` is pure: report bytes, nonce, NVIDIA's answers, NVIDIA's key
  list and `now` in; a `GpuProof` or one `Refusal` out.
- `ask` sends one chat request, and is the only way to send one. In one
  call and in this order: the request is checked; a report is fetched under
  a fresh nonce; Intel's collateral is reused from `Kept` or fetched; the
  Intel side is verified; each instance's evidence is checked to carry the
  nonce and posted to NVIDIA; NVIDIA's keys are reused from `Kept` or
  fetched; the GPU side is verified; and only then, holding a `Proof` with
  both halves, is the request sent. There is no way to skip the GPU. A
  failed step ends the call with its `Stop` and nothing is sent. The three
  services each go through a route of the caller's (`Routes`), meant to be
  three Tor circuits.

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

For every model entry, before anything is posted: `nvidia_payload` is
present, is a JSON object with a list of evidence that is not empty, and its
`nonce` is ours.

NVIDIA answers each post with `[["JWT", overall token], {"GPU-0": token,
…}]`. Every token, the overall one and each GPU's, must:

- name, in its header, `ES384` and a key that NVIDIA's key list holds as a
  P-384 key, and its signature must verify with that key (ring);
- have `iss` equal to `https://nras.attestation.nvidia.com`;
- be valid at `now`: `nbf` and `iat` not after it, `exp` after it, with no
  leeway, as in NEAR's SDK;
- have `eat_nonce` equal to our nonce.

The overall token must have `x-nvidia-ver` equal to `2.0` and
`x-nvidia-overall-att-result` equal to `true`. There must be one GPU token
for each GPU in that instance's evidence, and each must have:

- `measres` equal to `success`;
- `true` for `x-nvidia-gpu-arch-check`,
  `x-nvidia-gpu-attestation-report-cert-chain-validated`,
  `x-nvidia-gpu-attestation-report-parsed`,
  `x-nvidia-gpu-attestation-report-nonce-match`,
  `x-nvidia-gpu-attestation-report-signature-verified`,
  `x-nvidia-gpu-driver-rim-fetched`, `x-nvidia-gpu-driver-rim-schema-validated`,
  `x-nvidia-gpu-driver-rim-cert-validated`,
  `x-nvidia-gpu-driver-rim-signature-verified`,
  `x-nvidia-gpu-driver-rim-measurements-available`,
  `x-nvidia-gpu-vbios-rim-fetched`, `x-nvidia-gpu-vbios-rim-schema-validated`,
  `x-nvidia-gpu-vbios-rim-cert-validated`,
  `x-nvidia-gpu-vbios-rim-signature-verified`,
  `x-nvidia-gpu-vbios-rim-measurements-available` and
  `x-nvidia-gpu-vbios-index-no-conflict`;
- `secboot` equal to `true` and `dbgstat` equal to `disabled`.

The overall token's checks are those of NEAR's SDK (`rs/src/nvidia.rs`),
which does not read the GPU tokens. The GPU tokens' required values are
NVIDIA's own appraisal policy for version 3 (`NVGPURemotePolicyExample.json`
in github.com/NVIDIA/nvtrust), with secure boot and debugging added; all
were present on every GPU NVIDIA appraised on 19 November. NVIDIA's
`x-nvidia-attestation-warning` and the overall token's `submods` digests are
not read. Anything missing, malformed or false is refused.

## The chat request

- **The connection.** A new TLS connection through the same proxy, with the
  ordinary certificate checks against Mozilla's roots, and accepted only if
  the SHA-256 of its certificate key equals the one seen when the report was
  fetched, the key the gateway's quote is tied to. The comparison is made
  after the handshake and before any byte of the request is written.
- **Kept between requests.** `Kept` holds Intel's collateral and NVIDIA's
  key list. The caller chooses their age, at most a day. The collateral is
  fetched again when older, or when a report names a platform family it does
  not cover; the key list when older, or when a verdict names a key it does
  not hold (NVIDIA signs with a new key many times a day: its list held 208
  keys, about 513 KB, on 19 November). NVIDIA's verdicts are never kept: each
  request has its own, for its own nonce.
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

## What NVIDIA's service sees

For each request, each instance's GPU evidence as NEAR published it (with
our nonce), the Tor exit's address, and the timing; and a fetch of its key
list now and then. Never the prompt, the reply or the account key. It is an
online dependency: when it does not answer, or refuses, nothing is sent.

## What it does not check

- **That the GPUs and the Intel quote are one machine.** An instance's GPU
  evidence and its Intel quote share only the nonce; nothing proves the
  GPUs NVIDIA passed are in the machine whose quote passed.
- **The GPUs' firmware and driver against values of Cloak's own.** NVIDIA's
  service compares them with NVIDIA's reference values and says whether
  they match; Cloak trusts that verdict, signed by a key NVIDIA publishes on
  the same host.
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
- **A real reply.** No request with a real key has been made. That a real
  reply opens, that NEAR accepts all-fields mode for the chosen models, and
  streaming are all unproven.
- Also not checked: the OHTTP key's signature (Cloak will not use OHTTP), and
  NEAR's key service, which decides which machines get the model's key.

## Known and not solved

- **NVIDIA refuses most Tor exits.** On 19 November, through a tor started
  for the purpose, NVIDIA's service answered 403 Forbidden (a "Your client
  does not have permission to get URL" page, before any check of the
  evidence) on 7 of 8 circuits, to the evidence post and to the public key
  list alike, in about a second. One exit got 200 on both, with no account
  key. While that holds, `ask` stops at NVIDIA most of the time; nothing
  here retries on another circuit or goes around Tor.
- **NVIDIA's terms.** NVIDIA's attestation service terms may require a
  commercial licence for a paid product; they must be read before release.

## Dependencies

Each already in the tree through another crate; two are now direct, both
permissively licensed and pinned by Cargo.lock: `ring` 0.17.14 (Apache-2.0
AND ISC), for ES384, and `base64` 0.23.1 (MIT OR Apache-2.0), for NVIDIA's
tokens.

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
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model z-ai/glm-5.3-flash
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model z-ai/glm-5.3-flash --key-file FILE

The gate checks:

- `tests/proof.rs`: the Intel check against a saved live report; and the
  GPU check against another saved live report with NVIDIA's real answer to
  its evidence and NVIDIA's real key list (`tests/fixtures/nvidia`). The
  real set passes at its fetch time, and is refused when the evidence's
  nonce differs (before anything would be posted), the evidence is missing
  from an entry, a token's signature is changed, a token names a key NVIDIA
  does not list, a token's nonce differs, the overall result is false, a
  GPU's claim fails, a GPU's token is missing, or the token has expired.
  Changes NVIDIA's signature forbids are signed again with a key made for
  each run alone and added to the key list; the real tokens signed again
  unchanged that way pass, so each refusal comes from its change. The key
  list was fetched directly rather than through Tor, because NVIDIA refused
  it through Tor; the report and NVIDIA's answer came through Tor.
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
report GET, Intel's collateral GETs, one POST of each instance's GPU
evidence to NVIDIA and the GET of NVIDIA's key list, and prints each
outcome, with timings, in plain words; `--save DIR` keeps what it fetched,
as `tests/fixtures` is kept. With `--key-file` it reads the account key
from FILE and makes one chat request through `ask`, the message "ping",
after the proof check. It never prints the key.

No code is copied from NEAR, NVIDIA or anywhere else. NEAR's MIT-licensed
`inference-sdk` and its model server's source (`inference-proxy`, which
carries no licence file) were read; the SDK's published version 2 vectors
are copied, with its MIT licence, into `tests/fixtures/near-inference-sdk`.
NVIDIA's `nvtrust` attestation SDK and appraisal policy were read; the claim
names it documents are used.
