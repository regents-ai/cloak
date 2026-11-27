import Foundation

/// Master app-wide Security & Privacy Profile governing which network modes,
/// Connected Apps rails, Inference Serving modes, and integrations are permitted.
/// Enforced both in UI (disabling disallowed controls) and fail-closed at routing boundaries.
public enum SecurityProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Zero cloud AI traffic: Local AI (built-in + loopback 127.0.0.1 servers),
    /// Local Access, Local Voice, Local CloakDoor ($0), and explicit model/offline-data downloads only.
    case localOnly
    /// Strictly anonymous cloud posture: Local AI + zkAPI Anon Inference ONLY.
    /// Forces Tor, Cover Traffic, and Local Prompt Rewriting ON; blocks account-linked or
    /// single-wallet cloud rails (NEAR, Venice, Boundless) and account-linked Network Serving.
    case anonCloud
    /// Full Private Cloud AI posture: unlocks all local + cloud rails (Local, NEAR TEE,
    /// Venice Base, Boundless Tempo, zkAPI Anon), Connected Apps on all 5 rails, and Inference Serving.
    case privateCloud

    public var id: Self { self }

    public var title: String {
        switch self {
        case .localOnly: "Local Only + Downloads"
        case .anonCloud: "Anon Private Cloud"
        case .privateCloud: "Private Cloud AI"
        }
    }

    public var shortTitle: String {
        switch self {
        case .localOnly: "Local Only"
        case .anonCloud: "Anon Cloud"
        case .privateCloud: "Private Cloud"
        }
    }

    public var symbol: String {
        switch self {
        case .localOnly: "lock.laptopcomputer"
        case .anonCloud: "theatermasks"
        case .privateCloud: "shield.lefthalf.filled"
        }
    }

    public var summary: String {
        switch self {
        case .localOnly:
            "Hard-blocks all cloud AI traffic, wallets, and network serving. Only Local AI (on this Mac or 127.0.0.1), Local Connected Apps, and explicit model/data downloads are allowed."
        case .anonCloud:
            "Allows Local AI and unlinkable zkAPI Anon Inference only, with Tor, Cover Traffic, and Local Prompt Rewriting locked ON. Blocks account-linked and single-wallet cloud rails."
        case .privateCloud:
            "Unlocks all Local and Private Cloud rails (NEAR TEE, Venice Base USDC, Boundless Tempo, zkAPI Anon), Connected Apps on every rail, Inference Serving, and integrations."
        }
    }

    public var allowedItems: [String] {
        switch self {
        case .localOnly:
            [
                "Local AI chat (built-in MLX/GGUF + loopback 127.0.0.1 servers)",
                "Connected Apps (CloakDoor) on Local ($0) rail with Privacy Shield",
                "Local Access, Saved Project Profiles, Local Voice, and explicit Model / Offline Data downloads",
            ]
        case .anonCloud:
            [
                "Everything in Local Only",
                "zkAPI Anon Inference (fresh one-time ZK keys over Tor + Cover Traffic + Local Prompt Rewriting)",
                "Connected Apps (CloakDoor) on Local ($0) and zkAPI Anon rails",
            ]
        case .privateCloud:
            [
                "All 4 Chat modes: Local, NEAR AI Gateway (TEE), Token Inference (Venice & Boundless), zkAPI Anon",
                "Connected Apps (CloakDoor) on all 5 rails (Local, NEAR, Venice, Boundless, zkAPI)",
                "Inference Serving (Network + Local) and external verified cloud integrations",
            ]
        }
    }

    public var blockedItems: [String] {
        switch self {
        case .localOnly:
            [
                "NEAR AI Gateway, Venice, Boundless, and zkAPI cloud requests",
                "Cloud wallet RPC reads and cloud Connected Apps billing",
                "Network Inference Serving and cloud integrations",
            ]
        case .anonCloud:
            [
                "Account-linked NEAR AI Gateway and single-wallet Venice / Boundless rails",
                "Direct non-Tor cloud traffic, disabling Cover Traffic, or turning off Prompt Rewriting",
                "Account-linked Network Inference Serving and non-anonymous integrations",
            ]
        case .privateCloud:
            [
                "None — all Cloak modes and integrations are available (each mode still enforces its own privacy boundaries)",
            ]
        }
    }

    // MARK: - Capability Predicates

    /// Whether NEAR AI Gateway (TEE, account API key) is allowed.
    public var allowsNear: Bool { self == .privateCloud }

    /// Whether Token Inference (Venice Base USDC & Boundless Tempo USDC.e) is allowed.
    public var allowsTokenInference: Bool { self == .privateCloud }

    /// Whether zkAPI Anon Inference (Ethereum ETH deposit + one-time ZK keys over Tor) is allowed.
    public var allowsZkAPI: Bool { self == .anonCloud || self == .privateCloud }

    /// Whether any remote cloud chat or cloud wallet network traffic is allowed.
    public var allowsAnyCloud: Bool { self != .localOnly }

    /// Whether account-linked Network Inference Serving (`Network + Local`) is allowed.
    public var allowsNetworkServing: Bool { self == .privateCloud }

    /// Whether Tor routing and Cover Traffic are locked ON for all cloud traffic.
    public var enforcesTorAndCover: Bool { self == .anonCloud }

    /// Whether Local Prompt Rewriting is locked ON for all cloud chat turns.
    public var enforcesPromptRewriting: Bool { self == .anonCloud }

    /// Whether third-party cloud integrations (e.g. Tinfoil, external cloud tools) are unlocked.
    public var allowsCloudIntegrations: Bool { self == .privateCloud }

    /// Plain-English refusal reason when an action is blocked by this Security Profile.
    public func refusalMessage(for feature: String) -> String {
        "\(feature) is disabled in \(shortTitle) profile. Switch to \(requiredProfile(for: feature).shortTitle) in Settings → General to enable it."
    }

    private func requiredProfile(for feature: String) -> SecurityProfile {
        let lower = feature.lowercased()
        if lower.contains("zkapi") || lower.contains("anon") {
            return .anonCloud
        }
        return .privateCloud
    }
}
