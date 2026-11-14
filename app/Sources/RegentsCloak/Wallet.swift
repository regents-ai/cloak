import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// Development mode's one wallet (decision 10 in docs/plan.md): made on this
/// Mac when its owner presses Create, funded by him, and paying for every
/// chat sent, so the provider can link them all. Its key is in the keychain
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

    let supervisor: Supervisor
    let folder: URL
    /// Set once the conversations' key is open; the deposit is sealed with it.
    var deposits: DepositStore?
    /// Whether the keychain has been asked for the wallet.
    private(set) var found = false
    private(set) var address: String?
    private(set) var look: Look?
    var model = Wallet.defaultModel
    /// The last request that stopped.
    var stop: RemoteStop?
    private(set) var creating = false
    /// Requests under way, for their progress.
    private(set) var working = 0
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "wallet")

    init(supervisor: Supervisor, folder: URL) {
        self.supervisor = supervisor
        self.folder = folder
    }

    var exchange: Exchange {
        { [supervisor] request, keep in try await supervisor.exchange(request: request, keep: keep) }
    }

    /// A deposit that can pay now: open, with something left.
    var depositUsable: Bool {
        guard let deposit = look?.deposit else { return false }
        return deposit.pending != true && deposit.gone != true && deposit.left.units > 0
    }

    /// Sending is certain to stop for want of funds, as the network showed
    /// the wallet when it was last read: no deposit to pay from, and too
    /// little for a new one.
    var lacksFunds: Bool {
        guard let look else { return false }
        return !depositUsable && look.balance < look.least
    }

    /// Asks the keychain for the wallet, then reads it if there is one.
    func find() async {
        do {
            address = try await WalletKeychain.address()
            found = true
        } catch {
            logger.error("cannot read the wallet: \(error.description, privacy: .public)")
            return
        }
        await refresh()
    }

    /// Makes the wallet: the sender makes the key, the keychain keeps it.
    func create() async {
        guard found, address == nil, !creating else { return }
        creating = true
        defer { creating = false }
        do {
            address = try await Remote.create(exchange: exchange) { key, address in
                try await WalletKeychain.store(key: key, address: address)
            }
            stop = nil
        } catch {
            record(error)
            return
        }
        await refresh()
    }

    /// Reads the balance, the provider's setup and models, and the deposit.
    func refresh() async {
        guard let address, let deposits, supervisor.phase == .running else { return }
        await run { [exchange] () async throws(RemoteStop) in
            self.look = try await Remote.look(address: address, deposits: deposits, exchange: exchange)
        }
    }

    /// Closes the deposit with the provider, which refunds what is unspent.
    func close() async {
        guard let deposits else { return }
        await run { [exchange, model] () async throws(RemoteStop) in
            try await Remote.close(model: model, key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange)
        }
        await refresh()
    }

    /// The network's own close: asks to close, or takes the deposit back.
    func withdraw() async {
        guard let deposits else { return }
        await run { [exchange] () async throws(RemoteStop) in
            try await Remote.withdraw(key: { try WalletKeychain.key() }, deposits: deposits, exchange: exchange)
        }
        await refresh()
    }

    private func run(_ request: () async throws(RemoteStop) -> Void) async {
        working += 1
        defer { working -= 1 }
        do {
            try await request()
            stop = nil
        } catch {
            record(error)
        }
    }

    func record(_ stop: RemoteStop) {
        logger.error("wallet request stopped: \(stop.code.rawValue, privacy: .public) \(stop.detail, privacy: .public)")
        self.stop = stop
    }
}
