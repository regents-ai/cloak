import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// What the Chat window holds: the saved conversations, the one shown, the
/// message being written, and the one rewording at a time. Nothing here is
/// sent anywhere; every turn is a draft.
@MainActor
@Observable
final class Chat {
    enum Access {
        case opening
        case open(ConversationStore)
        /// The key is missing while conversations are on disk, so none
        /// opens and no new key is made.
        case missingKey
        /// The keychain did not give the key, or the folder did not open.
        case failed
    }

    /// The one rewording under way.
    struct Rewording {
        let conversation: UUID
        let original: String
        /// The turn asked again, or nil for a new message.
        let turn: UUID?
        let started: Date
        let task: Task<Void, Never>
    }

    enum Problem {
        case save
        case delete
    }

    /// The last rewording that ended without a reworded text.
    struct Stop: Equatable {
        let reason: RewriteStop
        let newMessage: Bool
    }

    let supervisor: Supervisor
    let folder: URL
    private(set) var access = Access.opening
    /// Newest first.
    private(set) var conversations: [Conversation] = []
    /// Conversation files that did not open; they are left as they are.
    private(set) var unreadable: [UUID] = []
    var selection: UUID?
    /// The message being written.
    var draft = ""
    private(set) var rewording: Rewording?
    var stop: Stop?
    /// The last change to disk that failed.
    var problem: Problem?
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "chat")

    init(supervisor: Supervisor, folder: URL) {
        self.supervisor = supervisor
        self.folder = folder
    }

    var selected: Conversation? {
        conversations.first { $0.id == selection }
    }

    var isOpen: Bool {
        if case .open = access { true } else { false }
    }

    /// A new message can be written: the store is open and nothing is being
    /// reworded.
    var canCompose: Bool {
        isOpen && rewording == nil
    }

    /// Rewording needs Cloak running.
    var canReword: Bool {
        canCompose && supervisor.phase == .running
    }

    var canSubmit: Bool {
        canReword && !Self.isBlank(draft)
    }

    /// Finds the key, or makes the first one, then opens every conversation
    /// file. The keychain may ask first.
    func open() async {
        switch access {
        case .opening, .failed: break
        case .open, .missingKey: return
        }
        let folder = self.folder
        do {
            guard let key = try await ConversationStore.key(for: folder, find: Keychain.find, make: Keychain.make) else {
                logger.error("the conversations' key is missing; none is made over their files")
                unreadable = try ConversationStore.ids(in: folder)
                access = .missingKey
                return
            }
            let store = ConversationStore(folder: folder, key: key)
            var conversations = [Conversation](), unreadable = [UUID]()
            for entry in try store.load() {
                switch entry {
                case .conversation(let conversation): conversations.append(conversation)
                case .unreadable(let id): unreadable.append(id)
                }
            }
            if !unreadable.isEmpty { logger.error("\(unreadable.count) conversation files did not open; they are left as they are") }
            self.conversations = conversations.sorted { $0.created > $1.created }
            self.unreadable = unreadable
            access = .open(store)
            newConversation()
            selection = self.conversations.first?.id
        } catch {
            logger.error("cannot open the conversations: \(String(describing: error), privacy: .public)")
            access = .failed
        }
    }

    /// Shows the empty conversation, made if there is none. It is saved with
    /// its first turn.
    func newConversation() {
        guard isOpen else { return }
        if let empty = conversations.first(where: \.turns.isEmpty) {
            selection = empty.id
        } else {
            let conversation = Conversation()
            conversations.insert(conversation, at: 0)
            selection = conversation.id
        }
    }

    func delete(_ id: UUID) {
        guard case .open(let store) = access, let conversation = conversations.first(where: { $0.id == id }) else { return }
        if rewording?.conversation == id { rewording?.task.cancel() }
        if !conversation.turns.isEmpty {
            do {
                try store.delete(id)
            } catch {
                logger.error("cannot delete a conversation: \(String(describing: error), privacy: .public)")
                problem = .delete
                return
            }
        }
        conversations.removeAll { $0.id == id }
        if selection == id {
            selection = nil
            newConversation()
        }
    }

    /// Rewords the message written, as a new turn of the conversation shown.
    func submit() {
        let original = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, let conversation = selected else { return }
        draft = ""
        start(conversation.id, original, turn: nil)
    }

    /// Rewords a turn again, from its original.
    func reword(_ turn: Turn, in conversation: UUID) {
        guard canReword else { return }
        start(conversation, turn.original, turn: turn.id)
    }

    func cancel() {
        rewording?.task.cancel()
    }

    /// The reworded text as edited; saved as it changes.
    func edit(_ turn: UUID, in id: UUID, to text: String) {
        guard var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn }), conversation.turns[index].reworded != text
        else { return }
        conversation.turns[index].reworded = text
        update(conversation)
    }

    private func start(_ conversation: UUID, _ original: String, turn: UUID?) {
        stop = nil
        let task = Task { await reword(original, in: conversation, turn: turn) }
        rewording = Rewording(conversation: conversation, original: original, turn: turn, started: .now, task: task)
    }

    private func reword(_ original: String, in id: UUID, turn: UUID?) async {
        let result: Result<String, RewriteStop>
        do {
            result = .success(try await supervisor.rewrite(original))
        } catch {
            result = .failure(error)
        }
        rewording = nil
        // A conversation deleted meanwhile takes its rewording with it.
        guard var conversation = conversations.first(where: { $0.id == id }) else { return }
        switch result {
        case .success(let reworded):
            if let turn, let index = conversation.turns.firstIndex(where: { $0.id == turn }) {
                conversation.turns[index].reworded = reworded
            } else {
                conversation.turns.append(Turn(original: original, reworded: reworded))
            }
            update(conversation)
        case .failure(let reason):
            stop = Stop(reason: reason, newMessage: turn == nil)
            // The message goes back to be written again; it is never shown
            // as reworded.
            if turn == nil, draft.isEmpty { draft = original }
        }
    }

    /// Puts the conversation in place of its old self and saves it.
    private func update(_ conversation: Conversation) {
        guard case .open(let store) = access, let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        do {
            try store.save(conversation)
            problem = nil
        } catch {
            logger.error("cannot save a conversation: \(String(describing: error), privacy: .public)")
            problem = .save
        }
    }

    /// Blank as the daemon sees it: nothing but White_Space.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}
