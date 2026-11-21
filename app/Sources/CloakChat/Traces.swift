import CryptoKit
import Foundation
import Security

// Trace sharing's lines to the helper (guest/near, "Trace sharing's lines"),
// what they carry and what comes back, and the keychain item sharing keeps.
// The model that runs them is `TraceShare`.

/// A consent scope of the commons: what it may do with a shared chat. The
/// first is always granted; the others are the owner's to grant.
public enum TraceScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case debuggingEvaluation = "debugging_evaluation"
    case benchmarkOnly = "benchmark_only"
    case rankingTraining = "ranking_training"
    case modelTraining = "model_training"
    case publicAttribution = "public_attribution"

    public var id: Self { self }

    /// The scopes a claim carries: the first, and those of `chosen`, each
    /// once, in the commons' order.
    static func granted(_ chosen: Set<TraceScope>) -> [TraceScope] {
        allCases.filter { $0 == .debuggingEvaluation || chosen.contains($0) }
    }

    /// The uses `scopes` grant, each once, in the commons' order, with
    /// `aggregate_analytics`: as the commons' own client maps them
    /// (`trace-commons-contributor/src/consent.rs`, `scopes_to_allowed_uses`).
    static func uses(of scopes: [TraceScope]) -> [String] {
        var uses: [String] = []
        for scope in scopes {
            let granted: [String] =
                switch scope {
                case .debuggingEvaluation: ["debugging", "evaluation"]
                case .benchmarkOnly: ["benchmark_generation"]
                case .rankingTraining: ["ranking_model_training"]
                case .modelTraining: ["model_training"]
                case .publicAttribution: []
                }
            uses += granted.filter { !uses.contains($0) }
        }
        return uses + ["aggregate_analytics"]
    }
}

/// Where the NEAR AI sign-in starts.
public enum TraceProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case github, google

    public var id: Self { self }
}

/// An enrolled commons account, as `enrol` gave it and every later line
/// carries it back. Nothing in it is secret.
public struct TraceAccount: Codable, Sendable, Equatable {
    let tenantId: String
    let deviceKeyId: String
    let issuerUrl: String
    let audience: String
    /// The witness's pin, as the commons published it at enrolment.
    let witness: Witness

    struct Witness: Codable, Sendable, Equatable {
        let url: String
        let signingAddress: String
        let expectedMeasurements: [String]
    }

    /// As a line has it.
    func line() throws(NearStop) -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(self), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw NearStop(kind: .line, code: nil, sent: false, text: "cannot write the account")
        }
        return object
    }
}

/// A readied message's exchange with NEAR: the request body as it was sent
/// and the reply body as it came, and NEAR's receipt for the two, or why
/// there is none.
public struct TraceExchange: Sendable, Equatable {
    public let request: Data
    public let response: Data
    /// The receipt as JSON, as the helper gave it; nil when there is none.
    let receipt: Data?
    public let noReceipt: String?

    public var hasReceipt: Bool { receipt != nil }
}

/// The witness's answer to a review: the envelope's bytes exactly as they
/// came, its four headers, and the ids it gave the trace.
public struct TraceReview: Sendable, Equatable, Decodable {
    public let envelope: Data
    let certificate: String
    let signature: String
    let evidence: String
    let evidenceSignature: String
    public let submissionId: String
    public let traceId: String
}

/// One trace shared from a chat, and the commons' last word on it.
public struct SharedTrace: Codable, Sendable, Equatable, Identifiable {
    public let chat: UUID
    /// The message it shared.
    public let turn: UUID
    public let submission: String
    public let trace: String
    public let shared: Date
    /// The commons' status, as it last reported it, or `withdrawn` once
    /// withdrawn from this Mac.
    public var status: String
    /// The credit the commons reported, pending and final; nil while it
    /// reported none.
    public var pending: Double?
    public var final: Double?
    /// How far the trace had gone when withdrawn, as the commons said:
    /// `not_distributed`, `commons_not_distributed` or
    /// `commons_distributed`; nil until withdrawn.
    public var reach: String?

    public var id: String { submission }
}

extension Near {
    /// Opens the NEAR AI sign-in: the commons' capabilities are read, and
    /// the helper waits on this Mac's loopback address for the browser. The
    /// sign-in's address for each provider. Sends nothing but that read.
    func listen(route: NearRoute) throws(NearStop) -> [TraceProvider: URL] {
        struct Listening: Decodable {
            let github: URL
            let google: URL
        }
        let line = try exchange(sends: false) { () throws(NearStop) -> [String: Any] in
            ["request": "listen", "route": route.line]
        }
        let listening: Listening = try answer(line, named: "listening", sends: false)
        return [.github: listening.github, .google: listening.google]
    }

    /// Waits for the sign-in `listen` opened, then enrols the device key
    /// whose seed is `deviceKey`. The account and its session; the NEAR AI
    /// session is dropped by the helper once the enrolment is sent.
    func enrol(route: NearRoute, deviceKey: Data) throws(NearStop) -> (account: TraceAccount, session: String) {
        struct Enrolled: Decodable {
            let account: TraceAccount
            let session: String
        }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            ["request": "enrol", "route": route.line, "device_key": deviceKey.base64EncodedString()]
        }
        let enrolled: Enrolled = try answer(line, named: "enrolled", sends: true)
        return (enrolled.account, enrolled.session)
    }

    /// An upload claim, then the commons' challenge under it: the binding
    /// the readied message carries, and when it ends.
    func ready(route: NearRoute, deviceKey: Data, account: TraceAccount, scopes: [TraceScope]) throws(NearStop) -> (
        binding: String, expires: Date
    ) {
        struct Admitted: Decodable {
            let binding: String
            let expiresAt: Date
        }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            [
                "request": "ready", "route": route.line, "device_key": deviceKey.base64EncodedString(), "account": try account.line(),
                "scopes": scopes.map(\.rawValue), "uses": TraceScope.uses(of: scopes),
            ]
        }
        let admitted: Admitted = try answer(line, named: "admitted", sends: true)
        return (admitted.binding, admitted.expiresAt)
    }

    /// Sends `turn` as `ask` does, but without Cloak's encryption and
    /// carrying the commons' challenge `admission`, then fetches NEAR's
    /// receipt for it. The answer, the check it went on, the tokens, and
    /// the exchange to review.
    func readied(
        route: NearRoute, proofAge: ProofFreshness, key: Key, turn: UUID, in conversation: Conversation, admission: String
    ) throws(NearStop) -> (text: String, proof: NearProof, tokens: Tokens?, exchange: TraceExchange) {
        struct Exchanged: Decodable {
            let proof: NearProof
            let request: Data
            let response: Data
            let noReceipt: String?
        }
        guard let messages = Remote.messages(for: turn, in: conversation) else {
            throw NearStop(kind: .request, code: nil, sent: false, text: "the turn is not in the conversation")
        }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            [
                "request": "readied", "model": Self.model, "route": route.line, "proof_age": proofAge.rawValue,
                "key": try Self.read(key), "body": ["model": Self.model, "messages": messages] as [String: Any],
                "admission": admission,
            ]
        }
        let exchanged: Exchanged = try answer(line, named: "exchanged", sends: true)
        let receipt = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["receipt"].flatMap {
            try? JSONSerialization.data(withJSONObject: $0)
        }
        guard (receipt == nil) != (exchanged.noReceipt == nil) else {
            throw NearStop(kind: .helper, code: nil, sent: true, text: "the helper's exchange has no receipt and no reason")
        }
        let (text, tokens) = try Self.reply(in: line)
        return (
            text, exchanged.proof, tokens,
            TraceExchange(request: exchanged.request, response: exchanged.response, receipt: receipt, noReceipt: exchanged.noReceipt)
        )
    }

    /// Checks the witness's enclave against the pin in `account`, and only
    /// once it passes sends it `exchange`, as one raw contribution, for
    /// redaction. Its answer exactly.
    func review(
        route: NearRoute, account: TraceAccount, scopes: [TraceScope], exchange: TraceExchange, version: String
    ) throws(NearStop) -> TraceReview {
        guard let receipt = exchange.receipt, let receiptLine = try? JSONSerialization.jsonObject(with: receipt) else {
            throw NearStop(kind: .request, code: nil, sent: false, text: "the exchange has no receipt")
        }
        let line = try self.exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            [
                "request": "review", "route": route.line, "account": try account.line(), "scopes": scopes.map(\.rawValue),
                "uses": TraceScope.uses(of: scopes), "version": version,
                "exchange": [
                    "request": exchange.request.base64EncodedString(), "response": exchange.response.base64EncodedString(),
                    "receipt": receiptLine,
                ] as [String: Any],
            ]
        }
        return try answer(line, named: "reviewed", sends: true)
    }

    /// Uploads `review`'s envelope, its bytes exactly and no others, with
    /// its four headers, under a new claim. The status the commons gave it,
    /// and the credit it reported, if any.
    func upload(route: NearRoute, deviceKey: Data, account: TraceAccount, scopes: [TraceScope], review: TraceReview) throws(NearStop)
        -> (status: String, pending: Double?, final: Double?)
    {
        struct Uploaded: Decodable {
            let commons: Receipt
            /// The commons' `TraceSubmissionReceipt`.
            struct Receipt: Decodable {
                let status: String?
                let creditPointsPending: Double?
                let creditPointsFinal: Double?
            }
        }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            [
                "request": "upload", "route": route.line, "device_key": deviceKey.base64EncodedString(), "account": try account.line(),
                "scopes": scopes.map(\.rawValue), "uses": TraceScope.uses(of: scopes),
                "envelope": [
                    "body": review.envelope.base64EncodedString(), "certificate": review.certificate, "signature": review.signature,
                    "evidence": review.evidence, "evidence_signature": review.evidenceSignature,
                ],
            ]
        }
        let uploaded: Uploaded = try answer(line, named: "uploaded", sends: true)
        // A receipt without a status is an accepted one, as the commons'
        // own schema reads it (`default_submission_status`).
        return (uploaded.commons.status ?? "accepted", uploaded.commons.creditPointsPending, uploaded.commons.creditPointsFinal)
    }

    /// The commons' status of each of `submissions`, 1 to 100 of them, as
    /// it reported them.
    func status(route: NearRoute, deviceKey: Data, account: TraceAccount, submissions: [String]) throws(NearStop) -> [Reported] {
        struct Reports: Decodable { let commons: [Reported] }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            [
                "request": "status", "route": route.line, "device_key": deviceKey.base64EncodedString(), "account": try account.line(),
                "submissions": submissions,
            ]
        }
        let reports: Reports = try answer(line, named: "reported", sends: true)
        return reports.commons
    }

    /// One submission's status, as the commons reported it
    /// (`TraceSubmissionStatusUpdate`).
    struct Reported: Decodable {
        let submissionId: String
        let status: String
        let creditPointsPending: Double
        let creditPointsFinal: Double?
    }

    /// Withdraws `submission` under the account session. How far it had
    /// gone, as the commons said, and the session if the commons renewed it.
    func withdraw(route: NearRoute, session: String, submission: String) throws(NearStop) -> (reach: String, session: String?) {
        struct Withdrawn: Decodable {
            let commons: Commons
            let session: String?
            struct Commons: Decodable { let distributionReach: String }
        }
        let line = try exchange(sends: true) { () throws(NearStop) -> [String: Any] in
            ["request": "withdraw", "route": route.line, "session": session, "submission": submission]
        }
        let withdrawn: Withdrawn = try answer(line, named: "withdrawn", sends: true)
        return (withdrawn.commons.distributionReach, withdrawn.session)
    }
}

/// What sharing keeps on this Mac, in one keychain item (`TracesKeychain`):
/// the device key's seed, the account and its session, the owner's choices,
/// and the traces shared.
struct TraceRecord: Codable, Sendable, Equatable {
    let deviceKey: Data
    var account: TraceAccount
    var session: String
    /// The provider the owner last signed in with.
    var provider: TraceProvider
    /// The scopes granted beyond the first.
    var scopes: Set<TraceScope>
    var shared: [SharedTrace]
}

/// Where the record is kept: the keychain in the app, a stand-in in the
/// checks. `load` gives nil when nothing is kept.
public struct TraceVault: Sendable {
    let load: @Sendable () async throws -> Data?
    let save: @Sendable (Data) async throws -> Void

    public init(load: @escaping @Sendable () async throws -> Data?, save: @escaping @Sendable (Data) async throws -> Void) {
        self.load = load
        self.save = save
    }

    public static let keychain = TraceVault(load: { try await TracesKeychain.load() }, save: { try await TracesKeychain.store($0) })
}

/// Trace sharing's record: a generic password in the login keychain, this
/// device only, in the file keychain as the NEAR key is (`NearKeychain`),
/// under a service of its own. Read when Share Traces is turned on, and
/// written after each change.
public enum TracesKeychain {
    static let service = "sh.regents.cloak.traces"

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "traces",
        ]
    }

    /// The record, or nil when none is kept.
    @concurrent
    public static func load() async throws(Keychain.Failure) -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Keychain.Failure(status: status) }
        return data
    }

    /// Keeps `record` in place of any kept before.
    @concurrent
    public static func store(_ record: Data) async throws(Keychain.Failure) {
        var query = item
        query[kSecAttrLabel as String] = "Regents Cloak trace sharing"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = record
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: record] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }
}

extension TraceRecord {
    /// A new device key's seed: Ed25519, 32 bytes, as the helper takes it.
    static func newDeviceKey() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }
}
