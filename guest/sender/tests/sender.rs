//! Functional checks of the sender against stand-ins, test-only: a SOCKS5
//! stand-in for the guest's Tor port, which records each connection's user
//! name and destination and passes it to the local server named for that
//! destination; the provider's MPP root; and the Tempo network's RPC. They
//! cover what happens after payment (the answer and the ways it stops), the
//! check of the balance before anything reaches the provider, the headers
//! that go out, and the Tor identities each connection uses.
//!
//!     cargo test --manifest-path guest/sender/Cargo.toml

use std::collections::HashMap;
use std::net::SocketAddr;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

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

#[derive(Clone)]
struct Seen {
    connections: Arc<Mutex<Vec<Connection>>>,
    requests: Arc<Mutex<Vec<Request>>>,
    rpc: Arc<Mutex<Vec<String>>>,
}

/// What the provider stand-in answers a chat request with.
#[derive(Clone)]
struct Provider {
    seen: Seen,
    status: u16,
    body: Value,
}

/// The stand-ins and a sender to ask.
struct Stage {
    _stand_ins: tokio::runtime::Runtime,
    sender: tokio::runtime::Runtime,
    network: Network,
    seen: Seen,
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
        };
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
            let rpc = Router::new()
                .route("/", post(rpc))
                .with_state((seen.clone(), balance));
            let routes = HashMap::from([
                (PROVIDER.to_owned(), listen(provider).await),
                (RPC.to_owned(), listen(rpc).await),
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
            tor,
        };
        Self {
            _stand_ins: stand_ins,
            sender,
            network,
            seen,
        }
    }

    /// One request as the host makes it: waits for the turn, sends it, keeps
    /// each deposit reported, and returns the answer and what was kept.
    fn ask(&self, request: Value) -> (Value, Vec<Value>) {
        let (sender, host) = UnixStream::pair().unwrap();
        std::thread::scope(|scope| {
            let served = scope.spawn(|| serve(&self.sender, &self.network, sender).unwrap());
            let mut frames = Frames::new(host);
            assert_eq!(frames.read().unwrap().unwrap().0, b'Y');
            frames
                .write(b'R', &serde_json::to_vec(&request).unwrap())
                .unwrap();
            let mut kept = vec![];
            loop {
                let (kind, payload) = frames.read().unwrap().unwrap();
                match kind {
                    b'S' => {
                        kept.push(serde_json::from_slice(&payload).unwrap());
                        frames.write(b'K', &[]).unwrap();
                    }
                    b'A' => {
                        served.join().unwrap();
                        return (serde_json::from_slice(&payload).unwrap(), kept);
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

async fn rpc(State((seen, balance)): State<(Seen, u128)>, Json(call): Json<Value>) -> Json<Value> {
    let method = call["method"].as_str().unwrap_or_default().to_owned();
    seen.rpc.lock().unwrap().push(method.clone());
    let result = match method.as_str() {
        "eth_call" => json!(format!("0x{balance:064x}")),
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
        "escrow": "0x4d50500000000000000000000000000000000000", "chainId": 4217, "opened": true,
    })
}

fn send(identity: &str, deposit: Value) -> Value {
    json!({
        "op": "send", "key": key(), "deposit": deposit, "model": "cheap", "identity": identity,
        "messages": [
            { "role": "user", "content": "Name a calm colour." },
            { "role": "assistant", "content": "Sage green." },
            { "role": "user", "content": "What is a good name for a goldfish?" },
        ],
    })
}

fn is_identity(user: &str) -> bool {
    user.len() == 64 && user.bytes().all(|b| b.is_ascii_hexdigit())
}

#[test]
fn a_send_carries_only_the_turns_and_brings_the_answer_back() {
    let stage = Stage::new(
        200,
        completion(
            json!({ "role": "assistant", "content": "Bubbles." }),
            "stop",
        ),
        5_000_000,
    );
    let identity = "ab".repeat(32);
    let request = send(&identity, Value::Null);
    let (reply, kept) = stage.ask(request.clone());
    assert_eq!(reply, json!({ "ok": { "answer": "Bubbles." } }));
    assert!(kept.is_empty());

    {
        let requests = stage.seen.requests.lock().unwrap();
        let [sent] = requests.as_slice() else {
            panic!("{} requests", requests.len())
        };
        assert_eq!(sent.path, "/mpp/v1/chat/completions");
        let body: Value = serde_json::from_slice(&sent.body).unwrap();
        assert_eq!(
            body,
            json!({ "model": "cheap", "messages": request["messages"], "stream": false })
        );
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
    assert_eq!(reply, json!({ "ok": { "answer": "Bubbles." } }));
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
    let stage = Stage::new(
        200,
        completion(json!({ "content": "Goldie." }), "length"),
        0,
    );
    let (reply, _) = stage.ask(send(&"ab".repeat(32), usable()));
    assert_eq!(reply, json!({ "ok": { "answer": "Goldie." } }));
    assert!(stage.seen.rpc.lock().unwrap().is_empty());
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
        (
            200,
            completion(json!({ "content": "Hm." }), "content_filter"),
            "answer_refused",
        ),
        (
            200,
            completion(json!({ "content": null, "refusal": "No." }), "stop"),
            "answer_refused",
        ),
        (
            200,
            completion(json!({ "content": "  " }), "stop"),
            "answer_refused",
        ),
        (200, json!({ "choices": [] }), "failed"),
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
        send(&"ab".repeat(32), Value::Null),
        send(&"ab".repeat(32), usable()),
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

    // A deposit not yet confirmed open is shown as it was kept.
    let mut pending = usable();
    pending["opened"] = json!(false);
    let (reply, _) = stage.ask(json!({ "op": "wallet", "address": address, "deposit": pending }));
    assert_eq!(
        reply["ok"]["deposit"],
        json!({ "deposit": "1000000", "spent": "0", "pending": true })
    );
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
