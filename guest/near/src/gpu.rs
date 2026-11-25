//! The pure GPU half: Intel Trust Authority's signed verdict on the NVIDIA
//! GPUs of one model server, as NEAR's gateway obtains it from Intel
//! (`/v1/attestation/ita-token`), tied to our nonce through Intel's verifier
//! nonce. No network and no clock but `now`.
//!
//! Every link is checked here, from values Intel signs:
//!
//! - Intel signs each token (PS384) with a key its published list holds.
//! - Each token's TDX half is the gateway's quote as Intel appraised it. Its
//!   report data must be SHA-512 of Intel's verifier nonce (`val`, then
//!   `iat`, each base64-decoded once) and the gateway's runtime data: the
//!   compact JSON `{"signing_algo":"ed25519","signing_address":…,
//!   "caller_nonce":…,"tls_cert_fingerprint":…}`, rebuilt here from the
//!   gateway key and TLS key the Intel check established and our nonce. Its
//!   firmware, kernel and compose measurements must be a pinned gateway's.
//! - The model token's GPU half names the same verifier nonce, and every
//!   GPU's evidence nonce must be SHA-256 of it, so the evidence was made
//!   after Intel issued that nonce, which must be no older than five minutes.
//!
//! Intel's client (github.com/intel/trustauthority-client-for-go, `go-tdx`
//! and `go-nvgpu`) derives the report data and the GPU nonce the same way.

use std::collections::BTreeMap;
use std::fmt;

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::signature::{RsaPublicKeyComponents, RSA_PSS_2048_8192_SHA384};
use serde::Deserialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256, Sha512};

use crate::{GpuProof, IntelProof, Pins, Refusal};

/// The issuer of every token Intel Trust Authority signs.
const ISSUER: &str = "https://portal.trustauthority.intel.com";
/// The claims version of the GPU half of Intel's tokens.
const GPU_VERSION: &str = "3.0";
/// How old Intel's verifier nonce, and so the GPU evidence made after it,
/// may be at `now`: five minutes, as long as Intel's tokens live.
const EVIDENCE_AGE: u64 = 300;
/// Claims every GPU must carry as `true`: every boolean `x-nvidia-` claim of
/// Intel's verdicts, which cover NVIDIA's appraisal policy
/// (`NVGPURemotePolicyExample.json` in github.com/NVIDIA/nvtrust), and
/// secure boot. The policy's three certificate claims are, in this version
/// of the claims, the chains in `CHAINS`.
const TRUE: [&str; 17] = [
    "x-nvidia-gpu-arch-check",
    "x-nvidia-gpu-attestation-report-cert-chain-fwid-match",
    "x-nvidia-gpu-attestation-report-parsed",
    "x-nvidia-gpu-attestation-report-nonce-match",
    "x-nvidia-gpu-attestation-report-signature-verified",
    "x-nvidia-gpu-driver-rim-fetched",
    "x-nvidia-gpu-driver-rim-schema-validated",
    "x-nvidia-gpu-driver-rim-signature-verified",
    "x-nvidia-gpu-driver-rim-version-match",
    "x-nvidia-gpu-driver-rim-measurements-available",
    "x-nvidia-gpu-vbios-rim-fetched",
    "x-nvidia-gpu-vbios-rim-schema-validated",
    "x-nvidia-gpu-vbios-rim-signature-verified",
    "x-nvidia-gpu-vbios-rim-version-match",
    "x-nvidia-gpu-vbios-rim-measurements-available",
    "x-nvidia-gpu-vbios-index-no-conflict",
    "secboot",
];
/// Claims every GPU must carry with this text: the measurement result, and
/// debugging off.
const TEXT: [(&str, &str); 2] = [("measres", "success"), ("dbgstat", "disabled")];
/// The certificate chains every GPU's claims describe: its attestation
/// report's, and its driver's and firmware's reference values'. Each must
/// be `valid`, with an OCSP answer that is `good`, valid and for the nonce
/// asked, as Intel's verifier saw it.
const CHAINS: [&str; 3] = [
    "x-nvidia-gpu-attestation-report-cert-chain",
    "x-nvidia-gpu-driver-rim-cert-chain",
    "x-nvidia-gpu-vbios-rim-cert-chain",
];

/// What was wrong with Intel's verdict on the GPUs, or with its tie to our
/// nonce.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GpuRefusal {
    /// NEAR's answer, a token in it or Intel's key list is not in the form
    /// they take.
    Malformed(String),
    /// A token names a signing key Intel's key list does not hold.
    UnknownKey,
    /// A token's signature is not PS384, or does not verify with the key it
    /// names.
    Signature,
    /// A token from an issuer other than Intel Trust Authority.
    Issuer,
    /// A token not valid at `now`: not yet, or no longer.
    Time,
    /// Intel's verifier nonce is from after its token, or older than five
    /// minutes.
    NonceAge,
    /// The gateway's quote, as Intel read it, is not tied to Intel's nonce,
    /// the gateway's key, its TLS key and our nonce.
    ReportData,
    /// The quote Intel appraised does not have a pinned gateway's
    /// measurements.
    NotGateway,
    /// Intel's verdict on the gateway's platform is not `UpToDate`.
    Tcb(String),
    /// Intel says the gateway can be debugged.
    Debug,
    /// The answer does not hold exactly one GPU token, for the model asked.
    Models,
    /// The GPU token carries no GPU.
    NoGpus,
    /// The GPU half names another verifier nonce than the TDX half, or a
    /// GPU's evidence was not made under SHA-256 of it.
    GpuNonce,
    /// The overall verdict on the GPUs is not `true`.
    Verdict,
    /// A GPU's claim is missing or not the value required.
    Claim { gpu: String, claim: &'static str },
}

impl fmt::Display for GpuRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GpuRefusal::Malformed(what) => write!(f, "malformed: {what}"),
            GpuRefusal::UnknownKey => write!(f, "a token names a key Intel does not publish"),
            GpuRefusal::Signature => write!(f, "a token's signature does not verify"),
            GpuRefusal::Issuer => write!(f, "a token comes from an issuer other than Intel"),
            GpuRefusal::Time => write!(f, "a token is not valid now"),
            GpuRefusal::NonceAge => {
                write!(f, "Intel's nonce is from after its token, or too old")
            }
            GpuRefusal::ReportData => write!(
                f,
                "the gateway's quote is not tied to Intel's nonce, its keys and our nonce"
            ),
            GpuRefusal::NotGateway => {
                write!(f, "the quote Intel appraised is not a pinned gateway's")
            }
            GpuRefusal::Tcb(status) => write!(f, "Intel rates the gateway's platform {status}"),
            GpuRefusal::Debug => write!(f, "Intel says the gateway can be debugged"),
            GpuRefusal::Models => write!(f, "not exactly one GPU token, for this model"),
            GpuRefusal::NoGpus => write!(f, "the GPU token carries no GPU"),
            GpuRefusal::GpuNonce => {
                write!(f, "the GPU evidence was not made under Intel's nonce")
            }
            GpuRefusal::Verdict => write!(f, "the overall verdict on the GPUs is not a pass"),
            GpuRefusal::Claim { gpu, claim } => {
                write!(f, "the verdict on {gpu} does not have {claim} as required")
            }
        }
    }
}

/// NEAR's answer from `/v1/attestation/ita-token`. Its other fields,
/// `jwks_url` among them, are not used.
#[derive(Deserialize)]
struct Answer {
    gateway: Signed,
    models: Vec<ModelSigned>,
}

#[derive(Deserialize)]
struct Signed {
    token: String,
}

#[derive(Deserialize)]
struct ModelSigned {
    /// NEAR's label, outside Intel's signature.
    model: String,
    token: String,
}

/// Intel's published key list; each key is read when a token names it.
#[derive(Deserialize)]
struct Keys {
    keys: Vec<Map<String, Value>>,
}

#[derive(Deserialize)]
struct Header {
    alg: String,
    kid: String,
}

/// A token's claims, as far as they are read.
#[derive(Deserialize)]
struct Claims {
    iss: String,
    nbf: u64,
    iat: u64,
    exp: u64,
    tdx: Tdx,
    nvgpu: Option<Nvgpu>,
}

#[derive(Deserialize, PartialEq, Eq)]
struct VerifierNonce {
    val: String,
    iat: String,
    signature: String,
}

/// The TDX half: Intel's appraisal of the gateway's quote.
#[derive(Deserialize)]
struct Tdx {
    attester_tcb_status: String,
    tdx_is_debuggable: bool,
    #[serde(with = "hex")]
    tdx_report_data: Vec<u8>,
    #[serde(with = "hex")]
    tdx_mrtd: Vec<u8>,
    #[serde(with = "hex")]
    tdx_rtmr0: Vec<u8>,
    #[serde(with = "hex")]
    tdx_rtmr1: Vec<u8>,
    #[serde(with = "hex")]
    tdx_rtmr2: Vec<u8>,
    #[serde(with = "hex")]
    tdx_mrconfigid: Vec<u8>,
    verifier_nonce: VerifierNonce,
}

/// The GPU half: Intel's appraisal of one server's GPU evidence.
#[derive(Deserialize)]
struct Nvgpu {
    #[serde(rename = "x-nvidia-ver")]
    version: String,
    #[serde(rename = "x-nvidia-overall-att-result")]
    overall: bool,
    eat_nonce: String,
    verifier_nonce: VerifierNonce,
    claim_details: BTreeMap<String, Map<String, Value>>,
}

/// Checks NEAR's `answer` from Intel Trust Authority, fetched for `model`
/// under the same `nonce` as the report whose Intel check gave `intel`,
/// against Intel's key list `keys` (its JSON as fetched), the gateway sets
/// of `pins` and `now` (seconds since 1970).
pub fn verify_gpu(
    answer: &[u8],
    nonce: &[u8; 32],
    model: &str,
    intel: &IntelProof,
    keys: &[u8],
    pins: &Pins,
    now: u64,
) -> Result<GpuProof, Refusal> {
    check(answer, nonce, model, intel, keys, pins, now)
        .map(|gpus| GpuProof { gpus })
        .map_err(Refusal::Gpu)
}

fn check(
    answer: &[u8],
    nonce: &[u8; 32],
    model: &str,
    intel: &IntelProof,
    keys: &[u8],
    pins: &Pins,
    now: u64,
) -> Result<usize, GpuRefusal> {
    let answer: Answer = serde_json::from_slice(answer)
        .map_err(|e| GpuRefusal::Malformed(format!("NEAR's answer: {e}")))?;
    let keys: Keys = serde_json::from_slice(keys)
        .map_err(|e| GpuRefusal::Malformed(format!("Intel's key list: {e}")))?;
    let runtime = runtime_data(intel, nonce);

    let gateway = token(&answer.gateway.token, &keys, now)?;
    gateway_half(&gateway, &runtime, intel, pins, now)?;

    let [entry] = answer.models.as_slice() else {
        return Err(GpuRefusal::Models);
    };
    if entry.model != model {
        return Err(GpuRefusal::Models);
    }
    let claims = token(&entry.token, &keys, now)?;
    let material = gateway_half(&claims, &runtime, intel, pins, now)?;
    let nvgpu = claims.nvgpu.as_ref().ok_or(GpuRefusal::NoGpus)?;
    gpu_half(nvgpu, &claims.tdx.verifier_nonce, &material)
}

/// Whether the key list `keys` holds every key NEAR's `answer` names, so
/// that a kept list is fetched again once Intel signs with a new key.
pub(crate) fn keys_cover(answer: &[u8], keys: &[u8]) -> bool {
    let (Ok(answer), Ok(keys)) = (
        serde_json::from_slice::<Answer>(answer),
        serde_json::from_slice::<Keys>(keys),
    ) else {
        return false;
    };
    std::iter::once(&answer.gateway.token)
        .chain(answer.models.iter().map(|m| &m.token))
        .filter_map(|token| header(token).ok())
        .all(|header| keys.find(&header.kid).is_some())
}

/// The gateway's runtime data as NEAR builds it for Intel: compact JSON,
/// these fields in this order, every value lower-case hex but the
/// algorithm.
fn runtime_data(intel: &IntelProof, nonce: &[u8; 32]) -> String {
    format!(
        r#"{{"signing_algo":"ed25519","signing_address":"{}","caller_nonce":"{}","tls_cert_fingerprint":"{}"}}"#,
        hex::encode(intel.gateway_key),
        hex::encode(nonce),
        hex::encode(intel.gateway_tls_key)
    )
}

/// A token's TDX half: Intel's nonce in date, the quote's report data tied
/// to it and to `runtime`, a pinned gateway's measurements, `UpToDate` and
/// not debuggable. Answers with the nonce's material, `val` then `iat`.
fn gateway_half(
    claims: &Claims,
    runtime: &str,
    intel: &IntelProof,
    pins: &Pins,
    now: u64,
) -> Result<Vec<u8>, GpuRefusal> {
    let tdx = &claims.tdx;
    let nonce = &tdx.verifier_nonce;
    let malformed = || GpuRefusal::Malformed("Intel's nonce".into());
    let iat = STANDARD.decode(&nonce.iat).map_err(|_| malformed())?;
    let issued = issued(&iat).ok_or_else(malformed)?;
    if issued > claims.iat || now.saturating_sub(issued) >= EVIDENCE_AGE {
        return Err(GpuRefusal::NonceAge);
    }
    let mut material = STANDARD.decode(&nonce.val).map_err(|_| malformed())?;
    material.extend(iat);

    let expected = Sha512::new()
        .chain_update(&material)
        .chain_update(runtime.as_bytes())
        .finalize();
    if tdx.tdx_report_data != expected.as_slice() {
        return Err(GpuRefusal::ReportData);
    }
    if tdx.tdx_mrconfigid != intel.gateway_mrconfigid
        || !pins.gateway.iter().any(|pin| {
            pin.mrtd == tdx.tdx_mrtd
                && pin.rtmr0 == tdx.tdx_rtmr0
                && pin.rtmr1 == tdx.tdx_rtmr1
                && pin.rtmr2 == tdx.tdx_rtmr2
        })
    {
        return Err(GpuRefusal::NotGateway);
    }
    if tdx.attester_tcb_status != "UpToDate" {
        return Err(GpuRefusal::Tcb(tdx.attester_tcb_status.clone()));
    }
    if tdx.tdx_is_debuggable {
        return Err(GpuRefusal::Debug);
    }
    Ok(material)
}

/// The GPU half: the TDX half's verifier nonce, every GPU's evidence under
/// SHA-256 of its `material`, a `true` overall verdict, and every claim
/// required of each GPU. Answers with how many GPUs passed.
fn gpu_half(
    nvgpu: &Nvgpu,
    verifier_nonce: &VerifierNonce,
    material: &[u8],
) -> Result<usize, GpuRefusal> {
    if nvgpu.version != GPU_VERSION {
        return Err(GpuRefusal::Malformed(format!(
            "a GPU claims version other than {GPU_VERSION}"
        )));
    }
    let gpu_nonce: [u8; 32] = Sha256::digest(material).into();
    if nvgpu.verifier_nonce != *verifier_nonce || nonce32(&nvgpu.eat_nonce) != Some(gpu_nonce) {
        return Err(GpuRefusal::GpuNonce);
    }
    if !nvgpu.overall {
        return Err(GpuRefusal::Verdict);
    }
    if nvgpu.claim_details.is_empty() {
        return Err(GpuRefusal::NoGpus);
    }
    for (gpu, claims) in &nvgpu.claim_details {
        let refused = |claim| GpuRefusal::Claim {
            gpu: gpu.clone(),
            claim,
        };
        if claims
            .get("eat_nonce")
            .and_then(Value::as_str)
            .and_then(nonce32)
            != Some(gpu_nonce)
        {
            return Err(GpuRefusal::GpuNonce);
        }
        for claim in TRUE {
            if claims.get(claim) != Some(&Value::Bool(true)) {
                return Err(refused(claim));
            }
        }
        for (claim, text) in TEXT {
            if claims.get(claim).and_then(Value::as_str) != Some(text) {
                return Err(refused(claim));
            }
        }
        for chain in CHAINS {
            let chain_claims = claims.get(chain).and_then(Value::as_object);
            let field = |name| chain_claims.and_then(|c| c.get(name));
            let valid = field("x-nvidia-cert-status").and_then(Value::as_str) == Some("valid")
                && field("x-nvidia-cert-ocsp-status").and_then(Value::as_str) == Some("good")
                && field("x-nvidia-cert-ocsp-response-valid") == Some(&Value::Bool(true))
                && field("x-nvidia-cert-ocsp-nonce-matches") == Some(&Value::Bool(true));
            if !valid {
                return Err(refused(chain));
            }
        }
    }
    Ok(nvgpu.claim_details.len())
}

/// A token's header.
fn header(token: &str) -> Result<Header, GpuRefusal> {
    let encoded = token.split('.').next().unwrap_or_default();
    serde_json::from_slice(&base64url(encoded)?)
        .map_err(|_| GpuRefusal::Malformed("a token's header".into()))
}

/// A token's claims, once its PS384 signature verifies with the Intel key it
/// names, and it is Intel's and valid at `now`.
fn token(token: &str, keys: &Keys, now: u64) -> Result<Claims, GpuRefusal> {
    let malformed = |what: &str| GpuRefusal::Malformed(format!("a token's {what}"));
    let (signed, signature) = token.rsplit_once('.').ok_or_else(|| malformed("form"))?;
    let (_, claims) = signed.split_once('.').ok_or_else(|| malformed("form"))?;
    let header = header(token)?;
    if header.alg != "PS384" {
        return Err(GpuRefusal::Signature);
    }
    let key = keys.find(&header.kid).ok_or(GpuRefusal::UnknownKey)??;
    key.verify(
        &RSA_PSS_2048_8192_SHA384,
        signed.as_bytes(),
        &base64url(signature)?,
    )
    .map_err(|_| GpuRefusal::Signature)?;

    let claims: Claims = serde_json::from_slice(&base64url(claims)?)
        .map_err(|e| GpuRefusal::Malformed(format!("a token's claims: {e}")))?;
    if claims.iss != ISSUER {
        return Err(GpuRefusal::Issuer);
    }
    if claims.nbf > now || claims.iat > now || claims.exp <= now {
        return Err(GpuRefusal::Time);
    }
    Ok(claims)
}

impl Keys {
    /// The PS384 key listed under `kid`; None when there is none, an error
    /// when it is not an RSA key for PS384.
    fn find(&self, kid: &str) -> Option<Result<RsaPublicKeyComponents<Vec<u8>>, GpuRefusal>> {
        let key = self
            .keys
            .iter()
            .find(|key| key.get("kid").and_then(Value::as_str) == Some(kid))?;
        let field = |name| key.get(name).and_then(Value::as_str);
        let component = |name| field(name).and_then(|c| URL_SAFE_NO_PAD.decode(c).ok());
        Some(
            match (field("kty"), field("alg"), component("n"), component("e")) {
                (Some("RSA"), Some("PS384"), Some(n), Some(e)) => {
                    Ok(RsaPublicKeyComponents { n, e })
                }
                _ => Err(GpuRefusal::Malformed(
                    "Intel's key is not an RSA key for PS384".into(),
                )),
            },
        )
    }
}

/// Seconds since 1970 of the time Intel issued its verifier nonce, which
/// Intel writes in Go's form, in UTC: `2026-11-19 23:11:00 +0000 UTC`, with
/// a fraction of a second when there is one, which is dropped.
fn issued(text: &[u8]) -> Option<u64> {
    let text = std::str::from_utf8(text).ok()?.strip_suffix(" +0000 UTC")?;
    let (date, time) = text.split_once(' ')?;
    let (time, fraction) = time.split_once('.').unwrap_or((time, "0"));
    if fraction.is_empty() || !fraction.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let numbers = |text: &str, sep| -> Option<[u64; 3]> {
        let mut parts = text.split(sep).map(|p| {
            p.bytes()
                .all(|b| b.is_ascii_digit())
                .then(|| p.parse().ok())
                .flatten()
        });
        let parsed = [parts.next()??, parts.next()??, parts.next()??];
        parts.next().is_none().then_some(parsed)
    };
    let [year, month, day] = numbers(date, '-')?;
    let [hour, minute, second] = numbers(time, ':')?;
    if year < 1970 || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    // Days since 1970 of a date in the Gregorian calendar, counting years
    // from March so that the leap day ends one.
    let (year, month) = match month {
        1 | 2 => (year - 1, month + 9),
        _ => (year, month - 3),
    };
    let days = 365 * year + year / 4 - year / 100 + year / 400 + (153 * month + 2) / 5 + day - 1;
    let days = days.checked_sub(719_468)?;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn base64url(text: &str) -> Result<Vec<u8>, GpuRefusal> {
    URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| GpuRefusal::Malformed("a token that is not base64url".into()))
}

/// A nonce in hex, 32 bytes; None for anything else.
fn nonce32(text: &str) -> Option<[u8; 32]> {
    let mut nonce = [0u8; 32];
    hex::decode_to_slice(text, &mut nonce).ok()?;
    Some(nonce)
}
