//! The pure Intel half: the checks NEAR documents for its gateway and for
//! every model instance's Intel TDX quote, against pinned measurements,
//! failing closed on anything missing, malformed or different. No network
//! and no clock but `now`. The GPU half is `gpu.rs`.

use std::fmt;

use dcap_qvl::configs::RustCryptoConfig;
use dcap_qvl::intel;
use dcap_qvl::quote::{Quote, TDReport10};
use dcap_qvl::verify::QuoteVerifier;
use dcap_qvl::{QuotePolicy, TcbStatus};
use serde::Deserialize;
use sha2::{Digest, Sha256, Sha384};

use crate::{
    Collateral, GatewayMeasurements, GpuRefusal, IntelProof, Measurements, ModelMeasurements, Pins,
};

/// What names a model server's own host in its compose file, followed by
/// one to four digits: `INSTANCE_LABEL=gpu04`.
const LABEL: &[u8] = b"INSTANCE_LABEL=gpu";
/// The most digits a host's label may have.
const LABEL_DIGITS: usize = 4;

/// Which part of the report a refusal is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Who {
    Gateway,
    /// The model entry at this position in the report.
    Model(usize),
}

impl fmt::Display for Who {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Who::Gateway => write!(f, "the gateway"),
            Who::Model(index) => write!(f, "model instance {}", index + 1),
        }
    }
}

/// The one reason a report was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A field is missing or not in the form NEAR documents.
    Malformed(String),
    /// Signed with something other than Ed25519.
    Algorithm(Who),
    /// The nonce sent back is not ours.
    NonceEcho(Who),
    /// The gateway names a TLS key other than the one seen on the connection.
    TlsKey,
    /// No Intel collateral for this quote's platform family.
    NoCollateral(Who),
    /// Intel's check refused the quote: signatures, certificate chains,
    /// revocation, the platform's TCB status (only `UpToDate` passes),
    /// expired collateral, or the TD's attributes.
    Intel { who: Who, reason: String },
    /// A quote that is not from a TDX trust domain.
    NotTdx(Who),
    /// A TD running in debug mode.
    Debug(Who),
    /// The quote's report data is not the key, the TLS key and our nonce.
    ReportData(Who),
    /// The event log does not replay to the quoted RTMR3.
    Rtmr3(Who),
    /// MRCONFIGID is not 01, the SHA-256 of the compose file, then zeros.
    ConfigId(Who),
    /// A model server's compose file does not name its host exactly once,
    /// as `INSTANCE_LABEL=gpu` and one to four digits.
    Label(Who),
    /// A measured event that must appear once is missing or repeated.
    Event { who: Who, name: &'static str },
    /// The report lists no instance of the model.
    NoModels,
    /// An entry is for another model.
    ModelName { who: Who, name: String },
    /// The encryption key differs from the key the quote binds.
    KeyNotBound(Who),
    /// Not the same encryption key as the first instance.
    KeysDiffer(Who),
    /// An instance id already listed.
    SameInstance(Who),
    /// Measurements that equal no accepted set; `seen` names the ones a
    /// reviewer compares first.
    Pin { who: Who, seen: String },
    /// Intel Trust Authority's verdict on the GPUs, or its tie to our nonce,
    /// did not pass.
    Gpu(GpuRefusal),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Malformed(what) => write!(f, "the report is malformed: {what}"),
            Refusal::Algorithm(who) => write!(f, "{who} does not sign with Ed25519"),
            Refusal::NonceEcho(who) => write!(f, "{who} sent back a nonce that is not ours"),
            Refusal::TlsKey => write!(f, "the gateway names a TLS key other than the one on the connection"),
            Refusal::NoCollateral(who) => write!(f, "no Intel collateral for {who}'s platform"),
            Refusal::Intel { who, reason } => write!(f, "Intel's check refused {who}: {reason}"),
            Refusal::NotTdx(who) => write!(f, "{who}'s quote is not from a TDX trust domain"),
            Refusal::Debug(who) => write!(f, "{who} runs in debug mode"),
            Refusal::ReportData(who) => write!(f, "{who}'s quote is not tied to its key, the TLS key and our nonce"),
            Refusal::Rtmr3(who) => write!(f, "{who}'s event log does not match its quote"),
            Refusal::ConfigId(who) => write!(f, "{who}'s compose file does not match its quote"),
            Refusal::Label(who) => write!(f, "{who}'s compose file does not name its host once, as INSTANCE_LABEL=gpu and one to four digits"),
            Refusal::Event { who, name } => write!(f, "{who}'s measured event {name} is missing or repeated"),
            Refusal::NoModels => write!(f, "the report lists no instance of the model"),
            Refusal::ModelName { who, name } => write!(f, "{who} is for another model, {name}"),
            Refusal::KeyNotBound(who) => write!(f, "{who}'s encryption key is not the key its quote binds"),
            Refusal::KeysDiffer(who) => write!(f, "{who} holds a different encryption key"),
            Refusal::SameInstance(who) => write!(f, "{who} repeats another instance"),
            Refusal::Pin { who, seen } => write!(f, "{who}'s measurements are not among the pinned ones ({seen})"),
            Refusal::Gpu(refusal) => write!(f, "Intel's GPU verdict: {refusal}"),
        }
    }
}

impl std::error::Error for Refusal {}

#[derive(Deserialize)]
struct Report {
    gateway_attestation: Gateway,
    model_attestations: Vec<Model>,
}

#[derive(Deserialize)]
struct Gateway {
    signing_algo: String,
    signing_address: String,
    request_nonce: String,
    tls_cert_fingerprint: String,
    intel_quote: String,
    /// The event log as JSON text.
    event_log: String,
    info: Info,
}

#[derive(Deserialize)]
struct Model {
    model_name: String,
    signing_algo: String,
    signing_address: String,
    signing_public_key: String,
    request_nonce: String,
    tls_cert_fingerprint: String,
    intel_quote: String,
    event_log: Vec<Event>,
    info: Info,
}

#[derive(Deserialize)]
struct Info {
    tcb_info: TcbInfo,
}

#[derive(Deserialize)]
struct TcbInfo {
    /// Hashed exactly as sent, never re-encoded.
    app_compose: String,
}

#[derive(Deserialize)]
struct Event {
    imr: u32,
    event_type: u32,
    event: String,
    event_payload: String,
}

/// What one server's quote and event log establish.
struct Measured {
    tcb: TcbStatus,
    measurements: Measurements,
    instance_id: Vec<u8>,
}

/// Checks the Intel side of a report fetched under `nonce` on a connection
/// whose gateway certificate key hashed to `spki_sha256`, for `model`, with
/// Intel's `collateral`, against `pins`, at `now` (seconds since 1970).
pub fn verify_intel(
    report: &[u8],
    nonce: &[u8; 32],
    spki_sha256: &[u8; 32],
    model: &str,
    collateral: &[Collateral],
    pins: &Pins,
    now: u64,
) -> Result<IntelProof, Refusal> {
    let report: Report = parse(report)?;

    let gateway = &report.gateway_attestation;
    let who = Who::Gateway;
    let gateway_key = ed25519(who, &gateway.signing_algo, &gateway.signing_address)?;
    echo(who, &gateway.request_nonce, nonce)?;
    if bytes::<32>(
        "the gateway's TLS fingerprint",
        &gateway.tls_cert_fingerprint,
    )? != *spki_sha256
    {
        return Err(Refusal::TlsKey);
    }
    let events: Vec<Event> = serde_json::from_str(&gateway.event_log)
        .map_err(|e| Refusal::Malformed(format!("the gateway's event log: {e}")))?;
    let gateway_measured = server(
        who,
        &gateway.intel_quote,
        &events,
        &gateway.info.tcb_info.app_compose,
        &bound(&gateway_key, spki_sha256, nonce),
        collateral,
        now,
    )?;

    let Some(first) = report.model_attestations.first() else {
        return Err(Refusal::NoModels);
    };
    let model_key = bytes::<32>("an encryption key", &first.signing_public_key)?;
    let mut models = Vec::new();
    let mut model_pins = Vec::new();
    for (index, entry) in report.model_attestations.iter().enumerate() {
        let who = Who::Model(index);
        if entry.model_name != model {
            return Err(Refusal::ModelName {
                who,
                name: entry.model_name.clone(),
            });
        }
        let key = ed25519(who, &entry.signing_algo, &entry.signing_address)?;
        if bytes::<32>("an encryption key", &entry.signing_public_key)? != key {
            return Err(Refusal::KeyNotBound(who));
        }
        if key != model_key {
            return Err(Refusal::KeysDiffer(who));
        }
        echo(who, &entry.request_nonce, nonce)?;
        let tls = bytes::<32>("a model's TLS fingerprint", &entry.tls_cert_fingerprint)?;
        let measured = server(
            who,
            &entry.intel_quote,
            &entry.event_log,
            &entry.info.tcb_info.app_compose,
            &bound(&key, &tls, nonce),
            collateral,
            now,
        )?;
        if models
            .iter()
            .any(|m: &Measured| m.instance_id == measured.instance_id)
        {
            return Err(Refusal::SameInstance(who));
        }
        // The compose file is the one MRCONFIGID binds: `server` checked it.
        model_pins.push(model_measurements(
            who,
            &measured.measurements,
            &entry.info.tcb_info.app_compose,
        )?);
        models.push(measured);
    }

    pinned(
        Who::Gateway,
        &gateway_measurements(&gateway_measured.measurements),
        &pins.gateway,
    )?;
    for (index, pin) in model_pins.iter().enumerate() {
        pinned(Who::Model(index), pin, &pins.model)?;
    }

    Ok(IntelProof {
        gateway_key,
        gateway_tls_key: *spki_sha256,
        gateway_mrconfigid: gateway_measured.measurements.mrconfigid,
        model_key,
        instances: models.len(),
        gateway_tcb: gateway_measured.tcb,
        model_tcb: models.iter().map(|m| m.tcb).collect(),
    })
}

/// Every quote in a report, for fetching their collateral.
pub(crate) fn quotes(report: &[u8]) -> Result<Vec<Vec<u8>>, Refusal> {
    let report: Report = parse(report)?;
    std::iter::once(&report.gateway_attestation.intel_quote)
        .chain(report.model_attestations.iter().map(|m| &m.intel_quote))
        .map(|quote| {
            hex::decode(quote).map_err(|_| Refusal::Malformed("a quote that is not hex".into()))
        })
        .collect()
}

/// A quote's platform family: its FMSPC in upper-case hex and the CA that
/// issued its platform key, read from the certificates it carries.
pub(crate) fn family(quote: &[u8]) -> Result<(String, String), String> {
    let parsed = Quote::parse(quote).map_err(|e| format!("a quote: {e}"))?;
    let fmspc =
        intel::quote_fmspc(&parsed).map_err(|e| format!("a quote's platform family: {e}"))?;
    let ca = intel::quote_ca(&parsed).map_err(|e| format!("a quote's issuer: {e}"))?;
    Ok((hex::encode_upper(fmspc), ca.as_id_str().to_owned()))
}

fn parse(report: &[u8]) -> Result<Report, Refusal> {
    serde_json::from_slice(report).map_err(|e| Refusal::Malformed(e.to_string()))
}

fn bytes<const N: usize>(what: &str, text: &str) -> Result<[u8; N], Refusal> {
    let mut out = [0u8; N];
    hex::decode_to_slice(text, &mut out)
        .map_err(|_| Refusal::Malformed(format!("{what} is not {N} bytes of hex")))?;
    Ok(out)
}

fn ed25519(who: Who, algo: &str, key: &str) -> Result<[u8; 32], Refusal> {
    if algo != "ed25519" {
        return Err(Refusal::Algorithm(who));
    }
    bytes::<32>("a signing key", key)
}

fn echo(who: Who, sent_back: &str, nonce: &[u8; 32]) -> Result<(), Refusal> {
    match bytes::<32>("a nonce", sent_back)? == *nonce {
        true => Ok(()),
        false => Err(Refusal::NonceEcho(who)),
    }
}

/// The report data a quote must carry: SHA-256 of the signing key and the
/// TLS key's fingerprint, then the nonce.
fn bound(key: &[u8; 32], tls: &[u8; 32], nonce: &[u8; 32]) -> [u8; 64] {
    let mut data = [0u8; 64];
    data[..32].copy_from_slice(&Sha256::new().chain_update(key).chain_update(tls).finalize());
    data[32..].copy_from_slice(nonce);
    data
}

/// Intel's appraisal: only an `UpToDate` platform and quoting enclave pass,
/// with no grace for anything older and every piece of collateral in date.
/// Every NEAR server seen on 19 November 2026 is a multi-socket platform
/// whose certificate says it can add sockets, has its keys cached by Intel's
/// registration service and runs with SMT on; those three are accepted,
/// where dcap-qvl's strict policy alone would refuse them.
fn policy(now: u64) -> QuotePolicy {
    QuotePolicy::strict(now)
        .allow_dynamic_platform(true)
        .allow_cached_keys(true)
        .allow_smt(true)
}

/// One server's quote, checked by Intel's rules and tied to its report data,
/// its event log and its compose file; answers with what it measured.
fn server(
    who: Who,
    quote: &str,
    events: &[Event],
    app_compose: &str,
    report_data: &[u8; 64],
    collateral: &[Collateral],
    now: u64,
) -> Result<Measured, Refusal> {
    let quote =
        hex::decode(quote).map_err(|_| Refusal::Malformed(format!("{who}'s quote is not hex")))?;
    let (fmspc, ca) = family(&quote).map_err(Refusal::Malformed)?;
    let collateral = collateral
        .iter()
        .find(|c| c.fmspc == fmspc && c.ca == ca)
        .ok_or(Refusal::NoCollateral(who))?;
    let claims = QuoteVerifier::new_prod()
        .with_config::<RustCryptoConfig>()
        .verify_with_policy(&quote, &collateral.intel, now, &policy(now))
        .map_err(|e| Refusal::Intel {
            who,
            reason: format!("{e:#}"),
        })?;
    let td: &TDReport10 = claims.report.as_td10().ok_or(Refusal::NotTdx(who))?;
    if td.td_attributes[0] & 1 != 0 {
        return Err(Refusal::Debug(who));
    }
    if td.report_data != *report_data {
        return Err(Refusal::ReportData(who));
    }

    let mut rtmr3 = [0u8; 48];
    let mut measured = Vec::new();
    for event in events.iter().filter(|e| e.imr == 3) {
        let payload = hex::decode(&event.event_payload)
            .map_err(|_| Refusal::Malformed(format!("{who}'s event {} is not hex", event.event)))?;
        let digest = Sha384::new()
            .chain_update(event.event_type.to_le_bytes())
            .chain_update(b":")
            .chain_update(event.event.as_bytes())
            .chain_update(b":")
            .chain_update(&payload)
            .finalize();
        rtmr3 = Sha384::new()
            .chain_update(rtmr3)
            .chain_update(digest)
            .finalize()
            .into();
        measured.push((event.event.as_str(), payload));
    }
    if rtmr3 != td.rt_mr3 {
        return Err(Refusal::Rtmr3(who));
    }
    let mut config_id = [0u8; 48];
    config_id[0] = 1;
    config_id[1..33].copy_from_slice(&Sha256::digest(app_compose.as_bytes()));
    if td.mr_config_id != config_id {
        return Err(Refusal::ConfigId(who));
    }

    let once = |name: &'static str| -> Result<Vec<u8>, Refusal> {
        let mut found = measured.iter().filter(|(n, _)| *n == name);
        match (found.next(), found.next()) {
            (Some((_, payload)), None) => Ok(payload.clone()),
            _ => Err(Refusal::Event { who, name }),
        }
    };
    Ok(Measured {
        tcb: claims.tcb.status,
        measurements: Measurements {
            mrtd: td.mr_td.to_vec(),
            rtmr0: td.rt_mr0.to_vec(),
            rtmr1: td.rt_mr1.to_vec(),
            rtmr2: td.rt_mr2.to_vec(),
            mrconfigid: td.mr_config_id.to_vec(),
            app_id: once("app-id")?,
            key_provider: once("key-provider")?,
            mr_kms: once("mr-kms")?,
            os_image_hash: once("os-image-hash")?,
        },
        instance_id: once("instance-id")?,
    })
}

/// A gateway server's measurements as they are pinned: Intel TDX hardware,
/// OS image, and dstack KMS identity (`MRCONFIGID` is still checked against
/// `app_compose` in `server` and bound to Intel Trust Authority's token).
fn gateway_measurements(measured: &Measurements) -> GatewayMeasurements {
    GatewayMeasurements {
        mrtd: measured.mrtd.clone(),
        rtmr0: measured.rtmr0.clone(),
        rtmr1: measured.rtmr1.clone(),
        rtmr2: measured.rtmr2.clone(),
        app_id: measured.app_id.clone(),
        key_provider: measured.key_provider.clone(),
        mr_kms: measured.mr_kms.clone(),
        os_image_hash: measured.os_image_hash.clone(),
    }
}

/// A model server's measurements as they are pinned: MRCONFIGID gives way
/// to the SHA-256 of its compose file without its label's digits.
fn model_measurements(
    who: Who,
    measured: &Measurements,
    app_compose: &str,
) -> Result<ModelMeasurements, Refusal> {
    Ok(ModelMeasurements {
        mrtd: measured.mrtd.clone(),
        rtmr0: measured.rtmr0.clone(),
        rtmr1: measured.rtmr1.clone(),
        rtmr2: measured.rtmr2.clone(),
        compose_sha256_without_label: without_label(app_compose)
            .ok_or(Refusal::Label(who))?
            .to_vec(),
        app_id: measured.app_id.clone(),
        key_provider: measured.key_provider.clone(),
        mr_kms: measured.mr_kms.clone(),
        os_image_hash: measured.os_image_hash.clone(),
    })
}

/// SHA-256 of a compose file, exactly as sent, with the digits of its host's
/// label dropped: `LABEL` must appear exactly once, followed by one to
/// `LABEL_DIGITS` ASCII digits; None otherwise. Only those digits are
/// dropped, so anything else in or after the label stays in what is hashed.
fn without_label(app_compose: &str) -> Option<[u8; 32]> {
    let text = app_compose.as_bytes();
    let mut labels = (0..text.len()).filter(|&at| text[at..].starts_with(LABEL));
    let (Some(at), None) = (labels.next(), labels.next()) else {
        return None;
    };
    let digits_at = at + LABEL.len();
    let digits = text[digits_at..]
        .iter()
        .take_while(|b| b.is_ascii_digit())
        .count();
    (1..=LABEL_DIGITS).contains(&digits).then(|| {
        Sha256::new()
            .chain_update(&text[..digits_at])
            .chain_update(&text[digits_at + digits..])
            .finalize()
            .into()
    })
}

fn pinned<T: PartialEq + fmt::Display>(who: Who, seen: &T, accepted: &[T]) -> Result<(), Refusal> {
    match accepted.contains(seen) {
        true => Ok(()),
        false => Err(Refusal::Pin {
            who,
            seen: seen.to_string(),
        }),
    }
}

/// What a gateway's refusal names.
impl fmt::Display for GatewayMeasurements {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "MRTD {}, app-id {}, os-image-hash {}",
            hex::encode(&self.mrtd),
            hex::encode(&self.app_id),
            hex::encode(&self.os_image_hash)
        )
    }
}

/// What a model server's refusal names.
impl fmt::Display for ModelMeasurements {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "MRTD {}, compose SHA-256 without the label {}, os-image-hash {}",
            hex::encode(&self.mrtd),
            hex::encode(&self.compose_sha256_without_label),
            hex::encode(&self.os_image_hash)
        )
    }
}

/// The gate checks of the host's label in a model server's compose file,
/// offline, on the real compose of the third instance of the saved
/// z-ai/glm-5.3-flash report (tests/fixtures/report.json), label `gpu23`,
/// whose hash without the label is pinned in reference/near-pins.json. That
/// compose passes MRCONFIGID in the report's own check (tests/proof.rs).
#[cfg(test)]
mod label {
    use super::without_label;
    use crate::Pins;

    /// The real compose, exactly as sent.
    fn real() -> String {
        let report: serde_json::Value =
            serde_json::from_slice(include_bytes!("../tests/fixtures/report.json")).unwrap();
        report["model_attestations"][2]["info"]["tcb_info"]["app_compose"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    /// The real compose with its label, `INSTANCE_LABEL=gpu23`, in place.
    fn relabelled(label: &str) -> String {
        let real = real();
        assert_eq!(real.matches("INSTANCE_LABEL=gpu23").count(), 1);
        real.replace("INSTANCE_LABEL=gpu23", label)
    }

    /// Whether a model server with this compose, and otherwise the third
    /// instance's measurements, would pass the pin.
    fn passes(compose: &str) -> bool {
        let pins: Pins =
            serde_json::from_str(include_str!("../../../reference/near-pins.json")).unwrap();
        without_label(compose)
            .is_some_and(|hash| pins.model[2].compose_sha256_without_label == hash)
    }

    #[test]
    fn composes_differing_only_in_label_digits_have_one_pin() {
        assert!(passes(&real()));
        for label in ["gpu04", "gpu7", "gpu1234", "gpu0000"] {
            let compose = relabelled(&format!("INSTANCE_LABEL={label}"));
            assert_eq!(without_label(&compose), without_label(&real()), "{label}");
            assert!(passes(&compose), "{label}");
        }
    }

    #[test]
    fn a_label_with_letters_or_more_than_four_digits_is_refused() {
        for label in ["gpuab", "gpu12345", "gpu2b", "gpu23x", "gpu-23", "gpu 23"] {
            assert!(
                !passes(&relabelled(&format!("INSTANCE_LABEL={label}"))),
                "{label}"
            );
        }
        // With no digit, or more than four, no pin is made at all; any other
        // character stays in what is hashed.
        assert_eq!(without_label(&relabelled("INSTANCE_LABEL=gpuab")), None);
        assert_eq!(without_label(&relabelled("INSTANCE_LABEL=gpu12345")), None);
    }

    #[test]
    fn a_compose_without_exactly_one_label_is_refused() {
        for compose in [
            relabelled(""),
            relabelled("INSTANCE_LABEL=gpu"),
            relabelled("INSTANCE_LABEL=gpu23 INSTANCE_LABEL=gpu24"),
            relabelled("INSTANCE_LABEL=gpu23 INSTANCE_LABEL=gpu23"),
        ] {
            assert_eq!(without_label(&compose), None);
        }
    }

    #[test]
    fn a_compose_differing_anywhere_else_is_refused() {
        // Another telemetry address, as on the second Qwen/Qwen3.8-27B server
        // seen on 19 November, whose label differs too.
        let real = real();
        let other = relabelled("INSTANCE_LABEL=gpu04")
            .replace("telemetry-stg.infra.near.ai", "telemetry.infra.near.ai");
        assert_ne!(other, relabelled("INSTANCE_LABEL=gpu04"));
        assert!(!passes(&other));
        // One byte more, before the label and after it.
        assert!(!passes(&format!(" {real}")));
        assert!(!passes(&format!("{real} ")));
    }
}
