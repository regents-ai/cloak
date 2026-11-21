//! Functional checks of the sender against stand-ins, test-only: a SOCKS5
//! stand-in for the guest's Tor port, which records each connection's user
//! name and destination and passes it to the local server named for that
//! destination; the provider's MPP root; the Tempo network's RPC, which also
//! stands in for Base's; and Venice's API. They cover what happens after
//! payment (the completion and the ways it stops), the check of the balance
//! before anything reaches the provider, a deposit whose opening may not have
//! landed, the body and headers that go out, the provider's list of models,
//! the Tor identities each connection uses, and for Venice: that nothing
//! leaves for anywhere but its API with its header names, the signatures,
//! the end of an answer the host stops taking, and no key in a stop or the
//! log.
//!
//!     cargo test --manifest-path guest/sender/Cargo.toml

use std::collections::HashMap;
use std::net::SocketAddr;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, Uri};
use axum::routing::{get, post};
use axum::{Json, Router};
use cloak_sender::{serve, Frames, Network};
use mpp::protocol::methods::tempo::USDC;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const PROVIDER: &str = "provider.test";
const RPC: &str = "rpc.test";
const VENICE: &str = "venice.test";
const BASE: &str = "base.test";
/// The network's channel reserve, which the sender asks for a channel's state.
const RESERVE: &str = "0x4d50500000000000000000000000000000000000";

/// One connection through the SOCKS stand-in.
#[derive(Clone, Debug)]
struct Connection {
    user: String,
    host: String,
    /// The destination came as a name, for Tor to resolve.
    named: bool,
}

/// One request the provider stand-in took.
struct Request {
    path: String,
    headers: HeaderMap,
    body: Bytes,
}

/// One request the Venice stand-in took, as it came.
#[derive(Clone, Debug)]
struct Asked {
    line: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

#[derive(Clone)]
struct Seen {
    connections: Arc<Mutex<Vec<Connection>>>,
    requests: Arc<Mutex<Vec<Request>>>,
    rpc: Arc<Mutex<Vec<String>>>,
    venice: Arc<Mutex<Vec<Asked>>>,
    /// The Venice stand-in could not write an answer on: the sender's
    /// connection had ended.
    cut: Arc<Mutex<bool>>,
}

/// What the provider stand-in answers a chat request with.
#[derive(Clone)]
struct Provider {
    seen: Seen,
    status: u16,
    body: Value,
}

/// What the network stand-in answers with.
#[derive(Clone)]
struct Chain {
    seen: Seen,
    balance: u128,
    channel: Arc<Mutex<u128>>,
}

/// The stand-ins and a sender to ask.
struct Stage {
    _stand_ins: tokio::runtime::Runtime,
    sender: tokio::runtime::Runtime,
    network: Network,
    seen: Seen,
    /// The deposit the network shows for any channel, with nothing settled
    /// and no close asked for: none, as for a channel never opened, until a
    /// test sets it.
    channel: Arc<Mutex<u128>>,
}

impl Stage {
    fn new(status: u16, body: Value, balance: u128) -> Self {
        let stand_ins = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let seen = Seen {
            connections: Default::default(),
            requests: Default::default(),
            rpc: Default::default(),
            venice: Default::default(),
            cut: Default::default(),
        };
        let channel = Arc::new(Mutex::new(0));
        let tor = stand_ins.block_on(async {
            let provider = Router::new()
                .route(
                    "/mpp/setup",
                    get(|| async { format!("Tempo mainnet, chain 4217, pays in USDC.e {USDC}") }),
                )
                .route(
                    "/mpp/v1/models",
                    get(|| async {
                        Json(json!({ "data": [
                            { "id": "cheap", "pricing": { "input": 0.1, "output": 0.2 } },
                            { "id": "unpriced" },
                        ] }))
                    }),
                )
                .route("/mpp/v1/chat/completions", post(chat))
                .with_state(Provider {
                    seen: seen.clone(),
                    status,
                    body,
                });
            let rpc = Router::new().route("/", post(rpc)).with_state(Chain {
                seen: seen.clone(),
                balance,
                channel: channel.clone(),
            });
            let rpc = listen(rpc).await;
            let venice_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let venice_address = venice_listener.local_addr().unwrap();
            tokio::spawn(venice(venice_listener, seen.clone()));
            let routes = HashMap::from([
                (PROVIDER.to_owned(), listen(provider).await),
                (RPC.to_owned(), rpc),
                (BASE.to_owned(), rpc),
                (VENICE.to_owned(), venice_address),
            ]);
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let tor = listener.local_addr().unwrap();
            tokio::spawn(socks(listener, routes, seen.clone()));
            tor
        });
        let sender = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let network = Network {
            provider: format!("http://{PROVIDER}/mpp"),
            rpc: format!("http://{RPC}/"),
            venice: format!("http://{VENICE}"),
            base: format!("http://{BASE}/"),
            tor,
        };
        Self {
            _stand_ins: stand_ins,
            sender,
            network,
            seen,
            channel,
        }
    }

    /// One request as the host makes it: waits for the turn, sends it, keeps
    /// each deposit reported, and returns the answer and what was kept.
    fn ask(&self, request: Value) -> (Value, Vec<Value>) {
        let exchanged = self.exchange(request);
        assert!(exchanged.head.is_none() && exchanged.body.is_empty());
        (exchanged.reply, exchanged.kept)
    }

    /// As `ask`, also taking a Venice answer's head and body as they come.
    fn exchange(&self, request: Value) -> Exchanged {
        let (sender, host) = UnixStream::pair().unwrap();
        std::thread::scope(|scope| {
            let served = scope.spawn(|| serve(&self.sender, &self.network, sender).unwrap());
            let mut frames = Frames::new(host);
            assert_eq!(frames.read().unwrap().unwrap().0, b'Y');
            frames
                .write(b'R', &serde_json::to_vec(&request).unwrap())
                .unwrap();
            let (mut kept, mut head, mut body) = (vec![], None, vec![]);
            loop {
                let (kind, payload) = frames.read().unwrap().unwrap();
                match kind {
                    b'S' => {
                        kept.push(serde_json::from_slice(&payload).unwrap());
                        frames.write(b'K', &[]).unwrap();
                    }
                    b'V' => {
                        assert!(head.is_none(), "a second head");
                        head = Some(serde_json::from_slice(&payload).unwrap());
                    }
                    b'P' => {
                        assert!(head.is_some(), "a piece before the head");
                        body.extend(payload);
                    }
                    b'A' => {
                        return Exchanged {
                            reply: serde_json::from_slice(&payload).unwrap(),
                            kept,
                            head,
                            body,
                            logged: served.join().unwrap(),
                        };
                    }
                    other => panic!("unexpected frame {other}"),
                }
            }
        })
    }

    fn connections(&self) -> Vec<Connection> {
        self.seen.connections.lock().unwrap().clone()
    }
}

/// What one request brought the host.
struct Exchanged {
    reply: Value,
    kept: Vec<Value>,
    head: Option<Value>,
    body: Vec<u8>,
    /// The request's name and outcome, which are all the log has of it.
    logged: (&'static str, &'static str),
}

/// A chat's answer from the Venice stand-in, event by event.
const EVENTS: [&str; 3] = [
    "data: {\"choices\":[{\"delta\":{\"content\":\"Sage\"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\" green.\"}}]}\n\n",
    "data: [DONE]\n\n",
];

/// Venice's API as the sender sees it, by hand so that a test sees what came
/// byte for byte and when the sender's connection ends. Each connection takes
/// one request. /api/v1/chat/completions streams `EVENTS`, and
/// /api/v1/endless an event every 20 ms until it cannot write on.
async fn venice(listener: TcpListener, seen: Seen) {
    loop {
        let (mut stream, _) = listener.accept().await.unwrap();
        let seen = seen.clone();
        tokio::spawn(async move {
            let mut taken = vec![];
            let end = loop {
                if let Some(end) = taken.windows(4).position(|w| w == b"\r\n\r\n") {
                    break end;
                }
                let mut buffer = [0; 4096];
                let read = stream.read(&mut buffer).await?;
                if read == 0 {
                    return Ok(());
                }
                taken.extend_from_slice(&buffer[..read]);
            };
            let head = String::from_utf8(taken[..end].to_vec()).unwrap();
            let mut lines = head.split("\r\n");
            let line = lines.next().unwrap().to_owned();
            let headers: Vec<(String, String)> = lines
                .map(|line| {
                    let (name, value) = line.split_once(": ").unwrap();
                    (name.to_owned(), value.to_owned())
                })
                .collect();
            let length = headers
                .iter()
                .find(|(name, _)| name == "content-length")
                .map_or(0, |(_, value)| value.parse().unwrap());
            let mut body = taken[end + 4..].to_vec();
            while body.len() < length {
                let mut buffer = [0; 4096];
                let read = stream.read(&mut buffer).await?;
                body.extend_from_slice(&buffer[..read]);
            }
            let path = line.split(' ').nth(1).unwrap().to_owned();
            seen.venice.lock().unwrap().push(Asked {
                line,
                headers,
                body,
            });
            let chunk = |event: &str| format!("{:x}\r\n{event}\r\n", event.len());
            let streaming = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n";
            match path.as_str() {
                "/api/v1/chat/completions" => {
                    stream.write_all(streaming.as_bytes()).await?;
                    for event in EVENTS {
                        stream.write_all(chunk(event).as_bytes()).await?;
                    }
                    stream.write_all(b"0\r\n\r\n").await
                }
                "/api/v1/endless" => {
                    stream.write_all(streaming.as_bytes()).await?;
                    loop {
                        if stream.write_all(chunk(EVENTS[0]).as_bytes()).await.is_err() {
                            *seen.cut.lock().unwrap() = true;
                            return Ok(());
                        }
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                }
                _ => {
                    stream
                        .write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")
                        .await
                }
            }
        });
    }
}

async fn listen(app: Router) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    address
}

async fn chat(
    State(provider): State<Provider>,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> (StatusCode, Json<Value>) {
    provider.seen.requests.lock().unwrap().push(Request {
        path: uri.path().to_owned(),
        headers,
        body,
    });
    (
        StatusCode::from_u16(provider.status).unwrap(),
        Json(provider.body),
    )
}

async fn rpc(State(chain): State<Chain>, Json(call): Json<Value>) -> Json<Value> {
    let method = call["method"].as_str().unwrap_or_default().to_owned();
    chain.seen.rpc.lock().unwrap().push(method.clone());
    let to = call["params"][0]["to"].as_str().unwrap_or_default();
    let result = match method.as_str() {
        // A channel's state: what is settled, its deposit and when its close
        // was asked for, a word each.
        "eth_call" if to.eq_ignore_ascii_case(RESERVE) => {
            let (settled, deposit, close) = (0, *chain.channel.lock().unwrap(), 0);
            json!(format!("0x{settled:064x}{deposit:064x}{close:064x}"))
        }
        "eth_call" => json!(format!("0x{:064x}", chain.balance)),
        "eth_chainId" => json!("0x1079"),
        _ => {
            return Json(
                json!({ "jsonrpc": "2.0", "id": call["id"], "error": { "code": -32601, "message": "not here" } }),
            )
        }
    };
    Json(json!({ "jsonrpc": "2.0", "id": call["id"], "result": result }))
}

/// The guest's Tor port as the sender sees it: SOCKS5 with a user name and
/// password, destinations by name.
async fn socks(listener: TcpListener, routes: HashMap<String, SocketAddr>, seen: Seen) {
    loop {
        let (mut client, _) = listener.accept().await.unwrap();
        let (routes, seen) = (routes.clone(), seen.clone());
        tokio::spawn(async move {
            let mut head = [0u8; 2];
            client.read_exact(&mut head).await?;
            let mut methods = vec![0; head[1] as usize];
            client.read_exact(&mut methods).await?;
            assert!(methods.contains(&2), "the sender offers no user name");
            client.write_all(&[5, 2]).await?;
            client.read_exact(&mut head).await?;
            let mut user = vec![0; head[1] as usize];
            client.read_exact(&mut user).await?;
            let mut length = [0u8; 1];
            client.read_exact(&mut length).await?;
            let mut password = vec![0; length[0] as usize];
            client.read_exact(&mut password).await?;
            client.write_all(&[1, 0]).await?;
            let mut request = [0u8; 4];
            client.read_exact(&mut request).await?;
            let host = if request[3] == 3 {
                client.read_exact(&mut length).await?;
                let mut name = vec![0; length[0] as usize];
                client.read_exact(&mut name).await?;
                String::from_utf8(name).unwrap()
            } else {
                String::new()
            };
            let mut port = [0u8; 2];
            client.read_exact(&mut port).await?;
            seen.connections.lock().unwrap().push(Connection {
                user: String::from_utf8(user).unwrap(),
                host: host.clone(),
                named: request[3] == 3,
            });
            let Some(address) = routes.get(&host) else {
                return client.write_all(&[5, 4, 0, 1, 0, 0, 0, 0, 0, 0]).await;
            };
            let mut server = TcpStream::connect(address).await?;
            client.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            tokio::io::copy_bidirectional(&mut client, &mut server)
                .await
                .map(|_| ())
        });
    }
}

fn completion(message: Value, finish: &str) -> Value {
    json!({ "choices": [{ "index": 0, "message": message, "finish_reason": finish }] })
}

fn key() -> String {
    format!("0x{}", "11".repeat(32))
}

/// A deposit that can pay, as the host keeps it; it never existed.
fn usable() -> Value {
    let address = "0x0000000000000000000000000000000000000001";
    json!({
        "key": "made-up", "channelId": format!("0x{}01", "00".repeat(31)), "cumulativeAmount": "0", "deposit": "1000000",
        "descriptor": { "payer": address, "payee": address, "operator": address, "token": USDC,
                        "salt": format!("0x{}", "00".repeat(32)), "authorizedSigner": address,
                        "expiringNonceHash": format!("0x{}", "00".repeat(32)) },
        "escrow": RESERVE, "chainId": 4217, "opened": true,
    })
}

/// That deposit kept before its opening was known to land: as the toolkit
/// keeps one before its opening leaves, naming the challenge it answers, and
/// with `opened` false.
fn openings() -> [Value; 2] {
    let mut kept = usable();
    kept["pendingOpen"] = json!("challenge");
    let mut unconfirmed = usable();
    unconfirmed["opened"] = json!(false);
    [kept, unconfirmed]
}

/// The body as the Mac builds it, with a tool and its settings, which the
/// sender posts byte for byte.
const BODY: &str = r#"{"messages":[{"content":"Name a calm colour.","role":"user"},{"content":"Sage green.","role":"assistant"},{"content":"Suggest a goldfish name.","role":"user"}],"model":"cheap","stream":false,"temperature":0.7,"tools":[{"type":"function","function":{"name":"look","parameters":{}}}]}"#;

fn send(identity: &str, deposit: Value) -> Value {
    json!({ "op": "send", "key": key(), "deposit": deposit, "identity": identity, "body": BODY })
}

/// The completion the provider stand-in answered with, as the sender
/// returns it.
fn answered(completion: &Value) -> Value {
    json!({ "ok": { "completion": completion.to_string() } })
}

fn is_identity(user: &str) -> bool {
    user.len() == 64 && user.bytes().all(|b| b.is_ascii_hexdigit())
}

#[test]
fn a_send_carries_only_the_body_and_brings_the_completion_back() {
    let bubbles = completion(
        json!({ "role": "assistant", "content": "Bubbles." }),
        "stop",
    );
    let stage = Stage::new(200, bubbles.clone(), 5_000_000);
    let identity = "ab".repeat(32);
    let (reply, kept) = stage.ask(send(&identity, Value::Null));
    assert_eq!(reply, answered(&bubbles));
    assert!(kept.is_empty());

    {
        let requests = stage.seen.requests.lock().unwrap();
        let [sent] = requests.as_slice() else {
            panic!("{} requests", requests.len())
        };
        assert_eq!(sent.path, "/mpp/v1/chat/completions");
        assert_eq!(sent.body, BODY.as_bytes());
        let mut names: Vec<_> = sent.headers.keys().map(|name| name.as_str()).collect();
        names.sort();
        eprintln!("headers to the provider: {:?}", sent.headers);
        assert_eq!(
            names,
            [
                "accept",
                "accept-payment",
                "content-length",
                "content-type",
                "host"
            ]
        );
    }

    let connections = stage.connections();
    assert!(connections.iter().all(|c| c.named), "{connections:?}");
    let provider: Vec<_> = connections.iter().filter(|c| c.host == PROVIDER).collect();
    let rpc: Vec<_> = connections.iter().filter(|c| c.host == RPC).collect();
    assert_eq!(provider.len(), 1);
    assert_eq!(provider[0].user, identity);
    assert!(
        !rpc.is_empty()
            && rpc
                .iter()
                .all(|c| is_identity(&c.user) && c.user != identity),
        "{connections:?}"
    );
    assert_eq!(connections.len(), provider.len() + rpc.len());

    // Another conversation's send goes as its own identity.
    let other = "cd".repeat(32);
    let (reply, _) = stage.ask(send(&other, Value::Null));
    assert_eq!(reply, answered(&bubbles));
    assert_eq!(
        stage
            .connections()
            .iter()
            .filter(|c| c.host == PROVIDER)
            .map(|c| c.user.clone())
            .collect::<Vec<_>>(),
        [identity, other]
    );
}

#[test]
fn an_unfunded_send_stops_before_anything_reaches_the_provider() {
    let stage = Stage::new(
        200,
        completion(json!({ "content": "unused" }), "stop"),
        999_999,
    );
    let (reply, kept) = stage.ask(send(&"ab".repeat(32), Value::Null));
    assert_eq!(reply["stop"]["code"], "no_funds");
    assert!(kept.is_empty());
    assert!(stage.seen.requests.lock().unwrap().is_empty());
    assert!(stage.connections().iter().all(|c| c.host == RPC));
    assert_eq!(*stage.seen.rpc.lock().unwrap(), ["eth_call"]);
}

#[test]
fn a_deposit_that_can_pay_needs_no_balance() {
    let goldie = completion(json!({ "content": "Goldie." }), "length");
    let stage = Stage::new(200, goldie.clone(), 0);
    let (reply, _) = stage.ask(send(&"ab".repeat(32), usable()));
    assert_eq!(reply, answered(&goldie));
    assert!(stage.seen.rpc.lock().unwrap().is_empty());
}

/// An opening that landed holds the deposit, so the balance has dropped by
/// one: the toolkit recovers the deposit from the network, and the sender
/// does not stop first for want of a balance. The provider stand-in asks for
/// no payment, so what the toolkit then does is not shown here.
#[test]
fn an_opening_deposit_is_left_to_the_toolkit_whatever_the_balance() {
    let goldie = completion(json!({ "content": "Goldie." }), "stop");
    for deposit in openings() {
        let stage = Stage::new(200, goldie.clone(), 999_999);
        *stage.channel.lock().unwrap() = 1_000_000;
        let (reply, _) = stage.ask(send(&"ab".repeat(32), deposit.clone()));
        assert_eq!(reply, answered(&goldie), "{deposit}");
        assert_eq!(stage.seen.requests.lock().unwrap().len(), 1);
        assert!(stage.seen.rpc.lock().unwrap().is_empty());
    }
}

/// A deposit kept before its opening was known to land is shown as the
/// network shows its channel, and one the toolkit marked as opening is never
/// reported gone while the network shows none, so the host keeps its record
/// in case the opening still lands.
#[test]
fn an_opening_deposit_is_shown_as_the_network_shows_it() {
    let address = "0x0000000000000000000000000000000000000001";
    for deposit in openings() {
        let stage = Stage::new(200, json!({}), 999_999);
        let look = || {
            let request = json!({ "op": "wallet", "address": address, "deposit": deposit });
            stage.ask(request).0["ok"]["deposit"].clone()
        };
        let gone = deposit.get("pendingOpen").is_none();
        assert_eq!(
            look(),
            json!({ "deposit": "0", "spent": "0", "closeRequestedAt": 0, "withdrawAt": null, "gone": gone }),
            "{deposit}"
        );
        *stage.channel.lock().unwrap() = 1_000_000;
        assert_eq!(
            look(),
            json!({ "deposit": "1000000", "spent": "0", "closeRequestedAt": 0, "withdrawAt": null, "gone": false }),
            "{deposit}"
        );
    }
}

/// Whatever completion the provider gives comes back as it is: what to make
/// of it is for the Mac.
#[test]
fn a_completion_comes_back_as_the_provider_gave_it() {
    for body in [
        completion(json!({ "content": "Hm." }), "content_filter"),
        completion(
            json!({ "content": null, "tool_calls": [{ "id": "1", "type": "function", "function": { "name": "look", "arguments": "{}" } }] }),
            "tool_calls",
        ),
        json!({ "choices": [] }),
    ] {
        let stage = Stage::new(200, body.clone(), 0);
        let (reply, _) = stage.ask(send(&"ab".repeat(32), usable()));
        assert_eq!(reply, answered(&body));
    }
}

#[test]
fn the_models_are_the_providers_list_as_it_gives_it() {
    let stage = Stage::new(200, json!({}), 0);
    let (reply, kept) = stage.ask(json!({ "op": "models" }));
    let listed: Value = serde_json::from_str(reply["ok"]["models"].as_str().unwrap()).unwrap();
    assert_eq!(
        listed,
        json!({ "data": [
            { "id": "cheap", "pricing": { "input": 0.1, "output": 0.2 } },
            { "id": "unpriced" },
        ] })
    );
    assert!(kept.is_empty());
    let connections = stage.connections();
    assert!(
        connections.len() == 1
            && connections[0].host == PROVIDER
            && connections[0].named
            && is_identity(&connections[0].user),
        "{connections:?}"
    );
}

#[test]
fn each_way_a_send_stops_has_its_code() {
    let cases = [
        (404, json!({}), "model_unavailable"),
        (
            403,
            json!({ "error": { "code": "model_access_required" } }),
            "model_unavailable",
        ),
        (
            403,
            json!({ "error": { "code": "wallet_screened" } }),
            "wallet_refused",
        ),
        (401, json!({}), "wallet_refused"),
        (500, json!({}), "failed"),
    ];
    for (status, body, code) in cases {
        let stage = Stage::new(status, body.clone(), 0);
        let (reply, _) = stage.ask(send(&"ab".repeat(32), usable()));
        assert_eq!(reply["stop"]["code"], code, "{status} {body}: {reply}");
    }
}

#[test]
fn a_tor_port_that_refuses_is_tor_down() {
    let mut stage = Stage::new(200, json!({}), 5_000_000);
    stage.network.tor = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    for request in [
        json!({ "op": "wallet", "address": "0x0000000000000000000000000000000000000001", "deposit": null }),
        json!({ "op": "models" }),
        send(&"ab".repeat(32), Value::Null),
        send(&"ab".repeat(32), usable()),
        venice_chat(&format!("http://{VENICE}/api/v1/chat/completions")),
        json!({ "op": "venice_funds", "address": "0x0000000000000000000000000000000000000001" }),
    ] {
        let (reply, _) = stage.ask(request.clone());
        assert_eq!(reply["stop"]["code"], "tor_down", "{request}: {reply}");
    }
}

#[test]
fn the_wallet_shows_its_balance_the_setup_and_the_priced_models() {
    let stage = Stage::new(200, json!({}), 1_234_567);
    let address = "0x0000000000000000000000000000000000000001";
    let (reply, kept) = stage.ask(json!({ "op": "wallet", "address": address, "deposit": null }));
    assert_eq!(
        reply,
        json!({ "ok": {
        "balance": "1234567", "least": "1000000", "setup": true, "deposit": null,
        "models": [{ "id": "cheap", "pricing": { "input": 0.1, "output": 0.2 } }],
    } })
    );
    assert!(kept.is_empty());
    let connections = stage.connections();
    assert!(
        connections.iter().all(|c| c.named && is_identity(&c.user)),
        "{connections:?}"
    );
    let provider: Vec<_> = connections
        .iter()
        .filter(|c| c.host == PROVIDER)
        .map(|c| &c.user)
        .collect();
    assert!(connections
        .iter()
        .filter(|c| c.host == RPC)
        .all(|c| !provider.contains(&&c.user)));
}

#[test]
fn a_new_wallet_is_a_key_and_its_address() {
    let stage = Stage::new(200, json!({}), 0);
    let (first, _) = stage.ask(json!({ "op": "create" }));
    let (second, _) = stage.ask(json!({ "op": "create" }));
    for made in [&first, &second] {
        let key = made["ok"]["key"].as_str().unwrap();
        assert!(key.starts_with("0x") && key.len() == 66);
        assert!(made["ok"]["address"].as_str().unwrap().starts_with("0x"));
    }
    assert_ne!(first["ok"]["key"], second["ok"]["key"]);
    assert!(stage.connections().is_empty());
}

#[test]
fn a_request_that_does_not_read_stops_without_a_connection() {
    let stage = Stage::new(200, json!({}), 0);
    for request in [json!({ "op": "spend" }), send("not-hex", Value::Null)] {
        let (reply, _) = stage.ask(request);
        assert_eq!(reply["stop"]["code"], "failed");
    }
    assert!(stage.connections().is_empty());
}

/// The public test key of web3.js's documentation, and its address.
const TEST_KEY: &str = "0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318";
const TEST_ADDRESS: &str = "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23";

/// A Venice key as a test stands it in; never a real one.
const VENICE_KEY: &str = "VENICE-INFERENCE-KEY-test-only";

/// A Venice chat request as the Mac builds it, to `url`.
fn venice_chat(url: &str) -> Value {
    json!({
        "op": "venice", "identity": "ab".repeat(32), "method": "POST", "url": url,
        "headers": { "authorization": format!("Bearer {VENICE_KEY}"), "content-type": "application/json" },
        "body": r#"{"messages":[{"content":"Name a calm colour.","role":"user"}],"model":"m","stream":true}"#,
    })
}

/// Everything that is not a request for Venice's API, with its header
/// names, leaves nothing: other hosts, schemes, ports, user names and paths,
/// header names, a header value that would add a header, other methods, and
/// an identity that is not one. Against the live addresses, with only the Tor
/// port stood in: the one request for Venice's API, and the one for the
/// wallet's funds, leave for api.venice.ai and mainnet.base.org by name, and
/// nothing else leaves. Through the stand-ins, what reaches Venice is the
/// Mac's body and headers and HTTP's own, and its answer comes back as it
/// came.
#[test]
fn venice_requests_leave_for_venices_api_alone_with_its_header_names() {
    let mut stage = Stage::new(200, json!({}), 0);
    let live = Network {
        tor: stage.network.tor,
        ..Network::live()
    };
    let stood_in = std::mem::replace(&mut stage.network, live);
    let good = venice_chat("https://api.venice.ai/api/v1/chat/completions");
    let mut refused = vec![];
    for url in [
        "http://api.venice.ai/api/v1/chat/completions",
        "https://api.venice.ai.example/api/v1/chat/completions",
        "https://example.com/api/v1/chat/completions",
        "https://api.venice.ai:8443/api/v1/chat/completions",
        "https://cloak@api.venice.ai/api/v1/chat/completions",
        "https://api.venice.ai./api/v1/chat/completions",
        "https://api.venice.ai/api/v2/chat/completions",
        "https://api.venice.ai/api/v1",
        "https://api.venice.ai/api/v1/../v2/x",
        "https://api.venice.ai/api/v1/%2e%2e/x",
        "https://api.venice.ai/",
        "api.venice.ai/api/v1/chat/completions",
    ] {
        let mut request = good.clone();
        request["url"] = json!(url);
        refused.push(request);
    }
    for (name, value) in [
        ("cookie", "a=b"),
        ("x-venice-version", "1"),
        ("Authorization", "Bearer x"),
        ("host", "example.com"),
        (
            "content-type",
            "application/json\r\nx-forwarded-for: 1.2.3.4",
        ),
    ] {
        let mut request = good.clone();
        request["headers"][name] = json!(value);
        refused.push(request);
    }
    for (field, value) in [
        ("method", json!("PUT")),
        ("method", json!("CONNECT")),
        ("identity", json!("not-hex")),
        ("identity", json!("ab".repeat(31))),
    ] {
        let mut request = good.clone();
        request[field] = value;
        refused.push(request);
    }
    for request in refused {
        let exchanged = stage.exchange(request.clone());
        assert_eq!(exchanged.reply["stop"]["code"], "failed", "{request}");
        assert!(exchanged.head.is_none(), "{request}");
        assert!(
            stage.connections().is_empty(),
            "{request}: {:?}",
            stage.connections()
        );
    }

    // The SOCKS stand-in knows neither name, so each stops there.
    stage.exchange(good);
    stage.exchange(json!({ "op": "venice_funds", "address": TEST_ADDRESS }));
    let connections = stage.connections();
    let [venice, base] = connections.as_slice() else {
        panic!("{connections:?}")
    };
    assert!(venice.named && venice.host == "api.venice.ai" && venice.user == "ab".repeat(32));
    assert!(
        base.named
            && base.host == "mainnet.base.org"
            && is_identity(&base.user)
            && base.user != venice.user
    );

    stage.network = stood_in;
    let exchanged = stage.exchange(venice_chat(&format!(
        "http://{VENICE}/api/v1/chat/completions"
    )));
    assert_eq!(exchanged.reply, json!({ "ok": {} }));
    let head = exchanged.head.unwrap();
    assert_eq!(head["status"], 200);
    assert_eq!(head["headers"]["content-type"], "text/event-stream");
    assert_eq!(exchanged.body, EVENTS.concat().as_bytes());
    let asked = stage.seen.venice.lock().unwrap().clone();
    let [asked] = asked.as_slice() else {
        panic!("{asked:?}")
    };
    assert_eq!(asked.line, "POST /api/v1/chat/completions HTTP/1.1");
    assert_eq!(
        asked.body,
        venice_chat("")["body"].as_str().unwrap().as_bytes()
    );
    let mut headers = asked.headers.clone();
    headers.sort();
    let length = asked.body.len().to_string();
    assert_eq!(
        headers,
        [
            ("accept", "*/*"),
            ("authorization", &*format!("Bearer {VENICE_KEY}")),
            ("content-length", &*length),
            ("content-type", "application/json"),
            ("host", VENICE),
        ]
        .map(|(name, value)| (name.to_owned(), value.to_owned()))
    );
}

/// The signatures are the known ones, from Foundry's cast 1.8.6, which gives
/// web3.js's documented EIP-191 signature and the EIP-712 specification's
/// example signature for these keys: a Venice sign-in, and a five dollar
/// top-up exactly as VeniceTests builds it. Anything but a Venice sign-in
/// or a USDC transfer on Base is not signed. No connection is made.
#[test]
fn the_signatures_are_the_known_vectors() {
    let stage = Stage::new(200, json!({}), 0);
    let sign_in = format!(
        "api.venice.ai wants you to sign in with your Ethereum account:\n{TEST_ADDRESS}\n\nSign in to Venice AI\n\nURI: https://api.venice.ai/api/v1/chat/completions\nVersion: 1\nChain ID: 8453\nNonce: 8f3b2c1d0e9a8b7c6d5e4f3a2b1c0d9e\nIssued At: 2026-11-20T12:00:00.000Z\nExpiration Time: 2026-11-20T12:05:00.000Z"
    );
    let (signed, _) =
        stage.ask(json!({ "op": "venice_sign", "key": TEST_KEY, "message": sign_in }));
    assert_eq!(
        signed,
        json!({ "ok": { "signature": "0xbfbf3f2b2c76d9fe069414ae51fbb76c126200ae49979ad42ea640acff94bde457c4c96e7462349dcc73730c89a43a65f4a97994a7530b699dd66d989e07cf351b" } })
    );

    let transfer = || {
        json!({
            "types": {
                "EIP712Domain": [{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
                "TransferWithAuthorization": [{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}],
            },
            "primaryType": "TransferWithAuthorization",
            "domain": { "name": "USD Coin", "version": "2", "chainId": 8453, "verifyingContract": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" },
            "message": {
                "from": TEST_ADDRESS, "to": "0x2670B922ef37C7Df47158725C0CC407b5382293F", "value": "5000000",
                "validAfter": "1795218600", "validBefore": "1795219500", "nonce": format!("0x{}", "ab".repeat(32)),
            },
        })
    };
    let typed =
        |typed: Value| json!({ "op": "venice_typed", "key": TEST_KEY, "typed": typed.to_string() });
    let (signed, _) = stage.ask(typed(transfer()));
    assert_eq!(
        signed,
        json!({ "ok": { "signature": "0x040a9e69f427ddb42ff6321fb652a5e870ec467b85de57148f3cd0fc6ce97573011fa577e3a221ec3d37a04ac6dd345ae083ba141c04e419eb4e6ae1465ea6111b" } })
    );

    let mut refused = vec![json!({ "op": "venice_sign", "key": TEST_KEY, "message": "Some data" })];
    for (path, value) in [
        ("/domain/chainId", json!(1)),
        (
            "/domain/verifyingContract",
            json!("0x0000000000000000000000000000000000000001"),
        ),
        ("/domain/name", json!("USDC")),
        ("/primaryType", json!("Permit")),
        ("/types/TransferWithAuthorization/2/type", json!("uint128")),
        ("/message/spender", json!(TEST_ADDRESS)),
        ("/domain/salt", json!(format!("0x{}", "00".repeat(32)))),
    ] {
        let mut changed = transfer();
        let (parent, field) = path.rsplit_once('/').unwrap();
        changed.pointer_mut(parent).unwrap()[field] = value;
        refused.push(typed(changed));
    }
    for request in refused {
        let (reply, _) = stage.ask(request.clone());
        assert_eq!(reply["stop"]["code"], "failed", "{request}: {reply}");
    }
    assert!(stage.connections().is_empty());
}

/// When the host stops taking a Venice answer, as the Mac does when its
/// stream ends, the sender stops too and its connection to Venice ends.
#[test]
fn a_venice_answer_the_host_stops_taking_ends_its_request() {
    let stage = Stage::new(200, json!({}), 0);
    let mut request = venice_chat(&format!("http://{VENICE}/api/v1/endless"));
    request["method"] = json!("GET");
    request["body"] = Value::Null;
    let (sender, host) = UnixStream::pair().unwrap();
    std::thread::scope(|scope| {
        let served = scope.spawn(|| serve(&stage.sender, &stage.network, sender));
        let mut frames = Frames::new(host);
        assert_eq!(frames.read().unwrap().unwrap().0, b'Y');
        frames
            .write(b'R', &serde_json::to_vec(&request).unwrap())
            .unwrap();
        assert_eq!(frames.read().unwrap().unwrap().0, b'V');
        assert_eq!(frames.read().unwrap().unwrap().0, b'P');
        drop(frames);
        let stopped = Instant::now();
        // The sender's answer has nowhere to go.
        assert!(served.join().unwrap().is_err());
        assert!(
            stopped.elapsed() < Duration::from_secs(2),
            "the sender went on"
        );
    });
    let started = Instant::now();
    while !*stage.seen.cut.lock().unwrap() {
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "Venice's stand-in is still answering"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// No key, signature or header value reaches a stop's words or the log, on
/// any way a request carrying one stops: a key that does not read, a refused
/// message or typed data, a refused address, header name or header value,
/// Tor refusing, and Venice answering an error.
#[test]
fn no_key_reaches_a_stop_or_the_log() {
    let mut stage = Stage::new(200, json!({}), 0);
    let secrets = [
        VENICE_KEY,
        &TEST_KEY[2..],
        &TEST_KEY[2..64],
        "11111111111111",
    ];
    let unreadable = format!("0x{}zz", "11".repeat(31));
    let mut requests = vec![
        json!({ "op": "venice_sign", "key": unreadable, "message": "x" }),
        json!({ "op": "venice_sign", "key": format!("0x{}", "11".repeat(31)), "message": "x" }),
        json!({ "op": "venice_sign", "key": TEST_KEY, "message": "Some data" }),
        json!({ "op": "venice_typed", "key": TEST_KEY, "typed": "{}" }),
        json!({ "op": "venice_typed", "key": unreadable, "typed": "{}" }),
    ];
    let mut wrong_header = venice_chat(&format!("http://{VENICE}/api/v1/chat/completions"));
    wrong_header["headers"]["cookie"] = json!(VENICE_KEY);
    let mut broken_value = venice_chat(&format!("http://{VENICE}/api/v1/chat/completions"));
    broken_value["headers"]["authorization"] = json!(format!("Bearer {VENICE_KEY}\n"));
    // A request that does not read, at a value the reader would quote.
    let mut unread_headers = venice_chat(&format!("http://{VENICE}/api/v1/chat/completions"));
    unread_headers["headers"] = json!(format!("Bearer {VENICE_KEY}"));
    requests.extend([
        venice_chat("https://example.com/api/v1/chat/completions"),
        wrong_header,
        broken_value,
        unread_headers,
        venice_chat(&format!("http://{VENICE}/api/v1/missing")),
    ]);
    let check = |stage: &Stage, request: &Value| {
        let exchanged = stage.exchange(request.clone());
        let reply = exchanged.reply.to_string();
        let (name, outcome) = exchanged.logged;
        for secret in secrets {
            assert!(!reply.contains(secret), "{request}: {reply}");
        }
        assert!(
            ["venice", "venice_sign", "venice_typed", "unreadable"].contains(&name)
                && ["ok", "failed", "tor_down"].contains(&outcome),
            "{name} {outcome}"
        );
    };
    for request in &requests {
        check(&stage, request);
    }
    stage.network.tor = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    check(
        &stage,
        &venice_chat(&format!("http://{VENICE}/api/v1/chat/completions")),
    );
}
