import Foundation
import Network

/// One HTTP/1.1 request as the door reads it: one per connection, strictly,
/// within hard limits on its size and on its time.
struct HTTPRequest: Sendable {
    let method: String
    let target: String
    /// By lowercased name. Security-sensitive singletons given twice are refused;
    /// repeatable headers (such as `anthropic-beta`) are comma-joined per RFC 9110.
    let headers: [String: String]

    static let maxHead = 16 << 10
    static let maxBody = 8 << 20
    /// The whole request, head and body, must arrive within this.
    static let readLimit = Duration.seconds(30)

    /// The request target without any `?query` string (e.g. `/v1/messages?beta=true` → `/v1/messages`).
    var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    private static let singletonHeaders: Set<String> = [
        "content-length", "content-type", "host", "authorization", "x-api-key",
        "origin", "sec-fetch-site", "transfer-encoding",
    ]

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
            if let existing = headers[name] {
                guard !Self.singletonHeaders.contains(name) else {
                    throw Failure(400, "invalid_request", "The header \(name) is given twice.")
                }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        method = String(request[0])
        target = String(request[1])
        self.headers = headers
    }

    /// True when the request uses `Transfer-Encoding: chunked`.
    private var isChunked: Bool {
        headers["transfer-encoding"]?.lowercased() == "chunked"
    }

    /// The body's length, as its head gives it (for non-chunked requests).
    var length: Int {
        get throws(Failure) {
            if let te = headers["transfer-encoding"] {
                guard te.lowercased() == "chunked" else {
                    throw Failure(411, "length_required", "Send the body whole, with Content-Length or Transfer-Encoding: chunked.")
                }
                guard headers["content-length"] == nil else {
                    throw Failure(400, "invalid_request", "Do not send both Content-Length and Transfer-Encoding.")
                }
                return 0
            }
            guard let text = headers["content-length"] else {
                if method == "POST" { throw Failure(411, "length_required", "Send the body whole, with Content-Length.") }
                return 0
            }
            guard (1...9).contains(text.count), text.allSatisfy(\.isASCII), let length = Int(text), length >= 0 else {
                throw Failure(400, "invalid_request", "Content-Length did not read.")
            }
            guard length <= Self.maxBody else { throw Failure(413, "request_too_large", "The request is over 8 MiB.") }
            return length
        }
    }

    private static func isToken(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character))
    }

    /// Reads a request's head from `connection`. Returns it with the bytes
    /// read after it. Throws `Ended` when the connection ends or the task is
    /// cancelled first.
    static func head(_ connection: some Link) async throws -> (HTTPRequest, after: [UInt8]) {
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
    func body(after: [UInt8], from connection: some Link) async throws -> [UInt8] {
        let length = try self.length
        if isChunked {
            return try await chunkedBody(after: after, from: connection)
        }
        var body = after
        if body.count < length, headers["expect"]?.lowercased() == "100-continue" {
            await connection.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), final: false)
        }
        while body.count < length {
            body += try await connection.next(upTo: min(64 << 10, length - body.count))
        }
        return Array(body.prefix(length))
    }

    /// Reads an HTTP/1.1 `Transfer-Encoding: chunked` body up to `maxBody`.
    private func chunkedBody(after: [UInt8], from connection: some Link) async throws -> [UInt8] {
        let crlf: [UInt8] = [13, 10]
        var buffer = after
        var cursor = 0
        var decoded = [UInt8]()
        if headers["expect"]?.lowercased() == "100-continue" {
            await connection.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), final: false)
        }

        func ensureLine() async throws -> ArraySlice<UInt8> {
            while true {
                if let end = buffer[cursor...].firstRange(of: crlf)?.lowerBound {
                    let line = buffer[cursor..<end]
                    cursor = end + 2
                    return line
                }
                guard buffer.count - cursor <= 1024 else {
                    throw Failure(400, "invalid_request", "Chunk size line is too long.")
                }
                buffer += try await connection.next(upTo: 64 << 10)
            }
        }

        func ensureBytes(_ count: Int) async throws -> ArraySlice<UInt8> {
            while buffer.count - cursor < count {
                buffer += try await connection.next(upTo: min(64 << 10, max(1, count - (buffer.count - cursor))))
            }
            let slice = buffer[cursor..<(cursor + count)]
            cursor += count
            return slice
        }

        while true {
            let sizeLine = String(decoding: try await ensureLine(), as: UTF8.self)
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t")) ?? ""
            guard !hexPart.isEmpty, hexPart.count <= 8, let size = Int(hexPart, radix: 16), size >= 0 else {
                throw Failure(400, "invalid_request", "Chunked transfer size did not read.")
            }
            if size == 0 {
                // Consume optional trailer headers until terminating blank line.
                while !(try await ensureLine()).isEmpty {}
                return decoded
            }
            guard decoded.count + size <= Self.maxBody else {
                throw Failure(413, "request_too_large", "The request is over 8 MiB.")
            }
            decoded.append(contentsOf: try await ensureBytes(size))
            let tail = try await ensureBytes(2)
            guard tail.elementsEqual(crlf) else {
                throw Failure(400, "invalid_request", "Chunked transfer framing did not read.")
            }
            if cursor > 64 << 10 {
                buffer.removeFirst(cursor)
                cursor = 0
            }
        }
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
        405: "Method Not Allowed", 409: "Conflict", 411: "Length Required", 413: "Content Too Large",
        415: "Unsupported Media Type", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
    ]
}

/// What the door reads one request from and writes its answer to: an app's
/// connection to 127.0.0.1, or the agent's from the guest's door port.
protocol Link: Sendable {
    /// The next bytes, at most `limit`. Throws at the end of the stream, on
    /// an error, and when the task is cancelled, which cancels the link.
    func next(upTo limit: Int) async throws -> [UInt8]
    /// Returns once the other side has closed the link or it has failed, or
    /// once this side has ended it (`cancel`), dropping any bytes that come
    /// meanwhile. Cancelling the task does not end it, and leaves the link
    /// as it is.
    func ended() async
    /// Writes `data`; `final` ends this side of the stream after it.
    func write(_ data: Data, final: Bool) async
    /// Ends the link: a read under way ends, and nothing more is written.
    func cancel()
}

extension NWConnection: Link {
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

    func ended() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            @Sendable func watch() {
                receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
                    if error == nil, !complete, let data, !data.isEmpty { watch() } else { continuation.resume() }
                }
            }
            watch()
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

/// A connection from the guest's door port: the socket the guest's
/// connection came on, which it owns. It never blocks a thread: the socket
/// does not block, and a read or write that must wait waits for the socket
/// to be ready. Cancelling it, or cancelling the task of a read or write
/// under way, shuts the socket, which ends every read and write under way,
/// `ended` among them. The socket is closed once nothing holds the link.
final class GuestLink: Link {
    private let socket: Int32
    private let queue = DispatchQueue(label: "sh.regents.cloak.door.guest")

    /// Takes `socket`. Nil, having closed it, when the guest has closed its
    /// end already: a socket shut both ways takes no option, so a write to
    /// it would raise SIGPIPE.
    static func take(_ socket: Int32) -> GuestLink? {
        var on: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(socket)
            return nil
        }
        return GuestLink(socket)
    }

    private init(_ socket: Int32) {
        self.socket = socket
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        close(socket)
    }

    func next(upTo limit: Int) async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            var buffer = [UInt8](repeating: 0, count: limit)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress!, $0.count) }
                if n > 0 { return Array(buffer.prefix(n)) }
                guard n < 0, errno == EAGAIN || errno == EINTR else { throw HTTPRequest.Ended() }
                await ready(DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue))
            }
        } onCancel: {
            cancel()
        }
    }

    func ended() async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress!, $0.count) }
            if n > 0 { continue }
            guard n < 0, errno == EAGAIN || errno == EINTR else { return }
            await ready(DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue))
        }
    }

    func write(_ data: Data, final: Bool) async {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, data.count - done) }
            if n > 0 {
                done += n
                continue
            }
            guard n < 0, errno == EAGAIN || errno == EINTR else { return }
            await ready(DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue))
        }
        if final { shutdown(socket, SHUT_WR) }
    }

    func cancel() {
        shutdown(socket, SHUT_RDWR)
    }

    /// Returns once `source`'s socket can be read or written, or has ended.
    private func ready(_ source: some DispatchSourceProtocol) async {
        await withCheckedContinuation { continuation in
            source.setEventHandler { source.cancel() }
            source.setCancelHandler { continuation.resume() }
            source.resume()
        }
    }
}
