import Foundation
import Virtualization

/// The guest: two cores, 1 GiB, a console, the channel socket and an entropy
/// source. No network device and no disk. The entropy device only carries
/// random bytes into the guest; without it the guest kernel's random source
/// never becomes ready, and the daemon, which makes its keys and Tor
/// identities from it, waits forever. It reaches the host on two ports only:
/// the rewrite relay's and the Tor port's.
///
///     made --prepare--> prepared --start--> running --power off or error--> ended
///                                              |
///                                              +--stop--> stopped (ended is not called)
@MainActor
public final class Guest: NSObject {
    /// How the guest ended on its own.
    public enum End: Sendable, Equatable {
        case poweredOff
        case failed(String)
    }

    private let configuration: VZVirtualMachineConfiguration
    private let bootDirectory: URL
    private let listener = VZVirtioSocketListener()
    private var machine: VZVirtualMachine?
    private var relays: (rewrite: Relay, tor: TorRelay)?
    private var ended: ((End) -> Void)?

    /// Checks the guest's settings; nothing is written or started. The
    /// guest's console is written to `console`, and its boot files go in a
    /// folder of its own in `bootFolder`, which must exist.
    public init(kernel: URL, console: FileHandle, bootFolder: URL) throws {
        bootDirectory = bootFolder.appending(path: Self.bootPrefix + UUID().uuidString)
        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = bootDirectory.appending(path: "initrd")
        boot.commandLine = "console=hvc0 quiet"
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console)
        configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = 2
        configuration.memorySize = 1 << 30
        configuration.bootLoader = boot
        configuration.serialPorts = [serial]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try configuration.validate()
        super.init()
        listener.delegate = self
    }

    /// Writes the guest's boot files: its base root `base`, then the relay's
    /// channel token, a fresh rewriter key, the check cases and the model's
    /// name. The token and key exist only in this process and the guest's
    /// memory; the file that carries them exists only until `start` ends.
    public func prepare(base: URL, cases: Data, model: String, relay: Relay, tor: Tor) throws {
        let initrd = BootFiles.initrd(base: try Data(contentsOf: base), entries: [
            .init(path: "run/cloak/adapter-token", mode: 0o400, uid: 1001, gid: 1001, data: hex(relay.token)),
            .init(path: "run/cloak/rewriter-key", mode: 0o440, uid: 0, gid: 1003, data: hex(randomBytes(32))),
            .init(path: "etc/cloak/cases.jsonl", mode: 0o444, uid: 0, gid: 0, data: cases),
            .init(path: "etc/cloak/model", mode: 0o444, uid: 0, gid: 0, data: Data(model.utf8)),
        ])
        try FileManager.default.createDirectory(at: bootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: bootDirectory.appending(path: "initrd").path, contents: initrd, attributes: [.posixPermissions: 0o600]) else {
            removeBootFiles()
            throw GuestError(description: "cannot write the boot files")
        }
        relays = (relay, TorRelay(tor: tor))
    }

    /// Starts the prepared guest, and removes its boot files once the start
    /// has ended either way. `ended` is called once if the guest later powers
    /// off or stops with an error.
    public func start(ended: @escaping (End) -> Void) async throws {
        defer { removeBootFiles() }
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        self.machine = machine
        self.ended = ended
        try await machine.start()
        let socketDevice = machine.socketDevices[0] as! VZVirtioSocketDevice
        socketDevice.setSocketListener(listener, forPort: Relay.port)
        socketDevice.setSocketListener(listener, forPort: TorRelay.port)
    }

    /// Stops a running guest at once, as cutting its power does; `ended` is
    /// not called for it.
    public func stop() async throws {
        ended = nil
        guard let machine, machine.canStop else { return }
        try await machine.stop()
    }

    private func removeBootFiles() {
        try? FileManager.default.removeItem(at: bootDirectory)
    }

    private static let bootPrefix = "cloak-"

    /// Removes what guests left in `bootFolder` when the process that
    /// started them was killed before `start` ended: each guest's own folder,
    /// `cloak-<UUID>`, and nothing else.
    public static func removeBootFiles(in bootFolder: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: bootFolder.path)
        where name.hasPrefix(bootPrefix) && UUID(uuidString: String(name.dropFirst(bootPrefix.count))) != nil {
            try FileManager.default.removeItem(at: bootFolder.appending(path: name))
        }
    }

    private func end(_ end: End) {
        let ended = self.ended
        self.ended = nil
        ended?(end)
    }
}

extension Guest: @preconcurrency VZVirtualMachineDelegate {
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        end(.poweredOff)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        end(.failed("\(error)"))
    }
}

extension Guest: @preconcurrency VZVirtioSocketListenerDelegate {
    /// The guest's two ports on the host: the rewrite relay's and the Tor
    /// port's. The guest can open no other.
    public func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // Set by prepare, before start opens these ports.
        let (rewrite, tor) = relays!
        let socket = dup(connection.fileDescriptor)
        let port = connection.destinationPort
        connection.close()
        guard socket >= 0 else { return false }
        if port == TorRelay.port {
            tor.accept(socket)
        } else {
            rewrite.accept(socket)
        }
        return true
    }
}

struct GuestError: Error, CustomStringConvertible {
    let description: String
}

func hex(_ data: Data) -> Data { Data(data.map { String(format: "%02x", $0) }.joined().utf8) }
