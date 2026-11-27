import CloakChat
import CryptoKit
import Foundation
import Testing

/// Proof before sending, in NEAR mode: the `ask` line Cloak writes to the
/// helper carries exactly the freshness chosen, in seconds, as the age of a
/// check the helper may use instead of checking again, and the route chosen.
/// The helper is a stand-in script, pinned as the real one is, that keeps
/// the line it reads and answers as the real one does. A test-only key and
/// folder; never the keychain, never the network.
struct NearTests {
    static let cases: [(ProofFreshness, NearRoute, [String: String])] = [
        (.everyMessage, .direct, ["via": "direct"]),
        (
            .tenMinutes, .tor(socket: "/tmp/cloak-tor.test/socks", near: "near-id", intel: "intel-id"),
            ["via": "tor", "socket": "/tmp/cloak-tor.test/socks", "near_identity": "near-id", "intel_identity": "intel-id"]
        ),
        (.oneHour, .direct, ["via": "direct"]),
    ]

    static let answer = #"""
        {"answer":"replied","sent":true,"proof":{"passed_at":1795125440,"model_servers":1,"gpus":8,"model_key":"00","gateway_tls_key_sha256":"ff"},"reply":{"choices":[{"index":0,"message":{"role":"assistant","content":"\n\npong"},"finish_reason":"stop"}]}}
        """#

    @Test(arguments: cases)
    func askLineCarriesFreshnessAndRoute(freshness: ProofFreshness, route: NearRoute, expected: [String: String]) async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-near-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appending(path: "line")
        let helper = folder.appending(path: "cloak-near")
        let script = """
            #!/bin/sh
            IFS= read -r line
            printf '%s\\n' "$line" > '\(kept.path)'
            printf '%s\\n' '\(Self.answer)'
            """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let sha256 = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        let near = Near(helper: helper, sha256: sha256)
        defer { near.stop() }
        let turn = Turn(original: "ping", reworded: nil)

        let answered = try await near.ask(
            route: route, proofAge: freshness, key: { "sk-test" }, turn: turn.id, in: Conversation(turns: [turn]))

        #expect(answered.text == "pong")
        let line = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: kept)) as? [String: Any])
        #expect(line["request"] as? String == "ask")
        #expect(line["proof_age"] as? Int == freshness.rawValue)
        #expect(line["route"] as? [String: String] == expected)
        #expect(answered.proof.tlsProtocol == nil)
        #expect(answered.proof.isHybridPostQuantumTLS == false)
    }

    @Test
    func checkLineDecodesLocalNegotiatedTLSMetadata() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-near-tls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appending(path: "cloak-near")
        let response = #"""
            {"answer":"passed","sent":false,"proof":{"passed_at":1795125440,"model_servers":2,"gpus":8,"model_key":"00","gateway_tls_key_sha256":"ff","tls_protocol":"TLS 1.3","tls_cipher_suite":"TLS13_AES_256_GCM_SHA384","tls_key_exchange":"X25519MLKEM768"}}
            """#
        let script = """
            #!/bin/sh
            IFS= read -r _line
            printf '%s\\n' '\(response)'
            """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let sha256 = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        let near = Near(helper: helper, sha256: sha256)
        defer { near.stop() }

        let proof = try await near.check(route: .direct, proofAge: .everyMessage)

        #expect(proof.modelServers == 2)
        #expect(proof.gpus == 8)
        #expect(proof.tlsProtocol == "TLS 1.3")
        #expect(proof.tlsCipherSuite == "TLS13_AES_256_GCM_SHA384")
        #expect(proof.tlsKeyExchange == "X25519MLKEM768")
        #expect(proof.isHybridPostQuantumTLS == true)
        #expect(proof.tlsSummary == "TLS 1.3 · X25519MLKEM768")
    }

    @Test func sanitizedChatPayloadStripsUncoveredFieldsForConnectedApps() throws {
        let raw = Data(#"""
        {
          "model": "claude-sonnet-4-6",
          "stream": true,
          "temperature": 0.2,
          "max_tokens": 512,
          "top_k": 40,
          "stream_options": {"include_usage": true},
          "reasoning_effort": "high",
          "metadata": {"session": "abc"},
          "user": "dev-1",
          "messages": [
            {"role": "system", "content": "Be concise.", "cache_control": {"type": "ephemeral"}},
            {"role": "user", "content": "Check repo", "extra_field": 123}
          ],
          "tools": [
            {"type": "web_search", "name": "server_search"},
            {
              "type": "function",
              "function": {
                "name": "read_file",
                "description": "Reads a file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
                "strict": true
              }
            }
          ],
          "tool_choice": {"type": "function", "function": {"name": "read_file", "extra": true}}
        }
        """#.utf8)

        let clean = try Near.sanitizedChatPayload(from: raw)
        #expect(clean["model"] as? String == Near.model)
        #expect(clean["stream"] as? Bool == false)
        #expect(clean["max_tokens"] as? Int == 512)
        #expect(clean["temperature"] as? Double == 0.2)
        // Uncovered client extensions stripped so cloak-near strict E2EE sealing succeeds.
        #expect(clean["top_k"] == nil)
        #expect(clean["stream_options"] == nil)
        #expect(clean["reasoning_effort"] == nil)
        #expect(clean["metadata"] == nil)
        #expect(clean["user"] == nil)

        let msgs = try #require(clean["messages"] as? [[String: Any]])
        #expect(msgs.count == 2)
        #expect(msgs[0]["cache_control"] == nil)
        #expect(msgs[1]["extra_field"] == nil)

        let tools = try #require(clean["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let fn = try #require(tools[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "read_file")
        #expect(fn["strict"] == nil)

        let choice = try #require(clean["tool_choice"] as? [String: Any])
        let choiceFn = try #require(choice["function"] as? [String: Any])
        #expect(choiceFn["name"] as? String == "read_file")
        #expect(choiceFn["extra"] == nil)
    }
}
