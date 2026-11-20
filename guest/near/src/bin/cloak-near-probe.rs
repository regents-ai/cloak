//! Development only: fetches one model's report from NEAR's gateway, its
//! Intel collateral, and Intel Trust Authority's tokens on the GPUs under
//! the same nonce with the keys Intel signs them with, checks both sides
//! against the pins in reference/near-pins.json, and says what happened in
//! plain words. No account key, no chat request: GETs only, of the report,
//! the tokens, Intel's collateral and Intel's keys.
//!
//!     cloak-near-probe (--socks 127.0.0.1:9050 | --direct) --model Qwen/Qwen3.8-27B [--save DIR]
//!     cloak-near-probe (--socks 127.0.0.1:9050 | --direct) --model Qwen/Qwen3.8-27B --key-file FILE [--proof-age SECONDS] [--repeat N]
//!
//! Exactly one route: --socks goes through Tor's SOCKS5 port at that
//! address, one circuit for NEAR and one for Intel; --direct goes straight
//! there, so NEAR and Intel see this Mac's internet address. The first line
//! printed says which.
//!
//! With --save, the report, nonce, TLS key hash, collateral, NEAR's answer
//! of Intel's tokens, Intel's keys, and the time both checks are made at go
//! into DIR, as the gate check's fixtures are kept.
//!
//! With --key-file, the account key is read from FILE and the probe makes
//! chat requests through `ask` instead: the proof check, then the message
//! "ping", encrypted to the checked model key. The key is never printed.
//! --repeat asks N times (1 when not given) with one `Kept`, which keeps a
//! passed proof for --proof-age seconds (0 when not given: every ask checks
//! its own); for each ask it says how long it took and how long before the
//! reply its proof passed.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cloak_near::{
    ask, fetch_collateral, fetch_ita_keys, fetch_ita_tokens, fetch_report, verify_gpu,
    verify_intel, FetchError, Kept, Pins, Proxy, Route, Routes, Stop,
};
use hex::encode as hex;
use serde_json::json;

const PINS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../reference/near-pins.json"
));
const ATTEMPTS: u32 = 3;

fn main() -> ExitCode {
    let mut socks = None;
    let mut direct = false;
    let mut model = None;
    let mut save = None;
    let mut key_file = None;
    let mut proof_age = None;
    let mut repeat = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socks" => match args.next().and_then(|a| a.parse::<SocketAddr>().ok()) {
                Some(addr) => socks = Some(addr),
                None => return usage(),
            },
            "--direct" => direct = true,
            "--model" => model = args.next(),
            "--save" => save = args.next().map(PathBuf::from),
            "--key-file" => key_file = args.next().map(PathBuf::from),
            "--proof-age" => match args.next().and_then(|a| a.parse::<u64>().ok()) {
                Some(seconds) => proof_age = Some(seconds),
                None => return usage(),
            },
            "--repeat" => match args.next().and_then(|a| a.parse::<u32>().ok()) {
                Some(times) if times > 0 => repeat = Some(times),
                _ => return usage(),
            },
            _ => return usage(),
        }
    }
    let Some(model) = model else {
        return usage();
    };
    // Exactly one route; --save only without --key-file, and the chat
    // settings only with it.
    let chat_settings = proof_age.is_some() || repeat.is_some();
    if socks.is_some() == direct
        || (key_file.is_some() && save.is_some())
        || (key_file.is_none() && chat_settings)
    {
        return usage();
    }
    match socks {
        Some(addr) => println!(
            "Route: Tor, through the SOCKS5 proxy at {addr}, one circuit for NEAR and one for Intel"
        ),
        None => println!("Route: direct, no Tor: NEAR and Intel see this Mac's internet address"),
    }
    let outcome = match key_file {
        Some(key_file) => chat(
            socks,
            &model,
            &key_file,
            proof_age.unwrap_or(0),
            repeat.unwrap_or(1),
        ),
        None => {
            let started = Instant::now();
            let outcome = run(socks, &model, save);
            println!("In all: {:.1} s", started.elapsed().as_secs_f64());
            outcome
        }
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            println!("Stopped: {message}");
            ExitCode::FAILURE
        }
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: cloak-near-probe (--socks HOST:PORT | --direct) --model NAME [--save DIR | --key-file FILE [--proof-age SECONDS] [--repeat N]]"
    );
    ExitCode::from(2)
}

/// The proof check and then a chat request saying "ping", with the account
/// key in `key_file`, `repeat` times with one `Kept` that keeps a passed
/// proof for `proof_age` seconds; through Tor at `socks`, or direct.
fn chat(
    socks: Option<SocketAddr>,
    model: &str,
    key_file: &Path,
    proof_age: u64,
    repeat: u32,
) -> Result<(), String> {
    let pins: Pins = serde_json::from_str(PINS).map_err(|e| format!("the pins file: {e}"))?;
    let key = std::fs::read_to_string(key_file)
        .map_err(|e| format!("reading {}: {e}", key_file.display()))?;
    let mut kept = Kept::new(Duration::from_secs(60 * 60), Duration::from_secs(proof_age))
        .ok_or("a proof age over an hour is refused")?;
    println!("Checking NEAR AI Cloud's proof for {model}, then sending \"ping\"");
    println!("Proof age {proof_age} s; {repeat} ask(s)");

    let identities = [fresh_identity()?, fresh_identity()?];
    let routes = routes(socks, &identities);
    let body =
        json!({"model": model, "messages": [{"role": "user", "content": "ping"}]}).to_string();
    let mut stopped = 0;
    for n in 1..=repeat {
        println!("Ask {n} of {repeat}:");
        if let Err(stop) = ask_once(
            &routes,
            model,
            key.trim(),
            body.as_bytes(),
            &pins,
            &mut kept,
        ) {
            println!("Stopped: {stop}");
            stopped += 1;
        }
    }
    match stopped {
        0 => Ok(()),
        _ => Err(format!("{stopped} of {repeat} ask(s) got no reply")),
    }
}

/// One ask, said in plain words: how long it took, how long before the
/// reply its proof passed, and the reply.
fn ask_once(
    routes: &Routes,
    model: &str,
    key: &str,
    body: &[u8],
    pins: &Pins,
    kept: &mut Kept,
) -> Result<(), String> {
    let started = Instant::now();
    let outcome = ask(routes, model, key, body, pins, kept);
    let took = started.elapsed().as_secs_f64();
    match outcome {
        Ok(answered) => {
            // The clock counts whole seconds, so a proof kept from an ask
            // that ended in the second this one began cannot be told from a
            // new one; the age says it either way.
            println!(
                "The proof this went under passed {} s before the reply came",
                seconds_now()?.saturating_sub(answered.proof_passed_at)
            );
            println!(
                "The proof passed for {} model instance(s) and the {} GPUs of one model server, model encryption key {}",
                answered.proof.intel.instances,
                answered.proof.gpu.gpus,
                hex(answered.proof.intel.model_key)
            );
            println!("NEAR answered 200 in {took:.1} s; the reply, every encrypted field opened:");
            println!(
                "{}",
                serde_json::to_string_pretty(&answered.reply).expect("JSON prints")
            );
            Ok(())
        }
        Err(Stop::Pin) => {
            println!("The proof passed; nothing was sent to the chat endpoint ({took:.1} s).");
            Err(Stop::Pin.to_string())
        }
        Err(stop @ (Stop::Send(_) | Stop::Status { .. } | Stop::Reply(_))) => {
            println!("The proof passed; the encrypted request went after it ({took:.1} s in all).");
            Err(stop.to_string())
        }
        Err(stop) => {
            println!("Nothing was sent to the chat endpoint ({took:.1} s).");
            Err(stop.to_string())
        }
    }
}

fn run(socks: Option<SocketAddr>, model: &str, save: Option<PathBuf>) -> Result<(), String> {
    let pins: Pins = serde_json::from_str(PINS).map_err(|e| format!("the pins file: {e}"))?;
    println!("Checking NEAR AI Cloud's proof for {model}");

    let identities = [fresh_identity()?, fresh_identity()?];
    let routes = routes(socks, &identities);
    let mut busy = 0;
    let fetched = loop {
        let started = Instant::now();
        match fetch_report(&routes.near, model) {
            Ok(fetched) => {
                println!(
                    "Report: {} bytes in {:.1} s on one connection; gateway TLS key {}",
                    fetched.report.len(),
                    started.elapsed().as_secs_f64(),
                    hex(fetched.spki_sha256)
                );
                break fetched;
            }
            Err(FetchError::Busy { retry_after }) if busy + 1 < ATTEMPTS => {
                busy += 1;
                let wait = retry_after.unwrap_or(1);
                println!("The gateway was busy (429); asking again in {wait} s with a new nonce");
                sleep(Duration::from_secs(wait));
            }
            Err(error) => return Err(format!("fetching the report: {error}")),
        }
    };
    if busy > 0 {
        println!("Busy answers before the report: {busy}");
    }

    let started = Instant::now();
    let collateral = fetch_collateral(&routes.intel, &fetched.report)
        .map_err(|e| format!("fetching Intel's collateral: {e}"))?;
    println!(
        "Intel collateral: {} platform famil{} ({}), {} requests to Intel in {:.1} s",
        collateral.len(),
        if collateral.len() == 1 { "y" } else { "ies" },
        collateral
            .iter()
            .map(|c| format!("{} {}", c.fmspc, c.ca))
            .collect::<Vec<_>>()
            .join(", "),
        collateral.len() * 4,
        started.elapsed().as_secs_f64()
    );

    let write = |name: &str, bytes: &[u8]| match &save {
        Some(dir) => std::fs::create_dir_all(dir)
            .and_then(|()| std::fs::write(dir.join(name), bytes))
            .map_err(|e| format!("saving {name} in {}: {e}", dir.display())),
        None => Ok(()),
    };
    write("report.json", &fetched.report)?;
    write("nonce.hex", hex(fetched.nonce).as_bytes())?;
    write("spki.hex", hex(fetched.spki_sha256).as_bytes())?;
    write("model.txt", model.as_bytes())?;
    write(
        "collateral.json",
        &serde_json::to_vec(&collateral).map_err(|e| format!("encoding the collateral: {e}"))?,
    )?;

    let proof = verify_intel(
        &fetched.report,
        &fetched.nonce,
        &fetched.spki_sha256,
        model,
        &collateral,
        &pins,
        seconds_now()?,
    )
    .map_err(|refusal| format!("refused: {refusal}"))?;

    println!(
        "Intel's side passed, for the gateway and each of {} model instance(s):",
        proof.instances
    );
    for line in [
        "the gateway's quote is genuine Intel TDX by Intel's chain, revocation lists and collateral, which is in date",
        "the gateway's platform is UpToDate and not in debug mode",
        "the gateway's quote ties its Ed25519 key to the TLS key on this connection and to our nonce",
        "the gateway sent back our nonce and the TLS key we saw",
        "the gateway's event log replays to its RTMR3, and its compose file matches MRCONFIGID",
        "the gateway's MRTD, RTMR0-2, MRCONFIGID, app-id, key-provider, mr-kms and os-image-hash are the pinned ones",
        "every model entry is for this model, and its encryption key is the key its quote binds",
        "every instance holds the same encryption key and has an instance id of its own, bound in RTMR3",
        "every instance's quote passes the same Intel, debug, report data, event log and compose checks",
        "every instance's measurements are a pinned model set, its compose file compared without the digits of its one INSTANCE_LABEL=gpu",
    ] {
        println!("  passed: {line}");
    }
    println!("Gateway key: {}", hex(proof.gateway_key));
    println!("Model encryption key: {}", hex(proof.model_key));
    println!(
        "Intel TCB status: gateway {}; instances {}",
        proof.gateway_tcb,
        proof
            .model_tcb
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .join(", ")
    );

    // The same nonce as the report's, on the report's route.
    let started = Instant::now();
    let tokens = fetch_ita_tokens(&routes.near, model, &fetched.nonce).map_err(|e| {
        format!(
            "fetching Intel Trust Authority's tokens from NEAR ({:.1} s): {e}",
            started.elapsed().as_secs_f64()
        )
    })?;
    println!(
        "Intel Trust Authority's tokens, from NEAR under the same nonce: {} bytes in {:.1} s",
        tokens.len(),
        started.elapsed().as_secs_f64()
    );
    let started = Instant::now();
    let keys = fetch_ita_keys(&routes.intel).map_err(|e| {
        format!(
            "fetching Intel Trust Authority's keys ({:.1} s): {e}",
            started.elapsed().as_secs_f64()
        )
    })?;
    println!(
        "Intel Trust Authority's signing keys: {} bytes in {:.1} s",
        keys.len(),
        started.elapsed().as_secs_f64()
    );
    // Intel dates its tokens by its own clock: checked at a time read after
    // they came, which is also the time the saved set is checked at.
    let checked_at = seconds_now()?;
    write("ita.json", &tokens)?;
    write("ita-keys.json", &keys)?;
    write("fetched-at.txt", checked_at.to_string().as_bytes())?;
    if let Some(dir) = &save {
        println!(
            "Saved the report, nonce, TLS key hash, collateral, Intel's tokens and keys, and the time in {}",
            dir.display()
        );
    }

    let gpu = verify_gpu(
        &tokens,
        &fetched.nonce,
        model,
        &proof,
        &keys,
        &pins,
        checked_at,
    )
    .map_err(|refusal| format!("refused: {refusal}"))?;
    println!(
        "Intel Trust Authority's side passed, for the {} GPUs of one model server NEAR's gateway chose:",
        gpu.gpus
    );
    for line in [
        "the gateway's token and the GPU token are PS384-signed by a key Intel publishes, from Intel Trust Authority, in date",
        "in each, the gateway quote Intel appraised binds Intel's nonce with the gateway key, the TLS key and our nonce",
        "that quote has a pinned gateway's MRTD, RTMR0-2 and MRCONFIGID, Intel rates it UpToDate and not debuggable",
        "Intel's nonce was issued at most five minutes ago",
        "every GPU's evidence was made under SHA-256 of Intel's nonce, and the overall verdict is true",
        "every GPU has every boolean NVIDIA claim true, measres success, secure boot on, debugging disabled, and valid certificate chains with good OCSP answers",
    ] {
        println!("  passed: {line}");
    }
    println!(
        "Not checked: which of the model's servers those GPUs are in, the other servers' GPUs, that any GPU and quote are in one machine, the model workload, where the images came from, and the replies."
    );
    Ok(())
}

/// The routes to NEAR and to Intel: through Tor at `socks`, each with a
/// SOCKS user name of its own, or both direct.
fn routes<'a>(socks: Option<SocketAddr>, identities: &'a [String; 2]) -> Routes<'a> {
    let route = |identity: &'a str| match socks {
        Some(addr) => Route::Tor(Proxy {
            addr,
            user: identity,
            password: "cloak",
        }),
        None => Route::Direct,
    };
    Routes {
        near: route(&identities[0]),
        intel: route(&identities[1]),
    }
}

/// A SOCKS user name of its own, so Tor gives these connections a circuit
/// of their own.
fn fresh_identity() -> Result<String, String> {
    let mut bytes = [0u8; 8];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut bytes)
        .map_err(|_| "no randomness".to_string())?;
    Ok(hex(bytes))
}

fn seconds_now() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|e| e.to_string())
}
