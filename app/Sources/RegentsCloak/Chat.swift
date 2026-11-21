import CloakChat
import CloakDoor
import CloakSupervisor
import Foundation
import Observation
import os

/// What the Chat window holds: the saved conversations, the one shown, the
/// message being written, the one rewording at a time, and the turns being
/// sent. A conversation's first message fixes its mode (`Kind`). In V and
/// Token Inference, a turn leaves this Mac as reworded, or as written when
/// its owner presses Send Original Text on it or has Never reword ticked
/// (decision 11 in docs/plan.md), and only when its owner presses a Send,
/// or, with Review off, the box's Send, which sends it once it is reworded:
/// through Tor to a remote model, a V chat's paid through zkAPI by the
/// guest's payer, a new key for each request (`Payer`, decision 24), a
/// Token Inference chat's through the guest's sender from the one Tempo
/// wallet (`Wallet`, decisions 10 and 25). In either, a conversation whose
/// first message is a task is the agent's (decisions 12 and 26): each task
/// runs when its owner presses Run, its model requests reworded at the door
/// and paid as its chat's are. A conversation whose first message went to
/// NEAR is NEAR's (`NearMode`): each message goes there as written, at
/// once, paid by the owner's NEAR key. A conversation whose first message
/// went to the model on this Mac is Local Llama's: each message goes there
/// as written, with the conversation so far, and nothing leaves this Mac
/// (`Supervisor.answer`). With Saved chats off, a conversation started or
/// continued is kept in memory only (`unsaved`).
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
        /// give back if the rewording stops, and the mode it was written in.
        case new(draft: String, picks: DetailPicks, mode: Kind)
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
        let stop: Reason

        /// Why, from the way it was paid.
        enum Reason: Error {
            /// Token Inference's, from the Tempo wallet.
            case tempo(RemoteStop)
            /// V's, through the payer.
            case zkapi(PayStop)

            var code: String {
                switch self {
                case .tempo(let stop): stop.code.rawValue
                case .zkapi(let stop): stop.code.rawValue
                }
            }

            var detail: String {
                switch self {
                case .tempo(let stop): stop.detail
                case .zkapi(let stop): stop.detail
                }
            }
        }
    }

    /// The last rewording that ended without a reworded text.
    struct Stop: Equatable {
        let reason: RewriteStop
        let newMessage: Bool
    }

    /// A Local Llama answer under way.
    struct Answering {
        let turn: UUID
        let started: Date
        let task: Task<Void, Never>
    }

    /// A conversation's mode, fixed by its first message.
    enum Kind: Hashable {
        case v
        case token
        case near
        case llama

        /// Whether its chats can be the agent's.
        var hasAgent: Bool {
            self == .v || self == .token
        }
    }

    let supervisor: Supervisor
    /// Read here for Never reword, Review and Saved chats.
    let settings: AppSettings
    let agent: Agent
    let folder: URL
    /// Token Inference's wallet.
    let wallet: Wallet
    /// V's.
    let payer: Payer
    let nearMode: NearMode
    /// One download for each model that answers Local Llama chats, the
    /// least memory first: read here for whether the chosen one is on this
    /// Mac, which a Local Llama chat needs.
    let downloads: [ModelDownload]
    private(set) var access = Access.opening
    /// Newest first.
    private(set) var conversations: [Conversation] = []
    /// Conversation files that did not open; they are left as they are.
    private(set) var unreadable: [UUID] = []
    /// The conversations started or continued while Saved chats was off:
    /// none of their changes is written, for as long as Cloak runs, even
    /// once it is on again, so what was said while it was off never reaches
    /// the disk. One saved before keeps its file as it was then.
    private(set) var unsaved: Set<UUID> = []
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
    /// The mode the empty conversation's first message puts it in. In
    /// memory only: V at each launch.
    var kind = Kind.v
    /// Whether the empty conversation's first message is a task, in a mode
    /// with the agent. In memory only: off at each launch.
    var agentOn = false
    /// The wallet sheet is shown, for the conversation in front.
    var showingWallet = false
    /// The Modes page is shown.
    var showingModes = false
    private(set) var rewording: Rewording?
    var stop: Stop?
    /// The unsent message last opened or added; see `isOpen(_:in:)`. In
    /// memory only.
    var opened: UUID?
    /// By turn.
    private(set) var sending: [UUID: Sending] = [:]
    var sendStop: SendStop?
    /// The Local Llama answer under way, by conversation: one at a time in
    /// each.
    private(set) var answering: [UUID: Answering] = [:]
    /// Why each Local Llama message last asked has no answer, by turn. In
    /// memory only.
    private(set) var answerStops: [UUID: AnswerStop] = [:]
    /// The last change to disk that failed.
    var problem: Problem?
    /// Each conversation's own Tor identity, so each has circuits of its
    /// own. In memory only: a conversation opened again gets a new one.
    @ObservationIgnored private var identities: [UUID: String] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "chat")

    init(
        supervisor: Supervisor, settings: AppSettings, folder: URL, wallet: URL, queue: PayQueue, door: Door,
        nearMode: NearMode, downloads: [ModelDownload]
    ) {
        self.supervisor = supervisor
        self.settings = settings
        self.folder = folder
        self.wallet = Wallet(supervisor: supervisor, folder: wallet)
        let payer = Payer(
            queue: queue, running: { supervisor.phase == .running }, expiry: settings.depositExpires,
            keep: { settings.depositExpires = $0 }, chosen: { settings.vModel })
        self.payer = payer
        self.nearMode = nearMode
        self.downloads = downloads
        let agent = Agent(parts: Agent.Parts(
            run: { supervisor.run($0) }, pass: { door.pass(for: $0, paying: $1) }, reworded: { door.reworded(for: $0) }))
        self.agent = agent
        Task {
            for await running in Observations({ supervisor.phase == .running }) {
                // Each start of Cloak is a new guest, without the agent's
                // earlier work.
                if running { agent.restarted() }
                // V's deposit is read as Cloak starts, and forgotten as it
                // stops.
                payer.follow()
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

    /// With Never reword ticked, a message is added without Cloak running;
    /// its card then says why Send is off. A task runs unless running it is
    /// certain to stop, or one runs in its conversation already. A NEAR
    /// message goes unless sending it is certain to stop. A Local Llama
    /// message is asked unless asking is certain to stop (`llamaBlock`), or
    /// the model is answering in its conversation already.
    var canSubmit: Bool {
        guard let selected, !Self.isBlank(draft) else { return false }
        let mode = kind(of: selected)
        if isAgent(selected) { return isOpen && runBlock(in: mode) == nil && agent.runs[selected.id] == nil }
        if mode == .near { return isOpen && nearMode.sendBlock == nil }
        if mode == .llama { return isOpen && llamaBlock == nil && answering[selected.id] == nil }
        return settings.neverReword ? canCompose : canReword
    }

    /// The mode of `conversation`: as its first message made it, or, while
    /// it has none, as chosen. A saved conversation with no mark is V's.
    func kind(of conversation: Conversation) -> Kind {
        guard !conversation.turns.isEmpty else { return kind }
        if conversation.isNear { return .near }
        if conversation.isLlama { return .llama }
        return conversation.isToken ? .token : .v
    }

    /// Whether `conversation` is the agent's: as its first turn is, or, while
    /// it has none, as chosen.
    func isAgent(_ conversation: Conversation) -> Bool {
        conversation.turns.isEmpty ? agentOn && kind.hasAgent : conversation.isAgent
    }

    func isNear(_ conversation: Conversation) -> Bool {
        kind(of: conversation) == .near
    }

    func isLlama(_ conversation: Conversation) -> Bool {
        kind(of: conversation) == .llama
    }

    /// Marks `conversation`, while it is empty, with `mode`, as its first
    /// turn goes in; a V conversation has no mark.
    private func mark(_ conversation: inout Conversation, as mode: Kind) {
        guard conversation.turns.isEmpty else { return }
        conversation.token = mode == .token ? true : nil
        conversation.near = mode == .near ? true : nil
        conversation.llama = mode == .llama ? true : nil
    }

    /// The download of the model chosen to answer Local Llama chats
    /// (`AppSettings.answerModel`); nil when the name chosen is not one this
    /// release lists.
    var answerDownload: ModelDownload? {
        let name = settings.answerModel ?? supervisor.manifest.model
        return downloads.first { $0.model.name == name }
    }

    /// Why a Local Llama message is certain to stop if asked now.
    enum LlamaBlock {
        /// The model chosen is not one this release has.
        case unknown
        /// This Mac can't run the model chosen.
        case mac(ModelDownload)
        /// The model chosen is not on this Mac.
        case missing(ModelDownload)

        var words: String {
            switch self {
            case .unknown: "Choose a model in Settings."
            case .mac: "This Mac can't run the chosen model."
            case .missing: "Download the model to ask."
            }
        }
    }

    /// Why a Local Llama message can't be asked now, or nil when it can: off
    /// only where asking is certain to stop. Another model never answers in
    /// the chosen one's place. Cloak need not be running.
    var llamaBlock: LlamaBlock? {
        guard let download = answerDownload else { return .unknown }
        guard download.fits else { return .mac(download) }
        return download.state == .installed ? nil : .missing(download)
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

    /// Why Send is off for `turn`, in a chat of `mode`, now, or nil when it
    /// is on. Off only where sending is certain to stop: a reworded text
    /// left blank; Cloak not running, so nothing is routed through Tor; in
    /// Token Inference, no wallet, or, as the network last showed the
    /// wallet, no funds; in V, the chain at the latest block read showing
    /// the deposit closed. A V send with no deposit goes, and the payer
    /// answers it. A send under way never turns it off.
    func sendBlock(_ turn: Turn, in mode: Kind) -> String? {
        if let reworded = turn.reworded, Self.isBlank(reworded) { return "Reword it to send." }
        return originalBlock(in: mode)
    }

    /// Why Send Original Text is off now, or nil when it is on: Send's
    /// reasons but a blank reworded text, which it does not send.
    func originalBlock(in mode: Kind) -> String? {
        switch block(in: mode) {
        case .notRunning?: "Start Cloak to send."
        case .noWallet?: "Create a wallet to send."
        case .noFunds?: "Add funds to send."
        case .closed?: "Deposit closed."
        case nil: nil
        }
    }

    /// Why Run is off now, or nil when it is on: off only where running is
    /// certain to stop, as for Send.
    func runBlock(in mode: Kind) -> String? {
        switch block(in: mode) {
        case .notRunning?: "Start Cloak to run."
        case .noWallet?: "Create a wallet to run."
        case .noFunds?: "Add funds to run."
        case .closed?: "Deposit closed."
        case nil: nil
        }
    }

    private func block(in mode: Kind) -> Block? {
        let running = supervisor.phase == .running
        return mode == .token
            ? Block(running: running, hasWallet: wallet.presence != .absent && wallet.presence != .creating, lacksFunds: wallet.lacksFunds)
            : Block(running: running, closed: payer.closed)
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

    /// A new chat whose message box holds `text`, exactly as if typed there
    /// (the quick prompt's): nothing is sent or reworded. Before the store
    /// opens, the text waits for the empty conversation it opens on.
    func compose(_ text: String) {
        kind = .v
        agentOn = false
        newConversation()
        draft = text
    }

    func delete(_ id: UUID) {
        guard case .open(let store) = access, let conversation = conversations.first(where: { $0.id == id }) else { return }
        if rewording?.conversation == id { rewording?.task.cancel() }
        answering[id]?.task.cancel()
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
        unsaved.remove(id)
        if selection == id {
            selection = nil
            newConversation()
        }
    }

    /// Rewords the message written, as a new turn of the conversation shown,
    /// sent once reworded when Review is off;
    /// or, with Never reword ticked, adds it as written and sends it, the
    /// model on this Mac not asked; or, in the agent's conversation, runs it
    /// as its next task; or, in a NEAR conversation, adds it as written and
    /// sends it to NEAR; or, in a Local Llama conversation, adds it as
    /// written and asks the model on this Mac. The message goes with a line
    /// for each detail picked, but to NEAR and Local Llama, which get it as
    /// written.
    func submit() {
        let (written, picked) = (draft, picks)
        let original = picked.message(written.trimmingCharacters(in: .whitespacesAndNewlines))
        guard canSubmit, var conversation = selected else { return }
        draft = ""
        let mode = kind(of: conversation)
        if isAgent(conversation) {
            run(original, in: conversation.id)
        } else if mode == .near {
            let turn = Turn(original: written.trimmingCharacters(in: .whitespacesAndNewlines), reworded: nil)
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            opened = turn.id
            update(conversation)
            send(turn.id, in: conversation.id)
        } else if mode == .llama {
            let turn = Turn(original: written.trimmingCharacters(in: .whitespacesAndNewlines), reworded: nil)
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            update(conversation)
            ask(turn.id, in: conversation.id)
        } else if settings.neverReword {
            let turn = Turn(original: original, reworded: nil)
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            opened = turn.id
            update(conversation)
            send(turn.id, in: conversation.id)
        } else {
            start(conversation.id, original, .new(draft: written, picks: picked, mode: mode))
        }
    }

    /// Rewords a turn again, or for the first time if it was to go as
    /// written, from its original, until it is sent. It never sends, Review
    /// on or off.
    func reword(_ turn: Turn, in conversation: UUID) {
        guard canReword, turn.answer == nil, sending[turn.id] == nil else { return }
        start(conversation, turn.original, .again(turn.id))
    }

    func cancel() {
        rewording?.task.cancel()
    }

    /// Runs a task that ended without an answer again, as a new turn.
    func runAgain(_ turn: Turn, in id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }), runBlock(in: kind(of: conversation)) == nil
        else { return }
        run(turn.original, in: id)
    }

    /// Runs a task, its model requests paid as its chat's are: a V chat's
    /// through the payer, with V's model, a Token Inference chat's from the
    /// Tempo wallet, with its model. The first task marks its conversation
    /// with its mode, saved with its turn.
    private func run(_ task: String, in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let mode = kind(of: conversations[index])
        mark(&conversations[index], as: mode)
        let kept: (Turn) -> Void = { [weak self] turn in
            guard let self else { return }
            keep(turn, in: id)
            // A task that ended may have paid for its model requests.
            guard agent.runs[id] == nil else { return }
            if mode == .token { Task { await wallet.refresh() } } else { payer.follow() }
        }
        guard mode == .v else {
            agent.run(task, in: id, model: wallet.model, paying: .tempo, keep: kept)
            return
        }
        Task {
            do throws(PayStop) {
                let model = try await payer.modelForSend()
                agent.run(task, in: id, model: model, paying: .zkapi, keep: kept)
            } catch {
                logger.error("V's models did not read: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
                let words = error.code == .modelUnavailable
                    ? "The service lists no model now. Try again later." : "Cloak couldn't read V's models. Try again."
                agent.refuse(task, .failed(words), keep: kept)
            }
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

    /// Sends the turn as written, in place of its reworded text, which is
    /// dropped: from then on it is a turn that goes as written, shown with
    /// its Original alone, and sent so again after it is answered (decision
    /// 11). Each press is sent, as for Send.
    func sendOriginal(_ turn: UUID, in id: UUID) {
        guard var conversation = conversations.first(where: { $0.id == id }), originalBlock(in: kind(of: conversation)) == nil,
            let index = conversation.turns.firstIndex(where: { $0.id == turn }), conversation.turns[index].answer == nil
        else { return }
        conversation.turns[index].reworded = nil
        update(conversation)
        send(turn, in: id)
    }

    /// Sends the turn, reworded or as written, after the conversation's
    /// earlier turns as sent and answered, and keeps the answer with it.
    /// A turn sent after later ones moves to the end first, so the
    /// conversation is in the order its turns were sent and each request is
    /// the one before it plus more. Each press is sent; one under way never
    /// stops another. A NEAR conversation's turn goes to NEAR only; a V
    /// conversation's through the payer only, in the owner's turn; a Token
    /// Inference conversation's to the Tempo wallet's provider only.
    func send(_ turn: UUID, in id: UUID) {
        guard var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        if conversation.isNear {
            guard nearMode.sendBlock == nil, let route = nearMode.route else { return }
            press(turn, at: index, in: &conversation)
            Task { [conversation] in
                let answer = await nearMode.send(turn, in: conversation, route: route)
                sent(turn, in: id, answer: answer?.text, tokens: answer?.tokens)
            }
            return
        }
        let mode = kind(of: conversation)
        guard sendBlock(conversation.turns[index], in: mode) == nil else { return }
        if mode == .token {
            guard let deposits = wallet.deposits else { return }
            press(turn, at: index, in: &conversation)
            sendStop = nil
            let identity = identity(of: id)
            let (model, exchange) = (wallet.model, wallet.exchange)
            Task { [conversation] in
                let result: Result<String, SendStop.Reason>
                do throws(RemoteStop) {
                    result = .success(try await Remote.send(
                        turn, in: conversation, model: model, identity: identity,
                        key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange))
                } catch {
                    result = .failure(.tempo(error))
                }
                finish(turn, in: id, result)
                await wallet.refresh()
            }
            return
        }
        press(turn, at: index, in: &conversation)
        sendStop = nil
        let identity = identity(of: id)
        Task { [conversation] in
            let result: Result<String, SendStop.Reason>
            do throws(PayStop) {
                result = .success(try await payer.send(turn, in: conversation, identity: identity))
            } catch {
                result = .failure(.zkapi(error))
            }
            finish(turn, in: id, result)
            // Its settlement, and the deposit's new balance.
            payer.follow()
        }
    }

    /// The conversation's own Tor identity, made the first time.
    private func identity(of id: UUID) -> String {
        let identity = identities[id] ?? Self.newIdentity()
        identities[id] = identity
        return identity
    }

    private func finish(_ turn: UUID, in id: UUID, _ result: Result<String, SendStop.Reason>) {
        if case .failure(let reason) = result {
            logger.error("a send stopped: \(reason.code, privacy: .public) \(reason.detail, privacy: .private)")
            sendStop = SendStop(turn: turn, stop: reason)
        }
        sent(turn, in: id, answer: try? result.get(), tokens: nil)
    }

    /// Moves a turn sent after later ones to the end, and counts the press.
    private func press(_ turn: UUID, at index: Int, in conversation: inout Conversation) {
        if index != conversation.turns.count - 1 {
            conversation.turns.append(conversation.turns.remove(at: index))
            update(conversation)
        }
        if sending[turn] == nil { sending[turn] = Sending(started: .now) } else { sending[turn]?.presses += 1 }
    }

    /// One press of Send on the turn ended; its answer, when one came, is
    /// kept with it, and with it the tokens NEAR counted for that answer,
    /// in place of an earlier answer's. A conversation deleted meanwhile
    /// takes its answer with it.
    private func sent(_ turn: UUID, in id: UUID, answer: String?, tokens: Tokens?) {
        if let presses = sending[turn]?.presses, presses > 1 { sending[turn]?.presses -= 1 } else { sending[turn] = nil }
        guard let answer, var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        conversation.turns[index].answer = answer
        conversation.turns[index].tokens = tokens
        update(conversation)
    }

    /// Asks the chosen model on this Mac to answer a Local Llama
    /// conversation's turn, after its earlier turns as written and answered,
    /// and keeps the answer with it, or why none came. One at a time in a
    /// conversation.
    func ask(_ turn: UUID, in id: UUID) {
        guard answering[id] == nil, llamaBlock == nil, let model = answerDownload?.model,
            let conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        let messages = conversation.turns[..<index].flatMap { earlier in earlier.answer.map { [earlier.original, $0] } ?? [] }
            + [conversation.turns[index].original]
        answerStops[turn] = nil
        let task = Task {
            let result: Result<String, AnswerStop>
            do throws(AnswerStop) {
                result = .success(try await supervisor.answer(messages, with: model))
            } catch {
                result = .failure(error)
            }
            answered(turn, in: id, result)
        }
        answering[id] = Answering(turn: turn, started: .now, task: task)
    }

    /// Stops the Local Llama answer under way in the conversation.
    func stopAnswer(in id: UUID) {
        answering[id]?.task.cancel()
    }

    /// A Local Llama answer ended: kept with its turn, or why it has none.
    /// A conversation deleted meanwhile takes it with it.
    private func answered(_ turn: UUID, in id: UUID, _ result: Result<String, AnswerStop>) {
        answering[id] = nil
        guard var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        switch result {
        case .success(let answer):
            conversation.turns[index].answer = answer
            update(conversation)
        case .failure(let stop):
            answerStops[turn] = stop
        }
    }

    /// 32 random bytes, as hex: Tor's user name for one conversation, or for
    /// NEAR's or Intel's connections in NEAR mode.
    static func newIdentity() -> String {
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
    /// nothing is being reworded, nor in a NEAR or Local Llama
    /// conversation. An answer that does not come shows nothing.
    private func askDetails() {
        stopAskingDetails()
        guard !picks.fixed, Details.enoughToAsk(draft), selected.map({ isNear($0) || isLlama($0) }) != true else { return }
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
            let turn: UUID
            if case .again(let again) = asked, let index = conversation.turns.firstIndex(where: { $0.id == again }) {
                conversation.turns[index].reworded = reworded
                turn = again
            } else {
                if case .new(_, _, let mode) = asked { mark(&conversation, as: mode) }
                let new = Turn(original: original, reworded: reworded)
                conversation.turns.append(new)
                opened = new.id
                turn = new.id
            }
            update(conversation)
            // A new message, with Review off, goes now, as if Send were
            // pressed: through the same checks, so one certain to stop stays
            // open, saying why. A card's Reword only rewords.
            if case .new = asked, !settings.review { send(turn, in: id) }
        case .failure(let reason):
            guard case .new(let written, let picked, _) = asked else {
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

    /// Puts the conversation in place of its old self and saves it, unless
    /// Saved chats is off now or was off at one of its changes since Cloak
    /// opened (`unsaved`).
    private func update(_ conversation: Conversation) {
        guard case .open(let store) = access, let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        guard settings.savedChats, !unsaved.contains(conversation.id) else {
            unsaved.insert(conversation.id)
            return
        }
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
