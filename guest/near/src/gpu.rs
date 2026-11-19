//! The pure GPU half: each model instance's NVIDIA evidence, gathered under
//! our nonce, and NVIDIA's signed verdict on it from its attestation service
//! (NRAS, version 3). The overall token is checked as NEAR's MIT-licensed
//! SDK checks it (`rs/src/nvidia.rs` in github.com/nearai/inference-sdk);
//! every GPU's own token is checked the same way, and against the claims of
//! NVIDIA's appraisal policy for version 3 (`NVGPURemotePolicyExample.json`
//! in github.com/NVIDIA/nvtrust). No network and no clock but `now`.

use std::fmt;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ring::signature::{UnparsedPublicKey, ECDSA_P384_SHA384_FIXED};
use serde::Deserialize;
use serde_json::{Map, Value};

use crate::{GpuProof, Refusal, Who};

/// The issuer of every token NVIDIA's service signs.
const ISSUER: &str = "https://nras.attestation.nvidia.com";
/// The claims version of NRAS version 3's overall token.
const VERSION: &str = "2.0";
/// Claims every GPU's token must carry as `true`: those of NVIDIA's policy,
/// and secure boot.
const TRUE: [&str; 17] = [
    "x-nvidia-gpu-arch-check",
    "x-nvidia-gpu-attestation-report-cert-chain-validated",
    "x-nvidia-gpu-attestation-report-parsed",
    "x-nvidia-gpu-attestation-report-nonce-match",
    "x-nvidia-gpu-attestation-report-signature-verified",
    "x-nvidia-gpu-driver-rim-fetched",
    "x-nvidia-gpu-driver-rim-schema-validated",
    "x-nvidia-gpu-driver-rim-cert-validated",
    "x-nvidia-gpu-driver-rim-signature-verified",
    "x-nvidia-gpu-driver-rim-measurements-available",
    "x-nvidia-gpu-vbios-rim-fetched",
    "x-nvidia-gpu-vbios-rim-schema-validated",
    "x-nvidia-gpu-vbios-rim-cert-validated",
    "x-nvidia-gpu-vbios-rim-signature-verified",
    "x-nvidia-gpu-vbios-rim-measurements-available",
    "x-nvidia-gpu-vbios-index-no-conflict",
    "secboot",
];
/// Claims every GPU's token must carry with this text: NVIDIA's policy's
/// measurement result, and debugging off.
const TEXT: [(&str, &str); 2] = [("measres", "success"), ("dbgstat", "disabled")];

/// What was wrong with one instance's GPU evidence or NVIDIA's verdict on
/// it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GpuRefusal {
    /// `nvidia_payload` is missing, or not a JSON object with a nonce and a
    /// list of evidence.
    NoEvidence,
    /// The evidence was gathered under a nonce that is not ours.
    EvidenceNonce,
    /// NVIDIA's answer, or a token in it, is not in the form NVIDIA's
    /// service gives.
    Malformed(String),
    /// A token names a signing key NVIDIA's key list does not hold.
    UnknownKey,
    /// A token's signature is not ES384, or does not verify with the key it
    /// names.
    Signature,
    /// A token from an issuer other than NVIDIA's service.
    Issuer,
    /// A token not valid at `now`: not yet, or no longer.
    Time,
    /// A token for a nonce that is not ours.
    TokenNonce,
    /// NVIDIA's overall verdict is not `true`.
    Verdict,
    /// Not one token for each GPU the evidence holds.
    GpuCount,
    /// A GPU's claim is missing or not the value required.
    Claim { gpu: String, claim: &'static str },
}

impl fmt::Display for GpuRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GpuRefusal::NoEvidence => write!(f, "it carries no GPU evidence"),
            GpuRefusal::EvidenceNonce => {
                write!(
                    f,
                    "its GPU evidence was gathered under a nonce that is not ours"
                )
            }
            GpuRefusal::Malformed(what) => write!(f, "NVIDIA's answer is malformed: {what}"),
            GpuRefusal::UnknownKey => {
                write!(f, "NVIDIA's token names a key NVIDIA does not publish")
            }
            GpuRefusal::Signature => write!(f, "NVIDIA's token signature does not verify"),
            GpuRefusal::Issuer => write!(
                f,
                "a token comes from an issuer other than NVIDIA's service"
            ),
            GpuRefusal::Time => write!(f, "NVIDIA's token is not valid now"),
            GpuRefusal::TokenNonce => write!(f, "NVIDIA's token is for a nonce that is not ours"),
            GpuRefusal::Verdict => write!(f, "NVIDIA's overall verdict is not a pass"),
            GpuRefusal::GpuCount => write!(f, "NVIDIA did not give one verdict for each GPU"),
            GpuRefusal::Claim { gpu, claim } => {
                write!(
                    f,
                    "NVIDIA's verdict on {gpu} does not have {claim} as required"
                )
            }
        }
    }
}

/// One instance's GPU evidence as NEAR's report carries it, gathered under
/// our nonce. Only [`gpu_evidence`] makes one, so only evidence whose nonce
/// was checked can be posted to NVIDIA.
#[derive(Clone, Debug)]
pub struct GpuEvidence {
    /// The JSON text of `nvidia_payload`, posted to NVIDIA unchanged.
    pub(crate) payload: String,
    /// How many GPUs it holds evidence for.
    pub gpus: usize,
}

#[derive(Deserialize)]
struct Report {
    model_attestations: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    nvidia_payload: Option<String>,
}

#[derive(Deserialize)]
struct Payload {
    nonce: String,
    evidence_list: Vec<Value>,
}

/// NVIDIA's published key list; each key is read when a token names it.
#[derive(Deserialize)]
struct Keys {
    keys: Vec<Map<String, Value>>,
}

#[derive(Deserialize)]
struct Header {
    alg: String,
    kid: String,
}

/// Every model entry's GPU evidence, in the report's order, each checked to
/// carry our nonce before anything is posted.
pub fn gpu_evidence(report: &[u8], nonce: &[u8; 32]) -> Result<Vec<GpuEvidence>, Refusal> {
    let report: Report =
        serde_json::from_slice(report).map_err(|e| Refusal::Malformed(e.to_string()))?;
    if report.model_attestations.is_empty() {
        return Err(Refusal::NoModels);
    }
    report
        .model_attestations
        .into_iter()
        .enumerate()
        .map(|(index, entry)| {
            let refused = |refusal| Refusal::Gpu {
                who: Who::Model(index),
                refusal,
            };
            let payload = entry
                .nvidia_payload
                .ok_or(refused(GpuRefusal::NoEvidence))?;
            let parsed: Payload =
                serde_json::from_str(&payload).map_err(|_| refused(GpuRefusal::NoEvidence))?;
            if parsed.evidence_list.is_empty() {
                return Err(refused(GpuRefusal::NoEvidence));
            }
            if nonce32(&parsed.nonce) != Some(*nonce) {
                return Err(refused(GpuRefusal::EvidenceNonce));
            }
            Ok(GpuEvidence {
                payload,
                gpus: parsed.evidence_list.len(),
            })
        })
        .collect()
}

/// Checks NVIDIA's `answers`, one for each model entry of `report` in its
/// order, against the report's evidence, `nonce`, NVIDIA's key list `keys`
/// (its JSON as fetched) and `now` (seconds since 1970).
pub fn verify_gpu(
    report: &[u8],
    nonce: &[u8; 32],
    answers: &[Vec<u8>],
    keys: &[u8],
    now: u64,
) -> Result<GpuProof, Refusal> {
    let evidence = gpu_evidence(report, nonce)?;
    if answers.len() != evidence.len() {
        return Err(Refusal::Malformed(format!(
            "{} NVIDIA answers for {} model instances",
            answers.len(),
            evidence.len()
        )));
    }
    let keys: Keys = serde_json::from_slice(keys)
        .map_err(|e| Refusal::Malformed(format!("NVIDIA's key list: {e}")))?;
    let gpus = evidence
        .iter()
        .zip(answers)
        .enumerate()
        .map(|(index, (evidence, answer))| {
            appraise(answer, evidence.gpus, nonce, &keys, now).map_err(|refusal| Refusal::Gpu {
                who: Who::Model(index),
                refusal,
            })
        })
        .collect::<Result<_, _>>()?;
    Ok(GpuProof { gpus })
}

/// Whether the key list `keys` holds every key NVIDIA's `answers` name, so
/// that a kept list is fetched again once NVIDIA signs with a new key.
pub(crate) fn keys_cover(answers: &[Vec<u8>], keys: &[u8]) -> bool {
    let Ok(keys) = serde_json::from_slice::<Keys>(keys) else {
        return false;
    };
    answers
        .iter()
        .filter_map(|answer| tokens(answer).ok())
        .flat_map(|(overall, gpus)| {
            std::iter::once(overall).chain(gpus.into_iter().map(|(_, t)| t))
        })
        .filter_map(|token| header(&token).ok())
        .all(|header| keys.find(&header.kid).is_some())
}

/// One instance's verdict: the overall token passes, with its claims
/// version and a `true` overall result, and so does one token for each GPU,
/// with every claim required.
fn appraise(
    answer: &[u8],
    gpus: usize,
    nonce: &[u8; 32],
    keys: &Keys,
    now: u64,
) -> Result<usize, GpuRefusal> {
    let (overall, detached) = tokens(answer)?;
    let claims = token(&overall, nonce, keys, now)?;
    if claims.get("x-nvidia-ver").and_then(Value::as_str) != Some(VERSION) {
        return Err(GpuRefusal::Malformed(format!(
            "a claims version other than {VERSION}"
        )));
    }
    if claims.get("x-nvidia-overall-att-result") != Some(&Value::Bool(true)) {
        return Err(GpuRefusal::Verdict);
    }
    if detached.len() != gpus {
        return Err(GpuRefusal::GpuCount);
    }
    for (gpu, detached) in detached {
        let claims = token(&detached, nonce, keys, now)?;
        let refused = |claim| GpuRefusal::Claim {
            gpu: gpu.clone(),
            claim,
        };
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
    }
    Ok(gpus)
}

/// NVIDIA's answer, `[["JWT", overall token], {GPU name: its token}]`: the
/// overall token and each GPU's. As in NEAR's SDK, anything after the
/// overall token in the first entry, or after the second entry, is not used.
fn tokens(answer: &[u8]) -> Result<(String, Vec<(String, String)>), GpuRefusal> {
    let malformed = || GpuRefusal::Malformed("not NVIDIA's list of tokens".into());
    let answer: Vec<Value> = serde_json::from_slice(answer).map_err(|_| malformed())?;
    let overall = match answer.first().and_then(Value::as_array).map(Vec::as_slice) {
        Some([kind, token, ..]) if kind == "JWT" => token.as_str().ok_or_else(malformed)?,
        _ => return Err(malformed()),
    };
    let gpus = answer
        .get(1)
        .and_then(Value::as_object)
        .ok_or_else(malformed)?
        .iter()
        .map(|(gpu, token)| {
            Ok((
                gpu.clone(),
                token.as_str().ok_or_else(malformed)?.to_owned(),
            ))
        })
        .collect::<Result<_, _>>()?;
    Ok((overall.to_owned(), gpus))
}

/// A token's header.
fn header(token: &str) -> Result<Header, GpuRefusal> {
    let encoded = token.split('.').next().unwrap_or_default();
    serde_json::from_slice(&base64url(encoded)?)
        .map_err(|_| GpuRefusal::Malformed("a token's header".into()))
}

/// A token's claims, once its ES384 signature verifies with the NVIDIA key
/// it names and it is NVIDIA's, valid at `now` and for `nonce`.
fn token(
    token: &str,
    nonce: &[u8; 32],
    keys: &Keys,
    now: u64,
) -> Result<Map<String, Value>, GpuRefusal> {
    let malformed = |what: &str| GpuRefusal::Malformed(format!("a token's {what}"));
    let (signed, signature) = token.rsplit_once('.').ok_or_else(|| malformed("form"))?;
    let (_, claims) = signed.split_once('.').ok_or_else(|| malformed("form"))?;
    let header = header(token)?;
    if header.alg != "ES384" {
        return Err(GpuRefusal::Signature);
    }
    let key = keys.find(&header.kid).ok_or(GpuRefusal::UnknownKey)??;
    UnparsedPublicKey::new(&ECDSA_P384_SHA384_FIXED, key)
        .verify(signed.as_bytes(), &base64url(signature)?)
        .map_err(|_| GpuRefusal::Signature)?;

    let claims: Map<String, Value> =
        serde_json::from_slice(&base64url(claims)?).map_err(|_| malformed("claims"))?;
    if claims.get("iss").and_then(Value::as_str) != Some(ISSUER) {
        return Err(GpuRefusal::Issuer);
    }
    let time = |name| {
        claims
            .get(name)
            .and_then(Value::as_u64)
            .ok_or_else(|| malformed(name))
    };
    let (not_before, issued, expires) = (time("nbf")?, time("iat")?, time("exp")?);
    if not_before > now || issued > now || expires <= now {
        return Err(GpuRefusal::Time);
    }
    let eat_nonce = claims
        .get("eat_nonce")
        .and_then(Value::as_str)
        .ok_or_else(|| malformed("eat_nonce"))?;
    if nonce32(eat_nonce) != Some(*nonce) {
        return Err(GpuRefusal::TokenNonce);
    }
    Ok(claims)
}

impl Keys {
    /// The key listed under `kid`, as the uncompressed P-384 point ring
    /// takes; None when there is none, an error when it is not a P-384 key.
    fn find(&self, kid: &str) -> Option<Result<Vec<u8>, GpuRefusal>> {
        let key = self
            .keys
            .iter()
            .find(|key| key.get("kid").and_then(Value::as_str) == Some(kid))?;
        let field = |name| key.get(name).and_then(Value::as_str);
        let not_p384 = || GpuRefusal::Malformed("NVIDIA's key is not a P-384 key".into());
        if field("kty") != Some("EC") || field("crv") != Some("P-384") {
            return Some(Err(not_p384()));
        }
        let mut point = vec![4];
        for name in ["x", "y"] {
            match field(name).map(|c| URL_SAFE_NO_PAD.decode(c)) {
                Some(Ok(coordinate)) if coordinate.len() == 48 => point.extend(coordinate),
                _ => return Some(Err(not_p384())),
            }
        }
        Some(Ok(point))
    }
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
