// Compiled only by `app/build.sh darkbloom`: Darkbloom's window is in no
// release until its makers allow it (decision 36 in docs/plan.md).
#if DARKBLOOM
import Foundation
import Security

/// Darkbloom (Layr-Labs/d-inference, read at v0.10.16) as Cloak finds,
/// checks and drives it. Everything here is Darkbloom's own: its command
/// line in ~/.darkbloom/bin, signed by its developer; its installer, from
/// api.darkbloom.dev; its control service on 127.0.0.1, whose port and token
/// it writes to ~/.darkbloom/desktop/connection.json
/// (docs/reference/desktop-control.md); and its files saying how it serves.
/// The token, the local key and any request's text are read only when
/// needed, kept in memory only, and never logged or put on a command line:
/// the commands run here carry flags and a model's name, nothing else.
enum Darkbloom {
    /// Where Darkbloom's installer puts its command line.
    static let cli = URL.homeDirectory.appending(path: ".darkbloom/bin/darkbloom")
    /// Darkbloom's installer, as its documented `curl -fsSL … | bash` fetches
    /// it (docs/provider/installation.md:30).
    static let installer = URL(string: "https://api.darkbloom.dev/install.sh")!
    /// The oldest release whose flags, files and control service Cloak was
    /// built against.
    static let oldest = [0, 10, 16]
    /// What Darkbloom's own app requires of the command line before it runs
    /// it (desktop-app/src/main/backend.ts:20–21), and its installer of what it
    /// installs (scripts/install.sh:38): Apple's chain, the identifier
    /// io.darkbloom.provider, Darkbloom's team SLDQ2GJ6TL, and that team's
    /// certificate itself.
    static let requirement = #"anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL" and certificate leaf = H"95b67556e04653f56ba5411d20d33dd263ef6e2a""#

    /// Whether this Mac's system is one Darkbloom installs on: macOS 27 or
    /// later (scripts/install.sh:434–449).
    static var systemFits: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    /// What Cloak found of the command line: the checked file, its release,
    /// the flags its `start` takes, and its control service with what that
    /// last reported, when it answers for this release.
    struct Found: Sendable {
        var binary: URL
        var version: String
        var flags: Set<String>
        var control: DarkbloomControl?
        var snapshot: DarkbloomSnapshot?
    }

    /// The result of checking `~/.darkbloom/bin/darkbloom`.
    enum Lookup: Sendable {
        /// Not installed on this Mac.
        case missing
        /// Installed and validly signed, but older than `oldest`.
        case outdated(version: String)
        /// Installed, signed, and recent enough for Cloak to drive.
        case ready(Found)
    }

    /// Cached verified binary metadata keyed by resolved path + mtime + inode
    /// so opening Settings → Inference Serving doesn't re-hash Darkbloom.app
    /// and re-spawn `--version`/`start --help` on every tab switch.
    private struct VerifiedBinary: Sendable {
        let path: String
        let inode: UInt64
        let mtimeSec: Int
        let version: String
        let flags: Set<String>
    }
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedBinary: VerifiedBinary?

    private static func fileIdentity(_ binary: URL) -> (inode: UInt64, mtimeSec: Int)? {
        var st = stat()
        guard stat(binary.path, &st) == 0 else { return nil }
        return (st.st_ino, st.st_mtimespec.tv_sec)
    }

    /// Looks for the command line and checks it: its signature, then its
    /// release, then its flags, then whether its control service answers.
    @concurrent static func find() async throws(DarkbloomFailure) -> Lookup {
        guard FileManager.default.fileExists(atPath: cli.path) else { return .missing }
        let binary = cli.resolvingSymlinksInPath()
        let identity = fileIdentity(binary)

        let version: String
        let flags: Set<String>
        let cached: VerifiedBinary? = cacheLock.withLock {
            guard let c = cachedBinary, let id = identity,
                c.path == binary.path, c.inode == id.inode, c.mtimeSec == id.mtimeSec
            else { return nil }
            return c
        }
        if let cached {
            version = cached.version
            flags = cached.flags
        } else {
            try verify(binary)
            guard let v = await installedVersion(binary), let numbers = release(v) else {
                throw DarkbloomFailure("Unknown version", detail: "Darkbloom's command line didn't give a release Cloak can read.")
            }
            guard !numbers.lexicographicallyPrecedes(oldest) else {
                return .outdated(version: v)
            }
            let f = await startFlags(binary)
            version = v
            flags = f
            if let id = identity {
                cacheLock.withLock {
                    cachedBinary = VerifiedBinary(path: binary.path, inode: id.inode, mtimeSec: id.mtimeSec, version: v, flags: f)
                }
            }
        }
        var found = Found(binary: binary, version: version, flags: flags)
        guard let control = try DarkbloomControl.discover() else { return .ready(found) }
        do {
            let snapshot = try await control.state()
            // A service left from another release answers for that one; Connect restarts it (`desktop ensure`).
            guard snapshot.version == version else { return .ready(found) }
            found.control = control
            found.snapshot = snapshot
        } catch .unreachable {
            return .ready(found)
        } catch {
            throw DarkbloomFailure("Unknown Darkbloom", detail: error.reason)
        }
        return .ready(found)
    }

    /// Checks `binary`'s signature against `requirement` with the system's own
    /// check, every architecture and nested part, strictly.
    static func verify(_ binary: URL) throws(DarkbloomFailure) {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            throw DarkbloomFailure("Signature check failed", detail: "The system couldn't read \(binary.path).")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            let reason = error.map { $0.takeRetainedValue().localizedDescription } ?? "It isn't signed by Darkbloom's developer."
            throw DarkbloomFailure("Signature check failed", detail: reason)
        }
    }

    /// The release `darkbloom --version` gives, as it gives it.
    private static func installedVersion(_ binary: URL) async -> String? {
        var words: [String] = []
        do {
            for try await line in lines(binary, ["--version"]) {
                words += line.split(separator: " ").map(String.init)
            }
        } catch {
            return nil
        }
        return words.first { release($0) != nil }
    }

    /// A release's three numbers, from exactly "major.minor.patch".
    static func release(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { $0.allSatisfy { $0.isASCII && $0.isNumber } ? Int($0) : nil }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }

    /// Every flag `darkbloom start --help` lists.
    private static func startFlags(_ binary: URL) async -> Set<String> {
        var flags = Set<String>()
        do {
            for try await line in lines(binary, ["start", "--help"]) {
                for word in line.split(whereSeparator: { " ,/<>[]=".contains($0) }) where word.hasPrefix("--") {
                    flags.insert(String(word))
                }
            }
        } catch {
            return []
        }
        return flags
    }

    /// Reads `darkbloom models --json` to discover `required_provider_capabilities`
    /// per model ID (e.g. `["apple_m5", "mlx_nax"]`), which Darkbloom's `/control/v1/state`
    /// `eligible` boolean omits in v0.10.17.
    @concurrent static func modelRequiredCapabilities(_ binary: URL) async -> [String: [String]] {
        struct Entry: Decodable {
            let id: String
            let requiredProviderCapabilities: [String]?
        }
        var output = ""
        do {
            for try await line in lines(binary, ["models", "--json"]) {
                output += line + "\n"
            }
        } catch {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = output.data(using: .utf8),
            let entries = try? decoder.decode([Entry].self, from: data)
        else { return [:] }
        var map: [String: [String]] = [:]
        for entry in entries {
            if let caps = entry.requiredProviderCapabilities, !caps.isEmpty {
                map[entry.id] = caps
            }
        }
        return map
    }

    /// Returns whether this Mac satisfies `requiredCapabilities` reported by
    /// `darkbloom models --json` (currently filtering Apple M5 / `mlx_nax` models
    /// on M1–M4 Macs so incompatible models are never recommended or downloaded).
    static func hostSupports(requiredCapabilities: [String]) -> Bool {
        guard !requiredCapabilities.isEmpty else { return true }
        let brand = cpuBrandString().lowercased()
        let isM5OrNewer: Bool = {
            guard let range = brand.range(of: #"apple m(\d+)"#, options: .regularExpression) else { return false }
            let digits = brand[range].filter(\.isNumber)
            return (Int(digits) ?? 0) >= 5
        }()
        for cap in requiredCapabilities {
            let lower = cap.lowercased()
            if (lower == "apple_m5" || lower == "mlx_nax" || lower.hasPrefix("apple_m5")), !isM5OrNewer {
                return false
            }
        }
        return true
    }

    private static func cpuBrandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The flags Cloak's Start passes (`startArguments`), each of which
    /// `start --help` must list.
    static func startNeeds(alsoServe: Bool) -> Set<String> {
        [alsoServe ? "--me-first" : "--local", "--route", "--bind", "--model"]
    }

    /// The arguments of Cloak's Start: this Mac's model, its address on
    /// 127.0.0.1 only, the person's requests never sent on to another Mac or
    /// the network (`--route this-mac`), and either this Mac alone
    /// (`--local`, Darkbloom's Only me) or also Darkbloom's network with the
    /// person's requests first (`--me-first`). All five are in
    /// provider-swift/Sources/darkbloom/Start/StartCommand.swift at v0.10.16.
    static func startArguments(model: String, alsoServe: Bool) -> [String] {
        ["start", alsoServe ? "--me-first" : "--local", "--route", "this-mac", "--bind", "127.0.0.1", "--model", model]
    }

    /// Checks whether a Darkbloom provider daemon is currently alive on this
    /// Mac by reading `~/.darkbloom/daemon-state.json` (written every few
    /// seconds by `darkbloom start`, even when `darkbloom desktop` isn't running).
    static func isDaemonAlive() -> Bool {
        let file = URL.homeDirectory.appending(path: ".darkbloom/daemon-state.json")
        struct DaemonState: Decodable {
            let pid: Int32
            let writtenAt: Double?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: file),
            let state = try? decoder.decode(DaemonState.self, from: data),
            state.pid > 0
        else { return false }
        guard kill(state.pid, 0) == 0 || errno == EPERM else { return false }
        if let writtenAt = state.writtenAt {
            let age = Date.now.timeIntervalSince1970 - writtenAt
            if age > 120 { return false }
        }
        return true
    }

    /// Runs `executable` with `arguments` and returns combined stdout/stderr
    /// text (capped at 64 KiB) without failing on non-zero exit codes so
    /// diagnostic commands like `darkbloom doctor` can report blocking checks.
    @concurrent static func capture(_ executable: URL, _ arguments: [String]) async -> String {
        var collected: [String] = []
        var totalBytes = 0
        do {
            for try await line in lines(executable, arguments) {
                if totalBytes < 65_536 {
                    collected.append(line)
                    totalBytes += line.utf8.count + 1
                }
            }
        } catch {
            if collected.isEmpty {
                return "Command failed: \(error.localizedDescription)"
            }
        }
        return collected.joined(separator: "\n")
    }

    /// Runs `executable` with `arguments` and nothing on its input, handing
    /// back each line it writes on either output as it comes. It ends once
    /// the program has ended and its output is all read, throwing `Exit`
    /// unless it ended well. Whoever stops reading first stops the program
    /// and all it started, its process group (Foundation gives each program
    /// a group of its own), as Darkbloom's own app stops its installer with
    /// its download (docs/developer/desktop-app.md:651–652); Darkbloom's
    /// services run under launchd, not in it. The end is heard from the
    /// process's own handler: `waitUntilExit` polls a run loop, and on the
    /// thread a task resumes on it can wait forever.
    static func lines(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            let (ends, end) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { process in
                end.yield(process.terminationStatus)
                end.finish()
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let task = Task {
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                    for await status in ends {
                        continuation.finish(throwing: status == 0 ? nil : Exit(status: status))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // Foundation's Process does not call setpgid(), so kill(-pid)
                // returns ESRCH. Terminate the child process directly instead.
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// A program that ended with a status other than 0.
    struct Exit: Error {
        let status: Int32
    }

    /// Runs the command line to its end; when it doesn't end well, throws
    /// `words` with its last reason as the detail.
    @concurrent static func run(_ binary: URL, _ arguments: [String], failing words: String) async throws(DarkbloomFailure) {
        var reasons = Reasons()
        do {
            for try await line in lines(binary, arguments) {
                reasons.hear(line)
            }
        } catch {
            throw DarkbloomFailure(words, detail: reasons.reason)
        }
    }

    /// Fetches Darkbloom's installer from Darkbloom now and runs it as
    /// Darkbloom's own app runs its copy (docs/developer/desktop-app.md:621–655,
    /// desktop-app/src/main/backend.ts:263–396): with bash, the coordinator
    /// named, nothing on its input. `step` hears each of its five steps as
    /// it starts. The installer checks what it downloads before it installs
    /// it; Cloak checks the result again (`verify`) before running it.
    @concurrent static func install(step: @escaping @MainActor @Sendable (Int) -> Void) async throws(DarkbloomFailure) {
        let folder = URL.temporaryDirectory.appending(path: "darkbloom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "install.sh")
        do {
            var request = URLRequest(url: installer)
            // A client name that says neither Cloak nor its version, as the documented command's.
            request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try data.write(to: script)
        } catch {
            throw DarkbloomFailure("Couldn't download", detail: "Darkbloom's installer didn't download from api.darkbloom.dev.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["COORD_URL"] = "https://api.darkbloom.dev"
        var reasons = Reasons()
        do {
            for try await line in lines(URL(filePath: "/bin/bash"), [script.path], environment: environment) {
                reasons.hear(line)
                // "→ [2/5] Downloading …": the step's number.
                if line.hasPrefix("→ ["), let number = line.dropFirst(3).first?.wholeNumberValue {
                    await step(number)
                }
            }
        } catch {
            throw DarkbloomFailure("Couldn't install", detail: reasons.reason)
        }
    }

    /// The reason a run of Darkbloom's gave for stopping: its last `✗` or
    /// `Error:` line (how its installer and command line say what failed),
    /// else its last line, cut short, with anything that looks like a token,
    /// a key or a link's query taken out (as installProgress.ts's
    /// `sanitizeInstallLine` does).
    private struct Reasons {
        private var failure: String?
        private var last: String?

        var reason: String? { failure ?? last }

        mutating func hear(_ line: String) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            if text.hasPrefix("✗") || text.hasPrefix("Error:") {
                failure = Self.clean(text)
            } else {
                last = Self.clean(text)
            }
        }

        private static func clean(_ line: String) -> String {
            let text = line
                .replacing(/^(✗|Error:)\s*/, with: "")
                .replacing(/(https?:\/\/[^\s?#]+)[?#]\S*/) { $0.output.1 }
                .replacing(/(?i)\b(token|key|secret|password|authorization)\s*[:=]\s*(bearer\s+)?\S+/) { "\($0.output.1) …" }
                .replacing(/(?i)\bbearer\s+\S+/, with: "Bearer …")
                .replacing(/[A-Za-z0-9+\/=_-]{32,}/, with: "…")
            return String(text.prefix(200))
        }
    }
}

/// Why something of Darkbloom's stopped: a few words for the window, and,
/// for its note, Darkbloom's own reason when it gave one.
struct DarkbloomFailure: Error, Equatable, Sendable {
    var words: String
    var detail: String?

    init(_ words: String, detail: String? = nil) {
        self.words = words
        self.detail = detail
    }
}

/// How a call to Darkbloom's control service went wrong.
enum DarkbloomError: Error {
    /// It didn't answer, or the line to it broke.
    case unreachable
    /// It answered with something Cloak can't read.
    case unreadable
    /// It refused, in its own words.
    case refused(String)

    var reason: String {
        switch self {
        case .unreachable: "Darkbloom's control service isn't answering."
        case .unreadable: "Darkbloom answered in a way Cloak doesn't know."
        case .refused(let words): words
        }
    }
}

/// Darkbloom's control service: the port and token in the file it writes,
/// and its four routes (docs/reference/desktop-control.md:62–77). Each call
/// goes straight to 127.0.0.1, never through a proxy, with the token as its
/// bearer, no `Origin`, and no redirect followed.
struct DarkbloomControl: Sendable {
    let port: Int
    private let token: String

    /// The service's file, read as Darkbloom's own app reads it
    /// (desktop-app/src/main/backend.ts:165–180): a file of this user's, not a
    /// link, readable by this user alone, at most 4 KiB, of version 1, with
    /// a port, a token of 32 characters or more, and its process. Nil when
    /// there is no file.
    static func discover() throws(DarkbloomFailure) -> DarkbloomControl? {
        let file = URL.homeDirectory.appending(path: ".darkbloom/desktop/connection.json")
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_uid == getuid(), info.st_size <= 4096,
            let data = try? Data(contentsOf: file),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.version == 1, (1...65535).contains(record.port), record.token.count >= 32, record.pid > 0
        else {
            throw DarkbloomFailure("Unsafe connection", detail: "Darkbloom's connection file isn't as Darkbloom writes it.")
        }
        // If the control service PID is no longer alive, treat the stale
        // connection.json as offline instead of looping in `.connecting`.
        if kill(pid_t(record.pid), 0) != 0 && errno == ESRCH {
            return nil
        }
        return DarkbloomControl(port: record.port, token: record.token)
    }

    private struct Record: Decodable {
        let version: Int
        let port: Int
        let token: String
        let pid: Int
    }

    /// Everything the service reports now.
    func state() async throws(DarkbloomError) -> DarkbloomSnapshot {
        try await send(request("state"))
    }

    /// The local address's key, or nil while no local address runs (the
    /// service answers `null`; DesktopResources.swift:16–18).
    func endpointKey() async throws(DarkbloomError) -> String? {
        let key: Key? = try await send(request("endpoint-key"))
        return key?.key
    }

    private struct Key: Decodable {
        let key: String
    }

    /// Asks for `action`; the service answers with the operation it started.
    func act(_ action: DarkbloomAction) async throws(DarkbloomError) -> DarkbloomSnapshot.Operation {
        var request = request("actions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = action.body
        return try await send(request)
    }

    /// What the service reports, as it reports it: a whole report every 2
    /// seconds. The service ends each stream after 30 (a minute).
    func events() -> AsyncThrowingStream<DarkbloomSnapshot, any Error> {
        let request = request("events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DarkbloomError.unreachable }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let snapshot = try? Self.decoder.decode(DarkbloomSnapshot.self, from: Data(line.dropFirst(5).utf8))
                        else { throw DarkbloomError.unreadable }
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch let error as DarkbloomError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: DarkbloomError.unreachable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(_ resource: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control/v1/\(resource)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Answer: Decodable>(_ request: URLRequest) async throws(DarkbloomError) -> Answer {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw .unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw .unreachable }
        guard (200..<300).contains(status) else {
            throw .refused((try? Self.decoder.decode(Refusal.self, from: data))?.error ?? "Darkbloom refused.")
        }
        guard let answer = try? Self.decoder.decode(Answer.self, from: data) else { throw .unreadable }
        return answer
    }

    /// What the service says when it refuses.
    private struct Refusal: Decodable {
        let error: String
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// No cache, no cookies, no proxy, and no redirect followed, so the token
    /// goes to 127.0.0.1 and nowhere else.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 25
        return URLSession(configuration: configuration, delegate: Unredirected(), delegateQueue: nil)
    }()

    private final class Unredirected: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

/// One of the control service's actions Cloak asks for
/// (docs/reference/desktop-control.md:199–216), each with a new request ID.
enum DarkbloomAction: Sendable {
    case download(model: String)
    case remove(model: String)
    case cancel(operation: String)
    case stop
    case link

    var body: Data {
        var fields = ["id": UUID().uuidString.lowercased()]
        switch self {
        case .download(let model):
            fields["action"] = "download"
            fields["model"] = model
        case .remove(let model):
            fields["action"] = "remove"
            fields["model"] = model
        case .cancel(let operation):
            fields["action"] = "cancel"
            fields["operation"] = operation
        case .stop:
            fields["action"] = "stop"
        case .link:
            fields["action"] = "link"
        }
        return try! JSONEncoder().encode(fields)
    }
}

/// What Darkbloom's control service reports, as much of it as Cloak shows
/// (desktop-app/src/shared/contracts.ts, `Snapshot`).
struct DarkbloomSnapshot: Decodable, Equatable, Sendable {
    var `protocol`: Int
    var version: String
    var linked: Bool
    /// "stopped", "starting", "running", "draining" or "stale".
    var state: String
    /// What Darkbloom's network says of this Mac while it serves the network:
    /// "untrusted" until it has verified this Mac, "offline" while not
    /// connected; nil otherwise.
    var providerStatus: String?
    var models: [Model]
    var operations: [Operation]
    var memory: Memory
    var endpoint: Endpoint?
    var link: Link?
    var account: Account?
    var machine: Machine?
    var settings: Settings?
    var catalogError: String?
    /// Live provider activity reported by Darkbloom v0.10.17+ (`/control/v1/state`).
    var activity: Activity?
    /// Optional live provider metrics reported by newer Darkbloom builds
    /// (Decision N5.2 — darkbloom-monitor metrics).
    var metrics: Metrics?
    var stats: Metrics?

    var liveMetrics: Metrics? { metrics ?? stats }
    var providerName: String? {
        [machine?.name, settings?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    struct Activity: Decodable, Equatable, Sendable {
        var startedAt: Double?
        var requests: Int?
        var countedRequests: Int?
        var tokens: Int?
        var processedTokens: Int?
        var processedOutputTokens: Int?

        var resolvedRequests: Int? { requests ?? countedRequests }
        var resolvedTokens: Int? { processedOutputTokens ?? processedTokens ?? tokens }

        private enum CodingKeys: String, CodingKey {
            case startedAt, requests, countedRequests, tokens, processedTokens, processedOutputTokens
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try? c.decode(Double.self, forKey: .startedAt)
            requests = Self.decodeInt(c, forKey: .requests)
            countedRequests = Self.decodeInt(c, forKey: .countedRequests)
            tokens = Self.decodeInt(c, forKey: .tokens)
            processedTokens = Self.decodeInt(c, forKey: .processedTokens)
            processedOutputTokens = Self.decodeInt(c, forKey: .processedOutputTokens)
        }

        private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
            if let v = try? c.decode(Int.self, forKey: key) { return v }
            if let s = try? c.decode(String.self, forKey: key), let v = Int(s) { return v }
            return nil
        }
    }

    struct Account: Decodable, Equatable, Sendable {
        var signedIn: Bool?
        var email: String?
        var username: String?
        var displayName: String?
        var name: String?
        var handle: String?
        var legacyData: Bool?

        var identity: String? {
            [email, username, handle, displayName, name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
    }

    struct Machine: Decodable, Equatable, Sendable {
        var name: String?
    }

    struct Settings: Decodable, Equatable, Sendable {
        var name: String?
    }

    struct Metrics: Decodable, Equatable, Sendable {
        var tokensPerSecond: Double?
        var tps: Double?
        var requestsServed: Int?
        var totalRequests: Int?
        var activeRequests: Int?
        var inFlight: Int?
        var uptimeSeconds: Double?

        var resolvedTPS: Double? { tokensPerSecond ?? tps }
        var resolvedRequests: Int? { requestsServed ?? totalRequests }
        var resolvedActive: Int? { activeRequests ?? inFlight }
    }

    struct Model: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var displayName: String
        /// The download's size, in Darkbloom's GB.
        var sizeGb: Double?
        /// What it takes in memory once loaded, known once downloaded.
        var memoryGb: Double?
        var quantization: String?
        var description: String?
        var contextLength: Int?
        var downloaded: Bool
        /// Whether Darkbloom is set to serve it.
        var serving: Bool
        var loaded: Bool
        /// Whether Darkbloom can serve it on this Mac.
        var eligible: Bool
        /// Whether Darkbloom's list has it.
        var network: Bool
        /// "routable" once the network sends it requests.
        var registration: String?
    }

    struct Operation: Decodable, Equatable, Sendable {
        var id: String
        var action: String
        /// "running", "succeeded", "failed", "cancelled" or "interrupted".
        var state: String
        var message: String
        var cancellable: Bool
        var model: String?
        /// From 0 to 1, for a download that reports it.
        var progress: Double?
    }

    struct Memory: Decodable, Equatable, Sendable {
        var totalGb: Double
        /// What Darkbloom lets models take on this Mac, in its GB.
        var pinBudgetGb: Double?
    }

    struct Endpoint: Decodable, Equatable, Sendable {
        var baseUrl: String
        var authenticated: Bool
    }

    /// Darkbloom's link page and the code to give it.
    struct Link: Decodable, Equatable, Sendable {
        var url: String
        var code: String
    }
}

/// How Darkbloom on this Mac is set to serve, read from its own files each
/// time: the job it gave launchd (~/Library/LaunchAgents/io.darkbloom.provider.plist),
/// the address its local server listens on (`host` in ~/.darkbloom/local.json),
/// and where the person's requests go when this Mac is busy (`[local] route`
/// in ~/.config/darkbloom/provider.toml). Cloak changes none of them; its
/// Start asks Darkbloom to.
struct DarkbloomSetup: Equatable, Sendable {
    enum Mode: Sendable {
        /// `--local`: this Mac alone (Darkbloom's Only me).
        case onlyMe
        /// `--local-endpoint`: the network and this Mac (Both).
        case both
        /// The network alone.
        case network
    }

    struct Job: Equatable, Sendable {
        var mode: Mode
        /// Its `--bind`, when it has a local address.
        var bind: String?
        /// Model IDs passed via `--model` in the launchd job (used to identify
        /// the configured model in `--local` on-demand mode where `/control/v1/state`
        /// reports `serving: false, loaded: false` while idle).
        var models: [String] = []
        /// Whether launchd has it now: Darkbloom's Stop takes it out.
        var loaded: Bool
        /// Whether its process runs now.
        var running: Bool
        /// Whether launchd starts it at login while it has it.
        var runsAtLoad: Bool
    }

    var job: Job?
    /// The address the running local server listens on, when one runs.
    var listens: String?
    /// The saved route, nil when none is saved, the file can't be read, or
    /// the job reads another file.
    var route: String?

    /// Reads them now; `listening` is whether Darkbloom reports a live local
    /// address, which is when local.json is current.
    @concurrent static func read(listening: Bool) async -> DarkbloomSetup {
        let home = URL.homeDirectory
        var setup = DarkbloomSetup()
        var config = false
        if let data = try? Data(contentsOf: home.appending(path: "Library/LaunchAgents/io.darkbloom.provider.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        {
            let mode: Mode = arguments.contains("--local")
                ? .onlyMe
                : (arguments.contains("--local-endpoint") || arguments.contains("--me-first")) ? .both : .network
            let bind = arguments.firstIndex(of: "--bind").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            var models: [String] = []
            for idx in arguments.indices where arguments[idx] == "--model" {
                let next = idx + 1
                if arguments.indices.contains(next) {
                    models.append(arguments[next])
                }
            }
            let (loaded, running) = await launchd()
            setup.job = Job(
                mode: mode, bind: bind, models: models, loaded: loaded, running: running,
                runsAtLoad: plist["RunAtLoad"] as? Bool == true)
            config = arguments.contains("--config")
        }
        if listening, let data = try? Data(contentsOf: home.appending(path: ".darkbloom/local.json")) {
            struct Record: Decodable { let host: String }
            setup.listens = (try? JSONDecoder().decode(Record.self, from: data))?.host
        }
        if !config, let toml = try? String(contentsOf: home.appending(path: ".config/darkbloom/provider.toml"), encoding: .utf8) {
            setup.route = route(in: toml)
        }
        return setup
    }

    /// Whether launchd has Darkbloom's serving job, and whether its process
    /// runs, as `launchctl print` says (a `pid = ` line while it runs).
    private static func launchd() async -> (loaded: Bool, running: Bool) {
        var running = false
        do {
            for try await line in Darkbloom.lines(URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/io.darkbloom.provider"]) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") { running = true }
            }
        } catch {
            return (false, false)
        }
        return (true, running)
    }

    /// `route` in `[local]`, as Darkbloom writes it there.
    static func route(in toml: String) -> String? {
        var local = false
        for line in toml.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                local = text == "[local]"
                continue
            }
            let parts = text.split(separator: "=", maxSplits: 1)
            guard local, parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "route" else { continue }
            let value = parts[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// Whether `address` is this Mac's loopback, which only this Mac reaches.
    static func loopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1"
    }
}

/// Live per-million-token pricing from Darkbloom's public catalog endpoint
/// (`https://api.darkbloom.dev/v1/pricing`). Darkbloom takes a 0% platform cut
/// from providers, so token rates directly reflect relative per-token earning
/// potential when ranking fitting models on this Mac.
struct DarkbloomPricing: Decodable, Equatable, Sendable {
    static let endpoint = URL(string: "https://api.darkbloom.dev/v1/pricing")!

    struct Price: Decodable, Equatable, Sendable {
        var model: String
        /// Micro-USD per 1M input tokens (e.g. 35000 = $0.035 / 1M).
        var inputPrice: Int
        /// Micro-USD per 1M output tokens (e.g. 1500000 = $1.50 / 1M).
        var outputPrice: Int
        var cacheReadPrice: Int?
        var inputUsd: String?
        var outputUsd: String?
        var cacheReadUsd: String?

        var inputPerMillion: Double { Double(inputPrice) / 1_000_000.0 }
        var outputPerMillion: Double { Double(outputPrice) / 1_000_000.0 }

        /// Weighted earning score per 1M tokens (75% output, 25% input) since
        /// generation tokens dominate GPU time and provider revenue.
        var earningScore: Double {
            inputPerMillion * 0.25 + outputPerMillion * 0.75
        }

        /// Compact "$0.035 | $1.50 / 1M" display matching Cloak's pricing format.
        var compactRate: String {
            let input = Self.format(inputPerMillion)
            let output = Self.format(outputPerMillion)
            return "\(input) | \(output) / 1M"
        }

        private static func format(_ dollars: Double) -> String {
            let maxDigits = dollars < 0.10 ? 3 : 2
            return dollars.formatted(.currency(code: "USD").precision(.fractionLength(2...maxDigits)))
        }
    }

    var prices: [Price]
    var fallbackInputPrice: Int?
    var fallbackOutputPrice: Int?

    func price(for modelID: String) -> Price? {
        if let exact = prices.first(where: { $0.model == modelID }) { return exact }
        return prices.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    var fallbackEarningScore: Double {
        let input = Double(fallbackInputPrice ?? 50_000) / 1_000_000.0
        let output = Double(fallbackOutputPrice ?? 200_000) / 1_000_000.0
        return input * 0.25 + output * 0.75
    }

    @concurrent static func fetch() async -> DarkbloomPricing? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DarkbloomPricing.self, from: data)
    }
}
#endif
