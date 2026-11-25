import Foundation

/// One chat: its messages, each as written and, unless it goes as written,
/// as reworded, in the order they were sent, those not yet sent where they
/// were added. Or, when its first turn is a task, a conversation with the
/// agent (decision 12): its tasks in the order they ran. A V conversation,
/// chat or agent, is paid through zkAPI; one whose first message or task
/// went the Token Inference way is paid from the Tempo wallet (decision 25).
/// Or, when its first message went to NEAR, a NEAR Private AI conversation:
/// each message as written, its answer, and the tokens NEAR counted for it.
/// Or, when its first message went to the model on this Mac, a Local Llama
/// conversation: each message as written and its answer.
public struct Conversation: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let created: Date
    public var turns: [Turn]
    /// True once its first message or task went the Token Inference way,
    /// paid from the Tempo wallet; absent otherwise, as in every V
    /// conversation. Every later one goes that way too.
    public var token: Bool?
    /// Set once its first message went to Venice inside Pay-Per-Prompt: its
    /// model, tier and way to pay, never changed after. Absent otherwise.
    public var venice: VeniceChat?
    /// True once its first message went to NEAR (NEAR Private AI); absent
    /// otherwise. Every later message goes to NEAR too.
    public var near: Bool?
    /// True once its first message went to the model on this Mac (Local
    /// Llama); absent otherwise. Every later message goes there too.
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

    /// A Token Inference conversation: its first message or task went that
    /// way.
    public var isToken: Bool {
        token == true
    }

    /// A Token Inference conversation whose first message went to Venice.
    public var isVenice: Bool {
        venice != nil
    }

    /// A NEAR Private AI conversation: its first message went to NEAR.
    public var isNear: Bool {
        near == true
    }

    /// A Local Llama conversation: its first message went to the model on
    /// this Mac.
    public var isLlama: Bool {
        llama == true
    }

    /// The tokens NEAR counted for this chat's answers, added up; nil while
    /// no answer has counts.
    public var tokens: Tokens? {
        let counted = turns.compactMap(\.tokens)
        guard !counted.isEmpty else { return nil }
        return Tokens(input: counted.map(\.input).reduce(0, +), output: counted.map(\.output).reduce(0, +))
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
    /// Internal reasoning/thinking returned by reasoning models (e.g. Inkling 2
    /// Mini) for this turn, kept encrypted with the chat so subsequent turns
    /// send `reasoning_content` back through the model's chat template. Never
    /// shown in the visible message bubble.
    public var thinking: String?
    /// A task's steps, in the order the agent took them; nil for a message.
    public var steps: [Step]?
    /// The tokens NEAR counted for the answer, as its reply gave them; nil
    /// for every other mode's turn, and for a NEAR answer whose reply had
    /// none that read.
    public var tokens: Tokens?
    /// Local files explicitly attached to this Local Mode turn (metadata only,
    /// kept so the message card shows what was attached).
    public var attachments: [AttachedFile]?

    public init(
        id: UUID = UUID(), original: String, reworded: String?, answer: String? = nil, thinking: String? = nil,
        steps: [Step]? = nil, attachments: [AttachedFile]? = nil
    ) {
        self.id = id
        self.original = original
        self.reworded = reworded
        self.answer = answer
        self.thinking = thinking
        self.steps = steps
        self.attachments = attachments
    }

    /// The text that is sent: the reworded one, or the original when the
    /// message goes as written.
    public var sent: String { reworded ?? original }
}

/// Tokens as NEAR counts them for one answer: in, the message with the chat
/// before it, as sent; out, the answer. Or, added up, a chat's.
public struct Tokens: Codable, Sendable, Equatable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }
}

/// Display metadata for a local file attached to a Local Mode turn.
public struct AttachedFile: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let kind: String
    public let truncated: Bool

    public init(id: UUID = UUID(), name: String, kind: String, truncated: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.truncated = truncated
    }
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
