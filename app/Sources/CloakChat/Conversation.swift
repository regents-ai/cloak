import Foundation

/// One chat: its messages, each as written and, unless it goes as written,
/// as reworded, in the order they were sent, those not yet sent where they
/// were added. Or, when its first turn is a task, a conversation with the
/// agent (decision 12): its tasks in the order they ran. Or, when its first
/// message went to NEAR, a NEAR Privacy conversation: each message as
/// written. Or, when its first message went to the model on this Mac, a
/// Llama Normal conversation: each message as written and its answer.
public struct Conversation: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let created: Date
    public var turns: [Turn]
    /// True once its first message went to NEAR (NEAR Privacy); absent
    /// otherwise. Every later message goes to NEAR too.
    public var near: Bool?
    /// True once its first message went to the model on this Mac (Llama
    /// Normal); absent otherwise. Every later message goes there too.
    public var llama: Bool?

    public init(id: UUID = UUID(), created: Date = .now, turns: [Turn] = []) {
        self.id = id
        self.created = created
        self.turns = turns
    }

    /// The first message's words, on one line.
    public var title: String {
        guard let first = turns.first else { return "New chat" }
        return first.original.split(whereSeparator: \.isWhitespace).prefix(16).joined(separator: " ")
    }

    /// A conversation with the agent: its first turn is a task.
    public var isAgent: Bool {
        turns.first?.steps != nil
    }

    /// A NEAR Privacy conversation: its first message went to NEAR.
    public var isNear: Bool {
        near == true
    }

    /// A Llama Normal conversation: its first message went to the model on
    /// this Mac.
    public var isLlama: Bool {
        llama == true
    }
}

/// One message: as written, as reworded then edited, and once it was sent,
/// the model's answer. A turn without an answer is a draft. Or one task for
/// the agent: as written, as the door reworded it, the steps it took, and
/// its answer once it finished; one without an answer did not finish.
public struct Turn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let original: String
    /// Nil when the message goes as written: its owner pressed Send Original
    /// Text on it, or wrote it with Never reword ticked.
    /// For a task, nil until the agent's first model request has gone
    /// through the door, which rewords it.
    public var reworded: String?
    public var answer: String?
    /// A task's steps, in the order the agent took them; nil for a message.
    public var steps: [Step]?

    public init(id: UUID = UUID(), original: String, reworded: String?, answer: String? = nil, steps: [Step]? = nil) {
        self.id = id
        self.original = original
        self.reworded = reworded
        self.answer = answer
        self.steps = steps
    }

    /// The text that is sent: the reworded one, or the original when the
    /// message goes as written.
    public var sent: String { reworded ?? original }
}

/// One tool the agent used: its name and, where it has one, what it worked
/// on.
public struct Step: Codable, Sendable, Equatable {
    public let tool: String
    /// The command for bash; the path for read, edit and write; nil for any
    /// other tool.
    public let detail: String?

    public init(tool: String, detail: String?) {
        self.tool = tool
        self.detail = detail
    }
}
