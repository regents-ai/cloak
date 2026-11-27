import CloakChat
@testable import CloakDoor
import CloakSupervisor
import CryptoKit
import Darwin
import Foundation
import Testing

@Suite
@MainActor
struct V03Tests {
    private static let modelsPayload = #"{"object":"list","data":[{"id":"deepseek/deepseek-v4-flash-0731"},{"id":"qwen/qwen3-coder"}]}"#

    // MARK: - Anthropic Request & Response Translation

    @Test func anthropicRequestTranslatesSystemToolsToolUseAndToolResult() throws {
        let body = #"""
        {
          "model": "claude-sonnet-4-6",
          "max_tokens": 1024,
          "stream": true,
          "system": [
            {"type": "text", "text": "You are Claude Code.", "cache_control": {"type": "ephemeral"}},
            {"type": "text", "text": "Be concise."}
          ],
          "tools": [
            {
              "name": "read_file",
              "description": "Read a file",
              "input_schema": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"]
              }
            }
          ],
          "tool_choice": {"type": "any"},
          "stop_sequences": ["DONE"],
          "messages": [
            {
              "role": "user",
              "content": [
                {"type": "text", "text": "Inspect README.md"},
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}
              ]
            },
            {
              "role": "assistant",
              "content": [
                {"type": "thinking", "thinking": "internal thought"},
                {"type": "text", "text": "Reading README.md"},
                {"type": "tool_use", "id": "toolu_123", "name": "read_file", "input": {"path": "README.md"}}
              ]
            },
            {
              "role": "user",
              "content": [
                {"type": "tool_result", "tool_use_id": "toolu_123", "content": [{"type": "text", "text": "# Cloak"}]},
                {"type": "text", "text": "Now summarize it."}
              ]
            }
          ]
        }
        """#

        let translated = try Anthropic.translateRequest([UInt8](body.utf8))
        #expect(translated.requestedModel == "claude-sonnet-4-6")
        #expect(translated.streaming == true)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(translated.openAIBytes)) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-4-6")
        #expect(json["max_tokens"] as? Int == 1024)
        #expect(json["tool_choice"] as? String == "required")
        #expect(json["stop"] as? [String] == ["DONE"])

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect((tools[0]["function"] as? [String: Any])?["name"] as? String == "read_file")

        let messages = try #require(json["messages"] as? [[String: Any]])
        // system + user(text+image) + assistant(tool_calls) + tool(tool_result) + user(text)
        #expect(messages.count == 5)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are Claude Code.\n\nBe concise.")

        #expect(messages[1]["role"] as? String == "user")
        let userParts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(userParts.count == 2)
        #expect((userParts[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,iVBORw0KGgo=")

        #expect(messages[2]["role"] as? String == "assistant")
        let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "toolu_123")

        // Tool result MUST precede trailing user text in OpenAI format so tool outputs are never rewritten.
        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "toolu_123")
        #expect(messages[3]["content"] as? String == "# Cloak")

        #expect(messages[4]["role"] as? String == "user")
        #expect(messages[4]["content"] as? String == "Now summarize it.")
    }

    @Test func anthropicRejectsRemoteImageURL() {
        let body = #"""
        {
          "model": "claude-sonnet-4-6",
          "messages": [
            {
              "role": "user",
              "content": [
                {"type": "image", "source": {"type": "url", "url": "https://example.com/a.png"}}
              ]
            }
          ]
        }
        """#
        #expect(throws: CloakDoor.Failure.self) {
            _ = try Anthropic.translateRequest([UInt8](body.utf8))
        }
    }

    @Test func anthropicResponseTranslatesTextAndToolUseBothJSONAndSSE() throws {
        let openAICompletion = Data(#"""
        {
          "id": "chatcmpl-abc123",
          "object": "chat.completion",
          "model": "deepseek/deepseek-v4-flash-0731",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": "Let me check that file.",
                "tool_calls": [
                  {
                    "id": "call_99",
                    "type": "function",
                    "function": {
                      "name": "read_file",
                      "arguments": "{\"path\":\"Package.swift\"}"
                    }
                  }
                ]
              }
            }
          ],
          "usage": {
            "prompt_tokens": 42,
            "completion_tokens": 17
          }
        }
        """#.utf8)

        // 1. Non-streaming JSON
        let jsonResp = try Anthropic.answer(openAICompletion, requestedModel: "claude-sonnet-4-6", streaming: false)
        #expect(jsonResp.status == 200)
        #expect(jsonResp.type == "application/json")
        let decoded = try #require(try JSONSerialization.jsonObject(with: jsonResp.body) as? [String: Any])
        #expect(decoded["id"] as? String == "msg_abc123")
        #expect(decoded["type"] as? String == "message")
        #expect(decoded["model"] as? String == "claude-sonnet-4-6")
        #expect(decoded["stop_reason"] as? String == "tool_use")
        let usage = try #require(decoded["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 42)
        #expect(usage["output_tokens"] as? Int == 17)
        let content = try #require(decoded["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "Let me check that file.")
        #expect(content[1]["type"] as? String == "tool_use")
        #expect(content[1]["id"] as? String == "call_99")
        #expect(content[1]["name"] as? String == "read_file")
        #expect((content[1]["input"] as? [String: Any])?["path"] as? String == "Package.swift")

        // 2. Streaming SSE
        let sseResp = try Anthropic.answer(openAICompletion, requestedModel: "claude-sonnet-4-6", streaming: true)
        #expect(sseResp.status == 200)
        #expect(sseResp.type == "text/event-stream")
        let sseText = String(decoding: sseResp.body, as: UTF8.self)
        #expect(sseText.contains("event: message_start\n"))
        #expect(sseText.contains("event: content_block_start\n"))
        #expect(sseText.contains("text_delta"))
        #expect(sseText.contains("Let me check that file."))
        #expect(sseText.contains("input_json_delta"))
        #expect(sseText.contains("Package.swift"))
        #expect(sseText.contains("event: content_block_stop\n"))
        #expect(sseText.contains("event: message_delta\n"))
        #expect(sseText.contains(#""stop_reason":"tool_use""#))
        #expect(sseText.contains("event: message_stop\n"))
    }

    // MARK: - End-to-End Door HTTP Tests (Claude Code + x-api-key + Chunked + Token Billing)

    @Test(.timeLimit(.minutes(1)))
    func claudeCodeMessagesEndpointWithXApiKeyAliasMappingChunkedAndCountTokens() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-v03-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)

        let completionJSON = #"""
        {
          "id": "chatcmpl-claude1",
          "object": "chat.completion",
          "model": "qwen/qwen3-coder",
          "choices": [
            {
              "index": 0,
              "finish_reason": "stop",
              "message": {"role": "assistant", "content": "Done."}
            }
          ],
          "usage": {"prompt_tokens": 12, "completion_tokens": 3}
        }
        """#
        let standIn = PayTests.StandIn(answers: [
            "GET /v1/models": Self.modelsPayload,
            "R": completionJSON,
        ])

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts.map { "REWRITTEN: \($0)" } },
                queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macPayment: { .zkapi },
                preferredModel: { _ in "qwen/qwen3-coder" },
                forcedModel: { nil }),
            port: { 0 })

        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(await door.add("Claude Code"))

        // 1. Invalid key on /v1/messages returns Anthropic error shape.
        let badAuth = Data(
            ["POST /v1/messages?beta=true HTTP/1.1", "Host: 127.0.0.1", "x-api-key: wrong",
             "Content-Type: application/json", "Content-Length: 2", "", "{}"].joined(separator: "\r\n").utf8)
        let badResp = String(decoding: try await Self.tcp(port: door.port, send: badAuth), as: UTF8.self)
        #expect(badResp.hasPrefix("HTTP/1.1 401"))
        #expect(badResp.contains(#""type":"error""#))
        #expect(badResp.contains(#""type":"authentication_error""#))

        // 2. Local /v1/messages/count_tokens works with x-api-key and makes zero upstream calls.
        let countBody = #"{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hello world from Claude Code"}]}"#
        let countReq = Data(
            ["POST /v1/messages/count_tokens?beta=true HTTP/1.1", "Host: 127.0.0.1", "x-api-key: \(pass)",
             "Content-Type: application/json", "Content-Length: \(countBody.utf8.count)", "", countBody].joined(separator: "\r\n").utf8)
        let countResp = String(decoding: try await Self.tcp(port: door.port, send: countReq), as: UTF8.self)
        #expect(countResp.hasPrefix("HTTP/1.1 200"))
        #expect(countResp.contains(#""input_tokens":"#))
        #expect(standIn.frames.isEmpty)

        // 3. Chunked POST /v1/messages?beta=true with duplicate anthropic-beta headers, x-api-key,
        //    stream: true, and a Claude alias maps to preferredModel while rewriting user text only.
        let msgBody = #"""
        {"model":"claude-sonnet-4-6","max_tokens":256,"stream":true,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"RAW_TOOL_OUTPUT"},{"type":"text","text":"Explain this"}]}]}
        """#
        let chunkHex = String(msgBody.utf8.count, radix: 16)
        let chunkedLines = [
            "POST /v1/messages?beta=true HTTP/1.1",
            "Host: 127.0.0.1",
            "x-api-key: \(pass)",
            "anthropic-version: 2023-06-01",
            "anthropic-beta: claude-code-20250219",
            "anthropic-beta: interleaved-thinking-2025-05-14",
            "Content-Type: application/json",
            "Transfer-Encoding: chunked",
            "",
            chunkHex,
            msgBody,
            "0",
            "",
            "",
        ]
        let chunkedReq = Data(chunkedLines.joined(separator: "\r\n").utf8)
        let sseResp = String(decoding: try await Self.tcp(port: door.port, send: chunkedReq), as: UTF8.self)
        #expect(sseResp.hasPrefix("HTTP/1.1 200"))
        #expect(sseResp.contains("Content-Type: text/event-stream"))
        #expect(sseResp.contains("event: message_start"))
        #expect(sseResp.contains(#""model":"claude-sonnet-4-6""#))
        #expect(sseResp.contains("Done."))
        #expect(sseResp.contains("event: message_stop"))

        // Verify upstream received mapped model, untouched tool_result, and rewritten user text.
        let requestFrames = standIn.frames.compactMap(\.request)
        try #require(requestFrames.count == 1)
        let sentText = requestFrames[0].body
        #expect(sentText.contains(#""model":"qwen/qwen3-coder""#))
        #expect(sentText.contains("RAW_TOOL_OUTPUT"))
        #expect(sentText.contains("REWRITTEN: Explain this"))
        #expect(!sentText.contains(#""content":"Explain this""#))
        #expect(door.requests.first?.model == "claude-sonnet-4-6 → qwen/qwen3-coder")

        await door.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func connectedAppCanBillViaTokenInferenceTempo() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-v03-tempo-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)

        let modelsResp = try JSONSerialization.data(withJSONObject: ["ok": ["models": Self.modelsPayload]])
        let sender = SendTests.StandIn { request in
            request["op"] as? String == "models" ? modelsResp : SendTests.completed(SendTests.said("Paid on Tempo"))
        }
        let unusedPayer = PayTests.StandIn()

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts },
                queue: PayQueue(line: unusedPayer.line),
                exchange: sender.exchange,
                wallet: { "0x1111111111111111111111111111111111111111" },
                key: { SendTests.walletKey },
                sealing: { key },
                macPayment: { .tempo },
                preferredModel: { _ in "deepseek/deepseek-v4-flash-0731" },
                forcedModel: { nil }),
            port: { 0 })

        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(await door.add("Claude Code"))

        let body = #"{"model":"claude-opus-4-6","max_tokens":64,"messages":[{"role":"user","content":"Hi"}]}"#
        let req = Data(
            ["POST /v1/messages HTTP/1.1", "Host: 127.0.0.1", "x-api-key: \(pass)",
             "Content-Type: application/json", "Content-Length: \(body.utf8.count)", "", body].joined(separator: "\r\n").utf8)
        let resp = String(decoding: try await Self.tcp(port: door.port, send: req), as: UTF8.self)
        #expect(resp.hasPrefix("HTTP/1.1 200"))
        #expect(resp.contains("Paid on Tempo"))
        #expect(sender.read.map { $0["op"] as? String } == ["models", "send"])
        #expect(unusedPayer.frames.isEmpty)

        await door.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func realClaudeCodeCLIEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["CLOAK_TEST_CLAUDE_CLI"] == "1" else { return }
        let claudePath = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path
        guard FileManager.default.isExecutableFile(atPath: claudePath) else { return }

        let folder = URL(filePath: "/tmp").appending(path: "cloak-v03-claude-cli-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)

        let completionJSON = #"""
        {
          "id": "chatcmpl-real-claude-cli",
          "object": "chat.completion",
          "model": "qwen/qwen3-coder",
          "choices": [
            {
              "index": 0,
              "finish_reason": "stop",
              "message": {"role": "assistant", "content": "CLOAK_CLAUDE_CODE_OK"}
            }
          ],
          "usage": {"prompt_tokens": 25, "completion_tokens": 5}
        }
        """#
        let standIn = PayTests.StandIn(answers: [
            "GET /v1/models": Self.modelsPayload,
            "R": completionJSON,
        ])

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts.map { "[REWRITTEN] \($0)" } },
                queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macPayment: { .zkapi },
                preferredModel: { _ in "qwen/qwen3-coder" },
                forcedModel: { nil }),
            port: { 0 })

        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(await door.add("Claude Code"))

        let result = try await Self.runProcess(
            executable: claudePath,
            arguments: ["-p", "Say hello from Cloak", "--output-format", "text", "--no-session-persistence", "--tools", ""],
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": folder.path,
                "ANTHROPIC_BASE_URL": door.baseURL,
                "ANTHROPIC_API_KEY": pass,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ])
        await door.close()

        #expect(result.status == 0, "claude exited \(result.status): stdout=\(result.stdout) stderr=\(result.stderr)")
        #expect(result.stdout.contains("CLOAK_CLAUDE_CODE_OK"), "stdout=\(result.stdout) stderr=\(result.stderr)")
        #expect(!standIn.frames.compactMap(\.request).isEmpty)
    }

    // MARK: - Local Voice Text Sanitization & Merge

    @Test func voiceTextSanitizesMarkdownAndMergesDraftsCleanly() {
        let markdown = """
        <think>hidden chain of thought</think>
        ## Summary
        Here is **bold** and `inline_code` with a [Cloak link](https://regents.sh/cloak).

        ```swift
        let secret = 42
        ```

        - First point
        - Second point
        """
        let spoken = VoiceText.spoken(from: markdown)
        #expect(!spoken.contains("hidden chain of thought"))
        #expect(!spoken.contains("let secret = 42"))
        #expect(spoken.contains("Code block omitted."))
        #expect(spoken.contains("Summary"))
        #expect(spoken.contains("bold"))
        #expect(spoken.contains("inline_code"))
        #expect(spoken.contains("Cloak link"))
        #expect(!spoken.contains("https://regents.sh/cloak"))
        #expect(!spoken.contains("##"))
        #expect(!spoken.contains("**"))

        #expect(VoiceText.merge(prefix: "", transcript: "hello world") == "hello world")
        #expect(VoiceText.merge(prefix: "Draft", transcript: "more text") == "Draft more text")
        #expect(VoiceText.merge(prefix: "Draft ", transcript: "more text") == "Draft more text")
        #expect(VoiceText.merge(prefix: "Line 1\n", transcript: "Line 2") == "Line 1\nLine 2")
        #expect(VoiceText.merge(prefix: "Keep me", transcript: "   ") == "Keep me")
    }

    // MARK: - 4-Network Manifest, Arc Dual-Precision USDC, and Deterministic Spend Guardrails

    @Test func fourNetworkManifestAndArcDualPrecisionAccounting() {
        #expect(PaymentNetwork.all.map(\.id) == [.ethereum, .base, .tempo, .arc])
        #expect(PaymentNetwork.ethereum.chainID == 1 && PaymentNetwork.ethereum.circleDomain == 0)
        #expect(PaymentNetwork.base.chainID == 8453 && PaymentNetwork.base.circleDomain == 6)
        #expect(PaymentNetwork.tempo.chainID == 4217 && PaymentNetwork.tempo.circleDomain == nil)
        #expect(PaymentNetwork.arc.chainID == 5042 && PaymentNetwork.arc.circleDomain == 26)
        #expect(PaymentNetwork.arc.nativeDecimals == 18)
        #expect(PaymentNetwork.arc.erc20StableDecimals == 6)
        #expect(PaymentNetwork.arc.supportsOnChainPrivacy == false)
        #expect(PaymentNetwork.network(chainID: 5042) == .arc)
        #expect(PaymentNetwork.network(circleDomain: 26) == .arc)

        // Exact 6-decimal ERC-20 <-> 18-decimal Arc native wei conversions without float drift.
        let one = ArcUSDC.parseUSD("$1.00")
        #expect(one?.erc20Units == 1_000_000)
        #expect(one?.nativeWeiDecimalString == "1000000000000000000")
        #expect(ArcUSDC.fromNativeWei("1000000000000000000") == one)
        #expect(ArcUSDC.fromNativeWei("500000000000000000")?.formattedUSD == "$0.50")
        #expect(ArcUSDC.parseUSD("0.0025")?.formattedUSD == "$0.0025")
        #expect(ArcUSDC.parseUSD("-1.00") == nil)
        #expect(ArcUSDC.parseUSD("1.1234567") == nil)

        // Arc dual ERC-20 + native system event deduplication.
        var dedup = ArcTransferDeduplicator()
        let key = ArcTransferDeduplicator.TransferKey(txHash: "0xABC", from: "0x111", to: "0x222", microUnits: 500_000)
        let mirror = ArcTransferDeduplicator.TransferKey(txHash: "0xabc", from: "0x111", to: "0x222", microUnits: 500_000)
        #expect(dedup.recordIfNew(key) == true)
        #expect(dedup.recordIfNew(mirror) == false)
    }

    @Test func spendLedgerEnforcesWrongChainConcurrencyIdempotencyAndRelease() async {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-spend-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledgerFile = folder.appending(path: "spend-receipts.json")
        let ledger = SpendLedger(file: ledgerFile)

        // 1. Wrong chain ID is rejected BEFORE signing even when policy limits are disabled.
        let wrongChainQuote = SpendQuote(
            service: "Patchbay Verification",
            provider: "patchbay",
            network: .arc,
            expectedChainID: PaymentNetwork.arcTestnetChainID,
            asset: "USDC",
            maxMicroUSD: 100_000,
            leavesThisMac: "Tool manifest only"
        )
        let wrongChain = await ledger.authorize(wrongChainQuote, policy: .disabled)
        #expect(wrongChain == .rejected(.wrongChain(expected: 5042, actual: 5_042_002, network: .arc)))

        // 2. Concurrent agents racing against a shared $3.00 daily cap ($1.00 each) cannot overspend.
        let policy = SpendPolicy(
            enabled: true,
            dailyLimitMicroUSD: 3_000_000,
            perCallLimitMicroUSD: 1_000_000,
            allowedNetworks: [.arc, .base]
        )
        let decisions = await withTaskGroup(of: SpendDecision.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await ledger.authorize(
                        SpendQuote(
                            idempotencyKey: "job-\(i)",
                            service: "Patchbay Check",
                            provider: "patchbay",
                            network: .arc,
                            expectedChainID: 5042,
                            asset: "USDC",
                            maxMicroUSD: 1_000_000,
                            leavesThisMac: "Scoped test case"
                        ),
                        policy: policy
                    )
                }
            }
            var all: [SpendDecision] = []
            for await d in group { all.append(d) }
            return all
        }
        let approvedIDs = decisions.compactMap { decision -> UUID? in
            if case .approved(let id) = decision { return id }
            return nil
        }
        #expect(approvedIDs.count == 3)
        let snapReserved = await ledger.snapshot()
        #expect(snapReserved.reservedMicroUSD == 3_000_000)
        #expect(snapReserved.remainingTodayMicroUSD(limit: 3_000_000) == 0)

        // 3. Settling an approved reservation for less ($0.25 actual) immediately frees unused $0.75.
        await ledger.settle(reservationID: approvedIDs[0], actualMicroUSD: 250_000, networkFeeMicroUSD: 1_000, txHash: "0xtx1")
        let snapAfterSettle = await ledger.snapshot()
        #expect(snapAfterSettle.spentTodayMicroUSD == 251_000)
        #expect(snapAfterSettle.reservedMicroUSD == 2_000_000)
        #expect(snapAfterSettle.remainingTodayMicroUSD(limit: 3_000_000) == 749_000)

        // 4. Retrying a settled idempotencyKey returns idempotentReplay (never double-charges).
        let settledReceipt = snapAfterSettle.recentReceipts.first { $0.id == approvedIDs[0] }!
        let replay = await ledger.authorize(
            SpendQuote(
                idempotencyKey: settledReceipt.idempotencyKey,
                service: "Patchbay Check",
                provider: "patchbay",
                network: .arc,
                expectedChainID: 5042,
                asset: "USDC",
                maxMicroUSD: 1_000_000,
                leavesThisMac: "Scoped test case"
            ),
            policy: policy
        )
        #expect(replay == .idempotentReplay(receipt: settledReceipt))

        // 5. Restarting from persisted file releases stale in-flight reservations cleanly.
        let reloaded = SpendLedger(file: ledgerFile)
        let reloadedSnap = await reloaded.snapshot()
        #expect(reloadedSnap.reservedMicroUSD == 0)
        #expect(reloadedSnap.spentTodayMicroUSD == 251_000)
    }

    @Test func spendLedgerStateMachineEnforcesCapAcrossEvictionAmbiguousAndInvalidTransitions() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-spend-sm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledgerFile = folder.appending(path: "spend-receipts.json")

        // 1. Evicting display receipts past `maxStoredReceipts` or clearing history never resets today's cap.
        let capped = SpendLedger(file: ledgerFile, maxStoredReceipts: 5)
        let policy = SpendPolicy(
            enabled: true,
            dailyLimitMicroUSD: 1_000_000,   // $1.00 / day
            perCallLimitMicroUSD: 200_000,   // $0.20 / call
            allowedNetworks: [.arc]
        )
        for i in 0..<10 {
            let decision = await capped.authorize(
                SpendQuote(
                    idempotencyKey: "call-\(i)",
                    service: "Agent Call",
                    provider: "boundless",
                    network: .arc,
                    expectedChainID: 5042,
                    asset: "USDC",
                    maxMicroUSD: 100_000,
                    leavesThisMac: "Rewritten prompt only"
                ),
                policy: policy
            )
            guard case .approved(let id) = decision else {
                Issue.record("Expected call-\(i) to be approved, got \(decision)")
                return
            }
            await capped.settle(reservationID: id, actualMicroUSD: 100_000)
        }

        let snapFull = await capped.snapshot()
        #expect(snapFull.spentTodayMicroUSD == 1_000_000)
        #expect(snapFull.recentReceipts.count == 5)

        let overCap = await capped.authorize(
            SpendQuote(
                idempotencyKey: "call-10",
                service: "Agent Call",
                provider: "boundless",
                network: .arc,
                expectedChainID: 5042,
                asset: "USDC",
                maxMicroUSD: 100_000,
                leavesThisMac: "Rewritten prompt only"
            ),
            policy: policy
        )
        #expect(overCap == .rejected(.exceedsDailyLimit(requested: 100_000, remaining: 0, limit: 1_000_000)))

        // Clearing visible receipt history preserves today's committed total both in memory and after reload.
        await capped.clearHistory()
        #expect((await capped.snapshot()).spentTodayMicroUSD == 1_000_000)
        let reloaded = SpendLedger(file: ledgerFile, maxStoredReceipts: 5)
        #expect((await reloaded.snapshot()).spentTodayMicroUSD == 1_000_000)

        // 2. Active `.reserved` entries are never evicted, invalid transitions are ignored, and `.ambiguous` counts conservatively.
        let strict = SpendLedger(maxStoredReceipts: 3)
        let slowDecision = await strict.authorize(
            SpendQuote(
                idempotencyKey: "slow-1",
                service: "Slow Call",
                provider: "boundless",
                network: .arc,
                expectedChainID: 5042,
                asset: "USDC",
                maxMicroUSD: 200_000,
                leavesThisMac: "Rewritten prompt only"
            ),
            policy: policy
        )
        guard case .approved(let slowID) = slowDecision else {
            Issue.record("Expected slow-1 to be approved")
            return
        }

        var lastSettledID: UUID?
        for i in 0..<4 {
            let d = await strict.authorize(
                SpendQuote(
                    idempotencyKey: "fast-\(i)",
                    service: "Fast Call",
                    provider: "boundless",
                    network: .arc,
                    expectedChainID: 5042,
                    asset: "USDC",
                    maxMicroUSD: 100_000,
                    leavesThisMac: "Rewritten prompt only"
                ),
                policy: policy
            )
            guard case .approved(let id) = d else {
                Issue.record("Expected fast-\(i) to be approved")
                return
            }
            await strict.settle(reservationID: id, actualMicroUSD: 100_000)
            lastSettledID = id
        }

        let beforeAmbiguous = await strict.snapshot()
        #expect(beforeAmbiguous.reservedMicroUSD == 200_000)
        #expect(beforeAmbiguous.spentTodayMicroUSD == 400_000)

        // Settled receipt cannot transition to failed or ambiguous.
        let settledID = try #require(lastSettledID)
        await strict.release(reservationID: settledID, failed: true)
        await strict.markAmbiguous(reservationID: settledID)
        let afterInvalid = await strict.snapshot()
        #expect(afterInvalid.spentTodayMicroUSD == 400_000)
        #expect(afterInvalid.recentReceipts.first(where: { $0.id == settledID })?.status == .settled)

        // Marking the slow timed-out call ambiguous moves its reserved max into committed spend and blocks replay.
        await strict.markAmbiguous(reservationID: slowID)
        let afterAmbiguous = await strict.snapshot()
        #expect(afterAmbiguous.reservedMicroUSD == 0)
        #expect(afterAmbiguous.spentTodayMicroUSD == 600_000)
        let ambiguousRetry = await strict.authorize(
            SpendQuote(
                idempotencyKey: "slow-1",
                service: "Slow Call",
                provider: "boundless",
                network: .arc,
                expectedChainID: 5042,
                asset: "USDC",
                maxMicroUSD: 200_000,
                leavesThisMac: "Rewritten prompt only"
            ),
            policy: policy
        )
        #expect(ambiguousRetry == .rejected(.duplicateInFlight(idempotencyKey: "slow-1")))
    }

    @Test(.timeLimit(.minutes(1)))
    func doorOpenAwaitsReadyAndCoalescesConcurrentLoad() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-v03-door-sm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appsFile = folder.appending(path: "apps")
        let key = SymmetricKey(size: .bits256)
        // Seed an empty sealed apps file so `load()` calls `parts.sealing()`.
        try AgentStore(file: appsFile, key: key).save([])

        actor Counter {
            var count = 0
            func bump() -> Int {
                count += 1
                return count
            }
        }
        let sealingCalls = Counter()
        let standIn = PayTests.StandIn()
        let door = Door(
            file: appsFile,
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts },
                queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: {
                    _ = await sealingCalls.bump()
                    try? await Task.sleep(for: .milliseconds(30))
                    return key
                }),
            port: { 0 })

        async let firstLoad: Void = door.load()
        async let secondLoad: Void = door.load()
        _ = await (firstLoad, secondLoad)
        #expect(await sealingCalls.count == 1)

        // `await door.open()` must resolve to `.open` immediately with a bound port (no polling).
        await door.open()
        #expect(door.state == .open)
        #expect(door.port > 0)

        await door.close()
        #expect(door.state == .closed)
    }

    @Test(.timeLimit(.minutes(1)))
    func doorBlocksRequestBeforePayingWhenSpendGuardCapIsExceeded() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-v03-budget-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let standIn = PayTests.StandIn(answers: [
            "GET /v1/models": Self.modelsPayload,
            "R": SendTests.said("Should never be paid"),
        ])

        let strictPolicy = SpendPolicy(
            enabled: true,
            dailyLimitMicroUSD: 500_000,
            perCallLimitMicroUSD: 10_000, // $0.01 cap < $0.05 request estimate
            allowedNetworks: [.ethereum, .tempo, .arc]
        )

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts },
                queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macPayment: { .zkapi },
                spendLedger: SpendLedger(),
                spendPolicy: { strictPolicy },
                requestMaxMicroUSD: { _ in 50_000 }),
            port: { 0 })

        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(await door.add("Claude Code"))

        let body = #"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"Spend money"}]}"#
        let req = Data(
            ["POST /v1/messages HTTP/1.1", "Host: 127.0.0.1", "x-api-key: \(pass)",
             "Content-Type: application/json", "Content-Length: \(body.utf8.count)", "", body].joined(separator: "\r\n").utf8)
        let resp = String(decoding: try await Self.tcp(port: door.port, send: req), as: UTF8.self)
        #expect(resp.hasPrefix("HTTP/1.1 402"))
        #expect(resp.contains(#""type":"error""#))
        #expect(resp.contains("Spend Guardrails"))
        // Verify ZERO paid completion requests were ever sent upstream.
        #expect(standIn.frames.compactMap(\.request).isEmpty)

        await door.close()
    }

    // MARK: - Helpers

    private static func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @concurrent
    private static func tcp(port: UInt16, send payload: Data) async throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { throw POSIXError(.ECONNREFUSED) }
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                response.append(buffer, count: n)
            } else {
                break
            }
        }
        return response
    }

    @concurrent
    private static func runProcess(
        executable: String, arguments: [String], environment: [String: String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, out, err)
    }
}
