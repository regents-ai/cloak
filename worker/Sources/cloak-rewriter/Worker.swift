import Foundation
import MLX
import MLXLMCommon
import Synchronization
import os

let log = Logger(subsystem: "sh.regents.cloak", category: "rewriter")

/// Exits the worker. The supervisor treats any exit as the loss of the worker
/// and fails the request in progress.
func stop(_ reason: String) -> Never {
    log.error("stopping: \(reason, privacy: .public)")
    FileHandle.standardError.write(Data("cloak-rewriter: \(reason)\n".utf8))
    exit(2)
}

/// Runs one rewrite at a time (spec MAC03). A second request while one runs is
/// a protocol violation and stops the worker.
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
    /// while idle is one that crossed the answer, and does nothing.
    private enum State {
        case idle
        /// The request's task checks it, builds its prompt and has the model
        /// read the prompt.
        case preparing(Task<Void, Never>)
        /// The generation runs, and is the one a cancel stops.
        case generating(Task<Void, Never>)
    }

    let pin: ModelPin
    let container: ModelContainer
    private let state = Mutex(State.idle)

    init(pin: ModelPin, container: ModelContainer) {
        self.pin = pin
        self.container = container
    }

    func receive(_ frame: Frames.Incoming) {
        switch frame.kind {
        case .request:
            state.withLock { state in
                guard case .idle = state else { stop("request while busy") }
                state = .preparing(Task { await answer(frame.payload) })
            }
        case .cancel:
            state.withLock { state in
                switch state {
                case .idle: break
                case .preparing(let request): request.cancel()
                case .generating(let generation): generation.cancel()
                }
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
        log.info(
            "rewrite \(String(describing: info.stopReason), privacy: .public): \(info.promptTokenCount) prompt tokens in \(info.promptTime, format: .fixed(precision: 2)) s, \(info.generationTokenCount) generated in \(info.generateTime, format: .fixed(precision: 2)) s"
        )
        switch info.stopReason {
        case .stop: return (200, Reply.completion(model: pin.name, completion: completion, finishReason: "stop"))
        case .length: return (200, Reply.completion(model: pin.name, completion: completion, finishReason: "length"))
        case .cancelled: return (499, Reply.error("cancelled"))
        }
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
                guard case .preparing = state else {
                    preconditionFailure("a generation started outside a request")
                }
                state = .generating(generation)
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
