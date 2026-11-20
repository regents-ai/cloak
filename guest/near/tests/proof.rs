//! The gate check of the NEAR proof checker, offline, all public data.
//!
//! Intel's side: a real report for z-ai/glm-5.3-flash (the gateway and three
//! instances), fetched with no account key through Tor on 19 November 2026,
//! with its nonce, the gateway TLS key hash seen on that connection and
//! Intel's collateral, kept in tests/fixtures, checked against
//! reference/near-pins.json.
//!
//! The GPU side: one consistent set fetched together, with no account key,
//! through Tor on 19 November 2026 by the probe's `--save`, kept in
//! tests/fixtures/ita: a real report for Qwen/Qwen3.8-27B (one instance),
//! its nonce, gateway TLS key hash and Intel collateral, NEAR's answer of
//! Intel Trust Authority's tokens under the same nonce (the gateway's, and
//! one on eight GPUs) and Intel's published key list. Its Intel side is
//! checked first, as `ask` does. Changes that Intel's signature would forbid
//! are made by signing the changed token again with a test key
//! (tests/fixtures/ita/test-key.der, made for these checks alone), added to
//! the key list under the id `cloak-test`; the real tokens signed again
//! unchanged that way pass, so each refusal comes from its change.
//!
//! Each real set passes at its fetch time and is refused for each change
//! below.
//!
//! A passed proof is used again for at most an hour: a longer proof age is
//! refused. (Which kept proof `ask` uses is checked in src/chat.rs, where
//! it can be put in `Kept` by hand.)
//!
//!     cargo test --locked --manifest-path guest/near/Cargo.toml

use std::time::Duration;

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use cloak_near::{
    verify_gpu, verify_intel, Collateral, GpuProof, GpuRefusal, IntelProof, Kept, Pins, Refusal,
    TcbStatus, Who,
};
use ring::rand::SystemRandom;
use ring::signature::{RsaKeyPair, RsaPublicKeyComponents, RSA_PSS_SHA384};
use serde_json::{json, Value};

const DAY: u64 = 24 * 60 * 60;
const TEST_KID: &str = "cloak-test";

fn hex32(text: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    hex::decode_to_slice(text.trim(), &mut out).unwrap();
    out
}

struct Case {
    report: Vec<u8>,
    nonce: [u8; 32],
    spki: [u8; 32],
    model: String,
    collateral: Vec<Collateral>,
    pins: Pins,
    now: u64,
}

impl Case {
    fn real() -> Case {
        Case {
            report: include_bytes!("fixtures/report.json").to_vec(),
            nonce: hex32(include_str!("fixtures/nonce.hex")),
            spki: hex32(include_str!("fixtures/spki.hex")),
            model: include_str!("fixtures/model.txt").trim().to_owned(),
            collateral: serde_json::from_str(include_str!("fixtures/collateral.json")).unwrap(),
            pins: serde_json::from_str(include_str!("../../../reference/near-pins.json")).unwrap(),
            now: include_str!("fixtures/fetched-at.txt")
                .trim()
                .parse()
                .unwrap(),
        }
    }

    /// The report of the GPU side's set.
    fn ita() -> Case {
        Case {
            report: include_bytes!("fixtures/ita/report.json").to_vec(),
            nonce: hex32(include_str!("fixtures/ita/nonce.hex")),
            spki: hex32(include_str!("fixtures/ita/spki.hex")),
            model: include_str!("fixtures/ita/model.txt").trim().to_owned(),
            collateral: serde_json::from_str(include_str!("fixtures/ita/collateral.json")).unwrap(),
            pins: serde_json::from_str(include_str!("../../../reference/near-pins.json")).unwrap(),
            now: include_str!("fixtures/ita/fetched-at.txt")
                .trim()
                .parse()
                .unwrap(),
        }
    }

    fn check(&self) -> Result<IntelProof, Refusal> {
        verify_intel(
            &self.report,
            &self.nonce,
            &self.spki,
            &self.model,
            &self.collateral,
            &self.pins,
            self.now,
        )
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.report).unwrap()
    }

    /// The same case with the report changed by `change`.
    fn edited(mut self, change: impl FnOnce(&mut Value)) -> Case {
        let mut report = self.json();
        change(&mut report);
        self.report = serde_json::to_vec(&report).unwrap();
        self
    }
}

fn refusal(case: Case) -> Refusal {
    case.check()
        .expect_err("the changed report must be refused")
}

#[test]
fn the_real_report_passes_at_its_fetch_time() {
    let case = Case::real();
    let report = case.json();
    let entries = report["model_attestations"].as_array().unwrap();
    let proof = case.check().unwrap();

    assert_eq!(proof.instances, entries.len());
    assert_eq!(proof.instances, 3);
    assert_eq!(
        hex::encode(proof.gateway_key),
        report["gateway_attestation"]["signing_address"]
    );
    for entry in entries {
        assert_eq!(hex::encode(proof.model_key), entry["signing_public_key"]);
    }
    assert_eq!(proof.gateway_tcb, TcbStatus::UpToDate);
    assert_eq!(proof.model_tcb, vec![TcbStatus::UpToDate; 3]);
}

#[test]
fn another_nonce_is_refused() {
    let mut case = Case::real();
    case.nonce[0] ^= 1;
    assert_eq!(refusal(case), Refusal::NonceEcho(Who::Gateway));
}

#[test]
fn another_tls_key_is_refused() {
    let mut case = Case::real();
    case.spki[31] ^= 1;
    assert_eq!(refusal(case), Refusal::TlsKey);
}

#[test]
fn a_changed_pin_is_refused() {
    let mut case = Case::real();
    case.pins.gateway[0].rtmr1[0] ^= 1;
    assert!(matches!(
        refusal(case),
        Refusal::Pin {
            who: Who::Gateway,
            ..
        }
    ));

    // The third instance runs the third accepted image.
    let mut case = Case::real();
    case.pins.model[2].mrconfigid[1] ^= 1;
    assert!(matches!(
        refusal(case),
        Refusal::Pin {
            who: Who::Model(2),
            ..
        }
    ));
}

#[test]
fn a_swapped_model_key_is_refused() {
    let case = Case::real();
    let other = case.json()["gateway_attestation"]["signing_address"].clone();

    // An encryption key other than the one the quote binds.
    let swapped = other.clone();
    let case = case.edited(|r| r["model_attestations"][1]["signing_public_key"] = swapped);
    assert_eq!(refusal(case), Refusal::KeyNotBound(Who::Model(1)));

    // Every entry's key changed under both names, as a relay swapping the
    // key would: each quote still binds the real one.
    let case = Case::real().edited(|r| {
        for entry in r["model_attestations"].as_array_mut().unwrap() {
            entry["signing_public_key"] = other.clone();
            entry["signing_address"] = other.clone();
        }
    });
    assert_eq!(refusal(case), Refusal::ReportData(Who::Model(0)));
}

#[test]
fn another_model_name_is_refused() {
    let mut case = Case::real();
    case.model = "Qwen/Qwen3.8-27B".to_owned();
    assert!(matches!(
        refusal(case),
        Refusal::ModelName {
            who: Who::Model(0),
            ..
        }
    ));
}

#[test]
fn an_empty_model_list_is_refused() {
    let case = Case::real().edited(|r| r["model_attestations"] = json!([]));
    assert_eq!(refusal(case), Refusal::NoModels);
}

#[test]
fn expired_collateral_is_refused() {
    let mut case = Case::real();
    case.now += 31 * DAY;
    assert!(matches!(
        refusal(case),
        Refusal::Intel {
            who: Who::Gateway,
            ..
        }
    ));
}

/// Where the gateway's token, and the one on the GPUs, sit in NEAR's answer.
const GATEWAY: &str = "/gateway/token";
const GPUS: &str = "/models/0/token";

struct GpuCase {
    /// The report side, checked unchanged before every GPU check.
    case: Case,
    /// What the GPU check is given; the real values until a check changes
    /// them.
    nonce: [u8; 32],
    pins: Pins,
    now: u64,
    /// NEAR's answer of Intel's tokens.
    answer: Value,
    /// Intel's key list, as it came until the test key is added.
    keys: Value,
    test_key: RsaKeyPair,
}

impl GpuCase {
    fn real() -> GpuCase {
        let case = Case::ita();
        GpuCase {
            nonce: case.nonce,
            pins: case.pins.clone(),
            now: case.now,
            case,
            answer: serde_json::from_str(include_str!("fixtures/ita/ita.json")).unwrap(),
            keys: serde_json::from_str(include_str!("fixtures/ita/ita-keys.json")).unwrap(),
            test_key: RsaKeyPair::from_der(include_bytes!("fixtures/ita/test-key.der")).unwrap(),
        }
    }

    fn check(&self) -> Result<GpuProof, Refusal> {
        let intel: IntelProof = self.case.check().expect("the report side passes");
        verify_gpu(
            &serde_json::to_vec(&self.answer).unwrap(),
            &self.nonce,
            &self.case.model,
            &intel,
            &serde_json::to_vec(&self.keys).unwrap(),
            &self.pins,
            self.now,
        )
    }

    fn token(&self, at: &str) -> String {
        self.answer
            .pointer(at)
            .unwrap()
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn replace(&mut self, at: &str, token: String) {
        *self.answer.pointer_mut(at).unwrap() = Value::String(token);
    }

    /// Signs the token at `at` again with the test key, its claims changed
    /// by `change`, and adds the test key to the key list.
    fn resign(&mut self, at: &str, change: impl FnOnce(&mut Value)) {
        let mut claims = claims(&self.token(at));
        change(&mut claims);
        let header = json!({"alg": "PS384", "kid": TEST_KID, "typ": "JWT"});
        let signed = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header.to_string()),
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap())
        );
        let mut signature = vec![0; self.test_key.public().modulus_len()];
        self.test_key
            .sign(
                &RSA_PSS_SHA384,
                &SystemRandom::new(),
                signed.as_bytes(),
                &mut signature,
            )
            .unwrap();
        self.replace(
            at,
            format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature)),
        );

        let list = self.keys["keys"].as_array_mut().unwrap();
        if !list.iter().any(|k| k["kid"] == TEST_KID) {
            let public = RsaPublicKeyComponents::<Vec<u8>>::from(self.test_key.public());
            list.push(json!({
                "kty": "RSA",
                "alg": "PS384",
                "use": "sig",
                "kid": TEST_KID,
                "n": URL_SAFE_NO_PAD.encode(&public.n),
                "e": URL_SAFE_NO_PAD.encode(&public.e),
            }));
        }
    }
}

/// A token's claims, read without checking anything.
fn claims(token: &str) -> Value {
    let body = token.split('.').nth(1).unwrap();
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(body).unwrap()).unwrap()
}

/// `case`'s GPU refusal.
fn gpu_refusal(case: GpuCase) -> GpuRefusal {
    match case.check() {
        Err(Refusal::Gpu(refusal)) => refusal,
        other => panic!("expected a GPU refusal, got {other:?}"),
    }
}

/// The claims of one GPU in the token on the GPUs.
fn gpu<'a>(claims: &'a mut Value, name: &str) -> &'a mut Value {
    &mut claims["nvgpu"]["claim_details"][name]
}

#[test]
fn the_real_gpu_verdict_passes_at_its_fetch_time() {
    let case = GpuCase::real();
    let report: Value = serde_json::from_slice(&case.case.report).unwrap();
    assert_eq!(report["model_attestations"].as_array().unwrap().len(), 1);
    assert_eq!(case.answer["models"].as_array().unwrap().len(), 1);
    assert_eq!(case.check().unwrap().gpus, 8);

    // Signed again with the test key, unchanged, they pass too.
    let mut case = GpuCase::real();
    case.resign(GATEWAY, |_| {});
    case.resign(GPUS, |_| {});
    assert_eq!(case.check().unwrap().gpus, 8);
}

#[test]
fn a_gpu_verdict_for_another_nonce_is_refused() {
    let mut case = GpuCase::real();
    case.nonce[0] ^= 1;
    assert_eq!(gpu_refusal(case), GpuRefusal::ReportData);
}

#[test]
fn a_changed_signature_or_an_unlisted_key_is_refused() {
    for at in [GATEWAY, GPUS] {
        let mut case = GpuCase::real();
        let token = case.token(at);
        let (signed, signature) = token.rsplit_once('.').unwrap();
        let mut signature = URL_SAFE_NO_PAD.decode(signature).unwrap();
        signature[10] ^= 1;
        case.replace(
            at,
            format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature)),
        );
        assert_eq!(gpu_refusal(case), GpuRefusal::Signature, "{at}");
    }

    // Signed by a key Intel does not list.
    let mut case = GpuCase::real();
    let keys = case.keys.clone();
    case.resign(GPUS, |_| {});
    case.keys = keys;
    assert_eq!(gpu_refusal(case), GpuRefusal::UnknownKey);
}

#[test]
fn a_failed_gpu_claim_or_verdict_is_refused() {
    let mut case = GpuCase::real();
    case.resign(GPUS, |c| gpu(c, "GPU-3")["measres"] = json!("fail"));
    assert_eq!(
        gpu_refusal(case),
        GpuRefusal::Claim {
            gpu: "GPU-3".into(),
            claim: "measres"
        }
    );

    let mut case = GpuCase::real();
    case.resign(GPUS, |c| {
        gpu(c, "GPU-5")["x-nvidia-gpu-driver-rim-cert-chain"]["x-nvidia-cert-ocsp-status"] =
            json!("revoked")
    });
    assert_eq!(
        gpu_refusal(case),
        GpuRefusal::Claim {
            gpu: "GPU-5".into(),
            claim: "x-nvidia-gpu-driver-rim-cert-chain"
        }
    );

    let mut case = GpuCase::real();
    case.resign(GPUS, |c| {
        c["nvgpu"]["x-nvidia-overall-att-result"] = json!(false);
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::Verdict);
}

#[test]
fn a_missing_gpu_token_is_refused() {
    let mut case = GpuCase::real();
    case.answer["models"] = json!([]);
    assert_eq!(gpu_refusal(case), GpuRefusal::Models);

    // A token on the GPUs without its GPU half, and with no GPU in it.
    let mut case = GpuCase::real();
    case.resign(GPUS, |c| {
        c.as_object_mut().unwrap().remove("nvgpu");
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::NoGpus);

    let mut case = GpuCase::real();
    case.resign(GPUS, |c| c["nvgpu"]["claim_details"] = json!({}));
    assert_eq!(gpu_refusal(case), GpuRefusal::NoGpus);
}

#[test]
fn gpu_evidence_not_under_intels_nonce_is_refused() {
    let mut case = GpuCase::real();
    case.resign(GPUS, |c| {
        gpu(c, "GPU-1")["eat_nonce"] = json!("11".repeat(32))
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::GpuNonce);

    // The GPU half naming another of Intel's nonces than the TDX half.
    let mut case = GpuCase::real();
    case.resign(GPUS, |c| {
        c["nvgpu"]["verifier_nonce"]["val"] = json!(STANDARD.encode("another nonce"));
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::GpuNonce);
}

#[test]
fn an_old_intel_nonce_or_an_unpinned_gateway_is_refused() {
    let mut case = GpuCase::real();
    case.resign(GATEWAY, |c| {
        c["tdx"]["verifier_nonce"]["iat"] = json!(STANDARD.encode("2026-11-19 23:10:00 +0000 UTC"));
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::NonceAge);

    let mut case = GpuCase::real();
    for pin in &mut case.pins.gateway {
        pin.mrconfigid[1] ^= 1;
    }
    assert_eq!(gpu_refusal(case), GpuRefusal::NotGateway);
}

#[test]
fn an_expired_token_is_refused() {
    let mut case = GpuCase::real();
    let expires = claims(&case.token(GPUS))["exp"].as_u64().unwrap();
    case.now = expires - 1;
    assert!(case.check().is_ok());
    case.now = expires;
    assert_eq!(gpu_refusal(case), GpuRefusal::Time);
}

#[test]
fn a_proof_age_over_an_hour_is_refused() {
    let day = Duration::from_secs(DAY);
    assert!(Kept::new(day, Duration::from_secs(60 * 60)).is_some());
    assert!(Kept::new(day, Duration::from_secs(60 * 60 + 1)).is_none());
}
