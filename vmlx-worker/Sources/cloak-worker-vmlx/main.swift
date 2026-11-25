import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import RewriterKit
import VMLXTokenizers
import os

// cloak-worker-vmlx --name <model> --dir <model directory>
//
// Sandboxed pure-Swift vMLX worker (osaurus-ai/vmlx-swift, MIT) for fast Local
// Chat models such as OsaurusAI/Inkling-2-Mini-JANGH2 (10.2 GB, 60+ tok/s, fits
// 16 GB+ Apple silicon Macs). Speaks the exact same RewriterKit.Frames stdin /
// stdout protocol as cloak-rewriter-llama.

@main
struct CloakVmlxWorkerMain {
    static func main() async {
        Frames.claimOutput()
        signal(SIGPIPE, SIG_IGN)

        var arguments = [String: String]()
        var rest = CommandLine.arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard ["--name", "--dir"].contains(flag), arguments[flag] == nil, let value = rest.popFirst() else {
                stop("usage: cloak-worker-vmlx --name <model> --dir <model directory>")
            }
            arguments[flag] = value
        }
        guard let name = arguments["--name"], let dir = arguments["--dir"] else {
            stop("usage: cloak-worker-vmlx --name <model> --dir <model directory>")
        }
        let directory = URL(filePath: dir, directoryHint: .isDirectory)

        let pin: ModelPin
        do {
            pin = try ModelPin.load(name: name)
        } catch {
            stop("cannot load \(name): \(error)")
        }
        guard pin.engine == .vmlx, pin.answers != nil else {
            stop("\(name) is not a vMLX answer model")
        }
        do {
            try pin.verify(directory: directory)
        } catch {
            stop("cannot load \(name): \(error)", status: 3)
        }

        // Keep MLX buffer cache bounded so 16 GB Macs stay comfortably under
        // macOS memory pressure limits (~10.3 GiB peak for JANGH2).
        Memory.cacheLimit = 512 * 1024 * 1024

        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: #huggingFaceTokenizerLoader())
        } catch {
            stop("cannot load \(name): \(error)")
        }

        let worker = VmlxWorker(pin: pin, directory: directory, container: container)
        log.info(
            "loaded vmlx \(name, privacy: .public); active \(Memory.activeMemory) bytes, peak \(Memory.peakMemory) bytes, dspark=\(worker.useDSpark)"
        )
        guard Frames.ready() else {
            stop("supervisor channel closed")
        }

        do {
            for try await frame in Frames.incoming() {
                try worker.receive(frame)
            }
            await worker.finish()
        } catch {
            await worker.finish()
            stop("\(error)")
        }
    }
}
