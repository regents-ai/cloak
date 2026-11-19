# cloak-near

Slices 1 and 2 of Cloak's NEAR mode: the check of NEAR AI Cloud's hardware
proof, made before anything is sent, and the one chat request that follows a
passed check, encrypted to the model key the check established. It holds no
account: the caller gives the key for each request. It is not yet part of
the guest image, the build scripts or the app.

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
- `verify` is pure: report bytes, nonce, the key hash seen, the model name,
  the collateral, the pins and `now` in; a `CpuOnlyProof` or one `Refusal`
  out.
- `ask` sends one chat request, and is the only way to send one. In one
  call and in this order: the request is checked; a report is fetched under
  a fresh nonce; Intel's collateral is reused from `KeptCollateral` or
  fetched; the proof is verified; and only then is the request sent. A
  failed step ends the call with its `Stop` and nothing is sent.

## What `verify` checks

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

## The chat request

- **The connection.** A new TLS connection through the same proxy, with the
  ordinary certificate checks against Mozilla's roots, and accepted only if
  the SHA-256 of its certificate key equals the one seen when the report was
  fetched, the key the gateway's quote is tied to. The comparison is made
  after the handshake and before any byte of the request is written.
- **Collateral.** `KeptCollateral` holds Intel's collateral between
  requests. The caller chooses its age, at most a day; it is fetched again
  when older, or when a report names a platform family it does not cover.
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

## What it does not check

- **The GPU.** The NVIDIA evidence in each entry is not checked, so nothing
  here speaks for the GPU that holds the prompt while the model runs. The
  result is named `CpuOnlyProof` for that reason.
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

- `tests/proof.rs`: the proof check against a saved live report.
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
report GET and Intel's collateral GETs, and prints each outcome in plain
words; `--save DIR` keeps what it fetched, as `tests/fixtures` is kept. With
`--key-file` it reads the account key from FILE and makes one chat request
through `ask`, the message "ping", after the proof check. It never prints
the key.

No code is copied from NEAR or from anywhere else. NEAR's MIT-licensed
`inference-sdk` and its model server's source (`inference-proxy`, which
carries no licence file) were read; the SDK's published version 2 vectors
are copied, with its MIT licence, into `tests/fixtures/near-inference-sdk`.
