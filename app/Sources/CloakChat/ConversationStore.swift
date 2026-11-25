import CloakControl
import CryptoKit
import Foundation

/// Conversations on disk: one file each, `<id>.conversation`, sealed with
/// ChaChaPoly under one key, its combined form (nonce, ciphertext, tag) with
/// a fresh nonce on every write. The conversation's id is authenticated with
/// it, so one file cannot stand in for another. Nothing is on disk
/// unsealed: not a title, not a word. The folder is owner-only and each file
/// is written owner-only, then moved into place whole.
public struct ConversationStore: Sendable {
    public let folder: URL
    private let key: SymmetricKey

    static let suffix = ".conversation"

    /// A conversation file, opened or not.
    public enum Entry: Sendable, Equatable {
        case conversation(Conversation)
        /// The file is there and is left as it is: it does not open with
        /// this key, or what it holds is not a conversation.
        case unreadable(UUID)
    }

    public init(folder: URL, key: SymmetricKey) {
        self.folder = folder
        self.key = key
    }

    /// The conversations whose files are in `folder`, by id, opened or not.
    /// Other files are ignored.
    public static func ids(in folder: URL) throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap { name in
            guard name.hasSuffix(suffix) else { return nil }
            return UUID(uuidString: String(name.dropLast(suffix.count)))
        }
    }

    /// Every conversation file, opened where it opens.
    public func load() throws -> [Entry] {
        try Self.ids(in: folder).map { id in
            guard let sealed = try? Data(contentsOf: file(id)), let conversation = unseal(sealed, id) else {
                return .unreadable(id)
            }
            return .conversation(conversation)
        }
    }

    /// Seals the conversation and puts it in place of its file, whole: it is
    /// written to a new owner-only file first, then moved over the old one.
    public func save(_ conversation: Conversation) throws {
        try Places.makeOwnerOnly(folder)
        let sealed = try ChaChaPoly.seal(
            try JSONEncoder().encode(conversation), using: key, authenticating: Self.tag(conversation.id)
        ).combined
        try Self.replace(file(conversation.id), with: sealed)
    }

    /// Puts `data` in place of `file`, whole: written to a new owner-only
    /// file in the same folder first, then moved over the old one.
    package static func replace(_ file: URL, with data: Data) throws {
        let partial = file.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).partial")
        let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(partial.path, file.path) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Removes the conversation's file. One never saved, as with Saved chats
    /// off, has none, and nothing is removed.
    public func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: file(id))
        } catch CocoaError.fileNoSuchFile {}
    }

    func file(_ id: UUID) -> URL {
        folder.appending(path: id.uuidString + Self.suffix)
    }

    private func unseal(_ sealed: Data, _ id: UUID) -> Conversation? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
            let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.tag(id)),
            let conversation = try? JSONDecoder().decode(Conversation.self, from: plain), conversation.id == id
        else { return nil }
        return conversation
    }

    private static func tag(_ id: UUID) -> Data {
        Data(id.uuidString.utf8)
    }

    /// The key for the conversations in `folder` (and any sibling sealed files
    /// in `alsoSealed`, such as the Tempo deposit and Agents passes): the one
    /// `find` finds, or one `make` makes when none is found and no sealed file
    /// is there. Nil when the key is missing but sealed files are there: a new
    /// key over them would never open them, so none is made. `find` failing
    /// makes no key either.
    public static func key(
        for folder: URL, alsoSealed: [URL] = [],
        find: () async throws -> SymmetricKey?, make: () async throws -> SymmetricKey
    ) async throws -> SymmetricKey? {
        if let key = try await find() { return key }
        guard try ids(in: folder).isEmpty else { return nil }
        guard !alsoSealed.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return try await make()
    }
}
