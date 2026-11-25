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
    /// Credit balance on Venice for wallet billing.
    private(set) var credit: VeniceAccount?
    /// Last account-balance read stop.
    private(set) var accountStop: VeniceStop?
    /// On-chain USDC balance on Base for this Venice wallet.
    private(set) var funds: Amount?
    /// True if reading on-chain Base USDC failed.
    private(set) var fundsFailed = false
    /// Venice x402 top-up terms (minimum amount, payTo, timeout).
    private(set) var terms: VeniceTopUpTerms?
    /// In-flight x402 top-up guard (prevents double-click duplicate nonces).
    private(set) var adding = false
    /// Last top-up error, cleared on next press.
    private(set) var topUpStop: VeniceStop?
    /// Last completed top-up, cleared on next press.
    private(set) var added: VeniceTopUp?
    /// Last wallet creation error.
    private(set) var walletStop: RemoteStop?
    /// Reads in flight for toolbar/sheet spinner.
    private(set) var reading = 0
    /// Live streaming partial answers, by turn.
    private(set) var partial: [UUID: Partial] = [:]
    /// Last send stop per turn (in memory only).
    private(set) var stops: [UUID: VeniceStop] = [:]
    /// Conversations whose pinned model moved tier or went away.
    private(set) var retired: Set<UUID> = []

    @ObservationIgnored private var tasks: [UUID: [Int: Task<Void, Never>]] = [:]
    @ObservationIgnored private var presses = 0
    private let listIdentity = Chat.newIdentity()
    private let keyIdentity = Chat.newIdentity()
    private let walletIdentity = Chat.newIdentity()
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
    /// permitted by tier filter) or the first offered Private/TEE model.
    var effectiveChoice: VeniceChoice? {
        if let chosen = settings.veniceModel, chosen.tier.isVenicePrivate || settings.veniceAllTiers {
            return chosen
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
            if presence.address == nil { return "Create a Venice wallet in Funds." }
        case .key:
            if hasKey == false { return "Add your Venice key in Funds." }
            if hasKey == nil { return "Checking Venice key…" }
        }
        if conversation?.venice == nil && effectiveChoice == nil {
            return running ? "Loading Venice models…" : nil
        }
        return nil
    }

    func walletBlocks(for conversation: Conversation?) -> Bool {
        let pays = conversation?.venice?.pays ?? settings.venicePays
        switch pays {
        case .wallet: return presence.address == nil
        case .key: return hasKey == false
        }
    }

    // MARK: Dedicated Venice Wallet (Decision R5b)

    func findWallet() async {
        do throws(Keychain.Failure) {
            presence = WalletPresence(.success(try await VeniceWalletKeychain.address()))
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
            hasKey = try await ProviderKeychain.venice.has()
        } catch {
            logger.error("cannot check Venice API key: \(error.description, privacy: .public)")
            hasKey = nil
        }
    }

    func saveKey(_ key: String) async throws(Keychain.Failure) {
        try await ProviderKeychain.venice.store(key)
        hasKey = true
        await refresh()
    }

    func removeKey() async throws(Keychain.Failure) {
        try await ProviderKeychain.venice.remove()
        hasKey = false
        keyAccount = nil
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
        do throws(VeniceStop) {
            let list = try await read { () async throws(VeniceStop) in
                try await Venice.models(transport: self.transport(self.listIdentity))
            }
            models = list
            modelsFetchedAt = .now
            listStop = nil
            // Auto-select a sensible Private/TEE model on first load so it "just works".
            if settings.veniceModel == nil, let pick = offered.first(where: { !$0.offline }) ?? offered.first {
                settings.veniceModel = VeniceChoice(id: pick.id, name: pick.name, tier: pick.tier)
            }
        } catch {
            listStop = error
        }
    }

    func refreshBalances() async {
        guard running else { return }
        if hasKey == true {
            do {
                let key = try ProviderKeychain.venice.key()
                let venice = Venice(auth: .key(key), transport: transport(keyIdentity))
                keyAccount = try await read { () async throws(VeniceStop) in try await venice.account() }
                accountStop = nil
            } catch let stop as VeniceStop {
                accountStop = stop
            } catch {
                accountStop = VeniceStop(.keychain, sent: false, "could not read Venice API key")
            }
        }
        guard let address = presence.address else { return }
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(RemoteStop) {
            reading += 1
            defer { reading -= 1 }
            funds = try await Remote.veniceFunds(address: address, exchange: exchange)
            fundsFailed = false
        } catch {
            logger.error("Venice Base USDC balance read failed: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .public)")
            funds = nil
            fundsFailed = true
        }
        do throws(VeniceStop) {
            credit = try await read { () async throws(VeniceStop) in try await venice.account() }
            accountStop = nil
        } catch {
            accountStop = error
        }
        terms = try? await read { () async throws(VeniceStop) in try await venice.topUpTerms() }
    }

    /// Moves `amount` of Base USDC from the local Venice wallet into Venice AI
    /// credit via x402 EIP-3009 transfer. Guarded against double-clicks so one
    /// press never signs two nonces.
    func topUp(_ amount: Amount) async {
        guard running, !adding, let address = presence.address else { return }
        adding = true
        topUpStop = nil
        added = nil
        defer { adding = false }
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(VeniceStop) {
            let result = try await venice.add(amount, by: signer(address))
            added = result
            await refreshBalances()
        } catch {
            topUpStop = error
            logger.error("Venice top-up stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .public)")
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
