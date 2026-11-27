import CloakSupervisor
import Foundation

/// Anthropic Messages API (`/v1/messages` and `/v1/messages/count_tokens`)
/// compatibility layer for Claude Code and Anthropic SDK clients.
///
/// Translates Anthropic Messages requests into OpenAI Chat Completions JSON
/// bytes so they pass through Cloak's exact same `Asked` validation,
/// `Memory.rewrite` local prompt rewriter, and Tor/wallet/zkAPI send paths,
/// then translates the OpenAI completion back into Anthropic JSON or SSE
/// streaming events.
public enum Anthropic {
    struct Translated: Sendable {
        let openAIBytes: [UInt8]
        let requestedModel: String
        let streaming: Bool
    }

    /// Translates an Anthropic `POST /v1/messages` request body into an OpenAI
    /// `/v1/chat/completions` JSON payload suitable for `Asked.read(_:)`.
    static func translateRequest(_ bytes: [UInt8]) throws(Failure) -> Translated {
        guard String(validating: bytes, as: UTF8.self) != nil,
            let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        else {
            throw .invalid("The body must be a JSON object.")
        }
        guard let model = root["model"] as? String, !Asked.isBlank(model), model.utf8.count <= 256 else {
            throw .invalid("model is required.")
        }
        guard let rawMessages = root["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
            throw .invalid("messages must be a nonempty array.")
        }
        let streaming: Bool
        if let rawStream = root["stream"] {
            guard let flag = rawStream as? Bool else {
                throw .invalid("stream must be a boolean.")
            }
            streaming = flag
        } else {
            streaming = false
        }

        var openAIMessages: [[String: Any]] = []

        // System prompt: string or array of `{type: "text", text: "..."}` blocks.
        if let system = root["system"] {
            let systemText = try extractSystemText(system)
            if !Asked.isBlank(systemText) {
                openAIMessages.append(["role": "system", "content": systemText])
            }
        }

        for raw in rawMessages {
            guard let role = raw["role"] as? String, !role.isEmpty else {
                throw .invalid("Each Anthropic message needs a role.")
            }
            switch role {
            case "user":
                openAIMessages.append(contentsOf: try translateUserMessage(raw["content"]))
            case "assistant":
                openAIMessages.append(try translateAssistantMessage(raw["content"]))
            case "system", "developer":
                if let content = raw["content"] {
                    let text = try extractSystemText(content)
                    if !Asked.isBlank(text) {
                        openAIMessages.append(["role": role, "content": text])
                    }
                }
            default:
                throw .invalid("Unsupported Anthropic message role: \(role).")
            }
        }

        guard !openAIMessages.isEmpty else {
            throw .invalid("messages must contain at least one message.")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
            "stream": streaming,
        ]

        if let maxTokens = root["max_tokens"] {
            payload["max_tokens"] = maxTokens
        }
        if let temperature = root["temperature"] {
            payload["temperature"] = temperature
        }
        if let topP = root["top_p"] {
            payload["top_p"] = topP
        }
        if let topK = root["top_k"] {
            payload["top_k"] = topK
        }
        if let stopSequences = root["stop_sequences"] as? [String], !stopSequences.isEmpty {
            payload["stop"] = stopSequences
        }
        if let rawTools = root["tools"] as? [[String: Any]], !rawTools.isEmpty {
            let openAITools = translateTools(rawTools)
            if !openAITools.isEmpty {
                payload["tools"] = openAITools
            }
        }
        if let rawChoice = root["tool_choice"] as? [String: Any],
            let choice = translateToolChoice(rawChoice)
        {
            payload["tool_choice"] = choice
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw .invalid("Could not encode translated request.")
        }
        return Translated(openAIBytes: [UInt8](data), requestedModel: model, streaming: streaming)
    }

    /// Local token estimate for `POST /v1/messages/count_tokens`.
    /// Runs strictly on-device with zero network calls.
    static func countTokens(_ bytes: [UInt8]) throws(Failure) -> HTTPResponse {
        guard String(validating: bytes, as: UTF8.self) != nil,
            let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
            root["messages"] is [Any]
        else {
            throw .invalid("The body must be a JSON object with messages.")
        }
        var characters = 0
        if let system = root["system"] {
            characters += measureJSONCharacters(system)
        }
        if let messages = root["messages"] {
            characters += measureJSONCharacters(messages)
        }
        if let tools = root["tools"] {
            characters += measureJSONCharacters(tools)
        }
        let estimate = max(1, (characters + 3) / 4)
        return HTTPResponse(status: 200, body: Data(#"{"input_tokens":\#(estimate)}"#.utf8))
    }

    /// Translates an OpenAI Chat Completion JSON response into an Anthropic
    /// Messages JSON response (or Anthropic SSE stream when `streaming == true`).
    static func answer(_ completion: Data, requestedModel: String, streaming: Bool) throws(Failure) -> HTTPResponse {
        let unreadable = Failure(502, "invalid_upstream_response", "The provider's answer did not read.")
        guard let object = try? JSONSerialization.jsonObject(with: completion) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw unreadable
        }

        let rawID = (object["id"] as? String) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let messageID = rawID.hasPrefix("msg_") ? rawID : "msg_\(rawID.replacingOccurrences(of: "chatcmpl-", with: ""))"

        var blocks: [[String: Any]] = []
        if let text = message["content"] as? String, !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        } else if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty {
                blocks.append(["type": "text", "text": joined])
            }
        }

        var hasToolUse = false
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in toolCalls.enumerated() {
                guard let function = call["function"] as? [String: Any],
                    let name = function["name"] as? String, !name.isEmpty
                else { continue }
                let callID = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "toolu_\(index)_\(UUID().uuidString.prefix(8))"
                let argsString = (function["arguments"] as? String) ?? "{}"
                let parsedInput: Any
                if let argsData = argsString.data(using: .utf8),
                    let jsonObj = try? JSONSerialization.jsonObject(with: argsData),
                    jsonObj is [String: Any]
                {
                    parsedInput = jsonObj
                } else {
                    parsedInput = [String: Any]()
                }
                blocks.append([
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": parsedInput,
                ])
                hasToolUse = true
            }
        }

        if blocks.isEmpty {
            blocks.append(["type": "text", "text": ""])
        }

        let finishReason = first["finish_reason"] as? String
        let stopReason: String
        switch finishReason {
        case "tool_calls", "function_call":
            stopReason = "tool_use"
        case "length":
            stopReason = "max_tokens"
        default:
            stopReason = hasToolUse ? "tool_use" : "end_turn"
        }

        let usage = object["usage"] as? [String: Any]
        let inputTokens = (usage?["prompt_tokens"] as? Int) ?? (usage?["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage?["completion_tokens"] as? Int) ?? (usage?["output_tokens"] as? Int) ?? 0

        if !streaming {
            let response: [String: Any] = [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": requestedModel,
                "content": blocks,
                "stop_reason": stopReason,
                "stop_sequence": NSNull(),
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": outputTokens,
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw unreadable
            }
            return HTTPResponse(status: 200, body: data)
        }

        // Anthropic Server-Sent Events sequence.
        var sse = Data()
        func emit(_ event: String, _ payload: [String: Any]) throws(Failure) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw unreadable
            }
            sse.append(Data("event: \(event)\ndata: ".utf8))
            sse.append(data)
            sse.append(Data("\n\n".utf8))
        }

        try emit("message_start", [
            "type": "message_start",
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "content": [Any](),
                "model": requestedModel,
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": 0,
                ],
            ],
        ])

        for (index, block) in blocks.enumerated() {
            let blockType = block["type"] as? String ?? "text"
            if blockType == "tool_use",
                let id = block["id"] as? String,
                let name = block["name"] as? String
            {
                try emit("content_block_start", [
                    "type": "content_block_start",
                    "index": index,
                    "content_block": [
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": [String: Any](),
                    ],
                ])
                let inputObj = block["input"] ?? [String: Any]()
                let inputJSON: String
                if let inputData = try? JSONSerialization.data(withJSONObject: inputObj, options: [.sortedKeys, .withoutEscapingSlashes]),
                    let encoded = String(data: inputData, encoding: .utf8)
                {
                    inputJSON = encoded
                } else {
                    inputJSON = "{}"
                }
                if !inputJSON.isEmpty {
                    try emit("content_block_delta", [
                        "type": "content_block_delta",
                        "index": index,
                        "delta": [
                            "type": "input_json_delta",
                            "partial_json": inputJSON,
                        ],
                    ])
                }
                try emit("content_block_stop", [
                    "type": "content_block_stop",
                    "index": index,
                ])
            } else {
                let text = block["text"] as? String ?? ""
                try emit("content_block_start", [
                    "type": "content_block_start",
                    "index": index,
                    "content_block": [
                        "type": "text",
                        "text": "",
                    ],
                ])
                if !text.isEmpty {
                    try emit("content_block_delta", [
                        "type": "content_block_delta",
                        "index": index,
                        "delta": [
                            "type": "text_delta",
                            "text": text,
                        ],
                    ])
                }
                try emit("content_block_stop", [
                    "type": "content_block_stop",
                    "index": index,
                ])
            }
        }

        try emit("message_delta", [
            "type": "message_delta",
            "delta": [
                "stop_reason": stopReason,
                "stop_sequence": NSNull(),
            ],
            "usage": [
                "output_tokens": outputTokens,
            ],
        ])
        try emit("message_stop", [
            "type": "message_stop",
        ])

        return HTTPResponse(status: 200, type: "text/event-stream", body: sse)
    }

    // MARK: - Helpers

    private static func extractSystemText(_ raw: Any) throws(Failure) -> String {
        if let text = raw as? String {
            return text
        }
        if let blocks = raw as? [[String: Any]] {
            var texts: [String] = []
            for block in blocks {
                guard let type = block["type"] as? String else {
                    throw .invalid("Each system block must include a type.")
                }
                if type == "text", let text = block["text"] as? String, !Asked.isBlank(text) {
                    texts.append(text)
                }
            }
            return texts.joined(separator: "\n\n")
        }
        throw .invalid("system must be a string or an array of text blocks.")
    }

    private static func translateUserMessage(_ rawContent: Any?) throws(Failure) -> [[String: Any]] {
        if let text = rawContent as? String {
            return [["role": "user", "content": text]]
        }
        guard let blocks = rawContent as? [[String: Any]] else {
            throw .invalid("Each user message content must be a string or an array of content blocks.")
        }

        var toolMessages: [[String: Any]] = []
        var systemReminders: [String] = []
        var userParts: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else {
                throw .invalid("Each content block must include a type.")
            }
            switch type {
            case "text":
                guard let text = block["text"] as? String else {
                    throw .invalid("Each text block must include text.")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<system-reminder>") && trimmed.hasSuffix("</system-reminder>") {
                    systemReminders.append(trimmed)
                } else {
                    userParts.append(["type": "text", "text": text])
                }
            case "image":
                guard let source = block["source"] as? [String: Any],
                    let sourceType = source["type"] as? String, sourceType == "base64",
                    let mediaType = source["media_type"] as? String, !mediaType.isEmpty,
                    let data = source["data"] as? String, !data.isEmpty
                else {
                    throw .invalid("Send each image in the request as base64. Cloak sends no remote URLs.")
                }
                userParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(data)"],
                ])
            case "tool_result":
                guard let toolUseID = block["tool_use_id"] as? String, !toolUseID.isEmpty else {
                    throw .invalid("Each tool_result block requires tool_use_id.")
                }
                let contentText = flattenToolResultContent(block["content"])
                toolMessages.append([
                    "role": "tool",
                    "tool_call_id": toolUseID,
                    "content": contentText,
                ])
            default:
                // Skip unknown metadata-only blocks if blank, reject unsupported media links.
                if let text = block["text"] as? String, !Asked.isBlank(text) {
                    userParts.append(["type": "text", "text": text])
                }
            }
        }

        var result = toolMessages
        if !systemReminders.isEmpty {
            result.append(["role": "system", "content": systemReminders.joined(separator: "\n\n")])
        }
        if !userParts.isEmpty {
            if userParts.count == 1, (userParts[0]["type"] as? String) == "text", let single = userParts[0]["text"] as? String {
                result.append(["role": "user", "content": single])
            } else {
                result.append(["role": "user", "content": userParts])
            }
        }
        return result
    }

    private static func translateAssistantMessage(_ rawContent: Any?) throws(Failure) -> [String: Any] {
        if let text = rawContent as? String {
            return ["role": "assistant", "content": text]
        }
        guard let blocks = rawContent as? [[String: Any]] else {
            return ["role": "assistant", "content": ""]
        }

        var texts: [String] = []
        var toolCalls: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String {
                    texts.append(text)
                }
            case "tool_use":
                guard let id = block["id"] as? String, !id.isEmpty,
                    let name = block["name"] as? String, !name.isEmpty
                else {
                    throw .invalid("Each tool_use block requires id and name.")
                }
                let input = block["input"] ?? [String: Any]()
                let argsJSON: String
                if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
                    let str = String(data: data, encoding: .utf8)
                {
                    argsJSON = str
                } else {
                    argsJSON = "{}"
                }
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": argsJSON,
                    ],
                ])
            case "thinking", "redacted_thinking":
                continue
            default:
                continue
            }
        }

        var message: [String: Any] = ["role": "assistant"]
        if texts.isEmpty {
            message["content"] = toolCalls.isEmpty ? "" : NSNull()
        } else {
            message["content"] = texts.joined(separator: "\n")
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        return message
    }

    private static func flattenToolResultContent(_ raw: Any?) -> String {
        if let text = raw as? String {
            return text
        }
        if let blocks = raw as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                return nil
            }
            return parts.joined(separator: "\n")
        }
        return ""
    }

    private static func translateTools(_ rawTools: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for tool in rawTools {
            guard let name = tool["name"] as? String, !name.isEmpty else { continue }
            var function: [String: Any] = [
                "name": name,
                "parameters": tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()],
            ]
            if let description = tool["description"] as? String, !description.isEmpty {
                function["description"] = description
            }
            result.append([
                "type": "function",
                "function": function,
            ])
        }
        return result
    }

    private static func translateToolChoice(_ raw: [String: Any]) -> Any? {
        guard let type = raw["type"] as? String else { return nil }
        switch type {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return ["type": "function", "function": ["name": name]]
        default:
            return nil
        }
    }

    private static func measureJSONCharacters(_ value: Any) -> Int {
        if let string = value as? String {
            return string.count
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + measureJSONCharacters($1) }
        }
        if let dict = value as? [String: Any] {
            return dict.reduce(0) { $0 + $1.key.count + measureJSONCharacters($1.value) }
        }
        return 4
    }
}
