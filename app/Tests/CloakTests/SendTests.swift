import CloakChat
import CloakHost
import CryptoKit
import Foundation
import Testing

/// Development mode's send path on the Mac, against a stand-in for the
/// guest's sender on the other end of a socket pair: the request built when
/// the turn comes, the deposit kept sealed before the sender goes on, the
/// answer back, and each way it stops. Test-only keys and folders; never the
/// keychain, never the network.
@Suite
struct SendTests {
    let folder = URL(filePath: "/tmp").appending(path: "cloak-send-\(UUID().uuidString.prefix(8))")
    let key = SymmetricKey(size: .bits256)
    static let walletKey = Data(repeating: 0x11, count: 32)
    static let deposit = Data(#"{"key":"scope","channelId":"0x01","cumulativeAmount":"0","deposit":"1000000","opened":true}"#.utf8)

    var deposits: DepositStore { DepositStore(folder: folder.appending(path: "wallet"), key: key) }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An exchange with a stand-in sender: it gives the turn, reads the
    /// request, reports each of `reports` as a deposit change and waits for
    /// it to be kept, then answers what `answer` gives for the request, or
    /// goes away on nil. Returns the requests it read.
    final class StandIn: @unchecked Sendable {
        let reports: [Data]
        let answer: @Sendable ([String: Any]) -> Data?
        private let lock = NSLock()
        private var requests = [[String: Any]]()

        init(reports: [Data] = [], answer: Data?) {
            self.reports = reports
            self.answer = { _ in answer }
        }

        init(answer: @escaping @Sendable ([String: Any]) -> Data?) {
            self.reports = []
            self.answer = answer
        }

        var read: [[String: Any]] { lock.withLock { requests } }

        var exchange: Exchange {
            { request, keep in
                var pair: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
                let other = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
                Thread { self.serve(other) }.start()
                return try await Sender.exchange(pair[0], request: request, keep: keep)
            }
        }

        private func serve(_ handle: FileHandle) {
            defer { try? handle.close() }
            write(handle, "Y", Data())
            guard let (kind, payload) = Self.frame(handle), kind == UInt8(ascii: "R"),
                let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { return }
            lock.withLock { requests.append(request) }
            for report in reports {
                write(handle, "S", report)
                guard let (kind, _) = Self.frame(handle), kind == UInt8(ascii: "K") else { return }
            }
            if let answer = answer(request) { write(handle, "A", answer) }
        }

        private func write(_ handle: FileHandle, _ kind: Character, _ payload: Data) {
            let length = UInt32(payload.count).bigEndian
            try? handle.write(contentsOf: Data([kind.asciiValue!]) + withUnsafeBytes(of: length) { Data($0) } + payload)
        }

        static func frame(_ handle: FileHandle) -> (UInt8, Data)? {
            guard let head = exactly(handle, 5) else { return nil }
            let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            guard let payload = length == 0 ? Data() : exactly(handle, length) else { return nil }
            return (head[head.startIndex], payload)
        }

        private static func exactly(_ handle: FileHandle, _ count: Int) -> Data? {
            var data = Data()
            while data.count < count {
                guard let more = try? handle.read(upToCount: count - data.count), !more.isEmpty else { return nil }
                data += more
            }
            return data
        }
    }

    static func ok(_ value: String) -> Data { Data(#"{"ok":\#(value)}"#.utf8) }

    /// The sender's answer to a send: the provider's completion, as text.
    static func completed(_ completion: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": ["completion": completion]])
    }

    /// A completion whose one choice says `content`.
    static func said(_ content: String, finish: String = "stop", more: String = "") -> String {
        #"{"id":"c1","object":"chat.completion","choices":[{"index":0,"finish_reason":"\#(finish)","message":{"role":"assistant","content":"\#(content)"\#(more)}}]}"#
    }

    static let conversation = Conversation(turns: [
        Turn(original: "Um, what colour is calm?", reworded: "Name a calm colour.", answer: "Sage green."),
        Turn(original: "never mind this one", reworded: "Skip this."),
        Turn(original: "and a goldfish name pls", reworded: "Suggest a goldfish name."),
    ])

    @Test func aSendCarriesOnlyTheRewordedTurnsAndTheDepositIsKeptSealed() async throws {
        defer { remove() }
        let standIn = StandIn(reports: [Self.deposit], answer: Self.completed(Self.said("Bubbles.")))
        let turn = Self.conversation.turns[2].id
        let identity = String(repeating: "ab", count: 32)
        let answer = try await Remote.send(
            turn, in: Self.conversation, model: "cheap", identity: identity,
            key: { Self.walletKey }, deposits: deposits, exchange: standIn.exchange)
        #expect(answer == "Bubbles.")

        let request = try #require(standIn.read.first)
        #expect(Set(request.keys) == ["op", "key", "deposit", "body", "identity"])
        #expect(request["op"] as? String == "send")
        #expect(request["identity"] as? String == identity)
        #expect(request["key"] as? String == "0x" + String(repeating: "11", count: 32))
        #expect(request["deposit"] is NSNull)
        let sent = try #require(request["body"] as? String)
        let body = try #require(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "stream"])
        #expect(body["model"] as? String == "cheap")
        #expect(body["stream"] as? Bool == false)
        #expect(body["messages"] as? [[String: String]] == [
            ["role": "user", "content": "Name a calm colour."],
            ["role": "assistant", "content": "Sage green."],
            ["role": "user", "content": "Suggest a goldfish name."],
        ])

        #expect(try deposits.load() == Self.deposit)
        let sealed = try Data(contentsOf: deposits.file)
        #expect(sealed.range(of: Data("channelId".utf8)) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: deposits.file.path)[.posixPermissions] as? Int == 0o600)

        // The next request carries the deposit kept by the time its turn came.
        let next = StandIn(answer: Self.completed(Self.said("Goldie.")))
        _ = try await Remote.send(
            turn, in: Self.conversation, model: "cheap", identity: identity,
            key: { Self.walletKey }, deposits: deposits, exchange: next.exchange)
        let carried = try #require(next.read.first?["deposit"] as? [String: Any])
        #expect(carried["channelId"] as? String == "0x01")
    }

    /// A message its owner chose to send as written goes as written, now or
    /// replayed later; the reworded ones around it go as reworded.
    @Test func aTurnGoingAsWrittenIsSentAsWrittenInItsPlace() async throws {
        defer { remove() }
        let conversation = Conversation(turns: [
            Turn(original: "Um, what colour is calm?", reworded: nil, answer: "Sage green."),
            Turn(original: "and a goldfish name pls", reworded: "Suggest a goldfish name.", answer: "Bubbles."),
            Turn(original: "now one for a cat", reworded: nil),
        ])
        let standIn = StandIn(answer: Self.completed(Self.said("Whiskers.")))
        let answer = try await Remote.send(
            conversation.turns[2].id, in: conversation, model: "cheap", identity: String(repeating: "ab", count: 32),
            key: { Self.walletKey }, deposits: deposits, exchange: standIn.exchange)
        #expect(answer == "Whiskers.")

        let sent = try #require(standIn.read.first?["body"] as? String)
        let body = try #require(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(body["messages"] as? [[String: String]] == [
            ["role": "user", "content": "Um, what colour is calm?"],
            ["role": "assistant", "content": "Sage green."],
            ["role": "user", "content": "Suggest a goldfish name."],
            ["role": "assistant", "content": "Bubbles."],
            ["role": "user", "content": "now one for a cat"],
        ])
    }

    @Test func eachStopComesBackWithItsCode() async throws {
        defer { remove() }
        for code in ["no_funds", "wallet_refused", "model_unavailable", "tor_down", "failed"] {
            let standIn = StandIn(answer: Data(#"{"stop":{"code":"\#(code)","detail":"made up"}}"#.utf8))
            let stop = await #expect(throws: RemoteStop.self) {
                try await Remote.send(
                    Self.conversation.turns[2].id, in: Self.conversation, model: "cheap",
                    identity: String(repeating: "ab", count: 32), key: { Self.walletKey }, deposits: deposits,
                    exchange: standIn.exchange)
            }
            #expect(stop?.code.rawValue == code)
        }
    }

    /// Chat shows only an answer that says something and finished by
    /// stopping or at its length.
    @Test func aCompletionWithoutAnAnswerIsRefused() async throws {
        defer { remove() }
        let cases: [(String, RemoteStop.Code?)] = [
            (Self.said("Bubbles."), nil),
            (Self.said("Bubbles.", finish: "length"), nil),
            (Self.said(" \\n "), .answerRefused),
            (Self.said("Bubbles.", finish: "content_filter"), .answerRefused),
            (Self.said("Bubbles.", more: #","refusal":"no""#), .answerRefused),
            (#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[]}}]}"#, .answerRefused),
            (#"{"choices":[]}"#, .failed),
            ("not json", .failed),
        ]
        for (completion, code) in cases {
            let standIn = StandIn(answer: Self.completed(completion))
            do {
                let answer = try await Remote.send(
                    Self.conversation.turns[2].id, in: Self.conversation, model: "cheap",
                    identity: String(repeating: "ab", count: 32), key: { Self.walletKey }, deposits: deposits,
                    exchange: standIn.exchange)
                #expect(code == nil && answer == "Bubbles.", "\(completion)")
            } catch {
                #expect(error.code == code, "\(completion)")
            }
        }
    }

    @Test func aSenderThatGoesAwayLeavesNothingKept() async throws {
        defer { remove() }
        let standIn = StandIn(answer: nil)
        let stop = await #expect(throws: RemoteStop.self) {
            try await Remote.send(
                Self.conversation.turns[2].id, in: Self.conversation, model: "cheap",
                identity: String(repeating: "ab", count: 32), key: { Self.walletKey }, deposits: deposits,
                exchange: standIn.exchange)
        }
        #expect(stop?.code == .unreachable)
        #expect(try deposits.load() == nil)
    }

    @Test func aKeyThatCannotBeReadSendsNothing() async throws {
        defer { remove() }
        struct Locked: Error {}
        let standIn = StandIn(answer: Self.completed(Self.said("unused")))
        let stop = await #expect(throws: RemoteStop.self) {
            try await Remote.send(
                Self.conversation.turns[2].id, in: Self.conversation, model: "cheap",
                identity: String(repeating: "ab", count: 32), key: { throw Locked() }, deposits: deposits,
                exchange: standIn.exchange)
        }
        #expect(stop?.code == .failed)
        #expect(standIn.read.isEmpty)
    }

    @Test func aDepositTheNetworkShowsClosedIsForgotten() async throws {
        defer { remove() }
        try deposits.keep(Self.deposit)
        let look = StandIn(answer: Self.ok(
            #"{"balance":"0","least":"1000000","setup":true,"models":[],"deposit":{"deposit":"0","spent":"5","closeRequestedAt":0,"gone":true}}"#))
        let seen = try await Remote.look(address: "0x01", deposits: deposits, exchange: look.exchange)
        #expect(seen.deposit?.gone == true)
        #expect(try deposits.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: deposits.file.path))
    }

    @Test func aDepositReportedGoneIsRemoved() throws {
        defer { remove() }
        try deposits.keep(Self.deposit)
        try deposits.keep(Data("null".utf8))
        #expect(try deposits.load() == nil)
        // Another key does not open it.
        try deposits.keep(Self.deposit)
        #expect(throws: (any Error).self) { try DepositStore(folder: deposits.file.deletingLastPathComponent(), key: SymmetricKey(size: .bits256)).load() }
    }

    @Test func aNewWalletIsKeptBeforeItsAddressComesBack() async throws {
        let made = StandIn(answer: Self.ok(#"{"key":"0x\#(String(repeating: "22", count: 32))","address":"0xabc"}"#))
        let kept = Kept()
        let address = try await Remote.create(exchange: made.exchange) { key, address in await kept.set(key, address) }
        #expect(address == "0xabc")
        #expect(await kept.value?.key == Data(repeating: 0x22, count: 32))
        #expect(await kept.value?.address == "0xabc")
    }

    actor Kept {
        var value: (key: Data, address: String)?
        func set(_ key: Data, _ address: String) { value = (key, address) }
    }

    /// A Venice answer the Mac stops reading closes the connection to the
    /// sender, which the sender takes as the end of the request: the
    /// stand-in, waiting on the socket after the head and one piece, finds
    /// it closed.
    @Test(.timeLimit(.minutes(1))) func aVeniceAnswerTheMacStopsReadingClosesItsConnection() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let other = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        let (closed, ended) = AsyncStream.makeStream(of: Bool.self)
        Thread {
            let frame = { (kind: Character, payload: String) in
                let length = UInt32(payload.utf8.count).bigEndian
                try? other.write(contentsOf: Data([kind.asciiValue!]) + withUnsafeBytes(of: length) { Data($0) } + Data(payload.utf8))
            }
            frame("Y", "")
            let request = StandIn.frame(other)
            frame("V", #"{"status":200,"headers":{"content-type":"text/event-stream"}}"#)
            frame("P", "data: {}\n\n")
            ended.yield(request?.0 == UInt8(ascii: "R") && StandIn.frame(other) == nil)
            ended.finish()
        }.start()

        var pieces = [Sender.Piece]()
        for try await piece in Sender.stream(pair[0], request: Data(#"{"op":"venice"}"#.utf8)) {
            pieces.append(piece)
            if case .body = piece { break }
        }

        #expect(pieces == [.head(status: 200, headers: ["content-type": "text/event-stream"]), .body(Data("data: {}\n\n".utf8))])
        #expect(await closed.first { _ in true } == true)
    }

    @Test func answersAreSealedWithTheirConversation() throws {
        defer { remove() }
        let store = ConversationStore(folder: folder.appending(path: "conversations"), key: key)
        try store.save(Self.conversation)
        let sealed = try Data(contentsOf: folder.appending(path: "conversations/\(Self.conversation.id.uuidString).conversation"))
        #expect(sealed.range(of: Data("Sage".utf8)) == nil)
        #expect(try store.load() == [.conversation(Self.conversation)])
    }
}
