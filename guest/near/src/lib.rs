//! The guest's check of NEAR AI Cloud's hardware proof, its Intel quotes
//! and Intel Trust Authority's verdict on its GPUs, made before anything is
//! sent to it, and the one chat request that follows a passed check (slices
//! 1 to 3 of the NEAR mode).
//!
//! [`ask`] is the only way to send: in one call it fetches a report under a
//! fresh nonce, fetches Intel's collateral or reuses what [`Kept`] holds,
//! checks the Intel quotes, fetches Intel Trust Authority's tokens on the
//! GPUs under the same nonce, checks them with Intel's signing keys, and
//! only then sends the chat request, encrypted to the model key the proof
//! checked, on a new connection that must show the gateway certificate key
//! the proof is tied to. When [`Kept`] holds a proof that passed for the
//! same model no longer ago than the proof age the caller chose, at most an
//! hour, the request goes straight to sending under that proof instead: the
//! hardware was then checked up to that long before, not at the moment of
//! sending. [`check`] is the same check, or the same kept proof, without
//! the sending: `ask` is `check`, then the request.
//!
//! [`respond`] is the line format of `cloak-near`, the helper the Mac app
//! starts: one request a line in, one answer a line out.
//!
//! [`fetch_report`] opens one TLS connection to NEAR's gateway on the
//! caller's [`Route`] (through Tor, or direct), records the SHA-256 of the
//! gateway certificate's public key, and on that connection asks for the
//! attestation report of one model with a fresh nonce and no account key.
//! [`fetch_collateral`] fetches the Intel collateral the report's quotes
//! need, straight from Intel's servers. [`fetch_ita_tokens`] asks NEAR's
//! gateway, under the same nonce, for the tokens Intel Trust Authority
//! signed on the gateway's quote and one model server's GPUs, and
//! [`fetch_ita_keys`] fetches the keys Intel signs them with, from Intel.
//! [`verify_intel`] and [`verify_gpu`] are pure: they check what was fetched
//! against the nonce, the key seen on the connection, the model's name, the
//! collateral, the pinned measurements, Intel's keys and a time given by
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
mod helper;
mod verify;

use std::net::SocketAddr;
use std::path::Path;

use serde::{Deserialize, Serialize};

pub use chat::{ask, check, Answered, Kept, Passed, Stop};
pub use dcap_qvl::{QuoteCollateralV3, TcbStatus};
pub use fetch::{
    fetch_collateral, fetch_ita_keys, fetch_ita_tokens, fetch_report, FetchError, Fetched,
};
pub use gpu::{verify_gpu, GpuRefusal};
pub use helper::respond;
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

/// Tor's SOCKS5 port. Names are resolved by Tor; the user name and password
/// ask Tor for a circuit of their own. A connection that cannot be made on
/// that circuit is tried on new ones, each asked for by this user name with
/// the attempt's number appended.
#[derive(Clone, Copy, Debug)]
pub struct Proxy<'a> {
    pub addr: SocksAddr<'a>,
    pub user: &'a str,
    pub password: &'a str,
}

/// Where Tor's SOCKS5 port listens. Only the first socket differs; the SOCKS
/// steps, TLS and HTTP on it are the same.
#[derive(Clone, Copy, Debug)]
pub enum SocksAddr<'a> {
    /// A TCP address, as `127.0.0.1:9050`.
    Tcp(SocketAddr),
    /// A Unix socket file, as the Mac app's tor listens on.
    Unix(&'a Path),
}

/// How a connection reaches its host. Either way, the same certificate
/// checks, key pin and HTTP follow.
#[derive(Clone, Copy, Debug)]
pub enum Route<'a> {
    /// An ordinary connection to the host, its name looked up by the system:
    /// the host sees the Mac's internet address. One attempt.
    Direct,
    /// Through Tor: the host sees a Tor exit's address.
    Tor(Proxy<'a>),
}

/// The routes [`ask`] and [`check`] take: to NEAR's gateway (the report, Intel Trust
/// Authority's tokens and the chat request), and to Intel's servers (the
/// collateral, and the keys Intel Trust Authority signs its tokens with).
/// Through Tor, each is meant to be a circuit of its own.
#[derive(Clone, Copy, Debug)]
pub struct Routes<'a> {
    pub near: Route<'a>,
    pub intel: Route<'a>,
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
    pub model: Vec<ModelMeasurements>,
}

/// One server's measurements, read from its verified quote and from its
/// replayed RTMR3 event log; a gateway's are pinned as they are. Every value
/// is hex in the pins file.
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

/// A model server's measurements as they are pinned: those of
/// [`Measurements`] but MRCONFIGID. Every model server's compose file names
/// its own host (`INSTANCE_LABEL=gpu04`), so it is pinned by its hash with
/// that label's digits dropped, once MRCONFIGID has been checked against
/// the whole file. Every value is hex in the pins file.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelMeasurements {
    #[serde(with = "hex")]
    pub mrtd: Vec<u8>,
    #[serde(with = "hex")]
    pub rtmr0: Vec<u8>,
    #[serde(with = "hex")]
    pub rtmr1: Vec<u8>,
    #[serde(with = "hex")]
    pub rtmr2: Vec<u8>,
    /// SHA-256 of the compose file, its one `INSTANCE_LABEL=gpu` followed by
    /// one to four digits, with those digits dropped.
    #[serde(with = "hex")]
    pub compose_sha256_without_label: Vec<u8>,
    #[serde(with = "hex")]
    pub app_id: Vec<u8>,
    #[serde(with = "hex")]
    pub key_provider: Vec<u8>,
    #[serde(with = "hex")]
    pub mr_kms: Vec<u8>,
    #[serde(with = "hex")]
    pub os_image_hash: Vec<u8>,
}

/// What a passed check establishes before a chat request is sent: both
/// halves, from one report under one nonce.
///
/// Covered: genuine, up-to-date Intel TDX hardware reports that the gateway
/// and every listed instance of the model run the pinned images (a model
/// instance's compose file pinned but for its host's label), that the
/// gateway's report is tied to the TLS key this client saw and to this
/// client's nonce, and that every instance holds the one encryption key it
/// names; and Intel Trust Authority, in tokens it signed, passes every GPU
/// of one model server, evidence made under a nonce Intel issued at most
/// five minutes before and that a pinned gateway's quote ties to this
/// client's nonce.
///
/// Not covered: which model server those GPUs are in, or that they are in
/// the same machine as any quote checked (the GPU token is tied to the
/// gateway's quote, not to a model server's, and only by the nonce); the
/// GPUs of the model's other servers; the GPUs' firmware and driver against
/// values of Cloak's own (Intel's verifier judges them against NVIDIA's);
/// the model workload the measured launcher fetches; where the images came
/// from; and anything about the replies.
///
/// All of it holds at the moment the check passed. A request sent under a
/// proof [`Kept`] holds goes on hardware checked up to the proof age before.
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
    /// SHA-256 of the gateway's TLS key: the one seen on the connection, and
    /// the one its quote binds.
    pub gateway_tls_key: [u8; 32],
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

/// What the GPU side of a passed check establishes: Intel Trust Authority's
/// verdict on every GPU of one model server, which NEAR's gateway chose,
/// passed, tied to this client's nonce through Intel's nonce and the
/// gateway's quote. It does not say which of the report's instances that
/// server is.
#[derive(Clone, Debug)]
pub struct GpuProof {
    /// How many GPUs Intel passed.
    pub gpus: usize,
}
