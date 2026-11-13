import Foundation
import MLX
import MLXLMCommon
import RewriterKit
import Synchronization
import os

/// MLX's own memory figures, numbers only: what its arrays hold, what it keeps
/// cached for reuse, and the most its arrays have held since the worker
/// started.
func mlxMemory(_ memory: Memory.Snapshot) -> String {
    "MLX active \(memory.activeMemory), cache \(memory.cacheMemory), peak \(memory.peakMemory) bytes"
}

/// Runs one rewrite at a time (spec MAC03). A second request while one runs is
/// a protocol fault and stops the worker, once that rewrite has stopped.
final class Worker: Sendable {
    /// The one rewrite at a time:
    ///
    ///     idle --request--> preparing --generation starts--> generating
    ///      ^                    |                                |
    ///      +------------- answer written ------------------------+
    ///
    /// A cancel while preparing cancels the request's own task, which stops
    /// the model reading the prompt at its next chunk, or the generation as
    /// it starts; a cancel while generating stops the generation; a cancel
    /// while idle is one that crossed the answer, and does nothing. The end
    /// of the supervisor's channel, and any protocol fault, cancels the same
    /// way, then waits for the request's task to write its answer.
    private enum State {
        case idle
        /// The request's task checks it, builds its prompt and has the model
        /// read the prompt.
        case preparing(Task<Void, Never>)
        /// The generation runs, and is the one a cancel stops; the request's
        /// task waits for it, then writes the answer.
        case generating(request: Task<Void, Never>, generation: Task<Void, Never>)
    }

    let pin: ModelPin
    let container: ModelContainer
    private let state = Mutex(State.idle)

    init(pin: ModelPin, container: ModelContainer) {
        self.pin = pin
        self.container = container
    }

    func receive(_ frame: Frames.Incoming) throws(ProtocolFault) {
        switch frame.kind {
        case .request:
            try state.withLock { state throws(ProtocolFault) in
                guard case .idle = state else { throw ProtocolFault("request while busy") }
                state = .preparing(Task { await answer(frame.payload) })
            }
        case .cancel:
            _ = cancel()
        }
    }

    /// The supervisor closed the channel or broke the protocol: stops the
    /// rewrite in progress as a cancel does, and returns once its answer is
    /// written. The program ends only after this, because ending it tears
    /// down the model library's GPU state, which a running rewrite would
    /// still be using.
    func finish() async {
        await cancel()?.value
    }

    /// Cancels the rewrite in progress and returns its request's task; nil
    /// when idle.
    private func cancel() -> Task<Void, Never>? {
        state.withLock { state in
            switch state {
            case .idle:
                return nil
            case .preparing(let request):
                request.cancel()
                return request
            case .generating(let request, let generation):
                generation.cancel()
                return request
            }
        }
    }

    private func answer(_ body: Data) async {
        let (status, reply) = await respond(to: body)
        // Idle before the answer goes out: the supervisor sends its next
        // request as soon as it has read this answer.
        state.withLock { $0 = .idle }
        Frames.answer(status: status, body: reply)
    }

    private func respond(to body: Data) async -> (UInt16, Data) {
        guard let request = try? JSONDecoder().decode(ChatRequest.self, from: body), request.model == pin.name else {
            log.info("rejected a request that is not the daemon's rewrite request")
            return (400, Reply.error("invalid request"))
        }
        let completion: Completion
        do {
            completion = try await generate(request)
        } catch {
            // Cancelled while preparing: the prompt reading stopped, or the
            // generation's stream ended with this task's cancellation.
            guard !Task.isCancelled else {
                log.info("rewrite cancelled while the prompt was read")
                return (499, Reply.error("cancelled"))
            }
            log.error("rewrite failed: \(String(describing: error), privacy: .public)")
            return (500, Reply.error("rewrite failed"))
        }
        let info = completion.info
        let memory = Memory.snapshot()
        log.info(
            "rewrite \(String(describing: info.stopReason), privacy: .public): \(info.promptTokenCount) prompt tokens in \(info.promptTime, format: .fixed(precision: 2)) s, \(info.generationTokenCount) generated in \(info.generateTime, format: .fixed(precision: 2)) s; \(mlxMemory(memory), privacy: .public)"
        )
        let finishReason: String
        switch info.stopReason {
        case .stop: finishReason = "stop"
        case .length: finishReason = "length"
        case .cancelled: return (499, Reply.error("cancelled"))
        }
        return (
            200,
            Reply.completion(
                model: pin.name, text: completion.text, promptTokens: info.promptTokenCount,
                completionTokens: info.generationTokenCount, finishReason: finishReason)
        )
    }

    /// Applies the model's own chat template with the pinned settings, then
    /// decodes greedily. The reply carries exactly the generated text; the
    /// daemon decides whether it is acceptable. The model reads the prompt
    /// in chunks inside `generateTokensTask`, checking this task's
    /// cancellation between them.
    private func generate(_ request: ChatRequest) async throws -> Completion {
        let templateContext: [String: any Sendable] = pin.chatTemplateContext
        return try await container.perform(values: request) { context, request in
            let prompt = try context.tokenizer.applyChatTemplate(
                messages: request.templateMessages, tools: nil, additionalContext: templateContext)
            let (events, generation) = try generateTokensTask(
                input: LMInput(tokens: MLXArray(prompt)),
                parameters: GenerateParameters(maxTokens: request.maxTokens, temperature: 0),
                context: context)
            self.state.withLock { state in
                guard case .preparing(let request) = state else {
                    preconditionFailure("a generation started outside a request")
                }
                state = .generating(request: request, generation: generation)
                if Task.isCancelled { generation.cancel() }
            }
            var tokens: [Int] = []
            var summary: GenerateCompletionInfo?
            for await event in events {
                switch event {
                case .token(let token): tokens.append(token)
                case .info(let info): summary = info
                }
            }
            await generation.value
            guard let summary else { throw WorkerError("generation ended without its summary") }
            return Completion(
                text: context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false), info: summary)
        }
    }
}

struct Completion: Sendable {
    let text: String
    let info: GenerateCompletionInfo
}
