import CLlama
import CryptoKit
import Foundation
import RewriterKit

/// One loaded GGUF model and its pinned chat template (cloak_llama.h). The
/// worker runs one request at a time on it, a rewrite or a Local Llama
/// answer; `cancel` is safe from any thread.
public final class Engine: @unchecked Sendable {
    /// How one rewrite or answer ended, with llama.cpp's counts and timings.
    public struct Rewrite: Sendable {
        /// `tooLong` only for an answer: the conversation leaves no room for
        /// a whole answer inside the cap, and nothing was computed.
        /// `thinkingExhausted` when a thinking model used its thinking budget
        /// without producing a visible answer.
        public enum Finish: Sendable { case stop, length, cancelled, tooLong, thinkingExhausted, failed(step: String, code: Int32) }
        public let finish: Finish
        public let text: String
        public let reasoning: String?
        public let promptTokens: Int
        public let generatedTokens: Int
        public let contextTokens: UInt32
        public let promptSeconds: Double
        public let generateSeconds: Double
        public let metalAllocatedBytes: UInt64
    }

    /// What a request asks for, by its user message.
    public enum Ask: Sendable {
        /// The daemon's rewrite of `{"texts":[...]}`.
        case rewrite
        /// Cloak's own details of a message being written, `{"draft":"..."}`
        /// (decision 13 in docs/plan.md).
        case details
    }

    private let engine: OpaquePointer
    /// The pinned reply grammar, reference/rewrite-reply.gbnf, built into
    /// this worker (decision 9 in docs/plan.md); nil for a model that never
    /// rewords.
    private let grammar: String?
    /// Cloak's details grammar, reference/details-reply.gbnf, built into this
    /// worker and part of no pin (decision 13).
    private let detailsGrammar = String(decoding: Data(PackageResources.details_reply_gbnf), as: UTF8.self)
    /// Requests run here, off Swift's own threads, as llama.cpp blocks while
    /// it computes.
    private let queue = DispatchQueue(label: "sh.regents.cloak.rewriter-llama")

    /// Loads the pin's one GGUF file with the pin's chat template file,
    /// `chat_template.jinja`, optional verified LoRA adapter, and its frozen
    /// template settings. A pinned grammar must be the one built into this
    /// worker, byte for byte.
    public init(pin: ModelPin, directory: URL, lora: URL? = nil) throws {
        if let pinned = pin.grammar {
            let built = Data(PackageResources.rewrite_reply_gbnf)
            let digest = SHA256.hash(data: built).map { String(format: "%02x", $0) }.joined()
            guard pinned.file == "rewrite-reply.gbnf", pinned.sha256 == digest else {
                throw WorkerError("\(pin.name) pins a grammar this worker was not built with")
            }
            grammar = String(decoding: built, as: UTF8.self)
        } else {
            grammar = nil
        }
        let weights = pin.files.map(\.path).filter { $0.hasSuffix(".gguf") }
        guard weights.count == 1 else { throw WorkerError("\(pin.name) pins \(weights.count) GGUF files, not one") }
        let template = try String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8)
        let settings = pin.chatTemplateContext.sorted { $0.key < $1.key }
        let names = settings.map { strdup($0.key) }
        let values = settings.map { strdup($0.value.json) }
        defer { (names + values).forEach { free($0) } }
        var error = [CChar](repeating: 0, count: 1024)
        guard let loaded = cloak_engine_load(
            directory.appending(path: weights[0]).path, template, lora?.path, names.map { UnsafePointer($0) },
            values.map { UnsafePointer($0) }, settings.count, &error, error.count)
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

    /// Clears the cancel; the worker calls it as it takes a request.
    public func arm() { cloak_engine_arm(engine) }

    public func cancel() { cloak_engine_cancel(engine) }

    /// What this request asks for and the grammar it decodes under. For the
    /// daemon's `{"texts":[...]}` with at least one text, the pinned grammar,
    /// for exactly as many texts as the user message carries: the worker adds
    /// the grammar's `texts` rule, written out item by item, as llama.cpp
    /// repeats a rule at most 2000 times. For Cloak's `{"draft":"..."}`, the
    /// details grammar as built in. Nil for any other user message, and for
    /// any request at all to a model that never rewords.
    public func grammar(for request: ChatRequest) -> (ask: Ask, grammar: String)? {
        guard let grammar else { return nil }
        let user = Data(request.user.utf8)
        if let message = try? JSONDecoder().decode([String: [String]].self, from: user),
            message.count == 1, let texts = message["texts"], !texts.isEmpty
        {
            return (.rewrite, grammar + "texts ::= item" + String(repeating: " \",\" item", count: texts.count - 1) + "\n")
        }
        if let message = try? JSONDecoder().decode([String: String].self, from: user), message.count == 1,
            message["draft"] != nil
        {
            return (.details, detailsGrammar)
        }
        return nil
    }

    public func rewrite(_ request: ChatRequest, grammar: String) async -> Rewrite {
        await run { cloak_engine_rewrite(self.engine, request.system, request.user, Int32(request.maxTokens), grammar) }
    }

    private final class PartialBox: @unchecked Sendable {
        let handler: @Sendable (String) -> Void
        init(_ handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
    }

    /// A Local Llama answer to `conversation`: up to `maxAnswerTokens` visible
    /// answer tokens plus a separate `maxThinkingTokens` budget for reasoning
    /// models (Decision R7), bounded by `maxContext`. When `onPartial` is given,
    /// streams visible answer snapshots as they generate.
    public func answer(
        _ conversation: Conversation, maxAnswerTokens: Int32, maxThinkingTokens: Int32, maxContext: UInt32,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async -> Rewrite {
        await run {
            let roles = conversation.messages.map { strdup($0.role) }
            let contents = conversation.messages.map { strdup($0.content) }
            let reasonings: [UnsafeMutablePointer<CChar>?] = conversation.messages.map { $0.reasoningContent.flatMap { strdup($0) } }
            defer {
                (roles + contents + reasonings).forEach { free($0) }
            }
            let box = onPartial.map(PartialBox.init)
            let userData = box.map { Unmanaged.passUnretained($0).toOpaque() }
            let callback: cloak_partial_callback? = box == nil ? nil : { text, length, context in
                guard let text, let context else { return }
                let box = Unmanaged<PartialBox>.fromOpaque(context).takeUnretainedValue()
                let string = String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
                box.handler(string)
            }
            return withExtendedLifetime(box) {
                cloak_engine_answer(
                    self.engine, roles.map { UnsafePointer($0) }, contents.map { UnsafePointer($0) },
                    reasonings.map { ptr in ptr.map { UnsafePointer<CChar>($0) } }, roles.count,
                    maxAnswerTokens, maxThinkingTokens, maxContext, callback, userData)
            }
        }
    }

    private func run(_ compute: @escaping @Sendable () -> cloak_result) async -> Rewrite {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = compute()
                defer { cloak_result_free(&result) }
                let finish: Rewrite.Finish
                switch result.finish {
                case CLOAK_FINISH_STOP: finish = .stop
                case CLOAK_FINISH_LENGTH: finish = .length
                case CLOAK_FINISH_CANCELLED: finish = .cancelled
                case CLOAK_FINISH_TOO_LONG: finish = .tooLong
                case CLOAK_FINISH_THINKING_EXHAUSTED: finish = .thinkingExhausted
                default: finish = .failed(step: String(cString: result.failed_step), code: result.failed_code)
                }
                let text = result.text.map {
                    String(decoding: UnsafeRawBufferPointer(start: $0, count: result.text_length), as: UTF8.self)
                }
                let reasoning: String? = result.reasoning.flatMap { ptr in
                    guard result.reasoning_length > 0 else { return nil }
                    return String(decoding: UnsafeRawBufferPointer(start: ptr, count: result.reasoning_length), as: UTF8.self)
                }
                continuation.resume(
                    returning: Rewrite(
                        finish: finish, text: text ?? "", reasoning: reasoning, promptTokens: Int(result.prompt_tokens),
                        generatedTokens: Int(result.generated_tokens), contextTokens: result.context_tokens,
                        promptSeconds: result.prompt_seconds, generateSeconds: result.generate_seconds,
                        metalAllocatedBytes: result.metal_allocated_bytes))
            }
        }
    }
}
