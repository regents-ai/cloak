import Foundation
import Synchronization

/// The native worker as a child process, spoken to in frames over its
/// standard input and output (see worker/Sources/cloak-rewriter/Frames.swift).
/// One request at a time. The first fault marks the worker lost and stops it:
/// the host never restarts it, and every later request fails.
final class WorkerChannel: Sendable {
    /// The largest answer accepted. The worker's 16,384-token limit keeps real
    /// answers far below it; a larger one means the worker is broken. Answers
    /// over the daemon's own reply limit still pass, so the daemon refuses them.
    static let maxAnswer = 16 << 20

    private struct State {
        var inFlight = false
        var lost = false
    }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let state = Mutex(State())

    init(executable: URL, arguments: [String]) throws {
        let toWorker = Pipe(), fromWorker = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = toWorker
        process.standardOutput = fromWorker
        try process.run()
        input = toWorker.fileHandleForWriting
        output = fromWorker.fileHandleForReading
    }

    func waitUntilReady() -> Bool {
        guard let (kind, payload) = readFrame(), kind == 0x59, payload.isEmpty else {
            markLost()
            return false
        }
        return true
    }

    /// The worker's answer (status and body), or nil when the worker is lost.
    func relay(_ request: Data) -> Data? {
        guard !state.withLock(\.lost) else { return nil }
        do {
            try input.write(contentsOf: Self.frame(0x52, request))
        } catch {
            markLost()
            return nil
        }
        state.withLock { $0.inFlight = true }
        defer { state.withLock { $0.inFlight = false } }
        guard let (kind, payload) = readFrame(), kind == 0x41, payload.count >= 2 else {
            markLost()
            return nil
        }
        return payload
    }

    /// Asks the worker to stop the request in progress, once.
    func cancel() {
        state.withLock { state in
            guard state.inFlight, !state.lost else { return }
            state.inFlight = false
            try? input.write(contentsOf: Self.frame(0x43, Data()))
        }
    }

    /// Ends a healthy worker by closing its input, and waits for it.
    func finish() {
        try? input.close()
        process.waitUntilExit()
    }

    private func markLost() {
        state.withLock { $0.lost = true }
        process.terminate()
    }

    private func readFrame() -> (UInt8, Data)? {
        guard let header = readExactly(5) else { return nil }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxAnswer, let payload = readExactly(length) else { return nil }
        return (header[header.startIndex], payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let block = try? output.read(upToCount: count - data.count), !block.isEmpty else { return nil }
            data += block
        }
        return data
    }

    static func frame(_ kind: UInt8, _ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([kind, UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + payload
    }
}
