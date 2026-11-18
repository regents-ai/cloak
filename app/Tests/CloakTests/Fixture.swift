import CloakControl
@testable import CloakSupervisor
import CryptoKit
import Foundation

/// An installation in a temporary folder, pinned in its own manifest: the
/// bundle's parts and the Application Support folder's, with shell scripts in
/// place of tor and the worker that note each start, and placeholder files
/// for the rest. The guest's kernel is a placeholder, and the test process
/// has no virtualization entitlement, so a guest never starts here.
struct Fixture {
    /// Notes the start, and says it opened the SOCKS socket it was given
    /// (--SocksPort "unix:<path> IsolateSOCKSAuth"), as tor does.
    private static let opened = """
        echo $$ >> "$(dirname "$0")/starts"
        while [ "$1" != --SocksPort ]; do shift; done
        socket=${2#unix:}
        echo "[notice] Opened Socks listener connection (ready) on ${socket% IsolateSOCKSAuth}"
        """
    /// Opens its SOCKS socket and bootstraps at once, then runs until stopped.
    static let tor = """
        #!/bin/sh
        \(opened)
        echo "[notice] Bootstrapped 100% (done): Done"
        exec sleep 600
        """
    /// Opens its SOCKS socket and never bootstraps.
    static let slowTor = """
        #!/bin/sh
        \(opened)
        exec sleep 600
        """
    /// Exits before its SOCKS socket opens.
    static let failingTor = """
        #!/bin/sh
        echo $$ >> "$(dirname "$0")/starts"
        exit 1
        """
    /// Signals ready, then runs until its input closes.
    static let worker = """
        #!/bin/sh
        echo $$ >> "$(dirname "$0")/starts"
        printf 'Y\\000\\000\\000\\000'
        exec cat > /dev/null
        """
    /// Never signals ready, as a worker still loading its model, and runs
    /// until stopped.
    static let loadingWorker = """
        #!/bin/sh
        echo $$ >> "$(dirname "$0")/starts"
        exec sleep 600
        """
    /// Exits before it signals ready.
    static let failingWorker = """
        #!/bin/sh
        echo $$ >> "$(dirname "$0")/starts"
        exit 1
        """

    let root: URL
    let layout: Layout
    let manifest: Manifest

    init(tor: String = Fixture.tor, worker: String = Fixture.worker) throws {
        root = URL(filePath: "/tmp").appending(path: "cloak-fixture-\(UUID().uuidString.prefix(8))")
        layout = Layout(bundle: root.appending(path: "bundle"), support: root.appending(path: "support"))
        let contents: [(Manifest.Part, Manifest.Place, String, String)] = [
            (.kernel, .bundle, "guest/Image", "not a kernel"),
            (.initrd, .bundle, "guest/initrd.gz", "not a root"),
            (.tor, .bundle, "tor/tor", tor),
            (.libevent, .bundle, "tor/libevent-2.1.7.dylib", "not a library"),
            (.worker, .support, "worker/cloak-rewriter-llama", worker),
        ]
        var pins = [Manifest.Pin]()
        for (part, place, path, text) in contents {
            let url = (place == .bundle ? layout.bundle : layout.support).appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            pins.append(.init(part: part, place: place, path: path, sha256: digest))
        }
        let model = layout.support.appending(path: "models/standin")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appending(path: "config.json"))
        manifest = Manifest(
            release: "0.0.0-test", build: "test", modelMemory: 7 << 30, cloakMemory: 10 << 30,
            model: .init(name: "standin", label: "development stand-in", files: [
                .init(path: "config.json", size: 2, sha256: SHA256.hash(data: Data("{}".utf8)).map { String(format: "%02x", $0) }.joined(),
                      url: URL(string: "http://127.0.0.1:9/config.json")!),
            ]),
            pins: pins)
    }

    /// A supervisor on this installation, on a Mac that meets the manifest,
    /// whose worker never rests.
    @MainActor
    func supervisor(hardware: Checks.Hardware = .init(appleSilicon: true, memory: 64 << 30, graphicsLimit: 48 << 30)) throws -> Supervisor {
        try Supervisor(manifest: manifest, layout: layout, hardware: hardware) { nil }
    }

    func url(_ part: Manifest.Part) -> URL {
        layout.url(part, in: manifest)
    }

    /// The process of each start of the script for `part`, in order.
    func starts(_ part: Manifest.Part) -> [pid_t] {
        let log = url(part).deletingLastPathComponent().appending(path: "starts")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

func isRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}
