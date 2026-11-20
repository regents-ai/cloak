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
    /// The worker could not start, or it ended, for this reason.
    case failed(Reason)
}

/// A Local Llama chat's request to the worker (an `L` frame) and its reply:
/// the conversation so far, each message as written and each answer as
/// given, alternating and ending with the message to answer. The worker
/// puts it through the model's own chat template with no system message,
/// no grammar and llama.cpp's default sampling.
enum LocalLlama {
    /// The largest request a frame carries (`Frames.maxPayload`).
    static let maxRequest = 1 << 20
    /// The worker's status when the conversation and an answer do not fit.
    static let tooLongStatus: UInt16 = 413

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let messages: [Message]
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    /// The request for `messages`, which alternate the owner's and the
    /// model's, starting and ending with the owner's; nil when it is larger
    /// than a frame carries.
    static func request(_ messages: [String]) -> Data? {
        let request = Request(messages: messages.enumerated().map { index, content in
            .init(role: index.isMultiple(of: 2) ? "user" : "assistant", content: content)
        })
        let data = try! JSONEncoder().encode(request)
        return data.count <= maxRequest ? data : nil
    }

    /// The answer's text in a completed reply; nil when it holds none.
    static func answer(_ body: Data) -> String? {
        (try? JSONDecoder().decode(Reply.self, from: body))?.choices.first?.message.content
    }
}
