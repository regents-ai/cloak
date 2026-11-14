import Foundation
import Network

/// One HTTP/1.1 request as the door reads it: one per connection, strictly,
/// within hard limits on its size and on its time.
struct HTTPRequest: Sendable {
    let method: String
    let target: String
    /// By lowercased name. A name given twice is refused.
    let headers: [String: String]

    static let maxHead = 16 << 10
    static let maxBody = 4 << 20
    /// The whole request, head and body, must arrive within this.
    static let readLimit = Duration.seconds(30)

    /// The head, without its blank line: a request line, then header lines,
    /// each ending in CRLF.
    init(head: ArraySlice<UInt8>) throws(Failure) {
        let lines = head.split(separator: Array("\r\n".utf8), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, !request[0].isEmpty, request[0].allSatisfy(\.isUppercase), request[1].hasPrefix("/") else {
            throw Failure(400, "invalid_request", "The request line did not read.")
        }
        guard request[2] == "HTTP/1.1" else { throw Failure(505, "http_version_not_supported", "Use HTTP/1.1.") }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line[..<colon].isEmpty, line[..<colon].allSatisfy(Self.isToken),
                !line.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F })
            else { throw Failure(400, "invalid_request", "A header line did not read.") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard headers.updateValue(value, forKey: name) == nil else {
                throw Failure(400, "invalid_request", "The header \(name) is given twice.")
            }
        }
        method = String(request[0])
        target = String(request[1])
        self.headers = headers
    }

    /// The body's length, as its head gives it.
    var length: Int {
        get throws(Failure) {
            guard headers["transfer-encoding"] == nil else {
                throw Failure(411, "length_required", "Send the body whole, with Content-Length.")
            }
            guard let text = headers["content-length"] else {
                if method == "POST" { throw Failure(411, "length_required", "Send the body whole, with Content-Length.") }
                return 0
            }
            guard (1...9).contains(text.count), text.allSatisfy(\.isASCII), let length = Int(text), length >= 0 else {
                throw Failure(400, "invalid_request", "Content-Length did not read.")
            }
            guard length <= Self.maxBody else { throw Failure(413, "request_too_large", "The request is over 4 MiB.") }
            return length
        }
    }

    private static func isToken(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character))
    }

    /// Reads a request's head from `connection`. Returns it with the bytes
    /// read after it. Throws `Ended` when the connection ends or the task is
    /// cancelled first.
    static func head(_ connection: NWConnection) async throws -> (HTTPRequest, after: [UInt8]) {
        var buffer = [UInt8]()
        var end: Int?
        while end == nil {
            guard buffer.count <= maxHead else { throw Failure(431, "request_header_fields_too_large", "The request's head is over 16 KiB.") }
            let from = max(0, buffer.count - 3)
            buffer += try await connection.next(upTo: 64 << 10)
            end = buffer[from...].firstRange(of: Array("\r\n\r\n".utf8))?.lowerBound
        }
        guard end! <= maxHead else { throw Failure(431, "request_header_fields_too_large", "The request's head is over 16 KiB.") }
        return (try HTTPRequest(head: buffer[..<end!]), Array(buffer[(end! + 4)...]))
    }

    /// Reads the rest of the body from `connection`, after the bytes `after`
    /// read with the head; bytes past it are not taken.
    func body(after: [UInt8], from connection: NWConnection) async throws -> [UInt8] {
        let length = try self.length
        var body = after
        if body.count < length, headers["expect"]?.lowercased() == "100-continue" {
            await connection.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), final: false)
        }
        while body.count < length {
            body += try await connection.next(upTo: min(64 << 10, length - body.count))
        }
        return Array(body.prefix(length))
    }

    /// The connection ended before a whole request.
    struct Ended: Error {}
}

/// One answer, written whole, after which the connection closes.
struct HTTPResponse: Sendable {
    let status: Int
    var type = "application/json"
    var headers: [(String, String)] = []
    let body: Data

    var bytes: Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        for (name, value) in [("Content-Type", type), ("Content-Length", "\(body.count)"), ("Cache-Control", "no-store"),
                              ("X-Content-Type-Options", "nosniff"), ("Connection", "close")] + headers {
            head += "\(name): \(value)\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }

    private static let reasons = [
        200: "OK", 400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
        431: "Request Header Fields Too Large", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        505: "HTTP Version Not Supported",
    ]
}

extension NWConnection {
    /// The next bytes, at most `limit`. Throws at the end of the stream, on
    /// an error, and when the task is cancelled, which cancels the
    /// connection.
    func next(upTo limit: Int) async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receive(minimumIncompleteLength: 1, maximumLength: limit) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: [UInt8](data))
                    } else {
                        continuation.resume(throwing: HTTPRequest.Ended())
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Writes `data`; `final` ends this side of the stream after it.
    func write(_ data: Data, final: Bool) async {
        await withCheckedContinuation { continuation in
            send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                 completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
