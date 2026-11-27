//! The line format of `cloak-near`, the helper the Mac app starts for NEAR
//! mode: one request a line in, one answer a line out (README.md, "The
//! helper"). Each line is a `check`, which runs [`check`], or an `ask`,
//! which runs [`ask`]; the answer says whether the chat request may have
//! reached NEAR ([`Stop::sent`]). The account key comes only inside an `ask`
//! line, is used for that request and dropped with it; no answer quotes it.

use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::error::Category;
use serde_json::Value;

use crate::{ask, check, Kept, Pins, Proof, Proxy, Route, Routes, SocksAddr, Stop, TlsSession};

/// The SOCKS password sent with each identity. Tor keeps circuits apart by
/// the user name and password together; the identities alone tell them
/// apart.
const PASSWORD: &str = "cloak";

#[derive(Deserialize)]
#[serde(tag = "request", rename_all = "lowercase", deny_unknown_fields)]
enum Request {
    Check {
        model: String,
        route: RouteLine,
        /// Seconds.
        proof_age: u64,
    },
    Ask {
        model: String,
        route: RouteLine,
        /// Seconds.
        proof_age: u64,
        key: String,
        body: Value,
    },
}

#[derive(Deserialize)]
#[serde(tag = "via", rename_all = "lowercase", deny_unknown_fields)]
enum RouteLine {
    /// NEAR and Intel see the Mac's internet address. (Written with braces
    /// so that a field beside `via` is refused, as everywhere else.)
    Direct {},
    /// Through tor's SOCKS port at the socket file `socket`, NEAR's
    /// connections under the SOCKS user name `near_identity` and Intel's
    /// under `intel_identity`.
    Tor {
        socket: PathBuf,
        near_identity: String,
        intel_identity: String,
    },
}

impl RouteLine {
    fn routes(&self) -> Routes<'_> {
        match self {
            RouteLine::Direct {} => Routes {
                near: Route::Direct,
                intel: Route::Direct,
            },
            RouteLine::Tor {
                socket,
                near_identity,
                intel_identity,
            } => {
                let tor = |user| {
                    Route::Tor(Proxy {
                        addr: SocksAddr::Unix(socket),
                        user,
                        password: PASSWORD,
                    })
                };
                Routes {
                    near: tor(near_identity),
                    intel: tor(intel_identity),
                }
            }
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "answer", rename_all = "lowercase")]
enum Answer {
    /// A `check` passed; `sent` is false.
    Passed { sent: bool, proof: ProofLine },
    /// An `ask` was answered; `sent` is true.
    Replied {
        sent: bool,
        proof: ProofLine,
        reply: Value,
    },
    /// A line stopped at the step `stop`; `code` is NEAR's status, given
    /// only when `stop` is `status`.
    Stopped {
        sent: bool,
        stop: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<u16>,
        text: String,
    },
}

/// What a proof that passed covered, and when it passed.
#[derive(Serialize)]
struct ProofLine {
    /// Seconds since 1970.
    passed_at: u64,
    model_servers: usize,
    gpus: usize,
    /// The model's Ed25519 encryption key, in hex.
    model_key: String,
    /// SHA-256 of the gateway's TLS key, in hex.
    gateway_tls_key_sha256: String,
    /// Negotiated TLS protocol version on the gateway connection (local only).
    #[serde(skip_serializing_if = "Option::is_none")]
    tls_protocol: Option<String>,
    /// Negotiated TLS cipher suite on the gateway connection (local only).
    #[serde(skip_serializing_if = "Option::is_none")]
    tls_cipher_suite: Option<String>,
    /// Negotiated TLS key exchange group on the gateway connection (local only).
    #[serde(skip_serializing_if = "Option::is_none")]
    tls_key_exchange: Option<String>,
}

impl ProofLine {
    fn of(proof: &Proof, passed_at: u64, tls: Option<&TlsSession>) -> ProofLine {
        ProofLine {
            passed_at,
            model_servers: proof.intel.instances,
            gpus: proof.gpu.gpus,
            model_key: hex::encode(proof.intel.model_key),
            gateway_tls_key_sha256: hex::encode(proof.intel.gateway_tls_key),
            tls_protocol: tls.map(|t| t.protocol.clone()),
            tls_cipher_suite: tls.map(|t| t.cipher_suite.clone()),
            tls_key_exchange: tls.map(|t| t.key_exchange.clone()),
        }
    }
}

/// The answer to one line of the helper's input, as one line of JSON
/// without its line end. A line that is not a known request gets a stop of
/// its own, `line`.
pub fn respond(line: &[u8], pins: &Pins, kept: &mut Kept) -> String {
    let answer = match serde_json::from_slice::<Request>(line) {
        Ok(request) => run(request, pins, kept),
        Err(error) => Answer::Stopped {
            sent: false,
            stop: "line",
            code: None,
            text: unreadable(&error),
        },
    };
    serde_json::to_string(&answer).expect("an answer serializes")
}

fn run(request: Request, pins: &Pins, kept: &mut Kept) -> Answer {
    match request {
        Request::Check {
            model,
            route,
            proof_age,
        } => match check(
            &route.routes(),
            &model,
            pins,
            kept,
            Duration::from_secs(proof_age),
        ) {
            Ok(passed) => Answer::Passed {
                sent: false,
                proof: ProofLine::of(&passed.proof, passed.at, passed.tls.as_ref()),
            },
            Err(stop) => stopped(&stop),
        },
        Request::Ask {
            model,
            route,
            proof_age,
            key,
            body,
        } => match ask(
            &route.routes(),
            &model,
            &key,
            &serde_json::to_vec(&body).expect("JSON serializes"),
            pins,
            kept,
            Duration::from_secs(proof_age),
        ) {
            Ok(answered) => Answer::Replied {
                sent: true,
                proof: ProofLine::of(
                    &answered.proof,
                    answered.proof_passed_at,
                    answered.tls.as_ref(),
                ),
                reply: answered.reply,
            },
            Err(stop) => stopped(&stop),
        },
    }
}

fn stopped(stop: &Stop) -> Answer {
    let (step, code) = match stop {
        Stop::Request(_) => ("request", None),
        Stop::Fetch(_) => ("fetch", None),
        Stop::Refused(_) => ("refused", None),
        Stop::Connect(_) => ("connect", None),
        Stop::Pin => ("pin", None),
        Stop::Send(_) => ("send", None),
        Stop::Status { code, .. } => ("status", Some(*code)),
        Stop::Reply(_) => ("reply", None),
    };
    Answer::Stopped {
        sent: stop.sent(),
        stop: step,
        code,
        text: stop.to_string(),
    }
}

/// Why a line is not a request, without quoting it: serde's own words can
/// quote what the line holds, the key included.
fn unreadable(error: &serde_json::Error) -> String {
    match error.classify() {
        Category::Data => "the line is not a known request".into(),
        Category::Syntax | Category::Eof | Category::Io => "the line is not JSON".into(),
    }
}

/// Proof before sending, for the helper's `check` line, offline: with a
/// proof kept for the model, a `check` line passes without opening any
/// connection, while an `ask` line with the same kept proof goes to the
/// chat endpoint's connection. The route is a socket file on this machine
/// whose listener counts each connection and closes it; nothing leaves
/// this machine.
#[cfg(test)]
mod checks {
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use serde_json::{json, Value};

    use super::respond;
    use crate::e2ee::ReplyKey;
    use crate::{GpuProof, IntelProof, Kept, Passed, Pins, Proof, TcbStatus, TlsSession};

    const MODEL: &str = "z-ai/glm-5.3-flash";

    /// A folder of its own, a socket file in it, and how many connections
    /// the socket's listener has taken; each is closed at once.
    fn counting_socket() -> (PathBuf, PathBuf, Arc<AtomicUsize>) {
        let made = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let folder = std::env::temp_dir().join(format!(
            "cloak-near-check-{}-{}",
            std::process::id(),
            made.as_nanos()
        ));
        std::fs::create_dir(&folder).unwrap();
        let socket = folder.join("socks");
        let listener = UnixListener::bind(&socket).unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let counted = connections.clone();
        thread::spawn(move || {
            for connection in listener.incoming() {
                counted.fetch_add(1, Ordering::SeqCst);
                drop(connection);
            }
        });
        (folder, socket, connections)
    }

    /// A proof that passed at `at`, with a model key that can be sealed for.
    fn passed(at: u64) -> Passed {
        Passed {
            proof: Proof {
                intel: IntelProof {
                    gateway_key: [0; 32],
                    gateway_tls_key: [7; 32],
                    gateway_mrconfigid: Vec::new(),
                    model_key: ReplyKey([0x42; 32]).public(),
                    instances: 3,
                    gateway_tcb: TcbStatus::UpToDate,
                    model_tcb: vec![TcbStatus::UpToDate; 3],
                },
                gpu: GpuProof { gpus: 8 },
            },
            at,
            tls: Some(TlsSession {
                protocol: "TLS 1.3".into(),
                cipher_suite: "TLS13_AES_256_GCM_SHA384".into(),
                key_exchange: "X25519MLKEM768".into(),
            }),
        }
    }

    #[test]
    fn a_check_line_never_opens_the_chat_endpoint() {
        let (folder, socket, connections) = counting_socket();
        let route = json!({
            "via": "tor",
            "socket": socket,
            "near_identity": "near",
            "intel_identity": "intel"
        });
        let pins = Pins {
            gateway: Vec::new(),
            model: Vec::new(),
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let mut kept = Kept::new(Duration::from_secs(3600)).unwrap();
        kept.keep(true, MODEL, &passed(now - 5), 600);

        let check = json!({"request": "check", "model": MODEL, "route": route, "proof_age": 600});
        let answer: Value =
            serde_json::from_str(&respond(check.to_string().as_bytes(), &pins, &mut kept)).unwrap();
        assert_eq!(answer["answer"], "passed", "{answer}");
        assert_eq!(answer["sent"], false);
        assert_eq!(answer["proof"]["passed_at"], now - 5);
        assert_eq!(answer["proof"]["model_servers"], 3);
        assert_eq!(answer["proof"]["gpus"], 8);
        assert_eq!(answer["proof"]["tls_protocol"], "TLS 1.3");
        assert_eq!(answer["proof"]["tls_key_exchange"], "X25519MLKEM768");
        assert_eq!(connections.load(Ordering::SeqCst), 0);

        // The same kept proof, for an `ask`: it goes to the chat endpoint's
        // connection, which the listener takes and closes, so nothing is
        // written and the answer says so.
        let ask = json!({
            "request": "ask",
            "model": MODEL,
            "route": route,
            "proof_age": 600,
            "key": "sk-example",
            "body": {"model": MODEL, "messages": [{"role": "user", "content": "ping"}]}
        });
        let answer: Value =
            serde_json::from_str(&respond(ask.to_string().as_bytes(), &pins, &mut kept)).unwrap();
        std::fs::remove_dir_all(&folder).unwrap();
        assert_eq!(answer["answer"], "stopped", "{answer}");
        assert_eq!(answer["stop"], "connect");
        assert_eq!(answer["sent"], false);
        assert!(connections.load(Ordering::SeqCst) > 0);
    }
}
