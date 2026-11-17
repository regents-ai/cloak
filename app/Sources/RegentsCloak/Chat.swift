import CloakChat
import CloakDoor
import CloakSupervisor
import Foundation
import Observation
import os

/// What the Chat window holds: the saved conversations, the one shown, the
/// message being written, the one rewording at a time, and the turns being
/// sent. A turn leaves this Mac as reworded, or as written when its owner
/// ticks Send Original for that message (decision 11 in docs/plan.md), and
/// only when its owner presses Send: in Development mode (decision 10)
/// through the guest's sender and Tor to a remote model, paid from the one
/// wallet. A conversation whose first message is a task is the agent's
/// (decision 12): each task runs when its owner presses Run, its model
/// requests reworded at the door.
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

    /// What one rewording is for.
    enum Asked {
        /// A new message, with the box as it was written, picks and all, to
        /// give back if the rewording stops.
        case new(draft: String, picks: DetailPicks)
        /// A turn asked again.
        case again(UUID)
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

    /// What a conversation is, fixed by its first message.
    enum Kind: Hashable {
        case chat
        case agent
    }

    let supervisor: Supervisor
    let agent: Agent
    let folder: URL
    let wallet: Wallet
    private(set) var access = Access.opening
    /// Newest first.
    private(set) var conversations: [Conversation] = []
    /// Conversation files that did not open; they are left as they are.
    private(set) var unreadable: [UUID] = []
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            picks = DetailPicks()
            askDetails()
        }
    }
    /// The message being written.
    var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            if Self.isBlank(draft) { picks = DetailPicks() }
            askDetails()
        }
    }
    /// The details of the message being written, from the model on this Mac
    /// (decision 13), and what is picked for them. Cleared when the draft is
    /// emptied or another conversation is shown; given back with the draft
    /// when a new message's rewording stops.
    private(set) var picks = DetailPicks()
    /// The details of the draft are being asked for.
    private(set) var askingDetails = false
    @ObservationIgnored private var detailsAsk: Task<Void, Never>?
    /// The next message goes as written, without rewording. In memory only:
    /// off at each launch.
    var sendOriginal = false
    /// What the empty conversation's first message makes it. In memory only:
    /// a chat at each launch.
    var kind = Kind.chat
    private(set) var rewording: Rewording?
    var stop: Stop?
    /// The unsent message last opened or added; see `isOpen(_:in:)`. In
    /// memory only.
    var opened: UUID?
    /// By turn.
    private(set) var sending: [UUID: Sending] = [:]
    var sendStop: SendStop?
    /// The last change to disk that failed.
    var problem: Problem?
    /// Each conversation's own Tor identity, so each has circuits of its
    /// own. In memory only: a conversation opened again gets a new one.
    @ObservationIgnored private var identities: [UUID: String] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "chat")

    init(supervisor: Supervisor, folder: URL, wallet: URL, door: Door) {
        self.supervisor = supervisor
        self.folder = folder
        self.wallet = Wallet(supervisor: supervisor, folder: wallet)
        let agent = Agent(parts: Agent.Parts(
            run: { supervisor.run($0) }, pass: { door.pass(for: $0) }, reworded: { door.reworded(for: $0) }))
        self.agent = agent
        // Each start of Cloak is a new guest, without the agent's earlier work.
        Task {
            for await running in Observations({ supervisor.phase == .running }) where running {
                agent.restarted()
            }
        }
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

    /// A message going as written is added without Cloak running; its card
    /// then says why Send is off. A task runs unless running it is certain
    /// to stop, or one runs in its conversation already.
    var canSubmit: Bool {
        guard let selected, !Self.isBlank(draft) else { return false }
        if isAgent(selected) { return isOpen && runBlock == nil && agent.runs[selected.id] == nil }
        return sendOriginal ? canCompose : canReword
    }

    /// Whether `conversation` is the agent's: as its first turn is, or, while
    /// it has none, as chosen.
    func isAgent(_ conversation: Conversation) -> Bool {
        conversation.turns.isEmpty ? kind == .agent : conversation.isAgent
    }

    /// Whether the agent of `conversation`, which has earlier tasks, starts
    /// without them: Cloak has started again since it last ran one.
    func startsFresh(_ conversation: Conversation) -> Bool {
        conversation.isAgent && agent.runs[conversation.id] == nil && !agent.ran.contains(conversation.id)
    }

    /// Whether `turn` is its conversation's open message, the one card that
    /// can be edited, reworded again and sent: the one last opened or added
    /// while it is not answered, otherwise the last message while it is not
    /// answered. Every other card is shrunk.
    func isOpen(_ turn: Turn, in conversation: Conversation) -> Bool {
        guard turn.answer == nil else { return false }
        if conversation.turns.contains(where: { $0.id == opened && $0.answer == nil }) { return turn.id == opened }
        return turn.id == conversation.turns.last?.id
    }

    /// Why Send is off for `turn` now, or nil when it is on. Off only where
    /// sending is certain to stop: a reworded text left blank; Cloak not
    /// running, so nothing is routed through Tor; no wallet; or, as the
    /// network last showed the wallet, no funds. A send under way never
    /// turns it off.
    func sendBlock(_ turn: Turn) -> String? {
        if let reworded = turn.reworded, Self.isBlank(reworded) { return "Reword it to send." }
        return switch block {
        case .notRunning?: "Start Cloak to send."
        case .noWallet?: "Create a wallet to send."
        case .noFunds?: "Add funds to send."
        case nil: nil
        }
    }

    /// Why Run is off now, or nil when it is on: off only where running is
    /// certain to stop, as for Send.
    var runBlock: String? {
        switch block {
        case .notRunning?: "Start Cloak to run."
        case .noWallet?: "Create a wallet to run."
        case .noFunds?: "Add funds to run."
        case nil: nil
        }
    }

    private var block: Block? {
        Block(running: supervisor.phase == .running, hasWallet: wallet.presence != .absent && wallet.presence != .creating, lacksFunds: wallet.lacksFunds)
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
        agent.stop(id)
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

    /// Rewords the message written, as a new turn of the conversation shown;
    /// or, with Send Original ticked, adds it as written and sends it; or, in
    /// the agent's conversation, runs it as its next task.
    /// The message goes with a line for each detail picked.
    func submit() {
        let (written, picked) = (draft, picks)
        let original = picked.message(written.trimmingCharacters(in: .whitespacesAndNewlines))
        guard canSubmit, var conversation = selected else { return }
        draft = ""
        if isAgent(conversation) {
            run(original, in: conversation.id)
        } else if sendOriginal {
            let turn = Turn(original: original, reworded: nil)
            conversation.turns.append(turn)
            opened = turn.id
            update(conversation)
            send(turn.id, in: conversation.id)
        } else {
            start(conversation.id, original, .new(draft: written, picks: picked))
        }
    }

    /// Rewords a turn again, or for the first time if it was to go as
    /// written, from its original, until it is sent.
    func reword(_ turn: Turn, in conversation: UUID) {
        guard canReword, turn.answer == nil, sending[turn.id] == nil else { return }
        start(conversation, turn.original, .again(turn.id))
    }

    func cancel() {
        rewording?.task.cancel()
    }

    /// Runs a task that ended without an answer again, as a new turn.
    func runAgain(_ turn: Turn, in id: UUID) {
        guard runBlock == nil else { return }
        run(turn.original, in: id)
    }

    private func run(_ task: String, in id: UUID) {
        agent.run(task, in: id, model: wallet.model) { [weak self] turn in
            guard let self else { return }
            keep(turn, in: id)
            // A task that ended may have paid for its model requests.
            if agent.runs[id] == nil { Task { await wallet.refresh() } }
        }
    }

    /// Puts a task's turn in its conversation, in place of its old self or at
    /// the end, and saves it. A conversation deleted meanwhile takes it with
    /// it.
    private func keep(_ turn: Turn, in id: UUID) {
        guard var conversation = conversations.first(where: { $0.id == id }) else { return }
        if let index = conversation.turns.firstIndex(where: { $0.id == turn.id }) {
            conversation.turns[index] = turn
        } else {
            conversation.turns.append(turn)
        }
        update(conversation)
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

    /// Sends the turn, reworded or as written, after the conversation's
    /// earlier turns as sent and answered, and keeps the answer with it.
    /// A turn sent after later ones moves to the end first, so the
    /// conversation is in the order its turns were sent and each request is
    /// the one before it plus more. Each press is sent; one under way never
    /// stops another.
    func send(_ turn: UUID, in id: UUID) {
        guard let deposits = wallet.deposits, var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn }), sendBlock(conversation.turns[index]) == nil
        else { return }
        if index != conversation.turns.count - 1 {
            conversation.turns.append(conversation.turns.remove(at: index))
            update(conversation)
        }
        sendStop = nil
        let identity = identities[id] ?? Self.newIdentity()
        identities[id] = identity
        if sending[turn] == nil { sending[turn] = Sending(started: .now) } else { sending[turn]?.presses += 1 }
        let (model, exchange) = (wallet.model, wallet.exchange)
        Task { [conversation] in
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

    /// Picks for a detail of the message being written, or clears its pick.
    /// The first pick fixes the details shown, so none are asked for until
    /// they are cleared.
    func pick(_ pick: DetailPicks.Pick?, at index: Int) {
        picks.pick(pick, at: index)
        if picks.fixed { stopAskingDetails() }
    }

    /// Once the draft has rested a moment, asks the model on this Mac for its
    /// details, in place of any request before. Not while something is
    /// picked, nor unless the draft has a few words, Cloak is running and
    /// nothing is being reworded. An answer that does not come shows
    /// nothing.
    private func askDetails() {
        stopAskingDetails()
        guard !picks.fixed, Details.enoughToAsk(draft) else { return }
        let draft = draft
        detailsAsk = Task {
            guard (try? await Task.sleep(for: Self.draftRest)) != nil, canReword, !picks.fixed else { return }
            askingDetails = true
            let details = try? await supervisor.details(for: draft)
            guard !Task.isCancelled else { return }
            askingDetails = false
            if let details { picks.show(details) }
        }
    }

    /// How long the draft rests unchanged before its details are asked for.
    private static let draftRest = Duration.milliseconds(1200)

    private func stopAskingDetails() {
        detailsAsk?.cancel()
        detailsAsk = nil
        askingDetails = false
    }

    private func start(_ conversation: UUID, _ original: String, _ asked: Asked) {
        // A rewrite never waits on a details request.
        stopAskingDetails()
        stop = nil
        let task = Task { await reword(original, in: conversation, asked) }
        let turn: UUID? = if case .again(let turn) = asked { turn } else { nil }
        rewording = Rewording(conversation: conversation, original: original, turn: turn, started: .now, task: task)
    }

    private func reword(_ original: String, in id: UUID, _ asked: Asked) async {
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
            if case .again(let turn) = asked, let index = conversation.turns.firstIndex(where: { $0.id == turn }) {
                conversation.turns[index].reworded = reworded
            } else {
                let new = Turn(original: original, reworded: reworded)
                conversation.turns.append(new)
                opened = new.id
            }
            update(conversation)
        case .failure(let reason):
            guard case .new(let written, let picked) = asked else {
                stop = Stop(reason: reason, newMessage: false)
                return
            }
            stop = Stop(reason: reason, newMessage: true)
            // The message goes back into the box as it was written, its picks
            // with it, to be written again; it is never shown as reworded. The
            // picks go first, so the draft finds them fixed and no new
            // details are asked for.
            if draft.isEmpty {
                picks = picked
                draft = written
            }
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
