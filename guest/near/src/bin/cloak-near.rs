//! The helper the Mac app starts for NEAR mode. It takes no arguments. It
//! reads one request a line on standard input and writes one answer a line
//! on standard output for each, in order, one at a time, and ends when
//! standard input closes. Nothing else goes to standard output; standard
//! error gets only a failure to read or write those two, never the key, a
//! message or a reply. The account key comes only inside an `ask` line.
//! The line format is in README.md, "The helper", and `cloak_near::respond`.
//!
//!     cloak-near

use std::io::{self, BufRead, Write};
use std::process::ExitCode;
use std::time::Duration;

use cloak_near::{respond, Kept, Pins};

const PINS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../reference/near-pins.json"
));
/// How long Intel's collateral and Intel Trust Authority's keys are kept.
const INTEL_AGE: Duration = Duration::from_secs(60 * 60);

fn main() -> ExitCode {
    if std::env::args_os().len() > 1 {
        eprintln!("usage: cloak-near (no arguments: requests come on standard input)");
        return ExitCode::from(2);
    }
    let pins: Pins = match serde_json::from_str(PINS) {
        Ok(pins) => pins,
        Err(error) => {
            eprintln!("cloak-near: the pins file: {error}");
            return ExitCode::FAILURE;
        }
    };
    let mut kept = Kept::new(INTEL_AGE).expect("an hour is within a day");
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut line = Vec::new();
    loop {
        line.clear();
        match input.read_until(b'\n', &mut line) {
            Ok(0) => return ExitCode::SUCCESS,
            Ok(_) => {}
            Err(error) => {
                eprintln!("cloak-near: reading standard input: {error}");
                return ExitCode::FAILURE;
            }
        }
        let answer = respond(&line, &pins, &mut kept);
        if let Err(error) = writeln!(output, "{answer}").and_then(|()| output.flush()) {
            eprintln!("cloak-near: writing standard output: {error}");
            return ExitCode::FAILURE;
        }
    }
}
