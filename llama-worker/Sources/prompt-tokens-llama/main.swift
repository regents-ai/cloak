import Foundation
import LlamaEngine
import RewriterKit

// prompt-tokens-llama <model> <model directory>
//
// A check tool, never installed. Reads one daemon rewrite request on standard
// input and prints, as a JSON array, the prompt tokens cloak-rewriter-llama
// gives the model for it: the same engine, loaded the same way.
// tests/test_llama_worker.py compares them with the MLX worker's.

let arguments = CommandLine.arguments
guard arguments.count == 3 else { stop("usage: prompt-tokens-llama <model> <model directory>") }
let tokens: [Int32]?
do {
    let request = try JSONDecoder().decode(ChatRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let pin = try ModelPin.load(name: arguments[1], engine: "llama")
    let engine = try Engine(pin: pin, directory: URL(filePath: arguments[2], directoryHint: .isDirectory))
    tokens = engine.promptTokens(request)
    engine.close()
} catch {
    stop("\(error)")
}
guard let tokens else { stop("the chat template failed") }
FileHandle.standardOutput.write(try JSONEncoder().encode(tokens))
