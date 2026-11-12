import Foundation

/// The host end of the guest's Tor port (guest/torport), the guest's one way
/// out. Each guest connection must open with a SOCKS5 greeting (RFC 1928)
/// that offers only no authentication or a user name and password (RFC
/// 1929), which is what torsocks and the daemon send; anything else is
/// closed without a byte. The greeting and everything after it go to tor's
/// SOCKS port, and tor's answers come back, until either end closes. The
/// relay takes no address from the guest: its one destination is tor, and
/// once tor has stopped, nothing (`Tor.connect`).
final class TorRelay: Sendable {
    static let port: UInt32 = 9050
    /// How long a connection may take to send its greeting.
    static let greetingTimeout = timeval(tv_sec: 10, tv_usec: 0)

    private let tor: Tor

    init(tor: Tor) {
        self.tor = tor
    }

    /// Takes ownership of the socket. Each connection has a thread of its
    /// own, as streams through Tor run side by side and for as long as they
    /// last.
    func accept(_ guest: Int32) {
        Thread { [self] in
            serve(guest)
            close(guest)
        }.start()
    }

    private func serve(_ guest: Int32) {
        var timeout = Self.greetingTimeout
        setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let greeting = Self.greeting(guest) else {
            log("refused a Tor port connection that did not open with a SOCKS5 greeting")
            return
        }
        var unlimited = timeval()
        setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &unlimited, socklen_t(MemoryLayout<timeval>.size))
        guard let socks = tor.connect(guest) else { return }
        defer {
            tor.disconnect(guest)
            close(socks)
        }
        guard Relay.write(socks, greeting) else { return }
        // Each direction copies until its source ends or its destination
        // fails, then shuts both sockets, which ends the other direction too.
        let answered = DispatchSemaphore(value: 0)
        Thread {
            Self.copy(from: socks, to: guest)
            Self.end(guest, socks)
            answered.signal()
        }.start()
        Self.copy(from: guest, to: socks)
        Self.end(guest, socks)
        answered.wait()
    }

    /// Version 5, the number of methods, then the methods, each 0 (no
    /// authentication) or 2 (user name and password); nil for anything else.
    private static func greeting(_ socket: Int32) -> Data? {
        guard let head = Relay.read(socket, 2), head[0] == 5, head[1] > 0,
              let methods = Relay.read(socket, Int(head[1])), methods.allSatisfy({ $0 == 0 || $0 == 2 })
        else { return nil }
        return head + methods
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = Data(count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0, Relay.write(destination, buffer.prefix(n)) else { return }
        }
    }

    private static func end(_ a: Int32, _ b: Int32) {
        shutdown(a, SHUT_RDWR)
        shutdown(b, SHUT_RDWR)
    }
}
