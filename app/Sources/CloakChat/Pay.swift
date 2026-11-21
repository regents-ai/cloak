import CloakHost
import Foundation

/// The limits the Mac keeps on the guest's payer (docs/zkapi-mac-side.md,
/// section 1), in one place, to be set again from step 7's measurements.
public enum PayLimit {
    /// From the payer's word that a chat request is held behind an earlier
    /// settlement: then the Mac hangs up, and nothing was sent or spent.
    public static let hold = Duration.seconds(180)
    /// From a chat request, and again from its hold's end: then the Mac
    /// hangs up, and the request may have been charged.
    public static let answer = Duration.seconds(600)
    /// For a read, a quote or a follow call.
    public static let read = Duration.seconds(60)
    /// For an approve, which signs and sends a transaction.
    public static let approve = Duration.seconds(660)
}

/// How a chat request is paid: V's through zkAPI, by the payer in the guest
/// (`PayQueue`), with a new key for each request; Token Inference's from the
/// one Tempo wallet, through the guest's sender (`Remote`), so the provider
/// can link them.
public enum Payment: Sendable, Equatable {
    case zkapi
    case tempo
}

/// What carries one frame to the payer and gives its frames back: in the
/// app, `Supervisor.pay`. It fails when there is no payer to reach.
public typealias PayLine = @Sendable (Pay.Ask, Data) async throws -> AsyncThrowingStream<Pay.Event, any Error>

/// The payloads of the payer's frames, exactly as docs/zkapi-mac-side.md,
/// section 1, writes them: every one a JSON object, every request body a
/// JSON text in a string. Nothing else is in a frame: no key, no wallet
/// secret, no message of the daemon's.
public enum PayFrame {
    /// `R`, host to guest: a chat request in OpenAI's shape, every user
    /// message already reworded on the Mac, and its conversation's Tor
    /// identity, 64 hex characters.
    public struct Request: Codable, Sendable, Equatable {
        public let identity: String
        public let body: String
    }

    /// `C`, host to guest: one of the payer's money routes, called in the
    /// guest; `body` is the route's JSON body, or "" for none.
    public struct Call: Codable, Sendable, Equatable {
        public let method: String
        public let path: String
        public let body: String
    }

    /// `V`, host to guest: a read of the deposit, and with `chain` of the
    /// chain at one block.
    public struct View: Codable, Sendable, Equatable {
        public let chain: Bool
    }

    /// `H`, guest to host: true once, when the hold first finds an earlier
    /// settlement unfinished; false once, when that hold ends, just before
    /// the request's key is asked for. No `H` comes for a request that was
    /// not held.
    public struct Held: Codable, Sendable, Equatable {
        public let held: Bool
    }

    /// `A`, guest to host: the HTTP status and the body the route gave.
    public struct Answer: Codable, Sendable, Equatable {
        public let status: Int
        public let body: String
    }
}

/// Why a request to the payer ended without what it asked for. The Mac
/// shows its own words for each code, never the daemon's message, and logs
/// the detail.
public struct PayStop: Error, Sendable, Equatable {
    public enum Code: String, Sendable {
        /// No payer could be reached; nothing was sent.
        case unreachable
        /// There is no deposit to pay from (402 `funding_required`).
        case noDeposit
        /// A withdrawal is under way (409 `withdrawal_pending`).
        case withdrawing
        /// The wallet is busy with another request (429 `busy`, 409
        /// `wallet_conflict`).
        case busy
        /// The service can't take this model now (`invalid_model`,
        /// `model_budget_unavailable`, `model_policy_unavailable`), or there
        /// is no model to send to.
        case modelUnavailable
        /// The way to the service through Tor failed
        /// (`anonymous_access_failed`).
        case torDown
        /// The request was turned away as it was (`invalid_request_error`,
        /// `invalid_body`, `invalid_frame`).
        case refused
        /// The provider failed or gave what does not read (`upstream_error`,
        /// `invalid_upstream_response`, `stream_unavailable`).
        case providerFailed
        /// The provider's answer had no text.
        case answerRefused
        /// The hold ran past `PayLimit.hold`; nothing was sent or spent.
        case heldTooLong
        /// No answer within the limit after the hold, or for a call; the
        /// request may have been charged, or the call carried out.
        case timedOut
        /// The connection ended before the answer; the request may have
        /// been charged.
        case ended
        /// Its owner stopped it, or Cloak did (408 `request_cancelled`).
        case cancelled
        /// Anything else: a money route refused, or an answer that does not
        /// read.
        case failed
    }

    public let code: Code
    public let detail: String

    public init(_ code: Code, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    /// The stop for a chat request answered with something other than 200,
    /// by the error's code in OpenAI's shape.
    init(status: Int, body: String) {
        struct Wrapped: Decodable {
            let error: Inner
            struct Inner: Decodable { let code: String? }
        }
        let code = (try? JSONDecoder().decode(Wrapped.self, from: Data(body.utf8)))?.error.code ?? ""
        let mapped: Code =
            switch code {
            case "funding_required": .noDeposit
            case "withdrawal_pending": .withdrawing
            case "busy", "wallet_conflict": .busy
            case "invalid_model", "model_budget_unavailable", "model_policy_unavailable": .modelUnavailable
            case "anonymous_access_failed": .torDown
            case "invalid_request_error", "invalid_body", "invalid_frame": .refused
            case "upstream_error", "invalid_upstream_response", "stream_unavailable": .providerFailed
            case "request_cancelled": .cancelled
            default: .failed
            }
        self.init(mapped, "status \(status), code \(code.isEmpty ? "none" : code)")
    }
}

/// The deposit as the payer's wallet and, when asked, the chain at one
/// block show it: the answer to `V`. `wallet` is the companion's own
/// `/wallet/status`; `chain` is read at one block, the latest when read.
public struct DepositView: Decodable, Sendable, Equatable {
    public let wallet: Wallet
    public let chain: Chain?

    public struct Wallet: Decodable, Sendable, Equatable {
        public let hasNote: Bool
        public let pendingRequest: Bool
        public let note: Note?

        public struct Note: Decodable, Sendable, Equatable {
            public let noteId: UInt32
            /// When anyone may send it to the service's operator, in seconds
            /// since 1970.
            public let expiryTs: UInt64
        }
    }

    public struct Chain: Decodable, Sendable, Equatable {
        public let block: UInt64
        /// The block's time, in seconds since 1970.
        public let time: UInt64
        /// The vault's `paused()`.
        public let paused: Bool
        /// The funding address's ETH, in wei.
        public let balanceWei: String
        /// The vault's record of the wallet's note; nil without one.
        public let note: Note?

        public struct Note: Decodable, Sendable, Equatable {
            /// "uninitialized", "active", "pending_withdrawal" or "closed".
            public let status: String
            public let expiryTs: UInt64
        }
    }
}

/// `GET /admin/funding/address`, and the answers of a deposit's approve and
/// follow call: the payer's Ethereum address and where its deposit is. Its
/// amounts of the asset are in gwei (`token_decimals` 9 for ETH).
public struct FundingStatus: Decodable, Sendable, Equatable {
    public let address: String
    public let chainId: UInt64
    /// In wei.
    public let ethBalance: String
    /// The saved deposit, in gwei; absent when none is saved.
    public let amount: UInt64?
    public let phase: String
    public let depositStage: String?
    public let transactionHash: String?
}

/// `GET /admin/withdrawal`, and the answers of a withdrawal's approve and
/// follow call: the deposit's balance and where its withdrawal is.
public struct WithdrawalStatus: Decodable, Sendable, Equatable {
    /// In wei.
    public let ethBalance: String
    /// What the deposit holds now, in gwei.
    public let privateBalance: UInt64
    public let destination: String?
    public let noteId: UInt64?
    public let phase: String
    public let transactionHash: String?
}

/// `GET /admin/return`, and the answers of Send Out's approve and follow
/// call: the funding address's ETH and where a send of it is.
public struct ReturnStatus: Decodable, Sendable, Equatable {
    /// In wei.
    public let ethBalance: String
    public let phase: String
    public let destination: String?
    public let transactionHash: String?
}

/// A quote the payer made for a deposit, a withdrawal or a send: what it
/// would sign, if approved within 30 seconds. Its wei amounts are decimal
/// strings; its `amount` is in gwei.
public struct PayQuote: Decodable, Sendable, Equatable {
    /// The dollars asked for, for a deposit quoted from dollars.
    public let inputMicroUsd: UInt64?
    public let id: String
    public let kind: String
    public let amount: UInt64
    public let destination: String?
    public let noteId: UInt64?
    public let principalWei: String
    public let requiredFeeWei: String
    public let requiredTotalWei: String
    public let shortfallWei: String
    /// In milliseconds since 1970, as the payer counts it.
    public let expiresAt: Int64

    /// When the payer stops taking an approve of it.
    public var expires: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }

    /// Expired now: the payer refuses an approve of it, so it is quoted
    /// again rather than approved unseen.
    public func expired(at now: Date) -> Bool { expires <= now }
}

/// One model in the service's list, as the payer reads it: its name, and
/// the most one request to it may cost, in millionths of a dollar.
public struct PayModel: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let cap: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case cap = "oaRequestLimitMicroUsd"
    }
}

extension JSONDecoder {
    /// The payer's answers, whose keys are snake case.
    static let pay: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
