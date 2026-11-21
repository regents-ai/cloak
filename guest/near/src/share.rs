//! Trace sharing with NEAR's Trace Commons, one readied NEAR chat message at
//! a time (docs/near-share.md, section 7). Every step goes on NEAR mode's
//! own route, with ordinary certificate checks against the roots its caller
//! gives. In the order a share takes:
//!
//! - [`listen`] reads the commons' published capabilities, the witness's pin
//!   among them, and opens a listener on this Mac's loopback address for the
//!   NEAR AI sign-in the person makes in their browser;
//! - [`enrol`] waits for that sign-in, runs the commons' enrolment ceremony
//!   with this Mac's device key and the NEAR AI session the browser handed
//!   over, and drops that session at once; its refresh token is never read;
//! - [`ready`] asks the issuer for an upload claim signed by the device key,
//!   then the commons for the admission challenge the readied message
//!   carries; [`crate::ask_readied`] sends that message, and [`receipt`]
//!   fetches and checks NEAR's receipt for it;
//! - [`review`] checks the witness's enclave against the pin the commons
//!   published at enrolment, and only once it passes sends the witness the
//!   exchange to redact; its envelope comes back exactly as it was sent;
//! - [`upload`] sends that envelope, the bytes given and no others;
//! - [`status`] and [`withdraw`] read and withdraw what was shared.
//!
//! The device key and the account session come only inside request lines,
//! and the NEAR AI session only from the browser. None is logged or put in
//! an answer, but the account session, which [`enrol`] and [`withdraw`]
//! hand back for the Mac to keep.

use std::fmt;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use rustls::RootCertStore;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::fetch::{connect, percent_decode, percent_encode, request, Answer, NEAR};
use crate::verify::{verify_witness, witness_set, WitnessSet};
use crate::{random, FetchError, Kept, Refusal, Route};

/// The commons' ingest: enrolment, challenges, uploads and their status.
pub(crate) const INGEST: &str = "ingest.tracecommons.ai";
/// Where NEAR AI's sign-in starts, followed by the provider.
const SIGNIN: &str = "https://cloud-platform.near.ai/v1/auth";
const PROVIDERS: [&str; 2] = ["github", "google"];
/// The page NEAR AI sends the browser back to, and the one it posts to.
const CALLBACK: &str = "/trace-commons/near-ai/callback";
const DEPOSIT: &str = "/trace-commons/near-ai/deposit";
/// How long the browser may take over one loopback request.
const LOOPBACK_STEP: Duration = Duration::from_secs(10);
const LOOPBACK_LIMIT: usize = 16 << 10;
/// How long the witness may take to redact: the commons' own client's limit.
const WITNESS_WAIT: Duration = Duration::from_secs(570);
/// The largest request the witness takes.
const WITNESS_LIMIT: usize = 32 << 20;
/// The largest envelope taken back.
const ENVELOPE_LIMIT: usize = 16 << 20;
/// The largest of any other answer.
const ANSWER_LIMIT: usize = 1 << 20;
/// The longest a challenge, and an enrolment ceremony, may run.
const CHALLENGE_LIFE: u64 = 900;
const CEREMONY_LIFE: u64 = 600;
/// The commons' consent policy the raw contribution is made under.
const POLICY_VERSION: &str = "2026-04-24";
/// What the raw contribution names as its source.
const AGENT: &str = "regents-cloak";
/// The tag a witness quote's report data starts with.
const WITNESS_TAG: &[u8; 8] = b"tcwitns1";
/// The consent scopes, the first always granted, and the uses they grant.
const SCOPES: [&str; 5] = [
    "debugging_evaluation",
    "benchmark_only",
    "ranking_training",
    "model_training",
    "public_attribution",
];
const USES: [&str; 6] = [
    "debugging",
    "evaluation",
    "benchmark_generation",
    "ranking_model_training",
    "model_training",
    "aggregate_analytics",
];

/// Where sharing's connections go: the commons, the witness and NEAR on
/// `route`, Intel on `intel`, every certificate checked against `roots`.
pub(crate) struct Net<'a> {
    pub route: Route<'a>,
    pub intel: Route<'a>,
    pub roots: &'a RootCertStore,
}

/// Why a step of sharing stopped. Up to and including `Connect`, nothing of
/// the step's own request was written ([`Halt::sent`]).
#[derive(Debug)]
pub enum Halt {
    /// The line cannot go as given, or the system gave no randomness or time.
    Request(String),
    /// The sign-in in the browser did not finish.
    Signin(String),
    /// A read made before sending failed: the capabilities, the witness's
    /// quote or Intel's collateral for it.
    Fetch(FetchError),
    /// The issuer gave no upload claim, so the step's own request, which
    /// goes under one, was not sent.
    Claim(String),
    /// The witness's enclave did not pass, so nothing was sent to it.
    Refused(Refusal),
    /// The connection to send on could not be made.
    Connect(FetchError),
    /// Writing the request or reading its answer failed; it may have arrived.
    Send(FetchError),
    /// The host answered with a status other than 200 to 299.
    Status {
        who: &'static str,
        code: u16,
        detail: String,
    },
    /// The answer is not what was asked for.
    Reply(String),
}

impl Halt {
    /// Whether the step's request may have reached its host.
    pub fn sent(&self) -> bool {
        match self {
            Halt::Request(_)
            | Halt::Signin(_)
            | Halt::Fetch(_)
            | Halt::Claim(_)
            | Halt::Refused(_)
            | Halt::Connect(_) => false,
            Halt::Send(_) | Halt::Status { .. } | Halt::Reply(_) => true,
        }
    }
}

impl fmt::Display for Halt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Halt::Request(why) => write!(f, "the request cannot be sent: {why}"),
            Halt::Signin(why) => write!(f, "the sign-in did not finish: {why}"),
            Halt::Fetch(error) => write!(f, "fetching: {error}"),
            Halt::Claim(why) => write!(f, "no upload claim: {why}"),
            Halt::Refused(refusal) => write!(f, "the witness was refused: {refusal}"),
            Halt::Connect(error) => write!(f, "connecting: {error}"),
            Halt::Send(error) => write!(f, "sending: {error}"),
            Halt::Status { who, code, detail } => write!(f, "{who} answered {code}: {detail}"),
            Halt::Reply(why) => write!(f, "the answer was refused: {why}"),
        }
    }
}

impl std::error::Error for Halt {}

/// The witness as the commons publishes it: where it is, the address its
/// enclave signs with, and the measurement sets the commons accepts.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Witness {
    pub url: String,
    pub signing_address: String,
    pub expected_measurements: Vec<String>,
}

/// A witness pin, read.
struct Pinned {
    host: String,
    address: [u8; 20],
    sets: Vec<WitnessSet>,
}

impl Witness {
    fn pinned(&self) -> Result<Pinned, String> {
        let host = https_host(&self.url).ok_or("the witness's address is not an https host")?;
        let mut address = [0u8; 20];
        self.signing_address
            .strip_prefix("0x")
            .and_then(|text| hex::decode_to_slice(text, &mut address).ok())
            .ok_or("the witness's signing address is not 20 bytes of hex")?;
        let sets = self
            .expected_measurements
            .iter()
            .map(|set| witness_set(set))
            .collect::<Option<Vec<_>>>()
            .filter(|sets| !sets.is_empty())
            .ok_or("the witness's measurements are not ones it can be checked against")?;
        Ok(Pinned {
            host,
            address,
            sets,
        })
    }
}

/// The commons' published capabilities, as far as Cloak reads them.
#[derive(Deserialize)]
struct Capabilities {
    ready: bool,
    near_ai_login_ready: Option<bool>,
    witness: Witness,
    issuer_url: String,
    audience: String,
}

/// An enrolled account, as [`enrol`] gives it and every later line carries
/// it back. Nothing in it is secret.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Account {
    pub tenant_id: String,
    pub device_key_id: String,
    pub issuer_url: String,
    pub audience: String,
    /// The witness's pin, as the commons published it at enrolment.
    pub witness: Witness,
}

/// This Mac's device key: Ed25519, from a 32-byte seed the Mac keeps.
pub(crate) struct Device {
    pair: Ed25519KeyPair,
}

impl Device {
    /// From the seed in standard base64.
    pub(crate) fn from_line(seed: &str) -> Result<Device, Halt> {
        let refused = || Halt::Request("the device key is not 32 bytes of base64".into());
        let seed = STANDARD.decode(seed).map_err(|_| refused())?;
        if seed.len() != 32 {
            return Err(refused());
        }
        let pair = Ed25519KeyPair::from_seed_unchecked(&seed).map_err(|_| refused())?;
        Ok(Device { pair })
    }

    fn public(&self) -> [u8; 32] {
        self.pair
            .public_key()
            .as_ref()
            .try_into()
            .expect("an Ed25519 public key is 32 bytes")
    }

    fn public_line(&self) -> String {
        STANDARD.encode(self.public())
    }

    /// The commons' id for the key: `sha256:` and the hex of its digest.
    fn key_id(&self) -> String {
        format!("sha256:{}", hex::encode(Sha256::digest(self.public())))
    }

    fn sign(&self, bytes: &[u8]) -> String {
        STANDARD.encode(self.pair.sign(bytes))
    }

    /// Refuses a key that is not the account's.
    fn of(&self, account: &Account) -> Result<(), Halt> {
        match self.key_id() == account.device_key_id {
            true => Ok(()),
            false => Err(Halt::Request("the device key is not the account's".into())),
        }
    }
}

/// The pseudonymous subject the commons knows an account's device by.
fn subject(device_key_id: &str) -> String {
    let digest = Sha256::digest(format!("user_subject:{device_key_id}"));
    format!("sha256:{}", hex::encode(digest))
}

/// A sign-in in the browser, waiting on this Mac's loopback address.
pub(crate) struct Signin {
    listener: TcpListener,
    /// `http://127.0.0.1:<port>`: the only origin the deposit is taken from.
    origin: String,
    /// A value of this sign-in's own, which the deposit must carry.
    state: String,
    capabilities: Capabilities,
}

/// Reads the commons' capabilities and, when it takes NEAR AI sign-ins,
/// opens the loopback listener the sign-in returns to. The sign-in's
/// address for each provider, for the Mac to open in the browser.
pub(crate) fn listen(net: &Net) -> Result<(Signin, Vec<String>), Halt> {
    let capabilities: Capabilities = fetch_json(
        net,
        INGEST,
        "the commons",
        "/v1/account/near/provision/capabilities",
    )?;
    if !capabilities
        .near_ai_login_ready
        .unwrap_or(capabilities.ready)
    {
        return Err(Halt::Request(
            "the commons is not taking NEAR AI sign-ins".into(),
        ));
    }
    let malformed = |why: &str| Halt::Fetch(FetchError::Malformed(why.to_owned()));
    capabilities
        .witness
        .pinned()
        .map_err(|why| malformed(&why))?;
    https_host(&capabilities.issuer_url)
        .ok_or_else(|| malformed("the issuer's address is not an https host"))?;
    let audience = capabilities.audience.trim();
    if audience.is_empty() || audience.len() > 256 {
        return Err(malformed("the upload audience is blank or too long"));
    }
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|e| Halt::Signin(format!("no loopback listener: {e}")))?;
    let port = listener
        .local_addr()
        .map_err(|e| Halt::Signin(format!("no loopback listener: {e}")))?
        .port();
    let origin = format!("http://127.0.0.1:{port}");
    let callback = percent_encode(&format!("{origin}{CALLBACK}"));
    let urls = PROVIDERS
        .iter()
        .map(|provider| format!("{SIGNIN}/{provider}?frontend_callback={callback}"))
        .collect();
    let state = hex::encode(random::<32>().ok_or_else(no_randomness)?);
    Ok((
        Signin {
            listener,
            origin,
            state,
            capabilities,
        },
        urls,
    ))
}

/// An account [`enrol`] made, and its session.
pub(crate) struct Enrolled {
    pub account: Account,
    pub account_id: String,
    pub anchor_hash: String,
    /// The account session: a bearer for withdrawing.
    pub session: String,
    /// When it ends, RFC 3339.
    pub session_expires_at: String,
}

/// Waits for the sign-in in the browser, then enrols this Mac's device key
/// with the NEAR AI session it gave: the commons' ceremony, started under
/// a PKCE challenge, the device's signature over the ceremony's nonce, and
/// the finish. The NEAR AI session is dropped once the finish is sent.
pub(crate) fn enrol(net: &Net, signin: Signin, device: &Device) -> Result<Enrolled, Halt> {
    let token = signin.token()?;
    let Signin { capabilities, .. } = signin;

    let verifier = URL_SAFE_NO_PAD.encode(random::<32>().ok_or_else(no_randomness)?);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    #[derive(Deserialize)]
    struct Started {
        ceremony_id: String,
        nonce: String,
        expires_at: i64,
    }
    let started: Started = post_json(
        net,
        INGEST,
        "the commons",
        "/v1/account/near-ai/provision/start",
        &json!({
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "device_public_key": device.public_line(),
        }),
        &[],
    )?;
    let now = now()?;
    let nonce: [u8; 32] = STANDARD
        .decode(&started.nonce)
        .ok()
        .and_then(|n| n.try_into().ok())
        .ok_or_else(|| Halt::Reply("the ceremony's nonce is not 32 bytes".into()))?;
    let expires_at = u64::try_from(started.expires_at).unwrap_or(0);
    if started.ceremony_id.is_empty()
        || started.ceremony_id.len() > 128
        || expires_at <= now
        || expires_at > now + CEREMONY_LIFE
    {
        return Err(Halt::Reply(
            "the ceremony is not one the commons' rules allow".into(),
        ));
    }
    let signature = device.sign(&device_bytes(
        &nonce,
        &started.ceremony_id,
        &device.public(),
        &challenge,
        started.expires_at,
    ));
    #[derive(Deserialize)]
    struct Finished {
        access_token: String,
        expires_in_secs: u64,
        account_id: String,
        tenant_id: String,
        device_key_id: String,
        anchor_hash: String,
    }
    let finished: Finished = post_json(
        net,
        INGEST,
        "the commons",
        "/v1/account/near-ai/provision/finish",
        &json!({
            "ceremony_id": started.ceremony_id,
            "code_verifier": verifier,
            "device_public_key": device.public_line(),
            "device_signature": signature,
            "access_token": token,
        }),
        &[&token],
    )?;
    drop(token);
    if !anchored(&finished.tenant_id)
        || finished.device_key_id != device.key_id()
        || !header_safe(&finished.access_token)
    {
        return Err(Halt::Reply(
            "the enrolment is not for this device, or not in an account namespace".into(),
        ));
    }
    Ok(Enrolled {
        account: Account {
            tenant_id: finished.tenant_id,
            device_key_id: finished.device_key_id,
            issuer_url: capabilities.issuer_url,
            audience: capabilities.audience,
            witness: capabilities.witness,
        },
        account_id: finished.account_id,
        anchor_hash: finished.anchor_hash,
        session: finished.access_token,
        session_expires_at: rfc3339(now.saturating_add(finished.expires_in_secs)),
    })
}

/// The bytes the device signs to enrol: the commons' own preimage
/// (`near_ai_provisioning_device_bytes`), each part after its length.
fn device_bytes(
    nonce: &[u8; 32],
    ceremony_id: &str,
    device: &[u8; 32],
    code_challenge: &str,
    expires_at: i64,
) -> Vec<u8> {
    let expiry = expires_at.to_be_bytes();
    let mut bytes = b"trace_commons.near_ai_provisioning_device.v1\n".to_vec();
    for part in [
        &nonce[..],
        ceremony_id.as_bytes(),
        &device[..],
        code_challenge.as_bytes(),
        &expiry[..],
    ] {
        bytes.extend_from_slice(&(part.len() as u64).to_le_bytes());
        bytes.extend_from_slice(part);
    }
    bytes
}

/// A tenant in one of the commons' account namespaces, as its
/// `is_anchored_tenant` reads one.
fn anchored(tenant_id: &str) -> bool {
    ["near-", "nearai-"]
        .iter()
        .any(|prefix| tenant_id.strip_prefix(prefix).is_some_and(lower_hex_64))
}

fn lower_hex_64(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl Signin {
    /// Serves the loopback page until the browser posts the sign-in, and
    /// answers NEAR AI's session token from it. Anything else the browser
    /// asks is answered and waited past.
    fn token(&self) -> Result<String, Halt> {
        for stream in self.listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let _ = stream.set_read_timeout(Some(LOOPBACK_STEP));
            let _ = stream.set_write_timeout(Some(LOOPBACK_STEP));
            if let Some(done) = self.serve(&mut stream) {
                return done;
            }
        }
        Err(Halt::Signin("the loopback listener closed".into()))
    }

    /// One loopback request: the page, the deposit, or a refusal.
    fn serve(&self, stream: &mut TcpStream) -> Option<Result<String, Halt>> {
        let (head, body) = loopback_request(stream)?;
        let mut lines = head.split("\r\n");
        let mut first = lines.next()?.split(' ');
        let (method, target) = (first.next()?, first.next()?);
        let headers: Vec<(String, &str)> = lines
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim()))
            .collect();
        let header = |name: &str| headers.iter().find(|(n, _)| n == name).map(|(_, v)| *v);
        // Only a request made to this listener by its own address: no other
        // name may lead a browser here.
        if header("host") != self.origin.strip_prefix("http://") {
            answer(stream, "403 Forbidden", &[], b"");
            return None;
        }
        match (method, target) {
            ("GET", CALLBACK) => {
                let (page, csp) = self.page();
                answer(
                    stream,
                    "200 OK",
                    &[
                        ("Content-Type", "text/html; charset=utf-8"),
                        ("Content-Security-Policy", &csp),
                        ("Referrer-Policy", "no-referrer"),
                    ],
                    page.as_bytes(),
                );
                None
            }
            ("POST", DEPOSIT) if header("origin") == Some(self.origin.as_str()) => {
                #[derive(Deserialize)]
                struct Deposit {
                    state: String,
                    fragment: String,
                }
                let deposit = serde_json::from_slice::<Deposit>(&body)
                    .ok()
                    .filter(|d| d.state == self.state);
                let Some(deposit) = deposit else {
                    answer(stream, "403 Forbidden", &[], b"");
                    return None;
                };
                answer(stream, "204 No Content", &[], b"");
                Some(fragment_token(&deposit.fragment).map_err(Halt::Signin))
            }
            _ => {
                answer(stream, "404 Not Found", &[], b"");
                None
            }
        }
    }

    /// The page NEAR AI returns the browser to: it posts the address's
    /// fragment, which the browser never sends itself, with this sign-in's
    /// state, and takes the fragment out of the address. Its one script is
    /// allowed by its hash and may reach only this listener.
    fn page(&self) -> (String, String) {
        let script = format!(
            "const m=document.getElementById(\"m\");\
             const f=location.hash.slice(1);\
             history.replaceState(null,\"\",location.pathname);\
             fetch(\"{DEPOSIT}\",{{method:\"POST\",headers:{{\"Content-Type\":\"application/json\"}},\
             body:JSON.stringify({{state:\"{state}\",fragment:f}})}})\
             .then(r=>{{m.textContent=r.ok?\"Signed in. You can close this tab.\":\"Sign-in failed. Try again in Cloak.\";}})\
             .catch(()=>{{m.textContent=\"Sign-in failed. Try again in Cloak.\";}});",
            state = self.state
        );
        let hash = STANDARD.encode(Sha256::digest(script.as_bytes()));
        let page = format!(
            "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">\
             <meta name=\"viewport\" content=\"width=device-width\"><title>Cloak</title>\
             <body style=\"font:15px -apple-system,system-ui,sans-serif;margin:3em\">\
             <p id=\"m\">Signing in…</p><script>{script}</script></body></html>"
        );
        let csp = format!(
            "default-src 'none'; script-src 'sha256-{hash}'; connect-src 'self'; style-src 'unsafe-inline'"
        );
        (page, csp)
    }
}

/// NEAR AI's session token from the sign-in's fragment,
/// `token=<session>&refresh_token=<refresh>`. The refresh token is not read.
fn fragment_token(fragment: &str) -> Result<String, String> {
    let mut token = None;
    for pair in fragment.split('&') {
        match pair.split_once('=') {
            Some(("token", value)) => token = percent_decode(value),
            Some(("error", _)) => return Err("NEAR AI did not sign you in".into()),
            _ => {}
        }
    }
    token
        .filter(|t| !t.is_empty() && t.len() <= 8 << 10 && header_safe(t))
        .ok_or_else(|| "NEAR AI sent no session".into())
}

/// A request the browser made to the listener: its head as text and its
/// body by its length, each within `LOOPBACK_LIMIT`; none for anything else.
fn loopback_request(stream: &mut TcpStream) -> Option<(String, Vec<u8>)> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(at) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
        if data.len() > LOOPBACK_LIMIT {
            return None;
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return None,
            Ok(read) => data.extend_from_slice(&chunk[..read]),
        }
    };
    let head = String::from_utf8(data[..end].to_vec()).ok()?;
    let length = head
        .split("\r\n")
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .map(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(Some(0))?;
    if length > LOOPBACK_LIMIT {
        return None;
    }
    while data.len() < end + 4 + length {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return None,
            Ok(read) => data.extend_from_slice(&chunk[..read]),
        }
    }
    Some((head, data[end + 4..end + 4 + length].to_vec()))
}

/// Writes one answer to the browser and closes.
fn answer(stream: &mut TcpStream, status: &str, headers: &[(&str, &str)], body: &[u8]) {
    let mut head = format!(
        "HTTP/1.1 {status}\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    let _ = stream
        .write_all(head.as_bytes())
        .and_then(|()| stream.write_all(body))
        .and_then(|()| stream.flush());
}

/// A challenge the commons issued: the binding the readied message
/// carries, and when it ends, in seconds since 1970.
pub(crate) struct Admission {
    pub binding: String,
    pub expires_at: u64,
}

/// An upload claim for the account, then the commons' admission challenge
/// under it.
pub(crate) fn ready(
    net: &Net,
    device: &Device,
    account: &Account,
    scopes: &[String],
    uses: &[String],
) -> Result<Admission, Halt> {
    granted(scopes, uses)?;
    let claim = claim(net, device, account, scopes, uses)?;
    #[derive(Deserialize)]
    struct Challenge {
        binding: String,
        expires_at: i64,
    }
    let answer = post(
        net,
        INGEST,
        "the commons",
        "/v1/admission/challenge",
        &[("Authorization", &format!("Bearer {claim}"))],
        &[],
        ANSWER_LIMIT,
        None,
        &[&claim],
    )?;
    let challenge: Challenge = reply_json(&answer)?;
    let now = now()?;
    let expires_at = u64::try_from(challenge.expires_at).unwrap_or(0);
    if !binding_shape(&challenge.binding) || expires_at <= now || expires_at > now + CHALLENGE_LIFE
    {
        return Err(Halt::Reply(
            "the challenge is not one the commons' rules allow".into(),
        ));
    }
    Ok(Admission {
        binding: challenge.binding,
        expires_at,
    })
}

/// A binding as the commons writes one:
/// `tcad1:<account anchor, 64 hex>:<nonce, hex>:<expiry, seconds>`, at most
/// 180 characters.
pub(crate) fn binding_shape(binding: &str) -> bool {
    let parts: Vec<&str> = binding.split(':').collect();
    binding.len() <= 180
        && parts.len() == 4
        && parts[0] == "tcad1"
        && lower_hex_64(parts[1])
        && !parts[2].is_empty()
        && parts[2]
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        && !parts[3].is_empty()
        && parts[3].bytes().all(|b| b.is_ascii_digit())
}

/// An upload claim from the issuer, its request signed by the device key
/// over its exact bytes: for `scopes` and `uses`, or with both empty for
/// the account's full grant, as the status read asks.
fn claim(
    net: &Net,
    device: &Device,
    account: &Account,
    scopes: &[String],
    uses: &[String],
) -> Result<String, Halt> {
    device.of(account)?;
    let issuer = https_host(&account.issuer_url)
        .ok_or_else(|| Halt::Request("the issuer's address is not an https host".into()))?;
    let body = serde_json::to_vec(&json!({
        "schema_version": "ironclaw.trace_upload_claim_request.v1",
        "tenant_id": account.tenant_id,
        "audience": account.audience,
        "consent_scopes": scopes,
        "allowed_uses": uses,
        "subject": subject(&account.device_key_id),
        "requested_at": rfc3339(now()?),
    }))
    .expect("JSON serializes");
    let signature = device.sign(&body);
    let answer = post(
        net,
        &issuer,
        "the issuer",
        "/v1/trace-upload-claim",
        &[
            ("Content-Type", "application/json"),
            ("x-trace-device-key-id", &account.device_key_id),
            ("x-trace-device-signature", &signature),
        ],
        &body,
        ANSWER_LIMIT,
        None,
        &[],
    )
    .map_err(|halt| Halt::Claim(halt.to_string()))?;
    #[derive(Deserialize)]
    struct Claimed {
        access_token: String,
    }
    let claimed: Claimed = reply_json(&answer).map_err(|halt| Halt::Claim(halt.to_string()))?;
    match header_safe(&claimed.access_token) {
        true => Ok(claimed.access_token),
        false => Err(Halt::Claim(
            "the issuer's claim is not one a header can carry".into(),
        )),
    }
}

/// Refuses a grant the commons does not know: every scope and use by its
/// name, each once, and debugging and evaluation always among them.
fn granted(scopes: &[String], uses: &[String]) -> Result<(), Halt> {
    let known = |names: &[String], all: &[&str]| {
        names.iter().all(|n| all.contains(&n.as_str()))
            && names
                .iter()
                .enumerate()
                .all(|(at, n)| !names[..at].contains(n))
    };
    if known(scopes, &SCOPES)
        && known(uses, &USES)
        && scopes.iter().any(|s| s == SCOPES[0])
        && uses.iter().any(|u| u == "debugging")
    {
        Ok(())
    } else {
        Err(Halt::Request(
            "the data uses are not ones the commons grants".into(),
        ))
    }
}

/// NEAR's signed receipt for a readied exchange, fetched on a new
/// connection to its gateway that must show the certificate key `pin`, and
/// checked: Ed25519, signed by the model, over the model's name and the
/// SHA-256 of `request_body` and `response_body`, the exact bytes sent and
/// received. The receipt as the witness takes it, or why there is none.
#[allow(clippy::too_many_arguments)]
pub(crate) fn receipt(
    route: &Route,
    roots: &RootCertStore,
    pin: &[u8; 32],
    model: &str,
    api_key: &str,
    reply: &Value,
    request_body: &[u8],
    response_body: &[u8],
) -> Result<Value, String> {
    let id = reply
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| opaque(id))
        .ok_or("the reply names no completion")?;
    let (mut tls, spki_sha256) =
        connect(route, NEAR, roots).map_err(|e| format!("connecting: {e}"))?;
    if spki_sha256 != *pin {
        return Err("NEAR's gateway showed another certificate key".into());
    }
    let authorization = format!("Bearer {api_key}");
    let path = format!(
        "/v1/signature/{id}?model={}&signing_algo=ed25519",
        percent_encode(model)
    );
    let answer = request(
        &mut tls,
        "GET",
        NEAR,
        &path,
        &[
            ("Authorization", &authorization),
            ("Accept", "application/json"),
        ],
        None,
        ANSWER_LIMIT,
    )
    .map_err(|e| format!("fetching: {e}"))?;
    if answer.status != 200 {
        return Err(format!("NEAR answered {}", answer.status));
    }
    let whole: Value = serde_json::from_slice(&answer.body).map_err(|_| "it is not JSON")?;
    let held = whole
        .get("receipt")
        .filter(|r| r.is_object())
        .unwrap_or(&whole);
    #[derive(Deserialize)]
    struct Signed {
        text: String,
        signature: String,
        signing_address: String,
        signing_algo: String,
        signature_kind: Option<String>,
    }
    let signed: Signed =
        serde_json::from_value(held.clone()).map_err(|_| "it is not a receipt".to_owned())?;
    if signed.signing_algo != "ed25519" || signed.signature_kind.as_deref() != Some("provider_tee")
    {
        return Err("it is not the model's own Ed25519 receipt".into());
    }
    let key = hex::decode(&signed.signing_address)
        .ok()
        .filter(|k| k.len() == 32)
        .ok_or("its key is not 32 bytes of hex")?;
    let signature = hex::decode(
        signed
            .signature
            .strip_prefix("0x")
            .unwrap_or(&signed.signature),
    )
    .ok()
    .filter(|s| s.len() == 64)
    .ok_or("its signature is not 64 bytes of hex")?;
    UnparsedPublicKey::new(&ED25519, &key)
        .verify(signed.text.as_bytes(), &signature)
        .map_err(|_| "its signature does not verify")?;
    let parts: Vec<&str> = signed.text.split(':').collect();
    let hashes = match parts[..] {
        [named, request_hex, response_hex] if named == model => (request_hex, response_hex),
        [request_hex, response_hex] => (request_hex, response_hex),
        _ => return Err("it is for another model, or not for one exchange".into()),
    };
    let same = |text: &str, body: &[u8]| {
        hex::decode(text).is_ok_and(|digest| digest == Sha256::digest(body).as_slice())
    };
    if !same(hashes.0, request_body) || !same(hashes.1, response_body) {
        return Err("it covers other bytes than this exchange".into());
    }
    Ok(json!({
        "text": signed.text,
        "signature": signed.signature,
        "signing_address": signed.signing_address,
        "signing_algo": "ed25519",
        "signature_kind": "provider_tee",
    }))
}

/// A readied exchange, as the readied message gave it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Exchange {
    /// The request body as it was sent, and the reply body as it came, in
    /// standard base64.
    pub request: String,
    pub response: String,
    /// NEAR's receipt for the two, as [`receipt`] gave it.
    pub receipt: Value,
}

/// The witness's answer: the envelope's bytes exactly, and its headers.
pub(crate) struct Reviewed {
    pub envelope: Vec<u8>,
    pub certificate: String,
    pub signature: String,
    pub evidence: String,
    pub evidence_signature: String,
    pub submission_id: String,
    pub trace_id: String,
}

/// Proof before sending, for the witness: a quote is fetched under a fresh
/// nonce and checked against the pin in `account` (Intel's rules, the
/// report data tying it to the signing address and the nonce, and an
/// accepted set of measurements), and only once it passes is the exchange
/// sent to it, as one raw contribution, for redaction. A quote that does
/// not pass stops the review, and nothing is sent.
pub(crate) fn review(
    net: &Net,
    kept: &mut Kept,
    account: &Account,
    scopes: &[String],
    uses: &[String],
    exchange: &Exchange,
    version: &str,
) -> Result<Reviewed, Halt> {
    granted(scopes, uses)?;
    let witness = account.witness.pinned().map_err(Halt::Request)?;
    let text = |b64: &str| {
        STANDARD
            .decode(b64)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .ok_or_else(|| Halt::Request("the exchange is not base64 of text".into()))
    };
    let (request_body, response_body) = (text(&exchange.request)?, text(&exchange.response)?);
    if !exchange.receipt.is_object() {
        return Err(Halt::Request("the exchange has no receipt".into()));
    }
    let contribution = contribution(account, scopes, &request_body, &response_body, version)?;
    let body = serde_json::to_vec(&json!({
        "raw_contribution": contribution.raw,
        "granted_scopes": scopes,
        "granted_uses": uses,
        "inference_receipt": exchange.receipt,
    }))
    .expect("JSON serializes");
    if body.len() > WITNESS_LIMIT {
        return Err(Halt::Request("the chat is too long for the witness".into()));
    }

    let nonce = random::<32>().ok_or_else(no_randomness)?;
    #[derive(Deserialize)]
    struct Quoted {
        quote_hex: String,
    }
    let quoted: Quoted = fetch_json(
        net,
        &witness.host,
        "the witness",
        &format!("/v1/attestation?nonce={}", hex::encode(nonce)),
    )?;
    let quote = hex::decode(&quoted.quote_hex).map_err(|_| {
        Halt::Fetch(FetchError::Malformed(
            "the witness's quote is not hex".into(),
        ))
    })?;
    let now = now()?;
    let collateral = kept
        .collateral_for_quote(&net.intel, &quote, now)
        .map_err(Halt::Fetch)?;
    let mut report_data = [0u8; 64];
    report_data[..8].copy_from_slice(WITNESS_TAG);
    report_data[8..28].copy_from_slice(&witness.address);
    report_data[28..60].copy_from_slice(&nonce);
    verify_witness(&quote, &report_data, &witness.sets, collateral, now).map_err(Halt::Refused)?;

    // Only now, the witness's enclave having passed, is the exchange sent.
    let answer = post(
        net,
        &witness.host,
        "the witness",
        "/v1/witness/admission",
        &[("Content-Type", "application/json")],
        &body,
        ENVELOPE_LIMIT,
        Some(WITNESS_WAIT),
        &[],
    )?;
    let header = |name: &str| {
        answer
            .header(name)
            .filter(|value| header_safe(value))
            .map(str::to_owned)
            .ok_or_else(|| Halt::Reply(format!("the witness sent no {name}")))
    };
    Ok(Reviewed {
        certificate: header("x-trace-witness-certificate")?,
        signature: header("x-trace-witness-signature")?,
        evidence: header("x-trace-admission-evidence")?,
        evidence_signature: header("x-trace-admission-signature")?,
        envelope: answer.body,
        submission_id: contribution.submission_id,
        trace_id: contribution.trace_id,
    })
}

/// One raw contribution and the ids it was made with.
struct Contribution {
    raw: Value,
    submission_id: String,
    trace_id: String,
}

/// The exchange as the commons' raw contribution, in the shape its own
/// client gives the witness for one final call (`final_call_witness_input`,
/// with the exchange appended last): no session history, the request and
/// reply bodies as they went, and the account's pseudonymous ids.
fn contribution(
    account: &Account,
    scopes: &[String],
    request_body: &str,
    response_body: &str,
    version: &str,
) -> Result<Contribution, Halt> {
    if version.is_empty() || version.len() > 64 || !version.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(Halt::Request(
            "the version is not one a trace can name".into(),
        ));
    }
    let at = rfc3339(now()?);
    let (submission_id, trace_id) = (uuid()?, uuid()?);
    let raw = json!({
        "trace_id": trace_id,
        "submission_id": submission_id,
        "created_at": at,
        "ironclaw": {
            "version": version,
            "feature_flags": {"agent": AGENT, "agent_version": version, "cwd_hash": "unknown"},
            "channel": "other",
        },
        "consent": {
            "policy_version": POLICY_VERSION,
            "scopes": scopes,
            "message_text_included": false,
            "tool_payloads_included": true,
            "correction_included": false,
            "routing_metadata_included": false,
            "revocable": true,
        },
        "contributor": {
            "pseudonymous_contributor_id": subject(&account.device_key_id),
            "tenant_scope_ref": account.tenant_id,
            "revocation_handle": uuid()?,
        },
        "events": [{
            "event_id": uuid()?,
            "event_type": "http_exchange",
            "timestamp": at,
            "content": response_body,
            "structured_payload": {
                "request": {"method": "POST", "body": request_body},
                "response": {"status": 200, "stream_restarted": false},
            },
            "tool_name": "http",
            "latency_ms": null,
            "token_counts": null,
            "cost_usd": null,
            "success": true,
        }],
        "outcome": {"user_feedback": "none", "task_success": "unknown"},
        "replay": {
            "replayable": false,
            "replay_notes": ["Final-call evidence only; session history and tool execution are not covered."],
        },
        "embedding_analysis": null,
        "value": {"submission_score": 0.0, "credit_points_pending": 0.0},
    });
    Ok(Contribution {
        raw,
        submission_id,
        trace_id,
    })
}

/// The witness's envelope and headers, as the person was shown them.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Envelope {
    /// The envelope's bytes, in standard base64.
    pub body: String,
    pub certificate: String,
    pub signature: String,
    pub evidence: String,
    pub evidence_signature: String,
}

/// Uploads the envelope under a new claim: its bytes exactly, with the
/// witness's four headers. The commons' answer as it came.
pub(crate) fn upload(
    net: &Net,
    device: &Device,
    account: &Account,
    scopes: &[String],
    uses: &[String],
    envelope: &Envelope,
) -> Result<Value, Halt> {
    granted(scopes, uses)?;
    let body = STANDARD
        .decode(&envelope.body)
        .map_err(|_| Halt::Request("the envelope is not base64".into()))?;
    let headers = [
        &envelope.certificate,
        &envelope.signature,
        &envelope.evidence,
        &envelope.evidence_signature,
    ];
    if !headers.iter().all(|value| header_safe(value)) {
        return Err(Halt::Request(
            "the witness's headers are not ones a request can carry".into(),
        ));
    }
    let claim = claim(net, device, account, scopes, uses)?;
    let answer = post(
        net,
        INGEST,
        "the commons",
        "/v1/traces",
        &[
            ("Authorization", &format!("Bearer {claim}")),
            ("Content-Type", "application/json"),
            ("x-trace-witness-certificate", &envelope.certificate),
            ("x-trace-witness-signature", &envelope.signature),
            ("x-trace-admission-evidence", &envelope.evidence),
            ("x-trace-admission-signature", &envelope.evidence_signature),
        ],
        &body,
        ANSWER_LIMIT,
        None,
        &[&claim],
    )?;
    reply_json(&answer)
}

/// The commons' status of each submission, read under a claim for the
/// account's full grant; its answer as it came.
pub(crate) fn status(
    net: &Net,
    device: &Device,
    account: &Account,
    submissions: &[String],
) -> Result<Value, Halt> {
    if submissions.is_empty()
        || submissions.len() > 100
        || !submissions.iter().all(|s| uuid_shape(s))
    {
        return Err(Halt::Request(
            "the submissions are not ones the commons names".into(),
        ));
    }
    let claim = claim(net, device, account, &[], &[])?;
    let body = serde_json::to_vec(&json!({ "submission_ids": submissions })).expect("serializes");
    let answer = post(
        net,
        INGEST,
        "the commons",
        "/v1/contributors/me/submission-status",
        &[
            ("Authorization", &format!("Bearer {claim}")),
            ("Content-Type", "application/json"),
        ],
        &body,
        ANSWER_LIMIT,
        None,
        &[&claim],
    )?;
    reply_json(&answer)
}

/// The account session after a withdrawal, when the commons renewed it.
pub(crate) struct Withdrawn {
    pub session: Option<String>,
    /// RFC 3339, as the commons sent it.
    pub session_expires_at: Option<String>,
}

/// Withdraws one submission under the account session.
pub(crate) fn withdraw(net: &Net, session: &str, submission: &str) -> Result<Withdrawn, Halt> {
    if !header_safe(session) || !uuid_shape(submission) {
        return Err(Halt::Request(
            "the session or the submission is not one the commons issues".into(),
        ));
    }
    let answer = post(
        net,
        INGEST,
        "the commons",
        &format!("/v1/account/traces/{submission}/withdraw"),
        &[("Authorization", &format!("Bearer {session}"))],
        &[],
        ANSWER_LIMIT,
        None,
        &[session],
    )?;
    let renewed = |name: &str| {
        answer
            .header(name)
            .filter(|value| header_safe(value))
            .map(str::to_owned)
    };
    let session = renewed("x-trace-commons-session-token");
    Ok(Withdrawn {
        session_expires_at: session
            .as_ref()
            .and(renewed("x-trace-commons-session-expires-at")),
        session,
    })
}

/// A GET that must be answered 200, read as JSON.
fn fetch_json<T: DeserializeOwned>(
    net: &Net,
    host: &str,
    who: &'static str,
    path: &str,
) -> Result<T, Halt> {
    let (mut tls, _) = connect(&net.route, host, net.roots).map_err(Halt::Fetch)?;
    let answer = request(
        &mut tls,
        "GET",
        host,
        path,
        &[("Accept", "application/json")],
        None,
        ANSWER_LIMIT,
    )
    .map_err(Halt::Fetch)?;
    if answer.status != 200 {
        return Err(Halt::Fetch(FetchError::Status {
            host: who,
            code: answer.status,
            detail: answer.detail(),
        }));
    }
    serde_json::from_slice(&answer.body)
        .map_err(|_| Halt::Fetch(FetchError::Malformed(format!("{who}'s answer"))))
}

/// A POST of JSON, answered as JSON.
fn post_json<T: DeserializeOwned>(
    net: &Net,
    host: &str,
    who: &'static str,
    path: &str,
    body: &Value,
    secrets: &[&str],
) -> Result<T, Halt> {
    let body = serde_json::to_vec(body).expect("JSON serializes");
    let answer = post(
        net,
        host,
        who,
        path,
        &[("Content-Type", "application/json")],
        &body,
        ANSWER_LIMIT,
        None,
        secrets,
    )?;
    reply_json(&answer)
}

/// One POST on a connection of its own, which must be answered 200 to 299;
/// `wait` for the answer when it is longer than a step. Each of `secrets`
/// is taken out of a refusal's words before they are cut to their start.
#[allow(clippy::too_many_arguments)]
fn post(
    net: &Net,
    host: &str,
    who: &'static str,
    path: &str,
    headers: &[(&str, &str)],
    body: &[u8],
    limit: usize,
    wait: Option<Duration>,
    secrets: &[&str],
) -> Result<Answer, Halt> {
    let (mut tls, _) = connect(&net.route, host, net.roots).map_err(Halt::Connect)?;
    if let Some(wait) = wait {
        tls.sock
            .set_read_timeout(Some(wait))
            .map_err(|e| Halt::Connect(e.into()))?;
    }
    let mut answer =
        request(&mut tls, "POST", host, path, headers, Some(body), limit).map_err(Halt::Send)?;
    if !(200..300).contains(&answer.status) {
        let mut words = String::from_utf8_lossy(&answer.body).into_owned();
        for secret in secrets.iter().filter(|s| !s.is_empty()) {
            words = words.replace(secret, "[withheld]");
        }
        answer.body = words.into_bytes();
        return Err(Halt::Status {
            who,
            code: answer.status,
            detail: answer.detail(),
        });
    }
    Ok(answer)
}

fn reply_json<T: DeserializeOwned>(answer: &Answer) -> Result<T, Halt> {
    serde_json::from_slice(&answer.body)
        .map_err(|_| Halt::Reply("it is not the JSON that was asked for".into()))
}

/// The host of an address that is `https://` and a host name alone.
fn https_host(url: &str) -> Option<String> {
    let host = url.strip_prefix("https://")?;
    let host = host.strip_suffix('/').unwrap_or(host);
    (!host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.'))
    .then(|| host.to_ascii_lowercase())
}

/// Text a header can carry: printable ASCII, no line breaks.
fn header_safe(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| (0x20..0x7f).contains(&b))
}

/// An id NEAR or the commons gives that can go in a path as it is.
fn opaque(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 256
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn uuid_shape(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(at, b)| match at {
            8 | 13 | 18 | 23 => b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

/// A random version 4 UUID.
fn uuid() -> Result<String, Halt> {
    let mut bytes = random::<16>().ok_or_else(no_randomness)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// `seconds` since 1970 as an RFC 3339 time in UTC, to the second.
fn rfc3339(seconds: u64) -> String {
    // Days to a civil date, after Howard Hinnant's `civil_from_days`.
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    let second = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        second / 3_600,
        second % 3_600 / 60,
        second % 60
    )
}

fn now() -> Result<u64, Halt> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Halt::Request("the clock reads before 1970".into()))?
        .as_secs())
}

fn no_randomness() -> Halt {
    Halt::Request("the system gave no randomness".into())
}

/// Sharing's checks, against the stand-in of `stand_in.rs`: every host is a
/// server on this machine behind a socket file of its own, and nothing
/// leaves it.
#[cfg(test)]
mod checks {
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    use ring::signature::{UnparsedPublicKey, ED25519};
    use serde_json::{json, Value};

    use super::{subject, Device, WITNESS_TAG};
    use crate::stand_in::{self, StandIn};
    use crate::verify::{family, verify_witness, witness_set};
    use crate::{Collateral, Helper, Kept, Pins, Refusal, Who};

    /// A device key's seed, made for these checks.
    const SEED: [u8; 32] = [9; 32];

    fn device() -> Device {
        Device::from_line(&STANDARD.encode(SEED)).unwrap()
    }

    fn helper(kept: Kept) -> Helper {
        let pins = Pins {
            gateway: Vec::new(),
            model: Vec::new(),
        };
        Helper::with_roots(pins, kept, stand_in::roots())
    }

    /// An enrolled account for the device, as `enrol` hands it back.
    fn account() -> Value {
        json!({
            "tenant_id": format!("near-{}", "ab".repeat(32)),
            "device_key_id": device().key_id(),
            "issuer_url": "https://issuer.tracecommons.ai",
            "audience": "trace-commons-ingest",
            "witness": {
                "url": "https://witness.tracecommons.ai",
                "signing_address": format!("0x{}", "11".repeat(20)),
                "expected_measurements": [format!("mrtd={}", "00".repeat(48))]
            }
        })
    }

    fn answer(helper: &mut Helper, line: &Value) -> Value {
        serde_json::from_str(&helper.respond(line.to_string().as_bytes())).unwrap()
    }

    /// Ruling 2: nothing raw goes to a witness whose quote does not pass.
    /// The stand-in witness answers the attestation read with a real quote
    /// that is not a witness's, the gateway's in tests/fixtures/report.json,
    /// and Intel's real collateral for it is held, so nothing is fetched
    /// from Intel. That quote passes Intel's own check at the time it was
    /// fetched; its report data is not the witness's tag, address and our
    /// nonce, so the review stops and the exchange is never sent.
    #[test]
    fn an_unverified_witness_quote_sends_nothing() {
        let report: Value =
            serde_json::from_slice(include_bytes!("../tests/fixtures/report.json")).unwrap();
        let quote_hex = report["gateway_attestation"]["intel_quote"]
            .as_str()
            .unwrap()
            .to_owned();
        let collateral: Vec<Collateral> =
            serde_json::from_str(include_str!("../tests/fixtures/collateral.json")).unwrap();
        let fetched_at: u64 = include_str!("../tests/fixtures/fetched-at.txt")
            .trim()
            .parse()
            .unwrap();

        let quote = hex::decode(&quote_hex).unwrap();
        let (fmspc, ca) = family(&quote).unwrap();
        let held = collateral
            .iter()
            .find(|c| c.fmspc == fmspc && c.ca == ca)
            .unwrap();
        let mut report_data = [0u8; 64];
        report_data[..8].copy_from_slice(WITNESS_TAG);
        let accepted = [witness_set(&format!("mrtd={}", "00".repeat(48))).unwrap()];
        assert_eq!(
            verify_witness(&quote, &report_data, &accepted, held, fetched_at),
            Err(Refusal::ReportData(Who::Witness))
        );

        let stand_in = StandIn::start(move |seen, _| {
            match (seen.host.as_str(), seen.path.split('?').next().unwrap()) {
                ("witness.tracecommons.ai", "/v1/attestation") => {
                    stand_in::json(200, json!({ "quote_hex": quote_hex }))
                }
                _ => stand_in::json(404, json!({})),
            }
        });
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let mut kept = Kept::new(Duration::from_secs(3600)).unwrap();
        kept.hold_collateral(collateral, now);
        let mut helper = helper(kept);
        let review = json!({
            "request": "review",
            "route": stand_in.route(),
            "account": account(),
            "scopes": ["debugging_evaluation"],
            "uses": ["debugging", "evaluation", "aggregate_analytics"],
            "exchange": {
                "request": STANDARD.encode(r#"{"model":"z-ai/glm-5.3-flash","messages":[{"role":"user","content":"ping"}]}"#),
                "response": STANDARD.encode(r#"{"id":"chatcmpl-1","choices":[]}"#),
                "receipt": {"text": "stand-in"}
            },
            "version": "1.0"
        });
        let answer = answer(&mut helper, &review);
        assert_eq!(answer["answer"], "stopped", "{answer}");
        assert_eq!(answer["stop"], "refused");
        assert_eq!(answer["sent"], false);
        let seen = stand_in.seen();
        assert_eq!(seen.len(), 1, "{seen:?}");
        assert_eq!(
            (seen[0].host.as_str(), seen[0].method.as_str()),
            ("witness.tracecommons.ai", "GET")
        );
        let nonce = seen[0].path.strip_prefix("/v1/attestation?nonce=").unwrap();
        assert!(nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(seen[0].body.is_empty());
    }

    /// The upload is the envelope the person was shown, byte for byte. The
    /// envelope here is JSON as no encoder would write it again (spaces, a
    /// tab, keys out of order, an escape beside its own letter, a trailing
    /// zero, a line end), so any reading and rewriting of it would show.
    /// The stand-in issuer gives a claim for a request the device key
    /// signed; the stand-in ingest sees exactly the envelope's bytes, under
    /// that claim, with the witness's four headers as given.
    #[test]
    fn the_upload_is_the_envelope_shown_byte_for_byte() {
        let stand_in = StandIn::start(|seen, _| match (seen.host.as_str(), seen.path.as_str()) {
            ("issuer.tracecommons.ai", "/v1/trace-upload-claim") => {
                stand_in::json(200, json!({ "access_token": "claim-for-upload" }))
            }
            ("ingest.tracecommons.ai", "/v1/traces") => {
                stand_in::json(202, json!({ "status": "received" }))
            }
            _ => stand_in::json(404, json!({})),
        });
        let envelope = "{ \"z\": 1,\t\"a\" : \"caf\\u00e9 café\" , \"n\": 1.50 }\r\n".as_bytes();
        let mut helper = helper(Kept::new(Duration::from_secs(3600)).unwrap());
        let upload = json!({
            "request": "upload",
            "route": stand_in.route(),
            "device_key": STANDARD.encode(SEED),
            "account": account(),
            "scopes": ["debugging_evaluation", "benchmark_only"],
            "uses": ["debugging", "evaluation", "benchmark_generation", "aggregate_analytics"],
            "envelope": {
                "body": STANDARD.encode(envelope),
                "certificate": "witness-certificate",
                "signature": "witness-signature",
                "evidence": "admission-evidence",
                "evidence_signature": "admission-signature"
            }
        });
        let answer = answer(&mut helper, &upload);
        assert_eq!(answer["answer"], "uploaded", "{answer}");
        assert_eq!(answer["sent"], true);
        assert_eq!(answer["commons"], json!({ "status": "received" }));

        let seen = stand_in.seen();
        assert_eq!(seen.len(), 2, "{seen:?}");
        let (claim, traces) = (&seen[0], &seen[1]);
        assert_eq!(
            (
                claim.host.as_str(),
                claim.method.as_str(),
                claim.path.as_str()
            ),
            ("issuer.tracecommons.ai", "POST", "/v1/trace-upload-claim")
        );
        let device = device();
        assert_eq!(
            claim.header("x-trace-device-key-id"),
            Some(device.key_id().as_str())
        );
        let signature = STANDARD
            .decode(claim.header("x-trace-device-signature").unwrap())
            .unwrap();
        UnparsedPublicKey::new(&ED25519, device.public())
            .verify(&claim.body, &signature)
            .unwrap();
        let asked: Value = serde_json::from_slice(&claim.body).unwrap();
        assert_eq!(asked["subject"], subject(&device.key_id()));
        assert_eq!(asked["consent_scopes"], upload["scopes"]);
        assert_eq!(asked["allowed_uses"], upload["uses"]);

        assert_eq!(
            (
                traces.host.as_str(),
                traces.method.as_str(),
                traces.path.as_str()
            ),
            ("ingest.tracecommons.ai", "POST", "/v1/traces")
        );
        assert_eq!(traces.body, envelope);
        assert_eq!(
            traces.header("authorization"),
            Some("Bearer claim-for-upload")
        );
        for (name, value) in [
            ("x-trace-witness-certificate", "witness-certificate"),
            ("x-trace-witness-signature", "witness-signature"),
            ("x-trace-admission-evidence", "admission-evidence"),
            ("x-trace-admission-signature", "admission-signature"),
        ] {
            assert_eq!(traces.header(name), Some(value), "{name}");
        }
    }
}
