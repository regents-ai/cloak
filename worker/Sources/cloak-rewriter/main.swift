import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import RewriterKit

// cloak-rewriter --name <model> --dir <model directory>
//
// Checks that the directory holds exactly the pinned files, loads the model
// from them, signals ready, then answers one rewrite request at a time over
// rewriter-kit's frames (Frames.swift) until the supervisor closes standard input or
// breaks the protocol. It then stops the rewrite in progress, as a cancel
// does, and exits once that rewrite's answer is written: with status 0 at the
// end of the channel, 2 after a protocol fault.
// Signed with cloak-rewriter.entitlements, it runs in the App Sandbox with no
// network and reads files only under
// ~/Library/Application Support/Regents Cloak/models/.

Frames.claimOutput()
signal(SIGPIPE, SIG_IGN)

var arguments = [String: String]()
var rest = CommandLine.arguments.dropFirst()
while let flag = rest.popFirst() {
    guard ["--name", "--dir"].contains(flag), arguments[flag] == nil, let value = rest.popFirst() else {
        stop("usage: cloak-rewriter --name <model> --dir <model directory>")
    }
    arguments[flag] = value
}
guard let name = arguments["--name"], let dir = arguments["--dir"] else {
    stop("usage: cloak-rewriter --name <model> --dir <model directory>")
}
let directory = URL(filePath: dir, directoryHint: .isDirectory)

let worker: Worker
do {
    let pin = try ModelPin.load(name: name, engine: "mlx")
    try pin.verify(directory: directory)
    let container = try await LLMModelFactory.shared.loadContainer(
        from: directory, using: TokenizerFiles())
    worker = Worker(pin: pin, container: container)
} catch {
    stop("cannot load \(name): \(error)")
}
// Loading leaves buffers in MLX's cache; give them back to the system before
// the first request.
let loaded = Memory.snapshot()
Memory.clearCache()
log.info(
    "loaded \(name, privacy: .public); \(mlxMemory(loaded), privacy: .public); after the cache clear, \(mlxMemory(Memory.snapshot()), privacy: .public)"
)
Frames.ready()

do {
    for try await frame in Frames.incoming() {
        try worker.receive(frame)
    }
    await worker.finish()
} catch {
    await worker.finish()
    stop("\(error)")
}
