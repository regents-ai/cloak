import AppKit
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
    /// The saved chats' one stage, so one open runs at a time.
    enum Access {
        /// Before the first open.
        case unopened
        /// Finding the key and reading the files: the first time, or
        /// `again` after they did not open.
        case opening(again: Bool)
        case open(ConversationStore)
        /// The key is missing while conversations are on disk, so none
        /// opens and no new key is made.
        case missingKey
        /// The keychain did not give the key, or the folder did not open;
        /// `again` when trying again did not open them either.
        case failed(again: Bool)
    }

    /// The one rewording under way, in all chats: one model on this Mac.
    struct Rewording {
        let conversation: UUID
        let original: String
        let asked: Asked
        let started: Date
        let task: Task<Void, Never>

        /// The turn asked again, or nil for a new message.
        var turn: UUID? {
            if case .again(let turn) = asked { turn } else { nil }
        }
    }

    /// What one rewording is for.
    enum Asked {
        /// A new message, with the box as it was written, picks and all, to
        /// give back if the rewording stops; the mode it was written in; and
        /// whether it is sent once reworded, as its press said: the box's
        /// Send, with Review off, rather than its Reword.
        case new(draft: String, picks: DetailPicks, mode: Kind, sends: Bool)
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

    /// Why a turn's last send stopped, kept with the turn until its next
    /// press of Send. Dismissing it hides its row only, so the card still
    /// says whether that send may have gone.
    struct SendStop {
        let reason: Reason
        var dismissed = false

        /// Why, from the way it was paid.
        enum Reason: Error {
            /// Token Inference's Boundless/Tempo wallet.
            case tempo(RemoteStop)
            /// Pay-Per-Prompt's Venice provider (Base USDC or Venice key).
            case venice(VeniceStop)
            /// Paranoid (V)'s zkAPI payer.
            case zkapi(PayStop)
            /// Private Cloud (NEAR), with the owner's NEAR key.
            case near(NearStop)

            var code: String {
                switch self {
                case .tempo(let stop): stop.code.rawValue
                case .venice(let stop): stop.kind.rawValue
                case .zkapi(let stop): stop.code.rawValue
                case .near(let stop): stop.kind.rawValue
                }
            }

            var detail: String {
                switch self {
                case .tempo(let stop): stop.detail
                case .venice(let stop): stop.text
                case .zkapi(let stop): stop.detail
                case .near(let stop): stop.text
                }
            }

            /// Whether the message may have reached the model, or been paid
            /// for, as the stop's own words say: the model answered with no
            /// text, or no answer came after the request went.
            var mayHaveGone: Bool {
                switch self {
                case .tempo(let stop): stop.code == .answerRefused
                case .venice(let stop): stop.sent
                case .zkapi(let stop): [.providerFailed, .answerRefused, .timedOut, .ended].contains(stop.code)
                case .near(let stop): stop.sent
                }
            }
        }
    }

    /// A rewording that ended without a reworded text, kept with its
    /// conversation until dismissed or the conversation's next rewording.
    struct Stop {
        let reason: RewriteStop
        /// The turn asked again, whose card says so; nil for a new message,
        /// which the box says so for.
        let turn: UUID?
        /// The new message's box, until it goes back into the box: at once
        /// when its conversation is shown as the rewording ends, else when
        /// it is next shown.
        var back: Back?
    }

    /// A new message's box as it was written.
    struct Back {
        let draft: String
        let picks: DetailPicks
    }

    /// A Local Llama answer under way, including live lifecycle stage and streamed partial text.
    struct Answering {
        let turn: UUID
        let started: Date
        var stage: LocalAnswerStage
        var didColdStart: Bool
        var partial = ""
        let task: Task<Void, Never>
    }

    /// An auto-start triggered by pressing Send/Run while Cloak was paused
    /// (Decision R3b), waiting for Cloak to reach `.running` before proceeding.
    struct AutoStart {
        let conversation: UUID
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
    /// Boundless / Tempo wallet.
    let wallet: Wallet
    /// Venice (Base USDC / optional key), the default Pay-Per-Prompt provider (Decision N5.1b).
    let veniceMode: VeniceMode
    /// Paranoid (V) zkAPI payer.
    let payer: Payer
    let nearMode: NearMode
    /// One download for each model that answers Local Llama chats, the
    /// least memory first: read here for whether the chosen one is on this
    /// Mac, which a Local Llama chat needs.
    let downloads: [ModelDownload]
    /// Optional 44 MB uncensored LoRA adapter downloads, keyed by adapter name.
    let adapterDownloads: [String: ModelDownload]
    private(set) var access = Access.unopened
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
            localAttachments = []
            localAttachmentError = nil
            askDetails()
            giveBack()
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
    /// Local-only file, PDF, document, or OCR'd image attachments for the next
    /// Local Mode turn. Cleared automatically when switching conversations,
    /// switching away from Local Mode, or submitting a turn so local files are
    /// never attached to cloud chats.
    var localAttachments: [LocalAttachment] = []
    var localAttachmentError: String?
    var attachingLocalFiles = false
    @ObservationIgnored private var turnLocalAttachments: [UUID: [LocalAttachment]] = [:]
    /// The details of the message being written, from the model on this Mac
    /// (decision 13), and what is picked for them. Cleared when the draft is
    /// emptied or another conversation is shown; given back with the draft
    /// when a new message's rewording stops (`giveBack`).
    private(set) var picks = DetailPicks()
    /// The details of the draft are being asked for.
    private(set) var askingDetails = false
    @ObservationIgnored private var detailsAsk: Task<Void, Never>?
    /// The mode the empty conversation's first message puts it in. Defaults to
    /// Local on first launch (Decision R2b) so new users can start immediately
    /// without wallets, keys, or Tor. In memory only.
    var kind = Kind.llama {
        didSet {
            if kind != oldValue {
                if kind != .llama {
                    localAttachments = []
                    localAttachmentError = nil
                }
                askDetails()
            }
        }
    }
    /// Whether the empty conversation's first message is a task, in a mode
    /// with the agent. In memory only: off at each launch.
    var agentOn = false {
        didSet {
            if agentOn != oldValue { askDetails() }
        }
    }
    /// Called when an answer completes in any mode (Local, NEAR, Token Inference,
    /// Anon V, or Agent) so the menu bar can highlight an unread reply if Chat
    /// is not currently in front.
    @ObservationIgnored var onAnswerArrived: ((UUID) -> Void)?
    /// The Funds sheet is shown, for the conversation in front.
    var showingWallet = false
    /// The 3-step hardware-aware Welcome Tour sheet is shown.
    var showingTour = false
    /// Step to open the Welcome Tour on (`0` by default; `2` when opened from Local Agent Box).
    var tourStep = 0

    func openTour(step: Int = 0) {
        tourStep = step
        showingTour = true
    }
    private(set) var rewording: Rewording?
    /// An inline auto-start under way after pressing Send/Run while paused.
    private(set) var autoStarting: AutoStart?
    @ObservationIgnored private var expiryGuard: ExpiryGuard?
    /// By conversation. In memory only.
    var stops: [UUID: Stop] = [:]
    /// The unsent message last opened or added; see `isOpen(_:in:)`. In
    /// memory only.
    var opened: UUID?
    /// By turn.
    private(set) var sending: [UUID: Sending] = [:]
    /// In-flight send tasks, by turn, so deleting a chat cancels them cleanly.
    @ObservationIgnored private var sendTasks: [UUID: Task<Void, Never>] = [:]
    /// By turn. In memory only.
    var sendStops: [UUID: SendStop] = [:]
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
        nearMode: NearMode, downloads: [ModelDownload], adapterDownloads: [String: ModelDownload] = [:]
    ) {
        self.supervisor = supervisor
        self.settings = settings
        self.folder = folder
        self.wallet = Wallet(supervisor: supervisor, folder: wallet)
        let veniceMode = VeniceMode(supervisor: supervisor, settings: settings)
        self.veniceMode = veniceMode
        let payer = Payer(
            queue: queue, running: { supervisor.phase == .running }, expiry: settings.depositExpires,
            keep: { settings.depositExpires = $0 }, chosen: { settings.vModel })
        self.payer = payer
        self.nearMode = nearMode
        self.downloads = downloads
        self.adapterDownloads = adapterDownloads
        let agent = Agent(parts: Agent.Parts(
            run: { supervisor.run($0) }, pass: { door.pass(for: $0, paying: $1) }, reworded: { door.reworded(for: $0) }))
        self.agent = agent
        self.expiryGuard = ExpiryGuard(payer: payer, settings: settings)
        Task {
            for await running in Observations({ supervisor.phase == .running }) {
                // Each start of Cloak is a new guest, without the agent's
                // earlier work.
                if running {
                    agent.restarted()
                    Task { await veniceMode.refresh() }
                    Task { try? await payer.loadModels() }
                }
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

    /// The download of the model that rewords, which every Start needs.
    var rewordingDownload: ModelDownload {
        // The manifest lists the model that rewords among those that answer
        // Local Llama chats (decision 21).
        downloads.first(where: \.rewords)!
    }

    /// The best Local answer model that fits this Mac's memory:
    /// Prefers the fast pure-Swift vMLX Inkling 2 Mini (10.2 GB JANGH2, 60+ tok/s,
    /// fits 16 GB+ Macs) when bundled, falling back to the largest fitting GGUF
    /// tier (Unsloth 13.6 GB on 24 GB Macs, Xylolabs NVFP4 17.6 GB on >=32 GB
    /// Macs, or Qwen 3.5 9B on 16 GB Macs without vMLX).
    var recommendedLocalDownload: ModelDownload {
        downloads.last(where: { $0.fits && $0.model.engine == .vmlx })
            ?? downloads.last(where: \.fits)
            ?? rewordingDownload
    }

    /// Selects and starts downloading the recommended Local model for this Mac.
    func downloadRecommendedLocalModel() {
        let target = recommendedLocalDownload
        settings.answerModel = target.rewords ? nil : target.model.name
        target.start()
    }

    /// Whether pressing Send/Run while paused can automatically start Cloak
    /// inline (Decision R3b): paused or ready, rewording model already on disk,
    /// and no auto-start already in flight.
    var canAutoStart: Bool {
        (supervisor.phase == .paused || supervisor.phase == .ready)
            && rewordingDownload.state == .installed
            && autoStarting == nil
    }

    /// Whether Cloak is either running now or ready to auto-start on Send.
    private var runningOrCanAutoStart: Bool {
        supervisor.phase == .running || canAutoStart
    }

    /// Rewording needs the store open, Cloak running (or ready to auto-start)
    /// and no rewording under way in any chat: one model on this Mac.
    var canReword: Bool {
        isOpen && rewording == nil && autoStarting == nil && runningOrCanAutoStart
    }

    /// With Never reword ticked, a message is added without Cloak running;
    /// its card then says why Send is off. A task runs unless running it is
    /// certain to stop, or one runs in its conversation already. A NEAR
    /// message goes unless sending it is certain to stop (auto-starting Cloak
    /// if Tor is on and Cloak is paused). A Local message is asked unless
    /// asking is certain to stop (`llamaBlock`), or the model is answering in
    /// its conversation already.
    var canSubmit: Bool {
        guard let selected, autoStarting == nil else { return false }
        let mode = kind(of: selected)
        if mode == .llama {
            let hasContent = !Self.isBlank(draft) || !localAttachments.isEmpty
            return hasContent && isOpen && llamaBlock == nil && answering[selected.id] == nil
        }
        guard !Self.isBlank(draft) else { return false }
        if isAgent(selected) { return isOpen && runBlock(in: mode) == nil && agent.runs[selected.id] == nil }
        if mode == .near {
            return isOpen && (nearMode.sendBlock == nil || (nearMode.hasKey == true && nearMode.route == nil && canAutoStart))
        }
        return settings.neverReword ? isOpen : canReword
    }

    /// Attaches one or more local PDF, document, image (OCR), or text/code files
    /// to the next Local Mode turn. Extraction runs off the main thread so PDF
    /// parsing and on-device Vision OCR never block the UI.
    func attachLocalFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        localAttachmentError = nil
        attachingLocalFiles = true
        let targetConversation = selection
        Task { [weak self] in
            let outcome: ([LocalAttachment], [String]) = await Task.detached(priority: .userInitiated) {
                var items: [LocalAttachment] = []
                var errors: [String] = []
                for url in urls {
                    do {
                        items.append(try LocalAttachment.from(url: url))
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                }
                return (items, errors)
            }.value
            guard let self else { return }
            self.attachingLocalFiles = false
            // Drop results if the user switched conversations or left Local Mode while reading.
            guard self.selection == targetConversation,
                let selected = self.selected, self.kind(of: selected) == .llama
            else { return }
            for item in outcome.0 {
                self.localAttachments.removeAll { $0.name == item.name && $0.kind == item.kind }
                self.localAttachments.append(item)
            }
            if !outcome.1.isEmpty {
                self.localAttachmentError = outcome.1.joined(separator: " ")
            }
        }
    }

    func removeLocalAttachment(_ id: UUID) {
        localAttachments.removeAll { $0.id == id }
    }

    /// Whether the shown chat's messages would be reworded while another
    /// chat's rewording runs, so its box says so, with Cancel: a V or Token
    /// Inference chat that is not the agent's, with Never reword off.
    var rewordsElsewhere: Bool {
        guard !settings.neverReword, let selected, let rewording, rewording.conversation != selected.id else { return false }
        let mode = kind(of: selected)
        return (mode == .v || mode == .token) && !isAgent(selected)
    }

    /// The mode of `conversation`: as its first message made it, or, while
    /// it has none, as the one being reworded was written in, or as chosen.
    /// A saved conversation with no mark is V's.
    func kind(of conversation: Conversation) -> Kind {
        guard !conversation.turns.isEmpty else { return firstMode(of: conversation.id) ?? kind }
        if conversation.isNear { return .near }
        if conversation.isLlama { return .llama }
        return conversation.isToken ? .token : .v
    }

    /// Whether `conversation` is the agent's: as its first turn is, or, while
    /// it has none, as chosen, unless its first message is being reworded.
    func isAgent(_ conversation: Conversation) -> Bool {
        conversation.turns.isEmpty ? firstMode(of: conversation.id) == nil && agentOn && kind.hasAgent : conversation.isAgent
    }

    /// The mode the first message of the conversation, being reworded now,
    /// was written in: chosen at its press, whatever is chosen since for
    /// another new chat.
    private func firstMode(of id: UUID) -> Kind? {
        guard let rewording, rewording.conversation == id, case .new(_, _, let mode, _) = rewording.asked else { return nil }
        return mode
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
    /// (`AppSettings.answerModel`). When no model is explicitly picked yet,
    /// defaults to `recommendedLocalDownload` unless the rewording model is
    /// already installed and the recommended model is not. Also migrates away
    /// cleanly if a saved model name was retired in a newer release.
    var answerDownload: ModelDownload? {
        if let chosen = settings.answerModel {
            return downloads.first { $0.model.name == chosen } ?? recommendedLocalDownload
        }
        if recommendedLocalDownload.state == .installed || rewordingDownload.state != .installed {
            return recommendedLocalDownload
        }
        return rewordingDownload
    }

    /// Strips a leading `vendor/` prefix from a model identifier for compact
    /// titlebar/header display while preserving the model's full name.
    static func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Provider label shown beside the model name where a mode routes to a
    /// named remote provider.
    func activeProviderName(for mode: Kind, conversation: Conversation? = nil) -> String? {
        switch mode {
        case .llama, .v: nil
        case .near: "NEAR"
        case .token: usesVenice(for: conversation) ? "Venice" : "Boundless"
        }
    }

    /// Concise active model label for `mode` and `conversation`, always non-empty
    /// so users can glance at what model will answer in every mode.
    func activeModelName(for mode: Kind, conversation: Conversation? = nil) -> String {
        switch mode {
        case .llama:
            guard let label = answerDownload?.model.label else { return "No model" }
            return activeUnfilteredLora != nil ? "\(label) · Unfiltered" : label
        case .near:
            return Near.displayModel
        case .token:
            if usesVenice(for: conversation) {
                if let pinnedID = conversation?.venice?.model {
                    if let live = veniceMode.models?.first(where: { $0.id == pinnedID }) {
                        return live.name
                    }
                    if settings.veniceModel?.id == pinnedID, let savedName = settings.veniceModel?.name {
                        return savedName
                    }
                    return Self.shortModelName(pinnedID)
                }
                if let choice = veniceMode.effectiveChoice {
                    return choice.name
                }
                return "Auto"
            }
            return Self.shortModelName(wallet.model)
        case .v:
            if let live = payer.model {
                return Self.shortModelName(live)
            }
            if let chosen = settings.vModel, !chosen.isEmpty {
                return Self.shortModelName(chosen)
            }
            return "Auto"
        }
    }

    /// Full model identifier shown inside the mode popover and tooltips.
    func activeModelFullName(for mode: Kind, conversation: Conversation? = nil) -> String {
        switch mode {
        case .llama:
            guard let model = answerDownload?.model else { return "No local model selected" }
            return activeUnfilteredLora != nil ? "\(model.label) (Unfiltered LoRA)" : model.label
        case .near:
            return Near.model
        case .token:
            if usesVenice(for: conversation) {
                if let pinnedID = conversation?.venice?.model {
                    if let live = veniceMode.models?.first(where: { $0.id == pinnedID }) {
                        return "\(live.name) (\(live.id))"
                    }
                    return pinnedID
                }
                if let choice = veniceMode.effectiveChoice {
                    return "\(choice.name) (\(choice.id))"
                }
                return "Auto (first available Private/TEE model once Cloak starts)"
            }
            return wallet.model
        case .v:
            if let live = payer.model {
                return live
            }
            if let chosen = settings.vModel, !chosen.isEmpty {
                return chosen
            }
            return "Auto (lowest-cost zkAPI model once Cloak starts)"
        }
    }

    /// The optional 44 MB uncensored LoRA adapter for the currently selected
    /// Local model when `settings.unfilteredLocal` is enabled; nil otherwise.
    var activeUnfilteredLora: Manifest.Model.Adapter? {
        guard settings.unfilteredLocal, let adapter = answerDownload?.model.unfilteredLora else { return nil }
        return adapter
    }

    /// Why a Local Llama message is certain to stop if asked now.
    enum LlamaBlock {
        /// The model chosen is not one this release has.
        case unknown
        /// This Mac can't run the model chosen.
        case mac(ModelDownload)
        /// The model (or its optional Unfiltered adapter) is not on this Mac.
        case missing(ModelDownload)

        @MainActor var words: String {
            switch self {
            case .unknown: "Choose a model in Settings."
            case .mac: "This Mac can't run the chosen model."
            case .missing(let download):
                download.model.memory == 0 ? "Download the Unfiltered adapter to ask." : "Download the model to ask."
            }
        }
    }

    /// Why a Local Llama message can't be asked now, or nil when it can: off
    /// only where asking is certain to stop. Another model never answers in
    /// the chosen one's place. Cloak need not be running.
    var llamaBlock: LlamaBlock? {
        guard let download = answerDownload else { return .unknown }
        guard download.fits else { return .mac(download) }
        guard download.state == .installed else { return .missing(download) }
        if let adapter = activeUnfilteredLora, let adapterDownload = adapterDownloads[adapter.name],
            adapterDownload.state != .installed
        {
            return .missing(adapterDownload)
        }
        return nil
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
    /// Whether Token Inference currently routes to Venice (`settings.payProvider == .venice`).
    /// Toggling between Venice and Boundless works both before the first message and mid-chat.
    func usesVenice(for conversation: Conversation?) -> Bool {
        settings.payProvider == .venice
    }

    /// Switches the active Token Inference provider (Venice ↔ Boundless) and
    /// warms the newly selected provider's state when Cloak is running.
    func selectPayProvider(_ provider: PayProvider) {
        guard settings.payProvider != provider else { return }
        settings.payProvider = provider
        guard supervisor.phase == .running else { return }
        Task {
            switch provider {
            case .boundless:
                await wallet.refresh()
            case .venice:
                if veniceMode.models == nil {
                    await veniceMode.refresh()
                }
            }
        }
    }

    func sendBlock(_ turn: Turn, in mode: Kind) -> String? {
        if let reworded = turn.reworded, Self.isBlank(reworded) { return "Reword it to send." }
        return originalBlock(in: mode)
    }

    /// Why Send Original Text is off now, or nil when it is on: Send's
    /// reasons but a blank reworded text, which it does not send.
    func originalBlock(in mode: Kind) -> String? {
        if mode == .token, usesVenice(for: selected) {
            return veniceMode.sendBlock(for: selected, canAutoStart: canAutoStart)
        }
        return switch block(in: mode) {
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

    /// Whether Send and Run are off for a reason Funds fixes: no wallet,
    /// no funds, no Venice key, or a deposit closed.
    func walletBlocks(in mode: Kind) -> Bool {
        if mode == .token, usesVenice(for: selected) {
            return veniceMode.walletBlocks(for: selected)
        }
        return switch block(in: mode) {
        case .noWallet?, .noFunds?, .closed?: true
        case .notRunning?, nil: false
        }
    }

    private func block(in mode: Kind) -> Block? {
        let running = runningOrCanAutoStart
        return mode == .token
            ? Block(running: running, hasWallet: wallet.presence.address != nil, lacksFunds: wallet.lacksFunds)
            : Block(running: running, closed: payer.closed)
    }

    /// Finds the key, or makes the first one, then opens every conversation
    /// file. The keychain may ask first. After a failure it tries again;
    /// while an open is under way, and once they are open or locked, it
    /// does nothing.
    func open() async {
        let again: Bool
        switch access {
        case .unopened: again = false
        case .failed, .missingKey: again = true
        case .opening, .open: return
        }
        access = .opening(again: again)
        let folder = self.folder
        do {
            guard let key = try await ConversationStore.key(
                for: folder,
                alsoSealed: [wallet.folder.appending(path: "deposit"), Launch.layout.agents],
                find: Keychain.find, make: Keychain.make)
            else {
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
            access = .failed(again: again)
        }
    }

    /// Shows the empty conversation, made if there is none. It is saved with
    /// its first turn. One whose first message is being reworded is not
    /// empty for this.
    func newConversation() {
        guard isOpen else { return }
        if let empty = conversations.first(where: { $0.turns.isEmpty && $0.id != rewording?.conversation }) {
            selection = empty.id
        } else {
            let conversation = Conversation()
            conversations.insert(conversation, at: 0)
            selection = conversation.id
        }
    }

    /// The quick prompt's Return: a new V chat whose box holds `text`, as if
    /// typed there; nothing is sent or reworded. An empty Return changes
    /// nothing here. The box is one for every chat and follows a change of
    /// chat, so what it holds stays, `text` after it: its picks first go on
    /// as lines of its text, as a change of chat clears them, and a message
    /// given back to the new chat (`giveBack`) joins it. Before the store
    /// opens, the text waits for the empty conversation it opens on.
    func compose(_ text: String) {
        guard !Self.isBlank(text) else { return }
        agentOn = false
        let held = picks.message(draft)
        if held != draft {
            picks = DetailPicks()
            draft = held
        }
        newConversation()
        draft = Self.isBlank(draft) ? text : draft + "\n\n" + text
    }

    /// Switches the active mode (bound to Command-1 through Command-4).
    /// If viewing a non-empty thread, opens a fresh empty chat in `mode` first.
    func selectMode(_ mode: Kind) {
        guard isOpen else { return }
        if selected?.turns.isEmpty != true {
            newConversation()
        }
        kind = mode
    }

    /// Deletes whichever non-empty or unreadable thread is currently selected
    /// (bound to Command-Shift-Delete). Empty "New chat" placeholders are left alone.
    func deleteSelected() {
        guard let id = selection else { return }
        if unreadable.contains(id) {
            deleteUnreadable(id)
            return
        }
        guard let selected = conversations.first(where: { $0.id == id }), !selected.turns.isEmpty else { return }
        delete(id)
    }

    func delete(_ id: UUID) {
        guard case .open(let store) = access, let removedIndex = conversations.firstIndex(where: { $0.id == id }) else { return }
        let conversation = conversations[removedIndex]
        if autoStarting?.conversation == id { stopAutoStart() }
        if rewording?.conversation == id { rewording?.task.cancel() }
        stops[id] = nil
        answering[id]?.task.cancel()
        veniceMode.stop(in: conversation)
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
        conversations.remove(at: removedIndex)
        for turn in conversation.turns {
            sendTasks.removeValue(forKey: turn.id)?.cancel()
            sending[turn.id] = nil
            sendStops[turn.id] = nil
            answerStops[turn.id] = nil
            turnLocalAttachments[turn.id] = nil
        }
        unsaved.remove(id)
        problem = nil
        if selection == id {
            // Select the prior (chronologically older) thread that slides into
            // `removedIndex`, or the nearest remaining non-empty thread above
            // it, so repeated Command-Shift-Delete presses chain cleanly.
            if removedIndex < conversations.count, !conversations[removedIndex].turns.isEmpty {
                selection = conversations[removedIndex].id
            } else if let above = conversations[..<min(removedIndex, conversations.count)].last(where: { !$0.turns.isEmpty }) {
                selection = above.id
            } else if let firstNonEmpty = conversations.first(where: { !$0.turns.isEmpty }) {
                selection = firstNonEmpty.id
            } else {
                selection = nil
                newConversation()
            }
        }
    }

    /// Deletes a conversation file that could not be opened/decrypted so
    /// corrupted entries don't stay stuck in the sidebar permanently.
    func deleteUnreadable(_ id: UUID) {
        guard case .open(let store) = access, let removedIndex = unreadable.firstIndex(of: id) else { return }
        do {
            try store.delete(id)
            unreadable.remove(at: removedIndex)
            problem = nil
            if selection == id {
                if removedIndex < unreadable.count {
                    selection = unreadable[removedIndex]
                } else if let previous = unreadable.last {
                    selection = previous
                } else if let lastChat = conversations.last(where: { !$0.turns.isEmpty }) {
                    selection = lastChat.id
                } else {
                    selection = nil
                    newConversation()
                }
            }
        } catch {
            logger.error("cannot delete an unreadable conversation: \(String(describing: error), privacy: .public)")
            problem = .delete
        }
    }

    /// Cancels an in-flight auto-start-on-send and pauses Cloak.
    func stopAutoStart() {
        autoStarting?.task.cancel()
        autoStarting = nil
        if supervisor.phase.state == .preparing {
            supervisor.send(.pause)
        }
    }

    /// Auto-starts Cloak inline (Decision R3b) and runs `work` once Cloak
    /// reaches `.running`. If startup fails or is cancelled, runs `onAbort`.
    private func startThen(in id: UUID, onAbort: @escaping @MainActor () -> Void = {}, work: @escaping @MainActor () -> Void) {
        if supervisor.phase == .running {
            work()
            return
        }
        guard canAutoStart else {
            onAbort()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.supervisor.send(.start)
            var sawPreparing = false
            for await phase in Observations({ self.supervisor.phase }) {
                if Task.isCancelled {
                    onAbort()
                    return
                }
                if phase == .running {
                    self.autoStarting = nil
                    work()
                    return
                }
                if phase.state == .preparing {
                    sawPreparing = true
                    continue
                }
                if sawPreparing || phase.state == .needsAttention {
                    self.autoStarting = nil
                    onAbort()
                    return
                }
            }
        }
        autoStarting = AutoStart(conversation: id, started: .now, task: task)
    }

    /// Rewords the message written, as a new turn of the conversation shown,
    /// sent once reworded when Review is off at the press;
    /// or, with Never reword ticked, adds it as written and sends it, the
    /// model on this Mac not asked; or, in the agent's conversation, runs it
    /// as its next task; or, in a NEAR conversation, adds it as written and
    /// sends it to NEAR; or, in a Local conversation, adds it as written and
    /// asks the model on this Mac. If Cloak is paused and a Tor/V/Pay-Per-Prompt
    /// mode needs it, automatically starts Cloak inline first (Decision R3b).
    func submit() {
        let (written, picked) = (draft, picks)
        let original = picked.message(written.trimmingCharacters(in: .whitespacesAndNewlines))
        guard canSubmit, var conversation = selected else { return }
        draft = ""
        let id = conversation.id
        let mode = kind(of: conversation)
        let restoreDraft: @MainActor () -> Void = { [weak self] in
            guard let self, self.conversations.contains(where: { $0.id == id }) else { return }
            if Self.isBlank(self.draft) {
                self.picks = picked
                self.draft = written
            } else {
                self.draft += "\n\n" + picked.message(written)
            }
        }
        if isAgent(conversation) {
            startThen(in: id, onAbort: restoreDraft) { [weak self] in
                self?.run(original, in: id)
            }
        } else if mode == .near {
            let turn = Turn(original: written.trimmingCharacters(in: .whitespacesAndNewlines), reworded: nil)
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            opened = turn.id
            update(conversation)
            send(turn.id, in: id)
        } else if mode == .llama {
            let attachments = localAttachments
            localAttachments = []
            localAttachmentError = nil
            let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
            let messageText = trimmed.isEmpty && !attachments.isEmpty
                ? "Summarize the attached local files."
                : trimmed
            let turn = Turn(
                original: messageText,
                reworded: nil,
                attachments: attachments.isEmpty
                    ? nil
                    : attachments.map { AttachedFile(id: $0.id, name: $0.name, kind: $0.kind.rawValue, truncated: $0.truncated) })
            if !attachments.isEmpty {
                turnLocalAttachments[turn.id] = attachments
            }
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            update(conversation)
            ask(turn.id, in: id)
        } else if settings.neverReword {
            let turn = Turn(original: original, reworded: nil)
            mark(&conversation, as: mode)
            conversation.turns.append(turn)
            opened = turn.id
            update(conversation)
            send(turn.id, in: id)
        } else {
            let sends = !settings.review
            startThen(in: id, onAbort: restoreDraft) { [weak self] in
                self?.start(id, original, .new(draft: written, picks: picked, mode: mode, sends: sends))
            }
        }
    }

    /// Rewords a turn again, or for the first time if it was to go as
    /// written, from its original, until it is sent. It never sends, Review
    /// on or off.
    func reword(_ turn: Turn, in conversation: UUID) {
        guard canReword, turn.answer == nil, sending[turn.id] == nil else { return }
        startThen(in: conversation) { [weak self] in
            self?.start(conversation, turn.original, .again(turn.id))
        }
    }

    /// Cancels the rewording under way, in whichever chat it is.
    func cancel() {
        rewording?.task.cancel()
    }

    /// Runs a task that ended without an answer again, as a new turn.
    func runAgain(_ turn: Turn, in id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }), runBlock(in: kind(of: conversation)) == nil
        else { return }
        startThen(in: id) { [weak self] in
            self?.run(turn.original, in: id)
        }
    }

    /// Runs a task, running from the press, its model requests paid as its
    /// chat's are: a V chat's through the payer, with V's model, read first,
    /// a Token Inference chat's from the Tempo wallet, with its model. The
    /// first task marks its conversation with its mode, saved with its turn.
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
            let model = wallet.model
            agent.run(task, in: id, paying: .tempo, model: { model }, keep: kept)
            return
        }
        agent.run(task, in: id, paying: .zkapi, model: { [payer, logger] () async throws(Agent.End) -> String in
            do throws(PayStop) {
                return try await payer.modelForSend()
            } catch {
                logger.error("V's models did not read: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .public)")
                throw .failed(error.code == .modelUnavailable
                    ? "The service lists no model now. Try again later." : "Cloak couldn't read V's models. Try again.")
            }
        }, keep: kept)
    }

    /// Puts a task's turn in its conversation, in place of its old self or at
    /// the end, and saves it. A conversation deleted meanwhile takes it with
    /// it.
    private func keep(_ turn: Turn, in id: UUID) {
        guard var conversation = conversations.first(where: { $0.id == id }) else { return }
        let hadAnswer: Bool
        if let index = conversation.turns.firstIndex(where: { $0.id == turn.id }) {
            hadAnswer = conversation.turns[index].answer != nil
            conversation.turns[index] = turn
        } else {
            hadAnswer = false
            conversation.turns.append(turn)
        }
        update(conversation)
        if !hadAnswer, let answer = turn.answer, !Self.isBlank(answer) {
            onAnswerArrived?(id)
        }
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
        guard sending[turn] == nil, var conversation = conversations.first(where: { $0.id == id }),
            originalBlock(in: kind(of: conversation)) == nil,
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
    /// the one before it plus more. A turn already sending ignores duplicate
    /// presses so accidental double-clicks never charge twice. A NEAR
    /// conversation's turn goes to NEAR only; a V conversation's through the
    /// payer only, in the owner's turn; a Token Inference conversation's to
    /// the Tempo wallet's provider only.
    func send(_ turn: UUID, in id: UUID) {
        guard sending[turn] == nil, var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        if conversation.isNear {
            if nearMode.route == nil, nearMode.hasKey == true, canAutoStart {
                startThen(in: id) { [weak self] in self?.send(turn, in: id) }
                return
            }
            guard nearMode.sendBlock == nil, let route = nearMode.route else { return }
            press(turn, at: index, in: &conversation)
            sendTasks[turn] = Task { [conversation] in
                defer { sendTasks[turn] = nil }
                do throws(NearStop) {
                    let answer = try await nearMode.send(turn, in: conversation, route: route)
                    finish(turn, in: id, .success(answer.text), tokens: answer.tokens)
                } catch {
                    finish(turn, in: id, .failure(.near(error)))
                }
            }
            return
        }
        let mode = kind(of: conversation)
        guard sendBlock(conversation.turns[index], in: mode) == nil else { return }
        if supervisor.phase != .running, canAutoStart {
            startThen(in: id) { [weak self] in self?.send(turn, in: id) }
            return
        }
        guard supervisor.phase == .running else { return }
        if mode == .token {
            // Route according to the active Token Inference provider toggle
            // so switching between Venice and Boundless works seamlessly mid-chat.
            let shouldUseVenice = settings.payProvider == .venice
            if shouldUseVenice {
                if conversation.venice == nil {
                    guard let chatConfig = veniceMode.newChat else {
                        // Load Venice models first if Cloak just started.
                        sendTasks[turn] = Task { [weak self] in
                            guard let self else { return }
                            await self.veniceMode.refreshModels()
                            self.sendTasks[turn] = nil
                            if self.veniceMode.newChat != nil {
                                self.send(turn, in: id)
                            }
                        }
                        return
                    }
                    conversation.venice = chatConfig
                    update(conversation)
                }
                press(turn, at: index, in: &conversation)
                let identity = identity(of: id)
                veniceMode.send(turn, in: conversation, identity: identity) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let answer):
                        let tokens: Tokens? =
                            if let i = answer.promptTokens, let o = answer.answerTokens {
                                Tokens(input: i, output: o)
                            } else { nil }
                        self.finish(turn, in: id, .success(answer.text), tokens: tokens)
                    case .failure(let stop):
                        self.finish(turn, in: id, .failure(.venice(stop)))
                    }
                }
                return
            }
            guard let deposits = wallet.deposits else { return }
            press(turn, at: index, in: &conversation)
            let identity = identity(of: id)
            let (model, exchange) = (wallet.model, wallet.exchange)
            sendTasks[turn] = Task { [conversation] in
                defer { sendTasks[turn] = nil }
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
        let identity = identity(of: id)
        sendTasks[turn] = Task { [conversation] in
            defer { sendTasks[turn] = nil }
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

    /// One press of Send ended: why it stopped, kept with its turn, or its
    /// answer, with the tokens NEAR counted for it.
    private func finish(_ turn: UUID, in id: UUID, _ result: Result<String, SendStop.Reason>, tokens: Tokens? = nil) {
        if case .failure(let reason) = result {
            logger.error("a send stopped: \(reason.code, privacy: .public) \(reason.detail, privacy: .public)")
            if conversations.contains(where: { $0.id == id }) {
                sendStops[turn] = SendStop(reason: reason)
            }
        }
        sent(turn, in: id, answer: try? result.get(), tokens: tokens)
    }

    /// Moves a turn sent after later ones to the end, counts the press, and
    /// clears why the turn's last send stopped.
    private func press(_ turn: UUID, at index: Int, in conversation: inout Conversation) {
        if index != conversation.turns.count - 1 {
            conversation.turns.append(conversation.turns.remove(at: index))
            update(conversation)
        }
        if sending[turn] == nil { sending[turn] = Sending(started: .now) } else { sending[turn]?.presses += 1 }
        sendStops[turn] = nil
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
        onAnswerArrived?(id)
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
        let priorMessages: [LocalMessage] = conversation.turns[..<index].flatMap { earlier -> [LocalMessage] in
            guard let answer = earlier.answer else { return [] }
            let userContent: String
            if let earlierAttachments = turnLocalAttachments[earlier.id],
                let block = LocalContextBuilder.attachmentsBlock(for: earlierAttachments)
            {
                userContent = LocalContextBuilder.inject(block, into: earlier.original)
            } else {
                userContent = earlier.original
            }
            return [.user(userContent), .assistant(answer, thinking: earlier.thinking)]
        }
        let promptText = conversation.turns[index].original
        let contextOptions = settings.localContextOptions
        let attachments = turnLocalAttachments[turn] ?? []
        answerStops[turn] = nil
        let lora = activeUnfilteredLora
        let warm = supervisor.isLocalModelWarm(model, lora: lora)
        let initialStage: LocalAnswerStage = warm ? .answering : .startingModel
        let task = Task { [weak self] in
            guard let self else { return }
            let localContext = await LocalContextBuilder.build(
                query: promptText,
                options: contextOptions,
                attachments: attachments)
            let finalPrompt = LocalContextBuilder.inject(localContext, into: promptText)
            let messages = priorMessages + [.user(finalPrompt)]
            let result: Result<LocalAnswer, AnswerStop>
            do throws(AnswerStop) {
                result = .success(try await self.supervisor.answer(
                    messages, with: model, lora: lora,
                    onStage: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            guard let self, var current = self.answering[id], current.turn == turn else { return }
                            current.stage = stage
                            if stage == .startingModel { current.didColdStart = true }
                            self.answering[id] = current
                        }
                    },
                    onPartial: { [weak self] partial in
                        Task { @MainActor [weak self] in
                            guard let self, var current = self.answering[id], current.turn == turn else { return }
                            current.stage = .answering
                            current.partial = partial
                            self.answering[id] = current
                        }
                    }))
            } catch {
                result = .failure(error)
            }
            self.answered(turn, in: id, result)
        }
        answering[id] = Answering(
            turn: turn, started: .now, stage: initialStage, didColdStart: !warm, partial: "", task: task)
    }

    /// Stops the Local Llama answer under way in the conversation.
    func stopAnswer(in id: UUID) {
        answering[id]?.task.cancel()
    }

    /// A Local Llama answer ended: kept with its turn, or why it has none.
    /// A conversation deleted meanwhile takes it with it.
    private func answered(_ turn: UUID, in id: UUID, _ result: Result<LocalAnswer, AnswerStop>) {
        answering[id] = nil
        guard var conversation = conversations.first(where: { $0.id == id }),
            let index = conversation.turns.firstIndex(where: { $0.id == turn })
        else { return }
        switch result {
        case .success(let reply):
            conversation.turns[index].answer = reply.text
            conversation.turns[index].thinking = reply.thinking
            update(conversation)
            onAnswerArrived?(id)
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
        stops[conversation] = nil
        let task = Task { await reword(original, in: conversation, asked) }
        rewording = Rewording(conversation: conversation, original: original, asked: asked, started: .now, task: task)
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
                if case .new(_, _, let mode, _) = asked { mark(&conversation, as: mode) }
                let new = Turn(original: original, reworded: reworded)
                conversation.turns.append(new)
                opened = new.id
                turn = new.id
            }
            update(conversation)
            // A new message pressed as Send, with Review off then, goes now,
            // as if Send were pressed: through the same checks, so one
            // certain to stop stays open, saying why. A card's Reword only
            // rewords.
            if case .new(_, _, _, true) = asked { send(turn, in: id) }
        case .failure(let reason):
            switch asked {
            case .again(let turn):
                stops[id] = Stop(reason: reason, turn: turn)
            case .new(let written, let picked, _, _):
                stops[id] = Stop(reason: reason, turn: nil, back: Back(draft: written, picks: picked))
                giveBack()
            }
        }
    }

    /// Gives the shown conversation's new message whose rewording stopped
    /// back to the box, as it was written, to be written again; it is never
    /// shown as reworded. Into an empty box with its picks, which go first,
    /// so the draft finds them fixed and no new details are asked for; after
    /// what the box holds otherwise, its picks as lines of its text, so
    /// nothing in the box is lost.
    private func giveBack() {
        guard let id = selection, let back = stops[id]?.back else { return }
        stops[id]?.back = nil
        if Self.isBlank(draft) {
            picks = back.picks
            draft = back.draft
        } else {
            draft += "\n\n" + back.picks.message(back.draft)
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
