import CloakControl
import Foundation

/// Why a Local Llama chat's message has no answer.
public enum AnswerStop: Error, Sendable, Equatable {
    /// Its task was cancelled: the owner pressed Stop.
    case stopped
    /// A Start, Pause, Stop or quit ended the worker that had it.
    case interrupted
    /// The conversation and an answer no longer fit the model's context on
    /// this Mac.
    case tooLong
    /// A reasoning model spent its thinking token budget without emitting a
    /// visible answer (Decision R7).
    case thinkingLimit
    /// The worker could not start, or it ended, for this reason.
    case failed(Reason)
}

/// One message in a Local Llama conversation. Assistant messages may carry
/// prior `thinking` so reasoning models like Inkling 2 Mini receive their own
/// `reasoning_content` across turns via their chat template.
public struct LocalMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    public let thinking: String?

    public static func user(_ content: String) -> Self {
        Self(role: "user", content: content, thinking: nil)
    }

    public static func assistant(_ content: String, thinking: String? = nil) -> Self {
        Self(role: "assistant", content: content, thinking: thinking.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Live stage of a Local Mode answer request so the UI can distinguish cold
/// model startup (verifying pins and loading weights into Apple Silicon memory)
/// from active prompt processing and reasoning.
public enum LocalAnswerStage: Sendable, Equatable {
    case startingModel
    case answering
}

/// User-selectable thinking effort for reasoning-capable local models (e.g. Inkling 2 Mini).
public enum LocalReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast = "low"
    case balanced = "medium"
    case deep = "high"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .deep: "Deep"
        }
    }

    public var detail: String {
        switch self {
        case .fast: "Brief thinking (~7× faster replies on Inkling 2 Mini)"
        case .balanced: "Moderate thinking for everyday coding & writing"
        case .deep: "Maximum thinking depth for hard math & architecture"
        }
    }
}

/// One completed Local Llama reply: visible answer text plus optional parsed
/// reasoning/thinking text to send back on subsequent turns.
public struct LocalAnswer: Sendable, Equatable {
    public let text: String
    public let thinking: String?

    public init(text: String, thinking: String? = nil) {
        self.text = text
        self.thinking = thinking.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A Local Llama chat's request to the worker (an `L` frame) and its reply:
/// the conversation so far, each message as written and each answer as
/// given (with prior thinking when the model emitted it), alternating and
/// ending with the message to answer. The worker puts it through the model's
/// own chat template with no system message, no grammar and default sampling.
package enum LocalLlama {
    /// The largest request a frame carries (`Frames.maxPayload`).
    static let maxRequest = 1 << 20
    /// The worker's status when the conversation and an answer do not fit.
    static let tooLongStatus: UInt16 = 413
    /// The worker's status when thinking consumed its budget before answering.
    static let thinkingLimitStatus: UInt16 = 422

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
            let reasoning_content: String?
        }

        let messages: [Message]
        let reasoning_effort: String?
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
                let reasoning_content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    /// The request for `messages`, which alternate user and assistant,
    /// starting and ending with user; nil when it is larger than a frame carries.
    package static func request(_ messages: [LocalMessage], reasoningEffort: LocalReasoningEffort? = nil) -> Data? {
        let request = Request(
            messages: messages.map { message in
                .init(
                    role: message.role, content: message.content,
                    reasoning_content: message.role == "assistant" ? message.thinking.flatMap { $0.isEmpty ? nil : $0 } : nil)
            },
            reasoning_effort: reasoningEffort?.rawValue)
        let data = try! JSONEncoder().encode(request)
        return data.count <= maxRequest ? data : nil
    }

    /// The answer and optional thinking in a completed reply; nil when it holds none.
    package static func answer(_ body: Data) -> LocalAnswer? {
        guard let message = (try? JSONDecoder().decode(Reply.self, from: body))?.choices.first?.message else {
            return nil
        }
        return LocalAnswer(text: message.content, thinking: message.reasoning_content)
    }
}
