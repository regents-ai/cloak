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
    }
}
