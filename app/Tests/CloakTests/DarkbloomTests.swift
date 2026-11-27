import CloakDarkbloom
import Foundation
import Testing

@Suite
@MainActor
struct DarkbloomTests {

    // MARK: - Money & Wire Codecs

    @Test func cloudEarningsDecodesLivePayloadsAndFormatsMicroUSDExactly() throws {
        // Real captured /control/v1/cloud response shape (decimal string counters + nulls).
        let cloudJSON = Data(#"""
        {
          "linked": true,
          "earnings_complete": true,
          "account_id": "acct_redacted",
          "earnings_since": 1795219200,
          "local_day_micro_usd": null,
          "observed_at": 1795741958.025741,
          "settled_records": "8802",
          "balance_micro_usd": "15921027",
          "local_earnings_micro_usd": null,
          "lifetime_micro_usd": "4921027",
          "week_micro_usd": "12888",
          "local_lifetime_micro_usd": null
        }
        """#.utf8)
        let decoded = try JSONDecoder.darkbloom.decode(DarkbloomCloudEarnings.self, from: cloudJSON)
        #expect(decoded.linked == true)
        #expect(decoded.balanceMicroUsd == 15_921_027)
        #expect(decoded.lifetimeMicroUsd == 4_921_027)
        #expect(decoded.weekMicroUsd == 12_888)
        #expect(decoded.settledRecords == 8_802)
        #expect(decoded.earningsComplete == true)
        #expect(decoded.localDayMicroUsd == nil)

        // Exact integer micro-USD formatting boundaries (zero floating-point drift).
        #expect(DarkbloomCloudEarnings.formatMicroUSD(0) == "$0.00")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(1) == "<$0.0001")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(50) == "$0.0001")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(12_888) == "$0.0129")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(50_000) == "$0.05")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(99_950) == "$0.10")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(100_000) == "$0.10")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(4_921_027) == "$4.92")
        #expect(DarkbloomCloudEarnings.formatMicroUSD(15_921_027) == "$15.92")

        // Activity session earnings and string counters decode cleanly.
        let activityJSON = Data(#"""
        {
          "started_at": 1795740000,
          "requests": "42",
          "processed_output_tokens": "12500",
          "earnings_micro_usd": "245000"
        }
        """#.utf8)
        let activity = try JSONDecoder.darkbloom.decode(DarkbloomSnapshot.Activity.self, from: activityJSON)
        #expect(activity.resolvedRequests == 42)
        #expect(activity.resolvedTokens == 12_500)
        #expect(activity.earningsMicroUsd == 245_000)
    }

    // MARK: - Hardware Capability Fail-Closed Guard

    @Test func hostSupportsEnforcesM5GLM5NextAndFailsClosedOnUnknownTags() {
        let gib: UInt64 = 1_073_741_824

        // Empty and universal runtime tags pass on any Apple Silicon Mac.
        #expect(Darkbloom.hostSupports(requiredCapabilities: [], cpuBrand: "Apple M4 Max", physicalMemoryBytes: 48 * gib))
        #expect(Darkbloom.hostSupports(
            requiredCapabilities: ["model_revisions_v1", "cache_policy_v1"],
            cpuBrand: "Apple M4 Max",
            physicalMemoryBytes: 48 * gib))

        // apple_m5 / mlx_nax reject M1–M4 and accept M5+.
        #expect(!Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax"],
            cpuBrand: "Apple M4 Max",
            physicalMemoryBytes: 128 * gib))
        #expect(Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax"],
            cpuBrand: "Apple M5",
            physicalMemoryBytes: 32 * gib))

        // glm5_next_v1 requires M5 Max/Ultra + >= 256 GiB.
        #expect(!Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax", "glm5_next_v1"],
            cpuBrand: "Apple M5",
            physicalMemoryBytes: 64 * gib))
        #expect(!Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax", "glm5_next_v1"],
            cpuBrand: "Apple M5 Max",
            physicalMemoryBytes: 128 * gib))
        #expect(Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax", "glm5_next_v1"],
            cpuBrand: "Apple M5 Max",
            physicalMemoryBytes: 256 * gib))
        #expect(Darkbloom.hostSupports(
            requiredCapabilities: ["apple_m5", "mlx_nax", "glm5_next_v1"],
            cpuBrand: "Apple M5 Ultra",
            physicalMemoryBytes: 512 * gib))

        // Unknown future capability tags MUST fail closed even on top-spec hardware.
        #expect(!Darkbloom.hostSupports(
            requiredCapabilities: ["future_neural_v2"],
            cpuBrand: "Apple M5 Ultra",
            physicalMemoryBytes: 512 * gib))
    }

    // MARK: - TOML, Release Parsing, and Redaction

    @Test func setupRouteReleaseVersionAndReasonsRedaction() {
        let toml = """
        [network]
        route = "ignored"

        [local]
        bind = "127.0.0.1"
        route = "this-mac" # keep local
        """
        #expect(DarkbloomSetup.route(in: toml) == "this-mac")
        #expect(DarkbloomSetup.loopback("127.0.0.1"))
        #expect(DarkbloomSetup.loopback("::1"))
        #expect(!DarkbloomSetup.loopback("0.0.0.0"))

        #expect(Darkbloom.release("0.10.19") == [0, 10, 19])
        #expect(Darkbloom.release("v0.10.19") == nil)
        #expect(Darkbloom.release("0.10") == nil)

        let syntheticStripe = "sk_" + "live_" + "supersecret1234567890abcdef"
        var reasons = DarkbloomReasons()
        reasons.hear("Starting...")
        reasons.hear("✗ Auth failed: Bearer \(syntheticStripe) token=abcdef123456 https://api.darkbloom.dev/auth?code=secret")
        reasons.hear("Trailing info line")
        let cleaned = reasons.reason ?? ""
        #expect(!cleaned.contains("sk_" + "live_"))
        #expect(!cleaned.contains("abcdef123456"))
        #expect(!cleaned.contains("code=secret"))
        #expect(cleaned.contains("https://api.darkbloom.dev/auth"))
    }

    // MARK: - State Machine & Concurrency Invariants

    @Test(.timeLimit(.minutes(1)))
    func modeLinkToServeConcurrentActionsAndAccountSignIn() async throws {
        let (events, emit) = AsyncThrowingStream.makeStream(of: DarkbloomSnapshot.self)
        defer { emit.finish() }

        actor Recorder {
            var actions: [DarkbloomAction] = []
            var startedArgs: [[String]] = []
            var cloudCalls = 0
            var cloudResult: Result<DarkbloomCloudEarnings, DarkbloomError> = .success(
                DarkbloomCloudEarnings(
                    linked: true,
                    balanceMicroUsd: 15_921_027,
                    lifetimeMicroUsd: 4_921_027,
                    weekMicroUsd: 12_888,
                    settledRecords: 8_802,
                    earningsComplete: true
                )
            )
            func recordAction(_ a: DarkbloomAction) -> DarkbloomSnapshot.Operation {
                actions.append(a)
                switch a {
                case .link:
                    return DarkbloomSnapshot.Operation(id: "op-link", action: "link", state: "running")
                case .stop:
                    return DarkbloomSnapshot.Operation(id: "op-stop", action: "stop", state: "running")
                case .cancel:
                    return DarkbloomSnapshot.Operation(id: "op-cancel", action: "cancel", state: "running")
                case .accountSignIn:
                    return DarkbloomSnapshot.Operation(id: "op-signin", action: "account-signin", state: "running")
                case .download(let m):
                    return DarkbloomSnapshot.Operation(id: "op-dl", action: "download", state: "running", model: m)
                case .remove(let m):
                    return DarkbloomSnapshot.Operation(id: "op-rm", action: "remove", state: "running", model: m)
                }
            }
            func recordRun(_ args: [String]) { startedArgs.append(args) }
            func readCloud() throws(DarkbloomError) -> DarkbloomCloudEarnings {
                cloudCalls += 1
                switch cloudResult {
                case .success(let v): return v
                case .failure(let e): throw e
                }
            }
            func setCloudResult(_ r: Result<DarkbloomCloudEarnings, DarkbloomError>) { cloudResult = r }
        }
        let rec = Recorder()
        let model = DarkbloomSnapshot.Model(
            id: "ternary-bonsai-2-27b",
            displayName: "Ternary Bonsai 2 27B",
            sizeGb: 9.0,
            memoryGb: 10.0,
            downloaded: true,
            serving: false,
            loaded: false,
            eligible: true,
            network: true
        )
        let initial = DarkbloomSnapshot(
            version: "0.10.19",
            linked: false,
            accountRevision: "rev-1",
            state: "stopped",
            models: [model],
            operations: [],
            memory: .init(totalGb: 48, pinBudgetGb: 32)
        )

        let client = DarkbloomControlClient(
            state: { () async throws(DarkbloomError) in initial },
            cloud: { () async throws(DarkbloomError) in try await rec.readCloud() },
            endpointKey: { () async throws(DarkbloomError) in "local-secret-key" },
            act: { action throws(DarkbloomError) in await rec.recordAction(action) },
            events: { events }
        )

        let mode = DarkbloomMode(parts: DarkbloomMode.Parts(
            systemFits: { true },
            cloakMemory: { 8 * 1_073_741_824 },
            find: { () async throws(DarkbloomFailure) in
                .ready(Darkbloom.Found(
                    binary: URL(filePath: "/tmp/darkbloom"),
                    version: "0.10.19",
                    flags: ["--local", "--me-first", "--route", "--bind", "--model"],
                    control: client,
                    snapshot: initial
                ))
            },
            discoverControl: { () throws(DarkbloomFailure) in client },
            isDaemonAlive: { false },
            run: { _, args, _ throws(DarkbloomFailure) in await rec.recordRun(args) },
            install: { _ throws(DarkbloomFailure) in },
            capture: { _, _ in "ok" },
            readSetup: { _ in DarkbloomSetup() },
            fetchPricing: { nil },
            fetchCapabilities: { _ in [:] },
            hostSupports: { _ in true },
            openURL: { _ in },
            loadChosenModel: { nil },
            saveChosenModel: { _ in },
            pollInterval: .milliseconds(20),
            reconnectDelay: .milliseconds(20)
        ))

        mode.open()
        await Self.until { mode.connected && mode.state == .stopped }
        #expect(mode.state == .stopped)

        // 1. Switching to Network + Local while unlinked initiates `.link`.
        mode.setServingMode(.network)
        await Self.until { await rec.actions.contains(.link) }
        #expect(mode.alsoServe == true)

        // 2. Link succeeds -> refreshes earnings AND automatically calls `darkbloom start --me-first`.
        var linkedSnap = initial
        linkedSnap.linked = true
        linkedSnap.accountRevision = "rev-2"
        linkedSnap.operations = [DarkbloomSnapshot.Operation(id: "op-link", action: "link", state: "succeeded")]
        emit.yield(linkedSnap)

        await Self.until { mode.cloudEarnings?.balanceMicroUsd == 15_921_027 }
        await Self.until { !(await rec.startedArgs.isEmpty) }
        let startArgs = await rec.startedArgs.first
        #expect(startArgs == ["start", "--me-first", "--route", "this-mac", "--bind", "127.0.0.1", "--model", "ternary-bonsai-2-27b"])

        // 3. Concurrent `.cancel(link)` + `.stop` must NOT clobber each other's completion tracking.
        var runningLinkAndServe = linkedSnap
        runningLinkAndServe.state = "running"
        runningLinkAndServe.operations = [
            DarkbloomSnapshot.Operation(id: "op-link-2", action: "link", state: "running")
        ]
        emit.yield(runningLinkAndServe)
        await Self.until { mode.snapshot?.state == "running" }

        mode.setServingMode(.off)
        await Self.until {
            let acts = await rec.actions
            return acts.contains(.cancel(operation: "op-link-2")) && acts.contains(.stop)
        }

        // Only `.stop` fails; `.cancel` succeeds — failure MUST still surface even though two ops were in flight.
        var stopFailedSnap = linkedSnap
        stopFailedSnap.state = "running"
        stopFailedSnap.operations = [
            DarkbloomSnapshot.Operation(id: "op-cancel", action: "cancel", state: "succeeded"),
            DarkbloomSnapshot.Operation(id: "op-stop", action: "stop", state: "failed", message: "Daemon busy"),
        ]
        emit.yield(stopFailedSnap)
        await Self.until { mode.state == .failed(DarkbloomFailure("Couldn't stop", detail: "Daemon busy")) }

        // 4. Dashboard account sign-in clears earnings refusal and re-fetches `/control/v1/cloud`.
        await rec.setCloudResult(.failure(.refused("Sign in to view account earnings")))
        mode.refreshEarnings(force: true)
        await Self.until { mode.cloudEarningsError == "Sign in to view account earnings" }

        await rec.setCloudResult(.success(DarkbloomCloudEarnings(linked: true, balanceMicroUsd: 20_000_000)))
        mode.signInAccount()
        await Self.until { await rec.actions.contains(.accountSignIn) }

        var signedInSnap = linkedSnap
        signedInSnap.accountRevision = "rev-3"
        signedInSnap.operations = [DarkbloomSnapshot.Operation(id: "op-signin", action: "account-signin", state: "succeeded")]
        emit.yield(signedInSnap)
        await Self.until { mode.cloudEarningsError == nil && mode.cloudEarnings?.balanceMicroUsd == 20_000_000 }

        mode.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func modeRejectsIneligibleModelAndClearsKeyOnClose() async {
        let (events, emit) = AsyncThrowingStream.makeStream(of: DarkbloomSnapshot.self)
        defer { emit.finish() }

        let badModel = DarkbloomSnapshot.Model(
            id: "m5-only-model", displayName: "M5 Only", sizeGb: 8, memoryGb: 9,
            downloaded: false, eligible: true, network: true)
        let goodModel = DarkbloomSnapshot.Model(
            id: "good-model", displayName: "Good Model", sizeGb: 8, memoryGb: 9,
            downloaded: true, eligible: true, network: true)
        let initial = DarkbloomSnapshot(
            version: "0.10.19", linked: false, state: "stopped",
            models: [badModel, goodModel], operations: [],
            memory: .init(totalGb: 48, pinBudgetGb: 32)
        )

        var savedChoice: String? = "m5-only-model"
        let client = DarkbloomControlClient(
            state: { () async throws(DarkbloomError) in initial },
            cloud: { () async throws(DarkbloomError) in DarkbloomCloudEarnings(linked: false) },
            endpointKey: { () async throws(DarkbloomError) in "db-local-key-123" },
            act: { action throws(DarkbloomError) in
                if case .download(let m) = action {
                    return DarkbloomSnapshot.Operation(id: "op-dl-bad", action: "download", state: "running", model: m)
                }
                return DarkbloomSnapshot.Operation(id: "op-other", action: "stop", state: "succeeded")
            },
            events: { events }
        )

        let mode = DarkbloomMode(parts: DarkbloomMode.Parts(
            systemFits: { true },
            cloakMemory: { 8 * 1_073_741_824 },
            find: { () async throws(DarkbloomFailure) in
                .ready(Darkbloom.Found(
                    binary: URL(filePath: "/tmp/darkbloom"),
                    version: "0.10.19",
                    flags: ["--local", "--me-first", "--route", "--bind", "--model"],
                    control: client,
                    snapshot: initial
                ))
            },
            discoverControl: { () throws(DarkbloomFailure) in client },
            isDaemonAlive: { false },
            run: { _, _, _ throws(DarkbloomFailure) in },
            install: { _ throws(DarkbloomFailure) in },
            capture: { _, _ in "" },
            readSetup: { _ in DarkbloomSetup() },
            fetchPricing: { nil },
            fetchCapabilities: { _ in [:] },
            hostSupports: { _ in true },
            openURL: { _ in },
            loadChosenModel: { savedChoice },
            saveChosenModel: { savedChoice = $0 },
            pollInterval: .milliseconds(20),
            reconnectDelay: .milliseconds(20)
        ))

        mode.open()
        await Self.until { mode.connected }

        // Key reveal works while open, clears on close, and cannot leak after close.
        await mode.showKey()
        #expect(mode.shownKey == "db-local-key-123")

        // Ineligible download failure blacklists the model and clears persisted choice.
        mode.downloadModel("m5-only-model")
        try? await Task.sleep(for: .milliseconds(20))
        var failedDownload = initial
        failedDownload.operations = [
            DarkbloomSnapshot.Operation(
                id: "op-dl-bad", action: "download", state: "failed",
                message: "Model is permanently ineligible (missing runtime capabilities)",
                model: "m5-only-model")
        ]
        emit.yield(failedDownload)
        await Self.until { mode.rejectedModelIDs.contains("m5-only-model") }
        #expect(mode.chosenModelID == nil)
        #expect(savedChoice == nil)
        #expect(mode.eligibleModels.map(\.id) == ["good-model"])

        mode.close()
        #expect(mode.shownKey == nil)
        await mode.showKey()
        #expect(mode.shownKey == nil)
    }

    // MARK: - Helpers

    private static func until(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
