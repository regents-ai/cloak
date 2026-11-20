//! Proof before sending, for the helper as the app drives it, offline: the
//! `cloak-near` binary is started, an `ask` line and then a `check` line go
//! to its standard input, and standard input is closed. The route is tor at
//! a socket file on this machine whose listener closes every connection,
//! so no proof can be had. Each answer must say the line stopped while
//! fetching the proof and that nothing was sent to the chat endpoint, and
//! neither standard output nor standard error may hold the key or the
//! message's words anywhere. Nothing leaves this machine.
//!
//!     cargo test --locked --manifest-path guest/near/Cargo.toml

use std::io::Write;
use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

const MODEL: &str = "Qwen/Qwen3.8-27B";
const KEY: &str = "sk-example-not-a-real-key";
const WORDS: &str = "words only the person wrote";

#[test]
fn an_ask_whose_proof_cannot_be_had_sends_nothing_and_never_shows_the_key() {
    let made = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let folder = std::env::temp_dir().join(format!(
        "cloak-near-helper-{}-{}",
        std::process::id(),
        made.as_nanos()
    ));
    std::fs::create_dir(&folder).unwrap();
    let socket = folder.join("socks");
    let listener = UnixListener::bind(&socket).unwrap();
    thread::spawn(move || {
        for connection in listener.incoming() {
            drop(connection);
        }
    });

    let route = json!({
        "via": "tor",
        "socket": socket,
        "near_identity": "near",
        "intel_identity": "intel"
    });
    let ask = json!({
        "request": "ask",
        "model": MODEL,
        "route": route,
        "proof_age": 600,
        "key": KEY,
        "body": {"model": MODEL, "messages": [{"role": "user", "content": WORDS}]}
    });
    let check = json!({"request": "check", "model": MODEL, "route": route, "proof_age": 600});

    let mut helper = Command::new(env!("CARGO_BIN_EXE_cloak-near"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = helper.stdin.take().unwrap();
    writeln!(input, "{ask}").unwrap();
    writeln!(input, "{check}").unwrap();
    drop(input);
    let output = helper.wait_with_output().unwrap();
    std::fs::remove_dir_all(&folder).unwrap();

    assert!(output.status.success(), "{:?}", output.status);
    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    for text in [&stdout, &stderr] {
        assert!(!text.contains(KEY));
        assert!(!text.contains(WORDS));
    }
    let answers: Vec<Value> = stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(answers.len(), 2, "{stdout}");
    for answer in &answers {
        assert_eq!(answer["answer"], "stopped", "{answer}");
        assert_eq!(answer["stop"], "fetch", "{answer}");
        assert_eq!(answer["sent"], false, "{answer}");
    }
}
