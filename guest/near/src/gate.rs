//! The gate checks of the NEAR request, offline. They live in the crate
//! because `send` is reachable only from inside it.
//!
//! - NEAR's own published vectors for its encryption, version 2, from its
//!   MIT-licensed SDK (tests/fixtures/near-inference-sdk, with the licence):
//!   each opens with NEAR's key, does not open with one byte changed, and
//!   what Cloak seals for NEAR's public key opens with NEAR's secret.
//! - A stand-in for NEAR's gateway on this machine: a SOCKS5 proxy with the
//!   TLS server behind it, whose certificate comes from a certificate
//!   authority made for this check alone (tests/fixtures/stand-in). It holds
//!   a model's key, records what `send` wrote, and answers sealed for the
//!   client's key. The round trip gives back the reply in plain text, and
//!   every word of the request was sealed for the model's key with the
//!   scheme's headers; a reply with a changed or a plain field is refused;
//!   a gateway whose certificate key is not the pinned one is refused before
//!   any request byte is written.
//!
//! The stand-in's certificates were made with OpenSSL 3.6.4 on 19 November
//! 2026 (P-256, valid until 2126, for `cloud-api.near.ai`); `spki.hex` is
//! the SHA-256 of the server key's SubjectPublicKeyInfo, as OpenSSL gave it.
//!
//!     cargo test --locked --manifest-path guest/near/Cargo.toml

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{RootCertStore, ServerConfig, ServerConnection, StreamOwned};
use serde_json::{json, Value};
use sha2::{Digest, Sha512};

use crate::chat::send;
use crate::e2ee::{ReplyKey, SealKey};
use crate::{GpuProof, IntelProof, Proof, Proxy, Route, SocksAddr, Stop, TcbStatus};

const MODEL: &str = "z-ai/glm-5.3-flash";
const API_KEY: &str = "sk-stand-in";

fn hex32(text: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    hex::decode_to_slice(text.trim(), &mut out).unwrap();
    out
}

#[test]
fn nears_version_2_vectors_open_and_seal() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/near-inference-sdk/e2ee-v2.json"
    ))
    .unwrap();
    let vectors = fixture["vectors"].as_array().unwrap();
    assert_eq!(vectors.len(), 2);
    for vector in vectors {
        let field = |name: &str| vector[name].as_str().unwrap();
        // An Ed25519 secret key is the first half of SHA-512 of its seed.
        let near = ReplyKey(
            Sha512::digest(hex32(field("private_seed")))[..32]
                .try_into()
                .unwrap(),
        );
        assert_eq!(hex::encode(near.public()), field("public_key"));
        assert_eq!(
            near.open(field("ciphertext")).as_deref(),
            Some(field("plaintext"))
        );

        let mut changed = hex::decode(field("ciphertext")).unwrap();
        *changed.last_mut().unwrap() ^= 1;
        assert_eq!(near.open(&hex::encode(changed)), None);

        let for_near = SealKey::from_ed25519(&hex32(field("public_key"))).unwrap();
        let words = "Cloak → NEAR, sealed for its key";
        assert_eq!(
            near.open(&for_near.seal(words).unwrap()).as_deref(),
            Some(words)
        );
    }
}

#[test]
fn the_stand_in_opens_the_request_and_the_reply_comes_back_plain() {
    let (reply, seen) = run(Some(Answer::Sealed), pinned());
    assert_eq!(reply.unwrap(), plain_reply());

    assert_eq!(
        seen.head.split("\r\n").next(),
        Some("POST /v1/chat/completions HTTP/1.1")
    );
    let model_public = hex::encode(model_key().public());
    for (name, value) in [
        ("host", "cloud-api.near.ai"),
        ("authorization", "Bearer sk-stand-in"),
        ("content-type", "application/json"),
        ("accept-encoding", "identity"),
        ("x-signing-algo", "ed25519"),
        ("x-encryption-version", "2"),
        ("x-encrypt-all-fields", "true"),
        ("x-no-aliasing", "true"),
        ("x-model-pub-key", &model_public),
    ] {
        assert_eq!(header(&seen.head, name), Some(value), "{name}");
    }

    // Every word was sealed for the model's key: each field differs from
    // what was asked and opens with the model's key to it. With them
    // opened, the request is the one asked, so nothing else changed; the
    // text that reads as a JSON list arrives as one text part, as NEAR
    // would read it.
    let asked = request();
    let mut expected = asked.clone();
    expected["messages"][4]["content"] = json!([{"type": "text", "text": "[\"and pong?\"]"}]);
    let mut sent: Value = serde_json::from_slice(&seen.body).unwrap();
    for (pointer, json) in SEALED {
        let value = sent.pointer_mut(pointer).unwrap();
        assert_ne!(Some(&*value), asked.pointer(pointer), "{pointer}");
        let opened = model_key().open(value.as_str().unwrap()).unwrap();
        *value = match json {
            true => serde_json::from_str(&opened).unwrap(),
            false => Value::String(opened),
        };
    }
    assert_eq!(sent, expected);
}

#[test]
fn a_reply_with_a_changed_or_plain_field_is_refused() {
    let (changed, first) = run(Some(Answer::Changed), pinned());
    assert!(matches!(changed, Err(Stop::Reply(_))), "{changed:?}");
    let (plain, second) = run(Some(Answer::Plain), pinned());
    assert!(matches!(plain, Err(Stop::Reply(_))), "{plain:?}");

    // Each request had a client key of its own.
    assert_ne!(
        header(&first.head, "x-client-pub-key"),
        header(&second.head, "x-client-pub-key")
    );
}

#[test]
fn another_certificate_key_is_refused_before_any_request_byte() {
    let mut pin = pinned();
    pin[0] ^= 1;
    let (result, seen) = run(None, pin);
    assert!(matches!(result, Err(Stop::Pin)), "{result:?}");
    assert!(
        seen.body.is_empty(),
        "{} bytes reached the stand-in",
        seen.body.len()
    );
}

/// The fields of `request()` that must arrive sealed, and whether each is
/// JSON (a list of parts, a parameters schema) rather than text.
const SEALED: [(&str, bool); 12] = [
    ("/messages/0/content", false),
    ("/messages/1/content", true),
    ("/messages/2/reasoning_content", false),
    ("/messages/2/tool_calls/0/function/name", false),
    ("/messages/2/tool_calls/0/function/arguments", false),
    ("/messages/3/name", false),
    ("/messages/3/content", false),
    ("/messages/4/content", true),
    ("/tools/0/function/name", false),
    ("/tools/0/function/description", false),
    ("/tools/0/function/parameters", true),
    ("/tool_choice/function/name", false),
];

/// A request with words in every place all-fields mode seals.
fn request() -> Value {
    json!({
        "model": MODEL,
        "messages": [
            {"role": "system", "content": "Answer in one word."},
            {"role": "user", "content": [{"type": "text", "text": "ping"}]},
            {
                "role": "assistant",
                "content": null,
                "reasoning_content": "They want a word looked up.",
                "tool_calls": [{
                    "id": "call-0",
                    "type": "function",
                    "function": {"name": "look_up", "arguments": "{\"word\":\"ping\"}"}
                }]
            },
            {"role": "tool", "tool_call_id": "call-0", "name": "look_up", "content": "a short sound"},
            {"role": "user", "content": "[\"and pong?\"]"}
        ],
        "tools": [{
            "type": "function",
            "function": {
                "name": "look_up",
                "description": "Looks a word up.",
                "parameters": {
                    "type": "object",
                    "properties": {"word": {"type": "string"}},
                    "required": ["word"]
                }
            }
        }],
        "tool_choice": {"type": "function", "function": {"name": "look_up"}},
        "temperature": 0.2,
        "stream": false
    })
}

/// The stand-in model's reply, before sealing.
fn plain_reply() -> Value {
    json!({
        "id": "chatcmpl-stand-in",
        "object": "chat.completion",
        "created": 1795125440,
        "model": MODEL,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "pong",
                "reasoning_content": "They said ping.",
                "refusal": null,
                "tool_calls": [{
                    "id": "call-1",
                    "type": "function",
                    "function": {"name": "look_up", "arguments": "{\"word\":\"pong\"}"}
                }]
            },
            "logprobs": null,
            "finish_reason": "tool_calls"
        }],
        "usage": {"prompt_tokens": 40, "completion_tokens": 12, "total_tokens": 52}
    })
}

/// How the stand-in answers: sealed as NEAR's model seals, with one
/// character of the sealed content changed, or with the content in plain
/// text.
#[derive(Clone, Copy)]
enum Answer {
    Sealed,
    Changed,
    Plain,
}

/// What reached the stand-in after the TLS handshake: the request's head
/// and body, or, when it expected nothing, every byte that came.
struct Seen {
    head: String,
    body: Vec<u8>,
}

/// The stand-in model's key.
fn model_key() -> ReplyKey {
    ReplyKey([0x42; 32])
}

/// A proof checked with the gateway TLS key hash `pin`.
fn proof(pin: [u8; 32]) -> Proof {
    Proof {
        intel: IntelProof {
            gateway_key: [0; 32],
            gateway_tls_key: pin,
            model_key: model_key().public(),
            instances: 1,
            gateway_tcb: TcbStatus::UpToDate,
            model_tcb: vec![TcbStatus::UpToDate],
        },
        gpu: GpuProof { gpus: 8 },
    }
}

fn pinned() -> [u8; 32] {
    hex32(include_str!("../tests/fixtures/stand-in/spki.hex"))
}

/// `send`s `request()` to a stand-in that answers as `answer`, or expects
/// nothing, under a proof checked with the gateway TLS key hash `pin`.
fn run(answer: Option<Answer>, pin: [u8; 32]) -> (Result<Value, Stop>, Seen) {
    let (addr, stand_in) = stand_in(answer);
    let route = Route::Tor(Proxy {
        addr: SocksAddr::Tcp(addr),
        user: "gate",
        password: "check",
    });
    let body = serde_json::to_vec(&request()).unwrap();
    let result = send(&proof(pin), &route, &roots(), MODEL, API_KEY, &body);
    (result, stand_in.join().unwrap())
}

fn stand_in(answer: Option<Answer>) -> (SocketAddr, JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let stand_in = thread::spawn(move || {
        let (mut tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        socks(&mut tcp);
        let mut tls = StreamOwned::new(ServerConnection::new(server_config()).unwrap(), tcp);
        // A client that leaves at once may close before the handshake's
        // last write; what came after it is read below either way.
        while tls.conn.is_handshaking() && tls.conn.complete_io(&mut tls.sock).is_ok() {}
        let Some(answer) = answer else {
            let mut came = Vec::new();
            let _ = tls.read_to_end(&mut came);
            return Seen {
                head: String::new(),
                body: came,
            };
        };
        let (head, body) = read_request(&mut tls);
        let reply = sealed_reply(&head, answer);
        write!(
            tls,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            reply.len()
        )
        .unwrap();
        tls.write_all(&reply).unwrap();
        tls.conn.send_close_notify();
        tls.flush().unwrap();
        Seen { head, body }
    });
    (addr, stand_in)
}

/// The proxy's half of SOCKS5 with a user name and password; it must be
/// asked for NEAR's gateway on port 443, by name.
fn socks(tcp: &mut TcpStream) {
    fn read(tcp: &mut TcpStream, length: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; length];
        tcp.read_exact(&mut bytes).unwrap();
        bytes
    }
    assert_eq!(read(tcp, 3), [5, 1, 2]);
    tcp.write_all(&[5, 2]).unwrap();
    assert_eq!(read(tcp, 1), [1]);
    let user = read(tcp, 1)[0] as usize;
    assert_eq!(read(tcp, user), b"gate");
    let password = read(tcp, 1)[0] as usize;
    assert_eq!(read(tcp, password), b"check");
    tcp.write_all(&[1, 0]).unwrap();
    let ask = read(tcp, 5);
    assert_eq!(ask[..4], [5, 1, 0, 3]);
    assert_eq!(read(tcp, ask[4] as usize), b"cloud-api.near.ai");
    assert_eq!(read(tcp, 2), 443u16.to_be_bytes());
    tcp.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
}

fn server_config() -> Arc<ServerConfig> {
    let certificate =
        CertificateDer::from(include_bytes!("../tests/fixtures/stand-in/server.der").to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        include_bytes!("../tests/fixtures/stand-in/server-key.der").to_vec(),
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

/// Roots holding only the stand-in's certificate authority.
fn roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    roots
        .add(CertificateDer::from(
            include_bytes!("../tests/fixtures/stand-in/ca.der").to_vec(),
        ))
        .unwrap();
    roots
}

/// The request's head, up to the empty line, and its body, by its length.
fn read_request(tls: &mut impl Read) -> (String, Vec<u8>) {
    let mut data = Vec::new();
    let mut more = |data: &mut Vec<u8>| {
        let mut chunk = [0u8; 16 << 10];
        let read = tls.read(&mut chunk).unwrap();
        assert!(read > 0, "the request was cut short");
        data.extend_from_slice(&chunk[..read]);
    };
    let end = loop {
        if let Some(at) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
        more(&mut data);
    };
    let head = String::from_utf8(data[..end].to_vec()).unwrap();
    let length: usize = header(&head, "content-length").unwrap().parse().unwrap();
    while data.len() < end + 4 + length {
        more(&mut data);
    }
    (head, data[end + 4..].to_vec())
}

/// A header's value, by its name in any case.
fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.split("\r\n").skip(1).find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.trim().eq_ignore_ascii_case(name).then(|| value.trim())
    })
}

/// `plain_reply()` sealed for the client key in `head`, as `answer` says.
fn sealed_reply(head: &str, answer: Answer) -> Vec<u8> {
    let client = SealKey::from_ed25519(&hex32(header(head, "x-client-pub-key").unwrap())).unwrap();
    let seal =
        |value: &mut Value| *value = Value::String(client.seal(value.as_str().unwrap()).unwrap());
    let mut reply = plain_reply();
    let message = &mut reply["choices"][0]["message"];
    for pointer in [
        "/reasoning_content",
        "/tool_calls/0/function/name",
        "/tool_calls/0/function/arguments",
    ] {
        seal(message.pointer_mut(pointer).unwrap());
    }
    match answer {
        Answer::Sealed => seal(&mut message["content"]),
        Answer::Changed => {
            seal(&mut message["content"]);
            let Value::String(sealed) = &mut message["content"] else {
                unreachable!()
            };
            let last = sealed.pop().unwrap();
            sealed.push(if last == '0' { '1' } else { '0' });
        }
        Answer::Plain => {}
    }
    serde_json::to_vec(&reply).unwrap()
}
