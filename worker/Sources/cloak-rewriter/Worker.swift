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
    /// The rewrite in progress: whether the supervisor cancelled it, and the
    /// generation to stop when it does.
    private struct Run {
        var cancelled = false
        var generation: Task<Void, Never>?
    }

    let pin: ModelPin
    let container: ModelContainer
    private let busy = Atomic(false)
    private let run = Mutex(Run())

    init(pin: ModelPin, container: ModelContainer) {
        self.pin = pin
        self.container = container
    }

    func receive(_ frame: Frames.Incoming) {
        switch frame.kind {
        case .request:
            guard !busy.exchange(true, ordering: .acquiringAndReleasing) else { stop("request while busy") }
            run.withLock { $0 = Run() }
            Task { await answer(frame.payload) }
        case .cancel:
            run.withLock { run in
                run.cancelled = true
                run.generation?.cancel()
            }
        }
    }

    private func answer(_ body: Data) async {
        let (status, reply) = await respond(to: body)
        busy.store(false, ordering: .releasing)
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
    /// daemon decides whether it is acceptable.
    private func generate(_ request: ChatRequest) async throws -> Completion {
        let templateContext: [String: any Sendable] = pin.chatTemplateContext
        return try await container.perform(values: request) { context, request in
            let prompt = try context.tokenizer.applyChatTemplate(
                messages: request.templateMessages, tools: nil, additionalContext: templateContext)
            let (events, generation) = try generateTokensTask(
                input: LMInput(tokens: MLXArray(prompt)),
                parameters: GenerateParameters(maxTokens: request.maxTokens, temperature: 0),
                context: context)
            self.run.withLock { run in
                run.generation = generation
                if run.cancelled { generation.cancel() }
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
