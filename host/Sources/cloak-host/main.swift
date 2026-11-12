import Foundation
import Virtualization

// cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl>
//            --worker <cloak-rewriter> --name <model> --dir <model directory>
//
// Starts the native worker, boots the guest with a fresh channel token and
// rewriter key, relays the guest's rewrite requests to the worker one at a
// time, and exits when the guest powers off. The guest's console is this
// process's standard output.

let usage = "usage: cloak-host --kernel <Image> --initrd <initrd.gz> --cases <cases.jsonl> --worker <cloak-rewriter> --name <model> --dir <model directory>"
let flags = ["--kernel", "--initrd", "--cases", "--worker", "--name", "--dir"]
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

// The worker.
let channel: WorkerChannel
do {
    channel = try WorkerChannel(executable: path("--worker"), arguments: [
        "--name", arguments["--name"]!, "--dir", arguments["--dir"]!,
    ])
} catch { fail("cannot start the worker: \(error)") }

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
} catch { fail("\(error)") }

func removeBootFiles() { try? FileManager.default.removeItem(at: bootDirectory) }

guard FileManager.default.createFile(atPath: bootInitrd.path, contents: initrd, attributes: [.posixPermissions: 0o600]) else {
    removeBootFiles()
    fail("cannot write the boot files")
}

final class Supervisor: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    let relay: Relay
    let worker: WorkerChannel

    init(relay: Relay, worker: WorkerChannel) {
        self.relay = relay
        self.worker = worker
    }

    func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let socket = dup(connection.fileDescriptor)
        connection.close()
        guard socket >= 0 else { return false }
        relay.accept(socket)
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
        worker.finish()
        exit(status)
    }
}

let supervisor = Supervisor(relay: Relay(token: token, worker: channel), worker: channel)
let listener = VZVirtioSocketListener()
listener.delegate = supervisor
let machine = VZVirtualMachine(configuration: configuration)
machine.delegate = supervisor
machine.start { result in
    removeBootFiles()
    if case .failure(let error) = result {
        log("cannot start the guest: \(error)")
        exit(1)
    }
    (machine.socketDevices[0] as! VZVirtioSocketDevice).setSocketListener(listener, forPort: Relay.port)
}
dispatchMain()
