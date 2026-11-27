import Foundation

/// Configuration snapshot for `CloakDoor`'s pre-send Privacy Shield.
public struct PrivacyShieldPolicy: Equatable, Sendable {
    /// Hard-block outbound requests containing credentials, private keys, or `.env` secrets
    /// before any network call or spend reservation runs.
    public var blockSecrets: Bool
    /// Replace private entities (custom Private Terms, ETH addresses, ENS names, home paths,
    /// emails, and non-loopback IPv4 addresses) with stable per-app aliases before sending,
    /// then restore them in human-facing assistant replies.
    public var maskEntities: Bool
    /// User-configured private terms (names, companies, private repo slugs, internal domains).
    public var privateTerms: [String]

    public static let disabled = PrivacyShieldPolicy(blockSecrets: false, maskEntities: false, privateTerms: [])

    public init(blockSecrets: Bool = true, maskEntities: Bool = true, privateTerms: [String] = []) {
        self.blockSecrets = blockSecrets
        self.maskEntities = maskEntities
        self.privateTerms = privateTerms
    }

    public var isActive: Bool { blockSecrets || maskEntities }

    /// Parses comma- or newline-separated private terms, trimming whitespace and dropping
    /// empty or single-character noise while preserving user order.
    public static func parsePrivateTerms(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for token in raw.components(separatedBy: CharacterSet(charactersIn: ",\n\r;")) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

/// A deterministic pre-send secret tripwire match. Never retains the raw secret value.
public struct SecretFinding: Equatable, Sendable {
    public let kind: String

    public init(kind: String) {
        self.kind = kind
    }
}

/// Conversation/app-local reversible alias map kept strictly in memory.
///
/// Maps sensitive developer and crypto entities (custom private terms, Ethereum addresses
/// including repetitive/low-entropy examples like `0x000...001`, ENS names, macOS/Linux home
/// paths, email addresses, and non-loopback IPv4 addresses) to stable aliases such as
/// `[ENTITY_1]`, `[ETH_1]`, `[ENS_1]`, `[PATH_1]`, `[EMAIL_1]`, `[IP_1]`, and restores them
/// on assistant text responses.
public struct RedactionMap: Sendable {
    private var forward: [String: String] = [:]
    private var reverse: [String: String] = [:]
    private var counters: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { reverse.isEmpty }
    public var count: Int { reverse.count }
    public var aliases: [String: String] { reverse }

    /// Masks sensitive entities in `text`, mutating the map to assign stable aliases across
    /// repeated mentions and turns. Returns the masked text and number of substitutions made.
    public mutating func mask(_ text: String, privateTerms: [String] = []) -> (masked: String, replacements: Int) {
        guard !text.isEmpty else { return (text, 0) }
        var current = text
        var total = 0

        // 1. Structured developer & crypto patterns first so whole paths/emails/ENS/addresses
        //    become a single coherent alias rather than partial fragments.
        let structured: [(kind: String, regex: NSRegularExpression, filter: ((String) -> Bool)?)] = [
            ("PATH", Self.homePathRegex, nil),
            ("EMAIL", Self.emailRegex, nil),
            ("ETH", Self.ethAddressRegex, nil),
            ("ENS", Self.ensRegex, nil),
            ("IP", Self.ipv4Regex, { match in
                match != "127.0.0.1" && match != "0.0.0.0" && !match.hasPrefix("127.")
            }),
        ]

        for rule in structured {
            let (updated, count) = replaceMatches(in: current, regex: rule.regex, kind: rule.kind, caseInsensitiveKey: rule.kind != "PATH") { match in
                if Self.isAliasToken(match) { return false }
                if let filter = rule.filter, !filter(match) { return false }
                return true
            }
            current = updated
            total += count
        }

        // 2. User-configured private terms (longest first so multi-word names/orgs win over substrings).
        let sortedTerms = privateTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }

        for term in sortedTerms {
            guard let regex = Self.termRegex(for: term) else { continue }
            let (updated, count) = replaceMatches(
                in: current,
                regex: regex,
                kind: "ENTITY",
                caseInsensitiveKey: true,
                canonicalOriginal: term
            ) { match in
                !Self.isAliasToken(match)
            }
            current = updated
            total += count
        }

        return (current, total)
    }

    /// Restores all known aliases in `text` back to their original values.
    public func restore(_ text: String) -> String {
        guard !reverse.isEmpty, !text.isEmpty, text.contains("[") else { return text }
        var result = text
        // Replace longest aliases first so e.g. `[ENTITY_10]` is never collided with shorter keys
        // (even though `]` terminates every alias cleanly).
        for (alias, original) in reverse.sorted(by: { $0.key.count > $1.key.count }) {
            if result.contains(alias) {
                result = result.replacingOccurrences(of: alias, with: original)
            }
        }
        return result
    }

    /// Returns true if `candidate` is a strict prefix of any alias stored in this map.
    func isAliasPrefix(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("["), !reverse.isEmpty else { return false }
        for alias in reverse.keys {
            if alias.hasPrefix(candidate) && candidate.count < alias.count {
                return true
            }
        }
        return false
    }

    // MARK: - Internal helpers

    private mutating func alias(for original: String, kind: String, caseInsensitiveKey: Bool, canonicalOriginal: String? = nil) -> String {
        let lookupKey = "\(kind):\(caseInsensitiveKey ? original.lowercased() : original)"
        if let existing = forward[lookupKey] {
            return existing
        }
        let next = (counters[kind] ?? 0) + 1
        counters[kind] = next
        let token = "[\(kind)_\(next)]"
        forward[lookupKey] = token
        reverse[token] = canonicalOriginal ?? original
        return token
    }

    private mutating func replaceMatches(
        in text: String,
        regex: NSRegularExpression,
        kind: String,
        caseInsensitiveKey: Bool,
        canonicalOriginal: String? = nil,
        accept: (String) -> Bool
    ) -> (String, Int) {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        // Avoid replacing inside existing `[KIND_N]` tokens.
        let aliasRanges = Self.aliasRegex.matches(in: text, options: [], range: fullRange).map(\.range)

        var output = ""
        output.reserveCapacity(text.count)
        var cursor = 0
        var count = 0

        for match in matches {
            let range = match.range
            guard range.location >= cursor else { continue }
            let overlapsExistingAlias = aliasRanges.contains { NSIntersectionRange($0, range).length > 0 }
            guard !overlapsExistingAlias else { continue }

            let value = ns.substring(with: range)
            guard accept(value) else { continue }

            if range.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            output += alias(for: value, kind: kind, caseInsensitiveKey: caseInsensitiveKey, canonicalOriginal: canonicalOriginal)
            cursor = range.location + range.length
            count += 1
        }

        if count == 0 { return (text, 0) }
        if cursor < ns.length {
            output += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return (output, count)
    }

    private static func isAliasToken(_ value: String) -> Bool {
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        return aliasRegex.firstMatch(in: value, options: [], range: range)?.range == range
    }

    private static func termRegex(for term: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let startsWord = term.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        let endsWord = term.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        let prefix = startsWord ? "(?<![A-Za-z0-9_])" : ""
        let suffix = endsWord ? "(?![A-Za-z0-9_])" : ""
        return try? NSRegularExpression(pattern: "\(prefix)\(escaped)\(suffix)", options: [.caseInsensitive])
    }

    private static let aliasRegex = try! NSRegularExpression(
        pattern: #"\[(?:ENTITY|EMAIL|ETH|ENS|PATH|IP)_\d+\]"#)
    private static let homePathRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])/(?:Users|home)/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._@%+-]+)*"#)
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?![A-Za-z0-9._%+-])"#)
    private static let ethAddressRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9a-fA-F])0x[0-9a-fA-F]{40}(?![0-9a-fA-F])"#)
    private static let ensRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._@-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+eth(?![A-Za-z0-9._-])"#,
        options: [.caseInsensitive])
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"(?<![0-9.])(?:(?:25[0-5]|2[0-4]\d|1?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|1?\d\d?)(?![0-9.])"#)
}

/// Chunk-boundary-safe incremental alias restorer for streamed assistant responses.
///
/// Buffers any trailing `[` suffix that is a strict prefix of a known alias in `map`
/// until either the closing `]` arrives or a non-matching character proves it is literal text.
public struct StreamingUnscrubber: Sendable {
    private let map: RedactionMap
    private var pending = ""

    public init(map: RedactionMap) {
        self.map = map
    }

    /// Feeds the next streamed text chunk and returns the safe restored prefix ready to emit.
    public mutating func push(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        pending += chunk
        guard !map.isEmpty else {
            let out = pending
            pending = ""
            return out
        }

        // Replace any complete aliases currently in `pending`.
        let replaced = map.restore(pending)

        // Hold back only a trailing partial `[` suffix if it is a strict prefix of a known alias.
        if let bracket = replaced.lastIndex(of: "[") {
            let tail = String(replaced[bracket...])
            if map.isAliasPrefix(tail) {
                let emit = String(replaced[..<bracket])
                pending = tail
                return emit
            }
        }

        pending = ""
        return replaced
    }

    /// Flushes any buffered tail at end-of-stream.
    public mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let out = map.restore(pending)
        pending = ""
        return out
    }
}

/// Pre-send Secret Tripwire and Reversible Alias Shield for `CloakDoor`.
public enum PrivacyShield {
    private struct SecretRule {
        let kind: String
        let regex: NSRegularExpression
    }

    private static let secretRules: [SecretRule] = [
        SecretRule(
            kind: "Private Key (PEM)",
            regex: try! NSRegularExpression(pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#)),
        SecretRule(
            kind: "AWS Access Key",
            regex: try! NSRegularExpression(pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#)),
        SecretRule(
            kind: "Anthropic API Key",
            regex: try! NSRegularExpression(pattern: #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#)),
        SecretRule(
            kind: "OpenAI API Key",
            regex: try! NSRegularExpression(pattern: #"\bsk-(?!ant-)(?:proj-|svcacct-|live-)?[A-Za-z0-9_-]{20,}\b"#)),
        SecretRule(
            kind: "GitHub Token",
            regex: try! NSRegularExpression(pattern: #"\b(?:(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})\b"#)),
        SecretRule(
            kind: "Stripe Live Key",
            regex: try! NSRegularExpression(pattern: #"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b"#)),
        SecretRule(
            kind: "Slack Token",
            regex: try! NSRegularExpression(pattern: #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#)),
        SecretRule(
            kind: "JWT",
            regex: try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#)),
        SecretRule(
            kind: "Wallet Private Key",
            regex: try! NSRegularExpression(
                pattern: #"(?i)(?:private[_ -]?key|privkey|wallet[_ -]?key|eth[_ -]?key|signer[_ -]?key)[\s:=]+["']?(?:0x)?[0-9a-f]{64}\b"#)),
    ]

    private static let envSecretKeyRegex = try! NSRegularExpression(
        pattern: #"(?i)\b[A-Z0-9_]{0,40}(?:API_KEY|SECRET_KEY|PRIVATE_KEY|ACCESS_TOKEN|AUTH_TOKEN|CLIENT_SECRET|DATABASE_URL|PASSWORD|MNEMONIC|SEED_PHRASE)[ \t]*[:=][ \t]*["']?(?!\[[A-Z]+_\d+\]|<[^>]+>|\$\{?[A-Za-z0-9_]+\}?|your[_-]|changeme|example|placeholder|xxx|redacted|cloak-[0-9a-f]{64}\b)([^\s"'`,;)]{12,})"#)

    private static let envSecretHints = [
        "api_key", "secret_key", "private_key", "access_token", "auth_token",
        "client_secret", "database_url", "password", "mnemonic", "seed_phrase",
    ]

    /// Deterministic `< 1 ms` scan for credentials and private keys. Returns deduplicated kinds.
    public static func detectSecrets(in text: String) -> [SecretFinding] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        var seen: Set<String> = []
        var findings: [SecretFinding] = []
        for rule in secretRules {
            if rule.regex.firstMatch(in: text, options: [], range: range) != nil {
                if seen.insert(rule.kind).inserted {
                    findings.append(SecretFinding(kind: rule.kind))
                }
            }
        }
        // Fast literal keyword pre-check avoids regex backtracking across large 128 KB+ tool_results.
        if text.contains("=") || text.contains(":") {
            let lowered = text.lowercased()
            if envSecretHints.contains(where: { lowered.contains($0) }),
                envSecretKeyRegex.firstMatch(in: text, options: [], range: range) != nil,
                seen.insert("Env Secret").inserted
            {
                findings.append(SecretFinding(kind: "Env Secret"))
            }
        }
        return findings
    }

    /// Scans all text values across the ENTIRE outbound OpenAI chat-completions JSON
    /// (`messages[]`, `tools[]`, `functions[]`, `system`, `instructions`, `metadata`, etc.)
    /// for secrets. Used as an instant fail-fast pre-check before touching models, rewriter, or Tor.
    public static func scanRequestJSONForSecrets(_ body: Data) -> [SecretFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var seen: Set<String> = []
        var all: [SecretFinding] = []
        collectSecrets(in: root, seen: &seen, findings: &all)
        return all
    }

    /// Applies the Privacy Shield to the final assembled OpenAI outbound JSON body right before
    /// transport:
    /// 1. Hard-blocks on any secret finding across the entire outbound payload (`messages`,
    ///    `tools`, `functions`, `system`, `instructions`, `metadata`, and nested tool results).
    /// 2. Masks sensitive entities across message text values, tool/function descriptions &
    ///    schema documentation, top-level system/instructions, and metadata using the app's
    ///    in-memory `RedactionMap`, preserving JSON structural keys, tool names, and media data URIs.
    static func protectRequestJSON(
        _ body: Data,
        map: inout RedactionMap,
        policy: PrivacyShieldPolicy
    ) throws(Failure) -> (data: Data, maskedCount: Int) {
        guard policy.isActive else { return (body, 0) }
        guard var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return (body, 0) }

        if policy.blockSecrets {
            var seen: Set<String> = []
            var findings: [SecretFinding] = []
            collectSecrets(in: root, seen: &seen, findings: &findings)
            if !findings.isEmpty {
                let summary = findings.map(\.kind).joined(separator: ", ")
                throw Failure(
                    400,
                    "secret_blocked",
                    "Blocked before sending: detected \(summary) in outbound request. Remove the secret and retry.")
            }
        }

        guard policy.maskEntities else { return (body, 0) }

        var totalMasked = 0
        if var messages = root["messages"] as? [[String: Any]] {
            var msgMasked = 0
            for index in messages.indices {
                msgMasked += maskMessage(&messages[index], map: &map, privateTerms: policy.privateTerms)
            }
            if msgMasked > 0 {
                root["messages"] = messages
                totalMasked += msgMasked
            }
        }
        if var tools = root["tools"] as? [[String: Any]] {
            var toolMasked = 0
            for index in tools.indices {
                toolMasked += maskToolDefinition(&tools[index], map: &map, privateTerms: policy.privateTerms)
            }
            if toolMasked > 0 {
                root["tools"] = tools
                totalMasked += toolMasked
            }
        }
        if var functions = root["functions"] as? [[String: Any]] {
            var fnMasked = 0
            for index in functions.indices {
                fnMasked += maskFunctionSpec(&functions[index], map: &map, privateTerms: policy.privateTerms)
            }
            if fnMasked > 0 {
                root["functions"] = functions
                totalMasked += fnMasked
            }
        }
        for topKey in ["system", "instructions"] {
            if let text = root[topKey] as? String {
                let (masked, replaced) = map.mask(text, privateTerms: policy.privateTerms)
                if replaced > 0 {
                    root[topKey] = masked
                    totalMasked += replaced
                }
            } else if var parts = root[topKey] as? [[String: Any]] {
                var changed = false
                for idx in parts.indices {
                    if let text = parts[idx]["text"] as? String {
                        let (masked, replaced) = map.mask(text, privateTerms: policy.privateTerms)
                        if replaced > 0 {
                            parts[idx]["text"] = masked
                            changed = true
                            totalMasked += replaced
                        }
                    }
                }
                if changed { root[topKey] = parts }
            }
        }
        if var metadata = root["metadata"] as? [String: Any] {
            let metaMasked = maskStringValuesRecursively(&metadata, map: &map, privateTerms: policy.privateTerms)
            if metaMasked > 0 {
                root["metadata"] = metadata
                totalMasked += metaMasked
            }
        }

        guard totalMasked > 0 else { return (body, 0) }
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return (body, 0)
        }
        return (encoded, totalMasked)
    }

    /// Restores aliases in an OpenAI chat-completion response JSON ONLY inside human-facing
    /// assistant text (`choices[].message.content`), never inside model-generated `tool_calls`
    /// or `function_call` arguments (preventing prompt-injected tool exfiltration).
    public static func restoreCompletionJSON(_ completion: Data, map: RedactionMap) -> (data: Data, restoredCount: Int) {
        guard !map.isEmpty else { return (completion, 0) }
        guard var root = try? JSONSerialization.jsonObject(with: completion) as? [String: Any],
            var choices = root["choices"] as? [[String: Any]]
        else { return (completion, 0) }

        var changed = 0
        for i in choices.indices {
            guard var message = choices[i]["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String {
                let restored = map.restore(text)
                if restored != text {
                    message["content"] = restored
                    choices[i]["message"] = message
                    changed += 1
                }
            } else if var parts = message["content"] as? [[String: Any]] {
                var partsChanged = false
                for j in parts.indices {
                    if let text = parts[j]["text"] as? String {
                        let restored = map.restore(text)
                        if restored != text {
                            parts[j]["text"] = restored
                            partsChanged = true
                            changed += 1
                        }
                    }
                }
                if partsChanged {
                    message["content"] = parts
                    choices[i]["message"] = message
                }
            }
        }

        guard changed > 0 else { return (completion, 0) }
        root["choices"] = choices
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) else {
            return (completion, 0)
        }
        return (encoded, changed)
    }

    // MARK: - Recursive JSON Helpers

    private static func collectSecrets(in value: Any, seen: inout Set<String>, findings: inout [SecretFinding]) {
        if let string = value as? String {
            // Skip base64 data URIs (images/files) so random base64 runs don't false-positive.
            if string.hasPrefix("data:") { return }
            for finding in detectSecrets(in: string) where seen.insert(finding.kind).inserted {
                findings.append(finding)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectSecrets(in: item, seen: &seen, findings: &findings)
            }
        } else if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                if key == "model" || key == "role" || key == "type" || key == "tool_call_id"
                    || key == "id" || key == "file_data" || key == "reasoning_effort"
                {
                    continue
                }
                collectSecrets(in: nested, seen: &seen, findings: &findings)
            }
        }
    }

    /// Masks human-readable descriptive fields in an OpenAI `tools[]` entry (`description`
    /// and nested JSON schema documentation) without breaking tool names or schema structure.
    private static func maskToolDefinition(_ tool: inout [String: Any], map: inout RedactionMap, privateTerms: [String]) -> Int {
        var count = 0
        if let desc = tool["description"] as? String {
            let (masked, replaced) = map.mask(desc, privateTerms: privateTerms)
            if replaced > 0 {
                tool["description"] = masked
                count += replaced
            }
        }
        if var fn = tool["function"] as? [String: Any] {
            let fnCount = maskFunctionSpec(&fn, map: &map, privateTerms: privateTerms)
            if fnCount > 0 {
                tool["function"] = fn
                count += fnCount
            }
        }
        if var schema = tool["input_schema"] as? [String: Any] {
            let schemaCount = maskSchemaDocFields(&schema, map: &map, privateTerms: privateTerms)
            if schemaCount > 0 {
                tool["input_schema"] = schema
                count += schemaCount
            }
        }
        return count
    }

    private static func maskFunctionSpec(_ fn: inout [String: Any], map: inout RedactionMap, privateTerms: [String]) -> Int {
        var count = 0
        if let desc = fn["description"] as? String {
            let (masked, replaced) = map.mask(desc, privateTerms: privateTerms)
            if replaced > 0 {
                fn["description"] = masked
                count += replaced
            }
        }
        if var params = fn["parameters"] as? [String: Any] {
            let paramCount = maskSchemaDocFields(&params, map: &map, privateTerms: privateTerms)
            if paramCount > 0 {
                fn["parameters"] = params
                count += paramCount
            }
        }
        return count
    }

    /// Walks a JSON Schema object recursively and masks prose documentation fields
    /// (`description`, `title`, `default`, `examples`) while preserving structural
    /// keys (`type`, `properties` names, `required`, `additionalProperties`).
    private static func maskSchemaDocFields(_ schema: inout [String: Any], map: inout RedactionMap, privateTerms: [String]) -> Int {
        var count = 0
        for docKey in ["description", "title", "default"] {
            if let text = schema[docKey] as? String {
                let (masked, replaced) = map.mask(text, privateTerms: privateTerms)
                if replaced > 0 {
                    schema[docKey] = masked
                    count += replaced
                }
            }
        }
        if var examples = schema["examples"] as? [Any] {
            var changed = false
            for idx in examples.indices {
                if let text = examples[idx] as? String {
                    let (masked, replaced) = map.mask(text, privateTerms: privateTerms)
                    if replaced > 0 {
                        examples[idx] = masked
                        changed = true
                        count += replaced
                    }
                }
            }
            if changed { schema["examples"] = examples }
        }
        if var properties = schema["properties"] as? [String: Any] {
            var changed = false
            for (propName, propValue) in properties {
                if var propDict = propValue as? [String: Any] {
                    let subCount = maskSchemaDocFields(&propDict, map: &map, privateTerms: privateTerms)
                    if subCount > 0 {
                        properties[propName] = propDict
                        changed = true
                        count += subCount
                    }
                }
            }
            if changed { schema["properties"] = properties }
        }
        for subKey in ["items", "additionalProperties"] {
            if var subDict = schema[subKey] as? [String: Any] {
                let subCount = maskSchemaDocFields(&subDict, map: &map, privateTerms: privateTerms)
                if subCount > 0 {
                    schema[subKey] = subDict
                    count += subCount
                }
            }
        }
        for listKey in ["anyOf", "oneOf", "allOf"] {
            if var list = schema[listKey] as? [[String: Any]] {
                var changed = false
                for idx in list.indices {
                    let subCount = maskSchemaDocFields(&list[idx], map: &map, privateTerms: privateTerms)
                    if subCount > 0 {
                        changed = true
                        count += subCount
                    }
                }
                if changed { schema[listKey] = list }
            }
        }
        if var defs = schema["$defs"] as? [String: Any] {
            var changed = false
            for (defName, defVal) in defs {
                if var defDict = defVal as? [String: Any] {
                    let subCount = maskSchemaDocFields(&defDict, map: &map, privateTerms: privateTerms)
                    if subCount > 0 {
                        defs[defName] = defDict
                        changed = true
                        count += subCount
                    }
                }
            }
            if changed { schema["$defs"] = defs }
        }
        return count
    }

    private static func maskStringValuesRecursively(_ dict: inout [String: Any], map: inout RedactionMap, privateTerms: [String]) -> Int {
        var count = 0
        for (key, val) in dict {
            if let text = val as? String {
                let (masked, replaced) = map.mask(text, privateTerms: privateTerms)
                if replaced > 0 {
                    dict[key] = masked
                    count += replaced
                }
            } else if var nested = val as? [String: Any] {
                let subCount = maskStringValuesRecursively(&nested, map: &map, privateTerms: privateTerms)
                if subCount > 0 {
                    dict[key] = nested
                    count += subCount
                }
            }
        }
        return count
    }

    private static func maskMessage(_ message: inout [String: Any], map: inout RedactionMap, privateTerms: [String]) -> Int {
        var count = 0
        if let text = message["content"] as? String {
            let (masked, replaced) = map.mask(text, privateTerms: privateTerms)
            if replaced > 0 {
                message["content"] = masked
                count += replaced
            }
        } else if var parts = message["content"] as? [[String: Any]] {
            var changed = false
            for idx in parts.indices {
                guard (parts[idx]["type"] as? String) == "text", let text = parts[idx]["text"] as? String else { continue }
                let (masked, replaced) = map.mask(text, privateTerms: privateTerms)
                if replaced > 0 {
                    parts[idx]["text"] = masked
                    changed = true
                    count += replaced
                }
            }
            if changed {
                message["content"] = parts
            }
        }
        if var toolCalls = message["tool_calls"] as? [[String: Any]] {
            var changed = false
            for idx in toolCalls.indices {
                guard var fn = toolCalls[idx]["function"] as? [String: Any],
                    let args = fn["arguments"] as? String
                else { continue }
                let (masked, replaced) = map.mask(args, privateTerms: privateTerms)
                if replaced > 0 {
                    fn["arguments"] = masked
                    toolCalls[idx]["function"] = fn
                    changed = true
                    count += replaced
                }
            }
            if changed {
                message["tool_calls"] = toolCalls
            }
        }
        if var fnCall = message["function_call"] as? [String: Any],
            let args = fnCall["arguments"] as? String
        {
            let (masked, replaced) = map.mask(args, privateTerms: privateTerms)
            if replaced > 0 {
                fnCall["arguments"] = masked
                message["function_call"] = fnCall
                count += replaced
            }
        }
        return count
    }
}
