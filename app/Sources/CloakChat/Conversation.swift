import Foundation

/// One chat: its messages, each as written and as reworded, oldest first.
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

/// One message: as written, and as reworded then edited. Nothing is sent yet,
/// so every turn is a draft.
public struct Turn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let original: String
    public var reworded: String

    public init(id: UUID = UUID(), original: String, reworded: String) {
        self.id = id
        self.original = original
        self.reworded = reworded
    }
}
