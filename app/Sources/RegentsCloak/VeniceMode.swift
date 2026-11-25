import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// Venice inside Pay-Per-Prompt mode (Decisions N5.1b & R5b):
/// - Uses a dedicated Keychain wallet (`VeniceWalletKeychain`, separate from
///   Boundless's Tempo wallet) so Base USDC and Tempo addresses can never be
///   correlated across providers.
/// - Defaults to local Base USDC wallet payment (or optional user Venice API
///   key stored in `ProviderKeychain.venice`).
/// - Streams responses incrementally via `partial[turn]` and caches the model
///   list briefly (60 s) to avoid an extra Tor round-trip on every turn.
@MainActor
@Observable
final class VeniceMode {
    struct Partial {
        let press: Int
        var text: String
    }

    let supervisor: Supervisor
    let settings: AppSettings

    /// Dedicated Base USDC wallet presence (`VeniceWalletKeychain`).
    private(set) var presence = WalletPresence.looking
    /// Whether an optional Venice API key is saved in Keychain.
    private(set) var hasKey: Bool?
    /// Venice's live text models, as last fetched.
    private(set) var models: [VeniceModel]?
    @ObservationIgnored private var modelsFetchedAt: Date?
    /// Last model-list error.
    private(set) var listStop: VeniceStop?
    /// Balance for API-key billing.
    private(set) var keyAccount: VeniceAccount?
    /// Last API-key account-balance read stop.
    private(set) var keyAccountStop: VeniceStop?
    /// Credit balance on Venice for wallet billing.
    private(set) var credit: VeniceAccount?
    /// Last wallet account-balance read stop.
    private(set) var accountStop: VeniceStop?
    /// On-chain USDC balance on Base for this Venice wallet.
    private(set) var funds: Amount?
    /// True if reading on-chain Base USDC failed.
    private(set) var fundsFailed = false
    /// Venice x402 top-up terms (minimum amount, payTo, timeout).
    private(set) var terms: VeniceTopUpTerms?
    /// In-flight x402 top-up guard (prevents double-click duplicate nonces).
    private(set) var adding = false
    /// True after a signed x402 top-up failed ambiguously over Tor (status != 400/401/402);
    /// blocks signing a second nonce until live balances are successfully re-read.
    private(set) var topUpUncertain = false
    /// Last top-up error, cleared on next press.
    private(set) var topUpStop: VeniceStop?
    /// Last completed top-up, cleared on next press.
    private(set) var added: VeniceTopUp?
    /// Last wallet creation error.
    private(set) var walletStop: RemoteStop?
    /// Reads in flight for toolbar/sheet spinner.
    private(set) var reading = 0
    /// Monotonic refresh generations so stale out-of-order Tor reads never
    /// overwrite newer balances or model lists.
    @ObservationIgnored private var modelsGeneration: UInt64 = 0
    @ObservationIgnored private var balancesGeneration: UInt64 = 0
    /// Live streaming partial answers, by turn.
    private(set) var partial: [UUID: Partial] = [:]
    /// Last send stop per turn (in memory only).
    private(set) var stops: [UUID: VeniceStop] = [:]
    /// Conversations whose pinned model moved tier or went away.
    private(set) var retired: Set<UUID> = []

    @ObservationIgnored private var tasks: [UUID: [Int: Task<Void, Never>]] = [:]
    @ObservationIgnored private var presses = 0
    private var listIdentity = Chat.newIdentity()
    private var keyIdentity = Chat.newIdentity()
    private var walletIdentity = Chat.newIdentity()

    private static func shouldRotateCircuit(for kind: VeniceStop.Kind) -> Bool {
        switch kind {
        case .unreachable, .failed, .torExitBlocked: true
        default: false
        }
    }
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "venice")

    /// Freshness window for cached model list during chat sends.
    private static let modelCacheTTL: TimeInterval = 60

    init(supervisor: Supervisor, settings: AppSettings) {
        self.supervisor = supervisor
        self.settings = settings
        Task {
            await findWallet()
            await findKey()
        }
    }

    var running: Bool {
        supervisor.phase == .running
    }

    var working: Int {
        reading + (adding ? 1 : 0) + (presence == .creating ? 1 : 0)
    }

    private var exchange: Exchange {
        { [supervisor] request, keep in try await supervisor.exchange(request: request, keep: keep) }
    }

    private func transport(_ identity: String) -> VeniceTransport {
        Remote.veniceTransport(identity: identity) { [supervisor] in try await supervisor.venice($0) }
    }

    private func signer(_ address: String) -> VeniceSigner {
        Remote.veniceSigner(address: address, key: { try VeniceWalletKeychain.key() }, exchange: exchange)
    }

    /// Models offered in the picker: Private and TEE by default, plus Anonymous
    /// when `veniceAllTiers` is enabled in Advanced settings; never remapped.
    var offered: [VeniceModel] {
        (models ?? []).filter { !$0.remapped && ($0.tier.isVenicePrivate || settings.veniceAllTiers) }
    }

    /// Effective model choice for a new Venice chat: user's saved pick (if still
    /// permitted by tier filter and still offered at the same tier when live
    /// models are loaded) or the first offered Private/TEE model.
    var effectiveChoice: VeniceChoice? {
        if let chosen = settings.veniceModel, chosen.tier.isVenicePrivate || settings.veniceAllTiers {
            if models == nil {
                return chosen
            }
            if let live = offered.first(where: { $0.id == chosen.id && $0.tier == chosen.tier }) {
                return VeniceChoice(id: live.id, name: live.name, tier: live.tier)
            }
        }
        guard let first = offered.first(where: { !$0.offline }) ?? offered.first else { return nil }
        return VeniceChoice(id: first.id, name: first.name, tier: first.tier)
    }

    /// The `VeniceChat` descriptor to stamp onto a brand-new Venice chat.
    var newChat: VeniceChat? {
        guard let choice = effectiveChoice else { return nil }
        return VeniceChat(model: choice.id, tier: choice.tier, pays: settings.venicePays)
    }

    /// Whether a Venice chat can send right now (or auto-start Cloak).
    func sendBlock(for conversation: Conversation?, canAutoStart: Bool) -> String? {
        if let conversation, retired.contains(conversation.id) {
            return "Model unavailable. Start a new chat."
        }
        if !running && !canAutoStart {
            return "Start Cloak to send."
        }
        let pays = conversation?.venice?.pays ?? settings.venicePays
        switch pays {
        case .wallet:
            switch presence {
            case .held: break
            case .looking: return "Reading Venice wallet…"
            case .unreadable: return "Couldn't read Venice wallet in Funds."
            case .absent, .creating: return "Create a Venice wallet in Funds."
            }
        case .key:
            if hasKey == false { return "Add your Venice key in Funds." }
            if hasKey == nil { return "Couldn't verify Venice key. Check Funds." }
        }
        if conversation?.venice == nil && effectiveChoice == nil {
            if running {
                return listStop != nil ? "Couldn't load Venice models. Refresh in Funds." : "Loading Venice models…"
            }
            return nil
        }
        return nil
    }

    func walletBlocks(for conversation: Conversation?) -> Bool {
        let pays = conversation?.venice?.pays ?? settings.venicePays
        switch pays {
        case .wallet: return presence.address == nil
        case .key: return hasKey != true
        }
    }

    // MARK: Dedicated Venice Wallet (Decision R5b)

    func findWallet() async {
        presence = .looking
        do throws(Keychain.Failure) {
            presence = WalletPresence(.success(try await VeniceWalletKeychain.address()))
            if running, presence.address != nil {
                await refreshBalances()
            }
        } catch {
            logger.error("cannot read Venice wallet from keychain: \(error.description, privacy: .public)")
            presence = .unreadable
        }
    }

    func createWallet() async {
        guard running, presence.create() else { return }
        walletStop = nil
        do throws(RemoteStop) {
            let address = try await Remote.create(exchange: exchange) { key, address in
                try await VeniceWalletKeychain.store(key: key, address: address)
            }
            presence = .held(address: address)
            await refresh()
        } catch {
            presence = .absent
            walletStop = error
            logger.error("Venice wallet create stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .public)")
        }
    }

    // MARK: Optional Venice API Key

    func findKey() async {
        do throws(Keychain.Failure) {
            let found = try await ProviderKeychain.venice.has()
            hasKey = found
            if running, found {
                await refreshBalances()
            }
        } catch {
            logger.error("cannot check Venice API key: \(error.description, privacy: .public)")
            hasKey = nil
        }
    }

    func saveKey(_ key: String) async throws(Keychain.Failure) {
        try await ProviderKeychain.venice.store(key)
        hasKey = true
        keyAccount = nil
        keyAccountStop = nil
        await refresh()
    }

    func removeKey() async throws(Keychain.Failure) {
        try await ProviderKeychain.venice.remove()
        balancesGeneration &+= 1
        hasKey = false
        keyAccount = nil
        keyAccountStop = nil
    }

    // MARK: Refresh & x402 Top-Up

    func refresh() async {
        guard running else { return }
        async let m: Void = refreshModels()
        async let a: Void = refreshBalances()
        _ = await (m, a)
    }

    func refreshModels() async {
        guard running else { return }
        modelsGeneration &+= 1
        let gen = modelsGeneration
        do throws(VeniceStop) {
            let list = try await read { () async throws(VeniceStop) in
                try await Venice.models(transport: self.transport(self.listIdentity))
            }
            guard modelsGeneration == gen, !Task.isCancelled else { return }
            models = list
            modelsFetchedAt = .now
            listStop = nil
            // Auto-select a sensible Private/TEE model on first load, or update
            // if a previously saved model was retired or changed privacy tier.
            if let pick = offered.first(where: { !$0.offline }) ?? offered.first {
                let savedStillValid = settings.veniceModel.map { saved in
                    offered.contains { $0.id == saved.id && $0.tier == saved.tier }
                } ?? false
                if !savedStillValid {
                    settings.veniceModel = VeniceChoice(id: pick.id, name: pick.name, tier: pick.tier)
                }
            }
        } catch {
            guard modelsGeneration == gen, !Task.isCancelled, error.kind != .cancelled, running else { return }
            if Self.shouldRotateCircuit(for: error.kind) {
                listIdentity = Chat.newIdentity()
            }
            listStop = error
        }
    }

    func refreshBalances() async {
        guard running else { return }
        balancesGeneration &+= 1
        let gen = balancesGeneration
        if hasKey == true {
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    try ProviderKeychain.venice.key()
                }.value
                guard balancesGeneration == gen, !Task.isCancelled, hasKey == true else { return }
                let venice = Venice(auth: .key(key), transport: transport(keyIdentity))
                let acct = try await read { () async throws(VeniceStop) in try await venice.account() }
                guard balancesGeneration == gen, !Task.isCancelled, hasKey == true else { return }
                keyAccount = acct
                keyAccountStop = nil
            } catch let stop as VeniceStop {
                guard balancesGeneration == gen, !Task.isCancelled, stop.kind != .cancelled, running else { return }
                if Self.shouldRotateCircuit(for: stop.kind) {
                    keyIdentity = Chat.newIdentity()
                }
                keyAccountStop = stop
            } catch {
                guard balancesGeneration == gen, !Task.isCancelled, running else { return }
                keyAccountStop = VeniceStop(.keychain, sent: false, "could not read Venice API key")
            }
        }
        guard balancesGeneration == gen, !Task.isCancelled, running, let address = presence.address else { return }
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(RemoteStop) {
            reading += 1
            defer { reading -= 1 }
            let nextFunds = try await Remote.veniceFunds(address: address, exchange: exchange)
            guard balancesGeneration == gen, !Task.isCancelled else { return }
            funds = nextFunds
            fundsFailed = false
        } catch {
            guard balancesGeneration == gen, !Task.isCancelled, running else { return }
            logger.error("Venice Base USDC balance read failed: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .public)")
            fundsFailed = true
        }
        guard balancesGeneration == gen, !Task.isCancelled, running else { return }
        do throws(VeniceStop) {
            let nextCredit = try await read { () async throws(VeniceStop) in try await venice.account() }
            guard balancesGeneration == gen, !Task.isCancelled else { return }
            credit = nextCredit
            accountStop = nil
            if !fundsFailed {
                topUpUncertain = false
            }
        } catch {
            guard balancesGeneration == gen, !Task.isCancelled, error.kind != .cancelled, running else { return }
            if Self.shouldRotateCircuit(for: error.kind) {
                walletIdentity = Chat.newIdentity()
            }
            accountStop = error
        }
        guard balancesGeneration == gen, !Task.isCancelled, running else { return }
        if let nextTerms = try? await read({ () async throws(VeniceStop) in try await venice.topUpTerms() }),
            balancesGeneration == gen, !Task.isCancelled
        {
            terms = nextTerms
        }
    }

    /// Moves `amount` of Base USDC from the local Venice wallet into Venice AI
    /// credit via x402 EIP-3009 transfer. Guarded against double-clicks so one
    /// press never signs two nonces.
    func topUp(_ amount: Amount) async {
        guard running, !adding, !topUpUncertain, let address = presence.address else { return }
        adding = true
        topUpStop = nil
        added = nil
        defer { adding = false }
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(VeniceStop) {
            let result = try await venice.add(amount, by: signer(address))
            added = result
            topUpUncertain = false
            // Immediately reflect the server-confirmed post-top-up balance even
            // if the follow-up balance refresh over Tor hiccups.
            credit = VeniceAccount(usd: result.balance, diem: credit?.diem, canSpend: true)
            accountStop = nil
            await refreshBalances()
        } catch {
            if Self.shouldRotateCircuit(for: error.kind) {
                walletIdentity = Chat.newIdentity()
            }
            topUpStop = error
            if error.sent && error.kind != .paymentRefused {
                topUpUncertain = true
            }
            logger.error("Venice top-up stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .public)")
            // If the signed EIP-3009 authorization was already transmitted over Tor,
            // refresh Base USDC + Venice Credit immediately so the user can see
            // whether payment landed before ever attempting another nonce.
            if error.sent {
                await refreshBalances()
            }
        }
    }

    private func read<T>(_ request: () async throws(VeniceStop) -> T) async throws(VeniceStop) -> T {
        reading += 1
        defer { reading -= 1 }
        do {
            return try await request()
        } catch {
            logger.error("a Venice read stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .public)")
            throw error
        }
    }

    func recordStop(_ stop: VeniceStop, for turn: UUID) {
        stops[turn] = stop
    }

    // MARK: Streaming Messages

    func send(
        _ turn: UUID, in conversation: Conversation, identity: String,
        answered: @escaping (Result<VeniceAnswer, VeniceStop>) -> Void
    ) {
        guard let chat = conversation.venice else { return }
        presses += 1
        let press = presses
        stops[turn] = nil
        partial[turn] = Partial(press: press, text: "")
        let (texts, feed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let transport = transport(identity)
        let walletAddress = presence.address
        let signer = walletAddress.map(signer)
        let freshCache: [VeniceModel]? =
            if let models, let fetched = modelsFetchedAt, Date.now.timeIntervalSince(fetched) < Self.modelCacheTTL {
                models
            } else {
                nil
            }
        let task = Task {
            let shown = Task { for await text in texts { show(text, for: turn, press: press) } }
            let result: Result<VeniceAnswer, VeniceStop>
            do throws(VeniceStop) {
                let auth: VeniceAuth
                switch chat.pays {
                case .key:
                    do throws(Keychain.Failure) {
                        auth = .key(try ProviderKeychain.venice.key())
                    } catch {
                        throw VeniceStop(.keychain, sent: false, "the key did not read: \(error.description)")
                    }
                case .wallet:
                    guard let signer else {
                        throw VeniceStop(.keychain, sent: false, "the Venice wallet address did not read")
                    }
                    auth = .wallet(signer)
                }
                let answer = try await Venice(auth: auth, transport: transport).ask(
                    chat, turn: turn, in: conversation, cachedModels: freshCache
                ) { feed.yield($0) }
                result = .success(answer)
            } catch {
                result = .failure(error)
            }
            feed.finish()
            await shown.value
            finish(turn, press: press, in: conversation.id, result)
            answered(result)
            if case .success = result {
                Task { await refreshBalances() }
            }
        }
        tasks[turn, default: [:]][press] = task
    }

    func dismissWalletStop() {
        walletStop = nil
    }

    func dismissStop(of turn: UUID) {
        stops[turn] = nil
    }

    func stop(_ turn: UUID) {
        tasks[turn]?.values.forEach { $0.cancel() }
    }

    func stop(in conversation: Conversation) {
        conversation.turns.forEach { stop($0.id) }
    }

    private func show(_ text: String, for turn: UUID, press: Int) {
        guard let shown = partial[turn], shown.press <= press else { return }
        partial[turn] = Partial(press: press, text: text)
    }

    private func finish(_ turn: UUID, press: Int, in conversation: UUID, _ result: Result<VeniceAnswer, VeniceStop>) {
        tasks[turn]?[press] = nil
        if tasks[turn]?.isEmpty == true { tasks[turn] = nil }
        if partial[turn]?.press == press { partial[turn] = nil }
        switch result {
        case .success:
            stops[turn] = nil
        case .failure(let stop):
            logger.error("a Venice message stopped: \(stop.kind.rawValue, privacy: .public) \(stop.text, privacy: .public)")
            stops[turn] = stop
            if stop.kind == .gone || stop.kind == .tierChanged { retired.insert(conversation) }
        }
    }
}
