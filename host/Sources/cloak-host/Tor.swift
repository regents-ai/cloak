import Foundation
import os

/// tor, the Tor Project's own program (Decision 5 in docs/plan.md), as this
/// host's child: the guest's one way out, through `TorRelay`. Its settings
/// are the reference's (reference/wrapper/torrc) given on its command line,
/// with no configuration file. Its SOCKS port is on the Mac's loopback, as
/// the reference's is on its own, but on a free port tor picks, so it never
/// meets another tor on the Mac. (On a socket file tor answers each SOCKS
/// request in a longer form that torsocks misreads, which puts stray bytes
/// in front of every stream.) All of its state (the directory cache, the
/// entry guards it chose, its state file) lives in one lasting folder,
/// `data`, and stays there from one run to the next, so tor keeps its entry
/// guards, as the Tor Project recommends, and a later start bootstraps from
/// what it saved. tor locks that folder while it runs: a second tor given it
/// exits about 5 seconds after opening its port, as after any other exit.
/// Its log lines go to this process's standard error. It is never
/// restarted: once it has stopped, nothing more is connected to its port,
/// which another program may then take, so every Tor connection from the
/// guest fails.
final class Tor: Sendable {
    /// How long, from its start, tor has to open its SOCKS port and
    /// bootstrap. tor itself never gives up. 90 s is the default of the Tor
    /// Project's own controller library, stem, whose `launch_tor` waits for
    /// the same line in tor's output; it says a tor with no saved state, as
    /// this one is on its first start, usually bootstraps "in 50 seconds or
    /// so". Here a first start took 7 to 10 s, and a second, reusing the
    /// state saved in `data`, 2.4 s.
    static let bootstrapLimit = 90
    /// tor's own line once it can build circuits; before it, tor refuses
    /// every request.
    static let bootstrapped = "[notice] Bootstrapped 100% (done)"

    /// tor's SOCKS port on 127.0.0.1.
    private let port: UInt16
    private let process: Process
    /// The guest sockets of the Tor relay's connections to tor's SOCKS port;
    /// nil once tor has stopped.
    private let relayed: OSAllocatedUnfairLock<Set<Int32>?>

    /// Starts tor on its lasting folder `data`, made owner-only if it does
    /// not exist, and returns once tor has bootstrapped, so that no task
    /// starts before tor can carry it, or once it is unavailable: exited, or
    /// stopped here at `bootstrapLimit`. Either way every Tor connection from
    /// the guest then fails, as after any later exit. Throws, with tor
    /// stopped, when its SOCKS port never opened: tor exited first, or was
    /// stopped at `bootstrapLimit`. This host is its owning process: a host
    /// that dies without stopping it ends it within about 15 seconds.
    init(executable: URL, data: URL) throws {
        // Never written: tor reads no configuration file.
        let absent = data.appending(path: "torrc").path
        process = Process()
        process.executableURL = executable
        process.arguments = [
            "--defaults-torrc", absent, "--ignore-missing-torrc", "-f", absent,
            "--SocksPort", "127.0.0.1:auto IsolateSOCKSAuth",
            "--DataDirectory", data.path,
            "--Log", "notice stdout",
            "--__OwningControllerProcess", String(getpid()),
        ]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Once tor has stopped, its port may be another program's: nothing
        // more is connected to it, and the relayed connections still open
        // are shut.
        let relayed = OSAllocatedUnfairLock<Set<Int32>?>(initialState: [])
        let stopped: @Sendable () -> Void = {
            relayed.withLock { guests in
                for guest in guests ?? [] { shutdown(guest, SHUT_RDWR) }
                guests = nil
            }
        }
        self.relayed = relayed
        process.terminationHandler = {
            log("tor exited with status \($0.terminationStatus)")
            stopped()
        }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try process.run()
        // One limit for the whole start, the SOCKS port and the bootstrap,
        // and one wait: tor's output is read on its own thread throughout.
        let limit = DispatchTime.now() + .seconds(Self.bootstrapLimit)
        let listening = OSAllocatedUnfairLock<UInt16?>(initialState: nil)
        let started = DispatchSemaphore(value: 0)
        Thread { [lines = Lines(output: output.fileHandleForReading)] in
            var lines = lines
            let port = lines.untilListening()
            listening.withLock { $0 = port }
            lines.untilBootstrapped()
            started.signal()
            lines.forward()
        }.start()
        let timedOut = started.wait(timeout: limit) == .timedOut
        if timedOut {
            stopped()
            process.terminate()
        }
        guard let port = listening.withLock({ $0 }) else {
            process.waitUntilExit()
            throw TorError(description: timedOut
                ? "its SOCKS port did not open within \(Self.bootstrapLimit) seconds; stopped it"
                : "it exited before its SOCKS port opened")
        }
        self.port = port
        if timedOut {
            log("tor did not bootstrap within \(Self.bootstrapLimit) seconds; stopped it, so every Tor connection fails")
        }
    }

    /// Connects the Tor relay's connection from `guest` to tor's SOCKS port:
    /// the socket, or nil once tor has stopped, whose port may then be
    /// another program's, or when tor cannot be reached. Until
    /// `disconnect(guest)`, tor stopping shuts `guest` down.
    func connect(_ guest: Int32) -> Int32? {
        relayed.withLock { guests in
            guard guests != nil else {
                log("cannot reach tor (it has stopped); closed a Tor port connection without an answer")
                return nil
            }
            let socks = socket(AF_INET, SOCK_STREAM, 0)
            guard socks >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socks, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else {
                log("cannot reach tor (\(String(cString: strerror(errno)))); closed a Tor port connection without an answer")
                close(socks)
                return nil
            }
            guests?.insert(guest)
            return socks
        }
    }

    /// Ends what `connect` began for `guest`; called before `guest` closes.
    func disconnect(_ guest: Int32) {
        relayed.withLock { _ = $0?.remove(guest) }
    }

    /// Stops tor. Its folder, with its state, stays for its next start.
    func stop() {
        process.terminate()
        process.waitUntilExit()
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
