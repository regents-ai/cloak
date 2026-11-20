import CloakChat
import CloakSupervisor
import Foundation

/// A request the door ends without the provider's answer, in OpenAI's error
/// shape, as the pinned daemon writes its own (`writeError` in
/// reference/src/zkapi/zkapi-clientd/internal/server/server.go): a plain
/// message, its code as both type and code, and the status that fits.
struct Failure: Error, Sendable, Equatable {
    let status: Int
    let code: String
    let message: String

    init(_ status: Int, _ code: String, _ message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    var response: HTTPResponse {
        let error = #"{"error":{"message":"# + Rewrite.quote(message) + #","type":"# + Rewrite.quote(code) + #","code":"#
            + Rewrite.quote(code) + #","param":null}}"#
        return HTTPResponse(status: status, headers: status == 401 ? [("WWW-Authenticate", "Bearer")] : [], body: Data(error.utf8))
    }

    static let pass = Failure(401, "invalid_api_key", "Use the pass Cloak showed when this app was added, as Authorization: Bearer and the pass.")
    static let origin = Failure(403, "browser_origin_denied", "Cloak does not answer web pages. Connect from an app on this Mac.")
    static let stopped = Failure(503, "cloak_stopped", "Cloak was paused or stopped. Start it, then try again.")

    static func invalid(_ message: String) -> Failure {
        Failure(400, "invalid_request_error", message)
    }

    /// The daemon's own words for a message over decision 6's cap
    /// (`InputTooLongError` in guest/daemon/rewriter.patch).
    static func tooLong(_ characters: Int) -> Failure {
        Failure(413, "input_too_long", "This message is \(characters.formatted(.number.locale(Locale(identifier: "en_US")))) characters long, over the limit of 10,000 characters. Shorten it and try again.")
    }

    init(_ stop: RewriteStop) {
        switch stop {
        case .tooLong(let characters): self = .tooLong(characters)
        case .timedOut: self.init(504, "rewrite_timed_out", "Rewording on this Mac took too long, so nothing was sent.")
        case .refused: self.init(502, "rewrite_failed", "Rewording on this Mac gave no usable text, so nothing was sent.")
        case .cancelled, .stopped: self = .stopped
        }
    }

    init(_ stop: RemoteStop) {
        switch stop.code {
        case .noFunds: self.init(402, "insufficient_funds", "The wallet has no funds for this request. Add USDC.e on Tempo in Chat, under Wallet.")
        case .walletRefused: self.init(402, "wallet_refused", "The provider turned the wallet away.")
        case .modelUnavailable: self.init(404, "model_not_found", "The provider can't use this model now. Pick another.")
        case .torDown: self.init(503, "tor_down", "Cloak couldn't reach the provider through Tor. Try again.")
        case .answerRefused, .failed: self.init(502, "failed", "The request did not go through. Try again.")
        case .unreachable: self = .stopped
        }
    }

    init(_ stop: PayStop) {
        switch stop.code {
        case .noDeposit: self.init(402, "no_deposit", "V has no deposit to pay for this request. Make one in Chat, under Wallet.")
        case .withdrawing: self.init(409, "withdrawal_pending", "V's deposit is being withdrawn, so it can't pay for requests now.")
        case .busy: self.init(429, "busy", "V's wallet is busy with another request. Try again.")
        case .modelUnavailable: self.init(404, "model_not_found", "The provider can't use this model now. Pick another.")
        case .torDown: self.init(503, "tor_down", "Cloak couldn't reach the provider through Tor. Try again.")
        case .refused: self.init(400, "invalid_request_error", "The provider turned the request away as it was.")
        case .providerFailed, .answerRefused, .failed: self.init(502, "failed", "The request did not go through. Try again.")
        case .heldTooLong: self.init(504, "settling", "The last request is still settling, so nothing was sent. Try again in a minute.")
        case .timedOut, .ended: self.init(504, "timed_out", "No answer came in time. The request may have been paid for.")
        case .unreachable: self.init(503, "wallet_unreachable", "Cloak couldn't reach V's wallet. Pause and start Cloak, then try again.")
        case .cancelled: self = .stopped
        }
    }
}
