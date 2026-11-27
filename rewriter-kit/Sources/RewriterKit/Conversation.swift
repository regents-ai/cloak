import Foundation

/// A Local Llama chat's request, sent only by the app in an `L` frame, and
/// nothing else: `{"messages":[{"role":"user","content":"..."},...]}`,
/// the messages alternating user and assistant, the first and the last from
/// the user. Assistant messages may carry an optional `reasoning_content`
/// string so reasoning models such as Inkling 2 Mini receive their prior
/// thinking across turns. No model, system message or setting: the worker
/// answers with its one pinned model, the model's chat template and default
/// sampling.
public struct Conversation: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let role: String
        public let content: String
        public let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case reasoningContent = "reasoning_content"
        }

        public init(role: String, content: String, reasoningContent: String? = nil) {
            self.role = role
            self.content = content
            self.reasoningContent = reasoningContent.flatMap { $0.isEmpty ? nil : $0 }
        }

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.container(keyedBy: AnyKey.self)
            let allowed: Set<String> = ["role", "content", "reasoning_content"]
            let present = Set(raw.allKeys.map(\.stringValue))
            guard present.isSubset(of: allowed), present.contains("role"), present.contains("content") else {
                throw WorkerError("unexpected fields in conversation message")
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            content = try container.decode(String.self, forKey: .content)
            let reasoning = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
            if reasoning != nil, role != "assistant" {
                throw WorkerError("reasoning_content is only allowed on assistant messages")
            }
            reasoningContent = reasoning.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public let messages: [Message]
    /// Optional reasoning effort hint for reasoning-capable local models such as Inkling 2 Mini
    /// (`"low"`, `"medium"`, `"high"`). Omitted or ignored by models without effort controls.
    public let reasoningEffort: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case messages
        case reasoningEffort = "reasoning_effort"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let allowed: Set<String> = ["messages", "reasoning_effort"]
        let present = Set(raw.allKeys.map(\.stringValue))
        guard present.isSubset(of: allowed), present.contains("messages") else {
            throw WorkerError("unexpected fields in conversation")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messages = try container.decode([Message].self, forKey: .messages)
        guard messages.count % 2 == 1,
            messages.enumerated().allSatisfy({ $0.element.role == ($0.offset.isMultiple(of: 2) ? "user" : "assistant") })
        else {
            throw WorkerError("request is not a Local Llama conversation")
        }
        self.messages = messages
        if let effort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) {
            let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
            self.reasoningEffort = valid.contains(trimmed) ? trimmed : nil
        } else {
            self.reasoningEffort = nil
        }
    }
}
