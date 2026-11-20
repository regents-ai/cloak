import Foundation
import LlamaEngine
import RewriterKit
import Synchronization
import os

/// Runs one request at a time (spec MAC03): a rewrite or a draft's details
/// (`R`), or a Local Llama answer (`L`). A second request while one runs is
/// a protocol fault and stops the worker, once that request has stopped.
final class Worker: Sendable {
    /// The one request at a time:
    ///
    ///     idle --request or conversation--> answering --answer written--> idle
    ///
    /// A cancel while answering stops llama.cpp before its next prompt chunk
    /// or token; a cancel while idle is one that crossed the answer, and does
    /// nothing. The end of the supervisor's channel, and any protocol fault,
    /// cancels the same way, then waits for the request to write its answer.
    private enum State {
        case idle
        case answering(Task<Void, Never>)
    }

    /// A Local Llama request's cap, conversation plus answer, in tokens: the
    /// largest context a rewrite has been measured to take (a 10,000-character
    /// message, decision 6's limit: 2,849 prompt tokens plus the daemon's
    /// 16,384, which llama.cpp rounds up to 19,456; evidence/stage3/
    /// small-lead-gguf-grammar/feasibility-20261114T052945Z.json), so a chat
    /// never holds more memory than a rewrite has been measured to hold.
    static let chatContext: UInt32 = 19_456
    /// The most tokens one Local Llama answer takes, leaving 15,360 tokens
    /// of the cap for the conversation.
    static let answerTokens: Int32 = 4_096

    let pin: ModelPin
    let engine: Engine
    private let state = Mutex(State.idle)

    init(pin: ModelPin, engine: Engine) {
        self.pin = pin
        self.engine = engine
    }

    func receive(_ frame: Frames.Incoming) throws(ProtocolFault) {
        switch frame.kind {
        case .request, .conversation:
            try state.withLock { state throws(ProtocolFault) in
                guard case .idle = state else { throw ProtocolFault("request while busy") }
                engine.arm()
                state = .answering(Task { await answer(frame) })
            }
        case .cancel:
            _ = cancel()
        }
    }

    /// The supervisor closed the channel or broke the protocol: stops the
    /// request in progress as a cancel does, and returns once its answer is
    /// written, so the program never ends under a running computation.
    func finish() async {
        await cancel()?.value
    }

    /// Cancels the request in progress and returns its task; nil when idle.
    private func cancel() -> Task<Void, Never>? {
        state.withLock { state in
            guard case .answering(let task) = state else { return nil }
            engine.cancel()
            return task
        }
    }

    private func answer(_ frame: Frames.Incoming) async {
        let (status, reply) =
            switch frame.kind {
            case .conversation: await respond(toConversation: frame.payload)
            default: await respond(to: frame.payload)
            }
        // Idle before the answer goes out: the supervisor sends its next
        // request as soon as it has read this answer.
        state.withLock { $0 = .idle }
        Frames.answer(status: status, body: reply)
    }

    /// Applies the model's own chat template with the pinned settings, then
    /// decodes greedily under the grammar for what the request asks: the
    /// pinned one for the daemon's rewrite, Cloak's details grammar for a
    /// draft's details (decision 13). The reply carries exactly the generated
    /// text; the daemon, or for details the app, decides whether it is
    /// acceptable.
    private func respond(to body: Data) async -> (UInt16, Data) {
        guard let request = try? JSONDecoder().decode(ChatRequest.self, from: body), request.model == pin.name,
            let (ask, grammar) = engine.grammar(for: request)
        else {
            log.info("rejected a request that is neither the daemon's rewrite request nor Cloak's details request")
            return (400, Reply.error("invalid request"))
        }
        let name = switch ask {
        case .rewrite: "rewrite"
        case .details: "details"
        }
        let rewrite = await engine.rewrite(request, grammar: grammar)
        let finishReason: String
        switch rewrite.finish {
        case .stop: finishReason = "stop"
        case .length: finishReason = "length"
        case .tooLong: preconditionFailure("only a Local Llama answer has a cap")
        case .cancelled:
            log.info("\(name, privacy: .public) cancelled")
            return (499, Reply.error("cancelled"))
        case .failed(let step, let code):
            log.error("\(name, privacy: .public) failed at its \(step, privacy: .public) step, llama.cpp code \(code)")
            return (500, Reply.error("rewrite failed"))
        }
        log.info(
            "\(name, privacy: .public) \(finishReason, privacy: .public): \(rewrite.promptTokens) prompt tokens in \(rewrite.promptSeconds, format: .fixed(precision: 2)) s, \(rewrite.generatedTokens) generated in \(rewrite.generateSeconds, format: .fixed(precision: 2)) s; context \(rewrite.contextTokens) tokens, Metal allocated \(rewrite.metalAllocatedBytes) bytes"
        )
        return (
            200,
            Reply.completion(
                model: pin.name, text: rewrite.text, promptTokens: rewrite.promptTokens,
                completionTokens: rewrite.generatedTokens, finishReason: finishReason)
        )
    }

    /// A Local Llama chat's next answer: the conversation as written through
    /// the model's chat template, no system message and no grammar, then
    /// llama.cpp's default sampling. Whatever the messages say, they are only
    /// ever a conversation: an `L` frame never takes the rewrite or details
    /// path. 413 when the conversation leaves no room for a whole answer
    /// inside the cap; nothing is trimmed.
    private func respond(toConversation body: Data) async -> (UInt16, Data) {
        guard let conversation = try? JSONDecoder().decode(Conversation.self, from: body) else {
            log.info("rejected a conversation that is not a Local Llama chat")
            return (400, Reply.error("invalid request"))
        }
        let answer = await engine.answer(conversation, maxTokens: Self.answerTokens, maxContext: Self.chatContext)
        let finishReason: String
        switch answer.finish {
        case .stop: finishReason = "stop"
        case .length: finishReason = "length"
        case .tooLong:
            log.info("answer too long: \(answer.promptTokens) prompt tokens")
            return (413, Reply.error("conversation too long"))
        case .cancelled:
            log.info("answer cancelled")
            return (499, Reply.error("cancelled"))
        case .failed(let step, let code):
            log.error("answer failed at its \(step, privacy: .public) step, llama.cpp code \(code)")
            return (500, Reply.error("answer failed"))
        }
        log.info(
            "answer \(finishReason, privacy: .public): \(answer.promptTokens) prompt tokens in \(answer.promptSeconds, format: .fixed(precision: 2)) s, \(answer.generatedTokens) generated in \(answer.generateSeconds, format: .fixed(precision: 2)) s; context \(answer.contextTokens) tokens, Metal allocated \(answer.metalAllocatedBytes) bytes"
        )
        return (
            200,
            Reply.completion(
                model: pin.name, text: answer.text, promptTokens: answer.promptTokens,
                completionTokens: answer.generatedTokens, finishReason: finishReason)
        )
    }
}
