import Foundation

/// tor, the Tor Project's own program (Decision 5 in docs/plan.md), as this
/// host's child: the guest's one way out, through `TorRelay`. Its settings
/// are the reference's (reference/wrapper/torrc) given on its command line,
/// with no configuration file. Its SOCKS port is on the Mac's loopback, as
/// the reference's is on its own, but on a free port tor picks, so it never
/// meets another tor on the Mac. (On a socket file tor answers each SOCKS
/// request in a longer form that torsocks misreads, which puts stray bytes
/// in front of every stream.) All of its state (the directory cache, the
/// guard it chose) lives in a private folder of its own and goes with it, so
/// nothing passes from one guest to the next. Its log lines go to this
/// process's standard error. It is never restarted: once it has stopped,
/// every Tor connection from the guest fails.
final class Tor: Sendable {
    /// How long, from its start, tor has to bootstrap. tor itself never gives
    /// up. 90 s is the default of the Tor Project's own controller library,
    /// stem, whose `launch_tor` waits for the same line in tor's output; it
    /// says a tor with no saved state, as this one always is, usually
    /// bootstraps "in 50 seconds or so". Here it took 7 to 9 s.
    static let bootstrapLimit = 90
    /// tor's own line once it can build circuits; before it, tor refuses
    /// every request.
    static let bootstrapped = "[notice] Bootstrapped 100% (done)"

    /// tor's SOCKS port on 127.0.0.1.
    let port: UInt16
    private let folder: URL
    private let process: Process

    /// Starts tor and returns once it has bootstrapped, so that no task
    /// starts before tor can carry it, or once it is unavailable: exited, or
    /// stopped here at `bootstrapLimit`. Either way every Tor connection from
    /// the guest then fails, as after any later exit. This host is its
    /// owning process: a host that dies without stopping it ends it within
    /// about 15 seconds, leaving its folder behind.
    init(executable: URL) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "cloak-tor-\(String(decoding: hex(randomBytes(8)), as: UTF8.self))")
        // Never written: tor reads no configuration file.
        let absent = folder.appending(path: "torrc").path
        process = Process()
        process.executableURL = executable
        process.arguments = [
            "--defaults-torrc", absent, "--ignore-missing-torrc", "-f", absent,
            "--SocksPort", "127.0.0.1:auto IsolateSOCKSAuth",
            "--DataDirectory", folder.appending(path: "data").path,
            "--Log", "notice stdout",
            "--__OwningControllerProcess", String(getpid()),
        ]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.terminationHandler = { log("tor exited with status \($0.terminationStatus)") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let limit = DispatchTime.now() + .seconds(Self.bootstrapLimit)
        var lines = Lines(output: output.fileHandleForReading)
        guard let port = lines.untilListening() else {
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
            throw TorError(description: "it exited before its SOCKS port opened")
        }
        self.port = port
        let done = DispatchSemaphore(value: 0)
        Thread { [lines] in
            var rest = lines
            rest.untilBootstrapped()
            done.signal()
            rest.forward()
        }.start()
        if done.wait(timeout: limit) == .timedOut {
            log("tor did not bootstrap within \(Self.bootstrapLimit) seconds; stopped it, so every Tor connection fails")
            process.terminate()
        }
    }

    /// Stops tor and removes its folder, with its state.
    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// tor's output, copied line by line to standard error.
private struct Lines: Sendable {
    let output: FileHandle
    private var pending = Data()

    init(output: FileHandle) {
        self.output = output
    }

    /// Copies lines until the one that says the SOCKS port listens, and
    /// returns that port; nil if tor's output ends first.
    mutating func untilListening() -> UInt16? {
        let listening = "Opened Socks listener connection (ready) on 127.0.0.1:"
        while let line = next() {
            if let at = line.range(of: listening), let port = UInt16(line[at.upperBound...]) { return port }
        }
        return nil
    }

    /// Copies lines until the one that says tor has bootstrapped, or until
    /// tor's output ends.
    mutating func untilBootstrapped() {
        while let line = next(), !line.contains(Tor.bootstrapped) {}
    }

    /// Copies the rest, until tor exits.
    mutating func forward() {
        while next() != nil {}
    }

    private mutating func next() -> String? {
        while true {
            if let end = pending.firstIndex(of: 0x0a) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                log("tor: \(line)")
                return line
            }
            // availableData returns what has arrived, and nothing at the end.
            let block = output.availableData
            if block.isEmpty { return nil }
            pending += block
        }
    }
}

struct TorError: Error, CustomStringConvertible {
    let description: String
}
