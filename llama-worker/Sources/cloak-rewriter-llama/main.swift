import Foundation
import LlamaEngine
import RewriterKit
import os

// cloak-rewriter-llama --name <model> --dir <model directory>
//
// The llama.cpp rewriter decision 8 measures beside cloak-rewriter
// (docs/plan.md), a drop-in for it: the same command line, frames, request
// and reply, file checks and sandbox. It checks that the directory holds
// exactly the pinned files, loads the pinned GGUF file with llama.cpp and
// the pinned chat template, checks a pinned grammar against the one built
// in, signals ready, then answers one rewrite request at a time until the
// supervisor closes standard input or breaks the protocol. It then stops the
// rewrite in progress, as a cancel does, and exits once that rewrite's
// answer is written: with status 0 at the end of the channel, 2 after a
// protocol fault.
// Signed with worker/cloak-rewriter.entitlements, it runs in the App Sandbox
// with no network and reads files only under
// ~/Library/Application Support/Regents Cloak/models/.

Frames.claimOutput()
signal(SIGPIPE, SIG_IGN)

var arguments = [String: String]()
var rest = CommandLine.arguments.dropFirst()
while let flag = rest.popFirst() {
    guard ["--name", "--dir"].contains(flag), arguments[flag] == nil, let value = rest.popFirst() else {
        stop("usage: cloak-rewriter-llama --name <model> --dir <model directory>")
    }
    arguments[flag] = value
}
guard let name = arguments["--name"], let dir = arguments["--dir"] else {
    stop("usage: cloak-rewriter-llama --name <model> --dir <model directory>")
}
let directory = URL(filePath: dir, directoryHint: .isDirectory)

let worker: Worker
do {
    let pin = try ModelPin.load(name: name, engine: "llama")
    try pin.verify(directory: directory)
    worker = Worker(pin: pin, engine: try Engine(pin: pin, directory: directory))
} catch {
    stop("cannot load \(name): \(error)")
}
log.info(
    "loaded \(name, privacy: .public); weights \(worker.engine.weightsBytes) bytes, Metal allocated \(Engine.metalAllocatedBytes) bytes"
)
Frames.ready()

do {
    for try await frame in Frames.incoming() {
        try worker.receive(frame)
    }
    await worker.finish()
    worker.engine.close()
} catch {
    await worker.finish()
    worker.engine.close()
    stop("\(error)")
}
