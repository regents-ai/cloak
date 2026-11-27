import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import RewriterKit
import Synchronization
import os

/// Runs one Local Llama conversation request (`L` frame) at a time on a pinned
/// pure-Swift vMLX / JANGH2 model (`osaurus-ai/vmlx-swift`). Speaks the exact
/// same `RewriterKit.Frames` binary protocol as `cloak-rewriter-llama`:
///
///     idle --conversation--> answering --answer written--> idle
///
/// Never serves `R` (rewrite) frames: prompt rewriting stays strictly on the
/// zero-HTTP `llama-worker` under Cloak's pinned GBNF grammars.
final class VmlxWorker: @unchecked Sendable {
    private enum State {
        case idle
        case answering(Task<Void, Never>)
    }

    /// Visible answer token budget for one Local chat turn (Decision R7).
    static let answerTokens = 4_096
    /// Separate thinking token budget for reasoning models like Inkling 2 Mini
    /// so long internal reasoning never starves the visible answer.
    static let thinkingTokens = 8_192

    let pin: ModelPin
    let directory: URL
    let container: ModelContainer
    let batchEngine: BatchEngine
    /// Enables DSpark MTP speculative decoding on >=24 GB Macs (~12.9 GiB peak);
    /// uses lean autoregressive JANGH2 (~10.3 GiB peak, 57-63 tok/s) on 16 GB Macs.
    let useDSpark: Bool
    private let state = Mutex(State.idle)

    init(pin: ModelPin, directory: URL, container: ModelContainer, batchEngine: BatchEngine) {
        self.pin = pin
        self.directory = directory
        self.container = container
        self.batchEngine = batchEngine
        self.useDSpark = ProcessInfo.processInfo.physicalMemory >= (24 << 30)
    }

    func receive(_ frame: Frames.Incoming) throws(ProtocolFault) {
        switch frame.kind {
        case .request, .conversation:
            try state.withLock { state throws(ProtocolFault) in
                guard case .idle = state else { throw ProtocolFault("request while busy") }
                state = .answering(Task { await self.answer(frame) })
            }
        case .cancel:
            _ = cancel()
        }
    }

    func finish() async {
        await cancel()?.value
    }

    private func cancel() -> Task<Void, Never>? {
        state.withLock { state in
            guard case .answering(let task) = state else { return nil }
            task.cancel()
            return task
        }
    }

    private func answer(_ frame: Frames.Incoming) async {
        let (status, reply): (UInt16, Data)
        switch frame.kind {
        case .conversation:
            (status, reply) = await respond(toConversation: frame.payload)
        case .request, .cancel:
            log.info("rejected non-conversation frame on vmlx worker")
            (status, reply) = (400, Reply.error("invalid request"))
        }
        state.withLock { $0 = .idle }
        if !Frames.answer(status: status, body: reply) {
            log.info("supervisor channel closed while writing answer")
        }
    }

    private func respond(toConversation body: Data) async -> (UInt16, Data) {
        guard let answers = pin.answers, let conversation = try? JSONDecoder().decode(Conversation.self, from: body) else {
            log.info("rejected invalid conversation frame on vmlx worker")
            return (400, Reply.error("invalid request"))
        }

        let maxContext = Int(answers.contextTokens)
        let rawMessages = conversation.messages
        let reasoningEffort = conversation.reasoningEffort ?? "medium"

        var params = GenerateParameters(
            maxTokens: Self.answerTokens + Self.thinkingTokens,
            temperature: 0.7,
            topP: 0.95
        )
        params.cacheChainId = "cloak-local"
        if useDSpark {
            params.draftStrategy = .dspark(drafterPath: directory)
        }
        let generateParams = params

        enum Outcome: Sendable {
            case ok(text: String, reasoning: String?, promptTokens: Int, completionTokens: Int, finishReason: String)
            case tooLong
            case thinkingExhausted
            case cancelled
            case failed(String)
        }

        let started = ContinuousClock.now
        let outcome: Outcome
        do {
            let lmInput: LMInput = try await container.perform { context in
                let chatMessages: [Chat.Message] = rawMessages.map { msg in
                    if msg.role == "assistant" {
                        return Chat.Message(
                            role: .assistant, content: msg.content, reasoningContent: msg.reasoningContent)
                    }
                    return .user(msg.content)
                }
                let userInput = UserInput(
                    chat: chatMessages,
                    additionalContext: ["reasoning_effort": reasoningEffort])
                return try await context.processor.prepare(input: userInput)
            }
            let promptCount = lmInput.text.tokens.size
            if promptCount + Self.answerTokens > maxContext {
                outcome = .tooLong
            } else {
                let stream = await batchEngine.generate(input: lmInput, parameters: generateParams)
                var visible = ""
                var reasoning = ""
                var lastEmitted = ""
                var lastEmit = ContinuousClock.now
                var thinkingChunks = 0
                var answerChunks = 0
                var info: GenerateCompletionInfo?
                var stoppedByBudget = false

                for await item in stream {
                    if Task.isCancelled {
                        break
                    }
                    switch item {
                    case .chunk(let text):
                        guard !text.isEmpty else { continue }
                        visible += text
                        answerChunks += 1
                        let now = ContinuousClock.now
                        if visible != lastEmitted,
                            answerChunks % 4 == 0 || lastEmit.duration(to: now) >= .milliseconds(60)
                        {
                            lastEmitted = visible
                            lastEmit = now
                            if !Frames.partial(Data(lastEmitted.utf8)) {
                                stoppedByBudget = false
                                visible = ""
                                break
                            }
                        }
                        if answerChunks >= Self.answerTokens {
                            stoppedByBudget = true
                            break
                        }
                    case .reasoning(let text):
                        guard !text.isEmpty else { continue }
                        reasoning += text
                        thinkingChunks += 1
                        if visible.isEmpty && thinkingChunks >= Self.thinkingTokens {
                            break
                        }
                    case .info(let completionInfo):
                        info = completionInfo
                    case .toolCall, .prefillProgress, .toolCallProgress:
                        break
                    @unknown default:
                        break
                    }
                    if stoppedByBudget || (visible.isEmpty && thinkingChunks >= Self.thinkingTokens) { break }
                }

                if Task.isCancelled {
                    outcome = .cancelled
                } else if visible.isEmpty && thinkingChunks >= Self.thinkingTokens {
                    outcome = .thinkingExhausted
                } else {
                    let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        outcome = thinkingChunks > 0 ? .thinkingExhausted : .failed("empty answer")
                    } else {
                        if visible != lastEmitted {
                            _ = Frames.partial(Data(visible.utf8))
                        }
                        let completionTokens = info?.generationTokenCount ?? (thinkingChunks + answerChunks)
                        let promptTokens = info?.promptTokenCount ?? promptCount
                        outcome = .ok(
                            text: visible,
                            reasoning: reasoning.isEmpty ? nil : reasoning,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            finishReason: stoppedByBudget ? "length" : "stop"
                        )
                    }
                }
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(String(describing: error))
        }

        switch outcome {
        case .ok(let text, let reasoning, let promptTokens, let completionTokens, let finishReason):
            let elapsed = started.duration(to: .now)
            log.info(
                "vmlx answer \(finishReason, privacy: .public): \(promptTokens) prompt tokens, \(completionTokens) generated in \(elapsed, privacy: .public); active \(Memory.activeMemory) bytes"
            )
            return (
                200,
                Reply.completion(
                    model: pin.name, text: text, reasoning: reasoning, promptTokens: promptTokens,
                    completionTokens: completionTokens, finishReason: finishReason)
            )
        case .tooLong:
            log.info("vmlx answer too long for pinned context")
            return (413, Reply.error("conversation too long"))
        case .thinkingExhausted:
            log.info("vmlx answer exhausted thinking budget")
            return (422, Reply.error("thinking limit reached"))
        case .cancelled:
            log.info("vmlx answer cancelled")
            return (499, Reply.error("cancelled"))
        case .failed(let detail):
            log.error("vmlx answer failed: \(detail, privacy: .public)")
            return (500, Reply.error("answer failed"))
        }
    }
}
