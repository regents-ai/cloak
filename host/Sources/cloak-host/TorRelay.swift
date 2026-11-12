import Foundation

/// The host end of the guest's Tor port (guest/torport), the guest's one way
/// out. Each guest connection must open with a SOCKS5 greeting (RFC 1928)
/// that offers only no authentication or a user name and password (RFC
/// 1929), which is what torsocks and the daemon send; anything else is
/// closed without a byte. The greeting and everything after it go to tor's
/// SOCKS port, and tor's answers come back, until either end closes. The
/// relay takes no address from the guest: its one destination is tor.
final class TorRelay: Sendable {
    static let port: UInt32 = 9050
    /// How long a connection may take to send its greeting.
    static let greetingTimeout = timeval(tv_sec: 10, tv_usec: 0)

    /// tor's SOCKS port on 127.0.0.1.
    private let socks: UInt16

    init(socks: UInt16) {
        self.socks = socks
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
        guard let tor = connectTor() else { return }
        defer { close(tor) }
        guard Relay.write(tor, greeting) else { return }
        // Each direction copies until its source ends or its destination
        // fails, then shuts both sockets, which ends the other direction too.
        let answered = DispatchSemaphore(value: 0)
        Thread {
            Self.copy(from: tor, to: guest)
            Self.end(guest, tor)
            answered.signal()
        }.start()
        Self.copy(from: guest, to: tor)
        Self.end(guest, tor)
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

    private func connectTor() -> Int32? {
        let tor = socket(AF_INET, SOCK_STREAM, 0)
        guard tor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = socks.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(tor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            log("cannot reach tor (\(String(cString: strerror(errno)))); closed a Tor port connection without an answer")
            close(tor)
            return nil
        }
        return tor
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
