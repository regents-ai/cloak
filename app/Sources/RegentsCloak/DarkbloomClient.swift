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
    /// installs (scripts/install.sh:39): Apple's chain, the identifier
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

    /// Looks for the command line and checks it: its signature, then its
    /// release, then its flags, then whether its control service answers.
    /// Nil when it isn't installed.
    @concurrent static func find() async throws(DarkbloomFailure) -> Found? {
        guard FileManager.default.fileExists(atPath: cli.path) else { return nil }
        let binary = cli.resolvingSymlinksInPath()
        try verify(binary)
        guard let version = await installedVersion(binary), let numbers = release(version) else {
            throw DarkbloomFailure("Unknown version", detail: "Darkbloom's command line didn't give a release Cloak can read.")
        }
        guard !numbers.lexicographicallyPrecedes(oldest) else {
            throw DarkbloomFailure(
                "Needs an update",
                detail: "Cloak works with Darkbloom 0.10.16 or later; this Mac has \(version). Run darkbloom update in Terminal.")
        }
        var found = Found(binary: binary, version: version, flags: await startFlags(binary))
        guard let control = try DarkbloomControl.discover() else { return found }
        do {
            let snapshot = try await control.state()
            // A service left from another release answers for that one; Connect restarts it (`desktop ensure`).
            guard snapshot.version == version else { return found }
            found.control = control
            found.snapshot = snapshot
        } catch .unreachable {
            return found
        } catch {
            throw DarkbloomFailure("Unknown Darkbloom", detail: error.reason)
        }
        return found
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

    /// Runs `executable` with `arguments` and nothing on its input, handing
    /// back each line it writes on either output as it comes. It ends once
    /// the program does, throwing `Exit` unless it ended well.
    static func lines(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    if let environment { process.environment = environment }
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                    process.waitUntilExit()
                    continuation.finish(throwing: process.terminationStatus == 0 ? nil : Exit(status: process.terminationStatus))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    /// The local address's key, or nil when it takes none.
    func endpointKey() async throws(DarkbloomError) -> String? {
        struct Key: Decodable { let key: String? }
        let key: Key = try await send(request("endpoint-key"))
        return key.key
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
    var catalogError: String?

    struct Model: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var displayName: String
        /// The download's size, in Darkbloom's GB.
        var sizeGb: Double?
        /// What it takes in memory once loaded, known once downloaded.
        var memoryGb: Double?
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
            let mode: Mode = arguments.contains("--local") ? .onlyMe : arguments.contains("--local-endpoint") ? .both : .network
            let bind = arguments.firstIndex(of: "--bind").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            let (loaded, running) = await launchd()
            setup.job = Job(mode: mode, bind: bind, loaded: loaded, running: running, runsAtLoad: plist["RunAtLoad"] as? Bool == true)
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
            return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Whether `address` is this Mac's loopback, which only this Mac reaches.
    static func loopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1"
    }
}
