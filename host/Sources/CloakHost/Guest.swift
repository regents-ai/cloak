import Foundation
import Virtualization

/// The guest: two cores, 1 GiB, a console, the channel socket, an entropy
/// source and, when given one, the payment disk. No network device. The
/// entropy device only carries random bytes into the guest; without it the
/// guest kernel's random source never becomes ready, and the daemon, which
/// makes its keys and Tor identities from it, waits forever. It reaches the
/// host on two ports only: the rewrite relay's and the Tor port's, and on a
/// third, the door port's, when it is given a door. A guest that serves also
/// runs the sender and the runner, and with its payment disk the payer, which
/// the host connects to (`connect`).
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

    /// The door port's: the guest's door port carries the agent's model
    /// requests here.
    public static let doorPort: UInt32 = 8742

    /// The payment disk: an image file on the Mac and the 32 random bytes it
    /// is encrypted under, both the caller's. The guest opens it with that
    /// key, and makes it, formatting the image, only when `isNew` says the
    /// image is blank and new; a disk that does not open ends the guest
    /// (guest/image/pay-disk).
    public struct PaymentDisk: Sendable {
        public let image: URL
        public let key: Data
        public let isNew: Bool

        public init(image: URL, key: Data, isNew: Bool) throws {
            guard key.count == 32 else { throw GuestError(description: "the payment disk's key is not 32 bytes") }
            self.image = image
            self.key = key
            self.isNew = isNew
        }
    }

    private let configuration: VZVirtualMachineConfiguration
    private let bootDirectory: URL
    private let disk: PaymentDisk?
    private let listener = VZVirtioSocketListener()
    private var machine: VZVirtualMachine?
    private var relays: (rewrite: Relay, tor: TorRelay, door: ((Int32) -> Void)?)?
    private var ended: ((End) -> Void)?

    /// Checks the guest's settings; nothing is written or started. The
    /// guest's console is written to `console`, and its boot files go in a
    /// folder of its own in `bootFolder`, which must exist. A `disk`'s image
    /// is the guest's only disk, read and written in place; each flush the
    /// guest makes reaches the Mac's storage before the guest goes on
    /// (`.full`: an F_FULLFSYNC of the image), so a guest killed at any
    /// moment leaves every write it flushed in the image.
    public init(kernel: URL, console: FileHandle, bootFolder: URL, disk: PaymentDisk? = nil) throws {
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
        if let disk {
            let image = try VZDiskImageStorageDeviceAttachment(
                url: disk.image, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: image)]
        }
        try configuration.validate()
        self.disk = disk
        super.init()
        listener.delegate = self
    }

    /// Writes the guest's boot files: its base root `base`, then the relay's
    /// channel token, a fresh rewriter key, the check cases and the model's
    /// name; without `cover`, a cover list with no URLs in place of the
    /// image's, the daemon's own cleared setting, so its cover worker never
    /// starts; when it `serve`s, the mark that starts the door port, the
    /// runner and the sender after the checks; and with a payment disk, its
    /// key, readable by the guest's root alone, which removes it once the
    /// disk is open, and, for a new image, the mark that has the guest make
    /// it. The token and the rewriter key exist only in this process and the
    /// guest's memory, and the disk's key only there and where the caller
    /// keeps it; the file that carries them, readable by this process's user
    /// alone, exists only until `start` ends. With a `door`, the guest's
    /// connections to the door port are handed to it, each as a socket it
    /// owns; without one, that port is not open.
    public func prepare(
        base: URL, cases: Data, model: String, relay: Relay, tor: Tor, cover: Bool, serve: Bool,
        door: ((Int32) -> Void)?
    ) async throws {
        var entries: [BootFiles.Entry] = [
            .init(path: "run/cloak/adapter-token", mode: 0o400, uid: 1001, gid: 1001, data: hex(relay.token)),
            .init(path: "run/cloak/rewriter-key", mode: 0o440, uid: 0, gid: 1003, data: hex(randomBytes(32))),
            .init(path: "etc/cloak/cases.jsonl", mode: 0o444, uid: 0, gid: 0, data: cases),
            .init(path: "etc/cloak/model", mode: 0o444, uid: 0, gid: 0, data: Data(model.utf8)),
        ]
        if !cover {
            entries.append(.init(path: "etc/cloak/cover.json", mode: 0o444, uid: 0, gid: 0, data: Data(#"{"urls":[]}"#.utf8)))
        }
        if serve {
            entries.append(.init(path: "etc/cloak/serve", mode: 0o444, uid: 0, gid: 0, data: Data()))
        }
        if let disk {
            entries.append(.init(path: "run/cloak/pay-disk-key", mode: 0o400, uid: 0, gid: 0, data: disk.key))
            if disk.isNew {
                entries.append(.init(path: "etc/cloak/pay-disk-new", mode: 0o444, uid: 0, gid: 0, data: Data()))
            }
        }
        let bootDirectory = self.bootDirectory
        do {
            try await Self.writeBootFiles(base: base, entries: entries, to: bootDirectory)
        } catch {
            removeBootFiles()
            throw error
        }
        relays = (relay, TorRelay(tor: tor), door)
    }

    @concurrent
    private static func writeBootFiles(base: URL, entries: [BootFiles.Entry], to bootDirectory: URL) async throws {
        let initrd = BootFiles.initrd(base: try Data(contentsOf: base), entries: entries)
        try FileManager.default.createDirectory(at: bootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: bootDirectory.appending(path: "initrd").path, contents: initrd, attributes: [.posixPermissions: 0o600]) else {
            throw GuestError(description: "cannot write the boot files")
        }
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
        if relays?.door != nil {
            socketDevice.setSocketListener(listener, forPort: Self.doorPort)
        }
    }

    /// A new connection to the running guest's `port`, as a socket the
    /// caller owns.
    public func connect(to port: UInt32) async throws -> Int32 {
        guard let device = machine?.socketDevices.first as? VZVirtioSocketDevice else {
            throw GuestError(description: "the guest is not running")
        }
        return try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                continuation.resume(with: result.flatMap { connection in
                    let socket = dup(connection.fileDescriptor)
                    connection.close()
                    return socket >= 0 ? .success(socket) : .failure(GuestError(description: "cannot take the connection"))
                })
            }
        }
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
    /// The guest's ports on the host: the rewrite relay's, the Tor port's
    /// and, with a door, the door port's. The guest can open no other.
    public func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // Set by prepare, before start opens these ports.
        let (rewrite, tor, door) = relays!
        let socket = dup(connection.fileDescriptor)
        let port = connection.destinationPort
        connection.close()
        guard socket >= 0 else { return false }
        switch port {
        case TorRelay.port: tor.accept(socket)
        case Self.doorPort: door!(socket)
        default: rewrite.accept(socket)
        }
        return true
    }
}

struct GuestError: Error, CustomStringConvertible {
    let description: String
}

func hex(_ data: Data) -> Data { Data(data.map { String(format: "%02x", $0) }.joined().utf8) }
