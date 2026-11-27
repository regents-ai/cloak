import CloakSupervisor
import CryptoKit
import Foundation

// The door rewords a chat request exactly where the pinned daemon does, and
// lets through only what the daemon lets through (paths under
// reference/src/zkapi/zkapi-clientd/internal/):
//
// - Every message whose role is "user" is reworded, or replayed as reworded
//   before (rewriter/transcript.go:69-111); none is ever sent as written.
//   Its text is a string content, or each of its non-blank text parts; its
//   image, audio and file parts, and a message with no text, go as they are
//   (rewriter/rewriter.go:115-174, 254-262).
// - Every other message, system, developer, assistant (with its tool
//   calls) and tool (a tool's result), goes as the app sent it
//   (rewriter/transcript.go:81-83), as do the tool definitions and the
//   other fields the daemon keeps (server/server.go:171-245).

/// A chat request as the door takes it: read and checked as the daemon's
/// `sanitize` checks it, with the refusals the provider would make anyway,
/// and each message with its digest and, for a user message with text, what
/// is reworded.
struct Asked: Sendable {
    let bytes: [UInt8]
    let model: String
    /// The app asked for server-sent events.
    let streaming: Bool
    /// The other fields that go on, by name: the daemon's, but for `stream`,
    /// which goes as false, and `stream_options`, which then has no use.
    let fields: [String: GoJSON]
    let messages: [Message]

    struct Message: Sendable {
        let value: GoJSON
        /// SHA-256 of the message as Go writes it back (`canonicalDigest`).
        let digest: Data
        let isUser: Bool
        /// A user message's texts; nil when it has none, or is not a user's.
        let draft: Draft?
    }

    /// One user message's texts to reword, as the daemon's `Select` finds
    /// them.
    struct Draft: Sendable {
        let members: [String: GoJSON]
        /// The content's parts; nil when the content is one string.
        let parts: [[String: GoJSON]]?
        /// Where the texts are among the parts.
        let indices: [Int]
        let texts: [String]
    }

    /// The fields the daemon lets through (`fields` in server/server.go).
    static let kept: Set<String> = [
        "model", "messages", "stream", "stream_options", "temperature", "top_p", "top_k", "n", "presence_penalty",
        "frequency_penalty", "repetition_penalty", "logit_bias", "logprobs", "top_logprobs", "max_tokens",
        "max_completion_tokens", "stop", "seed", "tools", "tool_choice", "parallel_tool_calls", "functions", "function_call",
        "response_format", "reasoning", "reasoning_effort", "include_reasoning", "modalities", "audio", "prediction",
    ]
    /// The roles the provider takes.
    static let roles: Set<String> = ["system", "developer", "user", "assistant", "tool", "function"]
    /// The transcript's limits (`maxTranscriptMessages`, `maxTranscriptBytes`).
    static let maxMessages = 4096
    static let maxTranscript = 8 << 20

    /// The request's `Content-Type` must be JSON.
    static func check(type: String?) throws(Failure) {
        let media = type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard media == "application/json" else { throw Failure(415, "unsupported_media_type", "Use Content-Type: application/json.") }
    }

    /// Reads the body, off the main thread.
    @concurrent
    static func read(_ bytes: [UInt8]) async throws(Failure) -> Asked {
        guard String(validating: bytes, as: UTF8.self) != nil, let body = try? GoJSON.read(bytes), let values = body.members else {
            throw .invalid("The body must be a JSON object.")
        }
        guard case .string(let model)? = values["model"]?.value, !isBlank(model), model.utf8.count <= 256 else {
            throw .invalid("model is required.")
        }
        guard case .array(let items)? = values["messages"]?.value, !items.isEmpty else {
            throw .invalid("messages must be a nonempty array.")
        }
        guard items.count <= maxMessages else { throw .invalid("At most 4,096 messages go in one request.") }
        if let stream = values["stream"], !["true", "false"].contains(text(stream, in: bytes)) {
            throw .invalid("stream must be a boolean.")
        }
        if let n = values["n"], !["null", "1"].contains(text(n, in: bytes)) {
            throw .invalid("Cloak gives one answer per request. Leave n out, or set it to 1.")
        }
        if let store = values["store"], text(store, in: bytes) == "true" {
            throw .invalid("Cloak stores nothing with the provider. Leave store out.")
        }
        let messages = try items.map { item throws(Failure) in
            guard let members = item.members, case .string(let role)? = members["role"]?.value, !role.isEmpty else {
                throw Failure.invalid("Each message needs a role.")
            }
            guard roles.contains(role) else { throw Failure.invalid("The role \(role) is not one the provider takes.") }
            let isUser = role == "user"
            let draft = try isUser ? select(members, in: bytes) : nil
            return Message(value: item, digest: Data(SHA256.hash(data: item.canonical(in: bytes))), isUser: isUser, draft: draft)
        }
        return Asked(
            bytes: bytes, model: model, streaming: values["stream"].map { text($0, in: bytes) == "true" } ?? false,
            fields: values.filter { kept.contains($0.key) && !["messages", "stream", "stream_options"].contains($0.key) },
            messages: messages)
    }

    /// `Select` on one user message: its texts, or nil when it has none to
    /// reword. Stricter than the daemon in two ways: a text part's text
    /// must be a string, and an image or file must be in the request
    /// itself, never a link or a stored file, which the provider refuses.
    private static func select(_ members: [String: GoJSON], in bytes: [UInt8]) throws(Failure) -> Draft? {
        let draft: Draft
        switch members["content"]?.value {
        case .string(let text):
            guard !isBlank(text) else { return nil }
            draft = Draft(members: members, parts: nil, indices: [], texts: [text])
        case .null:
            return nil
        case .array(let items):
            var parts = [[String: GoJSON]](), indices = [Int](), texts = [String]()
            for (index, item) in items.enumerated() {
                guard let part = item.members else { throw .invalid("Each part of a message must be an object.") }
                parts.append(part)
                switch try? part["type"]?.string() {
                case "text":
                    guard case .string(let text)? = part["text"]?.value else { throw .invalid("Each text part needs its text.") }
                    guard !isBlank(text) else { continue }
                    indices.append(index)
                    texts.append(text)
                case "image_url":
                    guard case .string(let url)? = part["image_url"]?.members?["url"]?.value, url.hasPrefix("data:") else {
                        throw .invalid("Send each image in the request, as a data: URL. Cloak sends no links.")
                    }
                case "file":
                    guard let file = part["file"]?.members, case .string(_)? = file["file_data"]?.value, file["file_id"] == nil else {
                        throw .invalid("Send each file in the request, as file_data. Cloak sends no stored files.")
                    }
                case "input_audio":
                    continue
                default:
                    throw .invalid("Each part must be text, an image, audio or a file. Others can't be reworded, so nothing was sent.")
                }
            }
            guard !texts.isEmpty else { return nil }
            draft = Draft(members: members, parts: parts, indices: indices, texts: texts)
        default:
            throw .invalid("Each user message needs its content: text, or a list of parts.")
        }
        let characters = Rewrite.characters(draft.texts)
        guard characters <= Rewrite.maxCharacters else { throw .tooLong(characters) }
        return draft
    }

    /// Blank as Go's `strings.TrimSpace` sees it.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    static func text(_ value: GoJSON, in bytes: [UInt8]) -> String {
        String(decoding: bytes[value.span], as: UTF8.self)
    }

    /// The body that goes to the provider: these messages, the fields kept,
    /// an optional resolved model ID, and `"stream":false`.
    func body(_ messages: [[UInt8]], modelOverride: String? = nil) -> Data {
        var members = fields.mapValues { Array(bytes[$0.span]) }
        if let modelOverride {
            members["model"] = Array(Rewrite.quote(modelOverride).utf8)
        }
        members["messages"] = Array("[".utf8) + messages.joined(separator: [UInt8(ascii: ",")]) + Array("]".utf8)
        members["stream"] = Array("false".utf8)
        return Data(Self.object(members))
    }

    /// An object of these members, as written, sorted by name.
    static func object(_ members: [String: [UInt8]]) -> [UInt8] {
        let sorted = members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        return Array("{".utf8) + sorted.map { Array(Rewrite.quote($0.key).utf8) + [UInt8(ascii: ":")] + $0.value }
            .joined(separator: [UInt8(ascii: ",")]) + Array("}".utf8)
    }
}

extension Asked.Draft {
    /// The message with its texts reworded, everything else as written
    /// (`Draft.Rewrite`, rewriter/rewriter.go:254-262).
    func message(_ reworded: [String], in bytes: [UInt8]) -> [UInt8] {
        var message = members.mapValues { Array(bytes[$0.span]) }
        if let parts {
            var written = parts.map { $0.mapValues { Array(bytes[$0.span]) } }
            for (index, text) in zip(indices, reworded) {
                written[index]["text"] = Array(Rewrite.quote(text).utf8)
            }
            message["content"] = Array("[".utf8) + written.map(Asked.object).joined(separator: [UInt8(ascii: ",")]) + Array("]".utf8)
        } else {
            message["content"] = Array(Rewrite.quote(reworded[0]).utf8)
        }
        return Asked.object(message)
    }
}

/// What the door remembers of one app's last request, in memory only, as
/// the pinned daemon remembers its one client's: the conversation's Tor
/// identity (`selectConversation`, zkapi/conversation.go:61-92) and the
/// transcript of its messages, user messages as reworded
/// (`Transcript`, rewriter/transcript.go). No message as written is kept:
/// only digests, and what was reworded.
struct Memory: Sendable {
    struct Entry: Sendable {
        let digest: Data
        /// The user message as sent; nil for any other.
        let user: [UInt8]?
    }

    private(set) var digests: [Data] = []
    private(set) var identity: String?
    var transcript: [Entry] = []

    /// The conversation's Tor identity: the last one when this request's
    /// messages begin with the last request's, else a new one.
    mutating func identity(for messages: [Asked.Message]) -> String {
        let digests = messages.map(\.digest)
        let continues = identity != nil && digests.starts(with: self.digests)
        if !continues {
            // 32 random bytes, as hex, as Chat's conversations have.
            identity = SymmetricKey(size: .bits256).withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
        }
        self.digests = digests
        return identity!
    }

    /// Drops the sticky Tor SOCKS identity after a Tor or WAF exit failure so
    /// the next request builds a fresh Tor circuit while keeping rewritten turns.
    mutating func rotateIdentity() {
        identity = nil
    }

    /// `Transcript.Rewrite`: each user message replayed as reworded before
    /// when the earlier request's messages begin this one, else reworded,
    /// one call per message, through `reword`; every other message as
    /// written. Returns the messages to send and the transcript after them,
    /// which is kept only once every message is done.
    func rewrite(
        _ asked: Asked, reword: @Sendable ([String]) async throws(RewriteStop) -> [String]
    ) async throws(Failure) -> (messages: [[UInt8]], transcript: [Entry]) {
        let continues = transcript.count <= asked.messages.count
            && zip(transcript, asked.messages).allSatisfy { $0.digest == $1.digest }
        var messages = [[UInt8]](), next = [Entry](), size = 0
        for (index, message) in asked.messages.enumerated() {
            guard !Task.isCancelled else { throw .stopped }
            let written = Array(asked.bytes[message.value.span])
            guard message.isUser else {
                messages.append(written)
                next.append(Entry(digest: message.digest, user: nil))
                continue
            }
            let user: [UInt8]
            if continues, index < transcript.count, let replay = transcript[index].user {
                user = replay
            } else if let draft = message.draft {
                do {
                    user = draft.message(try await reword(draft.texts), in: asked.bytes)
                } catch {
                    throw Failure(error)
                }
            } else {
                // No text to reword: an empty message, or images, audio and
                // files only.
                user = written
            }
            messages.append(user)
            next.append(Entry(digest: message.digest, user: user))
            size += user.count
            guard size <= Asked.maxTranscript else { throw .invalid("The conversation is over 8 MiB as reworded.") }
        }
        guard !Task.isCancelled else { throw .stopped }
        return (messages, next)
    }
}

extension Asked {
    /// The provider's completion as the app asked for it: as it came, or as
    /// one server-sent chunk and `[DONE]`, since the send path does not
    /// stream.
    static func answer(_ completion: Data, streaming: Bool) throws(Failure) -> HTTPResponse {
        let unreadable = Failure(502, "invalid_upstream_response", "The provider's answer did not read.")
        guard let object = try? JSONSerialization.jsonObject(with: completion) as? [String: Any] else { throw unreadable }
        guard streaming else { return HTTPResponse(status: 200, body: completion) }
        guard let choices = object["choices"] as? [[String: Any]] else { throw unreadable }
        var chunk = object
        chunk["object"] = "chat.completion.chunk"
        chunk["choices"] = choices.map { choice in
            var choice = choice
            var delta = choice.removeValue(forKey: "message") as? [String: Any] ?? [:]
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                delta["tool_calls"] = calls.enumerated().map { index, call in call.merging(["index": index]) { kept, _ in kept } }
            }
            choice["delta"] = delta
            return choice
        }
        guard let data = try? JSONSerialization.data(withJSONObject: chunk, options: .withoutEscapingSlashes) else { throw unreadable }
        return HTTPResponse(status: 200, type: "text/event-stream", body: Data("data: ".utf8) + data + Data("\n\ndata: [DONE]\n\n".utf8))
    }
}
