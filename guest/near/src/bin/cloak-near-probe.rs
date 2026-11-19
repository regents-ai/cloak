//! Development only: fetches one model's report from NEAR's gateway, its
//! Intel collateral, and NVIDIA's verdict on each instance's GPUs with the
//! keys NVIDIA signs them with, through a SOCKS5 proxy, checks both sides
//! against the pins in reference/near-pins.json, and says what happened in
//! plain words. No account key, no chat request: GETs of the report, Intel's
//! collateral and NVIDIA's keys, and one POST of each instance's GPU
//! evidence to NVIDIA.
//!
//!     cloak-near-probe --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B [--save DIR]
//!     cloak-near-probe --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B --key-file FILE
//!
//! With --save, the report, nonce, TLS key hash, collateral, NVIDIA's
//! answers and keys, and the time both checks are made at go into DIR, as
//! the gate check's fixtures are kept.
//!
//! With --key-file, the account key is read from FILE and the probe makes
//! one chat request through `ask` instead: the proof check, then the message
//! "ping", encrypted to the checked model key. The key is never printed.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cloak_near::{
    ask, fetch_collateral, fetch_gpu_verdict, fetch_nvidia_keys, fetch_report, gpu_evidence,
    verify_gpu, verify_intel, FetchError, Kept, Pins, Proxy, Routes, Stop,
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
    let mut model = None;
    let mut save = None;
    let mut key_file = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socks" => socks = args.next().and_then(|a| a.parse::<SocketAddr>().ok()),
            "--model" => model = args.next(),
            "--save" => save = args.next().map(PathBuf::from),
            "--key-file" => key_file = args.next().map(PathBuf::from),
            _ => return usage(),
        }
    }
    let (Some(socks), Some(model)) = (socks, model) else {
        return usage();
    };
    let outcome = match (key_file, save) {
        (Some(_), Some(_)) => return usage(),
        (Some(key_file), None) => chat(socks, &model, &key_file),
        (None, save) => run(socks, &model, save),
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
        "usage: cloak-near-probe --socks HOST:PORT --model NAME [--save DIR | --key-file FILE]"
    );
    ExitCode::from(2)
}

/// The proof check and then one chat request saying "ping", with the
/// account key in `key_file`.
fn chat(socks: SocketAddr, model: &str, key_file: &Path) -> Result<(), String> {
    let pins: Pins = serde_json::from_str(PINS).map_err(|e| format!("the pins file: {e}"))?;
    let key = std::fs::read_to_string(key_file)
        .map_err(|e| format!("reading {}: {e}", key_file.display()))?;
    println!("Checking NEAR AI Cloud's proof for {model}, then sending \"ping\", through {socks}");

    let identities = [fresh_identity()?, fresh_identity()?, fresh_identity()?];
    let routes = Routes {
        near: route(socks, &identities[0]),
        intel: route(socks, &identities[1]),
        nvidia: route(socks, &identities[2]),
    };
    let mut kept = Kept::new(Duration::from_secs(60 * 60)).expect("an hour is within a day");
    let body = json!({"model": model, "messages": [{"role": "user", "content": "ping"}]});
    let started = Instant::now();
    let outcome = ask(
        &routes,
        model,
        key.trim(),
        body.to_string().as_bytes(),
        &pins,
        &mut kept,
    );
    let took = started.elapsed().as_secs_f64();
    match outcome {
        Ok(answered) => {
            println!(
                "The proof passed for {} model instance(s) and their GPUs ({}), model encryption key {}",
                answered.proof.intel.instances,
                gpu_counts(&answered.proof.gpu.gpus),
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

fn run(socks: SocketAddr, model: &str, save: Option<PathBuf>) -> Result<(), String> {
    let pins: Pins = serde_json::from_str(PINS).map_err(|e| format!("the pins file: {e}"))?;
    println!("Checking NEAR AI Cloud's proof for {model}, through {socks}");

    let identities = [fresh_identity()?, fresh_identity()?, fresh_identity()?];
    let report_proxy = route(socks, &identities[0]);
    let mut busy = 0;
    let fetched = loop {
        let started = Instant::now();
        match fetch_report(&report_proxy, model) {
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

    let collateral_proxy = route(socks, &identities[1]);
    let started = Instant::now();
    let collateral = fetch_collateral(&collateral_proxy, &fetched.report)
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
        "every instance's quote passes the same Intel, debug, report data, event log, compose and pin checks",
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

    // Only evidence gathered under our nonce is posted.
    let evidence = gpu_evidence(&fetched.report, &fetched.nonce)
        .map_err(|refusal| format!("refused before posting to NVIDIA: {refusal}"))?;
    let nvidia_proxy = route(socks, &identities[2]);
    let mut answers = Vec::new();
    for (index, evidence) in evidence.iter().enumerate() {
        let started = Instant::now();
        let answer = fetch_gpu_verdict(&nvidia_proxy, evidence).map_err(|e| {
            format!(
                "posting model instance {}'s GPU evidence to NVIDIA ({:.1} s): {e}",
                index + 1,
                started.elapsed().as_secs_f64()
            )
        })?;
        println!(
            "NVIDIA: model instance {}'s evidence for {} GPUs answered 200 in {:.1} s ({} bytes)",
            index + 1,
            evidence.gpus,
            started.elapsed().as_secs_f64(),
            answer.len()
        );
        answers.push(answer);
    }
    let started = Instant::now();
    let keys =
        fetch_nvidia_keys(&nvidia_proxy).map_err(|e| format!("fetching NVIDIA's keys: {e}"))?;
    println!(
        "NVIDIA's signing keys: {} bytes in {:.1} s",
        keys.len(),
        started.elapsed().as_secs_f64()
    );
    // NVIDIA dates its verdicts by its own clock: checked at a time read
    // after they came, which is also the time the saved set is checked at.
    let checked_at = seconds_now()?;
    let answers_json = [b"[".as_slice(), &answers.join(b",".as_slice()), b"]"].concat();
    write("nvidia.json", &answers_json)?;
    write("nvidia-keys.json", &keys)?;
    write("fetched-at.txt", checked_at.to_string().as_bytes())?;
    if let Some(dir) = &save {
        println!(
            "Saved the report, nonce, TLS key hash, collateral, NVIDIA's answers and keys, and the time in {}",
            dir.display()
        );
    }

    let gpu = verify_gpu(&fetched.report, &fetched.nonce, &answers, &keys, checked_at)
        .map_err(|refusal| format!("refused: {refusal}"))?;
    println!(
        "NVIDIA's side passed, for every GPU of each instance ({}):",
        gpu_counts(&gpu.gpus)
    );
    for line in [
        "every instance's GPU evidence was gathered under our nonce, and was posted to NVIDIA unchanged",
        "NVIDIA's overall token for each instance is ES384-signed by a key NVIDIA publishes, from NVIDIA's service, in date and for our nonce",
        "its claims version is 2.0 and its overall result is true",
        "each instance has one NVIDIA token for each GPU in its evidence, each checked the same way",
        "every GPU's token has NVIDIA's policy claims true, measres success, secure boot on and debugging disabled",
    ] {
        println!("  passed: {line}");
    }
    println!(
        "Not checked: that each instance's GPUs and Intel quote are in one machine, the model workload, where the images came from, and the replies."
    );
    Ok(())
}

/// A route through the proxy with a SOCKS user name of its own.
fn route<'a>(socks: SocketAddr, identity: &'a str) -> Proxy<'a> {
    Proxy {
        addr: socks,
        user: identity,
        password: "cloak",
    }
}

/// GPUs passed for each instance, in words.
fn gpu_counts(gpus: &[usize]) -> String {
    gpus.iter()
        .map(|n| format!("{n} GPUs"))
        .collect::<Vec<_>>()
        .join(", ")
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
