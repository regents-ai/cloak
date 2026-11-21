import CloakControl
import CloakHost
import CryptoKit
import Foundation
import Security

// Token Inference (decisions 10 and 25 in docs/plan.md): a turn's reworded
// text, or its original when its owner chose to send it as written
// (decision 11), goes through the guest's sender (guest/sender), through
// Tor, to a remote model, paid from one wallet, so the provider can link
// every chat it pays for.

/// The wallet's key, made by the guest's sender with the payment toolkit's
/// own key code and kept only here: a generic password in the login
/// keychain, this device only, like the conversations' key (`Keychain`).
/// Its account is the wallet's address, so the address shows without the
/// key being read. The key is read only when a request that signs is built,
/// and goes to the sender in memory.
public enum WalletKeychain {
    static let service = "sh.regents.cloak.wallet"

    /// The wallet's address, or nil when there is none.
    @concurrent
    public static func address() async throws(Keychain.Failure) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
            let address = attributes[kSecAttrAccount as String] as? String
        else { throw Keychain.Failure(status: status) }
        return address
    }

    /// The wallet's key. Blocking: called while a request is built, off the
    /// main thread.
    public static func key() throws(Keychain.Failure) -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let key = result as? Data, key.count == 32 else { throw Keychain.Failure(status: status) }
        return key
    }

    /// Stores a new wallet; never one beside a wallet already there.
    @concurrent
    public static func store(key: Data, address: String) async throws(Keychain.Failure) {
        guard try await self.address() == nil else { throw Keychain.Failure(status: errSecDuplicateItem) }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
            kSecAttrLabel as String: "Regents Cloak wallet",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }
}

/// Whether this Mac holds the wallet, as the keychain last answered. A read
/// that fails is a stage of its own, which can be asked again.
public enum WalletPresence: Sendable, Equatable {
    /// The keychain is being asked, or has not been yet.
    case looking
    /// The keychain could not be read.
    case unreadable
    /// There is no wallet; Create makes one.
    case absent
    /// Create is under way.
    case creating
    /// The wallet, by its address.
    case held(address: String)

    /// What the keychain answered (`WalletKeychain.address`): the wallet's
    /// address, nil when there is none, or a failure.
    public init(_ read: Result<String?, Keychain.Failure>) {
        switch read {
        case .success(let address?): self = .held(address: address)
        case .success(nil): self = .absent
        case .failure: self = .unreadable
        }
    }

    public var address: String? {
        if case .held(let address) = self { address } else { nil }
    }

    /// Create starts only while there is no wallet; returns whether it did.
    public mutating func create() -> Bool {
        guard self == .absent else { return false }
        self = .creating
        return true
    }
}

/// The wallet's one deposit, as the sender reports it: kept as it comes,
/// never taken apart here, and given back with each request that needs it.
/// Sealed with ChaChaPoly under the conversations' key in one owner-only
/// file, which is gone while there is no deposit. The sender waits until
/// each change is on disk before it goes on, so a deposit about to open is
/// here before its payment leaves.
public struct DepositStore: Sendable {
    public let file: URL
    private let key: SymmetricKey
    private static let tag = Data("deposit".utf8)

    public init(folder: URL, key: SymmetricKey) {
        file = folder.appending(path: "deposit")
        self.key = key
    }

    /// The deposit, or nil when there is none.
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let box = try ChaChaPoly.SealedBox(combined: Data(contentsOf: file))
        return try ChaChaPoly.open(box, using: key, authenticating: Self.tag)
    }

    /// Keeps the deposit as the sender reported it; its `null` means it is gone.
    public func keep(_ deposit: Data) throws {
        if try JSONSerialization.jsonObject(with: deposit, options: .fragmentsAllowed) is NSNull {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try Places.makeOwnerOnly(file.deletingLastPathComponent())
        try ConversationStore.replace(file, with: try ChaChaPoly.seal(deposit, using: key, authenticating: Self.tag).combined)
    }
}

/// One exchange with the guest's sender: the request, built when its turn
/// comes, and each change to the deposit to keep before it goes on.
/// `Supervisor.exchange` in the app.
public typealias Exchange = @Sendable (
    _ request: @escaping @Sendable () throws -> Data, _ keep: @escaping @Sendable (Data) throws -> Void
) async throws -> Data

/// Why a request to the sender stopped.
public struct RemoteStop: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Decodable {
        case noFunds = "no_funds"
        case walletRefused = "wallet_refused"
        case modelUnavailable = "model_unavailable"
        case torDown = "tor_down"
        /// The completion has no answer Chat can show; found here, never by
        /// the sender.
        case answerRefused = "answer_refused"
        case failed
        /// The sender was not reached, or went away: Cloak is not running.
        case unreachable
    }

    public let code: Code
    /// Technical detail for the log; never a key or a message's text.
    public let detail: String
}

/// A token amount in its smallest units; USDC.e has six decimals.
public struct Amount: Sendable, Equatable, Comparable, Decodable {
    public let units: UInt64

    public init(units: UInt64) {
        self.units = units
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let units = UInt64(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an amount"))
        }
        self.units = units
    }

    /// Dollars as typed, with or without a dollar sign: whole units of a
    /// millionth, never rounded. Nil for no amount, more than six places,
    /// or more than an amount holds.
    public init?(dollars text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("$") { text.removeFirst() }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = Set("0123456789")
        guard let whole = parts.first, !whole.isEmpty, whole.allSatisfy(digits.contains) else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.count <= 6, fraction.allSatisfy(digits.contains), let dollars = UInt64(whole) else { return nil }
        let (scaled, over) = dollars.multipliedReportingOverflow(by: 1_000_000)
        let micros = UInt64(fraction.padding(toLength: 6, withPad: "0", startingAt: 0))!
        let (units, past) = scaled.addingReportingOverflow(micros)
        guard !over, !past, units > 0 else { return nil }
        self.units = units
    }

    public var dollars: Decimal { Decimal(units) / 1_000_000 }

    /// How much more than `funds` this amount needs; nil when `funds` are
    /// enough, or were not read.
    public func lacking(in funds: Amount?) -> Amount? {
        guard let funds, funds < self else { return nil }
        return Amount(units: units - funds.units)
    }

    public static func < (a: Amount, b: Amount) -> Bool { a.units < b.units }
}

/// The wallet as the network and the provider show it now.
public struct Look: Sendable, Equatable, Decodable {
    public let balance: Amount
    /// The least balance a first deposit needs.
    public let least: Amount
    /// The provider's setup still names Tempo and USDC.e.
    public let setup: Bool
    public let models: [Model]
    public let deposit: Deposit?

    public struct Model: Sendable, Equatable, Decodable, Identifiable {
        public let id: String
        public let pricing: Pricing
    }

    /// US dollars per million tokens.
    public struct Pricing: Sendable, Equatable, Decodable {
        public let input: Double
        public let output: Double
    }

    public struct Deposit: Sendable, Equatable, Decodable {
        public let deposit: Amount
        /// What this wallet has paid from it so far.
        public let spent: Amount
        /// When the network was asked to close it (seconds since 1970), or 0.
        public let closeRequestedAt: UInt64?
        /// When it can be taken back on the network.
        public let withdrawAt: UInt64?
        /// Closed on the network: forgotten here.
        public let gone: Bool?

        public var left: Amount { Amount(units: deposit.units > spent.units ? deposit.units - spent.units : 0) }
    }
}

/// The requests to the sender. Each builds its request only when its turn
/// comes, reading the deposit kept by then and, for those that sign, the
/// wallet's key; a key never leaves memory here.
public enum Remote {
    /// The wallet's key, read when a request that signs is built:
    /// `WalletKeychain.key` in the app.
    public typealias Key = @Sendable () throws -> Data

    /// Makes the wallet: the sender makes the key, `store` keeps it (the
    /// keychain). Returns the address.
    public static func create(
        exchange: Exchange, store: @Sendable (_ key: Data, _ address: String) async throws -> Void
    ) async throws(RemoteStop) -> String {
        struct Made: Decodable {
            let key: String
            let address: String
        }
        let made: Made = try await run(exchange, keep: { _ in }) { ["op": "create"] }
        guard let key = Data(hex: made.key), key.count == 32 else { throw RemoteStop(code: .failed, detail: "the new key is not 32 bytes") }
        do {
            try await store(key, made.address)
        } catch {
            throw RemoteStop(code: .failed, detail: "cannot keep the new wallet: \(error)")
        }
        return made.address
    }

    /// The balance, the provider's setup and models, and the deposit; a
    /// deposit the network shows closed is forgotten.
    public static func look(address: String, deposits: DepositStore, exchange: Exchange) async throws(RemoteStop) -> Look {
        let look: Look = try await run(exchange, keep: deposits.keep) {
            ["op": "wallet", "address": address, "deposit": try deposit(deposits)]
        }
        if look.deposit?.gone == true {
            do { try deposits.keep(Data("null".utf8)) } catch {
                throw RemoteStop(code: .failed, detail: "cannot forget the closed deposit: \(error)")
            }
        }
        return look
    }

    /// Sends `turn`'s text as sent, after the conversation's earlier turns
    /// as they were sent and answered, to `model` (`complete`). Returns the
    /// model's answer: the first choice's text, when it has one and finished
    /// by stopping or at its length.
    public static func send(
        _ turn: UUID, in conversation: Conversation, model: String, identity: String,
        key: @escaping Key, deposits: DepositStore, exchange: Exchange
    ) async throws(RemoteStop) -> String {
        guard let messages = messages(for: turn, in: conversation) else {
            throw RemoteStop(code: .failed, detail: "the turn is not in the conversation")
        }
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: ["model": model, "messages": messages, "stream": false], options: .withoutEscapingSlashes)
        } catch {
            throw RemoteStop(code: .failed, detail: "cannot build the body: \(error)")
        }
        return try content(of: try await complete(body, identity: identity, key: key, deposits: deposits, exchange: exchange))
    }

    /// The answer in `completion`, a chat completion in OpenAI's shape: the
    /// first choice's text, when it has one and finished by stopping or at
    /// its length. Shared by V (`Payer`), Token Inference and NEAR Private AI
    /// (`Near`).
    public static func content(of completion: Data) throws(RemoteStop) -> String {
        struct Completion: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Said
                let finish_reason: String?
            }
            struct Said: Decodable {
                let content: String?
                let refusal: String?
            }
        }
        guard let choices = try? JSONDecoder().decode(Completion.self, from: completion).choices else {
            throw RemoteStop(code: .failed, detail: "the provider's completion did not read")
        }
        guard let choice = choices.first else { throw RemoteStop(code: .failed, detail: "the provider gave no choice") }
        guard let content = choice.message.content, choice.message.refusal == nil, [nil, "stop", "length"].contains(choice.finish_reason),
            !content.unicodeScalars.allSatisfy(\.properties.isWhitespace)
        else { throw RemoteStop(code: .answerRefused, detail: "finish reason \(choice.finish_reason ?? "none")") }
        return content
    }

    /// Posts `body`, a chat request in OpenAI's shape built on this Mac with
    /// every user message reworded, but for a Chat message its owner chose to
    /// send as written, to the provider through Tor as
    /// `identity`, opening or topping up the deposit as needed, at the size
    /// the provider suggests. Returns the provider's completion as it gave
    /// it.
    public static func complete(
        _ body: Data, identity: String, key: @escaping Key, deposits: DepositStore, exchange: Exchange
    ) async throws(RemoteStop) -> Data {
        struct Completed: Decodable { let completion: String }
        let completed: Completed = try await run(exchange, keep: deposits.keep) {
            [
                "op": "send", "key": try hexKey(key), "deposit": try deposit(deposits),
                "body": String(decoding: body, as: UTF8.self), "identity": identity,
            ]
        }
        return Data(completed.completion.utf8)
    }

    /// The provider's list of models, as it gave it.
    public static func models(exchange: Exchange) async throws(RemoteStop) -> Data {
        struct Listed: Decodable { let models: String }
        let listed: Listed = try await run(exchange, keep: { _ in }) { ["op": "models"] }
        return Data(listed.models.utf8)
    }

    /// Closes the deposit with the provider, which refunds what is unspent.
    public static func close(model: String, key: @escaping Key, deposits: DepositStore, exchange: Exchange) async throws(RemoteStop) {
        struct Closed: Decodable {}
        let _: Closed = try await run(exchange, keep: deposits.keep) {
            ["op": "close", "key": try hexKey(key), "deposit": try kept(deposits), "model": model]
        }
    }

    /// The network's own close: the first asks to close the deposit, the
    /// next, after the grace period, takes it back.
    public static func withdraw(key: @escaping Key, deposits: DepositStore, exchange: Exchange) async throws(RemoteStop) {
        struct Submitted: Decodable { let step: String }
        let _: Submitted = try await run(exchange, keep: deposits.keep) {
            ["op": "withdraw", "key": try hexKey(key), "deposit": try kept(deposits)]
        }
    }

    /// The messages for `turn`: each earlier turn that was answered, as sent
    /// and as answered, then `turn`'s text as sent: reworded, or as written
    /// when its owner chose so. Nothing else: no instruction, and
    /// no original of a reworded turn.
    static func messages(for turn: UUID, in conversation: Conversation) -> [[String: String]]? {
        guard let index = conversation.turns.firstIndex(where: { $0.id == turn }) else { return nil }
        let earlier = conversation.turns[..<index].flatMap { turn in
            turn.answer.map { [["role": "user", "content": turn.sent], ["role": "assistant", "content": $0]] } ?? []
        }
        return earlier + [["role": "user", "content": conversation.turns[index].sent]]
    }

    /// The wallet's EIP-191 signature of Venice's sign-in, made in the guest
    /// (`venice_sign`), which signs nothing but Venice's sign-in.
    public static func veniceSign(_ message: String, key: @escaping Key, exchange: Exchange) async throws(RemoteStop) -> String {
        let signed: Signed = try await run(exchange, keep: { _ in }) { ["op": "venice_sign", "key": try hexKey(key), "message": message] }
        return signed.signature
    }

    /// The wallet's EIP-712 signature of `typed`, made in the guest
    /// (`venice_typed`), which signs nothing but a USDC transfer on Base.
    public static func veniceTyped(_ typed: Data, key: @escaping Key, exchange: Exchange) async throws(RemoteStop) -> String {
        let signed: Signed = try await run(exchange, keep: { _ in }) {
            ["op": "venice_typed", "key": try hexKey(key), "typed": String(decoding: typed, as: UTF8.self)]
        }
        return signed.signature
    }

    /// The address's USDC on Base at the latest block (`venice_funds`).
    public static func veniceFunds(address: String, exchange: Exchange) async throws(RemoteStop) -> Amount {
        struct Funds: Decodable { let balance: Amount }
        let funds: Funds = try await run(exchange, keep: { _ in }) { ["op": "venice_funds", "address": address] }
        return funds.balance
    }

    /// The wallet's signer for Venice: each signature is made in the guest
    /// with `key`, read as each request is built.
    public static func veniceSigner(address: String, key: @escaping Key, exchange: @escaping Exchange) -> VeniceSigner {
        VeniceSigner(
            address: address, personal: { try await veniceSign($0, key: key, exchange: exchange) },
            typed: { try await veniceTyped($0, key: key, exchange: exchange) })
    }

    /// Carries Venice's requests through the guest's sender (`venice`), each
    /// through Tor as `identity`, and its answer back as it comes: `stream`
    /// is `Supervisor.venice` in the app. A stop before Venice's head is
    /// `sent: false` only for `tor_down`; the request may have reached
    /// Venice for anything else. Ending the answer's body first ends the
    /// stream, which closes its connection.
    public static func veniceTransport(
        identity: String, stream: @escaping @Sendable (Data) async throws -> AsyncThrowingStream<Sender.Piece, any Error>
    ) -> VeniceTransport {
        { request throws(VeniceUnreachable) in
            let line: Data
            do {
                line = try JSONSerialization.data(
                    withJSONObject: [
                        "op": "venice", "identity": identity, "method": request.method, "url": request.url.absoluteString,
                        "headers": request.headers, "body": request.body.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
                    ] as [String: Any], options: .withoutEscapingSlashes)
            } catch {
                throw VeniceUnreachable(sent: false)
            }
            let pieces: AsyncThrowingStream<Sender.Piece, any Error>
            do {
                pieces = try await stream(line)
            } catch {
                throw VeniceUnreachable(sent: false)
            }
            let (heads, head) = AsyncStream.makeStream(of: Result<(Int, [String: String]), VeniceUnreachable>.self)
            let (body, feed) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            let forward = Task {
                var headed = false
                do {
                    for try await piece in pieces {
                        switch piece {
                        case .head(let status, let headers):
                            headed = true
                            head.yield(.success((status, headers)))
                            head.finish()
                        case .body(let bytes):
                            feed.yield(bytes)
                        case .end(let answer):
                            let ended = try? JSONDecoder().decode(Ended.self, from: answer)
                            guard headed else {
                                head.yield(.failure(VeniceUnreachable(sent: ended?.stop?.code != RemoteStop.Code.torDown.rawValue)))
                                head.finish()
                                return
                            }
                            if ended?.ok != nil { feed.finish() } else { feed.finish(throwing: VeniceUnreachable(sent: true)) }
                            return
                        }
                    }
                    throw Sender.Failure(description: "the stream ended without an answer")
                } catch {
                    head.yield(.failure(VeniceUnreachable(sent: true)))
                    head.finish()
                    feed.finish(throwing: VeniceUnreachable(sent: true))
                }
            }
            feed.onTermination = { _ in forward.cancel() }
            // Nil when this task is cancelled first.
            var first = heads.makeAsyncIterator()
            guard case .success(let (status, headers))? = await first.next() else {
                forward.cancel()
                throw VeniceUnreachable(sent: true)
            }
            return VeniceResponse(status: status, headers: headers, body: body)
        }
    }

    private struct Signed: Decodable { let signature: String }

    /// The sender's last word on a Venice request: `{"ok":{}}`, or a stop.
    private struct Ended: Decodable {
        let ok: Empty?
        let stop: Stop?
        struct Empty: Decodable {}
        struct Stop: Decodable { let code: String }
    }

    private static func deposit(_ deposits: DepositStore) throws -> Any {
        try deposits.load().map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }

    private static func kept(_ deposits: DepositStore) throws -> Any {
        guard let deposit = try deposits.load() else { throw RemoteStop(code: .failed, detail: "there is no deposit") }
        return try JSONSerialization.jsonObject(with: deposit)
    }

    private static func hexKey(_ key: Key) throws -> String {
        "0x" + (try key()).map { String(format: "%02x", $0) }.joined()
    }

    /// One exchange: the request `build` makes when its turn comes, and the
    /// sender's answer, `{"ok": T}` or `{"stop": {"code", "detail"}}`.
    private static func run<T: Decodable>(
        _ exchange: Exchange, keep: @escaping @Sendable (Data) throws -> Void,
        build: @escaping @Sendable () throws -> [String: Any]
    ) async throws(RemoteStop) -> T {
        let answer: Data
        do {
            answer = try await exchange(
                {
                    do { return try JSONSerialization.data(withJSONObject: try build()) } catch {
                        throw RemoteStop(code: .failed, detail: "cannot build the request: \(error)")
                    }
                },
                { deposit in
                    // Not kept, so the sender is never told to go on.
                    do { try keep(deposit) } catch {
                        throw RemoteStop(code: .failed, detail: "cannot keep the deposit: \(error)")
                    }
                })
        } catch let stop as RemoteStop {
            throw stop
        } catch {
            throw RemoteStop(code: .unreachable, detail: "\(error)")
        }
        guard let reply = try? JSONDecoder().decode(Reply<T>.self, from: answer) else {
            throw RemoteStop(code: .failed, detail: "the sender's answer did not read")
        }
        if let ok = reply.ok { return ok }
        if let stop = reply.stop { throw RemoteStop(code: stop.code, detail: stop.detail) }
        throw RemoteStop(code: .failed, detail: "the sender's answer is empty")
    }

    private struct Reply<T: Decodable>: Decodable {
        let ok: T?
        let stop: Stop?

        struct Stop: Decodable {
            let code: RemoteStop.Code
            let detail: String
        }
    }
}

extension Data {
    /// Bytes from hex, with or without 0x; nil for anything else.
    init?(hex: String) {
        let digits = Array((hex.hasPrefix("0x") ? hex.dropFirst(2) : Substring(hex)).utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
