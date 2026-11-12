import Foundation
import MLXLLM
import MLXLMCommon

// cloak-rewriter --name <model> --dir <model directory>
//
// Checks that the directory holds exactly the pinned files, loads the model
// from them, signals ready, then answers one rewrite request at a time over
// the frames in Frames.swift until the supervisor closes standard input. It
// then stops the rewrite in progress, as a cancel does, and exits once that
// rewrite's answer is written.
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
    let pin = try ModelPin.load(name: name)
    try pin.verify(directory: directory)
    let container = try await LLMModelFactory.shared.loadContainer(
        from: directory, using: TokenizerFiles())
    worker = Worker(pin: pin, container: container)
} catch {
    stop("cannot load \(name): \(error)")
}
log.info("loaded \(name, privacy: .public)")
Frames.ready()

for await frame in Frames.incoming() {
    worker.receive(frame)
}
await worker.finish()
