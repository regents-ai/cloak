//! The gate check of the NEAR proof checker, offline, all public data.
//!
//! Intel's side: a real report for z-ai/glm-5.3-flash (the gateway and three
//! instances), fetched with no account key through Tor on 19 November 2026,
//! with its nonce, the gateway TLS key hash seen on that connection and
//! Intel's collateral, kept in tests/fixtures, checked against
//! reference/near-pins.json.
//!
//! NVIDIA's side: a real report for Qwen/Qwen3.8-27B (one instance, eight
//! GPUs), fetched with no account key through Tor on 19 November 2026, with
//! its nonce, NVIDIA's answer to that instance's GPU evidence (fetched
//! through Tor with no key) and NVIDIA's published key list, kept in
//! tests/fixtures/nvidia. Changes that NVIDIA's signature would forbid are
//! made by signing the changed token again with a key made for each run
//! alone, added to the key list under the id `cloak-test`; the real tokens
//! signed again unchanged that way pass, so each refusal comes from its
//! change.
//!
//! Each real set passes at its fetch time and is refused for each change
//! below.
//!
//!     cargo test --locked --manifest-path guest/near/Cargo.toml

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use cloak_near::{
    gpu_evidence, verify_gpu, verify_intel, Collateral, GpuProof, GpuRefusal, IntelProof, Pins,
    Refusal, TcbStatus, Who,
};
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P384_SHA384_FIXED_SIGNING};
use serde_json::value::RawValue;
use serde_json::{json, Map, Value};

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

struct GpuCase {
    report: Vec<u8>,
    nonce: [u8; 32],
    /// NVIDIA's answer for each model entry, as it came.
    answers: Vec<Vec<u8>>,
    /// NVIDIA's key list, as it came until the test key is added.
    keys: Vec<u8>,
    now: u64,
    test_key: EcdsaKeyPair,
}

impl GpuCase {
    fn real() -> GpuCase {
        let answers: Vec<Box<RawValue>> =
            serde_json::from_str(include_str!("fixtures/nvidia/nvidia.json")).unwrap();
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P384_SHA384_FIXED_SIGNING, &rng).unwrap();
        GpuCase {
            report: include_bytes!("fixtures/nvidia/report.json").to_vec(),
            nonce: hex32(include_str!("fixtures/nvidia/nonce.hex")),
            answers: answers
                .iter()
                .map(|a| a.get().as_bytes().to_vec())
                .collect(),
            keys: include_bytes!("fixtures/nvidia/nvidia-keys.json").to_vec(),
            now: include_str!("fixtures/nvidia/fetched-at.txt")
                .trim()
                .parse()
                .unwrap(),
            test_key: EcdsaKeyPair::from_pkcs8(
                &ECDSA_P384_SHA384_FIXED_SIGNING,
                pkcs8.as_ref(),
                &rng,
            )
            .unwrap(),
        }
    }

    fn check(&self) -> Result<GpuProof, Refusal> {
        verify_gpu(
            &self.report,
            &self.nonce,
            &self.answers,
            &self.keys,
            self.now,
        )
    }

    fn answer(&self, instance: usize) -> Value {
        serde_json::from_slice(&self.answers[instance]).unwrap()
    }

    /// The first instance's overall token, or the token of `gpu`.
    fn token(&self, gpu: Option<&str>) -> String {
        let answer = self.answer(0);
        let token = match gpu {
            None => &answer[0][1],
            Some(gpu) => &answer[1][gpu],
        };
        token.as_str().unwrap().to_owned()
    }

    /// Puts `token` in place of the first instance's overall token, or of
    /// `gpu`'s.
    fn replace(&mut self, gpu: Option<&str>, token: String) {
        let mut answer = self.answer(0);
        match gpu {
            None => answer[0][1] = Value::String(token),
            Some(gpu) => answer[1][gpu] = Value::String(token),
        }
        self.answers[0] = serde_json::to_vec(&answer).unwrap();
    }

    /// Signs the first instance's overall token, or `gpu`'s, again with the
    /// test key, its claims changed by `change`, and adds the test key to
    /// the key list.
    fn resign(&mut self, gpu: Option<&str>, change: impl FnOnce(&mut Map<String, Value>)) {
        let token = self.token(gpu);
        let mut claims = claims(&token);
        change(&mut claims);
        let header = URL_SAFE_NO_PAD.encode(json!({"kid": TEST_KID, "alg": "ES384"}).to_string());
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        let signed = format!("{header}.{body}");
        let signature = self
            .test_key
            .sign(&SystemRandom::new(), signed.as_bytes())
            .unwrap();
        self.replace(
            gpu,
            format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref())),
        );

        let mut keys: Value = serde_json::from_slice(&self.keys).unwrap();
        let list = keys["keys"].as_array_mut().unwrap();
        if !list.iter().any(|k| k["kid"] == TEST_KID) {
            let point = self.test_key.public_key().as_ref();
            list.push(json!({
                "kty": "EC",
                "crv": "P-384",
                "kid": TEST_KID,
                "x": URL_SAFE_NO_PAD.encode(&point[1..49]),
                "y": URL_SAFE_NO_PAD.encode(&point[49..]),
            }));
        }
        self.keys = serde_json::to_vec(&keys).unwrap();
    }

    /// The same case with the report changed by `change`.
    fn edited(mut self, change: impl FnOnce(&mut Value)) -> GpuCase {
        let mut report: Value = serde_json::from_slice(&self.report).unwrap();
        change(&mut report);
        self.report = serde_json::to_vec(&report).unwrap();
        self
    }
}

/// A token's claims, read without checking anything.
fn claims(token: &str) -> Map<String, Value> {
    let body = token.split('.').nth(1).unwrap();
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(body).unwrap()).unwrap()
}

/// `case`'s GPU refusal for the first instance.
fn gpu_refusal(case: GpuCase) -> GpuRefusal {
    match case.check() {
        Err(Refusal::Gpu {
            who: Who::Model(0),
            refusal,
        }) => refusal,
        other => panic!("expected a GPU refusal for the first instance, got {other:?}"),
    }
}

#[test]
fn the_real_gpu_verdicts_pass_at_their_fetch_time() {
    let case = GpuCase::real();
    let report: Value = serde_json::from_slice(&case.report).unwrap();
    let payload: Value = serde_json::from_str(
        report["model_attestations"][0]["nvidia_payload"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(payload["evidence_list"].as_array().unwrap().len(), 8);
    assert_eq!(case.check().unwrap().gpus, vec![8]);

    // Signed again with the test key, unchanged, they pass too.
    let mut case = GpuCase::real();
    case.resign(None, |_| {});
    case.resign(Some("GPU-0"), |_| {});
    assert_eq!(case.check().unwrap().gpus, vec![8]);
}

#[test]
fn another_evidence_nonce_is_refused_before_anything_is_posted() {
    let case = GpuCase::real().edited(|r| {
        let entry = &mut r["model_attestations"][0];
        let mut payload: Value =
            serde_json::from_str(entry["nvidia_payload"].as_str().unwrap()).unwrap();
        payload["nonce"] = json!("11".repeat(32));
        entry["nvidia_payload"] = Value::String(payload.to_string());
    });
    let refused = Refusal::Gpu {
        who: Who::Model(0),
        refusal: GpuRefusal::EvidenceNonce,
    };
    assert_eq!(
        gpu_evidence(&case.report, &case.nonce).unwrap_err(),
        refused
    );
    assert_eq!(case.check().unwrap_err(), refused);
}

#[test]
fn missing_evidence_is_refused() {
    let case = GpuCase::real().edited(|r| {
        r["model_attestations"][0]
            .as_object_mut()
            .unwrap()
            .remove("nvidia_payload");
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::NoEvidence);

    // In the three-instance report, the third entry without it.
    let case = Case::real();
    assert_eq!(gpu_evidence(&case.report, &case.nonce).unwrap().len(), 3);
    let case = case.edited(|r| r["model_attestations"][2]["nvidia_payload"] = Value::Null);
    assert_eq!(
        gpu_evidence(&case.report, &case.nonce).unwrap_err(),
        Refusal::Gpu {
            who: Who::Model(2),
            refusal: GpuRefusal::NoEvidence
        }
    );
}

#[test]
fn a_changed_signature_or_an_unlisted_key_is_refused() {
    for gpu in [None, Some("GPU-5")] {
        let mut case = GpuCase::real();
        let token = case.token(gpu);
        let (signed, signature) = token.rsplit_once('.').unwrap();
        let mut signature = URL_SAFE_NO_PAD.decode(signature).unwrap();
        signature[10] ^= 1;
        case.replace(
            gpu,
            format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature)),
        );
        assert_eq!(gpu_refusal(case), GpuRefusal::Signature, "{gpu:?}");
    }

    // Signed by a key NVIDIA does not list.
    let mut case = GpuCase::real();
    let keys = case.keys.clone();
    case.resign(None, |_| {});
    case.keys = keys;
    assert_eq!(gpu_refusal(case), GpuRefusal::UnknownKey);
}

#[test]
fn another_token_nonce_is_refused() {
    let mut case = GpuCase::real();
    case.resign(None, |c| {
        c.insert("eat_nonce".into(), json!("11".repeat(32)));
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::TokenNonce);

    let mut case = GpuCase::real();
    case.resign(Some("GPU-2"), |c| {
        c.insert("eat_nonce".into(), json!("11".repeat(32)));
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::TokenNonce);
}

#[test]
fn a_false_overall_verdict_is_refused() {
    let mut case = GpuCase::real();
    case.resign(None, |c| {
        c.insert("x-nvidia-overall-att-result".into(), json!(false));
    });
    assert_eq!(gpu_refusal(case), GpuRefusal::Verdict);
}

#[test]
fn a_failed_gpu_claim_or_a_missing_gpu_is_refused() {
    let mut case = GpuCase::real();
    case.resign(Some("GPU-3"), |c| {
        c.insert("measres".into(), json!("fail"));
    });
    assert_eq!(
        gpu_refusal(case),
        GpuRefusal::Claim {
            gpu: "GPU-3".into(),
            claim: "measres"
        }
    );

    let mut case = GpuCase::real();
    let mut answer = case.answer(0);
    answer[1].as_object_mut().unwrap().remove("GPU-7");
    case.answers[0] = serde_json::to_vec(&answer).unwrap();
    assert_eq!(gpu_refusal(case), GpuRefusal::GpuCount);
}

#[test]
fn expired_verdicts_are_refused() {
    let mut case = GpuCase::real();
    let expires = claims(&case.token(None))["exp"].as_u64().unwrap();
    case.now = expires - 1;
    assert!(case.check().is_ok());
    case.now = expires;
    assert_eq!(gpu_refusal(case), GpuRefusal::Time);
}
