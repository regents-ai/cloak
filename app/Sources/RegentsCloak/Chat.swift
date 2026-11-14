import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// What the Chat window holds: the saved conversations, the one shown, the
/// message being written, the one rewording at a time, and the turns being
/// sent. A turn leaves this Mac only as reworded, and only when its owner
/// presses Send: in Development mode (decision 10 in docs/plan.md) through
/// the guest's sender and Tor to a remote model, paid from the one wallet.
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

    /// The presses of Send on one turn still under way.
    struct Sending {
        let started: Date
        var presses = 1
    }

    /// The last send that stopped.
    struct SendStop {
        let turn: UUID
        let stop: RemoteStop
    }

    /// The last rewording that ended without a reworded text.
    struct Stop: Equatable {
        let reason: RewriteStop
        let newMessage: Bool
    }

    let supervisor: Supervisor
    let folder: URL
    let wallet: Wallet
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
    /// By turn.
    private(set) var sending: [UUID: Sending] = [:]
    var sendStop: SendStop?
    /// The last change to disk that failed.
    var problem: Problem?
    /// Each conversation's own Tor identity, so each has circuits of its
    /// own. In memory only: a conversation opened again gets a new one.
    @ObservationIgnored private var identities: [UUID: String] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "chat")

    init(supervisor: Supervisor, folder: URL, wallet: URL) {
        self.supervisor = supervisor
        self.folder = folder
        self.wallet = Wallet(supervisor: supervisor, folder: wallet)
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

    /// Why Send is off for `turn` now, or nil when it is on. Off only where
    /// sending is certain to stop: nothing reworded to send; Cloak not
    /// running, so nothing is routed through Tor; no wallet; or, as the
    /// network last showed the wallet, no funds. A send under way never
    /// turns it off.
    func sendBlock(_ turn: Turn) -> String? {
        if Self.isBlank(turn.reworded) { return "Reword it to send." }
        if supervisor.phase != .running { return "Start Cloak to send." }
        if wallet.address == nil { return "Create a wallet to send." }
        if wallet.lacksFunds { return "Add funds to send." }
        return nil
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
            wallet.deposits = DepositStore(folder: wallet.folder, key: key)
            await wallet.find()
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
        identities[id] = nil
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

    /// Rewords a turn again, from its original, until it is sent.
    func reword(_ turn: Turn, in conversation: UUID) {
        guard canReword, turn.answer == nil, sending[turn.id] == nil else { return }
        start(conversation, turn.original, turn: turn.id)
    }

    func cancel() {
        rewording?.task.cancel()
    }

    /// The reworded text as edited, until it is sent; saved as it changes.
    func edit(_ turn: UUID, in id: UUID, to text: String) {
        guard sending[turn] == nil, var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn }), conversation.turns[index].answer == nil,
            conversation.turns[index].reworded != text
        else { return }
        conversation.turns[index].reworded = text
        update(conversation)
    }

    /// Sends the turn as reworded, after the conversation's earlier turns as
    /// sent and answered, and keeps the answer with it. Each press is sent;
    /// one under way never stops another.
    func send(_ turn: UUID, in id: UUID) {
        guard let deposits = wallet.deposits, let conversation = conversations.first(where: { $0.id == id }),
            let current = conversation.turns.first(where: { $0.id == turn }), sendBlock(current) == nil
        else { return }
        sendStop = nil
        let identity = identities[id] ?? Self.newIdentity()
        identities[id] = identity
        if sending[turn] == nil { sending[turn] = Sending(started: .now) } else { sending[turn]?.presses += 1 }
        let (model, exchange) = (wallet.model, wallet.exchange)
        Task {
            let result: Result<String, RemoteStop>
            do throws(RemoteStop) {
                result = .success(try await Remote.send(
                    turn, in: conversation, model: model, identity: identity,
                    key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange))
            } catch {
                result = .failure(error)
            }
            finish(turn, in: id, result)
        }
    }

    private func finish(_ turn: UUID, in id: UUID, _ result: Result<String, RemoteStop>) {
        if let presses = sending[turn]?.presses, presses > 1 { sending[turn]?.presses -= 1 } else { sending[turn] = nil }
        switch result {
        case .success(let answer):
            // A conversation deleted meanwhile takes its answer with it.
            if var conversation = conversations.first(where: { $0.id == id }),
                let index = conversation.turns.firstIndex(where: { $0.id == turn })
            {
                conversation.turns[index].answer = answer
                update(conversation)
            }
        case .failure(let stop):
            logger.error("a send stopped: \(stop.code.rawValue, privacy: .public) \(stop.detail, privacy: .public)")
            sendStop = SendStop(turn: turn, stop: stop)
        }
        Task { await wallet.refresh() }
    }

    /// 32 random bytes, as hex: Tor's user name for one conversation.
    private static func newIdentity() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    private func start(_ conversation: UUID, _ original: String, turn: UUID?) {
        stop = nil
        let task = Task { await reword(original, in: conversation, turn: turn) }
        rewording = Rewording(conversation: conversation, original: original, turn: turn, started: .now, task: task)
    }

    private func reword(_ original: String, in id: UUID, turn: UUID?) async {
        let result: Result<String, RewriteStop>
        do {
            result = .success(try await supervisor.rewrite([original])[0])
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
