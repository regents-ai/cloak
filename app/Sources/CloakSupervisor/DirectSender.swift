import CloakControl
import CloakHost
import Darwin
import Foundation
import os

/// Manages the pinned macOS host `cloak-sender` helper for optional direct
/// (no-Tor) Token Inference (Boundless + Tempo and Venice + Base).
///
/// The helper speaks the exact same framed binary protocol as the Linux
/// guest's `cloak-sender` (`Sender.exchange` / `Sender.stream`), over an
/// owner-only local Unix domain socket instead of vsock, and connects directly
/// over HTTPS without starting the Linux VM or Tor.
actor DirectSender {
    private let manifest: Manifest
    private let layout: Layout
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "direct-sender")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var socketPath: String?
    private var starting: Task<String, any Error>?

    init(manifest: Manifest, layout: Layout) {
        self.manifest = manifest
        self.layout = layout
    }

    /// Connects a POSIX `AF_UNIX` stream socket to the running direct helper,
    /// starting and SHA-256 verifying it lazily if needed.
    func connect() async throws -> Int32 {
        let path = try await ensureRunning()
        do {
            return try Self.connectUnix(path)
        } catch {
            // If the helper exited between our liveness check and connect(),
            // tear down stale state and retry once cleanly.
            if process?.isRunning != true {
                cleanUp()
                let freshPath = try await ensureRunning()
                return try Self.connectUnix(freshPath)
            }
            throw error
        }
    }

    /// Stops the direct helper process and removes its socket file.
    func stop() {
        starting?.cancel()
        starting = nil
        cleanUp()
    }

    private func ensureRunning() async throws -> String {
        if let proc = process, proc.isRunning, let path = socketPath {
            return path
        }
        cleanUp()
        if let starting {
            return try await starting.value
        }
        let task = Task<String, any Error> {
            try await self.launch()
        }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func launch() async throws -> String {
        guard let pin = manifest.pins.first(where: { $0.part == .sender }) else {
            throw Sender.Failure(description: "direct sender helper is not bundled in this build")
        }
        let helperURL = layout.url(pin)
        if case (_, let failure?) = await Checks.pinCheck(pin, at: helperURL) {
            throw Sender.Failure(description: "direct sender failed verification: \(failure.detail)")
        }

        let path = try prepareSocketPath()
        try? FileManager.default.removeItem(atPath: path)

        let proc = Process()
        proc.executableURL = helperURL
        proc.arguments = ["--unix", path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Forward stderr lines to os_log (cloak-sender logs request names & outcomes only, never secrets).
        let log = logger
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") where !line.isEmpty {
                    log.info("\(line, privacy: .public)")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            throw Sender.Failure(description: "cannot start direct sender: \(error.localizedDescription)")
        }

        let ready = await Self.waitForReady(stdout: stdout.fileHandleForReading, process: proc)
        guard ready else {
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate() }
            try? FileManager.default.removeItem(atPath: path)
            throw Sender.Failure(description: "direct sender exited before becoming ready")
        }

        self.process = proc
        self.stdinPipe = stdin
        self.socketPath = path
        logger.info("direct sender ready at \(path, privacy: .public)")
        return path
    }

    private func prepareSocketPath() throws -> String {
        let preferred = layout.directSenderSocket
        if preferred.path.utf8.count < 100 {
            try Places.makeOwnerOnly(preferred.deletingLastPathComponent())
            return preferred.path
        }
        let fallback = FileManager.default.temporaryDirectory
            .appending(path: "cloak-sender-\(getpid()).sock")
        return fallback.path
    }

    private func cleanUp() {
        if let stdinPipe {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if let process, process.isRunning {
            process.terminate()
        }
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        process = nil
        stdinPipe = nil
        socketPath = nil
    }

    private static func waitForReady(stdout: FileHandle, process: Process) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                let deadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deadline {
                    let chunk = stdout.availableData
                    if chunk.isEmpty {
                        continuation.resume(returning: false)
                        return
                    }
                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8),
                        text.split(separator: "\n").contains("ready")
                    {
                        continuation.resume(returning: true)
                        return
                    }
                }
                if process.isRunning { process.terminate() }
                continuation.resume(returning: false)
            }
        }
    }

    private static func connectUnix(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Sender.Failure(description: "cannot create unix socket (errno \(errno))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = path.utf8CString
        guard utf8.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw Sender.Failure(description: "direct sender socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: utf8.count) { dst in
                _ = utf8.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress!, utf8.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw Sender.Failure(description: "cannot connect to direct sender (errno \(err))")
        }
        return fd
    }
}
