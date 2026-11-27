import Foundation

/// Explicit payment protocol identifiers so Cloak keeps networks, assets,
/// payment protocols, and privacy properties strictly separated.
public enum PaymentProtocol: String, Codable, Hashable, Sendable, CaseIterable {
    case zkapiETHDeposit = "zkapi_eth_deposit"
    case x402
    case mpp
    case circleCCTP = "circle_cctp"
    case circleGateway = "circle_gateway"

    public var label: String {
        switch self {
        case .zkapiETHDeposit: "zkAPI ETH Deposit"
        case .x402: "x402"
        case .mpp: "MPP"
        case .circleCCTP: "Circle CCTP"
        case .circleGateway: "Circle Gateway"
        }
    }
}

/// Reviewed single-source manifest for Cloak's four payment networks:
/// Ethereum mainnet, Base, Tempo, and Arc.
///
/// Keeps EVM chain IDs, Circle CCTP/Gateway domain IDs, asset decimals,
/// settlement latency, and privacy boundaries explicit in one place.
public struct PaymentNetwork: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum ID: String, Codable, CaseIterable, Hashable, Sendable {
        case ethereum
        case base
        case tempo
        case arc
    }

    public let id: ID
    public let name: String
    public let chainID: UInt64
    /// Circle CCTP / Gateway domain ID (`nil` for Tempo, which is outside Circle's domain tables).
    public let circleDomain: UInt32?
    public let rpcURL: String
    public let nativeAsset: String
    /// Native balance / gas precision (`18` on Ethereum, Base, and Arc; `6` on Tempo).
    public let nativeDecimals: Int
    /// Primary USD stablecoin symbol used on this network.
    public let stableAsset: String
    /// ERC-20 stablecoin contract precision (`6` across Ethereum, Base, Tempo, and Arc).
    public let erc20StableDecimals: Int
    public let supportedProtocols: [PaymentProtocol]
    /// Honest Circle Gateway standard-deposit availability window (`nil` when unsupported).
    public let gatewayStandardDepositETA: String?
    /// Explicit privacy boundary: Arc privacy sector is not yet deployed on mainnet.
    public let supportsOnChainPrivacy: Bool
    public let roleSummary: String

    public static let arcTestnetChainID: UInt64 = 5_042_002

    public static let ethereum = PaymentNetwork(
        id: .ethereum,
        name: "Ethereum",
        chainID: 1,
        circleDomain: 0,
        rpcURL: "https://ethereum-rpc.publicnode.com",
        nativeAsset: "ETH",
        nativeDecimals: 18,
        stableAsset: "USDC",
        erc20StableDecimals: 6,
        supportedProtocols: [.zkapiETHDeposit, .circleCCTP, .circleGateway],
        gatewayStandardDepositETA: "~13–19 min",
        supportsOnChainPrivacy: false,
        roleSummary: "ETH deposits for unlinkable zkAPI Anon Inference; USDC transfers via CCTP/Gateway."
    )

    public static let base = PaymentNetwork(
        id: .base,
        name: "Base",
        chainID: 8453,
        circleDomain: 6,
        rpcURL: "https://mainnet.base.org",
        nativeAsset: "ETH",
        nativeDecimals: 18,
        stableAsset: "USDC",
        erc20StableDecimals: 6,
        supportedProtocols: [.x402, .circleCCTP, .circleGateway],
        gatewayStandardDepositETA: "~13–19 min",
        supportsOnChainPrivacy: false,
        roleSummary: "Base USDC x402 payments (Venice & merchant services) and CCTP/Gateway funding."
    )

    public static let tempo = PaymentNetwork(
        id: .tempo,
        name: "Tempo",
        chainID: 4217,
        circleDomain: nil,
        rpcURL: "https://rpc.tempo.xyz",
        nativeAsset: "USDC.e",
        nativeDecimals: 6,
        stableAsset: "USDC.e",
        erc20StableDecimals: 6,
        supportedProtocols: [.mpp],
        gatewayStandardDepositETA: nil,
        supportsOnChainPrivacy: false,
        roleSummary: "Boundless MPP token inference adapter using Tempo USDC.e (dedicated adapter, outside Circle CCTP)."
    )

    public static let arc = PaymentNetwork(
        id: .arc,
        name: "Arc",
        chainID: 5042,
        circleDomain: 26,
        rpcURL: "https://rpc.mainnet.arc.io",
        nativeAsset: "USDC",
        nativeDecimals: 18,
        stableAsset: "USDC",
        erc20StableDecimals: 6,
        supportedProtocols: [.x402, .circleCCTP, .circleGateway],
        gatewayStandardDepositETA: "~0.5 sec",
        supportsOnChainPrivacy: false,
        roleSummary: "USDC-gas operating balances, bounded agent purchases, and x402 service settlement (public ledger — not anonymous)."
    )

    public static let all: [PaymentNetwork] = [.ethereum, .base, .tempo, .arc]

    public static func network(for id: ID) -> PaymentNetwork {
        switch id {
        case .ethereum: .ethereum
        case .base: .base
        case .tempo: .tempo
        case .arc: .arc
        }
    }

    public static func network(chainID: UInt64) -> PaymentNetwork? {
        all.first { $0.chainID == chainID }
    }

    public static func network(circleDomain: UInt32) -> PaymentNetwork? {
        all.first { $0.circleDomain == circleDomain }
    }
}

/// Exact representation of an Arc USDC amount bridging Arc's two precision
/// interfaces over the same underlying balance:
/// - **ERC-20 interface:** 6 decimals (`1 USDC = 1_000_000`)
/// - **Native value / gas interface:** 18 decimals (`1 USDC = 1_000_000_000_000_000_000`)
///
/// Uses integer micro-units (`10^-6 USD`) internally to avoid binary floating-point drift.
public struct ArcUSDC: Codable, Equatable, Hashable, Comparable, Sendable {
    /// Exact 6-decimal USDC micro-units (`$1.00 == 1_000_000`).
    public let microUnits: UInt64

    public static let zero = ArcUSDC(microUnits: 0)
    public static let oneDollar = ArcUSDC(microUnits: 1_000_000)

    public init(microUnits: UInt64) {
        self.microUnits = microUnits
    }

    /// 6-decimal ERC-20 USDC integer units (`1 USDC = 10^6`).
    public var erc20Units: UInt64 { microUnits }

    /// 18-decimal Arc native balance / transaction value units (`1 USDC = 10^18`),
    /// returned as an exact base-10 integer string so large values never overflow `UInt64`.
    public var nativeWeiDecimalString: String {
        guard microUnits > 0 else { return "0" }
        return "\(microUnits)000000000000"
    }

    /// Converts an 18-decimal Arc native base-10 integer string into exact
    /// 6-decimal `ArcUSDC` micro-units (truncating sub-micro-USDC dust).
    public static func fromNativeWei(_ decimalString: String) -> ArcUSDC? {
        let trimmed = decimalString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber) else {
            return nil
        }
        let stripped = String(trimmed.drop(while: { $0 == "0" }))
        if stripped.isEmpty { return .zero }
        if stripped.count <= 12 { return .zero }
        let microDigits = String(stripped.dropLast(12))
        guard let micro = UInt64(microDigits) else { return nil }
        return ArcUSDC(microUnits: micro)
    }

    /// Parses a human USD string like `"5"`, `"$0.50"`, or `"12.345678"` strictly
    /// into 6-decimal micro-units without floating-point rounding.
    public static func parseUSD(_ input: String) -> ArcUSDC? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$") { s.removeFirst() }
        s = s.replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty, !s.hasPrefix("-") else { return nil }
        let parts = s.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeStr = parts[0].isEmpty ? "0" : String(parts[0])
        let fracStr = parts.count == 2 ? String(parts[1]) : ""
        guard wholeStr.allSatisfy(\.isNumber), fracStr.allSatisfy(\.isNumber), fracStr.count <= 6 else {
            return nil
        }
        guard let whole = UInt64(wholeStr) else { return nil }
        let paddedFrac = fracStr + String(repeating: "0", count: 6 - fracStr.count)
        guard let frac = UInt64(paddedFrac) else { return nil }
        let (scaledWhole, overflow1) = whole.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow1 else { return nil }
        let (total, overflow2) = scaledWhole.addingReportingOverflow(frac)
        guard !overflow2 else { return nil }
        return ArcUSDC(microUnits: total)
    }

    /// Human-readable USD string (always at least 2 decimal places, up to 4 for sub-cent amounts).
    public var formattedUSD: String {
        let dollars = microUnits / 1_000_000
        let remainder = microUnits % 1_000_000
        let cents = remainder / 10_000
        let subCents = remainder % 10_000
        if subCents == 0 {
            return String(format: "$%llu.%02llu", dollars, cents)
        }
        var frac = String(format: "%06llu", remainder)
        while frac.count > 2 && frac.last == "0" {
            frac.removeLast()
        }
        return "$\(dollars).\(frac)"
    }

    public static func < (lhs: ArcUSDC, rhs: ArcUSDC) -> Bool {
        lhs.microUnits < rhs.microUnits
    }
}

/// Deduplication key for Arc settlement events: a single ERC-20 USDC transfer
/// on Arc emits both an ERC-20 `Transfer` log and a native system event.
/// Keying transfers by `(txHash, from, to, amount)` prevents double-counting.
public struct ArcTransferDeduplicator: Sendable {
    public struct TransferKey: Hashable, Sendable {
        public let txHash: String
        public let from: String
        public let to: String
        public let microUnits: UInt64

        public init(txHash: String, from: String, to: String, microUnits: UInt64) {
            self.txHash = txHash.lowercased()
            self.from = from.lowercased()
            self.to = to.lowercased()
            self.microUnits = microUnits
        }
    }

    private var seen: Set<TransferKey> = []

    public init() {}

    /// Returns `true` the first time this transfer is observed and `false` for
    /// duplicate ERC-20 / native-system mirror events from the same transaction.
    public mutating func recordIfNew(_ key: TransferKey) -> Bool {
        seen.insert(key).inserted
    }
}
