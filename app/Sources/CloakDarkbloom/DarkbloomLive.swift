import Foundation
import Security

/// Live macOS/OS/HTTP adapter for Darkbloom (`Layr-Labs/d-inference`, verified
/// against `v0.10.16`–`v0.10.19`): signed binary verification (`SecStaticCode`),
/// CLI subprocess spawning, `launchd` setup inspection, loopback control API
/// (`127.0.0.1`), and public `/v1/pricing` fetch.
public enum Darkbloom {
    /// Where Darkbloom's installer puts its command line.
    public static let cli = URL.homeDirectory.appending(path: ".darkbloom/bin/darkbloom")
    /// Darkbloom's installer, as its documented `curl -fsSL … | bash` fetches
    /// it (docs/provider/installation.md:30).
    public static let installer = URL(string: "https://api.darkbloom.dev/install.sh")!
    /// The oldest release whose flags, files and control service Cloak was
    /// built against.
    public static let oldest = [0, 10, 16]
    /// What Darkbloom's own app requires of the command line before it runs
    /// it (desktop-app/src/main/backend.ts:20–21), and its installer of what it
    /// installs (scripts/install.sh:38): Apple's chain, the identifier
    /// `io.darkbloom.provider`, Darkbloom's team `SLDQ2GJ6TL`, and that team's
    /// certificate itself.
    public static let requirement = #"anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL" and certificate leaf = H"95b67556e04653f56ba5411d20d33dd263ef6e2a""#

    /// Whether this Mac's system is one Darkbloom installs on: macOS 27 or
    /// later (scripts/install.sh:434–449).
    public static var systemFits: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    /// What Cloak found of the command line: the checked file, its release,
    /// the flags its `start` takes, and its control service with what that
    /// last reported, when it answers for this release.
    public struct Found: Sendable {
        public var binary: URL
        public var version: String
        public var flags: Set<String>
        public var control: DarkbloomControlClient?
        public var snapshot: DarkbloomSnapshot?

        public init(
            binary: URL,
            version: String,
            flags: Set<String>,
            control: DarkbloomControlClient? = nil,
            snapshot: DarkbloomSnapshot? = nil
        ) {
            self.binary = binary
            self.version = version
            self.flags = flags
            self.control = control
            self.snapshot = snapshot
        }
    }

    /// The result of checking `~/.darkbloom/bin/darkbloom`.
    public enum Lookup: Sendable {
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
    @concurrent public static func find() async throws(DarkbloomFailure) -> Lookup {
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
            found.control = .live(control)
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
    public static func verify(_ binary: URL) throws(DarkbloomFailure) {
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
    public static func release(_ text: String) -> [Int]? {
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
    @concurrent public static func modelRequiredCapabilities(_ binary: URL) async -> [String: [String]] {
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
        guard let data = output.data(using: .utf8),
            let entries = try? JSONDecoder.darkbloom.decode([Entry].self, from: data)
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
    /// `darkbloom models --json`, failing closed on unknown future capability
    /// tags (matching Darkbloom's `ProviderRuntimeCapability` contract).
    public static func hostSupports(
        requiredCapabilities: [String],
        cpuBrand: String? = nil,
        physicalMemoryBytes: UInt64? = nil
    ) -> Bool {
        guard !requiredCapabilities.isEmpty else { return true }
        let brand = (cpuBrand ?? cpuBrandString()).lowercased()
        let memory = physicalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory
        let chipGeneration: Int = {
            guard let range = brand.range(of: #"apple m(\d+)"#, options: .regularExpression) else { return 0 }
            let digits = brand[range].filter(\.isNumber)
            return Int(digits) ?? 0
        }()
        let isM5OrNewer = chipGeneration >= 5
        let isMaxOrUltra = brand.contains("max") || brand.contains("ultra")
        let twoFiftySixGiB: UInt64 = 256 * 1_073_741_824
        for cap in requiredCapabilities {
            let lower = cap.lowercased()
            switch lower {
            case "model_revisions_v1", "cache_policy_v1":
                continue
            case "apple_m5", "mlx_nax":
                if !isM5OrNewer { return false }
            case "glm5_next_v1":
                // Darkbloom GLM5NextHardwareRequirement: M5 Max/Ultra, >= 256 GiB.
                if !(isM5OrNewer && isMaxOrUltra && memory >= twoFiftySixGiB) { return false }
            default:
                if lower.hasPrefix("apple_m5") {
                    if !isM5OrNewer { return false }
                } else {
                    // Fail closed on unknown future hardware/runtime capability tags.
                    return false
                }
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
    public static func startNeeds(alsoServe: Bool) -> Set<String> {
        [alsoServe ? "--me-first" : "--local", "--route", "--bind", "--model"]
    }

    /// The arguments of Cloak's Start: this Mac's model, its address on
    /// 127.0.0.1 only, the person's requests never sent on to another Mac or
    /// the network (`--route this-mac`), and either this Mac alone
    /// (`--local`, Darkbloom's Only me) or also Darkbloom's network with the
    /// person's requests first (`--me-first`).
    public static func startArguments(model: String, alsoServe: Bool) -> [String] {
        ["start", alsoServe ? "--me-first" : "--local", "--route", "this-mac", "--bind", "127.0.0.1", "--model", model]
    }

    /// Checks whether a Darkbloom provider daemon is currently alive on this
    /// Mac by reading `~/.darkbloom/daemon-state.json` (written every few
    /// seconds by `darkbloom start`, even when `darkbloom desktop` isn't running).
    public static func isDaemonAlive() -> Bool {
        let file = URL.homeDirectory.appending(path: ".darkbloom/daemon-state.json")
        struct DaemonState: Decodable {
            let pid: Int32
            let writtenAt: Double?
        }
        guard let data = try? Data(contentsOf: file),
            let state = try? JSONDecoder.darkbloom.decode(DaemonState.self, from: data),
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
    @concurrent public static func capture(_ executable: URL, _ arguments: [String]) async -> String {
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
    /// back each line it writes on either output as it comes.
    public static func lines(
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
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// A program that ended with a status other than 0.
    public struct Exit: Error {
        public let status: Int32
    }

    /// Runs the command line to its end; when it doesn't end well, throws
    /// `words` with its last reason as the detail.
    @concurrent public static func run(_ binary: URL, _ arguments: [String], failing words: String) async throws(DarkbloomFailure) {
        var reasons = DarkbloomReasons()
        do {
            for try await line in lines(binary, arguments) {
                reasons.hear(line)
            }
        } catch {
            throw DarkbloomFailure(words, detail: reasons.reason)
        }
    }

    /// Fetches Darkbloom's installer from `api.darkbloom.dev` and runs it with
    /// bash and `COORD_URL=https://api.darkbloom.dev`.
    @concurrent public static func install(step: @escaping @MainActor @Sendable (Int) -> Void) async throws(DarkbloomFailure) {
        let folder = URL.temporaryDirectory.appending(path: "darkbloom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "install.sh")
        do {
            var request = URLRequest(url: installer)
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
        var reasons = DarkbloomReasons()
        do {
            for try await line in lines(URL(filePath: "/bin/bash"), [script.path], environment: environment) {
                reasons.hear(line)
                if line.hasPrefix("→ ["), let number = line.dropFirst(3).first?.wholeNumberValue {
                    await step(number)
                }
            }
        } catch {
            throw DarkbloomFailure("Couldn't install", detail: reasons.reason)
        }
    }

    /// Reads Darkbloom's launchd plist, `local.json`, and `provider.toml`.
    @concurrent public static func readSetup(listening: Bool) async -> DarkbloomSetup {
        let home = URL.homeDirectory
        var setup = DarkbloomSetup()
        var config = false
        if let data = try? Data(contentsOf: home.appending(path: "Library/LaunchAgents/io.darkbloom.provider.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        {
            let mode: DarkbloomSetup.Mode = arguments.contains("--local")
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
            setup.job = DarkbloomSetup.Job(
                mode: mode, bind: bind, models: models, loaded: loaded, running: running,
                runsAtLoad: plist["RunAtLoad"] as? Bool == true)
            config = arguments.contains("--config")
        }
        if listening, let data = try? Data(contentsOf: home.appending(path: ".darkbloom/local.json")) {
            struct Record: Decodable { let host: String }
            setup.listens = (try? JSONDecoder().decode(Record.self, from: data))?.host
        }
        if !config, let toml = try? String(contentsOf: home.appending(path: ".config/darkbloom/provider.toml"), encoding: .utf8) {
            setup.route = DarkbloomSetup.route(in: toml)
        }
        return setup
    }

    private static func launchd() async -> (loaded: Bool, running: Bool) {
        var running = false
        do {
            for try await line in lines(URL(filePath: "/bin/launchctl"), ["print", "gui/\(getuid())/io.darkbloom.provider"]) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") { running = true }
            }
        } catch {
            return (false, false)
        }
        return (true, running)
    }

    /// Fetches live per-million-token pricing from `https://api.darkbloom.dev/v1/pricing`.
    @concurrent public static func fetchPricing() async -> DarkbloomPricing? {
        var request = URLRequest(url: DarkbloomPricing.endpoint)
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
        return try? JSONDecoder.darkbloom.decode(DarkbloomPricing.self, from: data)
    }
}

/// Injectable loopback control client handle (matching `Door.Parts` / `Agent.Parts`
/// closure-struct style) so `DarkbloomMode` can be driven by real HTTP in production
/// and deterministic in-memory streams/fixtures in `CloakTests`.
public struct DarkbloomControlClient: Sendable {
    public var state: @Sendable () async throws(DarkbloomError) -> DarkbloomSnapshot
    public var cloud: @Sendable () async throws(DarkbloomError) -> DarkbloomCloudEarnings
    public var endpointKey: @Sendable () async throws(DarkbloomError) -> String?
    public var act: @Sendable (DarkbloomAction) async throws(DarkbloomError) -> DarkbloomSnapshot.Operation
    public var events: @Sendable () -> AsyncThrowingStream<DarkbloomSnapshot, any Error>

    public init(
        state: @escaping @Sendable () async throws(DarkbloomError) -> DarkbloomSnapshot,
        cloud: @escaping @Sendable () async throws(DarkbloomError) -> DarkbloomCloudEarnings,
        endpointKey: @escaping @Sendable () async throws(DarkbloomError) -> String?,
        act: @escaping @Sendable (DarkbloomAction) async throws(DarkbloomError) -> DarkbloomSnapshot.Operation,
        events: @escaping @Sendable () -> AsyncThrowingStream<DarkbloomSnapshot, any Error>
    ) {
        self.state = state
        self.cloud = cloud
        self.endpointKey = endpointKey
        self.act = act
        self.events = events
    }

    public static func live(_ control: DarkbloomControl) -> DarkbloomControlClient {
        DarkbloomControlClient(
            state: { () async throws(DarkbloomError) in try await control.state() },
            cloud: { () async throws(DarkbloomError) in try await control.cloud() },
            endpointKey: { () async throws(DarkbloomError) in try await control.endpointKey() },
            act: { action throws(DarkbloomError) in try await control.act(action) },
            events: { control.events() }
        )
    }
}

/// Darkbloom's live loopback control service (`127.0.0.1`), authenticated with
/// the token in `~/.darkbloom/desktop/connection.json`, with no proxy, cookies,
/// redirects, or `Origin`.
public struct DarkbloomControl: Sendable {
    public let port: Int
    private let token: String

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }

    public static func discover() throws(DarkbloomFailure) -> DarkbloomControl? {
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

    public func state() async throws(DarkbloomError) -> DarkbloomSnapshot {
        try await send(request("state"))
    }

    public func cloud() async throws(DarkbloomError) -> DarkbloomCloudEarnings {
        try await send(request("cloud"))
    }

    public func endpointKey() async throws(DarkbloomError) -> String? {
        let key: Key? = try await send(request("endpoint-key"))
        return key?.key
    }

    private struct Key: Decodable {
        let key: String
    }

    public func act(_ action: DarkbloomAction) async throws(DarkbloomError) -> DarkbloomSnapshot.Operation {
        var request = request("actions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = action.body
        return try await send(request)
    }

    public func events() -> AsyncThrowingStream<DarkbloomSnapshot, any Error> {
        let request = request("events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DarkbloomError.unreachable }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let snapshot = try? JSONDecoder.darkbloom.decode(DarkbloomSnapshot.self, from: Data(line.dropFirst(5).utf8))
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
            throw .refused((try? JSONDecoder.darkbloom.decode(Refusal.self, from: data))?.error ?? "Darkbloom refused.")
        }
        guard let answer = try? JSONDecoder.darkbloom.decode(Answer.self, from: data) else { throw .unreadable }
        return answer
    }

    private struct Refusal: Decodable {
        let error: String
    }

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
