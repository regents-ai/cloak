import Foundation

/// The daemon's rewrite request, and nothing else
/// (`reference/rewriter-contract.md`): exactly these keys, a system message
/// then a user message, greedy decoding, no streaming.
public struct ChatRequest: Decodable, Sendable {
    public let model: String
    public let maxTokens: Int
    public let system: String
    public let user: String

    static let maxTokensLimit = 16384

    enum CodingKeys: String, CodingKey, CaseIterable {
        case model, stream, temperature, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Decodable {
        let role: String
        let content: String

        enum CodingKeys: String, CodingKey, CaseIterable { case role, content }

        init(from decoder: any Decoder) throws {
            try requireExactKeys(CodingKeys.self, in: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            content = try container.decode(String.self, forKey: .content)
        }
    }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        let stream = try container.decode(Bool.self, forKey: .stream)
        let temperature = try container.decode(Double.self, forKey: .temperature)
        let messages = try container.decode([Message].self, forKey: .messages)
        guard !stream, temperature == 0, (1...Self.maxTokensLimit).contains(maxTokens),
            messages.count == 2, messages[0].role == "system", messages[1].role == "user"
        else {
            throw WorkerError("request is not the daemon's rewrite request")
        }
        system = messages[0].content
        user = messages[1].content
    }

    public var templateMessages: [[String: any Sendable]] {
        [["role": "system", "content": system], ["role": "user", "content": user]]
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func requireExactKeys<Keys: CodingKey & CaseIterable>(_ keys: Keys.Type, in decoder: any Decoder) throws {
    let present = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    guard present == Set(Keys.allCases.map(\.stringValue)) else {
        throw WorkerError("unexpected fields \(present.symmetricDifference(Keys.allCases.map(\.stringValue)).sorted())")
    }
}
