import Foundation
import LlamaEngine
import RewriterKit
import os

// cloak-rewriter-llama --name <model> --dir <model directory>
//
// The rewriter, on llama.cpp (decision 8 in docs/plan.md). It checks that the
// directory holds exactly the pinned files, loads the pinned GGUF file with
// llama.cpp and the pinned chat template, checks the pinned grammar against
// the one built in, signals ready, then answers one request at a time (a
// rewrite, a draft's details or a Local Llama chat's next answer) until the
// supervisor closes standard input or breaks the protocol. It then stops the
// request in progress, as a cancel does, and exits once that request's
// answer is written: with status 0 at the end of the channel, 2
// after a protocol fault. It exits with status 3, before it is ready, when
// the directory does not hold exactly the pinned files, and with 2 when
// anything else stops it loading.
// Signed with llama-worker/cloak-rewriter.entitlements, it runs in the App
// Sandbox with no network and reads files only under
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

let pin: ModelPin
do {
    pin = try ModelPin.load(name: name)
} catch {
    stop("cannot load \(name): \(error)")
}
do {
    try pin.verify(directory: directory)
} catch {
    stop("cannot load \(name): \(error)", status: 3)
}
let worker: Worker
do {
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
