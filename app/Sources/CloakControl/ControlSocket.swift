import Foundation
import os

/// Where the app keeps its control channel and its single-instance lock: an
/// owner-only folder in its Application Support folder.
public enum Places {
    /// True when running as the isolated local test flavor (`Cloak Dev.app`,
    /// `sh.regents.cloak.dev`), built via `app/build.sh dev`. Production
    /// (`Cloak.app`, `sh.regents.cloak`) is always false.
    public static let isDev: Bool = {
        if Bundle.main.bundleIdentifier == "sh.regents.cloak.dev" { return true }
        if ProcessInfo.processInfo.environment["CLOAK_DEV"] == "1" { return true }
        return Bundle.main.bundleURL.path.contains("/Cloak Dev.app")
    }()

    public static let support = URL.applicationSupportDirectory.appending(path: isDev ? "Regents Cloak Dev" : "Regents Cloak")
    public static let control = support.appending(path: "control")
    public static let socket = control.appending(path: "cloak.sock")
    public static let lock = control.appending(path: "app.lock")

    /// Makes `folder`, with its parents, and leaves it owner-only.
    public static func makeOwnerOnly(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
}

/// One app per user: the app holds an exclusive lock on `Places.lock` for as
/// long as it runs, and the system lets it go when the app ends, however it
/// ends.
public enum Instance {
    /// Takes the lock and keeps it until this process ends. False when
    /// another app holds it.
    public static func claim() throws(ControlError) -> Bool {
        let file = open(Places.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw .failed("cannot open \(Places.lock.path): \(String(cString: strerror(errno)))") }
        if flock(file, LOCK_EX | LOCK_NB) == 0 { return true }
        close(file)
        return false
    }
}

/// The app's end of the control channel (MAC05): a Unix socket that only its
/// owner can reach, in an owner-only folder, published whole by renaming it
/// into place. Each connection is checked for its peer's user before a byte
/// is read; any other user's, and any request that is not one line of this
/// version's JSON, is closed without an answer.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (Request) async -> Response

    static let requestLimit = 64 << 10
    static let requestTimeout = timeval(tv_sec: 5, tv_usec: 0)
    private static let logger = Logger(subsystem: "sh.regents.cloak.app", category: "control")

    private let path: URL
    private let source: any DispatchSourceRead

    /// Serves `handler` on a socket at `path` for connections from this
    /// process's user. `path`'s folder must be owner-only already.
    public init(path: URL, handler: @escaping Handler) throws(ControlError) {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw .system("socket") }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        let staging = path.deletingLastPathComponent().appending(path: "\(path.lastPathComponent).\(getpid())")
        unlink(staging.path)
        let bound = withAddress(staging.path) { bind(listener, $0, $1) } == 0
        guard bound, chmod(staging.path, 0o600) == 0, listen(listener, 16) == 0,
              rename(staging.path, path.path) == 0, fcntl(listener, F_SETFL, O_NONBLOCK) == 0
        else {
            let error = ControlError.system("cannot publish \(path.path)")
            Darwin.close(listener)
            unlink(staging.path)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "sh.regents.cloak.control"))
        source.setEventHandler { Self.acceptWaiting(listener, handler: handler) }
        source.setCancelHandler { Darwin.close(listener) }
        source.resume()
        self.path = path
        self.source = source
    }

    /// Stops serving and removes the socket.
    public func close() {
        source.cancel()
        unlink(path.path)
    }

    private static func acceptWaiting(_ listener: Int32, handler: @escaping Handler) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
                logger.error("refused a control connection from user \(uid)")
                Darwin.close(connection)
                continue
            }
            // An accepted socket inherits the listener's non-blocking flag.
            _ = fcntl(connection, F_SETFL, 0)
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var timeout = requestTimeout
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global().async {
                guard let request = readRequest(connection) else {
                    logger.error("refused a control connection that sent no valid request")
                    Darwin.close(connection)
                    return
                }
                Task {
                    let response = await handler(request)
                    var line = (try? ControlCoding.encoder().encode(response)) ?? Data()
                    line.append(0x0a)
                    writeAll(connection, line)
                    Darwin.close(connection)
                }
            }
        }
    }

    /// One line of JSON, of this version, within the limit; nil for anything
    /// else, or for nothing within the timeout.
    private static func readRequest(_ connection: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0a) {
            let n = read(connection, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0, data.count + n <= requestLimit else { return nil }
            data.append(contentsOf: buffer[..<n])
        }
        let line = data.prefix { $0 != 0x0a }
        guard data.count == line.count + 1,
              let request = try? ControlCoding.decoder().decode(Request.self, from: line),
              request.version == StatusDocument.currentVersion
        else { return nil }
        return request
    }
}

/// `cloak`'s end of the control channel.
public enum ControlClient {
    /// Sends one request and returns the app's response, once the command
    /// has settled.
    public static func send(_ request: Request) throws(ControlError) -> Response {
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw .system("socket") }
        defer { close(connection) }
        var one: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withAddress(Places.socket.path, { connect(connection, $0, $1) }) == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw .notRunning }
            throw .system("cannot reach \(Places.socket.path)")
        }
        var line = (try? ControlCoding.encoder().encode(request)) ?? Data()
        line.append(0x0a)
        guard writeAll(connection, line) else { throw .refused }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(connection, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            data.append(contentsOf: buffer[..<n])
        }
        guard !data.isEmpty else { throw .refused }
        do {
            return try ControlCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw .failed("unreadable response: \(error)")
        }
    }
}

public enum ControlError: Error, Equatable, CustomStringConvertible {
    /// No app is listening.
    case notRunning
    /// The app closed the connection without an answer.
    case refused
    case failed(String)

    static func system(_ what: String) -> ControlError {
        .failed("\(what): \(String(cString: strerror(errno)))")
    }

    public var description: String {
        switch self {
        case .notRunning: "Cloak isn't open."
        case .refused: "Cloak refused the request."
        case .failed(let detail): detail
        }
    }
}

/// False when the socket failed before all of the data was written.
@discardableResult
private func writeAll(_ socket: Int32, _ data: Data) -> Bool {
    var done = 0
    while done < data.count {
        let n = data.withUnsafeBytes { write(socket, $0.baseAddress! + done, data.count - done) }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return false }
        done += n
    }
    return true
}

/// Calls `body` with `path` as a Unix socket address; -1 when the path is
/// too long for one.
private func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
