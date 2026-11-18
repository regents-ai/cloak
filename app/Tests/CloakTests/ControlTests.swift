import CloakControl
@testable import CloakSupervisor
import Foundation
import Testing

/// The control channel `cloak` uses: the versioned JSON it prints for each
/// status, and a socket that answers only its owner's well-formed requests.
@Suite(.serialized)
struct ControlTests {
    static let manifest = Manifest(
        release: "0.5.0-dev", build: "abc1234", modelMemory: 7 << 30, cloakMemory: 10 << 30,
        model: .init(name: "standin", label: "development stand-in", files: []), pins: [])

    /// Each status the supervisor produces, from the phases that produce it,
    /// with its reason and next action.
    static let expected: [(Phase, Status, Reason?, NextAction)] = [
        (.paused, .paused, nil, .start),
        (.stopping(.paused), .paused, nil, .wait),
        (.preparing(.run), .checking, nil, .wait),
        (.running, .running, nil, .pause),
        (.ready, .ready, nil, .start),
        (.needsAttention(.unsupportedHardware), .unsupportedHardware, .unsupportedHardware, NextAction.none),
        (.needsAttention(.workerStopped), .failed, .workerStopped, .start),
        (.stopping(.needsAttention(.torStopped)), .failed, .torStopped, .wait),
    ]

    @Test func everyStatusIsCoveredByTheChecksBelow() {
        #expect(Set(Self.expected.map(\.1)) == Set(Status.allCases))
    }

    @Test(arguments: 0..<expected.count)
    func theJSONForEachStatus(index: Int) throws {
        let (phase, status, reason, next) = Self.expected[index]
        let check = StatusDocument.Check(passed: true, at: Date(timeIntervalSince1970: 1_800_000_000), detail: "the check passed")
        let response = Response(refusal: nil, status: Self.manifest.status(of: phase, check: check, detail: "detail"))
        let json = try ControlCoding.encoder().encode(response)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["version", "status"])
        #expect(object["version"] as? Int == 1)
        let document = try #require(object["status"] as? [String: Any])
        var keys: Set<String> = ["version", "release", "build", "state", "status", "next_action", "model", "check", "detail"]
        if reason != nil { keys.insert("reason") }
        #expect(Set(document.keys) == keys)
        #expect(document["version"] as? Int == 1)
        #expect(document["status"] as? String == status.rawValue)
        #expect(document["state"] as? String == phase.state.rawValue)
        #expect(document["reason"] as? String == reason?.rawValue)
        #expect(document["next_action"] as? String == next.rawValue)
        #expect(document["release"] as? String == "0.5.0-dev")
        #expect(document["build"] as? String == "abc1234")
        #expect(document["model"] as? [String: String] == ["name": "standin", "label": "development stand-in"])
        let checked = try #require(document["check"] as? [String: Any])
        #expect(checked["passed"] as? Bool == true)
        #expect(checked["at"] as? String == "2027-01-15T08:00:00Z")
        // What cloak reads back is what was sent.
        #expect(try ControlCoding.decoder().decode(Response.self, from: json) == response)
    }

    @Test func theOwnerGetsAnAnswerThroughAnOwnerOnlySocket() throws {
        let place = try SocketPlace()
        defer { place.remove() }
        let response = Response(refusal: nil, status: Self.manifest.status(of: .running, check: nil, detail: ""))
        let server = try ControlServer(path: place.socket) { request in
            #expect(request == Request(.status))
            return response
        }
        defer { server.close() }
        #expect(try ControlClient.send(Request(.status), to: place.socket) == response)
        let mode = try FileManager.default.attributesOfItem(atPath: place.socket.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func anotherUsersConnectionIsClosedWithoutAnAnswer() throws {
        let place = try SocketPlace()
        defer { place.remove() }
        let response = Response(refusal: nil, status: Self.manifest.status(of: .running, check: nil, detail: ""))
        let server = try ControlServer(path: place.socket, owner: getuid() + 1) { _ in
            Issue.record("a request from another user was handled")
            return response
        }
        defer { server.close() }
        #expect(throws: ControlError.refused) { try ControlClient.send(Request(.status), to: place.socket) }
    }

    static let malformed: [String] = [
        "status\n",
        #"{"version":2,"command":"status"}"# + "\n",
        #"{"command":"status"}"# + "\n",
        #"{"version":1,"command":"rewrite"}"# + "\n",
        String(repeating: #"{"version":1,"command":"status"}"# + "\n", count: 2),
        String(repeating: "x", count: 70_000) + "\n",
    ]

    @Test(arguments: malformed)
    func aRequestThatIsNotOneLineOfThisVersionIsClosedWithoutAnAnswer(sent: String) throws {
        let place = try SocketPlace()
        defer { place.remove() }
        let response = Response(refusal: nil, status: Self.manifest.status(of: .paused, check: nil, detail: ""))
        let server = try ControlServer(path: place.socket) { _ in response }
        defer { server.close() }
        #expect(try place.exchange(Data(sent.utf8)).isEmpty)
        // The server still answers a good request.
        #expect(try ControlClient.send(Request(.status), to: place.socket) == response)
    }

    @Test func noAppListeningIsReportedAsNotRunning() throws {
        let place = try SocketPlace()
        defer { place.remove() }
        #expect(throws: ControlError.notRunning) { try ControlClient.send(Request(.status), to: place.socket) }
    }

    @Test func onlyOneAppHoldsTheLock() throws {
        let place = try SocketPlace()
        defer { place.remove() }
        #expect(try Instance.claim(place.lock))
        #expect(try !Instance.claim(place.lock))
    }
}

/// A short owner-only folder for a socket: a Unix socket path must fit in
/// 104 bytes.
struct SocketPlace {
    let folder: URL
    var socket: URL { folder.appending(path: "s.sock") }
    var lock: URL { folder.appending(path: "lock") }

    init() throws {
        folder = URL(filePath: "/tmp").appending(path: "ck-\(UUID().uuidString.prefix(8))")
        try Places.makeOwnerOnly(folder)
    }

    /// Sends raw bytes and returns everything the server sends back before
    /// it closes the connection.
    func exchange(_ data: Data) throws -> Data {
        let connection = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(connection) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socket.path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        var one: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = data.withUnsafeBytes { write(connection, $0.baseAddress!, $0.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(connection, &buffer, buffer.count)
            guard n > 0 else { break }
            received.append(contentsOf: buffer[..<n])
        }
        return received
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
