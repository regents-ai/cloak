import CLlama
import Foundation
import RewriterKit

/// One loaded GGUF model and its pinned chat template (cloak_llama.h). The
/// worker runs one rewrite at a time on it; `cancel` is safe from any thread.
public final class Engine: @unchecked Sendable {
    /// How one rewrite ended, with llama.cpp's counts and timings.
    public struct Rewrite: Sendable {
        public enum Finish: Sendable { case stop, length, cancelled, failed(step: String, code: Int32) }
        public let finish: Finish
        public let text: String
        public let promptTokens: Int
        public let generatedTokens: Int
        public let contextTokens: UInt32
        public let promptSeconds: Double
        public let generateSeconds: Double
        public let metalAllocatedBytes: UInt64
    }

    private let engine: OpaquePointer
    /// Rewrites run here, off Swift's own threads, as llama.cpp blocks while
    /// it computes.
    private let queue = DispatchQueue(label: "sh.regents.cloak.rewriter-llama")

    /// Loads the pin's one GGUF file with the pin's chat template file,
    /// `chat_template.jinja`, and its frozen template settings.
    public init(pin: ModelPin, directory: URL) throws {
        let weights = pin.files.map(\.path).filter { $0.hasSuffix(".gguf") }
        guard weights.count == 1 else { throw WorkerError("\(pin.name) pins \(weights.count) GGUF files, not one") }
        let template = try String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8)
        let settings = pin.chatTemplateContext.sorted { $0.key < $1.key }
        let names = settings.map { strdup($0.key) }
        defer { names.forEach { free($0) } }
        var error = [CChar](repeating: 0, count: 1024)
        guard let loaded = cloak_engine_load(
            directory.appending(path: weights[0]).path, template, names.map { UnsafePointer($0) },
            settings.map(\.value), settings.count, &error, error.count)
        else {
            throw WorkerError(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        engine = loaded
    }

    /// Frees the model and its Metal buffers; the engine is not used again.
    /// ggml's Metal device checks at process exit that every buffer is gone,
    /// so a program closes its engine before it exits.
    public func close() { cloak_engine_free(engine) }

    public var weightsBytes: UInt64 { cloak_engine_weights_bytes(engine) }

    public static var metalAllocatedBytes: UInt64 { cloak_metal_allocated_bytes() }

    /// The prompt tokens a rewrite of this request gives the model; nil when
    /// the chat template fails.
    public func promptTokens(_ request: ChatRequest) -> [Int32]? {
        var count = 0
        guard let tokens = cloak_engine_prompt(engine, request.system, request.user, &count) else { return nil }
        defer { free(tokens) }
        return Array(UnsafeBufferPointer(start: tokens, count: count))
    }

    /// Clears the cancel; the worker calls it as it takes a request.
    public func arm() { cloak_engine_arm(engine) }

    public func cancel() { cloak_engine_cancel(engine) }

    public func rewrite(_ request: ChatRequest) async -> Rewrite {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = cloak_engine_rewrite(self.engine, request.system, request.user, Int32(request.maxTokens))
                defer { cloak_result_free(&result) }
                let finish: Rewrite.Finish
                switch result.finish {
                case CLOAK_FINISH_STOP: finish = .stop
                case CLOAK_FINISH_LENGTH: finish = .length
                case CLOAK_FINISH_CANCELLED: finish = .cancelled
                default: finish = .failed(step: String(cString: result.failed_step), code: result.failed_code)
                }
                let text = result.text.map {
                    String(decoding: UnsafeRawBufferPointer(start: $0, count: result.text_length), as: UTF8.self)
                }
                continuation.resume(
                    returning: Rewrite(
                        finish: finish, text: text ?? "", promptTokens: Int(result.prompt_tokens),
                        generatedTokens: Int(result.generated_tokens), contextTokens: result.context_tokens,
                        promptSeconds: result.prompt_seconds, generateSeconds: result.generate_seconds,
                        metalAllocatedBytes: result.metal_allocated_bytes))
            }
        }
    }
}
