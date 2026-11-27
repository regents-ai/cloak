import Foundation

/// Plain-English Private Cloud intent presets that hide underlying payment/provider
/// plumbing (`NEAR AI Gateway`, `Venice Base USDC`, `Boundless Tempo`, `zkAPI`)
/// while always remaining transparent about which verified rail was selected.
public enum SmartPrivatePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case coding
    case reasoning

    public var id: Self { self }

    public var title: String {
        switch self {
        case .fast: "Fast Private"
        case .coding: "Coding Private"
        case .reasoning: "Reasoning Private"
        }
    }

    public var shortTitle: String {
        switch self {
        case .fast: "Fast"
        case .coding: "Coding"
        case .reasoning: "Reasoning"
        }
    }

    public var summary: String {
        switch self {
        case .fast: "Lowest-latency private cloud route for quick everyday answers."
        case .coding: "Best code-capable private model across your funded rails."
        case .reasoning: "Deepest multi-step reasoning model across your funded rails."
        }
    }
}

/// Snapshot of which Private Cloud rails are currently funded or configured on this Mac.
public struct PrivateCloudAvailability: Equatable, Sendable {
    public var nearReady: Bool
    public var veniceReady: Bool
    public var boundlessReady: Bool
    public var zkapiReady: Bool

    public init(
        nearReady: Bool = false,
        veniceReady: Bool = false,
        boundlessReady: Bool = false,
        zkapiReady: Bool = false
    ) {
        self.nearReady = nearReady
        self.veniceReady = veniceReady
        self.boundlessReady = boundlessReady
        self.zkapiReady = zkapiReady
    }

    public var anyReady: Bool { nearReady || veniceReady || boundlessReady || zkapiReady }
}

/// The concrete Private Cloud rail resolved by `SmartPrivateRouter`.
public enum PrivateCloudRail: String, Equatable, Sendable {
    case near
    case venice
    case boundless
    case zkapi

    public var title: String {
        switch self {
        case .near: "NEAR TEE"
        case .venice: "Venice · Base"
        case .boundless: "Boundless · Tempo"
        case .zkapi: "zkAPI · Unlinkable"
        }
    }

    public var privacyBadge: String {
        switch self {
        case .near: "Hardware-attested TEE"
        case .venice: "Zero-retention · Base USDC"
        case .boundless: "Local rewrite · Tempo USDC.e"
        case .zkapi: "Unlinkable ZK proofs · Tor"
        }
    }
}

/// Deterministic routing output — never silently guesses or falls back to an unfunded rail.
public struct SmartPrivateDecision: Equatable, Sendable {
    public let preset: SmartPrivatePreset
    public let rail: PrivateCloudRail
    public let ready: Bool
    public let summary: String

    public init(preset: SmartPrivatePreset, rail: PrivateCloudRail, ready: Bool, summary: String) {
        self.preset = preset
        self.rail = rail
        self.ready = ready
        self.summary = summary
    }
}

/// Pure, deterministic router that maps a user's plain-English intent (`Fast`, `Coding`,
/// `Reasoning`) to the best currently funded/configured Private Cloud rail.
public enum SmartPrivateRouter {
    /// Preference order per preset across Cloak's Private Cloud rails:
    /// - `fast`: NEAR TEE (direct attested speed) -> Venice (Base USDC) -> Boundless -> zkAPI
    /// - `coding`: NEAR TEE -> Boundless (strong open coder catalog) -> Venice -> zkAPI
    /// - `reasoning`: zkAPI (strongest anonymity + Tier 25 reasoning) -> NEAR TEE -> Boundless -> Venice
    public static func resolve(
        preset: SmartPrivatePreset,
        availability: PrivateCloudAvailability
    ) -> SmartPrivateDecision {
        let order: [PrivateCloudRail] = switch preset {
        case .fast: [.near, .venice, .boundless, .zkapi]
        case .coding: [.near, .boundless, .venice, .zkapi]
        case .reasoning: [.zkapi, .near, .boundless, .venice]
        }

        for rail in order where isReady(rail, in: availability) {
            return SmartPrivateDecision(
                preset: preset,
                rail: rail,
                ready: true,
                summary: "\(preset.title) → \(rail.title) (\(rail.privacyBadge))")
        }

        // Nothing funded/configured yet — recommend the lowest-friction onramp rail explicitly.
        let suggested: PrivateCloudRail = (preset == .reasoning) ? .near : .venice
        return SmartPrivateDecision(
            preset: preset,
            rail: suggested,
            ready: false,
            summary: "Add funds with Stripe Link / Apple Pay or add a NEAR key to activate \(preset.title).")
    }

    private static func isReady(_ rail: PrivateCloudRail, in availability: PrivateCloudAvailability) -> Bool {
        switch rail {
        case .near: availability.nearReady
        case .venice: availability.veniceReady
        case .boundless: availability.boundlessReady
        case .zkapi: availability.zkapiReady
        }
    }
}
