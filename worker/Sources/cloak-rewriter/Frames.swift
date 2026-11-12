import Foundation

/// Frames between the host supervisor and the worker, over the worker's
/// standard input and output: one kind byte, a 4-byte big-endian length, then
/// the payload.
///
/// In: `R` a request body, `C` cancel the request in progress.
/// Out: `Y` ready (empty), `A` an answer: 2-byte big-endian HTTP status, then
/// the reply body.
enum Frames {
    static let maxPayload = 1 << 20

    struct Incoming: Sendable {
        enum Kind: UInt8 { case request = 0x52, cancel = 0x43 }
        let kind: Kind
        let payload: Data
    }

    /// Frames go to a private copy of standard output, and standard output
    /// itself is pointed at standard error, so a library that prints cannot
    /// corrupt the channel.
    private static let output: FileHandle = {
        let channel = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        return FileHandle(fileDescriptor: channel, closeOnDealloc: true)
    }()

    static func claimOutput() { _ = output }

    static func ready() { write(kind: 0x59, payload: Data()) }

    static func answer(status: UInt16, body: Data) {
        write(kind: 0x41, payload: Data([UInt8(status >> 8), UInt8(status & 0xff)]) + body)
    }

    private static func write(kind: UInt8, payload: Data) {
        let length = UInt32(payload.count)
        let header = Data([kind, UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
        do {
            try output.write(contentsOf: header + payload)
        } catch {
            stop("supervisor channel closed")
        }
    }

    /// Reads frames on a thread of their own, so a cancel arrives while a
    /// rewrite runs. The stream ends when the supervisor closes the channel,
    /// and fails with a `ProtocolFault` at a frame the worker cannot take; no
    /// frame is read after either.
    static func incoming() -> AsyncThrowingStream<Incoming, any Error> {
        AsyncThrowingStream { continuation in
            Thread {
                do {
                    while let frame = try readFrame() { continuation.yield(frame) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }.start()
        }
    }

    private static func readFrame() throws(ProtocolFault) -> Incoming? {
        guard let header = try readExactly(5) else { return nil }
        guard let kind = Incoming.Kind(rawValue: header[0]) else { throw ProtocolFault("unknown frame kind") }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxPayload else { throw ProtocolFault("frame too large") }
        guard let payload = try readExactly(length) else { throw ProtocolFault("channel closed inside a frame") }
        return Incoming(kind: kind, payload: payload)
    }

    /// nil only at a clean end of input before the first byte.
    private static func readExactly(_ count: Int) throws(ProtocolFault) -> Data? {
        var data = Data()
        while data.count < count {
            guard let block = try? FileHandle.standardInput.read(upToCount: count - data.count), !block.isEmpty else {
                if data.isEmpty { return nil }
                throw ProtocolFault("channel closed inside a frame")
            }
            data += block
        }
        return data
    }
}

/// The supervisor broke the frame protocol. The worker stops for it, once
/// the rewrite in progress has stopped.
struct ProtocolFault: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
