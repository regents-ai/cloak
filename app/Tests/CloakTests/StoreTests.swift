import CloakChat
import CryptoKit
import Foundation
import Testing

/// The sealed conversations, in a folder of their own with keys made here:
/// never the real folder, never the keychain.
@Suite
struct StoreTests {
    let folder = URL(filePath: "/tmp").appending(path: "cloak-store-\(UUID().uuidString.prefix(8))/conversations")

    func store(_ key: SymmetricKey = SymmetricKey(size: .bits256)) -> ConversationStore {
        ConversationStore(folder: folder, key: key)
    }

    func file(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).conversation")
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    static let conversation = Conversation(turns: [
        Turn(original: "Please find my tax receipts from Barcelona", reworded: "Find the tax receipts from Barcelona."),
        Turn(original: "Also the ones from Lisbon", reworded: "Find the Lisbon receipts too."),
    ])

    @Test func whatIsSavedOpensAgainAndNothingIsReadableOnDisk() throws {
        defer { remove() }
        let store = store()
        let other = Conversation(turns: [Turn(original: "¿Dónde está?", reworded: "Localizar.")])
        try store.save(Self.conversation)
        try store.save(other)
        #expect(sorted(try store.load()) == sorted([.conversation(Self.conversation), .conversation(other)]))

        let sealed = try Data(contentsOf: file(Self.conversation.id))
        for word in ["Barcelona", "Lisbon", "receipts", "Please", "original", "reworded", "turns", Self.conversation.title] {
            #expect(sealed.range(of: Data(word.utf8)) == nil, "\(word)")
        }
        #expect(try FileManager.default.attributesOfItem(atPath: file(Self.conversation.id).path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        // Only the two files: nothing left over from writing them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    /// A chat with messages that went as written opens again as it was saved.
    @Test func turnsGoingAsWrittenOpenAgainAsSaved() throws {
        defer { remove() }
        let store = store()
        let conversation = Conversation(turns: [
            Turn(original: "Send this one just as I wrote it", reworded: nil, answer: "Sent."),
            Turn(original: "Please find my tax receipts from Barcelona", reworded: "Find the tax receipts from Barcelona."),
            Turn(original: "and the Lisbon ones as written", reworded: nil),
        ])
        try store.save(conversation)
        #expect(try store.load() == [.conversation(conversation)])
    }

    @Test func eachSaveHasAFreshNonce() throws {
        defer { remove() }
        let store = store()
        try store.save(Self.conversation)
        let first = try Data(contentsOf: file(Self.conversation.id))
        try store.save(Self.conversation)
        let second = try Data(contentsOf: file(Self.conversation.id))
        #expect(first.prefix(12) != second.prefix(12))
        #expect(first != second)
        #expect(try store.load() == [.conversation(Self.conversation)])
    }

    @Test func deleteRemovesTheFile() throws {
        defer { remove() }
        let store = store()
        try store.save(Self.conversation)
        try store.delete(Self.conversation.id)
        #expect(!FileManager.default.fileExists(atPath: file(Self.conversation.id).path))
        #expect(try store.load().isEmpty)
    }

    /// A file that does not open is shown as such and left exactly as it is;
    /// the others still open.
    @Test func aFileThatDoesNotOpenIsLeftAsItIs() throws {
        defer { remove() }
        let key = SymmetricKey(size: .bits256)
        let readable = Conversation(turns: [Turn(original: "Hello there", reworded: "Greet.")])
        try store(key).save(readable)
        // Sealed with another key.
        try store().save(Self.conversation)
        // Not sealed at all.
        let garbage = UUID()
        try Data("not a sealed box".utf8).write(to: file(garbage))
        // Sealed for one conversation, under another's name.
        let moved = Conversation(turns: [Turn(original: "Moved", reworded: "Moved.")])
        try store(key).save(moved)
        let swapped = UUID()
        try FileManager.default.moveItem(at: file(moved.id), to: file(swapped))
        // Other files are not conversations.
        try Data("x".utf8).write(to: folder.appending(path: "notes.txt"))

        let before = try [Self.conversation.id, garbage, swapped].map { try Data(contentsOf: file($0)) }
        #expect(sorted(try store(key).load())
            == sorted([.conversation(readable), .unreadable(Self.conversation.id), .unreadable(garbage), .unreadable(swapped)]))
        #expect(try [Self.conversation.id, garbage, swapped].map { try Data(contentsOf: file($0)) } == before)
    }

    /// A key is made only for an empty folder; a missing key over existing
    /// files, or a keychain that fails, makes none.
    @Test func noNewKeyIsMadeOverExistingFiles() async throws {
        defer { remove() }
        let key = SymmetricKey(size: .bits256)
        var made = 0
        let make = { () async throws -> SymmetricKey in
            made += 1
            return key
        }

        #expect(try await ConversationStore.key(for: folder, find: { nil }, make: make) == key)
        #expect(made == 1)

        try store(key).save(Self.conversation)
        #expect(try await ConversationStore.key(for: folder, find: { key }, make: make) == key)
        #expect(try await ConversationStore.key(for: folder, find: { nil }, make: make) == nil)
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            try await ConversationStore.key(for: folder, find: { throw Refused() }, make: make)
        }
        #expect(made == 1)
    }
}

/// Entries in the order of their ids, since a folder lists in no order.
func sorted(_ entries: [ConversationStore.Entry]) -> [ConversationStore.Entry] {
    func id(_ entry: ConversationStore.Entry) -> String {
        switch entry {
        case .conversation(let conversation): conversation.id.uuidString
        case .unreadable(let id): id.uuidString
        }
    }
    return entries.sorted { id($0) < id($1) }
}
