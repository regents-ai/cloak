//! A stand-in on this machine for every host trace sharing reaches, for its
//! checks: a SOCKS5 proxy on a socket file in a folder of its own, with a
//! TLS server behind it whose certificate names the commons' hosts, NEAR's
//! gateway and NEAR AI's sign-in host (tests/fixtures/share-stand-in, from a
//! certificate authority made for these checks alone). It answers each
//! request from a table its check gives and records every request that
//! came, in order. Nothing leaves this machine.
//!
//! The certificates were made with OpenSSL 3.6.4 on 21 November 2026: P-256,
//! valid until 2126, the server's for ingest.tracecommons.ai,
//! issuer.tracecommons.ai, the witness's Phala address, cloud-api.near.ai
//! and cloud-platform.near.ai.

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use der::{Decode, Encode};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{RootCertStore, ServerConfig, ServerConnection, StreamOwned};
use sha2::{Digest, Sha256};

use crate::{Proxy, Route, SocksAddr};

const SERVER: &[u8] = include_bytes!("../tests/fixtures/share-stand-in/server.der");

/// One request that reached the stand-in.
#[derive(Clone, Debug)]
pub(crate) struct Seen {
    /// The host the SOCKS request named.
    pub host: String,
    pub method: String,
    /// The path and query.
    pub path: String,
    /// Header names in lower case.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Seen {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }
}

/// A status, headers and a body.
pub(crate) type Reply = (u16, Vec<(String, String)>, Vec<u8>);

/// The table: the answer to a request, given the requests before it.
type Table = dyn Fn(&Seen, &[Seen]) -> Reply + Send + Sync;

pub(crate) struct StandIn {
    folder: PathBuf,
    socket: PathBuf,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl StandIn {
    pub fn start(table: impl Fn(&Seen, &[Seen]) -> Reply + Send + Sync + 'static) -> StandIn {
        let made = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let folder = std::env::temp_dir().join(format!(
            "cloak-near-share-{}-{}",
            std::process::id(),
            made.as_nanos()
        ));
        std::fs::create_dir(&folder).unwrap();
        let socket = folder.join("socks");
        let listener = UnixListener::bind(&socket).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let table: Arc<Table> = Arc::new(table);
        let recorded = seen.clone();
        thread::spawn(move || {
            for connection in listener.incoming() {
                let Ok(connection) = connection else { continue };
                let (table, recorded) = (table.clone(), recorded.clone());
                thread::spawn(move || serve(connection, &*table, &recorded));
            }
        });
        StandIn {
            folder,
            socket,
            seen,
        }
    }

    /// Every request so far, in order.
    pub fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    /// The route line for the helper: tor at the stand-in's socket file.
    pub fn route(&self) -> serde_json::Value {
        serde_json::json!({
            "via": "tor",
            "socket": self.socket,
            "near_identity": "near",
            "intel_identity": "intel"
        })
    }

    /// The same route, as sharing's steps take it.
    pub fn tor(&self) -> Route<'_> {
        Route::Tor(Proxy {
            addr: SocksAddr::Unix(&self.socket),
            user: "near",
            password: "cloak",
        })
    }
}

impl Drop for StandIn {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.folder);
    }
}

/// Roots holding only the stand-in's certificate authority.
pub(crate) fn roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    roots
        .add(CertificateDer::from(
            include_bytes!("../tests/fixtures/share-stand-in/ca.der").to_vec(),
        ))
        .unwrap();
    roots
}

/// The SHA-256 of the stand-in's certificate key, as `connect` gives it: the
/// pin a proof takes for the stand-in's gateway.
pub(crate) fn pin() -> [u8; 32] {
    let certificate = x509_cert::Certificate::from_der(SERVER).unwrap();
    let key = certificate
        .tbs_certificate()
        .subject_public_key_info()
        .to_der()
        .unwrap();
    Sha256::digest(key).into()
}

/// A JSON answer.
pub(crate) fn json(status: u16, value: serde_json::Value) -> Reply {
    (
        status,
        vec![("Content-Type".into(), "application/json".into())],
        serde_json::to_vec(&value).unwrap(),
    )
}

fn serve(mut socket: UnixStream, table: &Table, recorded: &Mutex<Vec<Seen>>) {
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let Some(host) = socks(&mut socket) else {
        return;
    };
    let mut tls = StreamOwned::new(ServerConnection::new(server_config()).unwrap(), socket);
    let Some((head, body)) = read_request(&mut tls) else {
        return;
    };
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap().split(' ');
    let (method, path) = (
        first.next().unwrap().to_owned(),
        first.next().unwrap().to_owned(),
    );
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(n, v)| (n.trim().to_ascii_lowercase(), v.trim().to_owned()))
        .collect();
    let seen = Seen {
        host,
        method,
        path,
        headers,
        body,
    };
    let before = recorded.lock().unwrap().clone();
    let (status, headers, body) = table(&seen, &before);
    recorded.lock().unwrap().push(seen);
    // A 204 ends at its headers, with no length, and the stand-in then holds
    // the connection until the client hangs up, as a server may.
    let mut head = match status {
        204 => format!("HTTP/1.1 {status} Stand-in\r\n"),
        _ => format!(
            "HTTP/1.1 {status} Stand-in\r\nContent-Length: {}\r\nConnection: close\r\n",
            body.len()
        ),
    };
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    let _ = tls.write_all(head.as_bytes());
    let _ = tls.write_all(&body);
    if status == 204 {
        let _ = tls.flush();
        let _ = tls.sock.set_read_timeout(None);
        let _ = tls.read(&mut [0u8; 1]);
    }
    tls.conn.send_close_notify();
    let _ = tls.flush();
}

/// The proxy's half of SOCKS5 with a user name and password, any of them;
/// the host asked for, by name, on port 443.
fn socks(socket: &mut UnixStream) -> Option<String> {
    fn read(socket: &mut UnixStream, length: usize) -> Option<Vec<u8>> {
        let mut bytes = vec![0u8; length];
        socket.read_exact(&mut bytes).ok()?;
        Some(bytes)
    }
    if read(socket, 3)? != [5, 1, 2] {
        return None;
    }
    socket.write_all(&[5, 2]).ok()?;
    read(socket, 1)?;
    let user = read(socket, 1)?[0] as usize;
    read(socket, user)?;
    let password = read(socket, 1)?[0] as usize;
    read(socket, password)?;
    socket.write_all(&[1, 0]).ok()?;
    let ask = read(socket, 5)?;
    if ask[..4] != [5, 1, 0, 3] {
        return None;
    }
    let host = String::from_utf8(read(socket, ask[4] as usize)?).ok()?;
    if read(socket, 2)? != 443u16.to_be_bytes() {
        return None;
    }
    socket.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).ok()?;
    Some(host)
}

fn server_config() -> Arc<ServerConfig> {
    let certificate = CertificateDer::from(SERVER.to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        include_bytes!("../tests/fixtures/share-stand-in/server-key.der").to_vec(),
    ));
    let provider = rustls::crypto::ring::default_provider();
    let mut config = ServerConfig::builder_with_provider(Arc::new(provider))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![certificate], key)
        .unwrap();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Arc::new(config)
}

/// The request's head, up to the empty line, and its body, by its length;
/// none when the client left first.
fn read_request(tls: &mut impl Read) -> Option<(String, Vec<u8>)> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 16 << 10];
    let end = loop {
        if let Some(at) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
        let read = tls.read(&mut chunk).ok().filter(|&r| r > 0)?;
        data.extend_from_slice(&chunk[..read]);
    };
    let head = String::from_utf8(data[..end].to_vec()).ok()?;
    let length: usize = head
        .split("\r\n")
        .filter_map(|line| line.split_once(':'))
        .find(|(n, _)| n.trim().eq_ignore_ascii_case("content-length"))
        .map_or(0, |(_, v)| v.trim().parse().unwrap());
    while data.len() < end + 4 + length {
        let read = tls.read(&mut chunk).ok().filter(|&r| r > 0)?;
        data.extend_from_slice(&chunk[..read]);
    }
    Some((head, data[end + 4..end + 4 + length].to_vec()))
}
