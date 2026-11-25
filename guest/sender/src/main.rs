//! cloak-sender: listens on the guest's vsock port for the host only, prints
//! "ready" on standard output once it listens, then serves one connection at
//! a time. Each connection's request and outcome go to standard error by
//! name, never its content.

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    use std::io::Write;
    use std::sync::Arc;
    use std::time::Instant;
    use vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY, VMADDR_CID_HOST};

    let listener = match VsockListener::bind(&VsockAddr::new(VMADDR_CID_ANY, cloak_sender::PORT)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("cloak-sender: cannot listen: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let runtime = Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("runtime"),
    );
    let network = Arc::new(cloak_sender::Network::live());
    println!("ready");
    let _ = std::io::stdout().flush();
    loop {
        let (stream, peer) = match listener.accept() {
            Ok(accepted) => accepted,
            Err(error) => {
                eprintln!("cloak-sender: accept failed: {error}");
                continue;
            }
        };
        // Only the host reaches this port; a connection from inside the
        // guest is closed unanswered.
        if peer.cid() != VMADDR_CID_HOST {
            continue;
        }
        // Serve each connection concurrently so long-running streaming Venice
        // requests never block Tempo wallet refreshes or other chats.
        let runtime = Arc::clone(&runtime);
        let network = Arc::clone(&network);
        std::thread::spawn(move || {
            let started = Instant::now();
            match cloak_sender::serve(&runtime, &network, stream) {
                Ok((name, outcome)) => eprintln!(
                    "cloak-sender: {name} {outcome} in {:.2} s",
                    started.elapsed().as_secs_f64()
                ),
                Err(error) => eprintln!("cloak-sender: connection failed: {error}"),
            }
        });
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> std::process::ExitCode {
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Instant;

    let mut args = std::env::args().skip(1);
    let socket_path = match (args.next().as_deref(), args.next()) {
        (Some("--unix"), Some(path)) if args.next().is_none() => PathBuf::from(path),
        _ => {
            eprintln!("usage: cloak-sender --unix <socket-path>");
            return std::process::ExitCode::from(2);
        }
    };

    let _ = std::fs::remove_file(&socket_path);
    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("cloak-sender: cannot listen on {}: {error}", socket_path.display());
            return std::process::ExitCode::FAILURE;
        }
    };
    if let Err(error) = std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600)) {
        eprintln!("cloak-sender: cannot secure socket: {error}");
        let _ = std::fs::remove_file(&socket_path);
        return std::process::ExitCode::FAILURE;
    }

    // Exit cleanly if the parent app closes our stdin pipe so the helper can
    // never orphan after an unexpected app exit.
    let cleanup_path = socket_path.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 64];
        let mut stdin = std::io::stdin();
        while let Ok(n) = stdin.read(&mut buf) {
            if n == 0 {
                break;
            }
        }
        let _ = std::fs::remove_file(&cleanup_path);
        std::process::exit(0);
    });

    let runtime = Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("runtime"),
    );
    let network = Arc::new(cloak_sender::Network::direct());
    println!("ready");
    let _ = std::io::stdout().flush();

    loop {
        let (stream, _) = match listener.accept() {
            Ok(accepted) => accepted,
            Err(error) => {
                eprintln!("cloak-sender: accept failed: {error}");
                continue;
            }
        };
        let runtime = Arc::clone(&runtime);
        let network = Arc::clone(&network);
        std::thread::spawn(move || {
            let started = Instant::now();
            match cloak_sender::serve(&runtime, &network, stream) {
                Ok((name, outcome)) => eprintln!(
                    "cloak-sender: {name} {outcome} in {:.2} s",
                    started.elapsed().as_secs_f64()
                ),
                Err(error) => eprintln!("cloak-sender: connection failed: {error}"),
            }
        });
    }
}
