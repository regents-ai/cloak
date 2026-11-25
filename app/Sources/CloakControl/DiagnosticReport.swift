import Foundation

/// Builds a user-initiated, fully inspectable, plain-text diagnostic report
/// strictly on-device. Never sends anything over the network and never reads
/// chats, prompts, or Keychain secrets.
public enum DiagnosticReport {
    /// Summary of a macOS crash report found in `~/Library/Logs/DiagnosticReports/`.
    public struct CrashInfo: Sendable, Equatable {
        public let filename: String
        public let date: Date
        public let processName: String
        public let summary: String
    }

    /// Generated report ready for user inspection and manual copy/paste.
    public struct Result: Sendable, Equatable {
        public let text: String
        public let logLineCount: Int
        public let crash: CrashInfo?
    }

    private static let crashPrefixes = ["RegentsCloak", "cloak-", "llama", "tor-"]

    /// Finds the newest Cloak-related crash report in `directory` (defaults to
    /// `~/Library/Logs/DiagnosticReports`) within `maxAge` (defaults to 7 days).
    public static func latestCrash(
        in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports"),
        maxAge: TimeInterval = 7 * 86_400,
        now: Date = .now
    ) -> CrashInfo? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        let matching: [(URL, Date)] = urls.compactMap { url in
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard ext == "ips" || ext == "crash" else { return nil }
            let lower = name.lowercased()
            guard crashPrefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= cutoff else {
                return nil
            }
            return (url, modified)
        }
        .sorted { $0.1 > $1.1 }

        guard let (newestURL, modified) = matching.first else { return nil }
        guard let raw = try? String(contentsOf: newestURL, encoding: .utf8) else { return nil }
        let extracted = extractCrashSummary(from: raw, filename: newestURL.lastPathComponent)
        return CrashInfo(
            filename: newestURL.lastPathComponent,
            date: modified,
            processName: extracted.processName,
            summary: redact(extracted.summary)
        )
    }

    /// Generates a complete, redacted plain-text diagnostic report off the main actor.
    @concurrent
    public static func generate(
        release: String,
        build: String,
        phaseTitle: String,
        reason: String?,
        rewriterModel: String,
        rewriterResting: Bool,
        lastCheckSummary: String,
        statusDetail: String,
        minutes: Int = 60
    ) async -> Result {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let ramGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)
        let cores = ProcessInfo.processInfo.processorCount
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        let rawLogs = fetchUnifiedLogs(minutes: minutes)
        let redactedLogs = rawLogs.map(redact)
        let crash = latestCrash()

        var lines: [String] = []
        lines.append("=== Regents Cloak Diagnostic Report ===")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: .now))")
        lines.append("Telemetry: none (local user-initiated export)")
        lines.append("")
        lines.append("[System & App]")
        lines.append("Release: \(release) (\(build))")
        lines.append("macOS: \(osVersion)")
        lines.append(String(format: "Hardware: %@ · %d cores · %.0f GB RAM", arch, cores, ramGiB))
        lines.append("Supervisor: \(phaseTitle)" + (reason.map { " (\($0))" } ?? ""))
        lines.append("Rewriter: \(rewriterModel)\(rewriterResting ? " (unloaded)" : "")")
        lines.append("Last check: \(lastCheckSummary)")
        lines.append("")
        lines.append("[Status Detail]")
        lines.append(redact(statusDetail))
        lines.append("")
        lines.append("[Recent Cloak Logs (last \(minutes)m, redacted)]")
        if redactedLogs.isEmpty {
            lines.append("(no log entries found in the last \(minutes) minutes)")
        } else {
            lines.append(contentsOf: redactedLogs)
        }
        lines.append("")
        lines.append("[Latest Crash Report (last 7 days, redacted)]")
        if let crash {
            lines.append("File: \(crash.filename)")
            lines.append("Process: \(crash.processName)")
            lines.append("Date: \(ISO8601DateFormatter().string(from: crash.date))")
            lines.append(crash.summary)
        } else {
            lines.append("None found in ~/Library/Logs/DiagnosticReports/")
        }

        return Result(
            text: lines.joined(separator: "\n"),
            logLineCount: redactedLogs.count,
            crash: crash
        )
    }

    /// Scrubs usernames in home paths, non-loopback IPv4 addresses, EVM
    /// addresses, long hex secrets, bearer/API keys, and emails.
    public static func redact(_ input: String) -> String {
        var text = input

        // Home directory usernames: /Users/<name>/ -> /Users/<redacted>/
        text = replace(text, pattern: #"/Users/[^/\s"':;]+"#, with: "/Users/<redacted>")

        // Bearer tokens & common API key prefixes
        text = replace(text, pattern: #"(?i)\b(Bearer|Authorization:)\s+[A-Za-z0-9._~+/=-]{8,}"#, with: "$1 <redacted-secret>")
        text = replace(text, pattern: #"\b(sk|vk|nk|ghp|gho|github_pat)_[A-Za-z0-9_-]{8,}\b"#, with: "<redacted-key>")
        text = replace(text, pattern: #"\bsk-[A-Za-z0-9_-]{12,}\b"#, with: "<redacted-key>")

        // 64-hex private keys / secrets (with or without 0x)
        text = replace(text, pattern: #"\b(?:0x)?[0-9a-fA-F]{64}\b"#, with: "<redacted-hex>")

        // 40-hex Ethereum / EVM wallet addresses
        text = replace(text, pattern: #"\b0x[0-9a-fA-F]{40}\b"#, with: "0x<redacted-address>")

        // Emails
        text = replace(text, pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, with: "<redacted-email>")

        // Non-loopback IPv4 addresses
        text = replaceIPv4(text)

        return text
    }

    /// Parses macOS JSON `.ips` crash reports (1-line JSON header + JSON body)
    /// into a compact exception + top crashed-thread stack trace, falling back
    /// to the first 50 lines for legacy `.crash` text reports.
    public static func extractCrashSummary(from raw: String, filename: String) -> (processName: String, summary: String) {
        let fallbackProcess = filename.split(separator: "-").first.map(String.init) ?? filename
        // macOS .ips format: first line is a JSON header object, remainder is the JSON payload.
        if let newline = raw.firstIndex(of: "\n") {
            let bodySlice = raw[raw.index(after: newline)...]
            if let data = bodySlice.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let procName = (json["procName"] as? String) ?? fallbackProcess
                var out: [String] = []
                if let exception = json["exception"] as? [String: Any] {
                    let type = exception["type"] as? String ?? "unknown"
                    let signal = exception["signal"] as? String
                    let subtype = exception["subtype"] as? String
                    out.append("Exception: \(type)" + (signal.map { " (\($0))" } ?? ""))
                    if let subtype, !subtype.isEmpty {
                        out.append("Subtype: \(subtype)")
                    }
                }
                if let termination = json["termination"] as? [String: Any] {
                    let indicator = termination["indicator"] as? String
                    let reasons = termination["reasons"] as? [String]
                    if let indicator, !indicator.isEmpty {
                        out.append("Termination: \(indicator)")
                    }
                    if let reasons, !reasons.isEmpty {
                        out.append("Reasons: \(reasons.joined(separator: "; "))")
                    }
                }
                if let asi = json["asi"] as? [String: [String]], !asi.isEmpty {
                    for (key, msgs) in asi.sorted(by: { $0.key < $1.key }) {
                        if let first = msgs.first {
                            out.append("ASI (\(key)): \(first)")
                        }
                    }
                }

                let images = (json["usedImages"] as? [[String: Any]]) ?? []
                if let faultingIdx = json["faultingThread"] as? Int,
                    let threads = json["threads"] as? [[String: Any]],
                    faultingIdx >= 0, faultingIdx < threads.count
                {
                    let thread = threads[faultingIdx]
                    let threadName = thread["name"] as? String ?? thread["queue"] as? String
                    out.append("Crashed thread #\(faultingIdx)" + (threadName.map { " (\($0))" } ?? "") + ":")
                    let frames = (thread["frames"] as? [[String: Any]]) ?? []
                    for (i, frame) in frames.prefix(25).enumerated() {
                        let imageIdx = frame["imageIndex"] as? Int
                        let imageName: String =
                            if let idx = imageIdx, idx >= 0, idx < images.count {
                                (images[idx]["name"] as? String) ?? "image#\(idx)"
                            } else {
                                "?"
                            }
                        let symbol = (frame["symbol"] as? String) ?? "0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
                        let offset = frame["symbolLocation"].map { " + \($0)" } ?? ""
                        out.append(String(format: "  %2d  %-26s %@", i, (imageName as NSString).utf8String!, "\(symbol)\(offset)"))
                    }
                }

                if !out.isEmpty {
                    return (procName, out.joined(separator: "\n"))
                }
            }
        }

        let head = raw.split(separator: "\n", omittingEmptySubsequences: false).prefix(50).joined(separator: "\n")
        return (fallbackProcess, head)
    }

    private static func fetchUnifiedLogs(minutes: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--last", "\(max(1, minutes))m",
            "--info",
            "--style", "compact",
            "--predicate", #"subsystem == "sh.regents.cloak.app""#,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ["(unable to read macOS unified log: \(error.localizedDescription))"]
        }

        let deadline = DispatchTime.now() + .seconds(5)
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if semaphore.wait(timeout: deadline) == .timedOut {
            process.terminate()
        }

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let allLines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("Filtering the log data") && !$0.hasPrefix("Timestamp") }
        return Array(allLines.suffix(120)).map { line in
            line.count > 240 ? String(line.prefix(240)) + "…" : line
        }
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceIPv4(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            let candidate = ns.substring(with: match.range)
            if candidate == "127.0.0.1" || candidate == "0.0.0.0" { continue }
            let octets = candidate.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { continue }
            if let swiftRange = Range(match.range, in: out) {
                out.replaceSubrange(swiftRange, with: "<redacted-ip>")
            }
        }
        return out
    }
}
