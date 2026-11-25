import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// Token Inference's one wallet (decisions 10 and 25 in docs/plan.md): made
/// on this Mac when its owner presses Create, funded by its owner, and
/// paying for every Token Inference chat sent, so the provider can link them
/// all. Its key is in the keychain
/// only (`WalletKeychain`); `look` is what the network and the provider show
/// of it, read again after each request. Every press reaches the guest's
/// sender, which takes one request at a time; none is refused here for one
/// already under way.
@MainActor
@Observable
final class Wallet {
    /// The cheapest suitable open model in the provider's list when this was
    /// written; any model in the list can be picked.
    static let defaultModel = "deepseek/deepseek-v4-flash-0731"
    private static let modelKey = "tokenModel"

    let supervisor: Supervisor
    let folder: URL
    /// Set once the conversations' key is open; the deposit is sealed with it.
    var deposits: DepositStore?
    private(set) var presence = WalletPresence.looking
    private(set) var look: Look?
    var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.modelKey)
        }
    }
    /// The last Create, Close or Withdraw that stopped, until the next one
    /// is pressed or it is dismissed. A read of the wallet never clears it.
    private(set) var stop: RemoteStop?
    /// The last read of the wallet that stopped, until one succeeds.
    private(set) var readStop: RemoteStop?
    /// Requests under way, for their progress.
    private(set) var working = 0
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "wallet")

    init(supervisor: Supervisor, folder: URL) {
        self.supervisor = supervisor
        self.folder = folder
        self.model = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel
    }

    var exchange: Exchange {
        { [supervisor] request, keep in try await supervisor.exchange(request: request, keep: keep) }
    }

    /// A deposit that can pay now, as the network last showed it: not gone,
    /// with something left.
    var depositUsable: Bool {
        guard let deposit = look?.deposit else { return false }
        return deposit.gone != true && deposit.left.units > 0
    }

    /// Sending is certain to stop for want of funds, as the network showed
    /// the wallet when it was last read: no deposit to pay from, and too
    /// little for a new one.
    var lacksFunds: Bool {
        guard let look else { return false }
        return !depositUsable && look.balance < look.least
    }

    /// Asks the keychain for the wallet, then reads it if there is one. A
    /// read that fails can be asked again.
    func find() async {
        presence = .looking
        let read: Result<String?, Keychain.Failure>
        do {
            read = .success(try await WalletKeychain.address())
        } catch {
            logger.error("cannot read the wallet: \(error.description, privacy: .public)")
            read = .failure(error)
        }
        presence = WalletPresence(read)
        await refresh()
    }

    /// Makes the wallet: the sender makes the key, the keychain keeps it.
    func create() async {
        guard presence.create() else { return }
        stop = nil
        let address: String
        do {
            address = try await Remote.create(exchange: exchange) { key, address in
                try await WalletKeychain.store(key: key, address: address)
            }
        } catch {
            presence = .absent
            stop = recorded(error)
            return
        }
        presence = .held(address: address)
        await refresh()
    }

    /// Reads the balance, the provider's setup and models, and the deposit.
    func refresh() async {
        guard let address = presence.address, let deposits, supervisor.phase == .running else { return }
        readStop = await run { [exchange] () async throws(RemoteStop) in
            self.look = try await Remote.look(address: address, deposits: deposits, exchange: exchange)
        }
    }

    /// Closes the deposit with the provider, which refunds what is unspent.
    func close() async {
        guard let deposits else { return }
        stop = nil
        stop = await run { [exchange, model] () async throws(RemoteStop) in
            try await Remote.close(model: model, key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange)
        }
        await refresh()
    }

    /// The network's own close: asks to close, or takes the deposit back.
    func withdraw() async {
        guard let deposits else { return }
        stop = nil
        stop = await run { [exchange] () async throws(RemoteStop) in
            try await Remote.withdraw(key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange)
        }
        await refresh()
    }

    /// Forgets what stopped, as its row's close button asks.
    func dismiss() {
        stop = nil
        readStop = nil
    }

    /// Runs one request; returns how it stopped, or nil when it did not.
    private func run(_ request: () async throws(RemoteStop) -> Void) async -> RemoteStop? {
        working += 1
        defer { working -= 1 }
        do {
            try await request()
            return nil
        } catch {
            return recorded(error)
        }
    }

    private func recorded(_ stop: RemoteStop) -> RemoteStop {
        logger.error("wallet request stopped: \(stop.code.rawValue, privacy: .public) \(stop.detail, privacy: .public)")
        return stop
    }
}
