import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// Venice inside Token Inference (docs/venice.md): each message goes,
/// reworded or as its owner chose, through the guest's sender and Tor to
/// the one model its chat began with, at the tier it had then, paid the way
/// the chat began: the owner's Venice key, or the credit Cloak's one wallet
/// (`Wallet`) bought at Venice with USDC on Base, from the same address that
/// pays Boundless on Tempo (decision 31). The Venice key is in the keychain
/// only (`ProviderKeychain.venice`), and so is the wallet's
/// (`WalletKeychain`); the wallet signs in the guest only. Every press of
/// Send and Add goes; none is refused here for one already under way.
@MainActor
@Observable
final class VeniceMode {
    /// One message's answer so far, from its newest press.
    struct Partial {
        let press: Int
        var text: String
    }

    let supervisor: Supervisor
    let settings: AppSettings
    /// Whether a Venice key is kept, as the keychain last answered; nil until
    /// it has, or when it could not.
    private(set) var hasKey: Bool?
    /// The last keychain request from Settings failed.
    private(set) var keyFailed = false
    /// Venice's text models, as last read.
    private(set) var models: [VeniceModel]?
    /// The last read of the list that stopped, until one succeeds.
    private(set) var listStop: VeniceStop?
    /// What the key has to spend, as last read.
    private(set) var keyAccount: VeniceAccount?
    /// The wallet's Venice credit, as last read.
    private(set) var credit: VeniceAccount?
    /// The last read of the key's balance or the wallet's credit that
    /// stopped, until one succeeds.
    private(set) var accountStop: VeniceStop?
    /// The wallet's USDC on Base at the latest block read.
    private(set) var funds: Amount?
    /// The last read of the wallet's USDC failed.
    private(set) var fundsFailed = false
    /// Venice's terms for a top-up, as last read; the sheet's amount starts
    /// at their least.
    private(set) var terms: VeniceTopUpTerms?
    /// Presses of Add still under way.
    private(set) var adding = 0
    /// The last press of Add that stopped, until the next press.
    private(set) var topUpStop: VeniceStop?
    /// The last top-up Venice took, until the next press.
    private(set) var added: VeniceTopUp?
    /// Reads under way, for the sheet's progress.
    private(set) var reading = 0
    /// Answers coming in, by turn.
    private(set) var partial: [UUID: Partial] = [:]
    /// Why each message last sent has no answer, by turn. In memory only.
    private(set) var stops: [UUID: VeniceStop] = [:]
    /// The chats whose model Venice no longer lists, or lists at another
    /// tier: certain to stop again, so they send no more. In memory only.
    private(set) var retired: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: [Int: Task<Void, Never>]] = [:]
    @ObservationIgnored private var presses = 0
    /// The sheet's reads, each under a Tor name of its own, new at each
    /// launch: the list, the key's balance, the wallet's.
    private let listIdentity = Chat.newIdentity()
    private let keyIdentity = Chat.newIdentity()
    private let walletIdentity = Chat.newIdentity()
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "venice")

    init(supervisor: Supervisor, settings: AppSettings) {
        self.supervisor = supervisor
        self.settings = settings
        Task { await find() }
    }

    var running: Bool {
        supervisor.phase == .running
    }

    private var exchange: Exchange {
        { [supervisor] request, keep in try await supervisor.exchange(request: request, keep: keep) }
    }

    private func transport(_ identity: String) -> VeniceTransport {
        Remote.veniceTransport(identity: identity) { [supervisor] in try await supervisor.venice($0) }
    }

    private func signer(_ address: String) -> VeniceSigner {
        Remote.veniceSigner(address: address, key: { try WalletKeychain.key() }, exchange: exchange)
    }

    /// The model new Venice chats begin with: the one chosen, unless it is
    /// Anonymous while All tiers is off.
    var choice: VeniceChoice? {
        guard let chosen = settings.veniceModel, chosen.tier.isVenicePrivate || settings.veniceAllTiers else { return nil }
        return chosen
    }

    /// The models the sheet offers: Private and TEE, and Anonymous with All
    /// tiers on; never one Venice may answer for from another.
    var offered: [VeniceModel] {
        (models ?? []).filter { !$0.remapped && ($0.tier.isVenicePrivate || settings.veniceAllTiers) }
    }

    /// Whether a press under way on `turn` has not ended.
    func answering(_ turn: UUID) -> Bool {
        tasks[turn]?.isEmpty == false
    }

    // MARK: Keychain

    /// Asks the keychain whether a key is kept, without reading it.
    func find() async {
        do throws(Keychain.Failure) {
            hasKey = try await ProviderKeychain.venice.has()
            keyFailed = false
        } catch {
            logger.error("cannot read whether a Venice key is kept: \(error.description, privacy: .public)")
            hasKey = nil
            keyFailed = true
        }
    }

    /// Keeps `key` in place of any before; returns whether it was kept.
    func save(_ key: String) async -> Bool {
        do throws(Keychain.Failure) {
            try await ProviderKeychain.venice.store(key)
            hasKey = true
            keyFailed = false
            keyAccount = nil
            return true
        } catch {
            logger.error("cannot keep the Venice key: \(error.description, privacy: .public)")
            keyFailed = true
            return false
        }
    }

    /// Removes the key.
    func remove() async {
        do throws(Keychain.Failure) {
            try await ProviderKeychain.venice.remove()
            hasKey = false
            keyFailed = false
            keyAccount = nil
        } catch {
            logger.error("cannot remove the Venice key: \(error.description, privacy: .public)")
            keyFailed = true
        }
    }

    /// The key, read off the main thread as a request is built.
    @concurrent
    private nonisolated static func key() async throws(Keychain.Failure) -> String {
        try ProviderKeychain.venice.key()
    }

    // MARK: Credit

    /// One press of Add: a top-up of exactly `amount` from the wallet at
    /// `address`, on Venice's terms read afresh. Each press signs and pays on
    /// its own; two presses pay twice.
    func add(_ amount: Amount, from address: String) async {
        adding += 1
        defer { adding -= 1 }
        topUpStop = nil
        added = nil
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(VeniceStop) {
            added = try await venice.add(amount, by: signer(address))
        } catch {
            logger.error("a top-up stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .private)")
            topUpStop = error
        }
        await readWallet(address)
    }

    // MARK: Reads

    /// Reads what the sheet shows: the list, and what the way new chats pay
    /// has to spend: the key's balance, or what the wallet at `wallet` holds
    /// on Base and at Venice. Costs nothing.
    func refresh(wallet: String?) async {
        guard running else { return }
        // What stopped is the other way's, once the way changes.
        accountStop = nil
        async let list: Void = readModels()
        switch settings.venicePays {
        case .key: await readKey()
        case .wallet: if let wallet { await readWallet(wallet) }
        }
        await list
    }

    /// Reads the list, and forgets the chosen model when Venice no longer
    /// lists it, or lists it at another tier, or may answer for it from
    /// another.
    func readModels() async {
        guard running else { return }
        do throws(VeniceStop) {
            let models = try await read { [transport = transport(listIdentity)] () async throws(VeniceStop) in
                try await Venice.models(transport: transport)
            }
            self.models = models
            listStop = nil
            if let chosen = settings.veniceModel, !models.contains(where: { $0.id == chosen.model && $0.tier == chosen.tier && !$0.remapped }) {
                settings.veniceModel = nil
            }
        } catch {
            listStop = error
        }
    }

    /// The key's balance.
    func readKey() async {
        guard running, hasKey == true else { return }
        do throws(VeniceStop) {
            let key: String
            do throws(Keychain.Failure) { key = try await Self.key() } catch {
                throw VeniceStop(.keychain, sent: false, "the key did not read: \(error.description)")
            }
            let venice = Venice(auth: .key(key), transport: transport(keyIdentity))
            keyAccount = try await read { () async throws(VeniceStop) in try await venice.account() }
            accountStop = nil
        } catch {
            accountStop = error
        }
    }

    /// The wallet's USDC on Base, its Venice credit, and Venice's terms. Terms
    /// that do not read leave the amount empty; Add reads them afresh, and
    /// says why.
    private func readWallet(_ address: String) async {
        guard running else { return }
        let venice = Venice(auth: .wallet(signer(address)), transport: transport(walletIdentity))
        do throws(RemoteStop) {
            reading += 1
            defer { reading -= 1 }
            funds = try await Remote.veniceFunds(address: address, exchange: exchange)
            fundsFailed = false
        } catch {
            logger.error("the wallet's USDC on Base did not read: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
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

    private func read<T>(_ request: () async throws(VeniceStop) -> T) async throws(VeniceStop) -> T {
        reading += 1
        defer { reading -= 1 }
        do {
            return try await request()
        } catch {
            logger.error("a Venice read stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .private)")
            throw error
        }
    }

    // MARK: Messages

    /// Sends `turn` of `conversation`, as its text is to go, to the chat's
    /// model, paid the chat's way (from the wallet at `wallet` for a chat
    /// that pays with the wallet), under the conversation's Tor `identity`;
    /// gives `answered` the answer, or nil when it stopped (`stops`). The
    /// list is read first on the same identity, and nothing more is sent
    /// unless it still has the chat's model at its tier, answering as
    /// itself.
    func send(_ turn: UUID, in conversation: Conversation, identity: String, wallet: String?, answered: @escaping (String?) -> Void) {
        guard let chat = conversation.venice else { return }
        presses += 1
        let press = presses
        stops[turn] = nil
        partial[turn] = Partial(press: press, text: "")
        let (texts, feed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let transport = transport(identity)
        let signer = wallet.map(signer)
        let task = Task {
            let shown = Task { for await text in texts { show(text, for: turn, press: press) } }
            let result: Result<VeniceAnswer, VeniceStop>
            do throws(VeniceStop) {
                let auth: VeniceAuth
                switch chat.pays {
                case .key:
                    do throws(Keychain.Failure) { auth = .key(try await Self.key()) } catch {
                        throw VeniceStop(.keychain, sent: false, "the key did not read: \(error.description)")
                    }
                case .wallet:
                    guard let signer else { throw VeniceStop(.keychain, sent: false, "the wallet's address did not read") }
                    auth = .wallet(signer)
                }
                result = .success(try await Venice(auth: auth, transport: transport).ask(chat, turn: turn, in: conversation) { feed.yield($0) })
            } catch {
                result = .failure(error)
            }
            feed.finish()
            await shown.value
            finish(turn, press: press, in: conversation.id, result)
            answered(try? result.get().text)
        }
        tasks[turn, default: [:]][press] = task
    }

    /// Forgets why `turn` last stopped, as its row's close button asks.
    func dismissStop(of turn: UUID) {
        stops[turn] = nil
    }

    /// Stops every press under way on `turn`. Whatever Venice charged so far
    /// stays charged.
    func stop(_ turn: UUID) {
        tasks[turn]?.values.forEach { $0.cancel() }
    }

    /// Stops every press under way in a chat being deleted.
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
            logger.error("a Venice message stopped: \(stop.kind.rawValue, privacy: .public) \(stop.text, privacy: .private)")
            stops[turn] = stop
            if stop.kind == .gone || stop.kind == .tierChanged { retired.insert(conversation) }
        }
    }
}
