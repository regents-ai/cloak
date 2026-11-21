//! The guest's sender, Token Inference's one way to a remote model
//! (decisions 10 and 25 in docs/plan.md). The host connects to it on the guest's
//! vsock port and, once it has its turn, sends one request; the sender pays
//! for it through the official MPP toolkit, or carries it to Venice, and
//! answers. Every connection it makes, to the provider, to the Tempo network,
//! to Venice's API and to Base alike, goes through the guest's Tor port with
//! a SOCKS user name of its own, and names are resolved by Tor: the guest has
//! no other way out.
//!
//! One connection, in frames of a kind byte, a four-byte big-endian length
//! and the payload:
//!
//! ```text
//! sender: Y            your turn; connections are served one at a time
//! host:   R <request>  JSON, below
//! sender: S <deposit>  the deposit's new state (JSON, or null when gone),
//! host:   K            once it is sealed on the Mac; zero or more of these
//! sender: L <head>     a Venice answer's {"status", "headers"}, once
//! sender: P <bytes>    its body as it arrives; zero or more of these
//! sender: A <reply>    {"ok": ...} or {"stop": {"code", "detail"}}
//! ```
//!
//! The host builds each request when its turn comes, from what it has kept,
//! so a request never carries a deposit older than the last one kept. The
//! wallet's key comes in the requests that sign and stays in this process's
//! memory only while one runs. No key, signature or header value reaches a
//! stop's words, nor the log, which has each request's name and outcome.

use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy::primitives::{address, Address, Bytes, TxKind, B256, U256};
use alloy::providers::{Provider, ProviderBuilder, RootProvider};
use alloy::rpc::client::ClientBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::SignerSync;
use alloy::sol_types::{Eip712Domain, SolStruct};
use mpp::client::channel_ops::{
    encode_precompile_request_close_call, encode_precompile_withdraw_call,
};
use mpp::client::tempo::charge::tx_builder::{build_tempo_tx, estimate_gas, TempoTxOptions};
use mpp::client::tempo::session::recovery::read_on_chain_channel_state;
use mpp::client::tempo::session::store::{
    ChannelStore, ChannelStoreError, ChannelStoreResult, StoredChannelEntry,
};
use mpp::client::tempo::signing::{sign_and_encode, TempoSigningMode};
use mpp::client::tempo::TempoClientError;
use mpp::client::{Fetch, HttpError, TempoSessionProvider};
use mpp::protocol::core::{format_authorization, parse_www_authenticate_all_bytes};
use mpp::protocol::methods::tempo::session::{ChannelDescriptor, SettlementRoute};
use mpp::protocol::methods::tempo::{CHAIN_ID, DEFAULT_RPC_URL, USDC};
use mpp::MppError;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};
use tempo_alloy::contracts::precompiles::{ITIP20, TIP20_CHANNEL_RESERVE_ADDRESS};
use tempo_alloy::primitives::transaction::Call;
use tempo_alloy::rpc::TempoTransactionRequest;
use tempo_alloy::TempoNetwork;

/// The guest's vsock port the host connects to.
pub const PORT: u32 = 8020;

const TURN: u8 = b'Y';
const REQUEST: u8 = b'R';
const KEEP: u8 = b'S';
const KEPT: u8 = b'K';
const ANSWER: u8 = b'A';
const HEAD: u8 = b'L';
const PIECE: u8 = b'P';
/// The largest frame either side takes.
const MAX_FRAME: usize = 16 << 20;

/// How long a deposit's owner waits, after asking the network to close it,
/// before taking it back.
const CLOSE_GRACE: u64 = 900;
/// Each request through Tor, from connecting to the last byte.
const REQUEST_LIMIT: Duration = Duration::from_secs(180);
/// The least balance a first deposit needs, checked before anything reaches
/// the provider: its suggested deposit, 1 USDC.e on 14 November 2026. The
/// toolkit opens and tops up each deposit at the size the provider's
/// challenge suggests, and at this size only when one suggests none.
const DEPOSIT: u128 = 1_000_000;

/// The only header names a Venice request carries: the key, the wallet's
/// sign-in, a top-up's payment and the body's type.
const VENICE_HEADERS: [&str; 4] = [
    "authorization",
    "sign-in-with-x",
    "payment-signature",
    "content-type",
];
/// The start of every message `venice_sign` signs: Venice's sign-in.
const VENICE_SIGN_IN: &str = "api.venice.ai wants you to sign in with your Ethereum account:\n";
/// USDC on Base, the one token `venice_typed` signs for and `venice_funds`
/// reads.
const BASE_USDC: Address = address!("833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
const BASE_CHAIN: u64 = 8453;

/// Where the sender's requests go: the provider's MPP root, the Tempo
/// network's RPC, Venice's API origin, Base's RPC and the guest's Tor port.
/// Only tests name others.
#[derive(Clone)]
pub struct Network {
    pub provider: String,
    pub rpc: String,
    pub venice: String,
    pub base: String,
    pub tor: SocketAddr,
}

impl Network {
    pub fn live() -> Self {
        Self {
            provider: "https://api.inference.boundless.network/mpp".into(),
            rpc: DEFAULT_RPC_URL.into(),
            venice: "https://api.venice.ai".into(),
            base: "https://mainnet.base.org".into(),
            tor: SocketAddr::from(([127, 0, 0, 1], 9050)),
        }
    }

    fn chat(&self) -> String {
        format!("{}/v1/chat/completions", self.provider)
    }

    /// A client whose every connection goes through Tor as `identity`,
    /// with names resolved by Tor, no proxy from the environment, no
    /// redirect followed and no header of its own beyond what HTTP needs.
    fn client(&self, identity: &str) -> Result<reqwest::Client, Stop> {
        let proxy = reqwest::Proxy::all(format!("socks5h://{identity}:cloak@{}", self.tor))?;
        Ok(reqwest::Client::builder()
            .no_proxy()
            .proxy(proxy)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(REQUEST_LIMIT)
            .build()?)
    }

    fn rpc(&self, client: &reqwest::Client) -> Result<RootProvider<TempoNetwork>, Stop> {
        let url = self
            .rpc
            .parse()
            .map_err(|e| Stop::failed(format!("RPC address: {e}")))?;
        Ok(ProviderBuilder::<_, _, TempoNetwork>::default()
            .connect_client(ClientBuilder::default().http_with_client(client.clone(), url)))
    }

    /// The toolkit's session payer for `signer`, paying in USDC.e only, its
    /// RPC through `rpc` and its requests to the provider through `client`.
    /// No most per deposit: the toolkit's only one caps what a deposit pays
    /// in all, and the balance is the limit.
    fn session(
        &self,
        signer: PrivateKeySigner,
        client: &reqwest::Client,
        rpc: &reqwest::Client,
        keep: Arc<dyn ChannelStore>,
    ) -> Result<TempoSessionProvider, Stop> {
        let origin = self
            .provider
            .parse()
            .map_err(|e| Stop::failed(format!("provider address: {e}")))?;
        Ok(TempoSessionProvider::new(signer, &self.rpc)?
            .with_http_client(rpc.clone())
            .with_hint_client(client.clone())
            .with_currencies([USDC])
            .with_fee_token(usdc())
            .with_default_deposit(DEPOSIT)
            .with_channel_store(keep)
            .with_origin(&origin)?)
    }
}

fn usdc() -> Address {
    USDC.parse().expect("the toolkit's USDC.e address")
}

/// A fresh SOCKS user name for traffic that belongs to no conversation, so
/// Tor gives it a circuit of its own.
fn fresh() -> String {
    hex(B256::random().as_slice())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A conversation's SOCKS user name: 32 bytes of hex.
fn is_identity(identity: &str) -> bool {
    identity.len() == 64 && identity.bytes().all(|b| b.is_ascii_hexdigit())
}

/// What the host asks.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// A new wallet key, made by the toolkit's own key code.
    Create,
    /// The wallet's balance and the least a first deposit needs, whether the
    /// provider's setup still names the network and token, the models and
    /// their prices, and the deposit's state on the network.
    Wallet {
        address: Address,
        deposit: Option<Deposit>,
    },
    /// The provider's list of models, as it gives it.
    Models,
    Send(Send),
    /// Closes the deposit with the provider, which refunds what is unspent.
    Close {
        key: B256,
        deposit: Deposit,
        model: String,
    },
    /// The network's own close, without the provider: the first press asks
    /// to close, one after the grace period takes the deposit back.
    Withdraw {
        key: B256,
        deposit: Deposit,
    },
    Venice(Venice),
    /// The EIP-191 signature of a Venice sign-in by `key`. No network.
    VeniceSign {
        key: B256,
        message: String,
    },
    /// The EIP-712 signature by `key` of `typed`, `eth_signTypedData_v4`
    /// JSON for a transfer of USDC on Base (EIP-3009's
    /// TransferWithAuthorization), and of nothing else. No network.
    VeniceTyped {
        key: B256,
        typed: String,
    },
    /// The address's USDC on Base.
    VeniceFunds {
        address: Address,
    },
}

impl Request {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Wallet { .. } => "wallet",
            Self::Models => "models",
            Self::Send(_) => "send",
            Self::Close { .. } => "close",
            Self::Withdraw { .. } => "withdraw",
            Self::Venice(_) => "venice",
            Self::VeniceSign { .. } => "venice_sign",
            Self::VeniceTyped { .. } => "venice_typed",
            Self::VeniceFunds { .. } => "venice_funds",
        }
    }
}

/// One request to Venice's API, as the Mac built it, sent through Tor as the
/// conversation's identity. Its answer streams: `L`, `P` frames, then `A`.
#[derive(Deserialize)]
pub struct Venice {
    identity: String,
    method: VeniceMethod,
    url: String,
    headers: BTreeMap<String, String>,
    /// JSON text, as the Mac built it.
    body: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "UPPERCASE")]
enum VeniceMethod {
    Get,
    Post,
}

alloy::sol! {
    /// EIP-3009's transfer, as USDC's typed data names it.
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct TransferWithAuthorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    #[sol(rpc)]
    interface IERC20 {
        function balanceOf(address owner) external view returns (uint256);
    }
}

/// What `venice_typed` takes: a TransferWithAuthorization in USDC's domain
/// on Base, with these types.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Typed {
    types: Value,
    primary_type: String,
    domain: TypedDomain,
    message: TransferWithAuthorization,
}

#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TypedDomain {
    name: String,
    version: String,
    chain_id: u64,
    verifying_contract: Address,
}

/// One chat request to the model. The Mac builds its body, with every user
/// message reworded there, and the sender posts those bytes as they are.
#[derive(Deserialize)]
pub struct Send {
    key: B256,
    deposit: Option<Deposit>,
    /// The request body, JSON, as the Mac built it.
    body: String,
    /// The conversation's SOCKS user name.
    identity: String,
}

/// A token amount in its smallest units, as a decimal string.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Amount(pub u128);

impl Serialize for Amount {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for Amount {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map(Amount)
            .map_err(serde::de::Error::custom)
    }
}

/// The toolkit's stored channel, as the host keeps it: the one deposit.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Deposit {
    key: String,
    channel_id: B256,
    cumulative_amount: Amount,
    deposit: Amount,
    descriptor: ChannelDescriptor,
    #[serde(skip_serializing_if = "Option::is_none")]
    settlement_route: Option<SettlementRoute>,
    escrow: Address,
    chain_id: u64,
    opened: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pending_open: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    origin: Option<String>,
}

impl Deposit {
    fn new(key: &str, entry: &StoredChannelEntry) -> Self {
        Self {
            key: key.to_owned(),
            channel_id: entry.channel_id,
            cumulative_amount: Amount(entry.cumulative_amount),
            deposit: Amount(entry.deposit),
            descriptor: entry.descriptor.clone(),
            settlement_route: entry.settlement_route.clone(),
            escrow: entry.escrow,
            chain_id: entry.chain_id,
            opened: entry.opened,
            pending_open: entry.pending_open.clone(),
            origin: entry.origin.clone(),
        }
    }

    fn entry(&self) -> StoredChannelEntry {
        StoredChannelEntry {
            channel_id: self.channel_id,
            cumulative_amount: self.cumulative_amount.0,
            deposit: self.deposit.0,
            descriptor: self.descriptor.clone(),
            settlement_route: self.settlement_route.clone(),
            escrow: self.escrow,
            chain_id: self.chain_id,
            opened: self.opened,
            pending_open: self.pending_open.clone(),
            origin: self.origin.clone(),
        }
    }

    /// Something left to spend, as kept. Whether its opening landed, or it
    /// has closed since, is the network's to say: the toolkit asks it before
    /// paying from the deposit, as it does for one about to open.
    fn usable(&self) -> bool {
        self.deposit > self.cumulative_amount
    }
}

/// Why a request stopped, in one of the few ways the app words for people.
#[derive(Debug, Serialize)]
pub struct Stop {
    code: Code,
    detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    NoFunds,
    WalletRefused,
    ModelUnavailable,
    TorDown,
    Failed,
}

impl Stop {
    fn new(code: Code, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }

    fn failed(detail: impl Into<String>) -> Self {
        Self::new(Code::Failed, detail)
    }

    pub fn code(&self) -> Code {
        self.code
    }
}

/// Whether a connection could not be made, through the error's sources: a
/// Tor port that refuses or a circuit that cannot be built.
fn unreachable(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut next = Some(error);
    while let Some(error) = next {
        if error
            .downcast_ref::<reqwest::Error>()
            .is_some_and(reqwest::Error::is_connect)
        {
            return true;
        }
        next = error.source();
    }
    false
}

impl From<reqwest::Error> for Stop {
    fn from(error: reqwest::Error) -> Self {
        let code = if unreachable(&error) {
            Code::TorDown
        } else {
            Code::Failed
        };
        Self::new(code, error.to_string())
    }
}

impl Stop {
    /// A reqwest error from a Venice request, in words without its address.
    fn venice(error: reqwest::Error) -> Self {
        error.without_url().into()
    }
}

impl From<MppError> for Stop {
    fn from(error: MppError) -> Self {
        let code = match &error {
            MppError::InsufficientBalance(_)
            | MppError::Tempo(TempoClientError::InsufficientBalance { .. }) => Code::NoFunds,
            MppError::PaymentRequired { .. }
            | MppError::VerificationFailed(_)
            | MppError::PaymentActionRequired(_) => Code::WalletRefused,
            _ if unreachable(&error) => Code::TorDown,
            _ => Code::Failed,
        };
        Self::new(code, error.to_string())
    }
}

impl From<HttpError> for Stop {
    fn from(error: HttpError) -> Self {
        match error {
            HttpError::Payment(error) => error.into(),
            HttpError::Request(error) => error.into(),
            error => Self::failed(error.to_string()),
        }
    }
}

impl From<alloy::transports::TransportError> for Stop {
    fn from(error: alloy::transports::TransportError) -> Self {
        let code = if unreachable(&error) {
            Code::TorDown
        } else {
            Code::Failed
        };
        Self::new(code, error.to_string())
    }
}

impl From<alloy::contract::Error> for Stop {
    fn from(error: alloy::contract::Error) -> Self {
        let code = if unreachable(&error) {
            Code::TorDown
        } else {
            Code::Failed
        };
        Self::new(code, error.to_string())
    }
}

/// One connection's frames.
pub struct Frames<S> {
    stream: S,
}

impl<S: Read + Write> Frames<S> {
    pub fn new(stream: S) -> Self {
        Self { stream }
    }

    /// The next frame, or None once the other side has closed.
    pub fn read(&mut self) -> io::Result<Option<(u8, Vec<u8>)>> {
        let mut head = [0; 5];
        match self.stream.read_exact(&mut head) {
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            result => result?,
        }
        let length = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
        if length > MAX_FRAME {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame too large",
            ));
        }
        let mut payload = vec![0; length];
        self.stream.read_exact(&mut payload)?;
        Ok(Some((head[0], payload)))
    }

    pub fn write(&mut self, kind: u8, payload: &[u8]) -> io::Result<()> {
        let length = u32::try_from(payload.len())
            .ok()
            .filter(|&length| length as usize <= MAX_FRAME)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "frame too large"))?;
        let mut frame = Vec::with_capacity(5 + payload.len());
        frame.push(kind);
        frame.extend(length.to_be_bytes());
        frame.extend(payload);
        self.stream.write_all(&frame)?;
        self.stream.flush()
    }
}

/// Serves one connection: gives it its turn, runs its request and answers.
/// Returns the request's name and how it ended, for the log.
pub fn serve<S: Read + Write + std::marker::Send + 'static>(
    runtime: &tokio::runtime::Runtime,
    network: &Network,
    stream: S,
) -> io::Result<(&'static str, &'static str)> {
    let frames = Arc::new(Mutex::new(Frames::new(stream)));
    frames.lock().unwrap().write(TURN, &[])?;
    let request = match frames.lock().unwrap().read()? {
        Some((REQUEST, payload)) => payload,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "expected a request",
            ))
        }
    };
    let (name, result) = match serde_json::from_slice::<Request>(&request) {
        Ok(request) => (
            request.name(),
            runtime.block_on(run(network, request, frames.clone())),
        ),
        // Where it stopped reading, never what it read, which may be a key.
        Err(error) => (
            "unreadable",
            Err(Stop::failed(format!(
                "unreadable request at line {} column {}",
                error.line(),
                error.column()
            ))),
        ),
    };
    let (outcome, reply) = match result {
        Ok(value) => ("ok", json!({ "ok": value })),
        Err(stop) => (code_name(stop.code), json!({ "stop": stop })),
    };
    frames
        .lock()
        .unwrap()
        .write(ANSWER, &serde_json::to_vec(&reply)?)?;
    Ok((name, outcome))
}

fn code_name(code: Code) -> &'static str {
    match code {
        Code::NoFunds => "no_funds",
        Code::WalletRefused => "wallet_refused",
        Code::ModelUnavailable => "model_unavailable",
        Code::TorDown => "tor_down",
        Code::Failed => "failed",
    }
}

async fn run<S: Read + Write + std::marker::Send + 'static>(
    network: &Network,
    request: Request,
    frames: Arc<Mutex<Frames<S>>>,
) -> Result<Value, Stop> {
    match request {
        Request::Create => {
            let signer = PrivateKeySigner::random();
            Ok(json!({ "key": signer.to_bytes(), "address": signer.address() }))
        }
        Request::Wallet { address, deposit } => wallet(network, address, deposit).await,
        Request::Models => {
            let models = listed(&network.client(&fresh())?, network).await?;
            Ok(json!({ "models": models }))
        }
        Request::Send(send) => {
            let keep = Keep::new(send.deposit.clone(), frames);
            send.run(network, keep).await
        }
        Request::Close {
            key,
            deposit,
            model,
        } => close(network, key, deposit, &model, frames).await,
        Request::Withdraw { key, deposit } => withdraw(network, key, deposit).await,
        Request::Venice(venice) => venice.run(network, frames).await,
        Request::VeniceSign { key, message } => {
            if !message.starts_with(VENICE_SIGN_IN) {
                return Err(Stop::failed("the message is not a Venice sign-in"));
            }
            let signature = signer(key)?
                .sign_message_sync(message.as_bytes())
                .map_err(|e| Stop::failed(e.to_string()))?;
            Ok(json!({ "signature": format!("0x{}", hex(&signature.as_bytes())) }))
        }
        Request::VeniceTyped { key, typed } => {
            let typed = serde_json::from_str::<Typed>(&typed)
                .ok()
                .filter(Typed::is_usdc_transfer_on_base)
                .ok_or_else(|| Stop::failed("the typed data is not a USDC transfer on Base"))?;
            let hash = typed.message.eip712_signing_hash(&usdc_on_base());
            let signature = signer(key)?
                .sign_hash_sync(&hash)
                .map_err(|e| Stop::failed(e.to_string()))?;
            Ok(json!({ "signature": format!("0x{}", hex(&signature.as_bytes())) }))
        }
        Request::VeniceFunds { address } => funds(network, address).await,
    }
}

fn signer(key: B256) -> Result<PrivateKeySigner, Stop> {
    PrivateKeySigner::from_bytes(&key).map_err(|e| Stop::failed(e.to_string()))
}

/// USDC's EIP-712 domain on Base.
fn usdc_on_base() -> Eip712Domain {
    Eip712Domain::new(
        Some("USD Coin".into()),
        Some("2".into()),
        Some(U256::from(BASE_CHAIN)),
        Some(BASE_USDC),
        None,
    )
}

impl Typed {
    fn is_usdc_transfer_on_base(&self) -> bool {
        self.primary_type == "TransferWithAuthorization"
            && self.domain
                == TypedDomain {
                    name: "USD Coin".into(),
                    version: "2".into(),
                    chain_id: BASE_CHAIN,
                    verifying_contract: BASE_USDC,
                }
            && self.types
                == json!({
                    "EIP712Domain": [
                        { "name": "name", "type": "string" },
                        { "name": "version", "type": "string" },
                        { "name": "chainId", "type": "uint256" },
                        { "name": "verifyingContract", "type": "address" },
                    ],
                    "TransferWithAuthorization": [
                        { "name": "from", "type": "address" },
                        { "name": "to", "type": "address" },
                        { "name": "value", "type": "uint256" },
                        { "name": "validAfter", "type": "uint256" },
                        { "name": "validBefore", "type": "uint256" },
                        { "name": "nonce", "type": "bytes32" },
                    ],
                })
    }
}

/// The address's USDC on Base, read through Tor on an identity of its own.
async fn funds(network: &Network, address: Address) -> Result<Value, Stop> {
    let url = network
        .base
        .parse()
        .map_err(|e| Stop::failed(format!("Base RPC address: {e}")))?;
    let base: RootProvider = ProviderBuilder::default()
        .connect_client(ClientBuilder::default().http_with_client(network.client(&fresh())?, url));
    let balance = IERC20::new(BASE_USDC, &base)
        .balanceOf(address)
        .call()
        .await?;
    Ok(json!({ "balance": Amount(balance.to::<u128>()) }))
}

impl Venice {
    /// The request, once it is one for Venice's API: the conversation's
    /// identity, the network's Venice origin exactly (https to
    /// api.venice.ai, its own port) with no user name, a path under
    /// /api/v1/, and Venice's header names alone. Nothing has left yet.
    fn request(&self, network: &Network) -> Result<reqwest::Request, Stop> {
        if !is_identity(&self.identity) {
            return Err(Stop::failed(
                "the conversation's identity is not 32 bytes of hex",
            ));
        }
        let venice = reqwest::Url::parse(&network.venice)
            .map_err(|e| Stop::failed(format!("Venice's origin: {e}")))?;
        let url = reqwest::Url::parse(&self.url)
            .ok()
            .filter(|url| {
                url.origin() == venice.origin()
                    && url.username().is_empty()
                    && url.password().is_none()
                    && url.path().starts_with("/api/v1/")
            })
            .ok_or_else(|| Stop::failed("the address is not Venice's API"))?;
        let mut headers = HeaderMap::new();
        for (name, value) in &self.headers {
            let name = VENICE_HEADERS
                .into_iter()
                .find(|allowed| allowed == name)
                .ok_or_else(|| Stop::failed("a header name Venice's requests do not carry"))?;
            let mut value = HeaderValue::from_str(value)
                .map_err(|_| Stop::failed(format!("the {name} header does not read")))?;
            value.set_sensitive(true);
            headers.insert(HeaderName::from_static(name), value);
        }
        let method = match self.method {
            VeniceMethod::Get => reqwest::Method::GET,
            VeniceMethod::Post => reqwest::Method::POST,
        };
        let mut request = reqwest::Request::new(method, url);
        *request.headers_mut() = headers;
        *request.body_mut() = self.body.clone().map(Into::into);
        Ok(request)
    }

    /// Sends the request and hands on Venice's answer as it comes: its
    /// status and headers, then its body. A frame the host does not take
    /// means it has gone: the answer is dropped, which closes its Tor stream.
    async fn run<S: Read + Write>(
        self,
        network: &Network,
        frames: Arc<Mutex<Frames<S>>>,
    ) -> Result<Value, Stop> {
        let request = self.request(network)?;
        let mut response = network
            .client(&self.identity)?
            .execute(request)
            .await
            .map_err(Stop::venice)?;
        let mut headers = BTreeMap::<String, String>::new();
        for (name, value) in response.headers() {
            let value = String::from_utf8_lossy(value.as_bytes());
            headers
                .entry(name.as_str().to_owned())
                .and_modify(|joined| *joined = format!("{joined}, {value}"))
                .or_insert_with(|| value.into_owned());
        }
        let head = json!({ "status": response.status().as_u16(), "headers": headers });
        hand_on(&frames, HEAD, head.to_string().as_bytes())?;
        while let Some(chunk) = response.chunk().await.map_err(Stop::venice)? {
            for piece in chunk.chunks(MAX_FRAME) {
                hand_on(&frames, PIECE, piece)?;
            }
        }
        Ok(json!({}))
    }
}

/// One frame of an answer on its way.
fn hand_on<S: Read + Write>(
    frames: &Mutex<Frames<S>>,
    kind: u8,
    payload: &[u8],
) -> Result<(), Stop> {
    tokio::task::block_in_place(|| frames.lock().unwrap().write(kind, payload))
        .map_err(|_| Stop::failed("the host has gone"))
}

async fn balance(rpc: &RootProvider<TempoNetwork>, owner: Address) -> Result<u128, Stop> {
    let balance = ITIP20::new(usdc(), rpc).balanceOf(owner).call().await?;
    Ok(balance.to::<u128>())
}

#[derive(Deserialize)]
struct Models {
    data: Vec<Listed>,
}

#[derive(Deserialize)]
struct Listed {
    id: String,
    pricing: Option<Pricing>,
}

/// US dollars per million tokens.
#[derive(Deserialize, Serialize)]
struct Pricing {
    input: f64,
    output: f64,
}

/// The provider's list of models, as JSON text.
async fn listed(client: &reqwest::Client, network: &Network) -> Result<String, Stop> {
    Ok(client
        .get(format!("{}/v1/models", network.provider))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?)
}

async fn wallet(
    network: &Network,
    address: Address,
    deposit: Option<Deposit>,
) -> Result<Value, Stop> {
    let client = network.client(&fresh())?;
    let rpc = network.rpc(&network.client(&fresh())?)?;
    let setup = async {
        let text = client
            .get(format!("{}/setup", network.provider))
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        Ok::<_, Stop>(
            text.contains(&CHAIN_ID.to_string())
                && text.to_lowercase().contains(&USDC.to_lowercase()),
        )
    };
    let models = async {
        let models: Models = serde_json::from_str(&listed(&client, network).await?)
            .map_err(|e| Stop::failed(format!("the provider's models: {e}")))?;
        Ok::<_, Stop>(
            models
                .data
                .into_iter()
                .filter_map(|model| Some(json!({ "id": model.id, "pricing": model.pricing? })))
                .collect::<Vec<_>>(),
        )
    };
    let (balance, setup, models) = tokio::try_join!(balance(&rpc, address), setup, models)?;
    // As the network shows its channel, whether or not its opening was known
    // to have landed when it was kept.
    let deposit = match deposit {
        Some(deposit) => {
            let state = read_on_chain_channel_state(&rpc, deposit.channel_id).await?;
            json!({
                "deposit": Amount(state.deposit),
                "spent": deposit.cumulative_amount,
                "closeRequestedAt": state.close_requested_at,
                "withdrawAt": (state.close_requested_at > 0).then(|| state.close_requested_at + CLOSE_GRACE),
                // Closed on the network: the host forgets it. Never while
                // its opening may still land, which would leave funds in a
                // channel the Mac has no record of; that one is the
                // toolkit's to forget, when it next pays.
                "gone": state.deposit == 0 && deposit.pending_open.is_none(),
            })
        }
        None => Value::Null,
    };
    Ok(
        json!({ "balance": Amount(balance), "least": Amount(DEPOSIT), "setup": setup, "models": models, "deposit": deposit }),
    )
}

impl Send {
    async fn run<S: Read + Write + std::marker::Send + 'static>(
        self,
        network: &Network,
        keep: Keep<S>,
    ) -> Result<Value, Stop> {
        if !is_identity(&self.identity) {
            return Err(Stop::failed(
                "the conversation's identity is not 32 bytes of hex",
            ));
        }
        let signer = signer(self.key)?;
        let rpc = network.client(&fresh())?;
        // Without a kept deposit with something left, a new one needs the
        // balance: checked before anything reaches the provider.
        if !self.deposit.as_ref().is_some_and(Deposit::usable)
            && balance(&network.rpc(&rpc)?, signer.address()).await? < DEPOSIT
        {
            return Err(Stop::new(Code::NoFunds, "the balance is below one deposit"));
        }
        let client = network.client(&self.identity)?;
        let payer = network.session(signer, &client, &rpc, Arc::new(keep))?;
        let response = client
            .post(network.chat())
            .header("Accept-Payment", "tempo/session")
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(self.body)
            .send_with_payment(&payer)
            .await?;
        answer(response).await
    }
}

#[derive(Deserialize)]
struct Problem {
    error: Option<ProblemDetail>,
}

#[derive(Deserialize)]
struct ProblemDetail {
    code: Option<Value>,
    #[serde(rename = "type")]
    kind: Option<String>,
}

/// The provider's completion, as JSON text, or why there is none. The Mac
/// reads the answer from it.
async fn answer(response: reqwest::Response) -> Result<Value, Stop> {
    let status = response.status();
    if !status.is_success() {
        let body = response.bytes().await.unwrap_or_default();
        let problem = serde_json::from_slice::<Problem>(&body)
            .ok()
            .and_then(|p| p.error);
        let code = problem
            .as_ref()
            .and_then(|p| p.code.as_ref())
            .map(Value::to_string)
            .unwrap_or_default();
        let kind = problem.and_then(|p| p.kind).unwrap_or_default();
        let detail = format!("the provider answered {status} {code} {kind}");
        return Err(match status.as_u16() {
            403 if code.contains("model_access_required") => {
                Stop::new(Code::ModelUnavailable, detail)
            }
            404 => Stop::new(Code::ModelUnavailable, detail),
            401 | 402 | 403 => Stop::new(Code::WalletRefused, detail),
            _ => Stop::failed(detail),
        });
    }
    Ok(json!({ "completion": response.text().await? }))
}

/// Closes the deposit with the provider. A cooperative close needs one of
/// the provider's session challenges, which an unpaid request with made-up
/// text brings; the close then carries the toolkit's final voucher, for
/// what this wallet has authorized, and the provider refunds the rest. The
/// host forgets the deposit once the network shows it closed.
async fn close<S: Read + Write + std::marker::Send + 'static>(
    network: &Network,
    key: B256,
    deposit: Deposit,
    model: &str,
    frames: Arc<Mutex<Frames<S>>>,
) -> Result<Value, Stop> {
    let signer = signer(key)?;
    let client = network.client(&fresh())?;
    let rpc = network.client(&fresh())?;
    let (channel, spent) = (deposit.channel_id.to_string(), deposit.cumulative_amount.0);
    let payer = network.session(
        signer,
        &client,
        &rpc,
        Arc::new(Keep::new(Some(deposit), frames)),
    )?;
    let probe = client
        .post(network.chat())
        .header("Accept-Payment", "tempo/session")
        .json(&json!({ "model": model, "messages": [{ "role": "user", "content": "Hello" }], "stream": false }))
        .send()
        .await?;
    let challenge = parse_www_authenticate_all_bytes(
        probe
            .headers()
            .get_all(reqwest::header::WWW_AUTHENTICATE)
            .iter()
            .map(|value| value.as_bytes()),
    )
    .into_iter()
    .filter_map(Result::ok)
    .find(|challenge| {
        challenge.method.as_str() == "tempo" && challenge.intent.as_str() == "session"
    })
    .ok_or_else(|| {
        Stop::failed(format!(
            "the provider answered {} with no session challenge",
            probe.status()
        ))
    })?;
    if !payer.restore(&challenge).await? {
        return Err(Stop::failed("the deposit is not open on the network"));
    }
    let credential = payer
        .close_credential_at_for_challenge(&challenge, &channel, spent)
        .await?;
    let closed = client
        .post(network.chat())
        .header(
            reqwest::header::AUTHORIZATION,
            format_authorization(&credential)?,
        )
        .send()
        .await?;
    if !closed.status().is_success() {
        return Err(Stop::failed(format!(
            "the provider answered the close with {}",
            closed.status()
        )));
    }
    Ok(json!({}))
}

/// The network's own close: asks to close the deposit, or once that has
/// been asked, takes it back. Nothing here waits for the grace period; the
/// network refuses a withdrawal before it ends.
async fn withdraw(network: &Network, key: B256, deposit: Deposit) -> Result<Value, Stop> {
    let signer = signer(key)?;
    let rpc = network.rpc(&network.client(&fresh())?)?;
    let state = read_on_chain_channel_state(&rpc, deposit.channel_id).await?;
    let (step, input) = if state.close_requested_at == 0 {
        (
            "requested",
            encode_precompile_request_close_call(&deposit.descriptor)?,
        )
    } else {
        (
            "withdrawn",
            encode_precompile_withdraw_call(&deposit.descriptor)?,
        )
    };
    let transaction = submit(&rpc, &signer, input).await?;
    Ok(json!({ "step": step, "transaction": transaction }))
}

/// Signs one call to the channel precompile with the toolkit and sends it to
/// the network; the fee is paid in USDC.e.
async fn submit(
    rpc: &RootProvider<TempoNetwork>,
    signer: &PrivateKeySigner,
    input: Bytes,
) -> Result<B256, Stop> {
    let from = signer.address();
    let calls = vec![Call {
        to: TxKind::Call(TIP20_CHANNEL_RESERVE_ADDRESS),
        value: U256::ZERO,
        input,
    }];
    let nonce = rpc.get_transaction_count(from).await?;
    let price = rpc.get_gas_price().await?;
    let mut options = TempoTxOptions {
        calls,
        chain_id: CHAIN_ID,
        fee_token: usdc(),
        nonce,
        nonce_key: U256::ZERO,
        gas_limit: 0,
        max_fee_per_gas: price,
        max_priority_fee_per_gas: price,
        fee_payer: false,
        valid_before: None,
        key_authorization: None,
    };
    let mut estimate = TempoTransactionRequest {
        calls: options.calls.clone(),
        ..Default::default()
    }
    .with_fee_token(usdc());
    estimate.inner.from = Some(from);
    estimate.inner.chain_id = Some(CHAIN_ID);
    estimate.inner.nonce = Some(nonce);
    estimate.inner.max_fee_per_gas = Some(price);
    estimate.inner.max_priority_fee_per_gas = Some(price);
    options.gas_limit = estimate_gas(rpc, estimate).await?;
    let signed = sign_and_encode(build_tempo_tx(options), signer, &TempoSigningMode::Direct)?;
    Ok(*rpc.send_raw_transaction(&signed).await?.tx_hash())
}

/// The toolkit's channel store for one request: the one deposit, seeded
/// from what the host kept, and every change sent to the host and sealed on
/// the Mac before the toolkit goes on, so a deposit about to open is on the
/// Mac's disk before its transaction leaves.
struct Keep<S> {
    deposit: Mutex<Option<Deposit>>,
    frames: Arc<Mutex<Frames<S>>>,
}

impl<S: Read + Write> Keep<S> {
    fn new(deposit: Option<Deposit>, frames: Arc<Mutex<Frames<S>>>) -> Self {
        Self {
            deposit: Mutex::new(deposit),
            frames,
        }
    }

    fn tell(&self, deposit: Option<&Deposit>) -> ChannelStoreResult<()> {
        let payload =
            serde_json::to_vec(&deposit).map_err(|e| ChannelStoreError::Io(e.to_string()))?;
        tokio::task::block_in_place(|| {
            let mut frames = self.frames.lock().unwrap();
            frames.write(KEEP, &payload)?;
            match frames.read()? {
                Some((KEPT, _)) => Ok(()),
                _ => Err(io::Error::other("the host did not keep the deposit")),
            }
        })
        .map_err(|e| ChannelStoreError::Io(e.to_string()))
    }
}

fn mismatch(what: &str) -> ChannelStoreError {
    ChannelStoreError::InvalidEntry(what.into())
}

#[async_trait::async_trait]
impl<S: Read + Write + std::marker::Send + 'static> ChannelStore for Keep<S> {
    async fn get(&self, key: &str) -> ChannelStoreResult<Option<StoredChannelEntry>> {
        Ok(self
            .deposit
            .lock()
            .unwrap()
            .as_ref()
            .filter(|kept| kept.key == key)
            .map(Deposit::entry))
    }

    async fn set(&self, entry: &StoredChannelEntry) -> ChannelStoreResult<()> {
        self.set_at(&entry.key(), entry).await
    }

    /// As the toolkit's memory store: the same channel merges, keeping the
    /// highest amounts and its first origin; a channel replaces another under
    /// the same key. There is one deposit, so another key is refused.
    async fn set_at(&self, key: &str, entry: &StoredChannelEntry) -> ChannelStoreResult<()> {
        let mut kept = self.deposit.lock().unwrap();
        let mut next = Deposit::new(key, entry);
        match kept.as_ref() {
            Some(current) if current.key != key => return Err(mismatch("one deposit at a time")),
            Some(current) if current.channel_id == entry.channel_id => {
                next.cumulative_amount = next.cumulative_amount.max(current.cumulative_amount);
                next.deposit = next.deposit.max(current.deposit);
                next.origin = match (&current.origin, &entry.origin) {
                    (Some(current), Some(origin)) if current != origin => {
                        return Err(mismatch("stored channel origin mismatch"))
                    }
                    (Some(current), _) => Some(current.clone()),
                    (None, origin) => origin.clone(),
                };
            }
            _ => {}
        }
        self.tell(Some(&next))?;
        *kept = Some(next);
        Ok(())
    }

    async fn find_channel(&self, channel_id: B256) -> ChannelStoreResult<Option<String>> {
        Ok(self
            .deposit
            .lock()
            .unwrap()
            .as_ref()
            .filter(|kept| kept.channel_id == channel_id)
            .map(|kept| kept.key.clone()))
    }

    async fn delete(&self, key: &str) -> ChannelStoreResult<()> {
        let mut kept = self.deposit.lock().unwrap();
        if kept.as_ref().is_some_and(|current| current.key == key) {
            self.tell(None)?;
            *kept = None;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn entry(channel: u8, cumulative: u128) -> StoredChannelEntry {
        let address = "0x0000000000000000000000000000000000000001".to_owned();
        StoredChannelEntry {
            channel_id: B256::with_last_byte(channel),
            cumulative_amount: cumulative,
            deposit: 1_000_000,
            descriptor: ChannelDescriptor {
                payer: address.clone(),
                payee: address.clone(),
                operator: address.clone(),
                token: USDC.into(),
                salt: B256::ZERO.to_string(),
                authorized_signer: address,
                expiring_nonce_hash: B256::ZERO.to_string(),
            },
            settlement_route: None,
            escrow: TIP20_CHANNEL_RESERVE_ADDRESS,
            chain_id: CHAIN_ID,
            opened: true,
            pending_open: None,
            origin: None,
        }
    }

    /// The host's end: keeps each deposit reported, answering K, until the
    /// store is dropped.
    fn host(stream: UnixStream) -> std::thread::JoinHandle<Vec<Value>> {
        std::thread::spawn(move || {
            let mut frames = Frames::new(stream);
            let mut kept = vec![];
            while let Ok(Some((KEEP, payload))) = frames.read() {
                kept.push(serde_json::from_slice(&payload).unwrap());
                frames.write(KEPT, &[]).unwrap();
            }
            kept
        })
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn each_change_to_the_deposit_is_kept_by_the_host() {
        let (sender, other) = UnixStream::pair().unwrap();
        let kept = host(other);
        let keep = Keep::new(None, Arc::new(Mutex::new(Frames::new(sender))));
        keep.set_at("scope", &entry(1, 10)).await.unwrap();
        // The same channel merges, keeping the highest amount.
        keep.set_at("scope", &entry(1, 5)).await.unwrap();
        assert_eq!(
            keep.get("scope").await.unwrap().unwrap().cumulative_amount,
            10
        );
        assert_eq!(
            keep.find_channel(B256::with_last_byte(1))
                .await
                .unwrap()
                .as_deref(),
            Some("scope")
        );
        // One deposit at a time.
        assert!(keep.set_at("other", &entry(2, 1)).await.is_err());
        keep.delete("scope").await.unwrap();
        assert!(keep.get("scope").await.unwrap().is_none());
        drop(keep);
        let kept = kept.join().unwrap();
        assert_eq!(kept.len(), 3);
        assert_eq!(kept[0]["cumulativeAmount"], "10");
        assert_eq!(kept[1]["cumulativeAmount"], "10");
        assert!(kept[2].is_null());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_change_the_host_did_not_keep_is_not_taken() {
        let (sender, other) = UnixStream::pair().unwrap();
        drop(other);
        let keep = Keep::new(None, Arc::new(Mutex::new(Frames::new(sender))));
        assert!(keep.set_at("scope", &entry(1, 10)).await.is_err());
        assert!(keep.get("scope").await.unwrap().is_none());
    }
}
