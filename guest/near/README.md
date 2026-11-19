# cloak-near

Slice 1 of Cloak's NEAR mode: the check of NEAR AI Cloud's hardware proof,
made before anything is sent. It holds no account and no key, sends no chat
request, and is not yet part of the guest image, the build scripts or the app.

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
- **Replies.** Response signatures come after a reply and are not part of
  this check.
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
    cargo test --locked            # the gate check, offline: tests/proof.rs
    cargo run --locked --bin cloak-near-probe -- --socks 127.0.0.1:9050 --model z-ai/glm-5.3-flash

The probe is for development: it makes only the report GET and Intel's
collateral GETs, and prints each outcome in plain words. `--save DIR` keeps
what it fetched, as `tests/fixtures` is kept.

NEAR's MIT-licensed `inference-sdk` was read for ideas; no code is copied
from it or from anywhere else.
