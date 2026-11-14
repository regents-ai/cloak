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
    /// it to be kept, then answers `answer`. Returns the requests it read.
    final class StandIn: @unchecked Sendable {
        let reports: [Data]
        let answer: Data?
        private let lock = NSLock()
        private var requests = [[String: Any]]()

        init(reports: [Data] = [], answer: Data?) {
            self.reports = reports
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
            if let answer { write(handle, "A", answer) }
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

    static let conversation = Conversation(turns: [
        Turn(original: "Um, what colour is calm?", reworded: "Name a calm colour.", answer: "Sage green."),
        Turn(original: "never mind this one", reworded: "Skip this."),
        Turn(original: "and a goldfish name pls", reworded: "Suggest a goldfish name."),
    ])

    @Test func aSendCarriesOnlyTheRewordedTurnsAndTheDepositIsKeptSealed() async throws {
        defer { remove() }
        let standIn = StandIn(reports: [Self.deposit], answer: Self.ok(#"{"answer":"Bubbles."}"#))
        let turn = Self.conversation.turns[2].id
        let identity = String(repeating: "ab", count: 32)
        let answer = try await Remote.send(
            turn, in: Self.conversation, model: "cheap", identity: identity,
            key: { Self.walletKey }, deposits: deposits, exchange: standIn.exchange)
        #expect(answer == "Bubbles.")

        let request = try #require(standIn.read.first)
        #expect(request["op"] as? String == "send")
        #expect(request["model"] as? String == "cheap")
        #expect(request["identity"] as? String == identity)
        #expect(request["key"] as? String == "0x" + String(repeating: "11", count: 32))
        #expect(request["deposit"] is NSNull)
        #expect(request["messages"] as? [[String: String]] == [
            ["role": "user", "content": "Name a calm colour."],
            ["role": "assistant", "content": "Sage green."],
            ["role": "user", "content": "Suggest a goldfish name."],
        ])

        #expect(try deposits.load() == Self.deposit)
        let sealed = try Data(contentsOf: deposits.file)
        #expect(sealed.range(of: Data("channelId".utf8)) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: deposits.file.path)[.posixPermissions] as? Int == 0o600)

        // The next request carries the deposit kept by the time its turn came.
        let next = StandIn(answer: Self.ok(#"{"answer":"Goldie."}"#))
        _ = try await Remote.send(
            turn, in: Self.conversation, model: "cheap", identity: identity,
            key: { Self.walletKey }, deposits: deposits, exchange: next.exchange)
        let carried = try #require(next.read.first?["deposit"] as? [String: Any])
        #expect(carried["channelId"] as? String == "0x01")
    }

    @Test func eachStopComesBackWithItsCode() async throws {
        defer { remove() }
        for code in ["no_funds", "wallet_refused", "model_unavailable", "tor_down", "answer_refused", "failed"] {
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
        let standIn = StandIn(answer: Self.ok(#"{"answer":"unused"}"#))
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

    @Test func answersAreSealedWithTheirConversation() throws {
        defer { remove() }
        let store = ConversationStore(folder: folder.appending(path: "conversations"), key: key)
        try store.save(Self.conversation)
        let sealed = try Data(contentsOf: folder.appending(path: "conversations/\(Self.conversation.id.uuidString).conversation"))
        #expect(sealed.range(of: Data("Sage".utf8)) == nil)
        #expect(try store.load() == [.conversation(Self.conversation)])
    }
}
