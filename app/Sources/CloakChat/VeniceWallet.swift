import Foundation

// The wallet route: Venice credit bought with USDC on Base and spent by a
// wallet's signed sign-in, with no Venice account (x402,
// docs.venice.ai/guides/integrations/x402-venice-api). The messages are built
// byte for byte as Venice's guide builds them; signing them is the signer's,
// which holds the key (docs/venice.md, "Wallet").

/// Signs for one wallet on Base. The key stays with the signer.
public struct VeniceSigner: Sendable {
    /// The wallet's address: 0x and forty hex digits, in EIP-55's mixed case.
    public let address: String
    /// An EIP-191 personal signature of the message's UTF-8 bytes, in hex
    /// with 0x.
    public let personal: @Sendable (_ message: String) async throws -> String
    /// An EIP-712 signature of the typed data, as eth_signTypedData_v4 takes
    /// it, in hex with 0x.
    public let typed: @Sendable (_ typedData: Data) async throws -> String

    public init(
        address: String, personal: @escaping @Sendable (_ message: String) async throws -> String,
        typed: @escaping @Sendable (_ typedData: Data) async throws -> String
    ) {
        self.address = address
        self.personal = personal
        self.typed = typed
    }
}

/// Venice's terms for a top-up: the Base USDC entry of its `402` answer to
/// `POST /x402/top-up`.
public struct VeniceTopUpTerms: Sendable, Equatable {
    /// Where the USDC goes, as Venice gave it.
    public let payTo: String
    /// The least a top-up takes.
    public let least: Amount
    /// How long a signed payment stays good, in seconds.
    public let timeout: Int
    /// USDC's EIP-712 domain name and version, as Venice gave them.
    let name: String
    let version: String
}

/// A top-up Venice took.
public struct VeniceTopUp: Sendable, Equatable {
    /// US dollars of credit added.
    public let credited: Decimal
    /// The wallet's credit now, in US dollars.
    public let balance: Decimal
}

/// One USDC transfer a top-up signs for (EIP-3009's
/// TransferWithAuthorization), with its times in seconds since 1970.
struct VeniceTransfer: Sendable, Equatable {
    let from: String
    let to: String
    let value: Amount
    let validAfter: Int
    let validBefore: Int
    /// Thirty-two bytes in hex with 0x.
    let nonce: String
}

enum VeniceWallet {
    static let domain = "api.venice.ai"
    static let statement = "Sign in to Venice AI"
    /// Base's USDC: the one asset a top-up is paid in.
    static let usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    /// The EIP-4361 message a sign-in signs, as Venice rebuilds it from the
    /// header's fields.
    static func message(address: String, uri: String, nonce: String, issued: String, expires: String) -> String {
        """
        \(domain) wants you to sign in with your Ethereum account:
        \(address)

        \(statement)

        URI: \(uri)
        Version: 1
        Chain ID: 8453
        Nonce: \(nonce)
        Issued At: \(issued)
        Expiration Time: \(expires)
        """
    }

    /// The `SIGN-IN-WITH-X` header for a signed message: its fields and the
    /// signature, as one JSON object in base64.
    static func header(address: String, uri: String, nonce: String, issued: String, expires: String, signature: String) -> String {
        let fields: JSON = .object([
            ("domain", .text(domain)), ("address", .text(address)), ("statement", .text(statement)), ("uri", .text(uri)),
            ("version", .text("1")), ("nonce", .text(nonce)), ("issuedAt", .text(issued)), ("expirationTime", .text(expires)),
            ("chainId", .text("eip155:8453")), ("type", .text("eip191")), ("signature", .text(signature)),
        ])
        return Data(fields.encoded.utf8).base64EncodedString()
    }

    /// A sign-in for one request to `url`, signed at `now` and good for five
    /// minutes. Venice takes each nonce once.
    static func signIn(for url: URL, signer: VeniceSigner, now: Date, nonce: String) async throws(VeniceStop) -> String {
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let issued = time.format(now)
        let expires = time.format(now.addingTimeInterval(300))
        let uri = url.absoluteString
        let signature: String
        do {
            signature = try await signer.personal(message(address: signer.address, uri: uri, nonce: nonce, issued: issued, expires: expires))
        } catch {
            throw VeniceStop(.signing, sent: false, "the signer did not sign the sign-in")
        }
        return header(address: signer.address, uri: uri, nonce: nonce, issued: issued, expires: expires, signature: signature)
    }

    /// The typed data a top-up's transfer signs, as eth_signTypedData_v4
    /// takes it.
    static func authorization(_ transfer: VeniceTransfer, terms: VeniceTopUpTerms) -> Data {
        func field(_ name: String, _ type: String) -> JSON { .object([("name", .text(name)), ("type", .text(type))]) }
        let data: JSON = .object([
            (
                "types",
                .object([
                    (
                        "EIP712Domain",
                        .list([field("name", "string"), field("version", "string"), field("chainId", "uint256"), field("verifyingContract", "address")])
                    ),
                    (
                        "TransferWithAuthorization",
                        .list([
                            field("from", "address"), field("to", "address"), field("value", "uint256"), field("validAfter", "uint256"),
                            field("validBefore", "uint256"), field("nonce", "bytes32"),
                        ])
                    ),
                ])
            ),
            ("primaryType", .text("TransferWithAuthorization")),
            (
                "domain",
                .object([("name", .text(terms.name)), ("version", .text(terms.version)), ("chainId", .number(8453)), ("verifyingContract", .text(usdc))])
            ),
            ("message", transfer.fields),
        ])
        return Data(data.encoded.utf8)
    }

    /// The `PAYMENT-SIGNATURE` header for a signed transfer, as the payment
    /// Venice's guide builds (x402 1.2.1's `createPaymentHeader` with
    /// version 2), in base64.
    static func payment(_ transfer: VeniceTransfer, signature: String) -> String {
        let payment: JSON = .object([
            ("x402Version", .number(2)), ("scheme", .text("exact")), ("network", .text("base")),
            ("payload", .object([("signature", .text(signature)), ("authorization", transfer.fields)])),
        ])
        return Data(payment.encoded.utf8).base64EncodedString()
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension VeniceTransfer {
    fileprivate var fields: JSON {
        .object([
            ("from", .text(from)), ("to", .text(to)), ("value", .text(String(value.units))), ("validAfter", .text(String(validAfter))),
            ("validBefore", .text(String(validBefore))), ("nonce", .text(nonce)),
        ])
    }
}

extension Venice {
    /// Venice's terms for a top-up: `POST /x402/top-up` with nothing, which
    /// Venice answers with `402` and its terms. Costs nothing.
    public func topUpTerms() async throws(VeniceStop) -> VeniceTopUpTerms {
        let request = VeniceRequest(method: "POST", url: URL(string: Self.base + "x402/top-up")!, headers: [:], body: nil)
        let response = try await Self.carry(request, transport)
        let body = try await Self.whole(response)
        guard response.status == 402 else { throw VeniceStop.answered(response.status, body, auth: nil) }
        struct Entry: Decodable {
            let amount: Amount
            let payTo: String
            let maxTimeoutSeconds: Int
            let extra: Extra

            struct Extra: Decodable {
                let name: String
                let version: String
            }
        }
        guard let challenge = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let accepts = challenge["accepts"] as? [[String: Any]],
            let base = accepts.first(where: {
                $0["scheme"] as? String == "exact" && $0["network"] as? String == "eip155:8453"
                    && ($0["asset"] as? String)?.lowercased() == VeniceWallet.usdc.lowercased()
            }),
            let entry = try? JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: base))
        else { throw VeniceStop(.failed, sent: true, "Venice's terms name no Base USDC top-up that reads") }
        return VeniceTopUpTerms(
            payTo: entry.payTo, least: entry.amount, timeout: entry.maxTimeoutSeconds, name: entry.extra.name, version: entry.extra.version)
    }

    /// Buys `amount` of Venice credit for `signer`'s wallet on `terms`: signs
    /// a USDC transfer of exactly `amount` to Venice, which Venice settles
    /// on Base when it takes it.
    public func topUp(_ amount: Amount, on terms: VeniceTopUpTerms, by signer: VeniceSigner) async throws(VeniceStop) -> VeniceTopUp {
        let now = Int(self.now().timeIntervalSince1970)
        let transfer = VeniceTransfer(
            from: signer.address, to: terms.payTo, value: amount, validAfter: now - 600, validBefore: now + terms.timeout,
            nonce: "0x" + VeniceWallet.hex(random(32)))
        let signature: String
        do {
            signature = try await signer.typed(VeniceWallet.authorization(transfer, terms: terms))
        } catch {
            throw VeniceStop(.signing, sent: false, "the signer did not sign the payment")
        }
        let request = VeniceRequest(
            method: "POST", url: URL(string: Self.base + "x402/top-up")!,
            headers: ["payment-signature": VeniceWallet.payment(transfer, signature: signature)], body: nil)
        let response = try await Self.carry(request, transport)
        let body = try await Self.whole(response)
        guard response.status == 200 else {
            guard [400, 401, 402].contains(response.status) else { throw VeniceStop.answered(response.status, body, auth: nil) }
            throw VeniceStop(.paymentRefused, sent: true, "status \(response.status) to the top-up")
        }
        struct Taken: Decodable {
            let data: Credit

            struct Credit: Decodable {
                let amountCredited: Decimal
                let newBalance: Decimal
            }
        }
        guard let credit = try? JSONDecoder().decode(Taken.self, from: body).data else {
            throw VeniceStop(.failed, sent: true, "the top-up's answer did not read")
        }
        return VeniceTopUp(credited: credit.amountCredited, balance: credit.newBalance)
    }
}

/// A JSON value written with its fields in the order given and its text
/// escaped as JavaScript's JSON.stringify escapes it, so that a message
/// matches Venice's examples byte for byte.
indirect enum JSON {
    case text(String)
    case number(Int)
    case list([JSON])
    case object([(String, JSON)])

    var encoded: String {
        switch self {
        case .text(let text): Self.quoted(text)
        case .number(let number): String(number)
        case .list(let items): "[" + items.map(\.encoded).joined(separator: ",") + "]"
        case .object(let fields): "{" + fields.map { Self.quoted($0.0) + ":" + $0.1.encoded }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
