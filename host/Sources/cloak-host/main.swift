import Foundation
import Virtualization

// cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl>
//            --worker <cloak-rewriter> --name <model> --dir <model directory>
//            --tor <tor>
//
// Starts the native worker and tor, waits for tor to bootstrap (at most 90
// seconds), boots the guest with a fresh channel token and rewriter key,
// relays the guest's rewrite requests to the worker one at a time and its Tor
// port to tor, starts a new worker after a lost one, and exits when the guest
// powers off, after stopping both. The guest's console is this process's
// standard output.

let usage = "usage: cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl> --worker <cloak-rewriter> --name <model> --dir <model directory> --tor <tor>"
let flags = ["--kernel", "--initrd", "--cases", "--worker", "--name", "--dir", "--tor"]
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

func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

func hex(_ data: Data) -> Data { Data(data.map { String(format: "%02x", $0) }.joined().utf8) }

// A write to a worker or guest connection that has gone fails, and is handled
// as that loss, instead of ending the host.
signal(SIGPIPE, SIG_IGN)

// The worker. The relay starts it the same way again after a loss.
let startWorker: @Sendable () throws -> WorkerChannel = {
    [executable = path("--worker"), workerArguments = ["--name", arguments["--name"]!, "--dir", arguments["--dir"]!]] in
    try WorkerChannel(executable: executable, arguments: workerArguments)
}
let channel: WorkerChannel
do { channel = try startWorker() } catch { fail("cannot start the worker: \(error)") }

// The guest: two cores, 1 GiB, a console, the channel socket and an entropy
// source. No network device and no disk. Its initrd is written just before it
// starts. The entropy device only carries random bytes into the guest; without
// it the guest kernel's random source never becomes ready, and the daemon,
// which makes its keys and Tor identities from it, waits forever.
let bootDirectory = FileManager.default.temporaryDirectory.appending(path: "cloak-\(UUID().uuidString)")
let bootInitrd = bootDirectory.appending(path: "initrd")
let boot = VZLinuxBootLoader(kernelURL: path("--kernel"))
boot.initialRamdiskURL = bootInitrd
boot.commandLine = "console=hvc0 quiet"
let console = VZVirtioConsoleDeviceSerialPortConfiguration()
console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: .standardOutput)
let configuration = VZVirtualMachineConfiguration()
configuration.cpuCount = 2
configuration.memorySize = 1 << 30
configuration.bootLoader = boot
configuration.serialPorts = [console]
configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
do { try configuration.validate() } catch { fail("invalid guest: \(error)") }

// tor, the guest's one way out (Tor.swift). Started, and waited for until it
// has bootstrapped or is unavailable, before the boot files exist, so no task
// starts before tor can carry it; every way this process ends from here stops
// it.
let tor: Tor
do { tor = try Tor(executable: path("--tor")) } catch { fail("cannot start Tor: \(error)") }

// The guest's boot files. The token and key exist only in this process and
// the guest's memory. The initrd that carries them exists only while the
// guest starts: written here, removed when the start ends either way.
let token = randomBytes(32)
let initrd: Data
do {
    initrd = BootFiles.initrd(base: try Data(contentsOf: path("--initrd")), entries: [
        .init(path: "run/cloak/adapter-token", mode: 0o400, uid: 1001, gid: 1001, data: hex(token)),
        .init(path: "run/cloak/rewriter-key", mode: 0o440, uid: 0, gid: 1003, data: hex(randomBytes(32))),
        .init(path: "etc/cloak/cases.jsonl", mode: 0o444, uid: 0, gid: 0, data: try Data(contentsOf: path("--cases"))),
        .init(path: "etc/cloak/model", mode: 0o444, uid: 0, gid: 0, data: Data(arguments["--name"]!.utf8)),
    ])
    try FileManager.default.createDirectory(at: bootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
} catch {
    tor.stop()
    fail("\(error)")
}

func removeBootFiles() { try? FileManager.default.removeItem(at: bootDirectory) }

guard FileManager.default.createFile(atPath: bootInitrd.path, contents: initrd, attributes: [.posixPermissions: 0o600]) else {
    removeBootFiles()
    tor.stop()
    fail("cannot write the boot files")
}

final class Supervisor: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    let relay: Relay
    let torRelay: TorRelay
    let tor: Tor

    init(relay: Relay, tor: Tor) {
        self.relay = relay
        self.torRelay = TorRelay(socks: tor.port)
        self.tor = tor
    }

    /// The guest's two ports on the host: the rewrite relay's and the Tor
    /// port's. The guest can open no other.
    func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let socket = dup(connection.fileDescriptor)
        let port = connection.destinationPort
        connection.close()
        guard socket >= 0 else { return false }
        if port == TorRelay.port {
            torRelay.accept(socket)
        } else {
            relay.accept(socket)
        }
        return true
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        log("guest stopped: \(error)")
        finish(1)
    }

    private func finish(_ status: Int32) {
        relay.finish()
        tor.stop()
        exit(status)
    }
}

let supervisor = Supervisor(relay: Relay(token: token, worker: channel, startWorker: startWorker), tor: tor)
let listener = VZVirtioSocketListener()
listener.delegate = supervisor
let machine = VZVirtualMachine(configuration: configuration)
machine.delegate = supervisor
machine.start { result in
    removeBootFiles()
    if case .failure(let error) = result {
        log("cannot start the guest: \(error)")
        tor.stop()
        exit(1)
    }
    let socketDevice = machine.socketDevices[0] as! VZVirtioSocketDevice
    socketDevice.setSocketListener(listener, forPort: Relay.port)
    socketDevice.setSocketListener(listener, forPort: TorRelay.port)
}
dispatchMain()
