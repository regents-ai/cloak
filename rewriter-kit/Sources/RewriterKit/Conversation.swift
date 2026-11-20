import Foundation

/// A Local Llama chat's request, sent only by the app in an `L` frame, and
/// nothing else: exactly `{"messages":[{"role":"user","content":"..."},...]}`,
/// the messages alternating user and assistant, the first and the last from
/// the user. No model, system message or setting: the worker answers with
/// its one pinned model, the model's chat template and llama.cpp's default
/// sampling.
public struct Conversation: Decodable, Sendable {
    public struct Message: Sendable {
        public let role: String
        public let content: String
    }

    public let messages: [Message]

    enum CodingKeys: String, CodingKey, CaseIterable { case messages }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messages = try container.decode([ChatRequest.Message].self, forKey: .messages)
        guard messages.count % 2 == 1,
            messages.enumerated().allSatisfy({ $0.element.role == ($0.offset.isMultiple(of: 2) ? "user" : "assistant") })
        else {
            throw WorkerError("request is not a Local Llama conversation")
        }
        self.messages = messages.map { Message(role: $0.role, content: $0.content) }
    }
}
