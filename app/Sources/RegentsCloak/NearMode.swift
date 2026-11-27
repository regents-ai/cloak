import CloakChat
import CloakSupervisor
import Foundation
import Observation
import os

/// NEAR mode: each message goes as written to one model on NEAR AI Cloud,
/// paid by the owner's own NEAR key, once NEAR's hardware check passes
/// (`Near`, the helper's owner). Direct, NEAR and Intel see this Mac's
/// internet address; through Tor, which needs Cloak running, they see a Tor
/// address, NEAR's connections and Intel's each under a name of their own,
/// new at each launch. The key is in the keychain only (`NearKeychain`).
/// Every press of Send reaches the helper, which takes one line at a time;
/// none is refused here for one already under way.
@MainActor
@Observable
final class NearMode {
    let near: Near
    let supervisor: Supervisor
    let settings: AppSettings
    let traces: NearTraces
    /// Whether a NEAR key is kept, as the keychain last answered; nil until
    /// it has. A read, save or remove the keychain refuses leaves it as it
    /// was and throws to whoever asked, which shows the stop where it asked:
    /// Settings' Key row, or the Wallet's.
    private(set) var hasKey: Bool?
    /// One local-only record of the actual TLS parameters negotiated with NEAR's
    /// gateway. Held strictly in memory on this Mac (zero telemetry, never sent).
    struct CryptoSessionEntry: Identifiable, Sendable, Equatable {
        let id = UUID()
        let recordedAt: Date
        let routeLabel: String
        let tlsProtocol: String
        let tlsKeyExchange: String
        let tlsCipherSuite: String?
        let isHybridPostQuantum: Bool
    }

    private static let maxCryptoSessions = 12

    /// Bounded in-memory log of recent negotiated NEAR TLS sessions (newest first).
    private(set) var cryptoSessions: [CryptoSessionEntry] = []

    /// Plain-text summary of recent negotiated TLS sessions for local diagnostic reports.
    var negotiatedCryptoSummary: String? {
        guard !cryptoSessions.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        return cryptoSessions.map { entry in
            let posture = entry.isHybridPostQuantum ? "hybrid-PQ" : "classical-ECC"
            let suite = entry.tlsCipherSuite.map { " · \($0)" } ?? ""
            return "\(fmt.string(from: entry.recordedAt)) | \(entry.routeLabel) | \(entry.tlsProtocol) · \(entry.tlsKeyExchange)\(suite) [\(posture)]"
        }
        .joined(separator: "\n")
    }

    private func recordCryptoSession(from proof: NearProof, route: NearRoute) {
        guard let kex = proof.tlsKeyExchange else { return }
        let entry = CryptoSessionEntry(
            recordedAt: .now,
            routeLabel: route == .direct ? "Direct" : "Tor",
            tlsProtocol: proof.tlsProtocol ?? "TLS",
            tlsKeyExchange: kex,
            tlsCipherSuite: proof.tlsCipherSuite,
            isHybridPostQuantum: proof.isHybridPostQuantumTLS
        )
        cryptoSessions.insert(entry, at: 0)
        if cryptoSessions.count > Self.maxCryptoSessions {
            cryptoSessions.removeLast(cryptoSessions.count - Self.maxCryptoSessions)
        }
    }

    /// The last check that passed, the one a message last went on included;
    /// nil once one stopped.
    private(set) var proof: NearProof?
    /// When the checks under way began; nil while none is.
    private(set) var checking: Date?
    /// The last check that stopped, until one passes.
    private(set) var checkStop: NearStop?
    @ObservationIgnored private var checks = 0
    /// Monotonic token so an older or cancelled check never overwrites a newer
    /// proof when the route changes (e.g. toggling Tor).
    @ObservationIgnored private var checkGeneration = 0
    private var nearIdentity = Chat.newIdentity()
    private var intelIdentity = Chat.newIdentity()

    private func rotateTorIdentities() {
        nearIdentity = Chat.newIdentity()
        intelIdentity = Chat.newIdentity()
    }
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "near")

    init(near: Near, supervisor: Supervisor, settings: AppSettings) {
        self.near = near
        self.supervisor = supervisor
        self.settings = settings
        self.traces = NearTraces(settings: settings)
        // For Send's block. A refusal here has nowhere to show; Settings and
        // the Wallet each ask again as they appear, and show their own.
        Task { try? await find() }
    }

    /// How the helper goes now: direct, or through Cloak's tor while Cloak
    /// runs; nil while Tor is on and Cloak is not running.
    var route: NearRoute? {
        guard settings.nearTor else { return .direct }
        return supervisor.torSocket.map { .tor(socket: $0, near: nearIdentity, intel: intelIdentity) }
    }

    /// Why Send is off now, or nil when it is on. Off only where sending is
    /// certain to stop: no key kept, or Tor on while Cloak is not running. A
    /// check or a send under way never turns it off.
    var sendBlock: String? {
        if hasKey == nil { return "Checking NEAR key…" }
        if hasKey == false { return "Add your NEAR key to send." }
        if route == nil { return "Start Cloak to send through Tor." }
        return nil
    }

    /// Checks NEAR's hardware on the route now, or finds a check that passed
    /// within the freshness chosen. Sends nothing to the model.
    func check() async {
        guard let route else { return }
        checkGeneration += 1
        let generation = checkGeneration
        if checking == nil { checking = .now }
        checks += 1
        defer {
            checks -= 1
            if checks == 0 { checking = nil }
        }
        do throws(NearStop) {
            let verified = try await near.check(route: route, proofAge: settings.proofFreshness)
            guard generation == checkGeneration, !Task.isCancelled else { return }
            proof = verified
            recordCryptoSession(from: verified, route: route)
            checkStop = nil
        } catch {
            guard generation == checkGeneration, !Task.isCancelled else { return }
            logger.error("a NEAR check stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .private)")
            if settings.nearTor, [.fetch, .connect, .send, .status].contains(error.kind) {
                rotateTorIdentities()
            }
            proof = nil
            checkStop = error
        }
    }

    /// Sends `turn` as written on `route`, once the check passes; returns
    /// NEAR's answer and the tokens it counted for it, when its reply says,
    /// or throws why it stopped, which Chat keeps with the turn.
    func send(_ turn: UUID, in conversation: Conversation, route: NearRoute) async throws(NearStop) -> (text: String, tokens: Tokens?) {
        let generation = checkGeneration
        do throws(NearStop) {
            let answer = try await near.ask(
                route: route, proofAge: settings.proofFreshness, key: { try NearKeychain.key() }, turn: turn, in: conversation)
            if self.route == route && checkGeneration == generation {
                proof = answer.proof
                recordCryptoSession(from: answer.proof, route: route)
                checkStop = nil
            }
            return (answer.text, answer.tokens)
        } catch {
            // The helper keeps no check after genuine attestation/pin/transport
            // failures; a model content refusal (`.reply`) is NOT a TEE failure,
            // and stale sends from a prior route must not clobber the active route.
            if self.route == route && checkGeneration == generation {
                if settings.nearTor, [.fetch, .connect, .send, .status].contains(error.kind) {
                    rotateTorIdentities()
                }
                switch error.kind {
                case .fetch, .refused, .pin, .helper, .ended:
                    proof = nil
                    checkStop = error
                case .reply, .line, .request, .connect, .send, .status, .key: break
                }
            }
            throw error
        }
    }

    /// Asks the keychain whether a key is kept, without reading it.
    func find() async throws(Keychain.Failure) {
        do throws(Keychain.Failure) {
            hasKey = try await NearKeychain.has()
        } catch {
            logger.error("cannot read whether a NEAR key is kept: \(error.description, privacy: .public)")
            throw error
        }
    }

    /// Keeps `key` in place of any before.
    func save(_ key: String) async throws(Keychain.Failure) {
        do throws(Keychain.Failure) {
            try await NearKeychain.store(key)
            hasKey = true
        } catch {
            logger.error("cannot keep the NEAR key: \(error.description, privacy: .public)")
            throw error
        }
    }

    /// Removes the key.
    func remove() async throws(Keychain.Failure) {
        do throws(Keychain.Failure) {
            try await NearKeychain.remove()
            hasKey = false
        } catch {
            logger.error("cannot remove the NEAR key: \(error.description, privacy: .public)")
            throw error
        }
    }
}

extension ProofFreshness {
    var title: String {
        switch self {
        case .everyMessage: "Every message"
        case .tenMinutes: "10 minutes"
        case .oneHour: "1 hour"
        }
    }
}
