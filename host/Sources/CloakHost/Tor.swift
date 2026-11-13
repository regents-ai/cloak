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
public final class Tor: Sendable {
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
    static let bootstrappedLine = "[notice] Bootstrapped 100% (done)"

    /// False when tor did not bootstrap within `bootstrapLimit` (it was
    /// stopped then) or exited before it did: every Tor connection fails.
    public let bootstrapped: Bool
    /// tor's SOCKS port on 127.0.0.1.
    private let port: UInt16
    private let child: Child
    /// The guest sockets of the Tor relay's connections to tor's SOCKS port;
    /// nil once tor has stopped.
    private let relayed: OSAllocatedUnfairLock<Set<Int32>?>

    private init(port: UInt16, bootstrapped: Bool, child: Child, relayed: OSAllocatedUnfairLock<Set<Int32>?>) {
        self.port = port
        self.bootstrapped = bootstrapped
        self.child = child
        self.relayed = relayed
    }

    /// Starts tor on its lasting folder `data`, made owner-only if it does
    /// not exist, and returns once tor has bootstrapped, so that no task
    /// starts before tor can carry it, or once it is unavailable: exited, or
    /// stopped here at `bootstrapLimit`. Either way every Tor connection from
    /// the guest then fails, as after any later exit. Throws, with tor
    /// stopped, when its SOCKS port never opened: tor exited first, or was
    /// stopped at `bootstrapLimit`. This process is its owning process: one
    /// that dies without stopping it ends it within about 15 seconds.
    public static func start(executable: URL, data: URL) async throws -> Tor {
        // Never written: tor reads no configuration file.
        let absent = data.appending(path: "torrc").path
        let process = Process()
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
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = try Child(process) {
            log("tor exited with status \($0.terminationStatus)")
            stopped()
        }
        // One limit for the whole start, the SOCKS port and the bootstrap,
        // and one wait: tor's output is read on its own thread throughout.
        // A start that is cancelled stops tor, which ends the wait.
        let pid = process.processIdentifier
        let (port, timedOut, bootstrapped) = try await withTaskCancellationHandler {
            try await onThread { () -> (UInt16?, Bool, Bool) in
                let limit = DispatchTime.now() + .seconds(Self.bootstrapLimit)
                let listening = OSAllocatedUnfairLock<UInt16?>(initialState: nil)
                let bootstrapped = OSAllocatedUnfairLock(initialState: false)
                let started = DispatchSemaphore(value: 0)
                Thread { [lines = Lines(output: output.fileHandleForReading)] in
                    var lines = lines
                    let port = lines.untilListening()
                    listening.withLock { $0 = port }
                    let done = lines.untilBootstrapped()
                    bootstrapped.withLock { $0 = done }
                    started.signal()
                    lines.forward()
                }.start()
                let timedOut = started.wait(timeout: limit) == .timedOut
                return (listening.withLock { $0 }, timedOut, !timedOut && bootstrapped.withLock { $0 })
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
        if timedOut {
            stopped()
            process.terminate()
        }
        guard let port else {
            await child.stopped("tor")
            throw TorError(description: timedOut
                ? "its SOCKS port did not open within \(Self.bootstrapLimit) seconds; stopped it"
                : "it exited before its SOCKS port opened")
        }
        if timedOut {
            log("tor did not bootstrap within \(Self.bootstrapLimit) seconds; stopped it, so every Tor connection fails")
        }
        return Tor(port: port, bootstrapped: bootstrapped, child: child, relayed: relayed)
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

    /// tor's process.
    public var processIdentifier: Int32 { child.process.processIdentifier }

    /// How tor ended, once it has, for whatever reason.
    public func exited() async -> Termination {
        await child.exited()
    }

    /// Stops tor and returns once it has exited, killed if it has not within
    /// `Child.exitLimit`. Its folder, with its state, stays for its next
    /// start.
    public func stop() async {
        child.process.terminate()
        await child.stopped("tor")
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

    /// Copies lines until the one that says tor has bootstrapped, and
    /// returns true, or until tor's output ends, and returns false.
    mutating func untilBootstrapped() -> Bool {
        while let line = next() {
            if line.contains(Tor.bootstrappedLine) { return true }
        }
        return false
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
