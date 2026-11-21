//! Slice 2: one chat request to NEAR AI Cloud, sent only under a proof that
//! passed, the Intel quotes and Intel Trust Authority's verdict on the GPUs
//! (slice 3): one checked in the same call, or one that passed for the same
//! model no longer ago than the proof age the caller chose. Every
//! field that holds the person's words is sealed for the model key the proof
//! checked (NEAR's encryption, version 2, with `X-Encrypt-All-Fields`), it
//! goes on a new connection whose gateway certificate key must be the one
//! the proof is tied to, and the reply's sealed fields are opened with a key
//! made for this request alone. Nothing falls back to plain text: a request
//! with a field the encryption does not cover is refused before anything is
//! fetched, and a reply with a field that does not open is refused whole.

use std::collections::HashMap;
use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustls::RootCertStore;
use serde_json::{json, Map, Value};

use crate::e2ee::{ReplyKey, SealKey};
use crate::fetch::{connect, families, family_collateral, mozilla, request, NEAR};
use crate::gpu::keys_cover;
use crate::{
    fetch_collateral, fetch_ita_keys, fetch_ita_tokens, fetch_report, verify_gpu, verify_intel,
    Collateral, FetchError, Pins, Proof, Refusal, Route, Routes,
};

const DAY: Duration = Duration::from_secs(24 * 60 * 60);
/// The longest a passed proof may be used again.
const HOUR: Duration = Duration::from_secs(60 * 60);
/// The largest reply taken; a sealed field is twice its text, in hex.
const REPLY_LIMIT: usize = 8 << 20;
/// How long the model may take: a reply that is not streamed comes only
/// once it is whole.
const REPLY_WAIT: Duration = Duration::from_secs(300);
/// Settings a request may carry in plain text; none holds the person's
/// words. Besides these, a request holds only `messages`, `tools` and
/// `tool_choice`, whose words are sealed.
const PLAIN: &[&str] = &[
    "model",
    "stream",
    "temperature",
    "top_p",
    "max_tokens",
    "max_completion_tokens",
    "n",
    "seed",
    "stop",
    "presence_penalty",
    "frequency_penalty",
    "parallel_tool_calls",
];

/// Why a chat request got no reply, or a check no proof. Up to and including
/// `Pin`, nothing was sent to the chat endpoint ([`Stop::sent`]).
#[derive(Debug)]
pub enum Stop {
    /// The request cannot go as given, the proof age is over an hour, or
    /// the system gave no randomness or time.
    Request(String),
    /// Fetching the report, Intel's collateral, Intel Trust Authority's
    /// tokens or Intel's keys for them failed.
    Fetch(FetchError),
    /// The proof was refused.
    Refused(Refusal),
    /// The proof passed, and the chat request's connection could not be
    /// made; no byte of the request was written.
    Connect(FetchError),
    /// The new connection's gateway certificate key is not the one the
    /// proof is tied to.
    Pin,
    /// Writing the chat request or reading its answer failed; the request
    /// may have reached NEAR.
    Send(FetchError),
    /// NEAR answered with a status other than 200: the code and the start
    /// of the body.
    Status { code: u16, detail: String },
    /// The reply was refused: a field that should be encrypted did not
    /// decrypt, or the reply is not the chat completion that was asked for.
    Reply(String),
}

impl fmt::Display for Stop {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Stop::Request(why) => write!(f, "the request cannot be sent: {why}"),
            Stop::Fetch(error) => write!(f, "fetching the proof: {error}"),
            Stop::Refused(refusal) => write!(f, "the proof was refused: {refusal}"),
            Stop::Connect(error) => write!(f, "connecting to send the request: {error}"),
            Stop::Pin => write!(
                f,
                "the gateway showed a certificate key other than the one its proof is tied to"
            ),
            Stop::Send(error) => write!(f, "sending the request: {error}"),
            Stop::Status { code, detail } => write!(f, "NEAR answered {code}: {detail}"),
            Stop::Reply(why) => write!(f, "the reply was refused: {why}"),
        }
    }
}

impl std::error::Error for Stop {}

impl Stop {
    /// Whether the chat request may have reached NEAR: false when the stop
    /// came before any byte of it was written (up to and including
    /// [`Stop::Pin`]), true once writing it began.
    pub fn sent(&self) -> bool {
        match self {
            Stop::Request(_) | Stop::Fetch(_) | Stop::Refused(_) | Stop::Connect(_) | Stop::Pin => {
                false
            }
            Stop::Send(_) | Stop::Status { .. } | Stop::Reply(_) => true,
        }
    }
}

/// What is kept between requests.
///
/// Intel's collateral and Intel Trust Authority's signing keys, each for at
/// most `max_age`. The collateral is fetched again when it is older, or does
/// not cover every platform family a new report's quotes name; the keys when
/// they are older, or do not hold every key new tokens name.
///
/// And for each model, the proof of the last check made for it, when that
/// check passed under a proof age above zero, with the gateway TLS key hash
/// it was checked with and the second it passed. A later call uses it when
/// it passed no longer before than that call's proof age; a request sent
/// under it goes on hardware checked up to that long before, not at the
/// moment of sending.
pub struct Kept {
    max_age: u64,
    collateral_at: u64,
    collateral: Vec<Collateral>,
    keys_at: u64,
    /// Intel Trust Authority's key list as it came.
    keys: Vec<u8>,
    /// The last proof that passed for each model, by the model's name.
    proofs: HashMap<String, Passed>,
}

/// A proof that passed, as [`check`] gives it and [`Kept`] keeps it.
#[derive(Clone, Debug)]
pub struct Passed {
    /// Every request sent under it goes on a connection showing the gateway
    /// TLS key it was checked with, `proof.intel.gateway_tls_key`.
    pub proof: Proof,
    /// When the proof passed, in seconds since 1970: in this call, or in an
    /// earlier one when [`Kept`] held it.
    pub at: u64,
}

impl Kept {
    /// Nothing kept yet; None when `max_age` is over a day.
    pub fn new(max_age: Duration) -> Option<Kept> {
        (max_age <= DAY).then(|| Kept {
            max_age: max_age.as_secs(),
            collateral_at: 0,
            collateral: Vec::new(),
            keys_at: 0,
            keys: Vec::new(),
            proofs: HashMap::new(),
        })
    }

    /// The proof kept for `model`, if it passed no longer than `proof_age`
    /// seconds before `now`; none when `proof_age` is zero. One that passed
    /// after `now`, as when the clock went back, is taken as too old.
    fn proof_for(&self, model: &str, proof_age: u64, now: u64) -> Option<Passed> {
        self.proofs
            .get(model)
            .filter(|passed| proof_age > 0 && passed.at <= now && now - passed.at <= proof_age)
            .cloned()
    }

    /// Keeps `passed` as `model`'s proof, in place of the one before it;
    /// nothing when the proof age is zero.
    pub(crate) fn keep(&mut self, model: &str, passed: &Passed, proof_age: u64) {
        if proof_age > 0 {
            self.proofs.insert(model.to_owned(), passed.clone());
        }
    }

    /// The collateral for `report`'s quotes at `now`.
    fn collateral_for(
        &mut self,
        intel: &Route,
        report: &[u8],
        now: u64,
    ) -> Result<&[Collateral], Stop> {
        let covered = families(report)
            .map_err(Stop::Fetch)?
            .iter()
            .all(|(fmspc, ca)| {
                self.collateral
                    .iter()
                    .any(|c| &c.fmspc == fmspc && &c.ca == ca)
            });
        if !covered || now.saturating_sub(self.collateral_at) > self.max_age {
            self.collateral = fetch_collateral(intel, report).map_err(Stop::Fetch)?;
            self.collateral_at = now;
        }
        Ok(&self.collateral)
    }

    /// The collateral for one quote's platform family at `now`: the kept
    /// list's, or else fetched from Intel for that family alone, joining the
    /// list (or taking its place when the list is older than `max_age`).
    pub(crate) fn collateral_for_quote(
        &mut self,
        intel: &Route,
        quote: &[u8],
        now: u64,
    ) -> Result<&Collateral, FetchError> {
        let (fmspc, ca) = crate::verify::family(quote).map_err(FetchError::Malformed)?;
        if now.saturating_sub(self.collateral_at) > self.max_age {
            self.collateral.clear();
            self.collateral_at = now;
        }
        let at = match self
            .collateral
            .iter()
            .position(|c| c.fmspc == fmspc && c.ca == ca)
        {
            Some(at) => at,
            None => {
                let fetched = family_collateral(intel, fmspc, ca)?;
                if self.collateral.is_empty() {
                    self.collateral_at = now;
                }
                self.collateral.push(fetched);
                self.collateral.len() - 1
            }
        };
        Ok(&self.collateral[at])
    }

    /// Holds `collateral` as if fetched at `at`, for a check made offline.
    #[cfg(test)]
    pub(crate) fn hold_collateral(&mut self, collateral: Vec<Collateral>, at: u64) {
        self.collateral = collateral;
        self.collateral_at = at;
    }

    /// Intel Trust Authority's key list for the tokens in `answer` at `now`.
    fn keys_for(&mut self, intel: &Route, answer: &[u8], now: u64) -> Result<&[u8], Stop> {
        if !keys_cover(answer, &self.keys) || now.saturating_sub(self.keys_at) > self.max_age {
            self.keys = fetch_ita_keys(intel).map_err(Stop::Fetch)?;
            self.keys_at = now;
        }
        Ok(&self.keys)
    }
}

/// A reply, and the proof it was sent under.
#[derive(Debug)]
pub struct Answered {
    pub proof: Proof,
    /// When `proof` passed, in seconds since 1970: in this call, or in an
    /// earlier one when [`Kept`] held it. The hardware was checked then, not
    /// when the request was sent.
    pub proof_passed_at: u64,
    /// The chat completion as NEAR's model gave it, every sealed field
    /// opened.
    pub reply: Value,
}

/// Sends one OpenAI-shaped chat request (`body`, not streamed) for `model`
/// to NEAR AI Cloud with `api_key`, in this order and no other: the request
/// is checked; [`check`] gives a proof that passed, kept or new, under
/// `proof_age`; and only then, under that proof, is the request sent,
/// pinned to the gateway TLS key and sealed for the model key the proof
/// checked. A step that fails before sending returns its [`Stop`], and
/// nothing is sent.
/// When the gateway shows another TLS key ([`Stop::Pin`]) or the reply does
/// not open ([`Stop::Reply`]), the model's kept proof is forgotten, so the
/// next call checks afresh; nothing is tried again in this one. The key is
/// used only in the request's Authorization header: never kept, logged or
/// put in a [`Stop`].
pub fn ask(
    routes: &Routes,
    model: &str,
    api_key: &str,
    body: &[u8],
    pins: &Pins,
    kept: &mut Kept,
    proof_age: Duration,
) -> Result<Answered, Stop> {
    // The same check `send` makes, here so that a request that cannot go
    // costs no fetch.
    checked(body, model, api_key)?;
    let passed = check(routes, model, pins, kept, proof_age)?;
    // Only now, holding a proof that passed, is the request sent.
    let reply = send(
        &passed.proof,
        &routes.near,
        &mozilla(),
        model,
        api_key,
        body,
    )
    .inspect_err(|stop| {
        // Another TLS key, or a reply that did not open: the proof is not
        // used again.
        if matches!(stop, Stop::Pin | Stop::Reply(_)) {
            kept.proofs.remove(model);
        }
    })?;
    Ok(Answered {
        proof: passed.proof,
        proof_passed_at: passed.at,
        reply,
    })
}

/// A readied message's reply, the exact bytes the receipt covers, and the
/// receipt.
#[derive(Debug)]
pub struct Exchanged {
    pub proof: Proof,
    /// When `proof` passed, in seconds since 1970.
    pub proof_passed_at: u64,
    /// The chat completion as NEAR's model gave it.
    pub reply: Value,
    /// The request body exactly as it was written.
    pub request: Vec<u8>,
    /// The reply body exactly as it came.
    pub response: Vec<u8>,
    /// NEAR's signed receipt for the two, checked here; or why there is
    /// none. Without one the exchange cannot be shared, and the reply
    /// stands.
    pub receipt: Result<Value, String>,
}

/// Sends the one message a person readied for sharing: [`ask`], but with
/// NEAR's encryption left off, so that NEAR's receipt covers the words
/// themselves, and with the commons' `admission` binding as the request's
/// one extra field, `metadata.trace_commons_admission`. The request must
/// pass the same check as any `ask` (its fields, the model, not streamed)
/// before `metadata` is added, and is sent only under a proof that passed,
/// on a connection pinned to the gateway TLS key that proof checked; then
/// NEAR's receipt is fetched on another connection pinned the same way.
/// Every other request goes through [`ask`] as before.
#[allow(clippy::too_many_arguments)]
pub fn ask_readied(
    routes: &Routes,
    roots: &RootCertStore,
    model: &str,
    api_key: &str,
    body: &[u8],
    admission: &str,
    pins: &Pins,
    kept: &mut Kept,
    proof_age: Duration,
) -> Result<Exchanged, Stop> {
    let mut body = checked(body, model, api_key)?;
    if !crate::share::binding_shape(admission) {
        return Err(Stop::Request(
            "the admission is not one the commons issues".into(),
        ));
    }
    body.insert(
        "metadata".into(),
        json!({ "trace_commons_admission": admission }),
    );
    let request = serde_json::to_vec(&body).expect("a JSON map serializes");
    let passed = check(routes, model, pins, kept, proof_age)?;
    let pin = passed.proof.intel.gateway_tls_key;
    let (reply, response) =
        send_plain(&pin, &routes.near, roots, api_key, &request).inspect_err(|stop| {
            if matches!(stop, Stop::Pin) {
                kept.proofs.remove(model);
            }
        })?;
    let receipt = crate::share::receipt(
        &routes.near,
        roots,
        &pin,
        model,
        api_key,
        &reply,
        &request,
        &response,
    );
    Ok(Exchanged {
        proof: passed.proof,
        proof_passed_at: passed.at,
        reply,
        request,
        response,
        receipt,
    })
}

/// Writes `request` as it is to NEAR's chat endpoint on a new connection
/// whose gateway certificate key must hash to `pin`, with no encryption
/// headers; the reply as JSON and its body exactly as it came.
fn send_plain(
    pin: &[u8; 32],
    route: &Route,
    roots: &RootCertStore,
    api_key: &str,
    request_body: &[u8],
) -> Result<(Value, Vec<u8>), Stop> {
    let (mut tls, spki_sha256) = connect(route, NEAR, roots).map_err(Stop::Connect)?;
    if spki_sha256 != *pin {
        return Err(Stop::Pin);
    }
    tls.sock
        .set_read_timeout(Some(REPLY_WAIT))
        .map_err(|e| Stop::Connect(e.into()))?;
    let authorization = format!("Bearer {api_key}");
    let mut answer = request(
        &mut tls,
        "POST",
        NEAR,
        "/v1/chat/completions",
        &[
            ("Authorization", &authorization),
            ("Content-Type", "application/json"),
            ("Accept", "application/json"),
            ("x-no-aliasing", "true"),
        ],
        Some(request_body),
        REPLY_LIMIT,
    )
    .map_err(Stop::Send)?;
    if answer.status != 200 {
        answer.body = String::from_utf8_lossy(&answer.body)
            .replace(api_key, "[the key]")
            .into_bytes();
        return Err(Stop::Status {
            code: answer.status,
            detail: answer.detail(),
        });
    }
    let reply: Value =
        serde_json::from_slice(&answer.body).map_err(|_| Stop::Reply("it is not JSON".into()))?;
    if !reply.get("choices").is_some_and(Value::is_array) {
        return Err(Stop::Reply("it has no choices".into()));
    }
    Ok((reply, answer.body))
}

/// A proof that passed for `model`, and nothing sent to the chat endpoint:
/// the one `kept` holds for `model` if it passed no longer than `proof_age`
/// before, or else a new one, fetched and checked in full in the order
/// `prove` follows. A new check takes the place of the model's kept proof:
/// by its own proof when it passes and `proof_age` is above zero, otherwise
/// by nothing. A `proof_age` of zero uses and keeps no proof; one over an
/// hour is refused before anything is fetched.
pub fn check(
    routes: &Routes,
    model: &str,
    pins: &Pins,
    kept: &mut Kept,
    proof_age: Duration,
) -> Result<Passed, Stop> {
    if proof_age > HOUR {
        return Err(Stop::Request("the proof age is over an hour".into()));
    }
    let proof_age = proof_age.as_secs();
    if let Some(passed) = kept.proof_for(model, proof_age, seconds()?) {
        return Ok(passed);
    }
    kept.proofs.remove(model);
    let passed = prove(routes, model, pins, kept)?;
    kept.keep(model, &passed, proof_age);
    Ok(passed)
}

/// The full check, in this order: a report is fetched under a fresh nonce on
/// the `near` route; Intel's collateral is reused from `kept` or fetched on
/// the `intel` route; the Intel quotes are checked against `pins`; Intel
/// Trust Authority's tokens are fetched from NEAR's gateway under the same
/// nonce on the `near` route, and the keys Intel signs them with are reused
/// from `kept` or fetched on the `intel` route; and the GPU side is checked.
/// A proof with both halves, or the failed step's [`Stop`].
fn prove(routes: &Routes, model: &str, pins: &Pins, kept: &mut Kept) -> Result<Passed, Stop> {
    let fetched = fetch_report(&routes.near, model).map_err(Stop::Fetch)?;
    let now = seconds()?;
    let collateral = kept.collateral_for(&routes.intel, &fetched.report, now)?;
    let intel = verify_intel(
        &fetched.report,
        &fetched.nonce,
        &fetched.spki_sha256,
        model,
        collateral,
        pins,
        now,
    )
    .map_err(Stop::Refused)?;
    let tokens = fetch_ita_tokens(&routes.near, model, &fetched.nonce).map_err(Stop::Fetch)?;
    // Intel dates its tokens by its own clock, so they are checked at a time
    // read after they came.
    let now = seconds()?;
    let keys = kept.keys_for(&routes.intel, &tokens, now)?;
    let gpu = verify_gpu(&tokens, &fetched.nonce, model, &intel, keys, pins, now)
        .map_err(Stop::Refused)?;
    Ok(Passed {
        proof: Proof { intel, gpu },
        at: now,
    })
}

/// Seconds since 1970 by the system clock.
fn seconds() -> Result<u64, Stop> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Stop::Request("the clock reads before 1970".into()))?
        .as_secs())
}

/// Seals `body`'s words for the model key in `proof`, opens a new
/// connection to the gateway on `route` that is accepted only if its
/// certificate passes the ordinary checks against `roots` and its key
/// hashes to the gateway TLS key `proof` was checked with, sends the
/// request once, and opens the reply with a key made for this request. Only
/// [`ask`] calls it, with a proof that passed in the same call or that
/// [`Kept`] held for the model within the proof age.
pub(crate) fn send(
    proof: &Proof,
    route: &Route,
    roots: &RootCertStore,
    model: &str,
    api_key: &str,
    body: &[u8],
) -> Result<Value, Stop> {
    let mut body = checked(body, model, api_key)?;
    let model_key = SealKey::from_ed25519(&proof.intel.model_key).ok_or_else(|| {
        Stop::Refused(Refusal::Malformed(
            "the model's key is not one that can be encrypted to".into(),
        ))
    })?;
    let reply_key =
        ReplyKey::fresh().ok_or_else(|| Stop::Request("no randomness for the reply key".into()))?;
    seal_request(&mut body, &mut |text| {
        model_key
            .seal(text)
            .ok_or_else(|| "no randomness for the encryption".to_owned())
    })
    .map_err(Stop::Request)?;
    let body = serde_json::to_vec(&body).expect("a JSON map serializes");

    // `connect` writes no byte of the request: a connection it cannot make
    // is tried again there, before anything of the request goes out.
    let (mut tls, spki_sha256) = connect(route, NEAR, roots).map_err(Stop::Connect)?;
    if spki_sha256 != proof.intel.gateway_tls_key {
        return Err(Stop::Pin);
    }
    tls.sock
        .set_read_timeout(Some(REPLY_WAIT))
        .map_err(|e| Stop::Connect(e.into()))?;
    let authorization = format!("Bearer {api_key}");
    let client_key = hex::encode(reply_key.public());
    let model_key = hex::encode(proof.intel.model_key);
    let mut answer = request(
        &mut tls,
        "POST",
        NEAR,
        "/v1/chat/completions",
        &[
            ("Authorization", &authorization),
            ("Content-Type", "application/json"),
            ("Accept", "application/json"),
            ("X-Signing-Algo", "ed25519"),
            ("X-Client-Pub-Key", &client_key),
            ("X-Model-Pub-Key", &model_key),
            ("X-Encryption-Version", "2"),
            ("X-Encrypt-All-Fields", "true"),
            ("x-no-aliasing", "true"),
        ],
        Some(&body),
        REPLY_LIMIT,
    )
    .map_err(Stop::Send)?;
    if answer.status != 200 {
        // The key is replaced before the body is cut to its start, so no
        // part of it is left where the cut falls.
        answer.body = String::from_utf8_lossy(&answer.body)
            .replace(api_key, "[the key]")
            .into_bytes();
        return Err(Stop::Status {
            code: answer.status,
            detail: answer.detail(),
        });
    }
    let mut reply: Value =
        serde_json::from_slice(&answer.body).map_err(|_| Stop::Reply("it is not JSON".into()))?;
    open_reply(&mut reply, &reply_key).map_err(Stop::Reply)?;
    Ok(reply)
}

/// The request as it will go, before sealing: a JSON object for `model`,
/// not streamed, with no field NEAR's encryption would leave in plain text
/// but those in `PLAIN`; and a key a header can carry.
fn checked(body: &[u8], model: &str, api_key: &str) -> Result<Map<String, Value>, Stop> {
    if api_key.is_empty() || !api_key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(Stop::Request(
            "the key is empty or holds characters a header cannot carry".into(),
        ));
    }
    let Ok(Value::Object(body)) = serde_json::from_slice::<Value>(body) else {
        return Err(Stop::Request("it is not a JSON object".into()));
    };
    match body.get("model").and_then(Value::as_str) {
        Some(named) if named == model => {}
        Some(named) => return Err(Stop::Request(format!("it is for {named}, not {model}"))),
        None => return Err(Stop::Request("it names no model".into())),
    }
    match body.get("stream") {
        None | Some(Value::Bool(false)) => {}
        Some(Value::Bool(true)) => {
            return Err(Stop::Request(
                "streamed replies are not supported yet".into(),
            ))
        }
        Some(_) => return Err(Stop::Request("`stream` is neither true nor false".into())),
    }
    // Walked without sealing, only to refuse what could not be sealed.
    seal_request(&mut body.clone(), &mut |text| Ok(text.to_owned())).map_err(Stop::Request)?;
    Ok(body)
}

/// Seals every field of the person's words in a request, as all-fields mode
/// asks: each message's content (a list of parts as its JSON, as is text
/// that reads as a JSON list, made one text part), name,
/// reasoning, refusal and tool calls' names and arguments; each tool's
/// name, description and parameters (as their JSON); and the name in a
/// tool choice. Anything else must be in `PLAIN`, a role or a tool call's
/// id; any other field is refused.
fn seal_request(
    body: &mut Map<String, Value>,
    seal: &mut dyn FnMut(&str) -> Result<String, String>,
) -> Result<(), String> {
    for (name, value) in body.iter_mut() {
        match name.as_str() {
            "messages" => {
                for message in objects(value, "messages")? {
                    seal_message(message, seal)?;
                }
            }
            "tools" => {
                for tool in objects(value, "tools")? {
                    seal_tool(tool, seal)?;
                }
            }
            // "auto", "none" or "required" carry nothing of the person's.
            "tool_choice" if value.is_string() => {}
            "tool_choice" => {
                let choice = value
                    .as_object_mut()
                    .ok_or("`tool_choice` is neither a word nor an object")?;
                seal_texts(object(choice, "function")?, &["name"], seal)?;
            }
            other if PLAIN.contains(&other) => {}
            other => return Err(uncovered(other)),
        }
    }
    Ok(())
}

fn seal_message(
    message: &mut Map<String, Value>,
    seal: &mut dyn FnMut(&str) -> Result<String, String>,
) -> Result<(), String> {
    for (name, value) in message.iter_mut() {
        match name.as_str() {
            "role" | "tool_call_id" => {}
            "content" if value.is_array() => *value = Value::String(seal(&value.to_string())?),
            // NEAR reads opened content that parses as a JSON list as a list
            // of parts, so text that is one goes as one text part.
            "content" if value.as_str().is_some_and(is_list) => {
                let parts = json!([{"type": "text", "text": value}]);
                *value = Value::String(seal(&parts.to_string())?)
            }
            "content" | "name" | "reasoning_content" | "reasoning" | "refusal" => {
                seal_text(value, name, seal)?
            }
            "tool_calls" if value.is_null() => {}
            "tool_calls" => {
                for call in objects(value, "tool_calls")? {
                    seal_texts(object(call, "function")?, &["name", "arguments"], seal)?;
                }
            }
            other => return Err(uncovered(other)),
        }
    }
    Ok(())
}

fn seal_tool(
    tool: &mut Map<String, Value>,
    seal: &mut dyn FnMut(&str) -> Result<String, String>,
) -> Result<(), String> {
    if tool.get("type").and_then(Value::as_str) != Some("function") {
        return Err(
            "only function tools can be sent; other kinds have NEAR run a tool itself".into(),
        );
    }
    let function = object(tool, "function")?;
    seal_texts(function, &["name", "description"], seal)?;
    if let Some(parameters) = function.get_mut("parameters").filter(|p| !p.is_null()) {
        *parameters = Value::String(seal(&parameters.to_string())?);
    }
    Ok(())
}

fn seal_texts(
    map: &mut Map<String, Value>,
    names: &[&str],
    seal: &mut dyn FnMut(&str) -> Result<String, String>,
) -> Result<(), String> {
    for name in names {
        if let Some(value) = map.get_mut(*name) {
            seal_text(value, name, seal)?;
        }
    }
    Ok(())
}

fn seal_text(
    value: &mut Value,
    name: &str,
    seal: &mut dyn FnMut(&str) -> Result<String, String>,
) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        Value::String(text) => {
            *text = seal(text)?;
            Ok(())
        }
        _ => Err(format!("`{name}` is not text")),
    }
}

fn is_list(text: &str) -> bool {
    serde_json::from_str::<Vec<Value>>(text).is_ok()
}

fn uncovered(name: &str) -> String {
    format!("it holds `{name}`, which NEAR's encryption would leave in plain text")
}

/// Opens, with this request's key, every field NEAR seals in a chat reply
/// in all-fields mode: each choice's content, reasoning, refusal and tool
/// calls' names and arguments. A field that does not open, or is not text,
/// refuses the whole reply; so do log probabilities, audio and the old
/// function call, which the request cannot ask for.
fn open_reply(reply: &mut Value, key: &ReplyKey) -> Result<(), String> {
    let choices = reply.get_mut("choices").ok_or("it has no choices")?;
    for choice in objects(choices, "choices")? {
        if choice.get("logprobs").is_some_and(|v| !v.is_null()) {
            return Err("it carries log probabilities, which were not asked for".into());
        }
        let message = object(choice, "message")?;
        for name in ["audio", "function_call"] {
            if message.get(name).is_some_and(|v| !v.is_null()) {
                return Err(format!("it carries `{name}`, which was not asked for"));
            }
        }
        for name in ["content", "reasoning_content", "reasoning", "refusal"] {
            if let Some(value) = message.get_mut(name) {
                open_text(value, name, key)?;
            }
        }
        if let Some(calls) = message.get_mut("tool_calls").filter(|v| !v.is_null()) {
            for call in objects(calls, "tool_calls")? {
                let function = object(call, "function")?;
                for name in ["name", "arguments"] {
                    if let Some(value) = function.get_mut(name) {
                        open_text(value, name, key)?;
                    }
                }
            }
        }
    }
    Ok(())
}

fn open_text(value: &mut Value, name: &str, key: &ReplyKey) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        Value::String(sealed) => {
            *sealed = key
                .open(sealed)
                .ok_or_else(|| format!("`{name}` does not decrypt with this request's key"))?;
            Ok(())
        }
        _ => Err(format!("`{name}` is not encrypted text")),
    }
}

/// The objects of a list; anything else is refused.
fn objects<'a>(
    value: &'a mut Value,
    name: &str,
) -> Result<Vec<&'a mut Map<String, Value>>, String> {
    let not_objects = || format!("`{name}` is not a list of objects");
    value
        .as_array_mut()
        .ok_or_else(not_objects)?
        .iter_mut()
        .map(|item| item.as_object_mut().ok_or_else(not_objects))
        .collect()
}

/// The object under `name`; anything else is refused.
fn object<'a>(
    map: &'a mut Map<String, Value>,
    name: &str,
) -> Result<&'a mut Map<String, Value>, String> {
    map.get_mut(name)
        .and_then(Value::as_object_mut)
        .ok_or_else(|| format!("`{name}` is not an object"))
}

/// The gate checks of the proof age, offline. A passed proof is put in
/// `Kept` by hand, and `ask` is pointed at a proxy on this machine that
/// closes every connection at once, so the first thing `ask` does fails and
/// its `Stop` says what that was: `Stop::Fetch` when it went to fetch a new
/// report, `Stop::Connect` when it went straight to sending under the kept
/// proof, `Stop::Request` when it went nowhere. Nothing leaves this machine.
#[cfg(test)]
mod proof_age {
    use std::net::{SocketAddr, TcpListener};
    use std::thread;
    use std::time::Duration;

    use serde_json::json;

    use super::{ask, seconds, Answered, Kept, Passed, Stop, DAY, HOUR};
    use crate::e2ee::ReplyKey;
    use crate::{GpuProof, IntelProof, Pins, Proof, Proxy, Route, Routes, SocksAddr, TcbStatus};

    const MODEL: &str = "z-ai/glm-5.3-flash";
    const OTHER: &str = "Qwen/Qwen3.8-27B";
    const TEN_MINUTES: Duration = Duration::from_secs(600);

    /// A proof that passed at `at`, with a model key that can be sealed for.
    fn passed(at: u64) -> Passed {
        Passed {
            proof: Proof {
                intel: IntelProof {
                    gateway_key: [0; 32],
                    gateway_tls_key: [7; 32],
                    model_key: ReplyKey([0x42; 32]).public(),
                    instances: 1,
                    gateway_tcb: TcbStatus::UpToDate,
                    model_tcb: vec![TcbStatus::UpToDate],
                },
                gpu: GpuProof { gpus: 8 },
            },
            at,
        }
    }

    /// `ask` for `model` under `proof_age`, through a proxy that closes
    /// every connection.
    fn attempt(kept: &mut Kept, model: &str, proof_age: Duration) -> Result<Answered, Stop> {
        let route = Route::Tor(Proxy {
            addr: SocksAddr::Tcp(closing_proxy()),
            user: "proof",
            password: "age",
        });
        let routes = Routes {
            near: route,
            intel: route,
        };
        let body = json!({"model": model, "messages": [{"role": "user", "content": "ping"}]});
        let pins = Pins {
            gateway: Vec::new(),
            model: Vec::new(),
        };
        ask(
            &routes,
            model,
            "sk-stand-in",
            body.to_string().as_bytes(),
            &pins,
            kept,
            proof_age,
        )
    }

    /// Whether `ask` for `model` under `proof_age` went straight to sending
    /// under a kept proof, rather than fetching a new report.
    fn reuses(kept: &mut Kept, model: &str, proof_age: Duration) -> bool {
        match attempt(kept, model, proof_age) {
            Err(Stop::Connect(_)) => true,
            Err(Stop::Fetch(_)) => false,
            other => panic!("expected a failed connection, got {other:?}"),
        }
    }

    /// A proxy on this machine that takes each connection and closes it.
    fn closing_proxy() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            for connection in listener.incoming() {
                drop(connection);
            }
        });
        addr
    }

    #[test]
    fn a_proof_older_than_the_proof_age_is_not_used() {
        let now = seconds().unwrap();
        let mut kept = Kept::new(DAY).unwrap();
        kept.keep(MODEL, &passed(now - 590), 600);
        assert!(reuses(&mut kept, MODEL, TEN_MINUTES));
        // The same proof, for a call with a shorter proof age.
        assert!(!reuses(&mut kept, MODEL, Duration::from_secs(589)));
        kept.keep(MODEL, &passed(now - 601), 600);
        assert!(!reuses(&mut kept, MODEL, TEN_MINUTES));
        // Passed after now, as when the clock went back: too old.
        kept.keep(MODEL, &passed(now + 60), 600);
        assert!(!reuses(&mut kept, MODEL, TEN_MINUTES));

        // The last second it is used, and the first it is not.
        kept.keep(MODEL, &passed(1_000_000), 600);
        assert!(kept.proof_for(MODEL, 600, 1_000_600).is_some());
        assert!(kept.proof_for(MODEL, 600, 1_000_601).is_none());
        assert!(kept.proof_for(MODEL, 600, 999_999).is_none());
    }

    #[test]
    fn a_new_check_that_fails_leaves_no_proof_kept() {
        let now = seconds().unwrap();
        let mut kept = Kept::new(DAY).unwrap();
        kept.keep(MODEL, &passed(now - 590), 600);
        // Too old for this call: a new check is made, and fails.
        assert!(!reuses(&mut kept, MODEL, Duration::from_secs(60)));
        // The proof it did not pass is not used by a call with a longer age.
        assert!(!reuses(&mut kept, MODEL, HOUR));
    }

    #[test]
    fn a_proof_kept_for_one_model_is_never_used_for_another() {
        let mut kept = Kept::new(DAY).unwrap();
        kept.keep(MODEL, &passed(seconds().unwrap()), 3600);
        assert!(!reuses(&mut kept, OTHER, HOUR));
        assert!(reuses(&mut kept, MODEL, HOUR));
    }

    #[test]
    fn a_proof_age_of_zero_uses_and_keeps_nothing() {
        let mut kept = Kept::new(DAY).unwrap();
        kept.keep(MODEL, &passed(seconds().unwrap()), 0);
        assert!(kept.proofs.is_empty());
        // A proof that passed this second is not used under a proof age of
        // zero, and the new check leaves nothing kept.
        kept.keep(MODEL, &passed(seconds().unwrap()), 600);
        assert!(!reuses(&mut kept, MODEL, Duration::ZERO));
        assert!(kept.proofs.is_empty());
    }

    #[test]
    fn a_proof_age_over_an_hour_is_refused_before_anything_is_fetched() {
        let mut kept = Kept::new(DAY).unwrap();
        kept.keep(MODEL, &passed(seconds().unwrap()), 3600);
        let over = HOUR + Duration::from_secs(1);
        assert!(matches!(
            attempt(&mut kept, MODEL, over),
            Err(Stop::Request(_))
        ));
        assert!(reuses(&mut kept, MODEL, HOUR));
    }
}
