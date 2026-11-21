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
/// none is refused here for one already under way. Each message goes by
/// `TraceShare`, which sends it as it always goes unless its chat is the one
/// readied for sharing; `share` follows the Share Traces switch.
@MainActor
@Observable
final class NearMode {
    /// The last NEAR message that stopped.
    struct SendStop {
        let turn: UUID
        let stop: NearStop
    }

    let near: Near
    let share: TraceShare
    let supervisor: Supervisor
    let settings: AppSettings
    /// Whether a NEAR key is kept, as the keychain last answered; nil until
    /// it has, or when it could not.
    private(set) var hasKey: Bool?
    /// The last keychain request from Settings failed.
    private(set) var keyFailed = false
    /// The last check that passed, the one a message last went on included;
    /// nil once one stopped.
    private(set) var proof: NearProof?
    /// When the checks under way began; nil while none is.
    private(set) var checking: Date?
    /// The last check that stopped, until one passes.
    private(set) var checkStop: NearStop?
    /// The last message that stopped, until the next Send or it is
    /// dismissed.
    var sendStop: SendStop?
    @ObservationIgnored private var checks = 0
    private let nearIdentity = Chat.newIdentity()
    private let intelIdentity = Chat.newIdentity()
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "near")

    init(near: Near, share: TraceShare, supervisor: Supervisor, settings: AppSettings) {
        self.near = near
        self.share = share
        self.supervisor = supervisor
        self.settings = settings
        Task { await find() }
        Task {
            for await on in Observations({ settings.shareTraces }) { await share.turn(on: on) }
        }
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
        if hasKey == false { return "Add your NEAR key in Settings." }
        if route == nil { return "Start Cloak to send through Tor." }
        return nil
    }

    /// Checks NEAR's hardware on the route now, or finds a check that passed
    /// within the freshness chosen. Sends nothing to the model.
    func check() async {
        guard let route else { return }
        if checking == nil { checking = .now }
        checks += 1
        defer {
            checks -= 1
            if checks == 0 { checking = nil }
        }
        do throws(NearStop) {
            proof = try await near.check(route: route, proofAge: settings.proofFreshness)
            checkStop = nil
        } catch {
            logger.error("a NEAR check stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .private)")
            proof = nil
            checkStop = error
        }
    }

    /// Sends `turn` as written on `route`, once the check passes, sealed
    /// unless Share Traces is on at the press and its chat is readied for
    /// sharing; returns NEAR's answer and the tokens it counted for it, when
    /// its reply says, or nil when it stopped (`sendStop`).
    func send(_ turn: UUID, in conversation: Conversation, route: NearRoute) async -> (text: String, tokens: Tokens?)? {
        sendStop = nil
        do throws(NearStop) {
            let answer = try await share.send(
                turn, in: conversation, shares: settings.shareTraces, on: near, route: route, proofAge: settings.proofFreshness,
                key: { try NearKeychain.key() })
            proof = answer.proof
            checkStop = nil
            return (answer.text, answer.tokens)
        } catch {
            logger.error("a NEAR message stopped: \(error.kind.rawValue, privacy: .public) \(error.text, privacy: .private)")
            sendStop = SendStop(turn: turn, stop: error)
            // The helper keeps no check after these, so the next message
            // checks again.
            switch error.kind {
            case .fetch, .refused, .pin, .reply, .helper, .ended:
                proof = nil
                checkStop = error
            case .line, .request, .connect, .send, .status, .key, .signin, .claim, .moved, .expired, .interrupted: break
            }
            return nil
        }
    }

    /// Asks the keychain whether a key is kept, without reading it.
    func find() async {
        do throws(Keychain.Failure) {
            hasKey = try await NearKeychain.has()
            keyFailed = false
        } catch {
            logger.error("cannot read whether a NEAR key is kept: \(error.description, privacy: .public)")
            hasKey = nil
            keyFailed = true
        }
    }

    /// Keeps `key` in place of any before; returns whether it was kept.
    func save(_ key: String) async -> Bool {
        do throws(Keychain.Failure) {
            try await NearKeychain.store(key)
            hasKey = true
            keyFailed = false
            return true
        } catch {
            logger.error("cannot keep the NEAR key: \(error.description, privacy: .public)")
            keyFailed = true
            return false
        }
    }

    /// Removes the key.
    func remove() async {
        do throws(Keychain.Failure) {
            try await NearKeychain.remove()
            hasKey = false
            keyFailed = false
        } catch {
            logger.error("cannot remove the NEAR key: \(error.description, privacy: .public)")
            keyFailed = true
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
