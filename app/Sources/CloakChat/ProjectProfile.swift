import Foundation

/// A saved, per-project workspace profile that isolates local folders, Privacy Shield
/// private terms, preferred inference rail, and optional Local Mode project notes across
/// Chat and Connected Apps (`CloakDoor`). Completely unlocked during beta.
public struct ProjectProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum RoutePreference: String, CaseIterable, Identifiable, Codable, Sendable {
        case keepCurrent
        case local
        case near
        case venice
        case boundless
        case zkapi

        public var id: Self { self }

        public var title: String {
            switch self {
            case .keepCurrent: "Keep current mode"
            case .local: "Local AI ($0 · on this Mac)"
            case .near: "NEAR AI Gateway (TEE)"
            case .venice: "Venice (Base USDC)"
            case .boundless: "Boundless (Tempo USDC.e)"
            case .zkapi: "zkAPI Anon Inference"
            }
        }

        public var shortTitle: String {
            switch self {
            case .keepCurrent: "Any mode"
            case .local: "Local ($0)"
            case .near: "NEAR TEE"
            case .venice: "Venice"
            case .boundless: "Boundless"
            case .zkapi: "zkAPI Anon"
            }
        }
    }

    public var id: UUID
    public var name: String
    /// Read-only local folders strictly scoped to this project in Local Mode.
    public var approvedFolders: [String]
    /// Comma- or newline-separated confidential names, organizations, or repo slugs
    /// automatically shielded by `CloakDoor`'s `PrivacyShield` when this project is active.
    public var privateTerms: String
    /// Optional preferred inference rail applied when activating this project.
    public var route: RoutePreference
    /// Optional Connected Apps model override when this project is active.
    public var doorModelOverride: String
    /// Short local-only project brief injected strictly in Local Mode (never sent to cloud rails).
    public var localNotes: String
    public var createdAt: Date
    public var updatedAt: Date

    public static let localNotesLimit = 1_500

    public init(
        id: UUID = UUID(),
        name: String,
        approvedFolders: [String] = [],
        privateTerms: String = "",
        route: RoutePreference = .keepCurrent,
        doorModelOverride: String = "",
        localNotes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.approvedFolders = Self.deduplicatedPaths(approvedFolders)
        self.privateTerms = privateTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        self.route = route
        self.doorModelOverride = doorModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localNotes = Self.clampedNotes(localNotes)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Parsed non-empty private terms for display counts and merging.
    public var parsedPrivateTerms: [String] {
        privateTerms
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    /// Formatted local-only project context block for Local Mode prompts (never sent to cloud).
    public var localContextBlock: String? {
        let trimmed = localNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "[Project Profile: \(name)]\n\(trimmed)"
    }

    /// Compact summary of what this profile isolates.
    public var summaryParts: [String] {
        var parts: [String] = []
        if route != .keepCurrent { parts.append(route.shortTitle) }
        if !approvedFolders.isEmpty {
            parts.append(approvedFolders.count == 1 ? "1 folder" : "\(approvedFolders.count) folders")
        }
        let termCount = parsedPrivateTerms.count
        if termCount > 0 {
            parts.append(termCount == 1 ? "1 shielded term" : "\(termCount) shielded terms")
        }
        if !localNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Local notes")
        }
        return parts
    }

    public static func clampedNotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > localNotesLimit else { return trimmed }
        return String(trimmed.prefix(localNotesLimit))
    }

    public static func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

/// Pure helpers combining an optional active `ProjectProfile` with global Cloak defaults
/// while preserving strict isolation between projects.
public enum ProjectProfileResolver {
    /// When a project profile is active, Local Mode searches ONLY that project's approved
    /// folders so files from other projects or global folders are never mixed in.
    public static func effectiveApprovedFolders(
        active: ProjectProfile?,
        globalFolders: [String]
    ) -> [String] {
        if let active {
            return active.approvedFolders
        }
        return globalFolders
    }

    /// Merges global Private Terms with the active project's Private Terms so activating a
    /// project immediately shields its names, companies, and repo slugs in `CloakDoor`.
    public static func mergedPrivateTermsRaw(
        active: ProjectProfile?,
        globalTermsRaw: String
    ) -> String {
        guard let active, !active.privateTerms.isEmpty else { return globalTermsRaw }
        if globalTermsRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return active.privateTerms
        }
        return "\(globalTermsRaw)\n\(active.privateTerms)"
    }

    /// Prefers the active project's Connected Apps model override when non-empty.
    public static func effectiveDoorModel(
        active: ProjectProfile?,
        globalModel: String?
    ) -> String? {
        if let override = active?.doorModelOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return override
        }
        let global = globalModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (global?.isEmpty == false) ? global : nil
    }
}
