@testable import CloakSupervisor
import CryptoKit
import Foundation

/// An installation in a temporary folder, pinned in its own manifest: the
/// bundle's parts and the Application Support folder's, as placeholder files.
/// Nothing is started from it.
struct Fixture {
    let root: URL
    let layout: Layout
    let manifest: Manifest

    init() throws {
        root = URL(filePath: "/tmp").appending(path: "cloak-fixture-\(UUID().uuidString.prefix(8))")
        layout = Layout(bundle: root.appending(path: "bundle"), support: root.appending(path: "support"))
        let contents: [(Manifest.Part, Manifest.Place, String, String)] = [
            (.kernel, .bundle, "guest/Image", "not a kernel"),
            (.initrd, .bundle, "guest/initrd.gz", "not a root"),
            (.tor, .bundle, "tor/tor", "not tor"),
            (.libevent, .bundle, "tor/libevent-2.1.7.dylib", "not a library"),
            (.worker, .support, "worker/cloak-rewriter-llama", "not a worker"),
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
    func supervisor() throws -> Supervisor {
        try Supervisor(manifest: manifest, layout: layout, hardware: .init(appleSilicon: true, memory: 64 << 30, graphicsLimit: 48 << 30)) { nil }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The repository's own folder, and the commands the checks run from it.
enum Repository {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Runs tests/`name`/main.go on `input`, built inside the pinned daemon
    /// module (Go's cache makes that quick) in a folder removed afterwards.
    static func tool(_ name: String, input: Data) throws -> Data {
        let daemon = root.appending(path: "reference/src/zkapi/zkapi-clientd")
        let command = "cloak-" + name.replacing("_", with: "-")
        let out = URL(filePath: NSTemporaryDirectory()).appending(path: "\(command)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let overlay = ["Replace": [daemon.appending(path: "cmd/\(command)/main.go").path: root.appending(path: "tests/\(name)/main.go").path]]
        try JSONEncoder().encode(overlay).write(to: out.appending(path: "overlay.json"))
        let tool = out.appending(path: command)
        try run(
            ["go", "build", "-p", "2", "-trimpath", "-overlay", out.appending(path: "overlay.json").path, "-o", tool.path,
             "./cmd/\(command)"],
            in: daemon, environment: ["CGO_ENABLED": "0"])
        return try run([tool.path], in: root, input: input)
    }

    /// Runs a command to its end; its output, or a failure with what it said.
    @discardableResult
    static func run(_ command: [String], in folder: URL, environment: [String: String] = [:], input: Data = Data()) throws -> Data {
        let files = URL(filePath: NSTemporaryDirectory()).appending(path: "cloak-run-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        let stdin = files.appending(path: "in"), stdout = files.appending(path: "out"), stderr = files.appending(path: "err")
        try input.write(to: stdin)
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = try FileHandle(forReadingFrom: stdin)
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failed(command: command.joined(separator: " "), said: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
        }
        return try Data(contentsOf: stdout)
    }

    struct Failed: Error {
        let command: String
        let said: String
    }
}
