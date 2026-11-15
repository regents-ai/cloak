import Foundation

/// What one line of the agent's output says for its task's card. The agent
/// is Pi in JSON mode, one event a line (docs/json.md in Pi's package): a
/// tool it starts using is a step; an answer of the model's that ends its
/// work is the task's answer; a model request that failed is a failure,
/// with the door's own sentence when the door refused it. Pi retries some
/// failures, so of the answers and failures, the last one stands.
public enum PiEvent: Sendable, Equatable {
    case step(Step)
    case answer(String)
    /// The door's sentence, or nil when the failure has none.
    case failure(String?)

    /// The event `line` is for the card; nil for every other line, and for
    /// one that does not read.
    public init?(line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "tool_execution_start":
            guard let tool = event["toolName"] as? String else { return nil }
            let arguments = event["args"] as? [String: Any]
            let detail: String? = switch tool {
            case "bash": arguments?["command"] as? String
            case "read", "edit", "write": arguments?["path"] as? String
            default: nil
            }
            self = .step(Step(tool: tool, detail: detail))
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            switch message["stopReason"] as? String {
            case "stop", "length":
                let blocks = message["content"] as? [[String: Any]] ?? []
                self = .answer(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
            case "error", "aborted":
                self = .failure((message["errorMessage"] as? String).flatMap(Self.sentence))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The door's sentence in a failure as Pi writes a refused request's:
    /// its status, then the OpenAI error the door answered with
    /// (`formatProviderError` in Pi's bundle).
    static func sentence(_ error: String) -> String? {
        guard let match = error.wholeMatch(of: /\d{3}: (\{.*\})/.dotMatchesNewlines()),
            let object = try? JSONSerialization.jsonObject(with: Data(match.output.1.utf8)) as? [String: Any],
            let message = object["message"] as? String
        else { return nil }
        return message
    }
}
