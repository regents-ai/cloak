import CloakHost
import Foundation
import Observation

/// The one way to the payer in the guest, and its one queue
/// (docs/zkapi-mac-side.md, section 1). The payer gives chat requests their
/// turns first in, first out, so the order is made here: one chat request
/// is out at a time, and the next leaves only when the last has its answer
/// or was cancelled. Every waiting `owner` request (Chat's Send) goes
/// before any waiting `door` request (an agent task started in a V chat, or
/// another app's request through the door), each rank in the order it came. A request being sent is never
/// cancelled to make room, since one cut after its key was asked for may be
/// charged. Each press is its own request: two presses send two. A request
/// cancelled while it waits leaves the queue, and one cancelled while it is
/// out closes its connection, which the payer takes as its cancel. Calls to
/// the money routes (`call`) and reads of the deposit (`view`) never wait
/// in it.
@MainActor
@Observable
public final class PayQueue {
    public enum Rank: Sendable, Equatable {
        case owner
        case door
    }

    private struct Waiter {
        let id: UUID
        let rank: Rank
        let go: CheckedContinuation<Void, Never>
    }

    /// The chat requests waiting for their turn, in the order they came.
    private var waiters: [Waiter] = []
    /// The chat request out now.
    private var out: UUID?
    /// The request out is held behind an earlier settlement.
    public private(set) var held = false
    @ObservationIgnored private let line: PayLine
    /// How long a held request may wait: `PayLimit.hold`, shorter only in
    /// checks.
    @ObservationIgnored private let hold: Duration

    public init(line: @escaping PayLine, hold: Duration = PayLimit.hold) {
        self.line = line
        self.hold = hold
    }

    /// A chat request is out.
    public var sending: Bool { out != nil }

    /// How many chat requests wait for their turn.
    public var waiting: Int { waiters.count }

    // MARK: Chat requests

    /// Sends `body`, a chat request in OpenAI's shape with every user
    /// message reworded already, as `identity`, in its turn. Returns the
    /// provider's completion, as it gave it.
    public func complete(_ body: Data, identity: String, rank: Rank) async throws(PayStop) -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(PayFrame.Request(identity: identity, body: String(decoding: body, as: UTF8.self)))
        } catch {
            throw PayStop(.failed, "cannot build the request: \(error)")
        }
        let id = UUID()
        try await turn(id, rank)
        defer { finish(id) }
        guard !Task.isCancelled else { throw PayStop(.cancelled, "cancelled before sending") }
        let answer = try await exchange(.request, payload, limit: PayLimit.answer)
        guard answer.status == 200 else { throw PayStop(status: answer.status, body: answer.body) }
        return Data(answer.body.utf8)
    }

    /// Waits for `id`'s turn; leaves the queue, and throws, when cancelled
    /// first.
    private func turn(_ id: UUID, _ rank: Rank) async throws(PayStop) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { go in
                waiters.append(Waiter(id: id, rank: rank, go: go))
                advance()
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
        guard out == id else { throw PayStop(.cancelled, "cancelled while waiting for its turn") }
    }

    private func leave(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).go.resume()
    }

    /// Gives the turn, when none is out: to the first owner's request, or
    /// else to the first door's.
    private func advance() {
        guard out == nil, let index = waiters.firstIndex(where: { $0.rank == .owner }) ?? waiters.indices.first else { return }
        let next = waiters.remove(at: index)
        out = next.id
        next.go.resume()
    }

    private func finish(_ id: UUID) {
        guard out == id else { return }
        out = nil
        held = false
        advance()
    }

    // MARK: Calls and reads

    /// Calls one of the payer's money routes, its body JSON or none, within
    /// `limit`. Returns the route's answer; a status outside 200 to 299
    /// throws.
    public func call(_ method: String, _ path: String, body: Data? = nil, limit: Duration = PayLimit.read) async throws(PayStop) -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                PayFrame.Call(method: method, path: path, body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
        } catch {
            throw PayStop(.failed, "cannot build the call: \(error)")
        }
        let answer = try await exchange(.call, payload, limit: limit)
        guard (200..<300).contains(answer.status) else {
            let reason = Self.answerDetail(answer.body).map { ": \($0)" } ?? ""
            throw PayStop(.failed, "\(method) \(path) answered \(answer.status)\(reason)")
        }
        return Data(answer.body.utf8)
    }

    /// Reads the deposit, and with `chain` the chain at one block.
    public func view(chain: Bool) async throws(PayStop) -> DepositView {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(PayFrame.View(chain: chain))
        } catch {
            throw PayStop(.failed, "cannot build the read: \(error)")
        }
        let answer = try await exchange(.view, payload, limit: PayLimit.read)
        guard answer.status == 200 else {
            let reason = Self.answerDetail(answer.body).map { ": \($0)" } ?? ""
            throw PayStop(.failed, "the read answered \(answer.status)\(reason)")
        }
        do {
            return try JSONDecoder.pay.decode(DepositView.self, from: Data(answer.body.utf8))
        } catch {
            throw PayStop(.failed, "the read did not read: \(error)")
        }
    }

    /// Extracts a short, safe error string from a payer admin/view error body
    /// (`{"error": "..."}` or `{"error": {"message": "..."}}`) for logging.
    private static func answerDetail(_ body: String) -> String? {
        struct Flat: Decodable { let error: String }
        struct Nested: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner
        }
        let data = Data(body.utf8)
        let raw = (try? JSONDecoder().decode(Flat.self, from: data))?.error
            ?? (try? JSONDecoder().decode(Nested.self, from: data))?.error.message
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 160 ? String(cleaned.prefix(160)) + "…" : cleaned
    }

    // MARK: One exchange

    /// What has happened to a chat request's hold.
    private enum Hold {
        case none
        case held
        case over
    }

    /// One frame to the payer and its answer. A chat request may run for
    /// `limit` from its frame; from an `H` that holds it, for `hold`; and
    /// from the `H` that ends the hold, for `limit` again. When a limit runs out, or the caller is cancelled, the
    /// connection closes.
    private func exchange(_ ask: Pay.Ask, _ payload: Data, limit: Duration) async throws(PayStop) -> PayFrame.Answer {
        guard !Task.isCancelled else { throw PayStop(.cancelled, "cancelled") }
        let events: AsyncThrowingStream<Pay.Event, any Error>
        do {
            events = try await line(ask, payload)
        } catch {
            throw PayStop(.unreachable, "\(error)")
        }
        let watch = Watch()
        let hold = self.hold
        let reader = Task { () throws -> Data in
            for try await event in events {
                switch event {
                case .held(let data):
                    guard let frame = try? JSONDecoder().decode(PayFrame.Held.self, from: data) else {
                        throw PayStop(.failed, "an H frame did not read")
                    }
                    if ask == .request { held = frame.held }
                    watch.arm(frame.held ? .held : .over, for: frame.held ? hold : limit)
                case .answer(let data):
                    return data
                }
            }
            throw PayStop(.ended, "the payer closed before answering")
        }
        watch.reader = reader
        watch.arm(.none, for: limit)
        let result = await withTaskCancellationHandler {
            await reader.result
        } onCancel: {
            reader.cancel()
        }
        watch.stop()
        switch result {
        case .success(let data):
            guard let answer = try? JSONDecoder().decode(PayFrame.Answer.self, from: data) else {
                throw PayStop(.failed, "the answer frame did not read")
            }
            return answer
        case .failure(let error):
            if let ran = watch.ranOut {
                throw ran == .held
                    ? PayStop(.heldTooLong, "held past \(hold)") : PayStop(.timedOut, "no answer within the limit")
            }
            if Task.isCancelled { throw PayStop(.cancelled, "cancelled") }
            if let stop = error as? PayStop {
                // Nothing was sent while the hold lasted.
                if watch.hold == .held, stop.code == .ended {
                    throw PayStop(.unreachable, "the payer went away during the hold")
                }
                throw stop
            }
            if watch.hold == .held { throw PayStop(.unreachable, "the payer went away during the hold") }
            throw PayStop(.ended, "\(error)")
        }
    }

    /// One exchange's time limit: armed again at each change of its hold,
    /// and ending the exchange's reader when it runs out.
    @MainActor
    private final class Watch {
        var reader: Task<Data, any Error>?
        private(set) var hold = Hold.none
        /// The hold's state when its limit ran out.
        private(set) var ranOut: Hold?
        private var timer: Task<Void, Never>?

        func arm(_ hold: Hold, for duration: Duration) {
            timer?.cancel()
            self.hold = hold
            timer = Task { [weak self] in
                guard (try? await Task.sleep(for: duration)) != nil, let self else { return }
                ranOut = hold
                reader?.cancel()
            }
        }

        func stop() {
            timer?.cancel()
        }
    }
}
