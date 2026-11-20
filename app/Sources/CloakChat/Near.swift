import CryptoKit
import Dispatch
import Foundation
import Security
import Synchronization

// NEAR mode: each message goes as written to one model on NEAR AI Cloud,
// paid by the owner's own NEAR key, once NEAR's hardware proof passes. The
// proof and the request are the helper's, cloak-near (guest/near, "The
// helper"); this side starts it, writes it one line, and reads its answer.

/// How NEAR mode's helper reaches NEAR and Intel.
public enum NearRoute: Sendable, Equatable {
    /// An ordinary connection: NEAR and Intel see this Mac's internet address.
    case direct
    /// Through tor's SOCKS socket file `socket`, NEAR's connections under the
    /// user name `near` and Intel's under `intel`, each on circuits of its own.
    case tor(socket: String, near: String, intel: String)

    /// As the helper's line has it.
    var line: [String: String] {
        switch self {
        case .direct: ["via": "direct"]
        case .tor(let socket, let near, let intel): ["via": "tor", "socket": socket, "near_identity": near, "intel_identity": intel]
        }
    }
}

/// How long a passed check is used again, in seconds: the helper's
/// `proof_age`.
public enum ProofFreshness: Int, CaseIterable, Identifiable, Sendable {
    case everyMessage = 0
    case tenMinutes = 600
    case oneHour = 3600

    public var id: Self { self }
}

/// What a passed check covered, and when it passed: for a check used again,
/// at an earlier line.
public struct NearProof: Sendable, Equatable, Decodable {
    public let passedAt: Date
    /// How many of the model's servers the Intel check covered.
    public let modelServers: Int
    /// How many GPUs of one server Intel passed.
    public let gpus: Int
}

/// Why a check or a message stopped, and whether the message may have
/// reached NEAR.
public struct NearStop: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, Decodable {
        /// The helper's own steps (guest/near, "Answers").
        case line, request, fetch, refused, connect, pin, send, status, reply
        /// The helper does not match its pin, or cannot start, or its answer
        /// did not read.
        case helper
        /// The helper quit before it answered.
        case ended
        /// The keychain did not give the key.
        case key
    }

    public let kind: Kind
    /// NEAR's HTTP status, for `status` only.
    public let code: Int?
    /// Whether the message may have reached NEAR.
    public let sent: Bool
    /// Technical detail for the log; never the key or a message's text.
    public let text: String
}

/// The owner's NEAR key: a generic password in the login keychain, this
/// device only, in the file keychain as the conversations' key is
/// (`Keychain`). Read only when an `ask` line is built, and given to the
/// helper in that line alone.
public enum NearKeychain {
    static let service = "sh.regents.cloak.near"

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "near",
        ]
    }

    /// Whether a key is kept; reads its attributes only, never the key.
    @concurrent
    public static func has() async throws(Keychain.Failure) -> Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return false }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
        return true
    }

    /// The key. Blocking: called while a line is built, off the main thread.
    public static func key() throws(Keychain.Failure) -> String {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Keychain.Failure(status: status)
        }
        return key
    }

    /// Keeps `key` in place of any key kept before.
    @concurrent
    public static func store(_ key: String) async throws(Keychain.Failure) {
        var query = item
        query[kSecAttrLabel as String] = "Regents Cloak NEAR key"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data(key.utf8)
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }

    /// Removes the key; none kept is no failure.
    @concurrent
    public static func remove() async throws(Keychain.Failure) {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
    }
}

/// NEAR mode's helper, started at the first line after its file matches its
/// pin, and given one line at a time on its own queue: each method blocks on
/// the helper's pipes with no suspension point, so lines go in the order
/// they came, each once its answer is read. One that quits is dropped; the
/// line it stopped is never written again, and the next starts a new one.
public actor Near {
    /// The one model, on NEAR AI Cloud.
    public static let model = "Qwen/Qwen3.8-27B"

    /// The NEAR key, read as an `ask` line is built: `NearKeychain.key` in
    /// the app.
    public typealias Key = @Sendable () throws -> String

    private let helper: URL
    private let sha256: String
    private let queue = DispatchSerialQueue(label: "sh.regents.cloak.near")
    /// The helper's process while one runs, for `stop`, which must not wait
    /// behind a line under way.
    private let current = Mutex<Process?>(nil)
    private var running: Running?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(helper: URL, sha256: String) {
        self.helper = helper
        self.sha256 = sha256
    }

    /// Checks NEAR's hardware, or finds a check that passed within
    /// `proofAge`; sends nothing to the model.
    public func check(route: NearRoute, proofAge: ProofFreshness) throws(NearStop) -> NearProof {
        let line = try exchange(asking: false) { () throws(NearStop) -> [String: Any] in
            ["request": "check", "model": Self.model, "route": route.line, "proof_age": proofAge.rawValue]
        }
        switch try answer(line, asking: false) {
        case .passed(let proof): return proof
        case .stopped(let stop): throw stop
        case .replied: throw NearStop(kind: .helper, code: nil, sent: false, text: "the helper answered a check with a reply")
        }
    }

    /// Sends `turn`'s text as written, after the conversation's earlier
    /// turns as sent and answered, once the check passes (within
    /// `proofAge`). Returns the answer, trimmed, and the check it went on.
    public func ask(
        route: NearRoute, proofAge: ProofFreshness, key: Key, turn: UUID, in conversation: Conversation
    ) throws(NearStop) -> (text: String, proof: NearProof) {
        guard let messages = Remote.messages(for: turn, in: conversation) else {
            throw NearStop(kind: .request, code: nil, sent: false, text: "the turn is not in the conversation")
        }
        let line = try exchange(asking: true) { () throws(NearStop) -> [String: Any] in
            let secret: String
            do { secret = try key() } catch { throw NearStop(kind: .key, code: nil, sent: false, text: "\(error)") }
            return [
                "request": "ask", "model": Self.model, "route": route.line, "proof_age": proofAge.rawValue, "key": secret,
                "body": ["model": Self.model, "messages": messages] as [String: Any],
            ]
        }
        switch try answer(line, asking: true) {
        case .replied(let proof):
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let reply = object["reply"] as? [String: Any], let completion = try? JSONSerialization.data(withJSONObject: reply)
            else { throw NearStop(kind: .helper, code: nil, sent: true, text: "the helper's reply did not read") }
            do throws(RemoteStop) {
                return (try Remote.content(of: completion).trimmingCharacters(in: .whitespacesAndNewlines), proof)
            } catch {
                throw NearStop(kind: .reply, code: nil, sent: true, text: error.detail)
            }
        case .stopped(let stop): throw stop
        case .passed: throw NearStop(kind: .helper, code: nil, sent: true, text: "the helper answered an ask with a check")
        }
    }

    /// Ends the helper at once, a line under way or not: at quit.
    public nonisolated func stop() {
        current.withLock { process in
            if let process { process.terminate() }
        }
    }

    /// Starts the helper if none runs, writes the line `build` makes, and
    /// reads the helper's answer line. `asking`: the line is an `ask`, which
    /// may have reached NEAR once the helper has it all.
    private func exchange(asking: Bool, build: () throws(NearStop) -> [String: Any]) throws(NearStop) -> Data {
        let running = try start()
        let request = try build()
        guard var line = try? JSONSerialization.data(withJSONObject: request, options: .withoutEscapingSlashes) else {
            throw NearStop(kind: .line, code: nil, sent: false, text: "cannot build the line")
        }
        line.append(0x0a)
        do {
            try running.input.write(contentsOf: line)
        } catch {
            // The helper never had the whole line, so it sent nothing.
            drop()
            throw NearStop(kind: .ended, code: nil, sent: false, text: "cannot write to the helper: \(error)")
        }
        guard let answer = running.line() else {
            drop()
            throw NearStop(kind: .ended, code: nil, sent: asking, text: "the helper quit")
        }
        return answer
    }

    private func answer(_ line: Data, asking: Bool) throws(NearStop) -> Answer {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let answer = try? decoder.decode(Answer.self, from: line) else {
            drop()
            throw NearStop(kind: .helper, code: nil, sent: asking, text: "the helper's answer did not read")
        }
        return answer
    }

    /// The helper running, or a new one once its file matches its pin.
    private func start() throws(NearStop) -> Running {
        if let running { return running }
        let digest: String
        do {
            digest = SHA256.hash(data: try Data(contentsOf: helper, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw NearStop(kind: .helper, code: nil, sent: false, text: "cannot read the helper: \(error)")
        }
        guard digest == sha256 else {
            throw NearStop(kind: .helper, code: nil, sent: false, text: "\(helper.path) has sha256 \(digest), pinned \(sha256)")
        }
        let process = Process()
        process.executableURL = helper
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // A write to a helper that quit fails here, rather than ending the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw NearStop(kind: .helper, code: nil, sent: false, text: "cannot start the helper: \(error)")
        }
        current.withLock { $0 = process }
        let started = Running(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        running = started
        return started
    }

    /// Ends the helper and forgets it.
    private func drop() {
        guard let running else { return }
        running.process.terminate()
        try? running.input.close()
        try? running.output.close()
        self.running = nil
        current.withLock { $0 = nil }
    }

    /// The helper while it runs: its process, the pipe it reads, and the
    /// pipe it answers on, with what has come of its next answer.
    private final class Running {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        private var pending = Data()

        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
        }

        /// The next answer line, without its end; nil once the helper's
        /// output ends.
        func line() -> Data? {
            while true {
                if let end = pending.firstIndex(of: 0x0a) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    return line
                }
                // availableData returns what has arrived, and nothing at the end.
                let block = output.availableData
                if block.isEmpty { return nil }
                pending += block
            }
        }
    }

    /// One answer line (guest/near, "Answers"). A reply's completion is
    /// read from the line itself.
    private enum Answer: Decodable {
        case passed(NearProof)
        case replied(NearProof)
        case stopped(NearStop)

        enum CodingKeys: String, CodingKey {
            case answer, sent, proof, stop, code, text
        }

        init(from decoder: any Decoder) throws {
            let answer = try decoder.container(keyedBy: CodingKeys.self)
            switch try answer.decode(String.self, forKey: .answer) {
            case "passed": self = .passed(try answer.decode(NearProof.self, forKey: .proof))
            case "replied": self = .replied(try answer.decode(NearProof.self, forKey: .proof))
            case "stopped":
                self = .stopped(NearStop(
                    kind: try answer.decode(NearStop.Kind.self, forKey: .stop), code: try answer.decodeIfPresent(Int.self, forKey: .code),
                    sent: try answer.decode(Bool.self, forKey: .sent), text: try answer.decode(String.self, forKey: .text)))
            default: throw DecodingError.dataCorruptedError(forKey: .answer, in: answer, debugDescription: "not an answer")
            }
        }
    }
}
