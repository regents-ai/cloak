//! Development only: fetches one model's report from NEAR's gateway and its
//! Intel collateral through a SOCKS5 proxy, checks it against the pins in
//! reference/near-pins.json, and says what happened in plain words. No
//! account key, no chat request: GETs of the report and Intel's collateral.
//!
//!     cloak-near-probe --socks 127.0.0.1:9050 --model Qwen/Qwen3.8-27B [--save DIR]
//!
//! With --save, the report, nonce, TLS key hash, collateral and fetch time go
//! into DIR, as the gate check's fixtures are kept.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cloak_near::{fetch_collateral, fetch_report, verify, FetchError, Pins, Proxy};
use hex::encode as hex;

const PINS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../reference/near-pins.json"
));
const ATTEMPTS: u32 = 3;

fn main() -> ExitCode {
    let mut socks = None;
    let mut model = None;
    let mut save = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socks" => socks = args.next().and_then(|a| a.parse::<SocketAddr>().ok()),
            "--model" => model = args.next(),
            "--save" => save = args.next().map(PathBuf::from),
            _ => return usage(),
        }
    }
    let (Some(socks), Some(model)) = (socks, model) else {
        return usage();
    };
    match run(socks, &model, save) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            println!("Stopped: {message}");
            ExitCode::FAILURE
        }
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: cloak-near-probe --socks HOST:PORT --model NAME [--save DIR]");
    ExitCode::from(2)
}

fn run(socks: SocketAddr, model: &str, save: Option<PathBuf>) -> Result<(), String> {
    let pins: Pins = serde_json::from_str(PINS).map_err(|e| format!("the pins file: {e}"))?;
    println!("Checking NEAR AI Cloud's proof for {model}, through {socks}");

    let report_identity = fresh_identity()?;
    let report_proxy = Proxy {
        addr: socks,
        user: &report_identity,
        password: "cloak",
    };
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
    let fetched_at = seconds_now()?;
    if busy > 0 {
        println!("Busy answers before the report: {busy}");
    }

    let collateral_identity = fresh_identity()?;
    let collateral_proxy = Proxy {
        addr: socks,
        user: &collateral_identity,
        password: "cloak",
    };
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

    if let Some(dir) = &save {
        let write = |name: &str, bytes: &[u8]| {
            std::fs::write(dir.join(name), bytes).map_err(|e| format!("saving {name}: {e}"))
        };
        std::fs::create_dir_all(dir).map_err(|e| format!("making {}: {e}", dir.display()))?;
        write("report.json", &fetched.report)?;
        write("nonce.hex", hex(fetched.nonce).as_bytes())?;
        write("spki.hex", hex(fetched.spki_sha256).as_bytes())?;
        write("fetched-at.txt", fetched_at.to_string().as_bytes())?;
        write("model.txt", model.as_bytes())?;
        write(
            "collateral.json",
            &serde_json::to_vec(&collateral)
                .map_err(|e| format!("encoding the collateral: {e}"))?,
        )?;
        println!(
            "Saved the report, nonce, TLS key hash, collateral and time in {}",
            dir.display()
        );
    }

    let now = seconds_now()?;
    let proof = verify(
        &fetched.report,
        &fetched.nonce,
        &fetched.spki_sha256,
        model,
        &collateral,
        &pins,
        now,
    )
    .map_err(|refusal| format!("refused: {refusal}"))?;

    println!(
        "Every check passed, for the gateway and each of {} model instance(s):",
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
    println!(
        "Not checked: the GPU, the model workload, where the images came from, and the replies."
    );
    Ok(())
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
