import Foundation
import RewriterKit
import Tokenizers

// prompt-tokens <model> <model directory>
//
// A check tool, never installed. Reads one daemon rewrite request on standard
// input and prints, as a JSON array, the prompt tokens cloak-rewriter gives
// the model for it: the same swift-transformers calls the worker makes
// (TokenizerFiles.swift, then Worker.generate's applyChatTemplate with the
// pinned template settings). tests/test_llama_worker.py compares them with
// the llama worker's.

let arguments = CommandLine.arguments
guard arguments.count == 3 else { stop("usage: prompt-tokens <model> <model directory>") }
do {
    let pin = try ModelPin.load(name: arguments[1], engine: "mlx")
    let tokenizer = try await AutoTokenizer.from(modelFolder: URL(filePath: arguments[2], directoryHint: .isDirectory))
    let request = try JSONDecoder().decode(ChatRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let tokens = try tokenizer.applyChatTemplate(
        messages: request.templateMessages, tools: nil, additionalContext: pin.chatTemplateContext)
    FileHandle.standardOutput.write(try JSONEncoder().encode(tokens))
} catch {
    stop("\(error)")
}
