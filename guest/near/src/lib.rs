//! The guest's check of NEAR AI Cloud's hardware proof, Intel's side and
//! NVIDIA's, made before anything is sent to it, and the one chat request
//! that follows a passed check (slices 1 to 3 of the NEAR mode).
//!
//! [`ask`] is the only way to send: in one call it fetches a report under a
//! fresh nonce, fetches Intel's collateral or reuses what [`Kept`] holds,
//! checks the Intel side, has NVIDIA's service appraise every instance's GPU
//! evidence, checks NVIDIA's signed verdicts, and only then sends the chat
//! request, encrypted to the model key the proof checked, on a new
//! connection that must show the gateway certificate key the proof is tied
//! to.
//!
//! [`fetch_report`] opens one TLS connection to NEAR's gateway through a
//! SOCKS5 proxy (the guest's Tor port), records the SHA-256 of the gateway
//! certificate's public key, and on that connection asks for the attestation
//! report of one model with a fresh nonce and no account key.
//! [`fetch_collateral`] fetches the Intel collateral the report's quotes
//! need, straight from Intel's servers. [`gpu_evidence`] reads each
//! instance's GPU evidence and checks it was gathered under our nonce;
//! [`fetch_gpu_verdict`] posts it to NVIDIA's attestation service, and
//! [`fetch_nvidia_keys`] fetches the keys NVIDIA signs its verdicts with.
//! [`verify_intel`] and [`verify_gpu`] are pure: they check what was fetched
//! against the nonce, the key seen on the connection, the model's name, the
//! collateral, the pinned measurements, NVIDIA's keys and a time given by
//! the caller, and answer with an [`IntelProof`] and a [`GpuProof`], or one
//! [`Refusal`].
//!
//! What a [`Proof`] covers, and what it does not, is said on it.

mod chat;
mod e2ee;
mod fetch;
#[cfg(test)]
mod gate;
mod gpu;
mod verify;

use std::net::SocketAddr;

use serde::{Deserialize, Serialize};

pub use chat::{ask, Answered, Kept, Stop};
pub use dcap_qvl::{QuoteCollateralV3, TcbStatus};
pub use fetch::{
    fetch_collateral, fetch_gpu_verdict, fetch_nvidia_keys, fetch_report, FetchError, Fetched,
};
pub use gpu::{gpu_evidence, verify_gpu, GpuEvidence, GpuRefusal};
pub use verify::{verify_intel, Refusal, Who};

/// `N` bytes from the system's secure random source; None if it fails.
fn random<const N: usize>() -> Option<[u8; N]> {
    let mut bytes = [0u8; N];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut bytes)
        .ok()?;
    Some(bytes)
}

/// The SOCKS5 proxy every connection goes through. Names are resolved by the
/// proxy; the user name and password ask Tor for a circuit of their own.
#[derive(Clone, Copy, Debug)]
pub struct Proxy<'a> {
    pub addr: SocketAddr,
    pub user: &'a str,
    pub password: &'a str,
}

/// The routes [`ask`] takes, each meant to be a Tor circuit of its own:
/// NEAR's gateway (the report and the chat request), Intel's servers (the
/// collateral) and NVIDIA's attestation service (the GPU verdicts and the
/// keys they are signed with).
#[derive(Clone, Copy, Debug)]
pub struct Routes<'a> {
    pub near: Proxy<'a>,
    pub intel: Proxy<'a>,
    pub nvidia: Proxy<'a>,
}

/// Intel's collateral for the quotes of one platform family (one FMSPC and
/// one issuing CA), as Intel's servers gave it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Collateral {
    /// The platform family, in upper-case hex as Intel's URLs take it.
    pub fmspc: String,
    /// The CA that issued the platform's key: `platform` or `processor`.
    pub ca: String,
    pub intel: QuoteCollateralV3,
}

/// The accepted measurements: reference/near-pins.json. A server passes when
/// its measurements equal one accepted set for its role, every value alike.
/// NEAR runs one model's instances on more than one image, and one image for
/// more than one model, so the model sets are not tied to a model.
#[derive(Clone, Debug, Deserialize)]
pub struct Pins {
    pub gateway: Vec<Measurements>,
    pub model: Vec<Measurements>,
}

/// One server's measurements, read from its verified quote and from its
/// replayed RTMR3 event log. Every value is hex in the pins file.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Measurements {
    /// The TD's firmware.
    #[serde(with = "hex")]
    pub mrtd: Vec<u8>,
    /// Firmware configuration.
    #[serde(with = "hex")]
    pub rtmr0: Vec<u8>,
    /// The kernel.
    #[serde(with = "hex")]
    pub rtmr1: Vec<u8>,
    /// The kernel command line and initial file system.
    #[serde(with = "hex")]
    pub rtmr2: Vec<u8>,
    /// 01, the SHA-256 of the app's compose file, then 15 zero bytes.
    #[serde(with = "hex")]
    pub mrconfigid: Vec<u8>,
    /// RTMR3 event `app-id`.
    #[serde(with = "hex")]
    pub app_id: Vec<u8>,
    /// RTMR3 event `key-provider`: which key service hands out its keys.
    #[serde(with = "hex")]
    pub key_provider: Vec<u8>,
    /// RTMR3 event `mr-kms`.
    #[serde(with = "hex")]
    pub mr_kms: Vec<u8>,
    /// RTMR3 event `os-image-hash`.
    #[serde(with = "hex")]
    pub os_image_hash: Vec<u8>,
}

/// What a passed check establishes before a chat request is sent: both
/// halves, from one report under one nonce.
///
/// Covered: genuine, up-to-date Intel TDX hardware reports that the gateway
/// and every listed instance of the model run the pinned images, that the
/// gateway's report is tied to the TLS key this client saw and to this
/// client's nonce, and that every instance holds the one encryption key it
/// names; and NVIDIA's attestation service, in tokens it signed for this
/// nonce, passes every GPU in each instance's evidence.
///
/// Not covered: that an instance's GPUs and its Intel quote are in the same
/// machine (they share only the nonce); the GPUs' firmware and driver
/// against values of Cloak's own (NVIDIA's service judges them); the model
/// workload the measured launcher fetches; where the images came from; and
/// anything about the replies.
#[derive(Clone, Debug)]
pub struct Proof {
    pub intel: IntelProof,
    pub gpu: GpuProof,
}

/// What the Intel side of a passed check establishes; it says nothing about
/// the GPUs.
#[derive(Clone, Debug)]
pub struct IntelProof {
    /// The gateway's Ed25519 key, bound to its quote with the TLS key seen.
    pub gateway_key: [u8; 32],
    /// The model's one Ed25519 encryption key, bound to every instance's
    /// quote.
    pub model_key: [u8; 32],
    /// How many instances of the model the report listed, each checked.
    pub instances: usize,
    /// Intel's verdict on the gateway's platform.
    pub gateway_tcb: TcbStatus,
    /// Intel's verdict on each instance's platform, in the report's order.
    pub model_tcb: Vec<TcbStatus>,
}

/// What the GPU side of a passed check establishes: NVIDIA's verdict on
/// every GPU of every instance passed. It says nothing about the Intel side.
#[derive(Clone, Debug)]
pub struct GpuProof {
    /// How many GPUs NVIDIA passed for each instance, in the report's order.
    pub gpus: Vec<usize>,
}
