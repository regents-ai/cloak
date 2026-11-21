import Foundation
import Observation

/// Trace sharing in NEAR Private AI (docs/near-share.md, section 7;
/// docs/state-machines.md, section 9f): one NEAR chat at a time is readied,
/// its next message goes without Cloak's encryption carrying the commons'
/// challenge, Review sends that exchange to the commons' witness for
/// redaction, and Share uploads exactly what the witness gave back. Each
/// step is a press; nothing goes to the witness or the commons without its
/// own. The network steps are the helper's (`Near`, Traces.swift), on a
/// helper of their own, `sharing`; the readied message goes on the chat's.
@MainActor
@Observable
public final class TraceShare {
    /// Where sharing is.
    public enum State: Equatable {
        /// Share Traces is off: nothing about sharing runs, and every NEAR
        /// message goes as it does without it.
        case off
        /// On, reading the keychain; `stop` when it could not.
        case opening
        /// On, with no account on this Mac.
        case signedOut
        /// The NEAR AI sign-in is open in the browser, and the helper waits
        /// for it.
        case signingIn
        /// Signed in, and where the one chat being shared is.
        case signedIn(Sharing)
    }

    public enum Sharing: Equatable {
        /// No chat is readied.
        case idle
        /// The chat's next message goes without Cloak's encryption,
        /// carrying the commons' challenge, until the challenge ends.
        case readied(Readied)
        /// That message is on its way.
        case sending(Readied, turn: UUID)
        /// Its answer came back, with the exchange to review.
        case answered(Answered)
        /// The witness's answer to the review, to share or not.
        case reviewed(Answered, TraceReview)
    }

    public struct Readied: Sendable, Equatable {
        public let chat: UUID
        let binding: String
        public let expires: Date
        /// The scopes granted when it was readied, which its review and
        /// upload carry.
        let scopes: [TraceScope]
    }

    public struct Answered: Sendable, Equatable {
        public let readied: Readied
        public let turn: UUID
        public let exchange: TraceExchange
    }

    /// A step under way, for its spinner. No press waits for one.
    public enum Step: Hashable, Sendable {
        case ready, review, share, refresh, withdraw
    }

    public private(set) var state: State = .off
    /// The last step that stopped, until the next press or it is dismissed.
    public var stop: NearStop?
    private var busy: [Step: Int] = [:]
    private var record: TraceRecord?
    /// Counts each turn of the switch and each sign-in, so that a step's
    /// answer from before one changes nothing.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var saving: Task<Void, Never>?
    private let sharing: Near
    private let vault: TraceVault
    private let version: String

    /// `sharing`: a helper for sharing's steps alone, which a sign-in holds
    /// while it waits. `version`: Cloak's, which a review names.
    public init(sharing: Near, vault: TraceVault, version: String) {
        self.sharing = sharing
        self.vault = vault
        self.version = version
    }

    /// The scopes granted beyond the first, for chats readied from now on.
    public var scopes: Set<TraceScope> { record?.scopes ?? [] }

    /// The provider last signed in with; nil before the first sign-in.
    public var provider: TraceProvider? { record?.provider }

    /// The traces shared from `chat`, oldest first.
    public func shared(in chat: UUID) -> [SharedTrace] {
        record?.shared.filter { $0.chat == chat } ?? []
    }

    public func isBusy(_ step: Step) -> Bool {
        busy[step, default: 0] > 0
    }

    /// Turns sharing on, reading the keychain, or off: the sharing helper
    /// ends at once, a step under way or not, and what was readied is
    /// forgotten. On again while the keychain could not be read reads it
    /// again.
    public func turn(on: Bool) async {
        guard on else {
            guard state != .off else { return }
            epoch += 1
            sharing.stop()
            record = nil
            stop = nil
            state = .off
            return
        }
        guard state == .off || (state == .opening && stop != nil) else { return }
        epoch += 1
        let mine = epoch
        stop = nil
        state = .opening
        do {
            let record = try await vault.load().map { try JSONDecoder().decode(TraceRecord.self, from: $0) }
            guard mine == epoch else { return }
            self.record = record
            state = record == nil ? .signedOut : .signedIn(.idle)
        } catch {
            guard mine == epoch else { return }
            stop = NearStop(kind: .key, code: nil, sent: false, text: "\(error)")
        }
    }

    /// Opens the NEAR AI sign-in with `provider` in the browser, by `open`,
    /// then enrols this Mac once it finishes there. A sign-in left waiting
    /// ends first. Signing in again keeps the device key, the choices and
    /// the traces shared, and forgets what was readied.
    public func signIn(with provider: TraceProvider, route: NearRoute, open: @MainActor (URL) -> Void) async {
        guard state != .off, state != .opening else { return }
        if state == .signingIn { sharing.stop() }
        epoch += 1
        let mine = epoch
        stop = nil
        state = .signingIn
        let deviceKey = record?.deviceKey ?? TraceRecord.newDeviceKey()
        do throws(NearStop) {
            let addresses = try await sharing.listen(route: route)
            guard mine == epoch, let address = addresses[provider] else { return }
            open(address)
            let (account, session) = try await sharing.enrol(route: route, deviceKey: deviceKey)
            guard mine == epoch else { return }
            record = TraceRecord(
                deviceKey: deviceKey, account: account, session: session, provider: provider, scopes: record?.scopes ?? [],
                shared: record?.shared ?? [])
            state = .signedIn(.idle)
            keep()
        } catch {
            guard mine == epoch else { return }
            stop = error
            state = record == nil ? .signedOut : .signedIn(.idle)
        }
    }

    /// Ends the sharing helper at once, a step under way or not: at quit.
    public nonisolated func end() {
        sharing.stop()
    }

    /// Ends a sign-in left waiting.
    public func cancelSignIn() {
        guard state == .signingIn else { return }
        epoch += 1
        sharing.stop()
        state = record == nil ? .signedOut : .signedIn(.idle)
    }

    /// Grants `scope`, or no longer does, for chats readied from now on.
    /// The first is always granted.
    public func grant(_ scope: TraceScope, _ granted: Bool) {
        guard scope != .debuggingEvaluation, var record else { return }
        if granted { record.scopes.insert(scope) } else { record.scopes.remove(scope) }
        self.record = record
        keep()
    }

    /// Readies `conversation`: an upload claim, then the commons'
    /// challenge, after which its next message goes without Cloak's
    /// encryption, carrying the challenge, until the challenge ends. In
    /// place of any chat readied before. Never a chat of another mode, nor
    /// an agent's, and only while signed in.
    public func ready(_ conversation: Conversation, route: NearRoute) async {
        guard conversation.isNear, !conversation.isAgent, case .signedIn = state, let record else { return }
        let mine = epoch
        let scopes = TraceScope.granted(record.scopes)
        stop = nil
        busy[.ready, default: 0] += 1
        defer { busy[.ready, default: 1] -= 1 }
        do throws(NearStop) {
            let admission = try await sharing.ready(route: route, deviceKey: record.deviceKey, account: record.account, scopes: scopes)
            guard mine == epoch, case .signedIn = state else { return }
            state = .signedIn(.readied(Readied(chat: conversation.id, binding: admission.binding, expires: admission.expires, scopes: scopes)))
        } catch {
            guard mine == epoch else { return }
            stop = error
        }
    }

    /// Sends `turn`, in `conversation`, on the chat's helper `chat`: as
    /// `Near.ask` does, unless `conversation` is the chat readied and its
    /// challenge has not ended, when it goes as the readied message and its
    /// exchange is kept for Review. Every press is sent; only the first
    /// after readying goes readied, and one that stopped before reaching
    /// NEAR leaves the chat readied.
    public func send(
        _ turn: UUID, in conversation: Conversation, on chat: Near, route: NearRoute, proofAge: ProofFreshness, key: Near.Key
    ) async throws(NearStop) -> (text: String, proof: NearProof, tokens: Tokens?) {
        guard conversation.isNear, !conversation.isAgent, case .signedIn(.readied(let readied)) = state,
            readied.chat == conversation.id, readied.expires > .now
        else {
            return try await chat.ask(route: route, proofAge: proofAge, key: key, turn: turn, in: conversation)
        }
        let sending = State.signedIn(.sending(readied, turn: turn))
        state = sending
        do throws(NearStop) {
            let answer = try await chat.readied(
                route: route, proofAge: proofAge, key: key, turn: turn, in: conversation, admission: readied.binding)
            if state == sending {
                state = .signedIn(.answered(Answered(readied: readied, turn: turn, exchange: answer.exchange)))
            }
            return (answer.text, answer.proof, answer.tokens)
        } catch {
            if state == sending { state = .signedIn(error.sent ? .idle : .readied(readied)) }
            throw error
        }
    }

    /// The exchange answered or reviewed, if one is.
    public var answered: Answered? {
        switch state {
        case .signedIn(.answered(let answered)), .signedIn(.reviewed(let answered, _)): answered
        default: nil
        }
    }

    /// Checks the witness's enclave, and only once it passes sends it the
    /// answered exchange, for redaction; its answer is the After to share.
    /// Never while the exchange has no receipt, which no review can pass.
    public func review(route: NearRoute) async {
        guard let answered, answered.exchange.hasReceipt, let record else { return }
        let mine = epoch
        stop = nil
        busy[.review, default: 0] += 1
        defer { busy[.review, default: 1] -= 1 }
        do throws(NearStop) {
            let review = try await sharing.review(
                route: route, account: record.account, scopes: answered.readied.scopes, exchange: answered.exchange, version: version)
            guard mine == epoch, self.answered == answered else { return }
            state = .signedIn(.reviewed(answered, review))
        } catch {
            guard mine == epoch else { return }
            stop = error
        }
    }

    /// Uploads exactly the envelope the review gave back, and keeps the
    /// trace with the status the commons gave it.
    public func share(route: NearRoute) async {
        guard case .signedIn(.reviewed(let answered, let review)) = state, let record else { return }
        let mine = epoch
        stop = nil
        busy[.share, default: 0] += 1
        defer { busy[.share, default: 1] -= 1 }
        do throws(NearStop) {
            let receipt = try await sharing.upload(
                route: route, deviceKey: record.deviceKey, account: record.account, scopes: answered.readied.scopes, review: review)
            // Kept whatever has changed since the press, for the commons
            // has it.
            guard var kept = self.record else { return }
            kept.shared.removeAll { $0.submission == review.submissionId }
            kept.shared.append(
                SharedTrace(
                    chat: answered.readied.chat, turn: answered.turn, submission: review.submissionId, trace: review.traceId,
                    shared: .now, status: receipt.status, pending: receipt.pending, final: receipt.final))
            self.record = kept
            keep()
            if state == .signedIn(.reviewed(answered, review)) { state = .signedIn(.idle) }
        } catch {
            guard mine == epoch else { return }
            stop = error
        }
    }

    /// Reads the commons' status of the traces shared from `chat`, the
    /// last 100 of them.
    public func refresh(_ chat: UUID, route: NearRoute) async {
        guard case .signedIn = state, let record else { return }
        let submissions = Array(record.shared.filter { $0.chat == chat }.suffix(100).map(\.submission))
        guard !submissions.isEmpty else { return }
        let mine = epoch
        stop = nil
        busy[.refresh, default: 0] += 1
        defer { busy[.refresh, default: 1] -= 1 }
        do throws(NearStop) {
            let reports = try await sharing.status(
                route: route, deviceKey: record.deviceKey, account: record.account, submissions: submissions)
            guard mine == epoch, var kept = self.record else { return }
            for report in reports {
                guard let index = kept.shared.firstIndex(where: { $0.submission == report.submissionId }) else { continue }
                kept.shared[index].status = report.status
                kept.shared[index].pending = report.creditPointsPending
                kept.shared[index].final = report.creditPointsFinal
            }
            self.record = kept
            keep()
        } catch {
            guard mine == epoch else { return }
            stop = error
        }
    }

    /// Withdraws `trace` under the account session, keeping the session
    /// the commons renewed, if it did.
    public func withdraw(_ trace: SharedTrace, route: NearRoute) async {
        guard case .signedIn = state, let record else { return }
        let mine = epoch
        stop = nil
        busy[.withdraw, default: 0] += 1
        defer { busy[.withdraw, default: 1] -= 1 }
        do throws(NearStop) {
            let withdrawn = try await sharing.withdraw(route: route, session: record.session, submission: trace.submission)
            // Kept whatever has changed since the press, as the share is.
            guard var kept = self.record else { return }
            if let index = kept.shared.firstIndex(where: { $0.submission == trace.submission }) {
                kept.shared[index].status = "withdrawn"
                kept.shared[index].reach = withdrawn.reach
            }
            if let session = withdrawn.session { kept.session = session }
            self.record = kept
            keep()
        } catch {
            guard mine == epoch else { return }
            stop = error
        }
    }

    /// Writes the record after any write under way, so the last written is
    /// the latest.
    private func keep() {
        let previous = saving
        saving = Task {
            await previous?.value
            guard let record, let data = try? JSONEncoder().encode(record) else { return }
            do {
                try await vault.save(data)
            } catch {
                stop = NearStop(kind: .key, code: nil, sent: false, text: "\(error)")
            }
        }
    }
}
