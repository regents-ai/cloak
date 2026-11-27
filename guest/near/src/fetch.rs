//! The network half: the report and Intel Trust Authority's tokens from
//! NEAR's gateway, Intel's collateral, and the keys Intel Trust Authority
//! signs with, every connection on the caller's route (through Tor's SOCKS5
//! port, at a TCP address or a socket file, names resolved by Tor; or
//! direct, names looked up by the system) with ordinary certificate checks
//! against Mozilla's roots. The chat request (`chat.rs`) uses the same
//! connection and HTTP code.

use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use der::{Decode, Encode};
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};

use crate::{Collateral, Proxy, QuoteCollateralV3, Route, SocksAddr};

pub(crate) const NEAR: &str = "cloud-api.near.ai";
const INTEL_API: &str = "api.trustedservices.intel.com";
const INTEL_CERTS: &str = "certificates.trustedservices.intel.com";
/// Intel Trust Authority's portal, which publishes its signing keys. Pinned
/// here: the `jku` in its tokens and NEAR's `jwks_url` are not followed.
const ITA_PORTAL: &str = "portal.trustauthority.intel.com";
/// The largest report taken; live ones are about 245 KB for each of the
/// model's servers, and three were seen.
const REPORT_LIMIT: usize = 4 << 20;
/// The largest answer taken from Intel, and NEAR's answer of Intel Trust
/// Authority's tokens. On 19 November Intel's were a few KB, its key list
/// about 12 KB, and NEAR's tokens on eight GPUs about 36 KB.
const INTEL_LIMIT: usize = 1 << 20;
const HEAD_LIMIT: usize = 64 << 10;
/// Each step, on either route: connecting, the handshake, every read and
/// write.
const STEP: Duration = Duration::from_secs(60);
/// Tor circuits one connection may try: a new one each time the last could
/// not be connected through (the SOCKS step or the TLS handshake failed).
const PATHS: u32 = 3;
/// Asks for Intel Trust Authority's tokens from NEAR, at most: NEAR's own
/// call to Intel fails at times, and NEAR then answers 502.
const TOKEN_ASKS: u32 = 3;
/// Says nothing about Cloak.
const USER_AGENT: &str = "curl/8.7.1";

/// Negotiated TLS session parameters observed directly on `rustls::ClientConnection`.
/// Held strictly locally so Cloak can verify whether the gateway actually negotiated
/// hybrid post-quantum key exchange (`X25519MLKEM768`) vs. classical ECC.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TlsSession {
    pub protocol: String,
    pub cipher_suite: String,
    pub key_exchange: String,
}

impl TlsSession {
    /// True when the negotiated key exchange includes an ML-KEM hybrid group.
    pub fn is_hybrid_pqc(&self) -> bool {
        self.key_exchange.to_ascii_uppercase().contains("MLKEM")
    }
}

/// A report as it came, with what it must be checked against.
#[derive(Clone, Debug)]
pub struct Fetched {
    /// The report's bytes, unparsed.
    pub report: Vec<u8>,
    /// The nonce sent with the request.
    pub nonce: [u8; 32],
    /// SHA-256 of the gateway certificate's SubjectPublicKeyInfo, as seen on
    /// the connection the report came on.
    pub spki_sha256: [u8; 32],
    /// Actual TLS session parameters negotiated on the report connection.
    pub tls: TlsSession,
}

#[derive(Debug)]
pub enum FetchError {
    /// The proxy, the connection, TLS or the certificate check failed.
    Connect(String),
    /// The gateway is busy: it asks for the request again after this many
    /// seconds.
    Busy { retry_after: Option<u64> },
    /// A status other than 200, with the start of the body.
    Status {
        host: &'static str,
        code: u16,
        detail: String,
    },
    /// An answer that is not what the request asked for.
    Malformed(String),
}

impl fmt::Display for FetchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FetchError::Connect(detail) => write!(f, "could not connect: {detail}"),
            FetchError::Busy {
                retry_after: Some(seconds),
            } => {
                write!(f, "the gateway is busy and asks again in {seconds} s")
            }
            FetchError::Busy { retry_after: None } => write!(f, "the gateway is busy"),
            FetchError::Status { host, code, detail } => {
                write!(f, "{host} answered {code}: {detail}")
            }
            FetchError::Malformed(detail) => write!(f, "unexpected answer: {detail}"),
        }
    }
}

impl std::error::Error for FetchError {}

impl From<io::Error> for FetchError {
    fn from(error: io::Error) -> Self {
        FetchError::Connect(error.to_string())
    }
}

/// Asks NEAR's gateway, with no account key, for `model`'s attestation
/// report under a fresh nonce, on one connection whose certificate key it
/// records.
pub fn fetch_report(route: &Route, model: &str) -> Result<Fetched, FetchError> {
    let nonce =
        crate::random().ok_or_else(|| FetchError::Connect("no randomness for the nonce".into()))?;
    let (mut tls, spki_sha256, tls_session) = connect(route, NEAR, &mozilla())?;
    let path = format!(
        "/v1/attestation/report?model={}&provider=near&signing_algo=ed25519&include_tls_fingerprint=true&nonce={}",
        percent_encode(model),
        hex::encode(nonce)
    );
    let answer = request(
        &mut tls,
        "GET",
        NEAR,
        &path,
        &[("Accept", "application/json"), ("x-no-aliasing", "true")],
        None,
        REPORT_LIMIT,
    )?;
    match answer.status {
        200 => Ok(Fetched {
            report: answer.body,
            nonce,
            spki_sha256,
            tls: tls_session,
        }),
        429 => Err(FetchError::Busy {
            retry_after: answer
                .header("retry-after")
                .and_then(|v| v.trim().parse().ok()),
        }),
        code => Err(FetchError::Status {
            host: NEAR,
            code,
            detail: answer.detail(),
        }),
    }
}

/// Fetches from Intel's own servers the collateral for every platform family
/// the report's quotes name.
pub fn fetch_collateral(route: &Route, report: &[u8]) -> Result<Vec<Collateral>, FetchError> {
    families(report)?
        .into_iter()
        .map(|(fmspc, ca)| family_collateral(route, fmspc, ca))
        .collect()
}

/// The platform family, FMSPC and issuing CA, of every quote in a report.
pub(crate) fn families(report: &[u8]) -> Result<BTreeSet<(String, String)>, FetchError> {
    crate::verify::quotes(report)
        .map_err(|r| FetchError::Malformed(r.to_string()))?
        .iter()
        .map(|quote| crate::verify::family(quote).map_err(FetchError::Malformed))
        .collect()
}

fn family_collateral(route: &Route, fmspc: String, ca: String) -> Result<Collateral, FetchError> {
    let pck = intel(
        route,
        INTEL_API,
        &format!("/sgx/certification/v4/pckcrl?ca={ca}&encoding=der"),
    )?;
    let tcb = intel(
        route,
        INTEL_API,
        &format!("/tdx/certification/v4/tcb?fmspc={fmspc}&update=standard"),
    )?;
    let qe = intel(
        route,
        INTEL_API,
        "/tdx/certification/v4/qe/identity?update=standard",
    )?;
    let root = intel(route, INTEL_CERTS, "/IntelSGXRootCA.der")?;
    let (tcb_info, tcb_info_signature) = signed(&tcb.body, "tcbInfo")?;
    let (qe_identity, qe_identity_signature) = signed(&qe.body, "enclaveIdentity")?;
    Ok(Collateral {
        fmspc,
        ca,
        intel: QuoteCollateralV3 {
            pck_crl_issuer_chain: pck.chain("sgx-pck-crl-issuer-chain")?,
            root_ca_crl: root.body,
            pck_crl: pck.body,
            tcb_info_issuer_chain: tcb.chain("tcb-info-issuer-chain")?,
            tcb_info,
            tcb_info_signature,
            qe_identity_issuer_chain: qe.chain("sgx-enclave-identity-issuer-chain")?,
            qe_identity,
            qe_identity_signature,
            // The platform's certificate chain is always the one in its quote.
            pck_certificate_chain: None,
        },
    })
}

/// Asks NEAR's gateway, with no account key and on a connection of its own,
/// for the tokens Intel Trust Authority signs on the gateway's quote and on
/// one of `model`'s servers' GPUs, under `nonce`, the report's; NEAR's
/// answer as it came. A 502, NEAR's own call to Intel having failed, is
/// asked again under the same nonce, `TOKEN_ASKS` asks at most; no other
/// answer is.
pub fn fetch_ita_tokens(
    route: &Route,
    model: &str,
    nonce: &[u8; 32],
) -> Result<Vec<u8>, FetchError> {
    let path = format!(
        "/v1/attestation/ita-token?model={}&signing_algo=ed25519&include_tls_fingerprint=true&nonce={}",
        percent_encode(model),
        hex::encode(nonce)
    );
    let mut asks = 1;
    loop {
        let user_buf;
        let attempt_route = match route {
            Route::Direct => route.clone(),
            Route::Tor(proxy) => {
                user_buf = if asks == 1 {
                    proxy.user.to_owned()
                } else {
                    format!("{}-tok-{asks}", proxy.user)
                };
                Route::Tor(Proxy {
                    user: &user_buf,
                    ..*proxy
                })
            }
        };
        match get(
            &attempt_route,
            NEAR,
            &path,
            &[("Accept", "application/json"), ("x-no-aliasing", "true")],
            INTEL_LIMIT,
        ) {
            Err(FetchError::Status { code, .. })
                if matches!(code, 403 | 429 | 502 | 503 | 504) && asks < TOKEN_ASKS =>
            {
                asks += 1
            }
            Err(FetchError::Malformed(_)) if asks < TOKEN_ASKS => asks += 1,
            answer => return Ok(answer?.body),
        }
    }
}

/// The list of keys Intel Trust Authority signs its tokens with, from its
/// portal, as it came.
pub fn fetch_ita_keys(route: &Route) -> Result<Vec<u8>, FetchError> {
    Ok(get(route, ITA_PORTAL, "/certs", &[], INTEL_LIMIT)?.body)
}

/// One GET to Intel on a connection of its own.
fn intel(route: &Route, host: &'static str, path: &str) -> Result<Answer, FetchError> {
    get(route, host, path, &[], INTEL_LIMIT)
}

/// One GET on a connection of its own, which must be answered 200. Over Tor,
/// retries up to `PATHS` fresh circuits when an exit node is blocked (403/429/5xx)
/// or drops mid-body.
fn get(
    route: &Route,
    host: &'static str,
    path: &str,
    headers: &[(&str, &str)],
    limit: usize,
) -> Result<Answer, FetchError> {
    let max_attempts = match route {
        Route::Direct => 1,
        Route::Tor(_) => PATHS,
    };
    let mut attempt = 1;
    loop {
        let user_buf;
        let attempt_route = match route {
            Route::Direct => route.clone(),
            Route::Tor(proxy) => {
                user_buf = if attempt == 1 {
                    proxy.user.to_owned()
                } else {
                    format!("{}-get-{attempt}", proxy.user)
                };
                Route::Tor(Proxy {
                    user: &user_buf,
                    ..*proxy
                })
            }
        };
        let result = (|| {
            let (mut tls, _, _) = connect(&attempt_route, host, &mozilla())?;
            let answer = request(&mut tls, "GET", host, path, headers, None, limit)?;
            match answer.status {
                200 => Ok(answer),
                code => Err(FetchError::Status {
                    host,
                    code,
                    detail: answer.detail(),
                }),
            }
        })();
        match result {
            Ok(answer) => return Ok(answer),
            Err(FetchError::Status { code, .. })
                if attempt < max_attempts && matches!(code, 403 | 429 | 502 | 503 | 504) =>
            {
                attempt += 1;
            }
            Err(FetchError::Malformed(_)) if attempt < max_attempts => {
                attempt += 1;
            }
            Err(err) => return Err(err),
        }
    }
}

/// Intel's signed JSON: the exact bytes of the signed object, which the
/// signature covers, and the signature.
fn signed(body: &[u8], key: &str) -> Result<(String, Vec<u8>), FetchError> {
    let malformed = || FetchError::Malformed(format!("Intel's {key} answer"));
    let fields: HashMap<&str, &RawValue> = serde_json::from_slice(body).map_err(|_| malformed())?;
    let object = fields.get(key).ok_or_else(malformed)?.get().to_owned();
    let signature: String =
        serde_json::from_str(fields.get("signature").ok_or_else(malformed)?.get())
            .map_err(|_| malformed())?;
    Ok((object, hex::decode(signature).map_err(|_| malformed())?))
}

pub(crate) type Tls = StreamOwned<ClientConnection, Socket>;

/// The socket a TLS connection runs on: TCP, to the host or to Tor's SOCKS
/// port, or Tor's socket file. Either has `STEP` for every read and write.
pub(crate) enum Socket {
    Tcp(TcpStream),
    Unix(UnixStream),
}

impl Socket {
    pub(crate) fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Socket::Tcp(stream) => stream.set_read_timeout(timeout),
            Socket::Unix(stream) => stream.set_read_timeout(timeout),
        }
    }
}

impl Read for Socket {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Socket::Tcp(stream) => stream.read(buf),
            Socket::Unix(stream) => stream.read(buf),
        }
    }
}

impl Write for Socket {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Socket::Tcp(stream) => stream.write(buf),
            Socket::Unix(stream) => stream.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Socket::Tcp(stream) => stream.flush(),
            Socket::Unix(stream) => stream.flush(),
        }
    }
}

/// Mozilla's roots, which every certificate is checked against.
pub(crate) fn mozilla() -> RootCertStore {
    RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    }
}

/// A TLS connection to `host`:443 on `route`, after ordinary certificate
/// checks against `roots`, and the SHA-256 of the leaf certificate's
/// SubjectPublicKeyInfo. No byte of any request is written here.
///
/// Through Tor, when the connection cannot be made (the SOCKS step or the
/// TLS handshake fails), it is made again on a new circuit, asked for by
/// the caller's SOCKS user name with the attempt's number appended, `PATHS`
/// attempts at most; then the last failure is returned. Direct, there is
/// one attempt.
pub(crate) fn connect(
    route: &Route,
    host: &str,
    roots: &RootCertStore,
) -> Result<(Tls, [u8; 32], TlsSession), FetchError> {
    let proxy = match route {
        Route::Direct => return handshake(Socket::Tcp(direct(host)?), host, roots),
        Route::Tor(proxy) => proxy,
    };
    let mut path = 1;
    loop {
        let user = match path {
            1 => proxy.user.to_owned(),
            _ => format!("{}-{path}", proxy.user),
        };
        let circuit = Proxy {
            user: &user,
            ..*proxy
        };
        match socks(&circuit, host, 443).and_then(|socket| handshake(socket, host, roots)) {
            Err(_) if path < PATHS => path += 1,
            made => return made,
        }
    }
}

/// TLS on `socket` to `host`, after ordinary certificate checks against
/// `roots`, and the SHA-256 of the leaf certificate's
/// SubjectPublicKeyInfo.
/// Crypto provider for NEAR TLS handshakes: `aws-lc-rs` with hybrid post-quantum
/// `X25519MLKEM768` promoted to first preference so TLS 1.3 offers a PQ key share
/// immediately while retaining classical groups for compatibility.
pub(crate) fn tls_provider() -> rustls::crypto::CryptoProvider {
    let mut provider = rustls::crypto::aws_lc_rs::default_provider();
    if let Some(pos) = provider
        .kx_groups
        .iter()
        .position(|g| g.name() == rustls::NamedGroup::X25519MLKEM768)
    {
        let pq = provider.kx_groups.remove(pos);
        provider.kx_groups.insert(0, pq);
    }
    provider
}

fn handshake(
    socket: Socket,
    host: &str,
    roots: &RootCertStore,
) -> Result<(Tls, [u8; 32], TlsSession), FetchError> {
    let provider = tls_provider();
    let mut config = ClientConfig::builder_with_provider(Arc::new(provider))
        .with_safe_default_protocol_versions()
        .map_err(|e| FetchError::Connect(e.to_string()))?
        .with_root_certificates(roots.clone())
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let name =
        ServerName::try_from(host.to_owned()).map_err(|e| FetchError::Connect(e.to_string()))?;
    let connection = ClientConnection::new(Arc::new(config), name)
        .map_err(|e| FetchError::Connect(e.to_string()))?;
    let mut tls = StreamOwned::new(connection, socket);
    while tls.conn.is_handshaking() {
        tls.conn.complete_io(&mut tls.sock)?;
    }
    let tls_session = extract_tls_session(&tls.conn);
    let leaf = tls
        .conn
        .peer_certificates()
        .and_then(|chain| chain.first())
        .ok_or_else(|| FetchError::Connect(format!("{host} showed no certificate")))?;
    let spki = x509_cert::Certificate::from_der(leaf.as_ref())
        .and_then(|c| c.tbs_certificate().subject_public_key_info().to_der())
        .map_err(|e| FetchError::Connect(format!("{host}'s certificate: {e}")))?;
    Ok((tls, Sha256::digest(spki).into(), tls_session))
}

fn extract_tls_session(conn: &ClientConnection) -> TlsSession {
    let protocol = conn
        .protocol_version()
        .map(format_protocol)
        .unwrap_or_else(|| "unknown".into());
    let cipher_suite = conn
        .negotiated_cipher_suite()
        .and_then(|s| s.suite().as_str())
        .unwrap_or("unknown")
        .to_owned();
    let key_exchange = conn
        .negotiated_key_exchange_group()
        .map(|g| format_named_group(g.name()))
        .unwrap_or_else(|| "unknown".into());
    TlsSession {
        protocol,
        cipher_suite,
        key_exchange,
    }
}

fn format_protocol(version: rustls::ProtocolVersion) -> String {
    match version {
        rustls::ProtocolVersion::TLSv1_3 => "TLS 1.3".into(),
        rustls::ProtocolVersion::TLSv1_2 => "TLS 1.2".into(),
        other => format!("{other:?}"),
    }
}

fn format_named_group(group: rustls::NamedGroup) -> String {
    match group {
        rustls::NamedGroup::X25519MLKEM768 => "X25519MLKEM768".into(),
        rustls::NamedGroup::secp256r1MLKEM768 => "SecP256r1MLKEM768".into(),
        rustls::NamedGroup::X25519 => "X25519".into(),
        rustls::NamedGroup::secp256r1 => "secp256r1".into(),
        rustls::NamedGroup::secp384r1 => "secp384r1".into(),
        other => format!("{other:?}"),
    }
}

/// A connection to `host`:`port` through a SOCKS5 proxy (RFC 1928) that
/// resolves the name itself, signed in with a user name and password
/// (RFC 1929). On a socket file tor answers with an IPv6 address of all
/// zeros, which is read like any other.
fn socks(proxy: &Proxy, host: &str, port: u16) -> Result<Socket, FetchError> {
    let refused = |what: &str| FetchError::Connect(format!("the proxy {what}"));
    let (user, password) = (proxy.user.as_bytes(), proxy.password.as_bytes());
    if !(1..=255).contains(&user.len()) || !(1..=255).contains(&password.len()) || host.len() > 255
    {
        return Err(refused("cannot take this user name, password or host"));
    }
    let mut stream = match proxy.addr {
        SocksAddr::Tcp(addr) => Socket::Tcp(tcp(&addr)?),
        SocksAddr::Unix(path) => Socket::Unix(unix(path)?),
    };
    let mut two = [0u8; 2];
    stream.write_all(&[5, 1, 2])?;
    stream.read_exact(&mut two)?;
    if two != [5, 2] {
        return Err(refused("did not take a user name"));
    }
    let mut sign_in = vec![1, user.len() as u8];
    sign_in.extend_from_slice(user);
    sign_in.push(password.len() as u8);
    sign_in.extend_from_slice(password);
    stream.write_all(&sign_in)?;
    stream.read_exact(&mut two)?;
    if two != [1, 0] {
        return Err(refused("refused the user name"));
    }
    let mut ask = vec![5, 1, 0, 3, host.len() as u8];
    ask.extend_from_slice(host.as_bytes());
    ask.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&ask)?;
    let mut head = [0u8; 4];
    stream.read_exact(&mut head)?;
    if head[0] != 5 || head[1] != 0 {
        return Err(refused(&format!(
            "could not reach {host} (code {})",
            head[1]
        )));
    }
    let address = match head[3] {
        1 => 4,
        4 => 16,
        3 => {
            let mut length = [0u8; 1];
            stream.read_exact(&mut length)?;
            length[0] as usize
        }
        _ => return Err(refused("answered with an unknown address type")),
    };
    stream.read_exact(&mut vec![0u8; address + 2])?;
    Ok(stream)
}

/// An ordinary connection to `host`:443, its name looked up by the system.
/// Each address the name has is tried in turn, as any connection does.
fn direct(host: &str) -> Result<TcpStream, FetchError> {
    let mut failed = FetchError::Connect(format!("{host} has no address"));
    for addr in (host, 443).to_socket_addrs()? {
        match tcp(&addr) {
            Ok(stream) => return Ok(stream),
            Err(error) => failed = error.into(),
        }
    }
    Err(failed)
}

/// A TCP connection to `addr`, with `STEP` for connecting and for every
/// read and write.
fn tcp(addr: &SocketAddr) -> io::Result<TcpStream> {
    let stream = TcpStream::connect_timeout(addr, STEP)?;
    stream.set_read_timeout(Some(STEP))?;
    stream.set_write_timeout(Some(STEP))?;
    Ok(stream)
}

/// A connection to the Unix socket file at `path`, with `STEP` for every
/// read and write. Connecting to a file on this machine does not wait on
/// the network.
fn unix(path: &Path) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(STEP))?;
    stream.set_write_timeout(Some(STEP))?;
    Ok(stream)
}

pub(crate) struct Answer {
    pub(crate) status: u16,
    /// Names in lower case.
    headers: Vec<(String, String)>,
    pub(crate) body: Vec<u8>,
}

impl Answer {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    /// A certificate chain Intel sends URL-encoded in a header.
    fn chain(&self, name: &str) -> Result<String, FetchError> {
        let value = self
            .header(name)
            .ok_or_else(|| FetchError::Malformed(format!("Intel sent no {name}")))?;
        percent_decode(value).ok_or_else(|| FetchError::Malformed(format!("Intel's {name}")))
    }

    /// The start of the body, printable, for a status other than 200.
    pub(crate) fn detail(&self) -> String {
        String::from_utf8_lossy(&self.body[..self.body.len().min(300)])
            .chars()
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect()
    }
}

/// One HTTP/1.1 request on the connection, with a body if one is given,
/// after which the connection closes; the answer's body is uncompressed and
/// at most `limit` bytes.
pub(crate) fn request(
    tls: &mut Tls,
    method: &str,
    host: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&[u8]>,
    limit: usize,
) -> Result<Answer, FetchError> {
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: {USER_AGENT}\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if let Some(body) = body {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("\r\n");
    tls.write_all(head.as_bytes())?;
    if let Some(body) = body {
        tls.write_all(body)?;
    }
    tls.flush()?;

    let mut reader = Reader {
        tls,
        buffer: Vec::new(),
    };
    let head = reader.until(b"\r\n\r\n", HEAD_LIMIT)?;
    let head = std::str::from_utf8(&head)
        .map_err(|_| FetchError::Malformed("a header that is not text".into()))?;
    let mut lines = head.trim_end().split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.strip_prefix("HTTP/1.1 "))
        .and_then(|rest| rest.get(..3))
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| FetchError::Malformed("no HTTP/1.1 status".into()))?;
    let headers = lines
        .map(|line| {
            let (name, value) = line
                .split_once(':')
                .ok_or_else(|| FetchError::Malformed("a broken header".into()))?;
            Ok((name.trim().to_ascii_lowercase(), value.trim().to_owned()))
        })
        .collect::<Result<Vec<_>, FetchError>>()?;
    let mut answer = Answer {
        status,
        headers,
        body: Vec::new(),
    };
    if answer
        .header("content-encoding")
        .is_some_and(|v| !v.eq_ignore_ascii_case("identity"))
    {
        return Err(FetchError::Malformed("a compressed body".into()));
    }
    answer.body = if answer
        .header("transfer-encoding")
        .is_some_and(|v| v.eq_ignore_ascii_case("chunked"))
    {
        reader.chunked(limit)?
    } else if let Some(length) = answer.header("content-length") {
        let length: usize = length
            .parse()
            .map_err(|_| FetchError::Malformed("a broken length".into()))?;
        if length > limit {
            return Err(FetchError::Malformed(format!("a body over {limit} bytes")));
        }
        reader.take(length)?
    } else {
        reader.rest(limit)?
    };
    Ok(answer)
}

struct Reader<'a> {
    tls: &'a mut Tls,
    buffer: Vec<u8>,
}

impl Reader<'_> {
    /// Reads more; false at the end of the stream.
    fn more(&mut self) -> Result<bool, FetchError> {
        let mut chunk = [0u8; 16 << 10];
        let read = self.tls.read(&mut chunk)?;
        self.buffer.extend_from_slice(&chunk[..read]);
        Ok(read > 0)
    }

    /// Everything up to `end`, which it consumes too.
    fn until(&mut self, end: &[u8], limit: usize) -> Result<Vec<u8>, FetchError> {
        loop {
            if let Some(at) = self.buffer.windows(end.len()).position(|w| w == end) {
                let found = self.buffer[..at].to_vec();
                self.buffer.drain(..at + end.len());
                return Ok(found);
            }
            if self.buffer.len() > limit || !self.more()? {
                return Err(FetchError::Malformed("an answer cut short".into()));
            }
        }
    }

    fn take(&mut self, length: usize) -> Result<Vec<u8>, FetchError> {
        while self.buffer.len() < length {
            if !self.more()? {
                return Err(FetchError::Malformed("a body cut short".into()));
            }
        }
        Ok(self.buffer.drain(..length).collect())
    }

    fn chunked(&mut self, limit: usize) -> Result<Vec<u8>, FetchError> {
        let mut body = Vec::new();
        loop {
            let line = self.until(b"\r\n", 1024)?;
            let size = std::str::from_utf8(&line)
                .ok()
                .and_then(|l| usize::from_str_radix(l.split(';').next()?.trim(), 16).ok())
                .ok_or_else(|| FetchError::Malformed("a broken chunk".into()))?;
            if size == 0 {
                // Trailers, if any, end with an empty line.
                while !self.until(b"\r\n", HEAD_LIMIT)?.is_empty() {}
                return Ok(body);
            }
            if size > limit - body.len() {
                return Err(FetchError::Malformed(format!("a body over {limit} bytes")));
            }
            body.extend(self.take(size)?);
            if self.take(2)? != b"\r\n" {
                return Err(FetchError::Malformed("a broken chunk".into()));
            }
        }
    }

    /// The rest of the stream, for an answer with neither a length nor
    /// chunks.
    fn rest(&mut self, limit: usize) -> Result<Vec<u8>, FetchError> {
        while self.more()? {
            if self.buffer.len() > limit {
                return Err(FetchError::Malformed(format!("a body over {limit} bytes")));
            }
        }
        Ok(std::mem::take(&mut self.buffer))
    }
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            out.push(
                u8::from_str_radix(std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?, 16).ok()?,
            );
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn tls_provider_prefers_hybrid_post_quantum_x25519mlkem768() {
        let provider = super::tls_provider();
        let groups: Vec<rustls::NamedGroup> =
            provider.kx_groups.iter().map(|g| g.name()).collect();
        assert_eq!(
            groups.first().copied(),
            Some(rustls::NamedGroup::X25519MLKEM768),
            "cloak-near TLS provider must offer X25519MLKEM768 first; got {groups:?}"
        );
        assert!(
            groups.contains(&rustls::NamedGroup::X25519),
            "classical fallback group must remain present; got {groups:?}"
        );
    }

    #[test]
    fn tls_session_classifies_hybrid_pq_vs_classical() {
        let pq = super::TlsSession {
            protocol: super::format_protocol(rustls::ProtocolVersion::TLSv1_3),
            cipher_suite: "TLS13_AES_256_GCM_SHA384".into(),
            key_exchange: super::format_named_group(rustls::NamedGroup::X25519MLKEM768),
        };
        assert_eq!(pq.protocol, "TLS 1.3");
        assert_eq!(pq.key_exchange, "X25519MLKEM768");
        assert!(pq.is_hybrid_pqc());

        let classical = super::TlsSession {
            protocol: super::format_protocol(rustls::ProtocolVersion::TLSv1_3),
            cipher_suite: "TLS13_AES_256_GCM_SHA384".into(),
            key_exchange: super::format_named_group(rustls::NamedGroup::X25519),
        };
        assert_eq!(classical.key_exchange, "X25519");
        assert!(!classical.is_hybrid_pqc());
    }
}
