import Foundation

/// One chat: its messages, each as written and, unless it goes as written,
/// as reworded, oldest first.
public struct Conversation: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let created: Date
    public var turns: [Turn]

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
}

/// One message: as written, as reworded then edited, and once it was sent,
/// the model's answer. A turn without an answer is a draft.
public struct Turn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let original: String
    /// Nil when the message goes as written: its owner ticked Send Original.
    public var reworded: String?
    public var answer: String?

    public init(id: UUID = UUID(), original: String, reworded: String?, answer: String? = nil) {
        self.id = id
        self.original = original
        self.reworded = reworded
        self.answer = answer
    }

    /// The text that is sent: the reworded one, or the original when the
    /// message goes as written.
    public var sent: String { reworded ?? original }
}
