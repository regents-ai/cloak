import Foundation

/// Quality-of-Service guardrails for Mac Inference Serving (battery, thermal safety,
/// and quiet-hours scheduling) so Cloak's Serving tab protects laptop ergonomics better
/// than running a raw background daemon.
public struct ServingQoSPolicy: Codable, Equatable, Sendable {
    /// Pause network serving automatically while running on battery power.
    public var pauseOnBattery: Bool
    /// Pause network serving automatically when macOS reports serious or critical thermal pressure.
    public var pauseOnHighThermal: Bool
    /// Pause network serving during configured quiet hours (local 24-hour clock).
    public var quietHoursEnabled: Bool
    /// Inclusive start hour (0...23) when quiet hours begin (e.g. 9 = 9:00 AM).
    public var quietStartHour: Int
    /// Exclusive end hour (0...23) when quiet hours end (e.g. 18 = 6:00 PM).
    /// Supports overnight wrap-around (e.g. 22 -> 7 pauses 10 PM through 7 AM).
    public var quietEndHour: Int

    public static let `default` = ServingQoSPolicy(
        pauseOnBattery: true,
        pauseOnHighThermal: true,
        quietHoursEnabled: false,
        quietStartHour: 9,
        quietEndHour: 18)

    public init(
        pauseOnBattery: Bool = true,
        pauseOnHighThermal: Bool = true,
        quietHoursEnabled: Bool = false,
        quietStartHour: Int = 9,
        quietEndHour: Int = 18
    ) {
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnHighThermal = pauseOnHighThermal
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartHour = max(0, min(23, quietStartHour))
        self.quietEndHour = max(0, min(23, quietEndHour))
    }
}

/// Live host power, thermal, and local clock state sampled before evaluating `ServingQoSPolicy`.
public struct ServingHostCondition: Equatable, Sendable {
    public enum ThermalLevel: Int, Comparable, Equatable, Sendable {
        case nominal = 0
        case fair = 1
        case serious = 2
        case critical = 3

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .nominal
            }
        }
    }

    public var onBattery: Bool
    public var thermal: ThermalLevel
    /// Local hour of day (0...23).
    public var hour: Int

    public init(onBattery: Bool, thermal: ThermalLevel, hour: Int) {
        self.onBattery = onBattery
        self.thermal = thermal
        self.hour = ((hour % 24) + 24) % 24
    }
}

/// Deterministic QoS evaluation result.
public enum ServingQoSDecision: Equatable, Sendable {
    case allow
    case pause(reason: PauseReason)

    public enum PauseReason: Equatable, Sendable {
        case onBattery
        case highThermal
        case quietHours(start: Int, end: Int)

        public var summary: String {
            switch self {
            case .onBattery:
                "Paused on battery — plug in to resume earning."
            case .highThermal:
                "Paused for Mac thermal safety — resumes once cool."
            case .quietHours(let start, let end):
                "Paused during quiet hours (\(Self.formatHour(start))–\(Self.formatHour(end)))."
            }
        }

        private static func formatHour(_ h: Int) -> String {
            let normalized = ((h % 24) + 24) % 24
            let suffix = normalized >= 12 ? "PM" : "AM"
            let display = normalized % 12 == 0 ? 12 : normalized % 12
            return "\(display)\(suffix)"
        }
    }
}

/// Pure QoS evaluator, Earn-to-Spend translator, and pluggable Serving Network catalog.
public enum ServingQoS {
    public static func evaluate(
        policy: ServingQoSPolicy,
        condition: ServingHostCondition
    ) -> ServingQoSDecision {
        if policy.pauseOnHighThermal, condition.thermal >= .serious {
            return .pause(reason: .highThermal)
        }
        if policy.pauseOnBattery, condition.onBattery {
            return .pause(reason: .onBattery)
        }
        if policy.quietHoursEnabled, isInQuietHours(hour: condition.hour, start: policy.quietStartHour, end: policy.quietEndHour) {
            return .pause(reason: .quietHours(start: policy.quietStartHour, end: policy.quietEndHour))
        }
        return .allow
    }

    public static func isInQuietHours(hour: Int, start: Int, end: Int) -> Bool {
        let h = ((hour % 24) + 24) % 24
        let s = ((start % 24) + 24) % 24
        let e = ((end % 24) + 24) % 24
        guard s != e else { return false }
        if s < e {
            return h >= s && h < e
        } else {
            // Overnight wrap-around (e.g. 22:00 -> 07:00)
            return h >= s || h < e
        }
    }

    /// Translates micro-USD serving earnings into an intuitive Private Cloud / coding-prompt
    /// equivalent (~$0.005 / 5,000 micro-USD per average private coding turn).
    public static func equivalentPrivatePrompts(microUSD: UInt64) -> Int {
        guard microUSD > 0 else { return 0 }
        return Int(microUSD / 5_000)
    }

    /// Human-readable "Earn -> Spend" caption for the Serving earnings card.
    public static func earnToSpendCaption(microUSD: UInt64) -> String? {
        let prompts = equivalentPrivatePrompts(microUSD: microUSD)
        guard prompts >= 1 else { return nil }
        return prompts == 1
            ? "Offsets ~1 private cloud coding prompt"
            : "Offsets ~\(prompts.formatted()) private cloud coding prompts"
    }
}

/// Pluggable Serving Network catalog preparing Cloak's Serving tab for multi-network
/// selection (`Darkbloom` active today; `Antseed` Mac Colony & `Gonka` under evaluation).
public struct ServingNetworkDescriptor: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case active = "Active"
        case evaluating = "Researching"
    }

    public let id: String
    public let name: String
    public let settlement: String
    public let status: Status
    public let summary: String

    public static let catalog: [ServingNetworkDescriptor] = [
        ServingNetworkDescriptor(
            id: "darkbloom",
            name: "Darkbloom",
            settlement: "Account balance · console.darkbloom.dev",
            status: .active,
            summary: "Native Swift/MLX serving on macOS 27+ with local-first priority and idle-only network routing."),
        ServingNetworkDescriptor(
            id: "antseed",
            name: "Antseed (Mac Colony)",
            settlement: "USDC on Base + $ANTS",
            status: .evaluating,
            summary: "P2P inference marketplace with Base USDC payment channels and Mac Colony workload pooling."),
        ServingNetworkDescriptor(
            id: "gonka",
            name: "Gonka",
            settlement: "Network rewards (DePIN)",
            status: .evaluating,
            summary: "Decentralized verifiable AI compute protocol with emerging Apple Silicon node support."),
    ]
}
