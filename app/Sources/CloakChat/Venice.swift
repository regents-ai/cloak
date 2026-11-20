import Foundation

// Venice (venice.ai), a provider inside Token Inference: each message goes,
// reworded on this Mac, to one model on Venice's live list, paid by the
// owner's own Venice key or by a wallet's Venice credit (VeniceWallet.swift).
// This side builds each request and reads each answer; carrying them, from
// the guest through Tor, is the transport's (docs/venice.md, "Transport").

/// One request for Venice's API, at `https://api.venice.ai/api/v1/`.
public struct VeniceRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    /// Names in lower case. May hold the key or a signed sign-in.
    public let headers: [String: String]
    public let body: Data?
}

extension VeniceRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The method and path alone: never a header nor the body, so that no log
    /// line shows the key, a signature or a message.
    public var description: String { "\(method) \(url.path)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["request": description]) }
}

/// Venice's answer as it arrives: its status and headers, then its body in
/// pieces.
public struct VeniceResponse: Sendable {
    public let status: Int
    /// Names in lower case.
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The transport could not carry a request; `sent`, whether any of it may
/// have reached Venice.
public struct VeniceUnreachable: Error, Sendable {
    public let sent: Bool

    public init(sent: Bool) {
        self.sent = sent
    }
}

/// Carries one request to Venice and gives back its answer.
public typealias VeniceTransport = @Sendable (VeniceRequest) async throws(VeniceUnreachable) -> VeniceResponse

/// How requests are paid for: the owner's own Venice key, or a wallet's
/// Venice credit, signed for by `VeniceSigner`.
public enum VeniceAuth: Sendable {
    case key(String)
    case wallet(VeniceSigner)
}

extension VeniceAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Which of the two, never the key.
    public var description: String {
        switch self {
        case .key: "key"
        case .wallet: "wallet"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["auth": description]) }
}

/// A model's privacy mode, as Venice names it
/// (docs.venice.ai/overview/privacy). A message goes to a TEE model
/// unencrypted, so Venice runs it as TEE, never as E2EE.
public enum VeniceTier: String, Codable, Sendable, CaseIterable {
    case anonymous, `private`, tee

    /// Venice's own word.
    public var name: String {
        switch self {
        case .anonymous: "Anonymous"
        case .private: "Private"
        case .tee: "TEE"
        }
    }

    /// What Venice says the tier means, and what it does not mean, for a
    /// tooltip.
    public var about: String {
        switch self {
        case .anonymous:
            "Venice's word for this model. Venice sends your messages to the model's own company without your Venice account. That company can read them and may keep them."
        case .private:
            "Venice's word for this model. Venice says the model keeps nothing once it answers, by contract. Venice and the model's host can still read your messages, and Cloak cannot check what they keep."
        case .tee:
            "Venice's word for this model. Venice says the model runs in sealed hardware that can prove what it runs, and keeps nothing once it answers. Cloak does not check that proof, and Venice can still read your messages on their way in."
        }
    }

    /// Venice's `privacy` field says `private`: the models a picker offers
    /// until its owner chooses to see the rest.
    public var isVenicePrivate: Bool { self != .anonymous }
}

/// One text model on Venice's list.
public struct VeniceModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let tier: VeniceTier
    /// Venice says it is offline for now.
    public let offline: Bool
    /// Venice may answer requests for this model from another one
    /// (`deprecation.autoRemap`).
    public let remapped: Bool
    public let context: Int
    /// Venice's prices, in US dollars for a million tokens.
    public let input: Decimal
    public let output: Decimal
}

/// What a Venice chat keeps: its model and the tier it had when the chat
/// began. A chat never moves to another model or tier.
public struct VeniceChat: Codable, Sendable, Equatable {
    public let model: String
    public let tier: VeniceTier

    public init(model: String, tier: VeniceTier) {
        self.model = model
        self.tier = tier
    }

    /// Stops, before anything is sent, unless `models` still has the chat's
    /// model at its tier, answering as itself.
    func check(in models: [VeniceModel]) throws(VeniceStop) {
        guard let model = models.first(where: { $0.id == self.model }), !model.remapped else {
            throw VeniceStop(.gone, sent: false, "the model is not listed, or Venice may answer for it from another")
        }
        guard model.tier == tier else { throw VeniceStop(.tierChanged, sent: false, "listed as \(model.tier.rawValue)") }
        guard !model.offline else { throw VeniceStop(.busy, sent: false, "listed as offline") }
    }
}

/// What the key, or the wallet, has to spend.
public struct VeniceAccount: Sendable, Equatable {
    /// US dollars, when Venice says.
    public let usd: Decimal?
    /// Venice's own DIEM, when Venice says; for a key only.
    public let diem: Decimal?
    /// Venice says it may spend now.
    public let canSpend: Bool
}

/// One answer, read whole.
public struct VeniceAnswer: Sendable, Equatable {
    public let text: String
    /// `stop`, or `length` when it ran out of room.
    public let finish: String
    public let promptTokens: Int?
    public let answerTokens: Int?
    /// What Venice says it cost, in US dollars.
    public let cost: Decimal?
    /// The wallet's Venice credit left, in US dollars; for a wallet only.
    public let balance: Decimal?
}

/// Why a request stopped, and whether it may have reached Venice.
public struct VeniceStop: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Venice turned the key down (401).
        case key
        /// Venice turned the wallet's sign-in down (401).
        case signIn
        /// The signer did not sign.
        case signing
        /// Too little balance or credit (402).
        case noBalance
        /// The key reached the spending limit set on it (402 with a limit
        /// code).
        case spendLimit
        /// Venice did not take a top-up's payment (400, 401 or 402 to it).
        case paymentRefused
        /// Too many requests (429).
        case rateLimit
        /// The chat's model is not listed, or Venice may answer for it from
        /// another, or Venice says it is not there (404, or 400
        /// `INVALID_MODEL`).
        case gone
        /// The chat's model is listed at another tier than when the chat
        /// began.
        case tierChanged
        /// The answer came from a model other than the chat's.
        case otherModel
        /// Venice refused it (403, or 401 `PRO_ONLY_MODEL`).
        case refused
        /// The chat is longer than its model takes (413, or 400 with a
        /// context code).
        case tooLong
        /// The model is offline, overloaded or full (503, 429
        /// `MODEL_OVERLOADED`, or the list says offline).
        case busy
        /// Venice could not be reached, or the connection broke.
        case unreachable
        /// Anything else, or an answer that did not read.
        case failed
        /// Its task was cancelled.
        case cancelled

        /// One or two words for the chat.
        public var title: String {
            switch self {
            case .key: "Key refused"
            case .signIn: "Sign-in refused"
            case .signing: "Not signed"
            case .noBalance: "No funds"
            case .spendLimit: "Spend limit"
            case .paymentRefused: "Not paid"
            case .rateLimit: "Try later"
            case .gone: "Model gone"
            case .tierChanged: "Tier changed"
            case .otherModel: "Other model"
            case .refused: "Refused"
            case .tooLong: "Too long"
            case .busy: "Busy"
            case .unreachable: "No connection"
            case .failed: "No answer"
            case .cancelled: "Stopped"
            }
        }

        /// A sentence for the chat: what happened, and what to do.
        public var words: String {
            switch self {
            case .key: "Venice turned down your key. Check it in Settings."
            case .signIn: "Venice turned down the wallet's sign-in. Send again."
            case .signing: "Cloak could not sign for the wallet. Send again."
            case .noBalance: "Your Venice balance is too low. Add funds, then send again."
            case .spendLimit: "Your key reached the spending limit set on it at Venice."
            case .paymentRefused: "Venice did not take the payment. Check the wallet's USDC on Base, then try again."
            case .rateLimit: "Venice is limiting requests. Wait a minute, then send again."
            case .gone: "Venice no longer offers this chat's model. Start a new chat."
            case .tierChanged: "Venice changed this model's tier since the chat began. Start a new chat."
            case .otherModel: "Venice answered from a different model, so the answer is not shown."
            case .refused: "Venice refused this request. Check your key's settings at Venice."
            case .tooLong: "This chat is too long for its model. Start a new chat."
            case .busy: "This model is busy or offline at Venice. Send again in a minute."
            case .unreachable: "Cloak could not reach Venice. Send again."
            case .failed: "Venice did not answer. Send again."
            case .cancelled: "You stopped this message."
            }
        }
    }

    public let kind: Kind
    /// Whether the request may have reached Venice.
    public let sent: Bool
    /// For the log: Venice's status and documented code, or Cloak's own
    /// step. Built from Cloak's own words alone, so never the key, a
    /// signature, a message, or words of Venice's.
    public let text: String

    init(_ kind: Kind, sent: Bool, _ text: String) {
        self.kind = kind
        self.sent = sent
        self.text = text
    }

    /// The stop for a status other than 200, from the status and the
    /// documented `code` alone, never Venice's message
    /// (docs.venice.ai/api-reference/error-codes).
    /// `auth` is nil for the model list, which goes without either.
    static func answered(_ status: Int, _ code: VeniceCode?, auth: VeniceAuth?) -> VeniceStop {
        let kind: Kind =
            switch (status, code) {
            case (401, .proOnly?): .refused
            case (401, _):
                switch auth {
                case .key?: .key
                case .wallet?: .signIn
                case nil: .failed
                }
            case (402, .usdLimit?), (402, .diemLimit?): .spendLimit
            case (402, _): .noBalance
            case (403, _): .refused
            case (404, _), (400, .invalidModel?): .gone
            case (413, _), (400, .tooManyTokens?), (400, .contextLength?): .tooLong
            case (429, .overloaded?): .busy
            case (429, _): .rateLimit
            case (503, _): .busy
            default: .failed
            }
        return VeniceStop(kind, sent: true, "status \(status)" + (code.map { " \($0.rawValue)" } ?? ""))
    }

    /// The stop for an error Venice sent after the answer began.
    static func midway(_ code: VeniceCode?) -> VeniceStop {
        let kind: Kind =
            switch code {
            case .overloaded?, .atCapacity?, .offline?: .busy
            case .tooManyTokens?, .contextLength?: .tooLong
            default: .failed
            }
        return VeniceStop(kind, sent: true, "error in the stream" + (code.map { " \($0.rawValue)" } ?? ""))
    }
}

/// The codes Venice documents that change which stop a status gives.
enum VeniceCode: String, Sendable {
    case proOnly = "PRO_ONLY_MODEL"
    case usdLimit = "API_KEY_USD_SPEND_LIMIT_EXCEEDED"
    case diemLimit = "API_KEY_DIEM_SPEND_LIMIT_EXCEEDED"
    case invalidModel = "INVALID_MODEL"
    case tooManyTokens = "TOO_MANY_TOKENS"
    case contextLength = "context_length_exceeded"
    case overloaded = "MODEL_OVERLOADED"
    case atCapacity = "MODEL_AT_CAPACITY"
    case offline = "MODEL_OFFLINE"
}

/// Venice's API, for one way of paying.
public struct Venice: Sendable {
    public let auth: VeniceAuth
    let transport: VeniceTransport
    /// The time a sign-in or payment is signed at.
    let now: @Sendable () -> Date
    /// `count` random bytes, for a sign-in's or payment's nonce.
    let random: @Sendable (_ count: Int) -> [UInt8]

    public init(auth: VeniceAuth, transport: @escaping VeniceTransport) {
        self.init(auth: auth, transport: transport, now: Date.init, random: { count in (0..<count).map { _ in .random(in: .min ... .max) } })
    }

    init(
        auth: VeniceAuth, transport: @escaping VeniceTransport, now: @escaping @Sendable () -> Date,
        random: @escaping @Sendable (_ count: Int) -> [UInt8]
    ) {
        self.auth = auth
        self.transport = transport
        self.now = now
        self.random = random
    }

    static let base = "https://api.venice.ai/api/v1/"

    /// Venice's text models now. The list is public, so it goes without
    /// the key or a sign-in.
    public static func models(transport: VeniceTransport) async throws(VeniceStop) -> [VeniceModel] {
        let request = VeniceRequest(method: "GET", url: URL(string: base + "models?type=text")!, headers: [:], body: nil)
        let response = try await carry(request, transport)
        let body = try await whole(response)
        guard response.status == 200 else { throw VeniceStop.answered(response.status, code(in: body), auth: nil) }
        do {
            return try JSONDecoder().decode(Listed.self, from: body).models
        } catch {
            throw VeniceStop(.failed, sent: true, "the model list did not read")
        }
    }

    /// What the key, or the wallet, has to spend. Costs nothing.
    public func account() async throws(VeniceStop) -> VeniceAccount {
        switch auth {
        case .key:
            let response = try await Self.carry(try await request("GET", "api_keys/rate_limits"), transport)
            let body = try await Self.whole(response)
            guard response.status == 200 else { throw VeniceStop.answered(response.status, Self.code(in: body), auth: auth) }
            struct Limits: Decodable {
                let data: Account
                struct Account: Decodable {
                    let accessPermitted: Bool
                    let balances: Balances
                }
                struct Balances: Decodable {
                    let USD: Decimal?
                    let DIEM: Decimal?
                }
            }
            guard let account = try? JSONDecoder().decode(Limits.self, from: body).data else {
                throw VeniceStop(.failed, sent: true, "the key's account did not read")
            }
            return VeniceAccount(usd: account.balances.USD, diem: account.balances.DIEM, canSpend: account.accessPermitted)
        case .wallet(let signer):
            let response = try await Self.carry(try await request("GET", "x402/balance/\(signer.address)"), transport)
            let body = try await Self.whole(response)
            guard response.status == 200 else { throw VeniceStop.answered(response.status, Self.code(in: body), auth: auth) }
            struct Balance: Decodable {
                let data: Wallet
                struct Wallet: Decodable {
                    let balanceUsd: Decimal
                    let canConsume: Bool
                }
            }
            guard let wallet = try? JSONDecoder().decode(Balance.self, from: body).data else {
                throw VeniceStop(.failed, sent: true, "the wallet's balance did not read")
            }
            return VeniceAccount(usd: wallet.balanceUsd, diem: nil, canSpend: wallet.canConsume)
        }
    }

    /// Sends `turn` of `conversation`, as its messages have it, to `chat`'s
    /// model, once Venice's list still has that model at the chat's tier,
    /// answering as itself; else sends nothing. Gives `partial` the answer
    /// so far as it arrives.
    public func ask(
        _ chat: VeniceChat, turn: UUID, in conversation: Conversation, partial: @Sendable (String) -> Void
    ) async throws(VeniceStop) -> VeniceAnswer {
        try chat.check(in: try await Self.models(transport: transport))
        guard let messages = Remote.messages(for: turn, in: conversation) else {
            throw VeniceStop(.failed, sent: false, "the turn is not in the conversation")
        }
        let response = try await Self.carry(try await request("POST", "chat/completions", body: Self.body(model: chat.model, messages: messages)), transport)
        guard response.status == 200 else {
            throw VeniceStop.answered(response.status, Self.code(in: try await Self.whole(response)), auth: auth)
        }
        return try await Self.read(response, model: chat.model, partial: partial)
    }

    /// A chat request's body: these fields and no others. Venice adds no
    /// instruction of its own, keeps any thinking out of the answer, and
    /// searches nothing. Every stream ends with its usage unasked. Venice
    /// ignores a misspelled `venice_parameters` key, so each is spelled as
    /// its API reference has it.
    static func body(model: String, messages: [[String: String]]) -> Data {
        struct Body: Encodable {
            let model: String
            let messages: [[String: String]]
            let stream = true
            let venice_parameters = Parameters()

            struct Parameters: Encodable {
                let include_venice_system_prompt = false
                let strip_thinking_response = true
                let enable_web_search = "off"
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings and booleans alone, which always encode.
        return try! encoder.encode(Body(model: model, messages: messages))
    }

    /// A request to `path` under the API, with the key, or a sign-in signed
    /// for it alone.
    func request(_ method: String, _ path: String, body: Data? = nil) async throws(VeniceStop) -> VeniceRequest {
        let url = URL(string: Self.base + path)!
        var headers = body == nil ? [:] : ["content-type": "application/json"]
        switch auth {
        case .key(let key): headers["authorization"] = "Bearer \(key)"
        case .wallet(let signer):
            headers["sign-in-with-x"] = try await VeniceWallet.signIn(
                for: url, signer: signer, now: now(), nonce: VeniceWallet.hex(random(16)))
        }
        return VeniceRequest(method: method, url: url, headers: headers, body: body)
    }

    static func carry(_ request: VeniceRequest, _ transport: VeniceTransport) async throws(VeniceStop) -> VeniceResponse {
        guard !Task.isCancelled else { throw VeniceStop(.cancelled, sent: false, "cancelled before sending") }
        do {
            return try await transport(request)
        } catch {
            throw VeniceStop(.unreachable, sent: error.sent, "the transport did not carry \(request)")
        }
    }

    /// A body read whole, up to a megabyte.
    static func whole(_ response: VeniceResponse) async throws(VeniceStop) -> Data {
        var body = Data()
        do {
            for try await piece in response.body {
                body += piece
                guard body.count <= 1 << 20 else { throw VeniceStop(.failed, sent: true, "the answer is over a megabyte") }
            }
        } catch let stop as VeniceStop {
            throw stop
        } catch {
            throw VeniceStop(.unreachable, sent: true, "the answer broke off")
        }
        guard !Task.isCancelled else { throw VeniceStop(.cancelled, sent: true, "cancelled while reading") }
        return body
    }

    /// The documented `code` in an error body, at its top or in its
    /// `error` object; nil for a code that changes no stop.
    static func code(in body: Data) -> VeniceCode? {
        struct Failure: Decodable {
            let code: VeniceCode?

            enum Keys: String, CodingKey { case code, error }

            init(from decoder: any Decoder) throws {
                let top = try decoder.container(keyedBy: Keys.self)
                let inner = try? top.nestedContainer(keyedBy: Keys.self, forKey: .error)
                let text = (try? top.decode(String.self, forKey: .code)) ?? (try? inner?.decode(String.self, forKey: .code))
                code = text.flatMap(VeniceCode.init(rawValue:))
            }
        }
        return (try? JSONDecoder().decode(Failure.self, from: body))?.code
    }

    /// A streamed answer, read to Venice's `[DONE]`.
    static func read(_ response: VeniceResponse, model: String, partial: @Sendable (String) -> Void) async throws(VeniceStop) -> VeniceAnswer {
        struct Chunk: Decodable {
            let model: String?
            let choices: [Choice]?
            let usage: Usage?
            let cost: Cost?
            let error: Failure?

            struct Choice: Decodable {
                let delta: Delta?
                let finish_reason: String?
            }
            struct Delta: Decodable {
                let content: String?
            }
            struct Usage: Decodable {
                let prompt_tokens: Int
                let completion_tokens: Int
            }
            struct Cost: Decodable {
                let usd: Decimal
            }
            struct Failure: Decodable {
                let code: String?
            }
        }

        var events = Events()
        var text = ""
        var finish: String?
        var usage: Chunk.Usage?
        var cost: Decimal?
        do {
            for try await piece in response.body {
                for event in events.add(piece) {
                    if event == "[DONE]" {
                        guard let finish, ["stop", "length"].contains(finish) else {
                            let named = finish.flatMap { ["tool_calls", "content_filter"].contains($0) ? $0 : nil }
                            throw VeniceStop(.failed, sent: true, "finish reason \(named ?? "missing or unknown")")
                        }
                        guard !text.unicodeScalars.allSatisfy(\.properties.isWhitespace) else { throw VeniceStop(.failed, sent: true, "no text") }
                        return VeniceAnswer(
                            text: text, finish: finish, promptTokens: usage?.prompt_tokens, answerTokens: usage?.completion_tokens, cost: cost,
                            balance: response.headers["x-balance-remaining"].flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) })
                    }
                    guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(event.utf8)) else {
                        throw VeniceStop(.failed, sent: true, "a chunk did not read")
                    }
                    if let failure = chunk.error { throw VeniceStop.midway(failure.code.flatMap(VeniceCode.init(rawValue:))) }
                    guard chunk.model == nil || chunk.model == model else { throw VeniceStop(.otherModel, sent: true, "a chunk named another model") }
                    for choice in chunk.choices ?? [] {
                        if let content = choice.delta?.content, !content.isEmpty {
                            text += content
                            partial(text)
                        }
                        if let reason = choice.finish_reason { finish = reason }
                    }
                    if let used = chunk.usage { usage = used }
                    if let spent = chunk.cost { cost = spent.usd }
                }
            }
        } catch let stop as VeniceStop {
            throw stop
        } catch {
            throw VeniceStop(.unreachable, sent: true, "the answer broke off")
        }
        guard !Task.isCancelled else { throw VeniceStop(.cancelled, sent: true, "cancelled while answering") }
        throw VeniceStop(.failed, sent: true, "the answer ended before [DONE]")
    }
}

/// Server-sent events, from bytes as they arrive: each event's data lines,
/// joined by line feeds. Comments and other fields are left out.
struct Events {
    private var line = Data()
    private var data: [String] = []

    mutating func add(_ bytes: Data) -> [String] {
        var complete: [String] = []
        for byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                if !data.isEmpty { complete.append(data.joined(separator: "\n")) }
                data.removeAll()
            } else if text.hasPrefix("data:") {
                let value = text.dropFirst(5)
                data.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
            }
        }
        return complete
    }
}

/// Venice's `GET /models` answer, as far as Cloak reads it.
private struct Listed: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let id: String
        let type: String
        let model_spec: Spec
    }

    struct Spec: Decodable {
        let name: String
        let privacy: Privacy
        let offline: Bool
        let availableContextTokens: Int
        let capabilities: Capabilities
        let pricing: Pricing
        let deprecation: Deprecation?
    }

    enum Privacy: String, Decodable {
        case `private`, anonymized
    }

    struct Capabilities: Decodable {
        let supportsTeeAttestation: Bool
    }

    struct Pricing: Decodable {
        let input: Price
        let output: Price
    }

    struct Price: Decodable {
        let usd: Decimal
    }

    struct Deprecation: Decodable {
        let autoRemap: Bool
    }

    var models: [VeniceModel] {
        data.filter { $0.type == "text" }.map { entry in
            let spec = entry.model_spec
            return VeniceModel(
                id: entry.id, name: spec.name,
                tier: spec.capabilities.supportsTeeAttestation ? .tee : spec.privacy == .private ? .private : .anonymous,
                offline: spec.offline, remapped: spec.deprecation?.autoRemap ?? false, context: spec.availableContextTokens,
                input: spec.pricing.input.usd, output: spec.pricing.output.usd)
        }
    }
}
