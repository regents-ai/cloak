import CloakControl
import Foundation

/// Deterministic local spending policy enforced in Swift outside the LLM.
/// Agents and prompts cannot alter or bypass these limits.
public struct SpendPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Maximum cumulative spend per rolling UTC/local calendar day in micro-USD (`$1.00 = 1_000_000`).
    public var dailyLimitMicroUSD: UInt64
    /// Maximum authorized spend for any single call or purchase in micro-USD.
    public var perCallLimitMicroUSD: UInt64
    /// Permitted payment networks. Empty rejects all when `enabled == true`.
    public var allowedNetworks: Set<PaymentNetwork.ID>
    /// Optional provider allowlist (lowercased IDs like `"boundless"`, `"zkapi"`, `"patchbay"`).
    /// Empty permits any Cloak-configured provider.
    public var allowedProviders: Set<String>
    /// Optional recipient/spender address allowlist (lowercased 0x addresses).
    /// Empty permits any recipient verified by the adapter.
    public var allowedRecipients: Set<String>

    public static let defaultDailyLimitMicroUSD: UInt64 = 5_000_000     // $5.00 / day
    public static let defaultPerCallLimitMicroUSD: UInt64 = 500_000     // $0.50 / call

    public static let disabled = SpendPolicy(
        enabled: false,
        dailyLimitMicroUSD: defaultDailyLimitMicroUSD,
        perCallLimitMicroUSD: defaultPerCallLimitMicroUSD,
        allowedNetworks: Set(PaymentNetwork.ID.allCases),
        allowedProviders: [],
        allowedRecipients: []
    )

    public init(
        enabled: Bool,
        dailyLimitMicroUSD: UInt64 = defaultDailyLimitMicroUSD,
        perCallLimitMicroUSD: UInt64 = defaultPerCallLimitMicroUSD,
        allowedNetworks: Set<PaymentNetwork.ID> = Set(PaymentNetwork.ID.allCases),
        allowedProviders: Set<String> = [],
        allowedRecipients: Set<String> = []
    ) {
        self.enabled = enabled
        self.dailyLimitMicroUSD = dailyLimitMicroUSD
        self.perCallLimitMicroUSD = perCallLimitMicroUSD
        self.allowedNetworks = allowedNetworks
        self.allowedProviders = Set(allowedProviders.map { $0.lowercased() })
        self.allowedRecipients = Set(allowedRecipients.map { $0.lowercased() })
    }
}

/// Pre-authorization quote evaluated deterministically before signing or paying.
/// Never carries prompt text, prompt hashes, or local file paths.
public struct SpendQuote: Equatable, Sendable {
    public let idempotencyKey: String
    public let service: String
    public let provider: String
    public let recipient: String?
    public let network: PaymentNetwork.ID
    public let expectedChainID: UInt64
    public let asset: String
    public let maxMicroUSD: UInt64
    /// Clear, user-facing summary of what leaves this Mac for this purchase.
    public let leavesThisMac: String

    public init(
        idempotencyKey: String = UUID().uuidString,
        service: String,
        provider: String,
        recipient: String? = nil,
        network: PaymentNetwork.ID,
        expectedChainID: UInt64,
        asset: String,
        maxMicroUSD: UInt64,
        leavesThisMac: String
    ) {
        self.idempotencyKey = idempotencyKey
        self.service = service
        self.provider = provider
        self.recipient = recipient
        self.network = network
        self.expectedChainID = expectedChainID
        self.asset = asset
        self.maxMicroUSD = maxMicroUSD
        self.leavesThisMac = leavesThisMac
    }
}

/// Why a spend authorization was deterministically rejected before signing.
public enum SpendRejection: Error, Equatable, Sendable {
    case wrongChain(expected: UInt64, actual: UInt64, network: PaymentNetwork.ID)
    case networkNotAllowed(PaymentNetwork.ID)
    case providerNotAllowed(String)
    case recipientNotAllowed(String)
    case exceedsPerCallLimit(requested: UInt64, limit: UInt64)
    case exceedsDailyLimit(requested: UInt64, remaining: UInt64, limit: UInt64)
    case duplicateInFlight(idempotencyKey: String)

    public var message: String {
        switch self {
        case .wrongChain(let expected, let actual, let network):
            let name = PaymentNetwork.network(for: network).name
            return "Blocked before signing: \(name) expects chain ID \(expected), not \(actual)."
        case .networkNotAllowed(let network):
            let name = PaymentNetwork.network(for: network).name
            return "Blocked by Cloak Spend Guardrails: \(name) is not enabled in your allowed networks."
        case .providerNotAllowed(let provider):
            return "Blocked by Cloak Spend Guardrails: provider '\(provider)' is not in your allowlist."
        case .recipientNotAllowed(let recipient):
            return "Blocked by Cloak Spend Guardrails: recipient \(recipient) is not in your allowlist."
        case .exceedsPerCallLimit(let requested, let limit):
            return "Blocked by Cloak Spend Guardrails: max cost \(ArcUSDC(microUnits: requested).formattedUSD) exceeds your per-call cap of \(ArcUSDC(microUnits: limit).formattedUSD)."
        case .exceedsDailyLimit(let requested, let remaining, let limit):
            return "Blocked by Cloak Spend Guardrails: max cost \(ArcUSDC(microUnits: requested).formattedUSD) exceeds your remaining daily budget (\(ArcUSDC(microUnits: remaining).formattedUSD) left of \(ArcUSDC(microUnits: limit).formattedUSD))."
        case .duplicateInFlight:
            return "Blocked duplicate payment retry while an identical authorization is already in flight."
        }
    }
}

/// Explicit, privacy-safe payment receipt. Stores only settlement identifiers
/// and amounts — never prompts, prompt hashes, or repository paths.
public struct SpendReceipt: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case reserved
        case settled
        case ambiguous
        case released
        case failed
    }

    public let id: UUID
    public let idempotencyKey: String
    public let timestamp: Date
    public let service: String
    public let provider: String
    public let recipient: String?
    public let network: PaymentNetwork.ID
    public let chainID: UInt64
    public let asset: String
    public let authorizedMaxMicroUSD: UInt64
    public var actualChargeMicroUSD: UInt64?
    public var networkFeeMicroUSD: UInt64?
    public var txHash: String?
    public var status: Status
    public let leavesThisMac: String
}

/// Outcome of `SpendLedger.authorize(_:policy:now:)`.
public enum SpendDecision: Equatable, Sendable {
    case approved(reservationID: UUID)
    case idempotentReplay(receipt: SpendReceipt)
    case rejected(SpendRejection)
}

/// Point-in-time summary for Cloak's Spend Guardrails UI.
public struct SpendSnapshot: Equatable, Sendable {
    public let spentTodayMicroUSD: UInt64
    public let reservedMicroUSD: UInt64
    public let recentReceipts: [SpendReceipt]

    public static let empty = SpendSnapshot(spentTodayMicroUSD: 0, reservedMicroUSD: 0, recentReceipts: [])

    public func remainingTodayMicroUSD(limit: UInt64) -> UInt64 {
        let committed = spentTodayMicroUSD.saturatingAdd(reservedMicroUSD)
        return limit > committed ? (limit - committed) : 0
    }
}

/// Thread-safe actor enforcing deterministic budgets, atomic concurrent
/// reservations, chain-ID verification, idempotency, and receipt reconciliation.
public actor SpendLedger {
    private struct PersistedLedger: Codable {
        var receipts: [SpendReceipt]
        var dailyCommittedMicroUSD: [String: UInt64]
    }

    private var receipts: [SpendReceipt] = []
    /// Cumulative settled and ambiguous spend per local calendar day (`yyyy-MM-dd`),
    /// persisted independently of `receipts` so truncating display history past
    /// `maxStoredReceipts` or clearing history never resets today's spending cap.
    private var dailyCommittedMicroUSD: [String: UInt64] = [:]
    private let file: URL?
    private let maxStoredReceipts: Int
    private static let maxTrackedDays = 14

    public init(file: URL? = nil, maxStoredReceipts: Int = 200) {
        self.file = file
        self.maxStoredReceipts = maxStoredReceipts
        if let file, let data = try? Data(contentsOf: file) {
            let loadedReceipts: [SpendReceipt]
            let loadedDaily: [String: UInt64]?
            if let ledger = try? JSONDecoder().decode(PersistedLedger.self, from: data) {
                loadedReceipts = ledger.receipts
                loadedDaily = ledger.dailyCommittedMicroUSD
            } else if let legacy = try? JSONDecoder().decode([SpendReceipt].self, from: data) {
                loadedReceipts = legacy
                loadedDaily = nil
            } else {
                loadedReceipts = []
                loadedDaily = nil
            }
            // Recover cleanly after an unexpected crash: any stale `.reserved`
            // entries from a prior process are marked `.released` so funds
            // aren't permanently wedged while preserving history.
            self.receipts = loadedReceipts.map { item in
                var copy = item
                if copy.status == .reserved {
                    copy.status = .released
                }
                return copy
            }
            if let loadedDaily {
                self.dailyCommittedMicroUSD = loadedDaily
            } else {
                var rebuilt: [String: UInt64] = [:]
                for receipt in self.receipts {
                    let key = Self.dayKey(for: receipt.timestamp)
                    switch receipt.status {
                    case .settled:
                        let charge = receipt.actualChargeMicroUSD ?? receipt.authorizedMaxMicroUSD
                        let fee = receipt.networkFeeMicroUSD ?? 0
                        rebuilt[key] = (rebuilt[key] ?? 0).saturatingAdd(charge.saturatingAdd(fee))
                    case .ambiguous:
                        rebuilt[key] = (rebuilt[key] ?? 0).saturatingAdd(receipt.authorizedMaxMicroUSD)
                    case .reserved, .released, .failed:
                        break
                    }
                }
                self.dailyCommittedMicroUSD = rebuilt
            }
        }
    }

    /// Evaluates `quote` deterministically and atomically reserves up to
    /// `quote.maxMicroUSD` against today's budget before any payment is signed.
    public func authorize(_ quote: SpendQuote, policy: SpendPolicy, now: Date = .now) -> SpendDecision {
        // 1. Always verify chain ID matches the manifest before signing anything.
        let spec = PaymentNetwork.network(for: quote.network)
        guard quote.expectedChainID == spec.chainID else {
            return .rejected(.wrongChain(expected: spec.chainID, actual: quote.expectedChainID, network: quote.network))
        }

        // 2. Idempotency check: retries never double-charge or double-reserve.
        if let existing = receipts.first(where: { $0.idempotencyKey == quote.idempotencyKey }) {
            switch existing.status {
            case .settled:
                return .idempotentReplay(receipt: existing)
            case .reserved, .ambiguous:
                return .rejected(.duplicateInFlight(idempotencyKey: quote.idempotencyKey))
            case .released, .failed:
                break
            }
        }

        // 3. Enforce deterministic spending policy when enabled.
        if policy.enabled {
            guard policy.allowedNetworks.contains(quote.network) else {
                return .rejected(.networkNotAllowed(quote.network))
            }
            if !policy.allowedProviders.isEmpty, !policy.allowedProviders.contains(quote.provider.lowercased()) {
                return .rejected(.providerNotAllowed(quote.provider))
            }
            if !policy.allowedRecipients.isEmpty {
                let target = quote.recipient?.lowercased() ?? ""
                guard !target.isEmpty, policy.allowedRecipients.contains(target) else {
                    return .rejected(.recipientNotAllowed(quote.recipient ?? "(missing)"))
                }
            }
            guard quote.maxMicroUSD <= policy.perCallLimitMicroUSD else {
                return .rejected(.exceedsPerCallLimit(requested: quote.maxMicroUSD, limit: policy.perCallLimitMicroUSD))
            }
            let (spent, reserved) = totalsToday(at: now)
            let committed = spent.saturatingAdd(reserved)
            let remaining = policy.dailyLimitMicroUSD > committed ? (policy.dailyLimitMicroUSD - committed) : 0
            guard quote.maxMicroUSD <= remaining else {
                return .rejected(.exceedsDailyLimit(
                    requested: quote.maxMicroUSD,
                    remaining: remaining,
                    limit: policy.dailyLimitMicroUSD))
            }
        }

        // 4. Atomically reserve budget and emit receipt record.
        let receipt = SpendReceipt(
            id: UUID(),
            idempotencyKey: quote.idempotencyKey,
            timestamp: now,
            service: quote.service,
            provider: quote.provider,
            recipient: quote.recipient,
            network: quote.network,
            chainID: quote.expectedChainID,
            asset: quote.asset,
            authorizedMaxMicroUSD: quote.maxMicroUSD,
            actualChargeMicroUSD: nil,
            networkFeeMicroUSD: nil,
            txHash: nil,
            status: .reserved,
            leavesThisMac: quote.leavesThisMac
        )
        receipts.insert(receipt, at: 0)
        trimStoredReceipts()
        persist()
        return .approved(reservationID: receipt.id)
    }

    /// Reconciles a reservation once settlement completes, releasing any unused
    /// difference between `authorizedMaxMicroUSD` and `actualMicroUSD`.
    /// Enforces a strict state machine: only `.reserved` receipts can transition.
    public func settle(
        reservationID: UUID,
        actualMicroUSD: UInt64,
        networkFeeMicroUSD: UInt64? = nil,
        txHash: String? = nil
    ) {
        guard let index = receipts.firstIndex(where: { $0.id == reservationID }),
            receipts[index].status == .reserved
        else { return }
        receipts[index].actualChargeMicroUSD = actualMicroUSD
        receipts[index].networkFeeMicroUSD = networkFeeMicroUSD
        receipts[index].txHash = txHash
        receipts[index].status = .settled
        let committed = actualMicroUSD.saturatingAdd(networkFeeMicroUSD ?? 0)
        recordDailySpend(committed, on: receipts[index].timestamp)
        trimStoredReceipts()
        persist()
    }

    /// Marks an in-flight reservation whose upstream outcome is uncertain
    /// (for example a network timeout after the payment may already have been
    /// submitted) as `.ambiguous`, conservatively counting its reserved maximum
    /// against today's budget so timeouts can never bypass daily limits.
    public func markAmbiguous(reservationID: UUID) {
        guard let index = receipts.firstIndex(where: { $0.id == reservationID }),
            receipts[index].status == .reserved
        else { return }
        receipts[index].status = .ambiguous
        recordDailySpend(receipts[index].authorizedMaxMicroUSD, on: receipts[index].timestamp)
        trimStoredReceipts()
        persist()
    }

    /// Releases a reservation after a failed or cancelled call so the budget
    /// returns immediately. Enforces a strict state machine: only `.reserved`
    /// receipts can transition.
    public func release(reservationID: UUID, failed: Bool = false) {
        guard let index = receipts.firstIndex(where: { $0.id == reservationID }),
            receipts[index].status == .reserved
        else { return }
        receipts[index].status = failed ? .failed : .released
        trimStoredReceipts()
        persist()
    }

    /// Current spend totals for today and recent receipts (newest first).
    public func snapshot(now: Date = .now) -> SpendSnapshot {
        let (spent, reserved) = totalsToday(at: now)
        return SpendSnapshot(
            spentTodayMicroUSD: spent,
            reservedMicroUSD: reserved,
            recentReceipts: Array(receipts.prefix(30))
        )
    }

    /// Clears non-active receipts from display history while preserving
    /// today's committed spend totals so clearing history never resets limits.
    public func clearHistory() {
        receipts.removeAll { $0.status != .reserved }
        persist()
    }

    private func totalsToday(at now: Date) -> (spent: UInt64, reserved: UInt64) {
        let spent = dailyCommittedMicroUSD[Self.dayKey(for: now)] ?? 0
        let startOfDay = Calendar.current.startOfDay(for: now)
        var reserved: UInt64 = 0
        for receipt in receipts where receipt.status == .reserved && receipt.timestamp >= startOfDay {
            reserved = reserved.saturatingAdd(receipt.authorizedMaxMicroUSD)
        }
        return (spent, reserved)
    }

    private func recordDailySpend(_ microUSD: UInt64, on date: Date) {
        let key = Self.dayKey(for: date)
        dailyCommittedMicroUSD[key] = (dailyCommittedMicroUSD[key] ?? 0).saturatingAdd(microUSD)
        if dailyCommittedMicroUSD.count > Self.maxTrackedDays {
            let keep = Set(dailyCommittedMicroUSD.keys.sorted().suffix(Self.maxTrackedDays))
            dailyCommittedMicroUSD = dailyCommittedMicroUSD.filter { keep.contains($0.key) }
        }
    }

    /// Evicts oldest finalized receipts past `maxStoredReceipts`, never evicting
    /// active `.reserved` authorizations.
    private func trimStoredReceipts() {
        while receipts.count > maxStoredReceipts,
            let index = receipts.lastIndex(where: { $0.status != .reserved })
        {
            receipts.remove(at: index)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private func persist() {
        guard let file else { return }
        try? Places.makeOwnerOnly(file.deletingLastPathComponent())
        let payload = PersistedLedger(receipts: receipts, dailyCommittedMicroUSD: dailyCommittedMicroUSD)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
