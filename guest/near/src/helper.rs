//! The line format of `cloak-near`, the helper the Mac app starts for NEAR
//! mode: one request a line in, one answer a line out (README.md, "The
//! helper"). A `check` runs [`check`] and an `ask` runs [`ask`]; the answer
//! says whether the chat request may have reached NEAR ([`Stop::sent`]).
//!
//! The other lines are trace sharing's (`share.rs`): `listen` and `enrol`
//! for the sign-in and enrolment, `ready` for the commons' challenge,
//! `readied` for the one message a person readied, sent by
//! [`ask_readied`], then `review`, `upload`, `status` and `withdraw`. Their
//! answers say whether the step's own request may have reached its host
//! ([`Halt::sent`]).
//!
//! The account key, the device key and the account session come only
//! inside request lines, are used for that line and dropped with it; no
//! answer quotes them but the account session, which `enrol` and
//! `withdraw` hand back for the Mac to keep.

use std::path::PathBuf;
use std::time::Duration;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rustls::RootCertStore;
use serde::{Deserialize, Serialize};
use serde_json::error::Category;
use serde_json::Value;

use crate::fetch::mozilla;
use crate::share::{self, Account, Device, Envelope, Exchange, Halt, Net, Signin};
use crate::{ask, ask_readied, check, Kept, Pins, Proof, Proxy, Route, Routes, SocksAddr, Stop};

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
    /// Reads the commons' capabilities and waits on the loopback address
    /// for the NEAR AI sign-in; the answer gives the sign-in's addresses.
    Listen { route: RouteLine },
    /// Waits for that sign-in, then enrols the device key.
    Enrol {
        route: RouteLine,
        /// The device key's 32-byte seed, in standard base64.
        device_key: String,
    },
    /// An upload claim, then the commons' admission challenge.
    Ready {
        route: RouteLine,
        device_key: String,
        account: Account,
        scopes: Vec<String>,
        uses: Vec<String>,
    },
    /// The readied message: an `ask`, unencrypted, carrying `admission`.
    Readied {
        model: String,
        route: RouteLine,
        /// Seconds.
        proof_age: u64,
        key: String,
        body: Value,
        admission: String,
    },
    /// The witness's enclave checked, then the exchange sent to it.
    Review {
        route: RouteLine,
        account: Account,
        scopes: Vec<String>,
        uses: Vec<String>,
        exchange: Exchange,
        /// Cloak's version, which the trace names.
        version: String,
    },
    Upload {
        route: RouteLine,
        device_key: String,
        account: Account,
        scopes: Vec<String>,
        uses: Vec<String>,
        envelope: Envelope,
    },
    Status {
        route: RouteLine,
        device_key: String,
        account: Account,
        submissions: Vec<String>,
    },
    Withdraw {
        route: RouteLine,
        session: String,
        submission: String,
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
    /// under `intel_identity`. Trace sharing's connections to the commons
    /// and the witness go under NEAR's.
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
    /// A `listen` is waiting: the sign-in's address for GitHub and for
    /// Google.
    Listening {
        sent: bool,
        github: String,
        google: String,
    },
    /// An `enrol` enrolled the device key.
    Enrolled {
        sent: bool,
        account: Account,
        account_id: String,
        anchor_hash: String,
        session: String,
        /// RFC 3339.
        session_expires_at: String,
    },
    /// A `ready` got the commons' challenge.
    Admitted {
        sent: bool,
        binding: String,
        /// Seconds since 1970.
        expires_at: u64,
    },
    /// A `readied` message was answered: its reply, and the exchange to
    /// review, or why it cannot be.
    Exchanged {
        sent: bool,
        proof: ProofLine,
        reply: Value,
        /// The request and reply bodies, in standard base64.
        request: String,
        response: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        receipt: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        no_receipt: Option<String>,
    },
    /// A `review` came back from the witness.
    Reviewed {
        sent: bool,
        /// The envelope's bytes, in standard base64.
        envelope: String,
        certificate: String,
        signature: String,
        evidence: String,
        evidence_signature: String,
        submission_id: String,
        trace_id: String,
    },
    /// An `upload` was taken: the commons' answer as it came.
    Uploaded { sent: bool, commons: Value },
    /// A `status` was read: the commons' answer as it came.
    Reported { sent: bool, commons: Value },
    /// A `withdraw` was taken: the commons' answer as it came, and the
    /// account session if it was renewed.
    Withdrawn {
        sent: bool,
        commons: Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        session: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_expires_at: Option<String>,
    },
    /// A line stopped at the step `stop`; `code` is the host's status,
    /// given only when `stop` is `status`.
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
}

impl ProofLine {
    fn of(proof: &Proof, passed_at: u64) -> ProofLine {
        ProofLine {
            passed_at,
            model_servers: proof.intel.instances,
            gpus: proof.gpu.gpus,
            model_key: hex::encode(proof.intel.model_key),
            gateway_tls_key_sha256: hex::encode(proof.intel.gateway_tls_key),
        }
    }
}

/// What the helper keeps between lines: the pins, what [`Kept`] holds, the
/// roots every sharing certificate is checked against, and a sign-in that
/// `listen` opened and `enrol` has not yet taken.
pub struct Helper {
    pins: Pins,
    kept: Kept,
    roots: RootCertStore,
    signin: Option<Signin>,
}

impl Helper {
    pub fn new(pins: Pins, kept: Kept) -> Helper {
        Helper::with_roots(pins, kept, mozilla())
    }

    pub(crate) fn with_roots(pins: Pins, kept: Kept, roots: RootCertStore) -> Helper {
        Helper {
            pins,
            kept,
            roots,
            signin: None,
        }
    }

    /// The answer to one line of the helper's input, as one line of JSON
    /// without its line end. A line that is not a known request gets a stop
    /// of its own, `line`.
    pub fn respond(&mut self, line: &[u8]) -> String {
        let answer = match serde_json::from_slice::<Request>(line) {
            Ok(request) => self.run(request),
            Err(error) => Answer::Stopped {
                sent: false,
                stop: "line",
                code: None,
                text: unreadable(&error),
            },
        };
        serde_json::to_string(&answer).expect("an answer serializes")
    }

    fn run(&mut self, request: Request) -> Answer {
        match request {
            Request::Check {
                model,
                route,
                proof_age,
            } => match check(
                &route.routes(),
                &model,
                &self.pins,
                &mut self.kept,
                Duration::from_secs(proof_age),
            ) {
                Ok(passed) => Answer::Passed {
                    sent: false,
                    proof: ProofLine::of(&passed.proof, passed.at),
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
                &self.pins,
                &mut self.kept,
                Duration::from_secs(proof_age),
            ) {
                Ok(answered) => Answer::Replied {
                    sent: true,
                    proof: ProofLine::of(&answered.proof, answered.proof_passed_at),
                    reply: answered.reply,
                },
                Err(stop) => stopped(&stop),
            },
            Request::Readied {
                model,
                route,
                proof_age,
                key,
                body,
                admission,
            } => match ask_readied(
                &route.routes(),
                &self.roots,
                &model,
                &key,
                &serde_json::to_vec(&body).expect("JSON serializes"),
                &admission,
                &self.pins,
                &mut self.kept,
                Duration::from_secs(proof_age),
            ) {
                Ok(exchanged) => {
                    let (receipt, no_receipt) = match exchanged.receipt {
                        Ok(receipt) => (Some(receipt), None),
                        Err(why) => (None, Some(why)),
                    };
                    Answer::Exchanged {
                        sent: true,
                        proof: ProofLine::of(&exchanged.proof, exchanged.proof_passed_at),
                        reply: exchanged.reply,
                        request: STANDARD.encode(&exchanged.request),
                        response: STANDARD.encode(&exchanged.response),
                        receipt,
                        no_receipt,
                    }
                }
                Err(stop) => stopped(&stop),
            },
            Request::Listen { route } => self.listen(&route).unwrap_or_else(halted),
            Request::Enrol { route, device_key } => {
                self.enrol(&route, &device_key).unwrap_or_else(halted)
            }
            Request::Ready {
                route,
                device_key,
                account,
                scopes,
                uses,
            } => Device::from_line(&device_key)
                .and_then(|device| {
                    share::ready(
                        &self.net(&route.routes()),
                        &device,
                        &account,
                        &scopes,
                        &uses,
                    )
                })
                .map(|admission| Answer::Admitted {
                    sent: true,
                    binding: admission.binding,
                    expires_at: admission.expires_at,
                })
                .unwrap_or_else(halted),
            Request::Review {
                route,
                account,
                scopes,
                uses,
                exchange,
                version,
            } => {
                let routes = route.routes();
                let net = Net {
                    route: routes.near,
                    intel: routes.intel,
                    roots: &self.roots,
                };
                share::review(
                    &net,
                    &mut self.kept,
                    &account,
                    &scopes,
                    &uses,
                    &exchange,
                    &version,
                )
                .map(|reviewed| Answer::Reviewed {
                    sent: true,
                    envelope: STANDARD.encode(&reviewed.envelope),
                    certificate: reviewed.certificate,
                    signature: reviewed.signature,
                    evidence: reviewed.evidence,
                    evidence_signature: reviewed.evidence_signature,
                    submission_id: reviewed.submission_id,
                    trace_id: reviewed.trace_id,
                })
                .unwrap_or_else(halted)
            }
            Request::Upload {
                route,
                device_key,
                account,
                scopes,
                uses,
                envelope,
            } => Device::from_line(&device_key)
                .and_then(|device| {
                    let net = self.net(&route.routes());
                    share::upload(&net, &device, &account, &scopes, &uses, &envelope)
                })
                .map(|commons| Answer::Uploaded {
                    sent: true,
                    commons,
                })
                .unwrap_or_else(halted),
            Request::Status {
                route,
                device_key,
                account,
                submissions,
            } => Device::from_line(&device_key)
                .and_then(|device| {
                    share::status(&self.net(&route.routes()), &device, &account, &submissions)
                })
                .map(|commons| Answer::Reported {
                    sent: true,
                    commons,
                })
                .unwrap_or_else(halted),
            Request::Withdraw {
                route,
                session,
                submission,
            } => share::withdraw(&self.net(&route.routes()), &session, &submission)
                .map(|withdrawn| Answer::Withdrawn {
                    sent: true,
                    commons: withdrawn.commons,
                    session: withdrawn.session,
                    session_expires_at: withdrawn.session_expires_at,
                })
                .unwrap_or_else(halted),
        }
    }

    /// Opens a sign-in, in place of one left waiting, whose listener closes.
    fn listen(&mut self, route: &RouteLine) -> Result<Answer, Halt> {
        self.signin = None;
        let (signin, urls) = share::listen(&self.net(&route.routes()))?;
        self.signin = Some(signin);
        let [github, google] = <[String; 2]>::try_from(urls).expect("two providers");
        Ok(Answer::Listening {
            sent: false,
            github,
            google,
        })
    }

    /// Takes the waiting sign-in and enrols with it.
    fn enrol(&mut self, route: &RouteLine, device_key: &str) -> Result<Answer, Halt> {
        let device = Device::from_line(device_key)?;
        let signin = self
            .signin
            .take()
            .ok_or_else(|| Halt::Request("no sign-in is waiting: send `listen` first".into()))?;
        let enrolled = share::enrol(&self.net(&route.routes()), signin, &device)?;
        Ok(Answer::Enrolled {
            sent: true,
            account: enrolled.account,
            account_id: enrolled.account_id,
            anchor_hash: enrolled.anchor_hash,
            session: enrolled.session,
            session_expires_at: enrolled.session_expires_at,
        })
    }

    fn net<'a>(&'a self, routes: &Routes<'a>) -> Net<'a> {
        Net {
            route: routes.near,
            intel: routes.intel,
            roots: &self.roots,
        }
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

fn halted(halt: Halt) -> Answer {
    let (step, code) = match &halt {
        Halt::Request(_) => ("request", None),
        Halt::Signin(_) => ("signin", None),
        Halt::Fetch(_) => ("fetch", None),
        Halt::Claim(_) => ("claim", None),
        Halt::Refused(_) => ("refused", None),
        Halt::Connect(_) => ("connect", None),
        Halt::Send(_) => ("send", None),
        Halt::Status { code, .. } => ("status", Some(*code)),
        Halt::Reply(_) => ("reply", None),
    };
    Answer::Stopped {
        sent: halt.sent(),
        stop: step,
        code,
        text: halt.to_string(),
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

    use super::Helper;
    use crate::e2ee::ReplyKey;
    use crate::{GpuProof, IntelProof, Kept, Passed, Pins, Proof, TcbStatus};

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
                    model_key: ReplyKey([0x42; 32]).public(),
                    instances: 3,
                    gateway_tcb: TcbStatus::UpToDate,
                    model_tcb: vec![TcbStatus::UpToDate; 3],
                },
                gpu: GpuProof { gpus: 8 },
            },
            at,
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
        kept.keep(MODEL, &passed(now - 5), 600);
        let mut helper = Helper::new(pins, kept);

        let check = json!({"request": "check", "model": MODEL, "route": route, "proof_age": 600});
        let answer: Value =
            serde_json::from_str(&helper.respond(check.to_string().as_bytes())).unwrap();
        assert_eq!(answer["answer"], "passed", "{answer}");
        assert_eq!(answer["sent"], false);
        assert_eq!(answer["proof"]["passed_at"], now - 5);
        assert_eq!(answer["proof"]["model_servers"], 3);
        assert_eq!(answer["proof"]["gpus"], 8);
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
            serde_json::from_str(&helper.respond(ask.to_string().as_bytes())).unwrap();
        std::fs::remove_dir_all(&folder).unwrap();
        assert_eq!(answer["answer"], "stopped", "{answer}");
        assert_eq!(answer["stop"], "connect");
        assert_eq!(answer["sent"], false);
        assert!(connections.load(Ordering::SeqCst) > 0);
    }
}
