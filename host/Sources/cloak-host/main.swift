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

// The worker.
let channel: WorkerChannel
do {
    channel = try WorkerChannel(executable: path("--worker"), arguments: [
        "--name", arguments["--name"]!, "--dir", arguments["--dir"]!,
    ])
} catch { fail("cannot start the worker: \(error)") }
guard channel.waitUntilReady() else { fail("the worker did not become ready") }

// The guest's boot files. The token and key exist only in this process and
// the guest's memory; the initrd that carries them is removed once read.
let token = randomBytes(32)
let rewriterKey = hex(randomBytes(32))
let cases: Data
let base: Data
do {
    cases = try Data(contentsOf: path("--cases"))
    base = try Data(contentsOf: path("--initrd"))
} catch { fail("\(error)") }
let bootDirectory = FileManager.default.temporaryDirectory.appending(path: "cloak-\(UUID().uuidString)")
let bootInitrd = bootDirectory.appending(path: "initrd")
do {
    try FileManager.default.createDirectory(at: bootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let initrd = BootFiles.initrd(base: base, entries: [
        .init(path: "run/cloak/adapter-token", mode: 0o400, uid: 1001, gid: 1001, data: hex(token)),
        .init(path: "run/cloak/rewriter-key", mode: 0o440, uid: 0, gid: 1003, data: rewriterKey),
        .init(path: "etc/cloak/cases.jsonl", mode: 0o444, uid: 0, gid: 0, data: cases),
        .init(path: "etc/cloak/model", mode: 0o444, uid: 0, gid: 0, data: Data(arguments["--name"]!.utf8)),
    ])
    guard FileManager.default.createFile(atPath: bootInitrd.path, contents: initrd, attributes: [.posixPermissions: 0o600]) else {
        fail("cannot write the boot files")
    }
} catch { fail("\(error)") }

func removeBootFiles() { try? FileManager.default.removeItem(at: bootDirectory) }

// The guest: two cores, 1 GiB, a console, the channel socket. No network
// device and no disk.
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
do { try configuration.validate() } catch { fail("invalid guest: \(error)") }

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
        removeBootFiles()
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
