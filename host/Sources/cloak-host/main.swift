import CloakHost
import Foundation

// cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl>
//            --worker <cloak-rewriter-llama> --name <model> --dir <model directory>
//            --tor <tor> --tor-data <tor's folder> [--serve]
//
// Starts the native worker and tor, waits for tor to open its SOCKS port and
// bootstrap (at most 90 seconds from its start; this process fails if the
// port has not opened by then), boots the guest with a fresh channel token
// and rewriter key, relays the guest's rewrite requests to the worker one at
// a time and its Tor port to tor, starts a new worker after a lost one, and
// exits when the guest powers off, after stopping both. The guest's console
// is this process's standard output.
//
// With --serve the guest runs the sender after its checks (Development mode,
// decision 10 in docs/plan.md) and its console goes to standard error: each
// line read from standard input is one request to the sender, and its answer
// is one line on standard output, after a line {"keep": <deposit>} for each
// deposit change the sender reports, which this kit does not keep. The guest
// is stopped once standard input ends.

let usage = "usage: cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl> --worker <cloak-rewriter-llama> --name <model> --dir <model directory> --tor <tor> --tor-data <tor's folder> [--serve]"
let flags = ["--kernel", "--initrd", "--cases", "--worker", "--name", "--dir", "--tor", "--tor-data"]
let (arguments, serving) = {
    var parsed = [String: String]()
    var serve = false
    var rest = CommandLine.arguments.dropFirst()
    while let flag = rest.popFirst() {
        if flag == "--serve", !serve {
            serve = true
            continue
        }
        guard flags.contains(flag), parsed[flag] == nil, let value = rest.popFirst() else { fail(usage) }
        parsed[flag] = value
    }
    guard parsed.count == flags.count else { fail(usage) }
    return (parsed, serve)
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
    guest = try Guest(kernel: path("--kernel"), console: serving ? .standardError : .standardOutput,
                      bootFolder: FileManager.default.temporaryDirectory)
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
                      relay: relay, tor: tor, serve: serving)
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
