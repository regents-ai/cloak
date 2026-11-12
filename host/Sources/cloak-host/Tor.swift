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
    /// tor's SOCKS port on 127.0.0.1.
    let port: UInt16
    private let folder: URL
    private let process: Process

    /// Starts tor and returns once its SOCKS port listens, without waiting
    /// for it to reach the Tor network. This host is its owning process: a
    /// host that dies without stopping it ends it within about 15 seconds,
    /// leaving its folder behind.
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
        var lines = Lines(output: output.fileHandleForReading)
        guard let port = lines.untilReady() else {
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
            throw TorError(description: "it exited before its SOCKS port opened")
        }
        self.port = port
        Thread { [lines] in
            var rest = lines
            rest.forward()
        }.start()
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
    mutating func untilReady() -> UInt16? {
        let ready = "Opened Socks listener connection (ready) on 127.0.0.1:"
        while let line = next() {
            if let at = line.range(of: ready), let port = UInt16(line[at.upperBound...]) { return port }
        }
        return nil
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
