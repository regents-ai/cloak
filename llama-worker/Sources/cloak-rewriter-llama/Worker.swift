import Foundation
import LlamaEngine
import RewriterKit
import Synchronization
import os

/// Runs one rewrite at a time (spec MAC03). A second request while one runs is
/// a protocol fault and stops the worker, once that rewrite has stopped.
final class Worker: Sendable {
    /// The one rewrite at a time:
    ///
    ///     idle --request--> rewriting --answer written--> idle
    ///
    /// A cancel while rewriting stops llama.cpp before its next prompt chunk
    /// or token; a cancel while idle is one that crossed the answer, and does
    /// nothing. The end of the supervisor's channel, and any protocol fault,
    /// cancels the same way, then waits for the rewrite to write its answer.
    private enum State {
        case idle
        case rewriting(Task<Void, Never>)
    }

    let pin: ModelPin
    let engine: Engine
    private let state = Mutex(State.idle)

    init(pin: ModelPin, engine: Engine) {
        self.pin = pin
        self.engine = engine
    }

    func receive(_ frame: Frames.Incoming) throws(ProtocolFault) {
        switch frame.kind {
        case .request:
            try state.withLock { state throws(ProtocolFault) in
                guard case .idle = state else { throw ProtocolFault("request while busy") }
                engine.arm()
                state = .rewriting(Task { await answer(frame.payload) })
            }
        case .cancel:
            _ = cancel()
        }
    }

    /// The supervisor closed the channel or broke the protocol: stops the
    /// rewrite in progress as a cancel does, and returns once its answer is
    /// written, so the program never ends under a running computation.
    func finish() async {
        await cancel()?.value
    }

    /// Cancels the rewrite in progress and returns its task; nil when idle.
    private func cancel() -> Task<Void, Never>? {
        state.withLock { state in
            guard case .rewriting(let task) = state else { return nil }
            engine.cancel()
            return task
        }
    }

    private func answer(_ body: Data) async {
        let (status, reply) = await respond(to: body)
        // Idle before the answer goes out: the supervisor sends its next
        // request as soon as it has read this answer.
        state.withLock { $0 = .idle }
        Frames.answer(status: status, body: reply)
    }

    /// Applies the model's own chat template with the pinned settings, then
    /// decodes greedily, under the pinned grammar when there is one. The
    /// reply carries exactly the generated text; the daemon decides whether
    /// it is acceptable.
    private func respond(to body: Data) async -> (UInt16, Data) {
        guard let request = try? JSONDecoder().decode(ChatRequest.self, from: body), request.model == pin.name,
            let decoding = engine.decoding(for: request)
        else {
            log.info("rejected a request that is not the daemon's rewrite request")
            return (400, Reply.error("invalid request"))
        }
        let rewrite = await engine.rewrite(request, decoding)
        let finishReason: String
        switch rewrite.finish {
        case .stop: finishReason = "stop"
        case .length: finishReason = "length"
        case .cancelled:
            log.info("rewrite cancelled")
            return (499, Reply.error("cancelled"))
        case .failed(let step, let code):
            log.error("rewrite failed at its \(step, privacy: .public) step, llama.cpp code \(code)")
            return (500, Reply.error("rewrite failed"))
        }
        log.info(
            "rewrite \(finishReason, privacy: .public): \(rewrite.promptTokens) prompt tokens in \(rewrite.promptSeconds, format: .fixed(precision: 2)) s, \(rewrite.generatedTokens) generated in \(rewrite.generateSeconds, format: .fixed(precision: 2)) s; context \(rewrite.contextTokens) tokens, Metal allocated \(rewrite.metalAllocatedBytes) bytes"
        )
        return (
            200,
            Reply.completion(
                model: pin.name, text: rewrite.text, promptTokens: rewrite.promptTokens,
                completionTokens: rewrite.generatedTokens, finishReason: finishReason)
        )
    }
}
