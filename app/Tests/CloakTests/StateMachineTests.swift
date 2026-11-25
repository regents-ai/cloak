@testable import CloakChat
import CloakControl
import CloakDoor
import CloakHost
@testable import CloakSupervisor
import CryptoKit
import Foundation
import Synchronization
import Testing

/// Fast pure-Swift state-machine checks (Decision R4b): verifies explicit and
/// shadow state transitions across `Phase`, `ConversationStore`, `Remote`,
/// `PayQueue`, `Payer`, and `Door` without booting a VM or touching the network
/// or keychain.
@MainActor
@Suite
struct StateMachineTests {
    // MARK: - Supervisor Phase FSM

    @Test func phaseTransitionsAndRefusals() {
        #expect(Phase.paused.after(.start) == .preparing(.run))
        #expect(Phase.paused.after(.verify) == .preparing(.verify))
        #expect(Phase.paused.after(.resume) == .preparing(.run))

        // Restart from running moves to stopping(.restart), then preparing(.run).
        #expect(Phase.running.after(.restart) == .stopping(.restart))
        #expect(Phase.stopping(.restart).after(.stopped) == .preparing(.run))

        // Pause, sleep or stop during a restart cancels the restart.
        #expect(Phase.stopping(.restart).after(.pause) == .stopping(.paused))
        #expect(Phase.stopping(.restart).after(.sleep) == .stopping(.paused))
        #expect(Phase.stopping(.restart).after(.stop) == .stopping(.ready))

        // Stopping to paused refuses start, accepts quit.
        #expect(Phase.stopping(.paused).after(.start) == nil)
        #expect(Phase.stopping(.paused).after(.quit) == .stopping(.quit))

        // Verify while running and resume while ready are refused.
        #expect(Phase.running.after(.verify) == nil)
        #expect(Phase.ready.after(.resume) == nil)
    }

    // MARK: - Keychain / Sealed Store Protection

    @Test nonisolated func conversationKeyRefusesToMintWhenSiblingSealedFileExists() async throws {
        let root = URL(filePath: "/tmp").appending(path: "cloak-sm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appending(path: "conversations")
        let deposit = root.appending(path: "wallet/deposit")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deposit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sealed-bytes".utf8).write(to: deposit)

        let minted = Mutex(false)
        let key = try await ConversationStore.key(
            for: conversations,
            alsoSealed: [deposit],
            find: { nil },
            make: {
                minted.withLock { $0 = true }
                return SymmetricKey(size: .bits256)
            })
        #expect(key == nil)
        #expect(!minted.withLock { $0 })
    }

    // MARK: - Remote.look Concurrent Deposit Replacement Race

    @Test func lookDoesNotDeleteADepositReplacedConcurrently() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-sm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let deposits = DepositStore(folder: folder, key: key)
        let oldDeposit = Data(#"{"id":"old"}"#.utf8)
        let newDeposit = Data(#"{"id":"new"}"#.utf8)
        try deposits.keep(oldDeposit)

        let goneReply = Data(
            #"{"ok":{"balance":"0","least":"1000000","setup":true,"models":[],"deposit":{"deposit":"1000000","spent":"0","gone":true}}}"#
                .utf8)

        let look = try await Remote.look(address: "0x01", deposits: deposits) { build, _ in
            _ = try build()
            // Concurrent Remote.complete writes a brand-new deposit before look finishes.
            try deposits.keep(newDeposit)
            return goneReply
        }

        #expect(look.deposit?.gone == true)
        #expect(try deposits.load() == newDeposit)
    }

    // MARK: - PayQueue Cancellation & Hold Error Precedence

    @Test func payQueueDoesNotDispatchWhenCancelledBeforeExchange() async throws {
        let dispatched = Mutex(0)
        let queue = PayQueue(line: { _, _ in
            dispatched.withLock { $0 += 1 }
            return AsyncThrowingStream { $0.finish() }
        })

        let task = Task {
            try await queue.complete(Data(#"{"model":"m","messages":[]}"#.utf8), identity: String(repeating: "a", count: 64), rank: .owner)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let stop as PayStop {
            #expect(stop.code == .cancelled)
        }
        #expect(dispatched.withLock { $0 } == 0)
    }

    @Test func payQueueMalformedHeldFrameThrowsFailedNotUnreachable() async {
        let queue = PayQueue(line: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.held(Data(#"{"held":true}"#.utf8)))
                continuation.yield(.held(Data("not-json".utf8)))
                continuation.finish()
            }
        })
        do {
            _ = try await queue.complete(
                Data(#"{"model":"m","messages":[]}"#.utf8),
                identity: String(repeating: "b", count: 64),
                rank: .owner)
            Issue.record("expected PayStop(.failed)")
        } catch {
            #expect(error.code == .failed)
        }
    }

    @Test func payQueueExtractsDaemonErrorReasonIntoStopDetail() async {
        let queue = PayQueue(line: { _, _ in
            AsyncThrowingStream { continuation in
                let answer = PayFrame.Answer(status: 502, body: #"{"error":"payment RPC unavailable; retry the saved funding attempt"}"#)
                continuation.yield(.answer((try? JSONEncoder().encode(answer)) ?? Data()))
                continuation.finish()
            }
        })
        do {
            _ = try await queue.view(chain: true)
            Issue.record("expected PayStop(.failed)")
        } catch {
            #expect(error.code == .failed)
            #expect(error.detail.contains("502"))
            #expect(error.detail.contains("payment RPC unavailable"))
        }
    }

    // MARK: - Payer Pause & Failed State Loop Safety

    @Test func payerPauseClearsModelsAndFailedIsNotMoving() async throws {
        final class Switch: @unchecked Sendable { var on = true }
        let running = Switch()
        let payer = Payer(
            queue: PayQueue(line: { ask, _ in
                AsyncThrowingStream { continuation in
                    switch ask {
                    case .view:
                        let view = #"{"status":200,"body":"{\"wallet\":{\"has_note\":false,\"pending_request\":false}}"}"#
                        continuation.yield(.answer(Data(view.utf8)))
                    case .call:
                        let models = #"{"status":200,"body":"{\"data\":[{\"id\":\"m1\",\"oa_request_limit_micro_usd\":100}]}"}"#
                        continuation.yield(.answer(Data(models.utf8)))
                    case .request:
                        break
                    }
                    continuation.finish()
                }
            }),
            running: { running.on },
            expiry: nil,
            keep: { _ in },
            chosen: { nil })

        try await payer.loadModels()
        #expect(payer.models?.count == 1)

        // Pausing clears cached models and prices so stale data does not survive restarts.
        running.on = false
        await payer.refresh()
        #expect(payer.state == .unread)
        #expect(payer.models == nil)
        #expect(payer.prices == nil)

        // Unknown phase produces .failed and must not spin the polling loop.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let view = try decoder.decode(DepositView.self, from: Data(#"{"wallet":{"has_note":false,"pending_request":false}}"#.utf8))
        let funding = try decoder.decode(
            FundingStatus.self,
            from: Data(#"{"address":"0x0000000000000000000000000000000000000001","chain_id":1,"eth_balance":"0","phase":"mystery_phase"}"#.utf8))
        let withdrawal = try decoder.decode(
            WithdrawalStatus.self,
            from: Data(#"{"eth_balance":"0","private_balance":0,"phase":"no_note"}"#.utf8))
        #expect(Payer.state(view: view, funding: funding, withdrawal: withdrawal, sending: false) == .failed("mystery_phase"))
    }

    // MARK: - Venice Tolerant Models Decoding & Amount Parsing (Phase 4)

    @Test func veniceModelsToleratesMalformedEntries() async throws {
        let json = """
            {"data":[
                {"id":"good-model","type":"text","model_spec":{"name":"Good Model","privacy":"private","offline":false,"availableContextTokens":32768,"capabilities":{"supportsTeeAttestation":true},"pricing":{"input":{"usd":0.5},"output":{"usd":1.5}}}},
                {"id":"weird-future-model","type":"text","model_spec":{"name":"Broken","privacy":"experimental_new_tier"}}
            ]}
            """
        let models = try await Venice.models { _ in
            VeniceResponse(status: 200, headers: [:], body: AsyncThrowingStream { c in
                c.yield(Data(json.utf8))
                c.finish()
            })
        }
        #expect(models.count == 1)
        #expect(models[0].id == "good-model")
        #expect(models[0].tier == .tee)
        #expect(Amount(dollars: "$10.50")?.units == 10_500_000)
        #expect(Amount(dollars: "0") == nil)
        #expect(Amount(dollars: "-5") == nil)
    }

    // MARK: - Local Model Auto-Selection & Unfiltered LoRA (16 / 24 / 32 / 48 GB Tiers)

    @Test func localModelTiersSelectByMacMemoryAndDecodeAdapter() throws {
        let loraFile = Manifest.Model.File(
            path: "Inkling-2-Mini-Uncensored-LoRA.gguf",
            size: 43_805_184,
            sha256: "42914b85c874e7fe249e93f0ac6e8abf08dc0bdf32aa1ec46c72714e64808f12",
            url: URL(string: "https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF/resolve/40886ab636cabb4decf4998224f790b462ab048e/Inkling-2-Mini-Uncensored-LoRA.gguf")!
        )
        let adapter = Manifest.Model.Adapter(name: "inkling-mini-uncensored-lora", label: "Unfiltered (AtomicChat LoRA)", file: loraFile)
        let qwen = Manifest.Model(name: "small-lead-gguf-grammar", label: "Qwen 3.5 9B", engine: .llama, memory: 7 << 30, files: [])
        let jangh2 = Manifest.Model(
            name: "inkling-mini-jangh2", label: "Inkling 2 Mini (Fast)", engine: .vmlx,
            memory: UInt64(9.5 * Double(1 << 30)), files: [])
        let unsloth24 = Manifest.Model(
            name: "inkling-mini-ud-q3-gguf", label: "Inkling 2 Mini (24 GB GGUF)", engine: .llama, memory: 14 << 30, files: [], unfilteredLora: adapter)
        let xylolabs32 = Manifest.Model(
            name: "inkling-mini-nvfp4-gguf", label: "Inkling 2 Mini (Full Quality)", engine: .llama, memory: 18 << 30, files: [], unfilteredLora: adapter)
        let manifest = Manifest(
            release: "0.2.0", build: "test", cloakMemory: 10 << 30, model: qwen.name,
            answerModels: [qwen, jangh2, unsloth24, xylolabs32], pins: [])

        func bestModel(ramGiB: UInt64, graphicsGiB: UInt64) -> String? {
            let hw = Checks.Hardware(appleSilicon: true, memory: ramGiB << 30, graphicsLimit: graphicsGiB << 30)
            let fitting = manifest.answerModels.filter { manifest.answerCheck($0, hardware: hw).1 == nil }
            return (fitting.last { $0.engine == .vmlx } ?? fitting.last)?.name
        }

        func bestLlamaModel(ramGiB: UInt64, graphicsGiB: UInt64) -> String? {
            let hw = Checks.Hardware(appleSilicon: true, memory: ramGiB << 30, graphicsLimit: graphicsGiB << 30)
            return manifest.answerModels.filter { $0.engine == .llama && manifest.answerCheck($0, hardware: hw).1 == nil }.last?.name
        }

        // With vMLX bundled: 16 GB, 24 GB, 32 GB, and 48 GB Macs all fit & recommend fast 10.2 GB Inkling 2 Mini (JANGH2)
        #expect(bestModel(ramGiB: 16, graphicsGiB: 11) == jangh2.name)
        #expect(bestModel(ramGiB: 24, graphicsGiB: 16) == jangh2.name)
        #expect(bestModel(ramGiB: 32, graphicsGiB: 22) == jangh2.name)
        // GGUF fallback tiers remain intact: 16 GB -> Qwen 3.5 9B, 24 GB -> Unsloth 13.6 GB, >=32 GB -> Xylolabs NVFP4 17.6 GB
        #expect(bestLlamaModel(ramGiB: 16, graphicsGiB: 11) == qwen.name)
        #expect(bestLlamaModel(ramGiB: 24, graphicsGiB: 16) == unsloth24.name)
        #expect(bestLlamaModel(ramGiB: 24, graphicsGiB: 18) == unsloth24.name)
        #expect(bestLlamaModel(ramGiB: 32, graphicsGiB: 22) == xylolabs32.name)
        // Concurrency checks: 16/24 GB Macs rest rewriter before waking Inkling; 48 GB runs concurrently
        let hw16 = Checks.Hardware(appleSilicon: true, memory: 16 << 30, graphicsLimit: 11 << 30)
        let hw24 = Checks.Hardware(appleSilicon: true, memory: 24 << 30, graphicsLimit: 18 << 30)
        let hw48 = Checks.Hardware(appleSilicon: true, memory: 48 << 30, graphicsLimit: 36 << 30)
        #expect(!manifest.canRunConcurrently(jangh2, hardware: hw16))
        #expect(!manifest.canRunConcurrently(unsloth24, hardware: hw24))
        #expect(manifest.canRunConcurrently(xylolabs32, hardware: hw48))
        #expect(adapter.repositoryURL?.absoluteString == "https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF")
        #expect(adapter.asDownloadModel().memory == 0)
        #expect(adapter.asDownloadModel().size == 43_805_184)

        // 8 GB Apple Silicon Mac: neither Local models nor Cloak's rewriter Start fit (triggers NEAR onboarding branch).
        #expect(bestModel(ramGiB: 8, graphicsGiB: 5) == nil)
        #expect(bestLlamaModel(ramGiB: 8, graphicsGiB: 5) == nil)
        let hwIntel = Checks.Hardware(appleSilicon: false, memory: 32 << 30, graphicsLimit: 24 << 30)
        #expect(manifest.answerCheck(qwen, hardware: hwIntel).1?.reason == .unsupportedHardware)
    }

    // MARK: - Keychain Wallet & Key Service Isolation

    @Test func keychainServiceIdentifiersAreStrictlyIsolated() {
        let services = [
            Keychain.service,
            WalletKeychain.service,
            VeniceWalletKeychain.service,
            ProviderKeychain.near.service,
            ProviderKeychain.venice.service,
        ]
        #expect(Set(services).count == services.count)
        #expect(WalletKeychain.service != VeniceWalletKeychain.service)
        #expect(KeychainStore.accessGroup == "367G3Z7G3J.sh.regents.cloak")
        let dp = KeychainStore.dataProtectionQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: WalletKeychain.service,
        ])
        #expect((dp[kSecUseDataProtectionKeychain as String] as? Bool) == true)
        #expect((dp[kSecAttrAccessGroup as String] as? String) == "367G3Z7G3J.sh.regents.cloak")
        #expect(KeychainStore.usesDataProtection == false)
    }

    // MARK: - Dollar Amount Validation (Crypto Funding Fail Paths)

    @Test func amountParsingRejectsInvalidAndZeroInputs() {
        #expect(Amount(dollars: "") == nil)
        #expect(Amount(dollars: "   ") == nil)
        #expect(Amount(dollars: "abc") == nil)
        #expect(Amount(dollars: "0") == nil)
        #expect(Amount(dollars: "0.00") == nil)
        #expect(Amount(dollars: "-10") == nil)
        #expect(Amount(dollars: "1.2345678") == nil)
        #expect(Amount(dollars: "$5")?.units == 5_000_000)
        #expect(Amount(dollars: "5.25")?.units == 5_250_000)
    }

    // MARK: - Startup Steps & Widget Bridge

    @Test func startStepsAndWidgetBridgeActionURLs() {
        #expect(Supervisor.StartStep.allCases == [.checking, .tor, .rewriter, .guest, .verifying])
        for step in Supervisor.StartStep.allCases {
            let wordCount = step.menuTitle.split(separator: " ").count
            #expect(wordCount >= 1 && wordCount <= 3)
            #expect(!step.detail(cover: true).isEmpty)
            #expect(!step.detail(cover: false).isEmpty)
        }
        #expect(Supervisor.StartStep.guest.detail(cover: true).contains("cover"))
        #expect(!Supervisor.StartStep.guest.detail(cover: false).contains("cover"))

        for command in WidgetCommand.allCases {
            let url = WidgetBridge.actionURL(for: command)
            #expect(WidgetBridge.command(from: url) == command)
        }
        #expect(WidgetBridge.command(from: URL(string: "https://regents.sh/cloak")!) == nil)
        #expect(WidgetBridge.command(from: URL(string: "cloak://action/unknown")!) == nil)
    }

    // MARK: - Inkling Multi-Turn Reasoning Preservation

    @Test func localLlamaPreservesThinkingAcrossTurns() throws {
        // 1. Outgoing multi-turn request carries reasoning_content on assistant turns only.
        let data = try #require(LocalLlama.request([
            .user("Pick a secret number."),
            .assistant("42.", thinking: "I will pick 42 as the answer."),
            .user("Why did you pick it?"),
        ]))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let msgs = try #require(obj["messages"] as? [[String: Any]])
        #expect(msgs.count == 3)
        #expect(msgs[0]["reasoning_content"] == nil)
        #expect(msgs[1]["role"] as? String == "assistant")
        #expect(msgs[1]["content"] as? String == "42.")
        #expect(msgs[1]["reasoning_content"] as? String == "I will pick 42 as the answer.")
        #expect(msgs[2]["reasoning_content"] == nil)

        // 2. Empty thinking is omitted cleanly.
        let noThink = try #require(LocalLlama.request([
            .user("Hi"),
            .assistant("Hello", thinking: ""),
            .user("Again"),
        ]))
        let noThinkMsgs = try #require((JSONSerialization.jsonObject(with: noThink) as? [String: Any])?["messages"] as? [[String: Any]])
        #expect(noThinkMsgs[1]["reasoning_content"] == nil)

        // 3. Incoming completion decodes both content and reasoning_content.
        let replyJSON = Data(#"{"choices":[{"message":{"role":"assistant","content":"Done.","reasoning_content":"Step 1 -> Step 2"}}]}"#.utf8)
        let parsed = try #require(LocalLlama.answer(replyJSON))
        #expect(parsed.text == "Done.")
        #expect(parsed.thinking == "Step 1 -> Step 2")

        // 4. Turn encodes thinking and stays backwards-compatible with older saved JSON lacking thinking.
        let turn = Turn(original: "Q", reworded: nil, answer: "A", thinking: "Chain of thought")
        let encoded = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(Turn.self, from: encoded)
        #expect(decoded.thinking == "Chain of thought")
        let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","original":"Old Q","answer":"Old A"}"#.utf8)
        let legacy = try JSONDecoder().decode(Turn.self, from: legacyJSON)
        #expect(legacy.answer == "Old A")
        #expect(legacy.thinking == nil)
    }

    // MARK: - NEAR AI Gateway Trace Export (Letta Trajectory v1)

    @Test func nearTraceExporterOnlyExportsAnsweredNearChatsInTrajectoryFormat() throws {
        // Non-NEAR chats (Local, Token, V, Agent) must always be refused.
        var local = Conversation(turns: [Turn(original: "Hello", reworded: nil, answer: "Hi")])
        local.llama = true
        #expect(throws: NearTraceExporter.Failure.notNearChat) {
            _ = try NearTraceExporter.encode(local)
        }

        var token = Conversation(turns: [Turn(original: "Hello", reworded: "Reworded", answer: "Hi")])
        token.token = true
        #expect(throws: NearTraceExporter.Failure.notNearChat) {
            _ = try NearTraceExporter.encode(token)
        }

        let anonV = Conversation(turns: [Turn(original: "Hello", reworded: "Reworded", answer: "Hi")])
        #expect(throws: NearTraceExporter.Failure.notNearChat) {
            _ = try NearTraceExporter.encode(anonV)
        }

        // NEAR chat without answered turns is refused.
        var emptyNear = Conversation(turns: [Turn(original: "Draft", reworded: nil, answer: nil)])
        emptyNear.near = true
        #expect(throws: NearTraceExporter.Failure.noAnsweredTurns) {
            _ = try NearTraceExporter.encode(emptyNear)
        }

        // Answered NEAR chat exports Letta Trajectory v1 using Turn.sent and omits unanswered drafts.
        var nearChat = Conversation(
            created: Date(timeIntervalSince1970: 1_795_400_000),
            turns: [
                Turn(original: "Private original", reworded: "Sent prompt", answer: "Enclave reply"),
                Turn(original: "Unanswered draft", reworded: nil, answer: nil),
            ]
        )
        nearChat.near = true

        let tempDir = FileManager.default.temporaryDirectory.appending(path: "cloak-trace-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exported = try NearTraceExporter.export(nearChat, to: tempDir)
        #expect(exported.conversationID == nearChat.id)
        #expect(exported.turnCount == 1)
        #expect(FileManager.default.fileExists(atPath: tempDir.appending(path: ".metadata_never_index").path))

        let backupValues = try tempDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backupValues.isExcludedFromBackup == true)

        let raw = try Data(contentsOf: exported.url)
        let records = try #require(JSONSerialization.jsonObject(with: raw) as? [[String: String]])
        #expect(records.count == 3)
        #expect(records[0]["role"] == "meta")
        #expect(records[0]["source"] == "cloak")
        #expect(records[0]["model"] == Near.model)
        #expect(records[1]["role"] == "user")
        #expect(records[1]["content"] == "Sent prompt")
        #expect(records[2]["role"] == "assistant")
        #expect(records[2]["content"] == "Enclave reply")

        let scanned = NearTraceExporter.scan(in: tempDir)
        #expect(scanned[nearChat.id]?.turnCount == 1)

        try NearTraceExporter.remove(conversationID: nearChat.id, from: tempDir)
        #expect(NearTraceExporter.scan(in: tempDir).isEmpty)
    }

    // MARK: - Append-Only Cover Traffic Log

    @Test @MainActor func coverLogAppendsPersistsAndClearsLastHourOrAll() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "cloak-cover-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let file = tempDir.appending(path: "cover-log.jsonl")

        let now = Date(timeIntervalSince1970: 1_795_500_000)
        let old = CoverEntry(timestamp: now.addingTimeInterval(-7200), url: "https://en.wikipedia.org/wiki/Main_Page", status: 200, bytes: 12_345, durationMs: 420)
        let recent = CoverEntry(timestamp: now.addingTimeInterval(-600), url: "https://news.ycombinator.com/", status: 200, bytes: 8_192, durationMs: 310)

        let log = CoverLog(file: file)
        log.append(old)
        log.append(recent)
        #expect(log.entries.count == 2)
        #expect(log.countInLastHour(now: now) == 1)

        // Persists across reload.
        let reloaded = CoverLog(file: file)
        #expect(reloaded.entries == [old, recent])

        // Clear Last Hour removes only entries within the past 60 minutes.
        reloaded.clearLastHour(now: now)
        #expect(reloaded.entries == [old])
        #expect(reloaded.countInLastHour(now: now) == 0)

        // Clear All empties memory and removes the file.
        reloaded.clearAll()
        #expect(reloaded.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Default pool holds all 58 curated HTTPS URLs.
        #expect(CoverTraffic.defaultPool.count == 58)
        #expect(CoverTraffic.defaultPool.allSatisfy { $0.hasPrefix("https://") })
    }

    @Test("Payer prefers recent quality-for-cost default model over alphabetical lowest-cap fallback")
    @MainActor
    func payerPrefersKnownDefaultModel() async throws {
        func queueReturning(_ bodyJSON: String) -> PayQueue {
            let envelope = try! JSONSerialization.data(withJSONObject: ["status": 200, "body": bodyJSON])
            return PayQueue(line: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.answer(envelope))
                    continuation.finish()
                }
            })
        }

        let catalog = #"{"data":[{"id":"aion-labs/aion-2.0","oa_request_limit_micro_usd":1000000},{"id":"anthropic/claude-haiku-5.5","oa_request_limit_micro_usd":1000000},{"id":"anthropic/claude-sonnet-5.5","oa_request_limit_micro_usd":2000000},{"id":"anthropic/claude-opus-5.5","oa_request_limit_micro_usd":3000000}]}"#
        let payer = Payer(queue: queueReturning(catalog), running: { true }, expiry: nil, keep: { _ in }, chosen: { nil })
        try await payer.loadModels()
        #expect(payer.model == "anthropic/claude-sonnet-5.5")

        // Explicit user pick still wins.
        let explicitPayer = Payer(
            queue: queueReturning(catalog), running: { true }, expiry: nil, keep: { _ in }, chosen: { "anthropic/claude-opus-5.5" })
        try await explicitPayer.loadModels()
        #expect(explicitPayer.model == "anthropic/claude-opus-5.5")

        // Fallback to lowest-cap model if no preferred defaults are listed.
        let fallback = #"{"data":[{"id":"custom/high-cap","oa_request_limit_micro_usd":3000000},{"id":"custom/low-cap","oa_request_limit_micro_usd":1000000}]}"#
        let fallbackPayer = Payer(queue: queueReturning(fallback), running: { true }, expiry: nil, keep: { _ in }, chosen: { nil })
        try await fallbackPayer.loadModels()
        #expect(fallbackPayer.model == "custom/low-cap")
    }

    @Test("Markdown and LatexMath parse display/inline LaTeX without breaking currency or code")
    func markdownAndLatexParsing() {
        let einstein = #"""
        Sure — here's Einstein's field equations:

        \[
        G_{\mu\nu}
        = R_{\mu\nu} - \frac{1}{2} R g_{\mu\nu}
        = \frac{8\pi G}{c^4} T_{\mu\nu}
        \]

        where \(G_{\mu\nu}\) is the Einstein tensor and \(T_{\mu\nu}\) is stress-energy.
        """#
        let blocks = Markdown.blocks(einstein)
        #expect(blocks.count == 3)
        guard case .paragraph(let intro) = blocks[0],
            case .math(let displayLatex) = blocks[1],
            case .paragraph(let explanation) = blocks[2]
        else {
            Issue.record("Unexpected block layout: \(blocks)")
            return
        }
        #expect(intro.contains("Einstein"))
        #expect(displayLatex.contains(#"\frac{8\pi G}{c^4}"#))

        // AST parses fractions, scripts, and Greek letters cleanly.
        let ast = LatexMath.parse(displayLatex)
        #expect(ast.contains { if case .fraction = $0 { return true }; return false })
        #expect(ast.contains { if case .script = $0 { return true }; return false })

        // Inline \( ... \) splits cleanly into serif runs with subscript roles.
        let inlineParts = LatexMath.splitInline(explanation)
        #expect(inlineParts == [
            .markdown("where "),
            .math(#"G_{\mu\nu}"#, display: false),
            .markdown(" is the Einstein tensor and "),
            .math(#"T_{\mu\nu}"#, display: false),
            .markdown(" is stress-energy."),
        ])
        let runs = LatexMath.inlineRuns(#"G_{\mu\nu}"#)
        #expect(runs.map(\.text).joined() == "Gμν")
        #expect(runs.first?.italic == true)
        #expect(runs.last?.role == .sub)

        // Currency amounts and code spans must NOT be treated as math.
        let currency = "Deposit $5 or $10 ($5–$10, $0.10 | $0.50) and keep `\\(x^2\\)` and `$E=mc^2$` as code."
        #expect(LatexMath.splitInline(currency) == [.markdown(currency)])

        // Single-dollar inline math works when valid.
        let singleDollar = "Energy is $E = mc^2$ and $\\hbar\\omega$."
        #expect(LatexMath.splitInline(singleDollar) == [
            .markdown("Energy is "),
            .math("E = mc^2", display: false),
            .markdown(" and "),
            .math(#"\hbar\omega"#, display: false),
            .markdown("."),
        ])

        // $$...$$ and \begin{aligned}...\end{aligned} display blocks parse cleanly.
        let aligned = #"""
        $$
        \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
        $$

        \begin{aligned}
        \nabla \cdot \vec{E} &= \frac{\rho}{\varepsilon_0} \\
        \nabla \times \vec{B} &= \mu_0 \vec{J}
        \end{aligned}
        """#
        let alignedBlocks = Markdown.blocks(aligned)
        #expect(alignedBlocks.count == 2)
        if case .math(let sumLatex) = alignedBlocks[0] {
            let nodes = LatexMath.parse(sumLatex)
            #expect(nodes.contains { if case .script(.bigOp("∑", _), _, _, true) = $0 { return true }; return false })
        } else {
            Issue.record("Expected $$ block")
        }
        if case .math(let maxwellLatex) = alignedBlocks[1] {
            let nodes = LatexMath.parse(maxwellLatex)
            #expect(nodes.contains { if case .matrix(kind: .aligned, let rows) = $0 { return rows.count == 2 }; return false })
        } else {
            Issue.record("Expected aligned block")
        }
    }

    @Test func localContextMemoryFolderSearchAndBuilder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "cloak-local-context-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }

        let memDir = root.appending(path: "mem", directoryHint: .isDirectory)
        let hermesDir = root.appending(path: "hermes", directoryHint: .isDirectory)
        let docsDir = root.appending(path: "docs", directoryHint: .isDirectory)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)

        // 1. Hermes-compatible memory store caps USER.md at 1,375 and MEMORY.md at 2,200.
        let store = LocalMemoryStore(folder: memDir, hermesFolder: hermesDir)
        let longUser = String(repeating: "u", count: 2_000)
        let longMemory = String(repeating: "m", count: 3_000)
        try store.save(.init(user: longUser, memory: longMemory), syncHermes: true)
        let loaded = store.load(syncHermes: false)
        #expect(loaded.user.count == LocalMemoryStore.userLimit)
        #expect(loaded.memory.count == LocalMemoryStore.memoryLimit)
        #expect(fm.fileExists(atPath: memDir.appending(path: ".metadata_never_index").path))
        #expect(fm.fileExists(atPath: hermesDir.appending(path: "USER.md").path))

        // 2. Approved folder search matches markdown/text while strictly skipping .env, dotfiles, and .pem keys.
        try "Cloak v0.2 roadmap: ship offline memory and local folder search.".write(
            to: docsDir.appending(path: "roadmap.md"), atomically: true, encoding: .utf8)
        try "API_SECRET=roadmap_super_secret".write(
            to: docsDir.appending(path: ".env"), atomically: true, encoding: .utf8)
        try "PRIVATE KEY roadmap".write(
            to: docsDir.appending(path: "id.pem"), atomically: true, encoding: .utf8)
        let matches = ApprovedFolderSearch.search(query: "What is on the roadmap?", folders: [docsDir.path])
        #expect(matches.count == 1)
        #expect(matches[0].relativePath == "docs/roadmap.md")
        #expect(matches[0].snippet.contains("offline memory"))

        // 3. LocalAttachment reads text, UTF-16, RTF, and OCR images, and rejects binary blobs.
        let txtFile = docsDir.appending(path: "notes.txt")
        try "Meeting notes for Tuesday launch.".write(to: txtFile, atomically: true, encoding: .utf8)
        let attachment = try LocalAttachment.from(url: txtFile)
        #expect(attachment.kind == .file)
        #expect(attachment.text.contains("Tuesday launch"))

        let utf16File = docsDir.appending(path: "utf16.txt")
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append("UTF16 Local Note".data(using: .utf16LittleEndian)!)
        try utf16Data.write(to: utf16File)
        let utf16Attachment = try LocalAttachment.from(url: utf16File)
        #expect(utf16Attachment.kind == .file)
        #expect(utf16Attachment.text.contains("UTF16 Local Note"))

        let rtfFile = docsDir.appending(path: "memo.rtf")
        let rtfContent = #"{\rtf1\ansi Cloak Local RTF Memo}"#
        try rtfContent.write(to: rtfFile, atomically: true, encoding: .utf8)
        let rtfAttachment = try LocalAttachment.from(url: rtfFile)
        #expect(rtfAttachment.kind == .document)
        #expect(rtfAttachment.text.contains("Cloak Local RTF Memo"))

        let binFile = docsDir.appending(path: "blob.dat")
        try Data([0x00, 0x01, 0x02, 0x00]).write(to: binFile)
        #expect(throws: LocalAttachment.ReadError.self) {
            _ = try LocalAttachment.from(url: binFile)
        }

        let turnWithAttachment = Turn(
            original: "Check this", reworded: nil,
            attachments: [AttachedFile(name: "notes.txt", kind: LocalAttachment.Kind.file.rawValue)])
        let encodedTurn = try JSONEncoder().encode(turnWithAttachment)
        let decodedTurn = try JSONDecoder().decode(Turn.self, from: encodedTurn)
        #expect(decodedTurn.attachments?.first?.name == "notes.txt")

        let priorBlock = LocalContextBuilder.attachmentsBlock(for: [attachment])
        #expect(priorBlock?.contains("notes.txt") == true)

        // 4. MacSnapshot includes hardware/OS/time fields without crashing.
        let snapshot = MacSnapshot.current()
        #expect(snapshot.contains("Current local time:"))
        #expect(snapshot.contains("OS: macOS"))

        // 5. LocalContextBuilder stays nil when everything is off, and injects cleanly when enabled.
        let disabled = await LocalContextBuilder.build(query: "hi", options: LocalContextOptions(), memoryStore: store)
        #expect(disabled == nil)

        try store.save(.init(user: "Prefers concise Swift answers.", memory: "Shipping Cloak v0.2."), syncHermes: false)
        let enabled = await LocalContextBuilder.build(
            query: "Summarize the roadmap",
            options: LocalContextOptions(shareMacInfo: true, useMemory: true, approvedFolders: [docsDir.path]),
            attachments: [attachment],
            memoryStore: store)
        let built = try #require(enabled)
        #expect(built.contains("[Local Context — stays strictly on this Mac"))
        #expect(built.contains("## This Mac"))
        #expect(built.contains("Prefers concise Swift answers."))
        #expect(built.contains("docs/roadmap.md"))
        #expect(built.contains("notes.txt"))

        let injected = LocalContextBuilder.inject(built, into: "Summarize the roadmap")
        #expect(injected.hasSuffix("User message:\nSummarize the roadmap"))
    }

    @Test func offlineDatasetsScaleProgressivelyAndComputeMissingDeltas() {
        for dataset in OfflineDataset.all {
            #expect(dataset.minLevel == 1)
            #expect(dataset.maxLevel >= 1)
            // Sizes grow monotonically from min to max.
            var prev: Int64 = 0
            for level in dataset.minLevel...dataset.maxLevel {
                let total = dataset.totalBytes(upTo: level)
                #expect(total > prev)
                prev = total
            }
        }

        // Tinfoil Kit is a single-tier downloadable & auto-unpacked bundle.
        let tinfoil = OfflineDataset.tinfoilkit
        #expect(!tinfoil.hasScaleSlider)
        #expect(tinfoil.highestCompleteLevel(installed: []) == 0)
        #expect(tinfoil.highestCompleteLevel(installed: ["TinfoilKit"]) == 1)

        // DevDocs progressive scaling: downloading Level 1 leaves only Level 2 delta missing.
        let devdocs = OfflineDataset.devdocs
        let level1Files = Set(devdocs.files(upTo: 1).map(\.installedName))
        #expect(devdocs.highestCompleteLevel(installed: []) == 0)
        #expect(devdocs.highestCompleteLevel(installed: level1Files) == 1)
        #expect(devdocs.missingFiles(upTo: 1, installed: level1Files).isEmpty)

        let delta1To2 = devdocs.missingFiles(upTo: 2, installed: level1Files)
        #expect(!delta1To2.isEmpty)
        #expect(devdocs.missingBytes(upTo: 2, installed: level1Files) == devdocs.totalBytes(upTo: 2) - devdocs.totalBytes(upTo: 1))

        let allFiles = Set(devdocs.files(upTo: 4).map(\.installedName))
        #expect(devdocs.highestCompleteLevel(installed: allFiles) == 4)
    }
}
