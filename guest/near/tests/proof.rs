//! The gate check of the NEAR proof checker, offline: a real report for
//! z-ai/glm-5.3-flash (the gateway and three instances), fetched with no
//! account key through Tor on 19 November 2026, with its nonce, the gateway
//! TLS key hash seen on that connection and Intel's collateral, all public
//! data kept in tests/fixtures, checked against reference/near-pins.json. It
//! passes at its fetch time and is refused for each change below.
//!
//!     cargo test --locked --manifest-path guest/near/Cargo.toml

use cloak_near::{verify, Collateral, CpuOnlyProof, Pins, Refusal, TcbStatus, Who};
use serde_json::{json, Value};

const DAY: u64 = 24 * 60 * 60;

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
        let hex32 = |text: &str| {
            let mut out = [0u8; 32];
            hex::decode_to_slice(text.trim(), &mut out).unwrap();
            out
        };
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

    fn check(&self) -> Result<CpuOnlyProof, Refusal> {
        verify(
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
