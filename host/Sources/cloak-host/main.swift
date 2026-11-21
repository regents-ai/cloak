import CloakHost
import Foundation

// cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl>
//            --worker <cloak-rewriter-llama> --name <model> --dir <model directory>
//            --tor <tor> --tor-data <tor's folder>
//            [--disk <image> --disk-key <key file> [--new-disk]]
//            [--serve [--door <socket file>] [--runner <socket file>] [--pay <socket file>]]
//
// Starts the native worker and tor, waits for tor to open its SOCKS port and
// bootstrap (at most 90 seconds from its start; this process fails if the
// port has not opened by then), boots the guest with a fresh channel token
// and rewriter key, relays the guest's rewrite requests to the worker one at
// a time and its Tor port to tor, starts a new worker after a lost one, and
// exits when the guest powers off, after stopping both. The guest's console
// is this process's standard output. The guest's cover traffic follows the
// cover list in the root given (/etc/cloak/cover.json): this command never
// lays an empty one over it, as the app does when its owner turns Cover off.
//
// With --disk the guest has its payment disk: the image file given, which
// must exist, encrypted under the 32 bytes in the key file given; with
// --new-disk the image is blank and the guest makes the disk in it. The guest
// ends at once when the disk does not open, saying why on its console.
//
// With --serve the guest runs the sender after its checks (Token Inference,
// decisions 10 and 25 in docs/plan.md) and its console goes to standard error: each
// line read from standard input is one request to the sender, and its answer
// is one line on standard output, after a line {"keep": <deposit>} for each
// deposit change the sender reports, which this kit does not keep. The guest
// is stopped once standard input ends.
//
// With --door, each guest connection to the door port is carried, byte for
// byte, to the socket file given, where a check's stand-in for the app's
// door listens. With --runner, this process listens on the socket file given
// for agent tasks for the guest's runner, one per connection: the client
// writes one line, the request as JSON ({"task", "session", "model",
// "pass"}), and reads one JSON line per event, {"output": <line>},
// {"error": <line>} or, last, {"exited": {"status", "signalled"}}, or else
// one last {"failed": <why>}. The client's end of the connection ends the
// task.
//
// With --pay, which needs --disk, this process listens on the socket file
// given for exchanges with the guest's payer (docs/zkapi-mac-side.md,
// section 1), one per connection: the client writes one line,
// {"frame": "R", "C" or "V", "payload": <the frame's JSON>}, and reads one
// line per frame back: each H frame's payload as sent, then, last,
// {"answer": <the A frame's payload>}, or else one last {"failed": <why>}.
// The client's end of the connection cancels the exchange.

let usage = "usage: cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl> --worker <cloak-rewriter-llama> --name <model> --dir <model directory> --tor <tor> --tor-data <tor's folder> [--disk <image> --disk-key <key file> [--new-disk]] [--serve [--door <socket file>] [--runner <socket file>] [--pay <socket file>]]"
let flags = ["--kernel", "--initrd", "--cases", "--worker", "--name", "--dir", "--tor", "--tor-data"]
let diskFlags = ["--disk", "--disk-key"]
let servingFlags = ["--door", "--runner", "--pay"]
let (arguments, serving, newDisk) = {
    var parsed = [String: String]()
    var serve = false, newDisk = false
    var rest = CommandLine.arguments.dropFirst()
    while let flag = rest.popFirst() {
        if flag == "--serve", !serve {
            serve = true
            continue
        }
        if flag == "--new-disk", !newDisk {
            newDisk = true
            continue
        }
        guard (flags + diskFlags + servingFlags).contains(flag), parsed[flag] == nil, let value = rest.popFirst() else { fail(usage) }
        parsed[flag] = value
    }
    let disk = diskFlags.allSatisfy { parsed[$0] != nil }
    guard flags.allSatisfy({ parsed[$0] != nil }), serve || servingFlags.allSatisfy({ parsed[$0] == nil }),
          disk || (diskFlags.allSatisfy({ parsed[$0] == nil }) && !newDisk && parsed["--pay"] == nil) else { fail(usage) }
    return (parsed, serve, newDisk)
}()
func path(_ flag: String) -> URL { URL(filePath: arguments[flag]!) }

func fail(_ message: String) -> Never {
    log(message)
    exit(2)
}

// A write to a worker or guest connection that has gone fails, and is handled
// as that loss, instead of ending the host.
signal(SIGPIPE, SIG_IGN)

// The worker, started the same way again after a loss.
let worker = path("--worker"), workerArguments = ["--name", arguments["--name"]!, "--dir", arguments["--dir"]!]
let channel: WorkerChannel
do { channel = try await WorkerChannel.start(executable: worker, arguments: workerArguments) } catch {
    fail("cannot start the worker: \(error)")
}
let relay = Relay(worker: channel) { [worker, workerArguments] in
    do {
        let next = try await WorkerChannel.start(executable: worker, arguments: workerArguments)
        log("started a new worker")
        return next
    } catch {
        log("cannot start a new worker: \(error); every later rewrite fails")
        return nil
    }
}

let guest: Guest
do {
    let disk = try arguments["--disk"].map { image in
        try Guest.PaymentDisk(image: URL(filePath: image), key: try Data(contentsOf: path("--disk-key")), isNew: newDisk)
    }
    guest = try Guest(kernel: path("--kernel"), console: serving ? .standardError : .standardOutput,
                      bootFolder: FileManager.default.temporaryDirectory, disk: disk)
} catch {
    fail("invalid guest: \(error)")
}

// tor, the guest's one way out. Started, and waited for until it has
// bootstrapped or is unavailable, before the boot files exist, so no task
// starts before tor can carry it; a tor whose SOCKS port never opened ends
// this process here. Every way this process ends from here stops it. Its
// state stays in its folder for the next start.
let tor: Tor
do { tor = try await Tor.start(executable: path("--tor"), data: path("--tor-data")) } catch {
    fail("cannot start Tor: \(error)")
}

do {
    try guest.prepare(base: path("--initrd"), cases: try Data(contentsOf: path("--cases")), model: arguments["--name"]!,
                      relay: relay, tor: tor, cover: true, serve: serving,
                      door: arguments["--door"].map { door in { guest in carry(guest, to: door) } })
    if let tasks = arguments["--runner"] {
        try serveTasks(at: tasks, on: guest)
    }
    if let payments = arguments["--pay"] {
        try serve(at: payments, on: guest, with: exchange)
    }
} catch {
    await tor.stop()
    fail("\(error)")
}

// Runs until the guest powers off (0) or stops with an error (1), then
// stops the worker and tor.
let (ends, ended) = AsyncStream.makeStream(of: Guest.End.self)
var status: Int32 = 1
do {
    try await guest.start { ended.yield($0) }
    if serving {
        Task {
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    let answer: Data
                    do {
                        let socket = try await guest.connect(to: Sender.port)
                        answer = try await Sender.exchange(socket, request: { Data(line.utf8) }) { deposit in
                            FileHandle.standardOutput.write(Data(#"{"keep":"#.utf8) + deposit + Data("}\n".utf8))
                        }
                    } catch {
                        answer = (try? JSONEncoder().encode(["host": "\(error)"])) ?? Data()
                    }
                    FileHandle.standardOutput.write(answer + Data("\n".utf8))
                }
            } catch {
                log("cannot read the requests: \(error)")
            }
            try? await guest.stop()
            ended.yield(.poweredOff)
        }
    }
    for await end in ends {
        if case .failed(let error) = end { log("guest stopped: \(error)") } else { status = 0 }
        break
    }
} catch {
    log("cannot start the guest: \(error)")
}
await relay.finish()
await tor.stop()
exit(status)


/// A socket file's address, for the calls that take a sockaddr.
func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// Carries one guest connection to the door port, byte for byte, to the
/// socket file at `path`, until either end closes; takes the guest's socket.
func carry(_ guest: Int32, to path: String) {
    Thread {
        defer { Darwin.close(guest) }
        let door = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard door >= 0 else { return }
        defer { Darwin.close(door) }
        guard (try? withSocketAddress(path, { Darwin.connect(door, $0, $1) })) == 0 else {
            log("cannot reach the door at \(path)")
            return
        }
        let answered = DispatchSemaphore(value: 0)
        Thread {
            pump(from: door, to: guest)
            answered.signal()
        }.start()
        pump(from: guest, to: door)
        answered.wait()
    }.start()
}

/// Copies until `source` ends or `destination` fails, then shuts both,
/// which ends the other direction too.
func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, $0.count) }
        if n < 0, errno == EINTR { continue }
        guard n > 0, send(Data(buffer.prefix(n)), to: destination) else { break }
    }
    Darwin.shutdown(source, SHUT_RDWR)
    Darwin.shutdown(destination, SHUT_RDWR)
}

/// Writes all of `data`; false when the socket failed first.
func send(_ data: Data, to socket: Int32) -> Bool {
    var done = 0
    while done < data.count {
        let n = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, data.count - done) }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return false }
        done += n
    }
    return true
}

/// One JSON line to a task's client.
func line(_ object: [String: Any]) -> Data {
    ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data("\n".utf8)
}

/// Listens on the socket file at `path` for tasks for the guest's runner,
/// each served on a thread of its own.
func serveTasks(at path: String, on guest: Guest) throws {
    try serve(at: path, on: guest, with: runTask)
}

/// Listens on the socket file at `path`, and serves each client with
/// `client` on a thread of its own.
func serve(at path: String, on guest: Guest, with client: @escaping @Sendable (Int32, Guest) -> Void) throws {
    let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0, try withSocketAddress(path, { Darwin.bind(server, $0, $1) }) == 0, Darwin.listen(server, 16) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    Thread {
        while true {
            let accepted = Darwin.accept(server, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                log("cannot take a client at \(path): \(String(cString: strerror(errno)))")
                return
            }
            Thread { client(accepted, guest) }.start()
        }
    }.start()
}

/// One task: its request line, then its events as lines, until it ends or
/// the client's end of the connection ends it. Takes the client's socket.
func runTask(_ client: Int32, on guest: Guest) {
    var request = Data()
    var byte: UInt8 = 0
    while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
        request.append(byte)
    }
    guard let request = try? JSONDecoder().decode(Runner.Request.self, from: request) else {
        _ = send(line(["failed": "the request did not read"]), to: client)
        Darwin.close(client)
        return
    }
    let done = DispatchSemaphore(value: 0)
    let work = Task {
        defer { done.signal() }
        do {
            let socket = try await guest.connect(to: Runner.port)
            for try await event in Runner.run(socket, request) {
                let object: [String: Any] = switch event {
                case .output(let data): ["output": String(decoding: data, as: UTF8.self)]
                case .error(let data): ["error": String(decoding: data, as: UTF8.self)]
                case .exited(let end): ["exited": ["status": end.status, "signalled": end.signalled]]
                }
                _ = send(line(object), to: client)
            }
        } catch {
            _ = send(line(["failed": "\(error)"]), to: client)
        }
    }
    // Nothing more comes from the client: its end ends the task.
    let watched = DispatchSemaphore(value: 0)
    Thread {
        var byte: UInt8 = 0
        while Darwin.read(client, &byte, 1) > 0 {}
        work.cancel()
        watched.signal()
    }.start()
    done.wait()
    Darwin.shutdown(client, SHUT_RDWR)
    watched.wait()
    Darwin.close(client)
}

/// One exchange with the guest's payer: its line, then a line for each
/// frame back, until the answer or the client's end of the connection,
/// which cancels it. Takes the client's socket.
func exchange(_ client: Int32, on guest: Guest) {
    var request = Data()
    var byte: UInt8 = 0
    while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
        request.append(byte)
    }
    guard let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
        let letter = object["frame"] as? String, letter.utf8.count == 1, let ask = Pay.Ask(rawValue: letter.utf8.first!),
        let fields = object["payload"], JSONSerialization.isValidJSONObject(fields),
        let payload = try? JSONSerialization.data(withJSONObject: fields)
    else {
        _ = send(line(["failed": "the request did not read"]), to: client)
        Darwin.close(client)
        return
    }
    let done = DispatchSemaphore(value: 0)
    let work = Task {
        defer { done.signal() }
        do {
            let socket = try await guest.connect(to: Pay.port)
            for try await event in Pay.exchange(socket, ask, payload) {
                switch event {
                case .held(let data): _ = send(data + Data("\n".utf8), to: client)
                case .answer(let data): _ = send(Data(#"{"answer":"#.utf8) + data + Data("}\n".utf8), to: client)
                }
            }
        } catch {
            _ = send(line(["failed": "\(error)"]), to: client)
        }
    }
    // Nothing more comes from the client: its end cancels the exchange.
    let watched = DispatchSemaphore(value: 0)
    Thread {
        var byte: UInt8 = 0
        while Darwin.read(client, &byte, 1) > 0 {}
        work.cancel()
        watched.signal()
    }.start()
    done.wait()
    Darwin.shutdown(client, SHUT_RDWR)
    watched.wait()
    Darwin.close(client)
}
