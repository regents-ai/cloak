import CloakControl
import CloakHost
import Foundation

/// The startup check: one harmless rewrite, sent by the daemon's own rewrite
/// code in the guest (guest/check) through the guest adapter and the relay
/// to the worker, read from the guest's console. The guest prints one JSON
/// result per case, then "cloak-guest: check exited <status>", runs its
/// agent cases (there are none here) and powers off.
final class Verification: Sendable {
    /// The one case, as tests/test_guest_path.py writes cases: a plain
    /// request the model rewrites cleanly.
    static let cases = Data(#"{"name":"startup","body":{"model":"target","messages":[{"role":"user","content":"Hey, could you please tell me the three biggest rivers in Europe? Thanks!!"}]},"cancel_after_ms":0}"#.utf8 + [0x0a])
    /// How long the guest has to boot and finish the check.
    static let limit: Duration = .seconds(300)

    private enum Event: Sendable {
        case output(Data)
        case ended(Guest.End)
        case timedOut
    }

    private struct CaseResult: Decodable {
        let name: String
        let outcome: String
        let error: String?
        let texts: [String]?
        let seconds: Double
    }

    /// The guest's console: its write end goes to the guest.
    let console = Pipe()
    private let events: AsyncStream<Event>
    private let feed: AsyncStream<Event>.Continuation

    init() {
        (events, feed) = AsyncStream.makeStream(of: Event.self)
        console.fileHandleForReading.readabilityHandler = { [feed] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                feed.yield(.output(data))
            }
        }
    }

    /// Called once if the guest ends on its own.
    func ended(_ end: Guest.End) {
        feed.yield(.ended(end))
    }

    /// The check's technical detail once it has passed. Throws the failure
    /// once it has failed, the guest has ended first, or `limit` has passed,
    /// and CancellationError when cancelled.
    func passed() async throws -> String {
        let limit = Task { [feed] in
            guard (try? await Task.sleep(for: Self.limit)) != nil else { return }
            feed.yield(.timedOut)
        }
        defer { limit.cancel() }
        var pending = Data()
        var result: CaseResult?
        var lastNote = "nothing"
        for await event in events {
            switch event {
            case .output(let data):
                pending += data
                while let end = pending.firstIndex(of: 0x0a) {
                    let line = String(decoding: pending[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    pending.removeSubrange(...end)
                    if line.hasPrefix("{"), let found = try? JSONDecoder().decode(CaseResult.self, from: Data(line.utf8)) {
                        result = found
                    } else if let status = line.wholeMatch(of: /cloak-guest: check exited (\d+)/)?.1 {
                        guard status == "0", let result, result.outcome == "rewritten", !(result.texts ?? []).isEmpty else {
                            throw Failure(.checkFailed, "the check exited \(status) with \(result.map { "\($0.outcome) \($0.error ?? "")" } ?? "no result")")
                        }
                        return "the startup check's rewrite went through the guest, the daemon and the worker in \(String(format: "%.2f", result.seconds)) s"
                    } else if line.hasPrefix("cloak-guest: ") {
                        lastNote = line
                    }
                }
            case .ended(.poweredOff):
                throw Failure(.checkFailed, "the guest powered off before its check finished; its last note: \(lastNote)")
            case .ended(.failed(let error)):
                throw Failure(.guestFailed, "the guest stopped: \(error)")
            case .timedOut:
                throw Failure(.checkFailed, "the check did not finish within \(Self.limit.components.seconds) seconds")
            }
        }
        throw CancellationError()
    }

    /// Stops reading the console, once the guest no longer writes to it.
    func close() {
        console.fileHandleForReading.readabilityHandler = nil
        feed.finish()
        try? console.fileHandleForReading.close()
        try? console.fileHandleForWriting.close()
    }
}
