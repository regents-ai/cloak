import Foundation

/// OpenAI-style reply bodies, carrying the fields the daemon reads.
public enum Reply {
    private struct Body: Encodable {
        struct Choice: Encodable {
            struct Message: Encodable {
                let role = "assistant"
                let content: String
                let reasoning_content: String?
            }
            let index = 0
            let message: Message
            let finish_reason: String
        }
        struct Usage: Encodable {
            let prompt_tokens: Int
            let completion_tokens: Int
            let total_tokens: Int
        }
        let id: String
        let object = "chat.completion"
        let created: Int
        let model: String
        let choices: [Choice]
        let usage: Usage
    }

    private struct ErrorBody: Encodable {
        struct Detail: Encodable { let message: String }
        let error: Detail
    }

    public static func completion(
        model: String, text: String, reasoning: String? = nil, promptTokens: Int, completionTokens: Int, finishReason: String
    ) -> Data {
        let nonEmptyReasoning = reasoning.flatMap { $0.isEmpty ? nil : $0 }
        return encode(
            Body(
                id: "chatcmpl-\(UUID().uuidString.lowercased())",
                created: Int(Date().timeIntervalSince1970),
                model: model,
                choices: [.init(message: .init(content: text, reasoning_content: nonEmptyReasoning), finish_reason: finishReason)],
                usage: .init(
                    prompt_tokens: promptTokens,
                    completion_tokens: completionTokens,
                    total_tokens: promptTokens + completionTokens)))
    }

    public static func error(_ message: String) -> Data {
        encode(ErrorBody(error: .init(message: message)))
    }

    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding these plain structs cannot fail.
        return try! encoder.encode(value)
    }
}
