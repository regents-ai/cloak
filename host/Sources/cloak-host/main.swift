import CloakHost
import Foundation

// cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl>
//            --worker <cloak-rewriter> --name <model> --dir <model directory>
//            --tor <tor> --tor-data <tor's folder>
//
// Starts the native worker and tor, waits for tor to open its SOCKS port and
// bootstrap (at most 90 seconds from its start; this process fails if the
// port has not opened by then), boots the guest with a fresh channel token
// and rewriter key, relays the guest's rewrite requests to the worker one at
// a time and its Tor port to tor, starts a new worker after a lost one, and
// exits when the guest powers off, after stopping both. The guest's console
// is this process's standard output.

let usage = "usage: cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl> --worker <cloak-rewriter> --name <model> --dir <model directory> --tor <tor> --tor-data <tor's folder>"
let flags = ["--kernel", "--initrd", "--cases", "--worker", "--name", "--dir", "--tor", "--tor-data"]
let arguments = {
    var parsed = [String: String]()
    var rest = CommandLine.arguments.dropFirst()
    while let flag = rest.popFirst() {
        guard flags.contains(flag), parsed[flag] == nil, let value = rest.popFirst() else { fail(usage) }
        parsed[flag] = value
    }
    guard parsed.count == flags.count else { fail(usage) }
    return parsed
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
    guest = try Guest(kernel: path("--kernel"), console: .standardOutput, bootFolder: FileManager.default.temporaryDirectory)
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
                      relay: relay, tor: tor)
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
