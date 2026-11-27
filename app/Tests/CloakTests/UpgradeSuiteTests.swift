import CloakChat
import CloakControl
import CloakDarkbloom
@testable import CloakDoor
import CloakSupervisor
import CryptoKit
import Foundation
import Testing

@Suite
@MainActor
struct UpgradeSuiteTests {

    // MARK: - LocalServerDiscovery & Recency + Quality Ranking

    @Test func localServerDiscoveryEnforcesLoopbackOnlyAndRanksByRecencyAndQuality() async throws {
        // Strict loopback check: plain HTTP on localhost / 127.0.0.1 / [::1] only.
        #expect(LocalServerDiscovery.isLoopback(URL(string: "http://127.0.0.1:1234")!))
        #expect(LocalServerDiscovery.isLoopback(URL(string: "http://localhost:11234")!))
        #expect(LocalServerDiscovery.isLoopback(URL(string: "http://[::1]:11434")!))

        #expect(!LocalServerDiscovery.isLoopback(URL(string: "https://127.0.0.1:1234")!))
        #expect(!LocalServerDiscovery.isLoopback(URL(string: "http://192.168.1.50:1234")!))
        #expect(!LocalServerDiscovery.isLoopback(URL(string: "http://0.0.0.0:11434")!))
        #expect(!LocalServerDiscovery.isLoopback(URL(string: "https://api.openai.com")!))

        // Refuses non-loopback completion before making any network request.
        await #expect(throws: LocalServerDiscovery.DiscoveryError.self) {
            _ = try await LocalServerDiscovery.complete(
                baseURL: URL(string: "https://api.openai.com")!,
                modelID: "gpt-4o",
                body: Data("{}".utf8))
        }

        // Parsing skips embedding/reranker models and ranks newer + higher-quality models first.
        let payload = Data(#"""
        {
          "object": "list",
          "data": [
            {"id": "text-embedding-nomic-v1.5"},
            {"id": "bge-reranker-large"},
            {"id": "meta/llama-3.3-8b-instruct"},
            {"id": "qwen/qwen3-4b-instruct"},
            {"id": "mlx-community/Qwen3.6-35B-A3B-4bit"},
            {"id": "thinkymachines/Inkling-2-Mini-JANGH2"}
          ]
        }
        """#.utf8)
        let parsed = LocalServerDiscovery.parseModels(
            data: payload,
            kind: .mlxServe,
            baseURL: URL(string: "http://127.0.0.1:11234")!)
        #expect(parsed.count == 4)
        #expect(parsed.map(\.modelID) == [
            "thinkymachines/Inkling-2-Mini-JANGH2",
            "mlx-community/Qwen3.6-35B-A3B-4bit",
            "qwen/qwen3-4b-instruct",
            "meta/llama-3.3-8b-instruct",
        ])
    }

    // MARK: - SmartPrivateRouter

    @Test func smartPrivateRouterSelectsBestReadyRailWithoutSilentFallback() {
        let allReady = PrivateCloudAvailability(nearReady: true, veniceReady: true, boundlessReady: true, zkapiReady: true)
        #expect(SmartPrivateRouter.resolve(preset: .fast, availability: allReady).rail == .near)
        #expect(SmartPrivateRouter.resolve(preset: .coding, availability: allReady).rail == .near)
        #expect(SmartPrivateRouter.resolve(preset: .reasoning, availability: allReady).rail == .zkapi)

        let onlyVenice = PrivateCloudAvailability(veniceReady: true)
        for preset in SmartPrivatePreset.allCases {
            let decision = SmartPrivateRouter.resolve(preset: preset, availability: onlyVenice)
            #expect(decision.ready == true)
            #expect(decision.rail == .venice)
        }

        let veniceAndBoundless = PrivateCloudAvailability(veniceReady: true, boundlessReady: true)
        #expect(SmartPrivateRouter.resolve(preset: .fast, availability: veniceAndBoundless).rail == .venice)
        #expect(SmartPrivateRouter.resolve(preset: .coding, availability: veniceAndBoundless).rail == .boundless)

        // When nothing is funded/configured, explicitly signals ready == false.
        let noneReady = PrivateCloudAvailability()
        let unfundedFast = SmartPrivateRouter.resolve(preset: .fast, availability: noneReady)
        #expect(unfundedFast.ready == false)
        #expect(unfundedFast.rail == .venice)
        #expect(unfundedFast.summary.contains("Stripe Link"))
    }

    // MARK: - ServingQoS & Earn-to-Spend & Network Registry

    @Test func servingQoSEvaluatesThermalBatteryQuietHoursAndEarnToSpend() {
        let defaultPolicy = ServingQoSPolicy.default
        // Plugged in, cool -> allow
        #expect(
            ServingQoS.evaluate(
                policy: defaultPolicy,
                condition: ServingHostCondition(onBattery: false, thermal: .fair, hour: 14)) == .allow)

        // High thermal takes priority over battery
        #expect(
            ServingQoS.evaluate(
                policy: defaultPolicy,
                condition: ServingHostCondition(onBattery: true, thermal: .serious, hour: 14)) == .pause(reason: .highThermal))

        // On battery -> pause
        #expect(
            ServingQoS.evaluate(
                policy: defaultPolicy,
                condition: ServingHostCondition(onBattery: true, thermal: .nominal, hour: 14)) == .pause(reason: .onBattery))

        // Daytime quiet hours (9..18)
        let workHours = ServingQoSPolicy(
            pauseOnBattery: false, pauseOnHighThermal: false,
            quietHoursEnabled: true, quietStartHour: 9, quietEndHour: 18)
        #expect(
            ServingQoS.evaluate(
                policy: workHours,
                condition: ServingHostCondition(onBattery: false, thermal: .nominal, hour: 9)) == .pause(reason: .quietHours(start: 9, end: 18)))
        #expect(
            ServingQoS.evaluate(
                policy: workHours,
                condition: ServingHostCondition(onBattery: false, thermal: .nominal, hour: 18)) == .allow)

        // Overnight wrap-around quiet hours (22..7)
        #expect(ServingQoS.isInQuietHours(hour: 22, start: 22, end: 7))
        #expect(ServingQoS.isInQuietHours(hour: 2, start: 22, end: 7))
        #expect(ServingQoS.isInQuietHours(hour: 6, start: 22, end: 7))
        #expect(!ServingQoS.isInQuietHours(hour: 7, start: 22, end: 7))
        #expect(!ServingQoS.isInQuietHours(hour: 21, start: 22, end: 7))

        // Earn -> Spend caption math
        #expect(ServingQoS.earnToSpendCaption(microUSD: 0) == nil)
        #expect(ServingQoS.earnToSpendCaption(microUSD: 4_999) == nil)
        #expect(ServingQoS.earnToSpendCaption(microUSD: 5_000) == "Offsets ~1 private cloud coding prompt")
        #expect(ServingQoS.earnToSpendCaption(microUSD: 250_000) == "Offsets ~50 private cloud coding prompts")

        // Pluggable Serving Network catalog includes Darkbloom (active), Antseed, and Gonka.
        let ids = ServingNetworkDescriptor.catalog.map(\.id)
        #expect(ids == ["darkbloom", "antseed", "gonka"])
        #expect(ServingNetworkDescriptor.catalog.first?.status == .active)
        #expect(ServingNetworkDescriptor.catalog.dropFirst().allSatisfy { $0.status == .evaluating })
    }

    // MARK: - CloakDoor Local ($0) Routing + PrivacyShield

    @Test func doorLocalRouteServesZeroCostCompletionsWithPrivacyShieldAndNoRemoteSpend() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloak-door-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let key = SymmetricKey(size: .bits256)
        final class Recorder: @unchecked Sendable {
            var localBodies: [String] = []
            var rewordCalls = 0
            var payCalls = 0
        }
        let recorder = Recorder()

        let queue = PayQueue { _, _ in
            recorder.payCalls += 1
            throw POSIXError(.EIO)
        }

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in
                    recorder.rewordCalls += 1
                    return texts
                },
                queue: queue,
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macRoute: { .local },
                localModels: {
                    Data(#"{"object":"list","data":[{"id":"inkling-2-mini-jangh2"}]}"#.utf8)
                },
                localComplete: { body in
                    let text = String(decoding: body, as: UTF8.self)
                    recorder.localBodies.append(text)
                    return Data(#"""
                    {
                      "id": "chatcmpl-local-1",
                      "object": "chat.completion",
                      "created": 1795750000,
                      "model": "inkling-2-mini-jangh2",
                      "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "Reviewed [ENTITY_1] locally."},
                        "finish_reason": "stop"
                      }]
                    }
                    """#.utf8)
                },
                privacyPolicy: {
                    PrivacyShieldPolicy(
                        blockSecrets: true,
                        maskEntities: true,
                        privateTerms: ["Mira Vale"])
                }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        defer { Task { await door.close() } }

        let check = await door.verifyConnection()
        #expect(check.ok == true)
        #expect(check.modelCount == 1)

        let pass = try #require(await door.add("Claude Code Local"))

        // 1. Secret tripwire still blocks leaked credentials even on Local route.
        let secretKey = "sk-ant-" + "api03-abcdefghijklmnopqrstuvwxyz0123456789"
        let blocked = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"use \#(secretKey)"}]}"#)
        #expect(blocked.status == 400)
        #expect(blocked.body.contains("secret_blocked"))
        #expect(recorder.localBodies.isEmpty)

        // 2. Normal request maps Claude alias -> local model, masks/restores private term, spends $0.
        let ok = try await Self.httpPost(
            port: door.port,
            path: "/v1/messages",
            auth: pass,
            useAnthropicHeader: true,
            body: #"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"Summarize Mira Vale notes."}]}"#)
        #expect(ok.status == 200)
        #expect(recorder.rewordCalls == 0)
        #expect(recorder.payCalls == 0)
        #expect(recorder.localBodies.count == 1)
        #expect(recorder.localBodies[0].contains("[ENTITY_1]"))
        #expect(!recorder.localBodies[0].contains("Mira Vale"))
        #expect(ok.body.contains("Reviewed Mira Vale locally."))
        #expect(door.spendSnapshot.spentTodayMicroUSD == 0)
    }

    // MARK: - Saved Project Profiles (Free in Beta)

    @Test func projectProfileIsolatesFoldersMergesPrivateTermsAndOverridesDoorModel() throws {
        let profile = ProjectProfile(
            name: "Acme Client Audit",
            approvedFolders: ["/Users/dev/acme-repo", "/Users/dev/acme-repo", ""],
            privateTerms: "Acme Corp, cedar-relay\nalice.eth",
            route: .local,
            doorModelOverride: "inkling-2-mini-jangh2",
            localNotes: "Client audit rules: check ERC-20 overflow paths only.")

        // Deduplicates paths and parses terms cleanly.
        #expect(profile.approvedFolders == ["/Users/dev/acme-repo"])
        #expect(profile.parsedPrivateTerms == ["Acme Corp", "cedar-relay", "alice.eth"])
        #expect(profile.localContextBlock?.contains("[Project Profile: Acme Client Audit]") == true)

        // Strict isolation: when a project is active, global folders are NOT mixed into Local search.
        let isolatedFolders = ProjectProfileResolver.effectiveApprovedFolders(
            active: profile,
            globalFolders: ["/Users/dev/personal-notes"])
        #expect(isolatedFolders == ["/Users/dev/acme-repo"])

        let fallbackFolders = ProjectProfileResolver.effectiveApprovedFolders(
            active: nil,
            globalFolders: ["/Users/dev/personal-notes"])
        #expect(fallbackFolders == ["/Users/dev/personal-notes"])

        // Private terms merge seamlessly with global Connected Apps Privacy Shield terms.
        let merged = ProjectProfileResolver.mergedPrivateTermsRaw(
            active: profile,
            globalTermsRaw: "GlobalSecret")
        let parsed = PrivacyShieldPolicy.parsePrivateTerms(merged)
        #expect(parsed.contains("GlobalSecret"))
        #expect(parsed.contains("Acme Corp"))
        #expect(parsed.contains("cedar-relay"))
        #expect(parsed.contains("alice.eth"))

        // Model override prefers active project, falling back cleanly to global override.
        #expect(
            ProjectProfileResolver.effectiveDoorModel(active: profile, globalModel: "qwen/qwen3-coder")
                == "inkling-2-mini-jangh2")
        #expect(
            ProjectProfileResolver.effectiveDoorModel(active: nil, globalModel: "qwen/qwen3-coder")
                == "qwen/qwen3-coder")

        // Codable round-trip preserves all fields cleanly.
        let encoded = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ProjectProfile].self, from: encoded)
        #expect(decoded == [profile])
    }

    // MARK: - 3-Tier SecurityProfile & CloakDoor Fail-Closed + NEAR / Venice Routing

    @Test func securityProfileEnforcesThreeTierCapabilitiesAndRefusalMessages() throws {
        // Local Only + Downloads
        #expect(!SecurityProfile.localOnly.allowsAnyCloud)
        #expect(!SecurityProfile.localOnly.allowsNear)
        #expect(!SecurityProfile.localOnly.allowsTokenInference)
        #expect(!SecurityProfile.localOnly.allowsZkAPI)
        #expect(!SecurityProfile.localOnly.allowsNetworkServing)
        #expect(!SecurityProfile.localOnly.allowsCloudIntegrations)
        #expect(!SecurityProfile.localOnly.enforcesTorAndCover)
        #expect(SecurityProfile.localOnly.refusalMessage(for: "zkAPI Anon Inference").contains("Local Only"))

        // Anon Private Cloud (Tor + Cover + Prompt Rewriting locked ON, zkAPI only)
        #expect(SecurityProfile.anonCloud.allowsAnyCloud)
        #expect(SecurityProfile.anonCloud.allowsZkAPI)
        #expect(!SecurityProfile.anonCloud.allowsNear)
        #expect(!SecurityProfile.anonCloud.allowsTokenInference)
        #expect(!SecurityProfile.anonCloud.allowsNetworkServing)
        #expect(!SecurityProfile.anonCloud.allowsCloudIntegrations)
        #expect(SecurityProfile.anonCloud.enforcesTorAndCover)
        #expect(SecurityProfile.anonCloud.enforcesPromptRewriting)
        #expect(SecurityProfile.anonCloud.refusalMessage(for: "NEAR AI Gateway").contains("Anon Cloud"))

        // Private Cloud AI (full feature set)
        #expect(SecurityProfile.privateCloud.allowsAnyCloud)
        #expect(SecurityProfile.privateCloud.allowsNear)
        #expect(SecurityProfile.privateCloud.allowsTokenInference)
        #expect(SecurityProfile.privateCloud.allowsZkAPI)
        #expect(SecurityProfile.privateCloud.allowsNetworkServing)
        #expect(SecurityProfile.privateCloud.allowsCloudIntegrations)
        #expect(!SecurityProfile.privateCloud.enforcesTorAndCover)
        #expect(!SecurityProfile.privateCloud.enforcesPromptRewriting)

        // Codable round-trip
        let data = try JSONEncoder().encode(SecurityProfile.allCases)
        let decoded = try JSONDecoder().decode([SecurityProfile].self, from: data)
        #expect(decoded == SecurityProfile.allCases)
    }

    @Test func doorEnforcesSecurityProfileFailClosedWithHTTP403() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloak-door-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let key = SymmetricKey(size: .bits256)
        final class Recorder: @unchecked Sendable {
            var rewordCalls = 0
            var nearCalls = 0
            var veniceCalls = 0
        }
        let recorder = Recorder()

        let queue = PayQueue { _, _ in throw POSIXError(.EIO) }
        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in
                    recorder.rewordCalls += 1
                    return texts
                },
                queue: queue,
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macRoute: { .near },
                routeAllowed: { route in
                    route == .local ? nil : SecurityProfile.localOnly.refusalMessage(for: "NEAR AI Gateway")
                },
                nearComplete: { _ in
                    recorder.nearCalls += 1
                    return Data("{}".utf8)
                },
                veniceComplete: { _, _ in
                    recorder.veniceCalls += 1
                    return Data("{}".utf8)
                }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        defer { Task { await door.close() } }

        let pass = try #require(await door.add("Blocked Client"))
        let resp = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"Qwen/Qwen3.8-27B","messages":[{"role":"user","content":"Hello"}]}"#)

        #expect(resp.status == 403)
        #expect(resp.body.contains("security_profile_blocked"))
        #expect(resp.body.contains("Local Only"))
        #expect(recorder.rewordCalls == 0)
        #expect(recorder.nearCalls == 0)
        #expect(recorder.veniceCalls == 0)
    }

    @Test func doorNearRouteServesAnthropicMessagesWithPrivacyShieldAndNoRewrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloak-door-near-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let key = SymmetricKey(size: .bits256)
        final class Recorder: @unchecked Sendable {
            var nearBodies: [String] = []
            var rewordCalls = 0
        }
        let recorder = Recorder()

        let queue = PayQueue { _, _ in throw POSIXError(.EIO) }
        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in
                    recorder.rewordCalls += 1
                    return texts
                },
                queue: queue,
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macRoute: { .near },
                nearModels: {
                    Data(#"{"object":"list","data":[{"id":"Qwen/Qwen3.8-27B","object":"model","owned_by":"near-ai"}]}"#.utf8)
                },
                nearComplete: { body in
                    let text = String(decoding: body, as: UTF8.self)
                    recorder.nearBodies.append(text)
                    return Data(#"""
                    {
                      "id": "chatcmpl-near-1",
                      "object": "chat.completion",
                      "created": 1795750100,
                      "model": "Qwen/Qwen3.8-27B",
                      "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "TEE verified reply for [ENTITY_1]."},
                        "finish_reason": "stop"
                      }]
                    }
                    """#.utf8)
                },
                privacyPolicy: {
                    PrivacyShieldPolicy(
                        blockSecrets: true,
                        maskEntities: true,
                        privateTerms: ["Cedar Vault"])
                }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        defer { Task { await door.close() } }

        let check = await door.verifyConnection()
        #expect(check.ok == true)
        #expect(check.modelCount == 1)

        let pass = try #require(await door.add("Claude Code NEAR"))
        let resp = try await Self.httpPost(
            port: door.port,
            path: "/v1/messages",
            auth: pass,
            useAnthropicHeader: true,
            body: #"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"Audit Cedar Vault enclave."}]}"#)

        #expect(resp.status == 200)
        #expect(recorder.rewordCalls == 0)
        #expect(recorder.nearBodies.count == 1)
        #expect(recorder.nearBodies[0].contains("Qwen/Qwen3.8-27B"))
        #expect(recorder.nearBodies[0].contains("[ENTITY_1]"))
        #expect(!recorder.nearBodies[0].contains("Cedar Vault"))
        #expect(resp.body.contains("TEE verified reply for Cedar Vault."))
        #expect(door.spendSnapshot.spentTodayMicroUSD == 0)
    }

    @Test func doorVeniceRouteServesCompletionsWithPrivacyShieldRewriterAndBaseUSDCLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloak-door-venice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let key = SymmetricKey(size: .bits256)
        final class Recorder: @unchecked Sendable {
            var veniceBodies: [String] = []
            var identities: [String] = []
            var rewordCalls = 0
        }
        let recorder = Recorder()

        let ledger = SpendLedger(file: folder.appending(path: "spend.json"))
        let queue = PayQueue { _, _ in throw POSIXError(.EIO) }
        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in
                    recorder.rewordCalls += 1
                    return texts.map { "Paraphrased: \($0)" }
                },
                queue: queue,
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macRoute: { .venice },
                veniceModels: {
                    Data(#"{"object":"list","data":[{"id":"qwen3-coder-480b","object":"model","owned_by":"venice-ai","pricing":{"input":1.0,"output":3.0}}]}"#.utf8)
                },
                veniceComplete: { body, identity in
                    recorder.veniceBodies.append(String(decoding: body, as: UTF8.self))
                    recorder.identities.append(identity)
                    return Data(#"""
                    {
                      "id": "chatcmpl-venice-1",
                      "object": "chat.completion",
                      "created": 1795750200,
                      "model": "qwen3-coder-480b",
                      "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "Venice handled [ENTITY_1]."},
                        "finish_reason": "stop"
                      }],
                      "usage": {"prompt_tokens": 1000, "completion_tokens": 2000}
                    }
                    """#.utf8)
                },
                preferredVeniceModel: { "qwen3-coder-480b" },
                spendLedger: ledger,
                spendPolicy: { SpendPolicy(enabled: true, dailyLimitMicroUSD: 1_000_000, perCallLimitMicroUSD: 100_000) },
                requestMaxMicroUSD: { _ in 25_000 },
                privacyPolicy: {
                    PrivacyShieldPolicy(
                        blockSecrets: true,
                        maskEntities: true,
                        privateTerms: ["Helios Corp"])
                }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        defer { Task { await door.close() } }

        let pass = try #require(await door.add("OpenCode Venice"))
        let resp = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Check Helios Corp config."}]}"#)

        #expect(resp.status == 200)
        #expect(recorder.rewordCalls == 1)
        #expect(recorder.veniceBodies.count == 1)
        #expect(recorder.identities.count == 1)
        #expect(recorder.veniceBodies[0].contains("qwen3-coder-480b"))
        #expect(recorder.veniceBodies[0].contains("Paraphrased:"))
        #expect(recorder.veniceBodies[0].contains("[ENTITY_1]"))
        #expect(!recorder.veniceBodies[0].contains("Helios Corp"))
        // Omitted max_tokens must be bounded into the outbound payload when Spend Guardrails are active.
        #expect(recorder.veniceBodies[0].contains(#""max_tokens":"#))
        #expect(resp.body.contains("Venice handled Helios Corp."))
        // Exact token usage: 1000 * $1/1M + 2000 * $3/1M = 7000 micro-USD ($0.007).
        #expect(door.spendSnapshot.spentTodayMicroUSD == 7_000)
        #expect(door.spendSnapshot.recentReceipts.first?.network == .base)
        #expect(door.spendSnapshot.recentReceipts.first?.asset == "USDC")
    }

    // MARK: - Audit Regressions (Spend Guardrails + DiagnosticReport)

    @Test func doorSpendGuardEnforcesProtocolCapsUncappedUsageAndNeverReleasesOnParseFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloak-door-spend-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let key = SymmetricKey(size: .bits256)
        final class StateBox: @unchecked Sendable {
            var veniceCalls = 0
            var replyBody = ""
        }
        let state = StateBox()
        let ledger = SpendLedger(file: folder.appending(path: "spend.json"))
        let queue = PayQueue { _, _ in throw POSIXError(.EIO) }

        let door = Door(
            file: folder.appending(path: "apps"),
            wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in texts },
                queue: queue,
                exchange: { _, _ in throw POSIXError(.EIO) },
                wallet: { nil },
                key: { Data() },
                sealing: { key },
                macRoute: { .venice },
                veniceModels: {
                    Data(#"""
                    {
                      "object": "list",
                      "data": [
                        {"id": "expensive-model", "pricing": {"input": 10.0, "output": 30.0}},
                        {"id": "high-cap-model", "oaRequestLimitMicroUsd": 1000000, "pricing": {"input": 1.0, "output": 2.0}}
                      ]
                    }
                    """#.utf8)
                },
                veniceComplete: { _, _ in
                    state.veniceCalls += 1
                    return Data(state.replyBody.utf8)
                },
                spendLedger: ledger,
                spendPolicy: { SpendPolicy(enabled: true, dailyLimitMicroUSD: 1_000_000, perCallLimitMicroUSD: 100_000) }, // $0.10/call, $1/day
                requestMaxMicroUSD: { _ in 50_000 }),
            port: { 0 })

        await door.open()
        try #require(door.state == .open)
        defer { Task { await door.close() } }
        let pass = try #require(await door.add("Budget Client"))

        // 1. Explicit max_tokens whose worst-case cost ($0.30 = 10k * $30/1M) exceeds $0.10 cap -> blocked BEFORE paying!
        let tooBig = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"expensive-model","max_tokens":10000,"messages":[{"role":"user","content":"Write a book"}]}"#)
        #expect(tooBig.status == 402)
        #expect(tooBig.body.contains("budget_limit_exceeded"))
        #expect(state.veniceCalls == 0)

        // 2. Protocol cap (`oaRequestLimitMicroUsd` = $1.00) exceeding $0.10 per-call cap -> blocked BEFORE paying!
        let protoCapBlocked = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"high-cap-model","max_tokens":100,"messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(protoCapBlocked.status == 402)
        #expect(state.veniceCalls == 0)

        // 3. Large actual usage is NEVER clipped down to $0.05: 5k input ($0.05) + 10k output ($0.30) = $0.35 (350_000 micro-USD).
        state.replyBody = #"""
        {
          "id": "chatcmpl-big",
          "object": "chat.completion",
          "created": 1795750300,
          "model": "expensive-model",
          "choices": [{"index": 0, "message": {"role": "assistant", "content": "Big reply"}, "finish_reason": "stop"}],
          "usage": {"prompt_tokens": 5000, "completion_tokens": 10000}
        }
        """#
        let ok = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"expensive-model","max_tokens":2000,"messages":[{"role":"user","content":"Small prompt"}]}"#)
        #expect(ok.status == 200)
        #expect(state.veniceCalls == 1)
        #expect(door.spendSnapshot.spentTodayMicroUSD == 350_000)

        // 4. Post-payment reply that fails to parse MUST mark `.ambiguous` and NEVER release the reservation!
        state.replyBody = "not-valid-json-after-payment"
        let badParse = try await Self.httpPost(
            port: door.port,
            path: "/v1/chat/completions",
            auth: "Bearer \(pass)",
            body: #"{"model":"expensive-model","max_tokens":2000,"messages":[{"role":"user","content":"Trigger bad parse"}]}"#)
        #expect(badParse.status == 502)
        #expect(state.veniceCalls == 2)
        #expect(door.spendSnapshot.recentReceipts.first?.status == .ambiguous)
        #expect(door.spendSnapshot.spentTodayMicroUSD > 350_000)
    }

    @Test func diagnosticReportRedactsBeforeTruncationAndEnforcesLiveTimeout() {
        // 1. An email straddling the 240-char truncation boundary MUST be scrubbed completely, leaving zero fragment.
        let padding = String(repeating: "x", count: 232)
        let rawLine = "\(padding) alice.secret@private-domain.example trailing info"
        let processed = DiagnosticReport.redactAndTruncateLogLines([rawLine], maxLines: 10, maxLineLength: 240)
        #expect(processed.count == 1)
        #expect(!processed[0].contains("alice"))
        #expect(!processed[0].contains("private-domain"))
        #expect(processed[0].contains("<redacted-email>") || processed[0].hasSuffix("…"))

        // 2. A hung child process that never closes stdout MUST terminate promptly at the timeout deadline.
        let start = ContinuousClock.now
        let result = DiagnosticReport.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            timeoutSeconds: 0.25)
        let elapsed = start.duration(to: .now)
        #expect(result.timedOut == true)
        #expect(elapsed < .seconds(2), "Expected timeout abort well under 2s, took \(elapsed)")
    }

    // MARK: - PrivacyShield 128 KB Perf Guard

    @Test func privacyShieldScans128KBNoisyPayloadQuickly() {
        let noisyLine = String(repeating: "const configValue = computeMetric(alpha, beta, gamma); ", count: 4) + "\n"
        let payload = String(repeating: noisyLine, count: 600) // ~135 KB
        let start = ContinuousClock.now
        let findings = PrivacyShield.detectSecrets(in: payload)
        let elapsed = start.duration(to: .now)
        #expect(findings.isEmpty)
        #expect(elapsed < .milliseconds(50), "Expected fast bounded scan on 128 KB payload, took \(elapsed)")
    }

    // MARK: - Helper

    private static func httpPost(
        port: UInt16, path: String, auth: String, useAnthropicHeader: Bool = false, body: String
    ) async throws -> (status: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useAnthropicHeader {
            req.setValue(auth, forHTTPHeaderField: "x-api-key")
        } else {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
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
