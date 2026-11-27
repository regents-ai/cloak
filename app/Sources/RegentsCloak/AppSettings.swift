import AppKit
import Carbon.HIToolbox
import CloakChat
import CloakControl
#if DARKBLOOM
import CloakDarkbloom
#endif
import CloakDoor
import CloakSupervisor
import Darwin
import Observation
import os
import ServiceManagement

/// Cloak's settings, kept in the app's defaults: every key and its default
/// is named here, once, and read and written only here. Only the Settings
/// window sets them, and Never reword also the drop-down beside a Chat
/// card's Send, Cover also its toggle in Chat's toolbar, and Tor for NEAR
/// also its pill under Chat's message box. No setting can be set from a
/// link, from the door, from AppleScript or from the guest: none of those
/// reaches this type. Whether the app opens at login is the system's login
/// item (`LoginItem`), and whether it checks for updates by itself is
/// Sparkle's own setting (`Updates`); neither is a default kept here.
@MainActor
@Observable
final class AppSettings {
    static let standard = AppSettings(.standard)

    /// Every key: one per setting, and one for the deposit's expiry, a fact
    /// kept rather than a setting.
    enum Key: String, CaseIterable {
        case freeMemory
        case shortcut
        case doorPort
        case neverReword
        case cover
        case review
        case savedChats
        case nearTor
        case tokenTor
        case nearShareTraces
        case proofFreshness
        case answerModel
        case unfilteredLocal
        case vModel
        case depositExpires
        case autoWithdrawBeforeExpiry
        case payProvider
        case veniceModel
        case veniceAllTiers
        case venicePays
        case localShareMacInfo
        case localUseMemory
        case localSyncHermesMemory
        case localApprovedFolders
        case localUseCalendar
        case localUseReminders
        case localUseContacts
        case walletTermsVersion
        case walletTermsAcceptedAt
        case doorPayment
        case doorModel
        case doorBlockSecrets
        case doorMaskEntities
        case doorPrivateTerms
        case localVoiceAutoSpeak
        case spendGuardEnabled
        case spendDailyLimitUSD
        case spendPerCallLimitUSD
        case spendAllowedNetworks
        case localReasoningEffort
        case externalLocalServerURL
        case externalLocalModelID
        case externalLocalServerName
        case smartPrivatePreset
        case servingPauseOnBattery
        case servingPauseOnHighThermal
        case servingQuietHoursEnabled
        case servingQuietStartHour
        case servingQuietEndHour
        case projectProfiles
        case activeProjectProfileID
        case securityProfile
    }

    /// Current version of the Beta Wallet Terms of Service & Privacy Policy.
    nonisolated static let currentWalletTermsVersion = 1

    /// Each setting until it is chosen, and again after Restore Defaults.
    /// The quick prompt's shortcut has none; Never reword is off; Cover,
    /// Review and Saved chats are on; Tor for NEAR is off; Local Llama
    /// answers with the model that rewords.
    nonisolated static let defaultFreeMemory = FreeMemory.fifteenMinutes
    nonisolated static let defaultProofFreshness = ProofFreshness.tenMinutes
    nonisolated static let defaultTokenTor = true
    nonisolated static let defaultDoorPort: UInt16 = Places.isDev ? 8743 : 8742
    /// The ports the door may take: none the system keeps for itself.
    nonisolated static let doorPorts: ClosedRange<Int> = 1024...65535

    @ObservationIgnored private let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// How long the model may go with nothing to reword before it leaves
    /// memory. The supervisor reads it each time that time starts again
    /// (`freeMemory(in:)`), so a change applies from then, with no restart.
    var freeMemory: FreeMemory {
        get {
            access(keyPath: \.freeMemory)
            return Self.freeMemory(in: defaults)
        }
        set {
            withMutation(keyPath: \.freeMemory) { defaults.set(newValue.rawValue, forKey: Key.freeMemory.rawValue) }
        }
    }

    /// The choice as the supervisor reads it, from wherever it asks.
    nonisolated static func freeMemory(in defaults: UserDefaults) -> FreeMemory {
        defaults.string(forKey: Key.freeMemory.rawValue).flatMap(FreeMemory.init) ?? defaultFreeMemory
    }

    /// The quick prompt's shortcut, or none. Set once the system has taken
    /// it (`QuickPrompt.choose`).
    var shortcut: Shortcut? {
        get {
            access(keyPath: \.shortcut)
            return defaults.data(forKey: Key.shortcut.rawValue).flatMap { try? PropertyListDecoder().decode(Shortcut.self, from: $0) }
        }
        set {
            withMutation(keyPath: \.shortcut) {
                defaults.set(try! newValue.map(PropertyListEncoder().encode), forKey: Key.shortcut.rawValue)
            }
        }
    }

    /// The port on 127.0.0.1 the door takes at its next open.
    var doorPort: UInt16 {
        access(keyPath: \.doorPort)
        return (defaults.object(forKey: Key.doorPort.rawValue) as? Int).flatMap(UInt16.init(exactly:)) ?? Self.defaultDoorPort
    }

    /// Whether Chat sends each message as written, at once, with no
    /// rewording and no review (decision 11 in docs/plan.md). Chat's own
    /// messages only: the door rewords whatever other apps and the agent
    /// send. It and Review are never both on: turning either on, from any
    /// view, turns the other off here.
    var neverReword: Bool {
        get {
            access(keyPath: \.neverReword)
            if securityProfile.enforcesPromptRewriting { return false }
            return defaults.bool(forKey: Key.neverReword.rawValue)
        }
        set {
            let effective = securityProfile.enforcesPromptRewriting ? false : newValue
            withMutation(keyPath: \.neverReword) { defaults.set(effective, forKey: Key.neverReword.rawValue) }
            if effective { review = false }
        }
    }

    /// Whether the guest's daemon sends cover traffic: its own background
    /// fetches of the public pages in the one list (reference/cover.json).
    /// The supervisor reads it as it writes a guest's boot files; a change
    /// while Running restarts Cloak with it (`Supervisor.followCover`).
    var cover: Bool {
        get {
            access(keyPath: \.cover)
            if securityProfile.enforcesTorAndCover { return true }
            return defaults.object(forKey: Key.cover.rawValue) as? Bool ?? true
        }
        set {
            let effective = securityProfile.enforcesTorAndCover ? true : newValue
            withMutation(keyPath: \.cover) { defaults.set(effective, forKey: Key.cover.rawValue) }
        }
    }

    /// App-wide Security & Privacy Profile governing which modes, Connected Apps
    /// rails, and integrations are permitted (`Local Only`, `Anon Private Cloud`,
    /// or `Private Cloud AI`).
    var securityProfile: SecurityProfile {
        get {
            access(keyPath: \.securityProfile)
            return Self.securityProfile(in: defaults)
        }
        set {
            withMutation(keyPath: \.securityProfile) {
                defaults.set(newValue.rawValue, forKey: Key.securityProfile.rawValue)
            }
            switch newValue {
            case .localOnly:
                doorPayment = .local
            case .anonCloud:
                cover = true
                neverReword = false
                if !doorPayment.isAllowed(in: .anonCloud) {
                    doorPayment = .zkapi
                }
            case .privateCloud:
                break
            }
        }
    }

    nonisolated static func securityProfile(in defaults: UserDefaults) -> SecurityProfile {
        defaults.string(forKey: Key.securityProfile.rawValue).flatMap(SecurityProfile.init(rawValue:)) ?? .privateCloud
    }

    nonisolated static func doorRouteRefusal(for route: Door.MacRoute, in defaults: UserDefaults) -> String? {
        let profile = securityProfile(in: defaults)
        switch route {
        case .local:
            return nil
        case .zkapi:
            return profile.allowsZkAPI ? nil : profile.refusalMessage(for: "zkAPI Anon Inference")
        case .near:
            return profile.allowsNear ? nil : profile.refusalMessage(for: "NEAR AI Gateway")
        case .venice:
            return profile.allowsTokenInference ? nil : profile.refusalMessage(for: "Venice AI")
        case .tempo:
            return profile.allowsTokenInference ? nil : profile.refusalMessage(for: "Boundless (Tempo)")
        }
    }

    /// Whether Chat shows each new reworded message for its owner to edit
    /// and send. Off, a new message is sent as soon as its rewording
    /// finishes, as if Send were pressed then. Turning it on turns Never
    /// reword off (`neverReword`). The agent's tasks and the door never have
    /// this step.
    var review: Bool {
        get {
            access(keyPath: \.review)
            return defaults.object(forKey: Key.review.rawValue) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.review) { defaults.set(newValue, forKey: Key.review.rawValue) }
            if newValue { neverReword = false }
        }
    }

    /// Whether Chat writes its conversations to disk, sealed. Off, a
    /// conversation started or continued is kept in memory only, for as
    /// long as Cloak runs, even once this is on again; the files already
    /// saved stay as they are until their owner deletes them.
    var savedChats: Bool {
        get {
            access(keyPath: \.savedChats)
            return defaults.object(forKey: Key.savedChats.rawValue) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.savedChats) { defaults.set(newValue, forKey: Key.savedChats.rawValue) }
        }
    }

    /// Whether NEAR mode goes through Tor, which needs Cloak running. Off,
    /// NEAR and Intel see this Mac's internet address.
    var nearTor: Bool {
        get {
            access(keyPath: \.nearTor)
            return defaults.bool(forKey: Key.nearTor.rawValue)
        }
        set {
            withMutation(keyPath: \.nearTor) { defaults.set(newValue, forKey: Key.nearTor.rawValue) }
        }
    }

    /// Whether Token Inference (Boundless / Venice) routes through Tor inside
    /// Cloak's Linux VM. On by default; when off, uses the pinned host
    /// `cloak-sender` over direct HTTPS (much faster, no VM/Tor needed, exposes
    /// this Mac's IP address to Boundless/Venice).
    var tokenTor: Bool {
        get {
            access(keyPath: \.tokenTor)
            return defaults.object(forKey: Key.tokenTor.rawValue) as? Bool ?? Self.defaultTokenTor
        }
        set {
            withMutation(keyPath: \.tokenTor) { defaults.set(newValue, forKey: Key.tokenTor.rawValue) }
        }
    }

    /// Whether NEAR AI Gateway chats can be exported locally as Letta
    /// Trajectory v1 files for handoff to the NEAR AI Gateway app. Off by
    /// default; Cloak never uploads traces on its own.
    var nearShareTraces: Bool {
        get {
            access(keyPath: \.nearShareTraces)
            return defaults.bool(forKey: Key.nearShareTraces.rawValue)
        }
        set {
            withMutation(keyPath: \.nearShareTraces) { defaults.set(newValue, forKey: Key.nearShareTraces.rawValue) }
        }
    }

    /// How long NEAR mode uses a passed check of NEAR's hardware again.
    var proofFreshness: ProofFreshness {
        get {
            access(keyPath: \.proofFreshness)
            return (defaults.object(forKey: Key.proofFreshness.rawValue) as? Int).flatMap(ProofFreshness.init) ?? Self.defaultProofFreshness
        }
        set {
            withMutation(keyPath: \.proofFreshness) { defaults.set(newValue.rawValue, forKey: Key.proofFreshness.rawValue) }
        }
    }

    /// The name of the model Local Llama chats are answered with (decision
    /// 21 in docs/plan.md); nil, the model that rewords. A name the manifest
    /// no longer lists answers nothing until another is chosen.
    var answerModel: String? {
        get {
            access(keyPath: \.answerModel)
            return defaults.string(forKey: Key.answerModel.rawValue)
        }
        set {
            withMutation(keyPath: \.answerModel) { defaults.set(newValue, forKey: Key.answerModel.rawValue) }
        }
    }

    /// Whether Local Inkling 2 Mini chats apply AtomicChat's optional 44 MB
    /// uncensored LoRA adapter (`Manifest.Model.unfilteredLora`). Off by
    /// default so standard model quality is preserved unless opted in.
    var unfilteredLocal: Bool {
        get {
            access(keyPath: \.unfilteredLocal)
            return defaults.bool(forKey: Key.unfilteredLocal.rawValue)
        }
        set {
            withMutation(keyPath: \.unfilteredLocal) { defaults.set(newValue, forKey: Key.unfilteredLocal.rawValue) }
        }
    }

    /// Thinking depth for reasoning-capable local models (`Fast`, `Balanced`, `Deep`).
    var localReasoningEffort: LocalReasoningEffort {
        get {
            access(keyPath: \.localReasoningEffort)
            return Self.localReasoningEffort(in: defaults)
        }
        set {
            withMutation(keyPath: \.localReasoningEffort) {
                defaults.set(newValue.rawValue, forKey: Key.localReasoningEffort.rawValue)
            }
        }
    }

    nonisolated static func localReasoningEffort(in defaults: UserDefaults) -> LocalReasoningEffort {
        defaults.string(forKey: Key.localReasoningEffort.rawValue).flatMap(LocalReasoningEffort.init(rawValue:)) ?? .balanced
    }

    /// Selected external loopback local server model (LM Studio, `mlx-serve`,
    /// Ollama, or Darkbloom Local), or nil to use Cloak's built-in worker.
    struct ExternalLocalSelection: Equatable, Sendable {
        let serverName: String
        let baseURL: URL
        let modelID: String

        var displayName: String {
            let leaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
            return leaf
                .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    var externalLocalSelection: ExternalLocalSelection? {
        access(keyPath: \.externalLocalSelection)
        return Self.externalLocalSelection(in: defaults)
    }

    func selectExternalLocal(_ model: DiscoveredLocalModel?) {
        withMutation(keyPath: \.externalLocalSelection) {
            if let model, LocalServerDiscovery.isLoopback(model.baseURL) {
                defaults.set(model.baseURL.absoluteString, forKey: Key.externalLocalServerURL.rawValue)
                defaults.set(model.modelID, forKey: Key.externalLocalModelID.rawValue)
                defaults.set(model.server.rawValue, forKey: Key.externalLocalServerName.rawValue)
            } else {
                defaults.removeObject(forKey: Key.externalLocalServerURL.rawValue)
                defaults.removeObject(forKey: Key.externalLocalModelID.rawValue)
                defaults.removeObject(forKey: Key.externalLocalServerName.rawValue)
            }
        }
    }

    nonisolated static func externalLocalSelection(in defaults: UserDefaults) -> ExternalLocalSelection? {
        guard let urlText = defaults.string(forKey: Key.externalLocalServerURL.rawValue),
            let url = URL(string: urlText),
            LocalServerDiscovery.isLoopback(url),
            let modelID = defaults.string(forKey: Key.externalLocalModelID.rawValue),
            !modelID.isEmpty
        else { return nil }
        let serverName = defaults.string(forKey: Key.externalLocalServerName.rawValue) ?? "Local Server"
        return ExternalLocalSelection(serverName: serverName, baseURL: url, modelID: modelID)
    }

    /// Plain-English Private Cloud intent preset (`Fast`, `Coding`, `Reasoning`).
    var smartPrivatePreset: SmartPrivatePreset {
        get {
            access(keyPath: \.smartPrivatePreset)
            return defaults.string(forKey: Key.smartPrivatePreset.rawValue).flatMap(SmartPrivatePreset.init(rawValue:)) ?? .fast
        }
        set {
            withMutation(keyPath: \.smartPrivatePreset) {
                defaults.set(newValue.rawValue, forKey: Key.smartPrivatePreset.rawValue)
            }
        }
    }

    // MARK: - Inference Serving QoS Guardrails

    var servingPauseOnBattery: Bool {
        get {
            access(keyPath: \.servingPauseOnBattery)
            return defaults.object(forKey: Key.servingPauseOnBattery.rawValue) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.servingPauseOnBattery) {
                defaults.set(newValue, forKey: Key.servingPauseOnBattery.rawValue)
            }
        }
    }

    var servingPauseOnHighThermal: Bool {
        get {
            access(keyPath: \.servingPauseOnHighThermal)
            return defaults.object(forKey: Key.servingPauseOnHighThermal.rawValue) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.servingPauseOnHighThermal) {
                defaults.set(newValue, forKey: Key.servingPauseOnHighThermal.rawValue)
            }
        }
    }

    var servingQuietHoursEnabled: Bool {
        get {
            access(keyPath: \.servingQuietHoursEnabled)
            return defaults.bool(forKey: Key.servingQuietHoursEnabled.rawValue)
        }
        set {
            withMutation(keyPath: \.servingQuietHoursEnabled) {
                defaults.set(newValue, forKey: Key.servingQuietHoursEnabled.rawValue)
            }
        }
    }

    var servingQuietStartHour: Int {
        get {
            access(keyPath: \.servingQuietStartHour)
            return (defaults.object(forKey: Key.servingQuietStartHour.rawValue) as? Int) ?? 9
        }
        set {
            let clamped = max(0, min(23, newValue))
            withMutation(keyPath: \.servingQuietStartHour) {
                defaults.set(clamped, forKey: Key.servingQuietStartHour.rawValue)
            }
        }
    }

    var servingQuietEndHour: Int {
        get {
            access(keyPath: \.servingQuietEndHour)
            return (defaults.object(forKey: Key.servingQuietEndHour.rawValue) as? Int) ?? 18
        }
        set {
            let clamped = max(0, min(23, newValue))
            withMutation(keyPath: \.servingQuietEndHour) {
                defaults.set(clamped, forKey: Key.servingQuietEndHour.rawValue)
            }
        }
    }

    #if DARKBLOOM
    nonisolated static func servingQoSPolicy(in defaults: UserDefaults) -> ServingQoSPolicy {
        ServingQoSPolicy(
            pauseOnBattery: defaults.object(forKey: Key.servingPauseOnBattery.rawValue) as? Bool ?? true,
            pauseOnHighThermal: defaults.object(forKey: Key.servingPauseOnHighThermal.rawValue) as? Bool ?? true,
            quietHoursEnabled: defaults.bool(forKey: Key.servingQuietHoursEnabled.rawValue),
            quietStartHour: (defaults.object(forKey: Key.servingQuietStartHour.rawValue) as? Int) ?? 9,
            quietEndHour: (defaults.object(forKey: Key.servingQuietEndHour.rawValue) as? Int) ?? 18)
    }
    #endif

    /// The model V chats are answered with, as its owner chose it in V's
    /// wallet; nil, the one whose requests cost least at most
    /// (`Payer.model`). A model the service no longer lists is passed over
    /// the same way until it lists it again. Kept through Restore Defaults,
    /// since the Settings window doesn't show it.
    var vModel: String? {
        get {
            access(keyPath: \.vModel)
            return defaults.string(forKey: Key.vModel.rawValue)
        }
        set {
            withMutation(keyPath: \.vModel) { defaults.set(newValue, forKey: Key.vModel.rawValue) }
        }
    }

    /// How Chat handles prompt rewriting before sending to remote providers:
    /// a single 3-way control over `neverReword` and `review` so there are no
    /// competing mutually-exclusive toggles.
    var promptRewriting: PromptRewriting {
        get {
            if neverReword { return .off }
            return review ? .review : .automatic
        }
        set {
            switch newValue {
            case .review:
                neverReword = false
                review = true
            case .automatic:
                neverReword = false
                review = false
            case .off:
                neverReword = true
            }
        }
    }

    /// Whether Cloak automatically withdraws a Paranoid (V) deposit 3 days
    /// before its 30-day expiry while Cloak is open and running. Opt-in
    /// (off by default) so money only moves automatically when the owner asks.
    var autoWithdrawBeforeExpiry: Bool {
        get {
            access(keyPath: \.autoWithdrawBeforeExpiry)
            return defaults.bool(forKey: Key.autoWithdrawBeforeExpiry.rawValue)
        }
        set {
            withMutation(keyPath: \.autoWithdrawBeforeExpiry) {
                defaults.set(newValue, forKey: Key.autoWithdrawBeforeExpiry.rawValue)
            }
        }
    }

    /// Which provider Token Inference uses for new chats: defaults to Boundless
    /// (Tempo USDC.e) for new users while keeping Venice (Base USDC) on the left
    /// of the toggle slider; persists whichever provider the user last toggled.
    var payProvider: PayProvider {
        get {
            access(keyPath: \.payProvider)
            return defaults.string(forKey: Key.payProvider.rawValue).flatMap(PayProvider.init) ?? .boundless
        }
        set {
            withMutation(keyPath: \.payProvider) {
                defaults.set(newValue.rawValue, forKey: Key.payProvider.rawValue)
            }
        }
    }

    /// The chosen Venice model for new Venice chats; nil picks the first
    /// available Private/TEE model automatically.
    var veniceModel: VeniceChoice? {
        get {
            access(keyPath: \.veniceModel)
            return defaults.data(forKey: Key.veniceModel.rawValue).flatMap { try? JSONDecoder().decode(VeniceChoice.self, from: $0) }
        }
        set {
            withMutation(keyPath: \.veniceModel) {
                defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.veniceModel.rawValue)
            }
        }
    }

    /// Whether the Venice model picker includes Anonymous-tier models in
    /// addition to Private and TEE models (kept in Advanced settings, N3b).
    var veniceAllTiers: Bool {
        get {
            access(keyPath: \.veniceAllTiers)
            return defaults.bool(forKey: Key.veniceAllTiers.rawValue)
        }
        set {
            withMutation(keyPath: \.veniceAllTiers) {
                defaults.set(newValue, forKey: Key.veniceAllTiers.rawValue)
            }
        }
    }

    /// How new Venice chats pay: local Base USDC wallet (default) or user's
    /// own Venice API key.
    var venicePays: VeniceChat.Pays {
        get {
            access(keyPath: \.venicePays)
            return defaults.string(forKey: Key.venicePays.rawValue).flatMap(VeniceChat.Pays.init) ?? .wallet
        }
        set {
            withMutation(keyPath: \.venicePays) {
                defaults.set(newValue.rawValue, forKey: Key.venicePays.rawValue)
            }
        }
    }

    /// Persisted guard for an ambiguously submitted Venice x402 EIP-3009 top-up.
    /// Stored outside `Key.allCases` so Restore Defaults never clears an
    /// active in-flight payment guard across app launches.
    private static let veniceUncertainTopUpKey = "veniceUncertainTopUp"

    var veniceUncertainTopUp: VeniceTopUpGuard? {
        get {
            access(keyPath: \.veniceUncertainTopUp)
            return defaults.data(forKey: Self.veniceUncertainTopUpKey).flatMap {
                try? JSONDecoder().decode(VeniceTopUpGuard.self, from: $0)
            }
        }
        set {
            withMutation(keyPath: \.veniceUncertainTopUp) {
                if let newValue, let data = try? JSONEncoder().encode(newValue) {
                    defaults.set(data, forKey: Self.veniceUncertainTopUpKey)
                } else {
                    defaults.removeObject(forKey: Self.veniceUncertainTopUpKey)
                }
            }
        }
    }

    // MARK: - Local Access (strictly opt-in, Local Mode only)

    /// Shares basic non-identifying Mac info (date/time, chip, RAM, macOS version,
    /// free disk) strictly with Local Mode models. Off by default.
    var localShareMacInfo: Bool {
        get {
            access(keyPath: \.localShareMacInfo)
            return defaults.bool(forKey: Key.localShareMacInfo.rawValue)
        }
        set {
            withMutation(keyPath: \.localShareMacInfo) {
                defaults.set(newValue, forKey: Key.localShareMacInfo.rawValue)
            }
        }
    }

    /// Includes Hermes-compatible local memory (`USER.md` & `MEMORY.md`) strictly
    /// in Local Mode chats. Off by default.
    var localUseMemory: Bool {
        get {
            access(keyPath: \.localUseMemory)
            return defaults.bool(forKey: Key.localUseMemory.rawValue)
        }
        set {
            withMutation(keyPath: \.localUseMemory) {
                defaults.set(newValue, forKey: Key.localUseMemory.rawValue)
            }
        }
    }

    /// Mirrors `USER.md` and `MEMORY.md` with `~/.hermes/memories/` when Local
    /// Memory is enabled. Off by default.
    var localSyncHermesMemory: Bool {
        get {
            access(keyPath: \.localSyncHermesMemory)
            return defaults.bool(forKey: Key.localSyncHermesMemory.rawValue)
        }
        set {
            withMutation(keyPath: \.localSyncHermesMemory) {
                defaults.set(newValue, forKey: Key.localSyncHermesMemory.rawValue)
            }
        }
    }

    /// User-approved read-only folder paths searched locally in Local Mode.
    var localApprovedFolders: [String] {
        get {
            access(keyPath: \.localApprovedFolders)
            return defaults.stringArray(forKey: Key.localApprovedFolders.rawValue) ?? []
        }
        set {
            let unique = Array(NSOrderedSet(array: newValue)) as? [String] ?? newValue
            withMutation(keyPath: \.localApprovedFolders) {
                defaults.set(unique, forKey: Key.localApprovedFolders.rawValue)
            }
        }
    }

    /// Opt-in read-only Calendar events (next 7 days) strictly in Local Mode.
    var localUseCalendar: Bool {
        get {
            access(keyPath: \.localUseCalendar)
            return defaults.bool(forKey: Key.localUseCalendar.rawValue)
        }
        set {
            withMutation(keyPath: \.localUseCalendar) {
                defaults.set(newValue, forKey: Key.localUseCalendar.rawValue)
            }
        }
    }

    /// Opt-in read-only open Reminders strictly in Local Mode.
    var localUseReminders: Bool {
        get {
            access(keyPath: \.localUseReminders)
            return defaults.bool(forKey: Key.localUseReminders.rawValue)
        }
        set {
            withMutation(keyPath: \.localUseReminders) {
                defaults.set(newValue, forKey: Key.localUseReminders.rawValue)
            }
        }
    }

    /// Opt-in read-only Contacts lookup (matching names in prompt) strictly in Local Mode.
    var localUseContacts: Bool {
        get {
            access(keyPath: \.localUseContacts)
            return defaults.bool(forKey: Key.localUseContacts.rawValue)
        }
        set {
            withMutation(keyPath: \.localUseContacts) {
                defaults.set(newValue, forKey: Key.localUseContacts.rawValue)
            }
        }
    }

    /// Snapshot of current Local Access options for `LocalContextBuilder`.
    /// When a Saved Project Profile is active, Local Mode strictly scopes folder
    /// search to that project's approved folders so projects never bleed together.
    var localContextOptions: LocalContextOptions {
        LocalContextOptions(
            shareMacInfo: localShareMacInfo,
            useMemory: localUseMemory,
            syncHermesMemory: localSyncHermesMemory,
            approvedFolders: ProjectProfileResolver.effectiveApprovedFolders(
                active: activeProjectProfile,
                globalFolders: localApprovedFolders),
            useCalendar: localUseCalendar,
            useReminders: localUseReminders,
            useContacts: localUseContacts)
    }

    /// Human-readable names of currently enabled Local Access sources.
    var activeLocalContextSummary: [String] {
        var names: [String] = []
        if let project = activeProjectProfile {
            names.append("Project: \(project.name)")
        }
        if localShareMacInfo { names.append("Mac info") }
        if localUseMemory { names.append("Memory") }
        let folders = ProjectProfileResolver.effectiveApprovedFolders(
            active: activeProjectProfile,
            globalFolders: localApprovedFolders)
        if !folders.isEmpty {
            let count = folders.count
            names.append(count == 1 ? "1 folder" : "\(count) folders")
        }
        if localUseCalendar { names.append("Calendar") }
        if localUseReminders { names.append("Reminders") }
        if localUseContacts { names.append("Contacts") }
        return names
    }

    // MARK: - Saved Project Profiles (free & unlocked in beta)

    var projectProfiles: [ProjectProfile] {
        get {
            access(keyPath: \.projectProfiles)
            return Self.projectProfiles(in: defaults)
        }
        set {
            withMutation(keyPath: \.projectProfiles) {
                if let data = try? JSONEncoder().encode(newValue) {
                    defaults.set(data, forKey: Key.projectProfiles.rawValue)
                }
            }
        }
    }

    nonisolated static func projectProfiles(in defaults: UserDefaults) -> [ProjectProfile] {
        guard let data = defaults.data(forKey: Key.projectProfiles.rawValue),
            let decoded = try? JSONDecoder().decode([ProjectProfile].self, from: data)
        else { return [] }
        return decoded
    }

    var activeProjectProfileID: UUID? {
        get {
            access(keyPath: \.activeProjectProfileID)
            return Self.activeProjectProfileID(in: defaults)
        }
        set {
            withMutation(keyPath: \.activeProjectProfileID) {
                if let newValue {
                    defaults.set(newValue.uuidString, forKey: Key.activeProjectProfileID.rawValue)
                } else {
                    defaults.removeObject(forKey: Key.activeProjectProfileID.rawValue)
                }
            }
        }
    }

    nonisolated static func activeProjectProfileID(in defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: Key.activeProjectProfileID.rawValue).flatMap(UUID.init(uuidString:))
    }

    var activeProjectProfile: ProjectProfile? {
        guard let id = activeProjectProfileID else { return nil }
        return projectProfiles.first { $0.id == id }
    }

    nonisolated static func activeProjectProfile(in defaults: UserDefaults) -> ProjectProfile? {
        guard let id = activeProjectProfileID(in: defaults) else { return nil }
        return projectProfiles(in: defaults).first { $0.id == id }
    }

    func saveProjectProfile(_ profile: ProjectProfile) {
        var next = projectProfiles
        var updated = profile
        updated.updatedAt = .now
        if let idx = next.firstIndex(where: { $0.id == updated.id }) {
            next[idx] = updated
        } else {
            next.append(updated)
        }
        projectProfiles = next
    }

    func deleteProjectProfile(_ id: UUID) {
        if activeProjectProfileID == id {
            activeProjectProfileID = nil
        }
        projectProfiles = projectProfiles.filter { $0.id != id }
    }

    func activateProjectProfile(_ id: UUID?) {
        activeProjectProfileID = id
        guard let profile = id.flatMap({ target in projectProfiles.first { $0.id == target } }) else { return }
        switch profile.route {
        case .local:
            doorPayment = .local
        case .near where securityProfile.allowsNear:
            doorPayment = .near
        case .venice where securityProfile.allowsTokenInference:
            doorPayment = .venice
        case .boundless where securityProfile.allowsTokenInference:
            doorPayment = .tempo
        case .zkapi where securityProfile.allowsZkAPI:
            doorPayment = .zkapi
        case .keepCurrent, .near, .venice, .boundless, .zkapi:
            break
        }
    }

    /// When V's deposit may be sent to the service's operator, as the payer
    /// last read it, so Chat can warn while Cloak is paused; nil without a
    /// deposit. Set only by `Payer`, and kept through Restore Defaults.
    var depositExpires: Date? {
        get {
            access(keyPath: \.depositExpires)
            return defaults.object(forKey: Key.depositExpires.rawValue) as? Date
        }
        set {
            withMutation(keyPath: \.depositExpires) { defaults.set(newValue, forKey: Key.depositExpires.rawValue) }
        }
    }

    /// Why a port can't be the door's.
    enum PortRefusal: Error, Equatable {
        /// Not a whole number in `doorPorts`.
        case outOfRange
        /// Something on this Mac listens on it now.
        case taken

        var words: String {
            switch self {
            case .outOfRange: "Use a number from 1024 to 65535."
            case .taken: "Another app is using this port."
            }
        }
    }

    /// Makes `text` the door's port when it is a number in `doorPorts` and
    /// nothing listens on 127.0.0.1 and it now. A refused one changes
    /// nothing. The port already chosen, and `open`, the one the door
    /// listens on now, are taken without a check, since the door holds them.
    func choose(port text: String, open: UInt16?) throws(PortRefusal) {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)), Self.doorPorts.contains(number) else {
            throw .outOfRange
        }
        let port = UInt16(number)
        guard port == doorPort || port == open || Self.isFree(port) else { throw .taken }
        withMutation(keyPath: \.doorPort) { defaults.set(number, forKey: Key.doorPort.rawValue) }
    }

    /// Whether a socket can take 127.0.0.1 and `port` now, as the door's
    /// listener does: without taking it over from another, and refused when
    /// another listens on it or on every address.
    nonisolated static func isFree(_ port: UInt16) -> Bool {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Version of the Beta Wallet Terms of Service & Privacy Policy signed
    /// locally on this Mac (0 when never accepted).
    var walletTermsVersion: Int {
        get {
            access(keyPath: \.walletTermsVersion)
            return defaults.integer(forKey: Key.walletTermsVersion.rawValue)
        }
        set {
            withMutation(keyPath: \.walletTermsVersion) {
                defaults.set(newValue, forKey: Key.walletTermsVersion.rawValue)
            }
        }
    }

    /// Timestamp when the current Beta Wallet Terms & Privacy Policy were signed locally.
    var walletTermsAcceptedAt: Date? {
        get {
            access(keyPath: \.walletTermsAcceptedAt)
            return defaults.object(forKey: Key.walletTermsAcceptedAt.rawValue) as? Date
        }
        set {
            withMutation(keyPath: \.walletTermsAcceptedAt) {
                if let newValue {
                    defaults.set(newValue, forKey: Key.walletTermsAcceptedAt.rawValue)
                } else {
                    defaults.removeObject(forKey: Key.walletTermsAcceptedAt.rawValue)
                }
            }
        }
    }

    /// Whether the user has signed the current Beta Wallet Terms & Privacy Policy.
    var walletTermsAccepted: Bool {
        walletTermsVersion >= Self.currentWalletTermsVersion
    }

    /// Records local acceptance of the current Beta Wallet Terms & Privacy Policy.
    func acceptWalletTerms() {
        walletTermsVersion = Self.currentWalletTermsVersion
        walletTermsAcceptedAt = .now
    }

    // MARK: - Connected Apps (Claude Code & OpenAI-compatible clients)

    /// Which payment rail Connected Apps on this Mac bill through: zkAPI Anon
    /// Inference (default) or Token Inference (Boundless / Tempo USDC.e).
    var doorPayment: DoorPayment {
        get {
            access(keyPath: \.doorPayment)
            return Self.doorPayment(in: defaults)
        }
        set {
            withMutation(keyPath: \.doorPayment) {
                defaults.set(newValue.rawValue, forKey: Key.doorPayment.rawValue)
            }
        }
    }

    nonisolated static func doorPayment(in defaults: UserDefaults) -> DoorPayment {
        defaults.string(forKey: Key.doorPayment.rawValue).flatMap(DoorPayment.init) ?? .zkapi
    }

    /// Optional model ID override for Connected Apps (empty = pass through
    /// requested model, or auto-map unknown Claude aliases on `/v1/messages`).
    var doorModel: String {
        get {
            access(keyPath: \.doorModel)
            return Self.doorModel(in: defaults) ?? ""
        }
        set {
            withMutation(keyPath: \.doorModel) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    defaults.removeObject(forKey: Key.doorModel.rawValue)
                } else {
                    defaults.set(trimmed, forKey: Key.doorModel.rawValue)
                }
            }
        }
    }

    nonisolated static func doorModel(in defaults: UserDefaults) -> String? {
        let active = activeProjectProfile(in: defaults)
        return ProjectProfileResolver.effectiveDoorModel(
            active: active,
            globalModel: defaults.string(forKey: Key.doorModel.rawValue))
    }

    nonisolated static func vModel(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: Key.vModel.rawValue)
    }

    /// Whether `CloakDoor` hard-blocks outbound Connected Apps requests containing
    /// detected credentials, private keys, or `.env` secrets. On by default.
    var doorBlockSecrets: Bool {
        get {
            access(keyPath: \.doorBlockSecrets)
            return Self.doorBlockSecrets(in: defaults)
        }
        set {
            withMutation(keyPath: \.doorBlockSecrets) {
                defaults.set(newValue, forKey: Key.doorBlockSecrets.rawValue)
            }
        }
    }

    nonisolated static func doorBlockSecrets(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.doorBlockSecrets.rawValue) as? Bool ?? true
    }

    /// Whether `CloakDoor` masks private terms, wallets, ENS names, home paths, and
    /// emails with reversible per-app aliases before sending and restores them on replies.
    var doorMaskEntities: Bool {
        get {
            access(keyPath: \.doorMaskEntities)
            return Self.doorMaskEntities(in: defaults)
        }
        set {
            withMutation(keyPath: \.doorMaskEntities) {
                defaults.set(newValue, forKey: Key.doorMaskEntities.rawValue)
            }
        }
    }

    nonisolated static func doorMaskEntities(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.doorMaskEntities.rawValue) as? Bool ?? true
    }

    /// Comma- or newline-separated private terms (names, organizations, repo slugs)
    /// masked locally by `CloakDoor`'s reversible alias map.
    var doorPrivateTerms: String {
        get {
            access(keyPath: \.doorPrivateTerms)
            return defaults.string(forKey: Key.doorPrivateTerms.rawValue) ?? ""
        }
        set {
            withMutation(keyPath: \.doorPrivateTerms) {
                defaults.set(newValue, forKey: Key.doorPrivateTerms.rawValue)
            }
        }
    }

    nonisolated static func doorPrivacyPolicy(in defaults: UserDefaults) -> PrivacyShieldPolicy {
        let blockSecrets = doorBlockSecrets(in: defaults)
        let maskEntities = doorMaskEntities(in: defaults)
        let rawTerms = ProjectProfileResolver.mergedPrivateTermsRaw(
            active: activeProjectProfile(in: defaults),
            globalTermsRaw: defaults.string(forKey: Key.doorPrivateTerms.rawValue) ?? "")
        return PrivacyShieldPolicy(
            blockSecrets: blockSecrets,
            maskEntities: maskEntities,
            privateTerms: PrivacyShieldPolicy.parsePrivateTerms(rawTerms))
    }

    // MARK: - Local Voice (100% on-device)

    /// Whether Cloak automatically reads new assistant replies aloud on this Mac
    /// using macOS's offline speech synthesizer. Off by default.
    var localVoiceAutoSpeak: Bool {
        get {
            access(keyPath: \.localVoiceAutoSpeak)
            return defaults.bool(forKey: Key.localVoiceAutoSpeak.rawValue)
        }
        set {
            withMutation(keyPath: \.localVoiceAutoSpeak) {
                defaults.set(newValue, forKey: Key.localVoiceAutoSpeak.rawValue)
            }
        }
    }

    // MARK: - Local Spend Guardrails (Deterministic, Outside the LLM)

    var spendGuardEnabled: Bool {
        get {
            access(keyPath: \.spendGuardEnabled)
            return defaults.bool(forKey: Key.spendGuardEnabled.rawValue)
        }
        set {
            withMutation(keyPath: \.spendGuardEnabled) {
                defaults.set(newValue, forKey: Key.spendGuardEnabled.rawValue)
            }
        }
    }

    var spendDailyLimitUSD: String {
        get {
            access(keyPath: \.spendDailyLimitUSD)
            return defaults.string(forKey: Key.spendDailyLimitUSD.rawValue) ?? "5.00"
        }
        set {
            withMutation(keyPath: \.spendDailyLimitUSD) {
                defaults.set(newValue, forKey: Key.spendDailyLimitUSD.rawValue)
            }
        }
    }

    var spendPerCallLimitUSD: String {
        get {
            access(keyPath: \.spendPerCallLimitUSD)
            return defaults.string(forKey: Key.spendPerCallLimitUSD.rawValue) ?? "0.50"
        }
        set {
            withMutation(keyPath: \.spendPerCallLimitUSD) {
                defaults.set(newValue, forKey: Key.spendPerCallLimitUSD.rawValue)
            }
        }
    }

    var spendAllowedNetworks: Set<PaymentNetwork.ID> {
        get {
            access(keyPath: \.spendAllowedNetworks)
            return Self.spendAllowedNetworks(in: defaults)
        }
        set {
            withMutation(keyPath: \.spendAllowedNetworks) {
                defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.spendAllowedNetworks.rawValue)
            }
        }
    }

    nonisolated static func spendAllowedNetworks(in defaults: UserDefaults) -> Set<PaymentNetwork.ID> {
        guard let raw = defaults.stringArray(forKey: Key.spendAllowedNetworks.rawValue) else {
            return Set(PaymentNetwork.ID.allCases)
        }
        return Set(raw.compactMap(PaymentNetwork.ID.init(rawValue:)))
    }

    nonisolated static func spendPolicy(in defaults: UserDefaults) -> SpendPolicy {
        let enabled = defaults.bool(forKey: Key.spendGuardEnabled.rawValue)
        let dailyStr = defaults.string(forKey: Key.spendDailyLimitUSD.rawValue) ?? "5.00"
        let perCallStr = defaults.string(forKey: Key.spendPerCallLimitUSD.rawValue) ?? "0.50"
        let daily = ArcUSDC.parseUSD(dailyStr)?.microUnits ?? SpendPolicy.defaultDailyLimitMicroUSD
        let perCall = ArcUSDC.parseUSD(perCallStr)?.microUnits ?? SpendPolicy.defaultPerCallLimitMicroUSD
        return SpendPolicy(
            enabled: enabled,
            dailyLimitMicroUSD: daily,
            perCallLimitMicroUSD: perCall,
            allowedNetworks: spendAllowedNetworks(in: defaults)
        )
    }

    /// Puts every setting the Settings window shows back to its default,
    /// each change told to whatever watches that setting. V's model, chosen
    /// in V's wallet, stays, and so does the deposit's expiry, which is not
    /// a setting.
    func restore() {
        for key in Key.allCases {
            let remove = { self.defaults.removeObject(forKey: key.rawValue) }
            switch key {
            case .freeMemory: withMutation(keyPath: \.freeMemory, remove)
            case .shortcut: withMutation(keyPath: \.shortcut, remove)
            case .doorPort: withMutation(keyPath: \.doorPort, remove)
            case .neverReword: withMutation(keyPath: \.neverReword, remove)
            case .cover: withMutation(keyPath: \.cover, remove)
            case .review: withMutation(keyPath: \.review, remove)
            case .savedChats: withMutation(keyPath: \.savedChats, remove)
            case .nearTor: withMutation(keyPath: \.nearTor, remove)
            case .tokenTor: withMutation(keyPath: \.tokenTor, remove)
            case .nearShareTraces: withMutation(keyPath: \.nearShareTraces, remove)
            case .proofFreshness: withMutation(keyPath: \.proofFreshness, remove)
            case .answerModel: withMutation(keyPath: \.answerModel, remove)
            case .unfilteredLocal: withMutation(keyPath: \.unfilteredLocal, remove)
            case .autoWithdrawBeforeExpiry: withMutation(keyPath: \.autoWithdrawBeforeExpiry, remove)
            case .veniceAllTiers: withMutation(keyPath: \.veniceAllTiers, remove)
            case .localShareMacInfo: withMutation(keyPath: \.localShareMacInfo, remove)
            case .localUseMemory: withMutation(keyPath: \.localUseMemory, remove)
            case .localSyncHermesMemory: withMutation(keyPath: \.localSyncHermesMemory, remove)
            case .localApprovedFolders: withMutation(keyPath: \.localApprovedFolders, remove)
            case .localUseCalendar: withMutation(keyPath: \.localUseCalendar, remove)
            case .localUseReminders: withMutation(keyPath: \.localUseReminders, remove)
            case .localUseContacts: withMutation(keyPath: \.localUseContacts, remove)
            case .doorPayment: withMutation(keyPath: \.doorPayment, remove)
            case .doorModel: withMutation(keyPath: \.doorModel, remove)
            case .doorBlockSecrets: withMutation(keyPath: \.doorBlockSecrets, remove)
            case .doorMaskEntities: withMutation(keyPath: \.doorMaskEntities, remove)
            case .doorPrivateTerms: withMutation(keyPath: \.doorPrivateTerms, remove)
            case .localVoiceAutoSpeak: withMutation(keyPath: \.localVoiceAutoSpeak, remove)
            case .spendGuardEnabled: withMutation(keyPath: \.spendGuardEnabled, remove)
            case .spendDailyLimitUSD: withMutation(keyPath: \.spendDailyLimitUSD, remove)
            case .spendPerCallLimitUSD: withMutation(keyPath: \.spendPerCallLimitUSD, remove)
            case .spendAllowedNetworks: withMutation(keyPath: \.spendAllowedNetworks, remove)
            case .localReasoningEffort: withMutation(keyPath: \.localReasoningEffort, remove)
            case .externalLocalServerURL, .externalLocalModelID, .externalLocalServerName:
                withMutation(keyPath: \.externalLocalSelection, remove)
            case .smartPrivatePreset: withMutation(keyPath: \.smartPrivatePreset, remove)
            case .servingPauseOnBattery: withMutation(keyPath: \.servingPauseOnBattery, remove)
            case .servingPauseOnHighThermal: withMutation(keyPath: \.servingPauseOnHighThermal, remove)
            case .servingQuietHoursEnabled: withMutation(keyPath: \.servingQuietHoursEnabled, remove)
            case .servingQuietStartHour: withMutation(keyPath: \.servingQuietStartHour, remove)
            case .servingQuietEndHour: withMutation(keyPath: \.servingQuietEndHour, remove)
            case .activeProjectProfileID: withMutation(keyPath: \.activeProjectProfileID, remove)
            case .securityProfile: withMutation(keyPath: \.securityProfile, remove)
            case .projectProfiles, .vModel, .depositExpires, .payProvider, .veniceModel, .venicePays,
                .walletTermsVersion, .walletTermsAcceptedAt: break
            }
        }
    }
}

/// Payment / inference rail for Connected Apps (Claude Code, OpenCode, Goose, Cursor, Cline, Aider, etc.).
enum DoorPayment: String, CaseIterable, Identifiable, Sendable {
    case local
    case near
    case venice
    case tempo
    case zkapi

    var id: Self { self }

    var payment: Payment {
        switch self {
        case .local, .near, .zkapi: .zkapi
        case .venice, .tempo: .tempo
        }
    }

    var macRoute: Door.MacRoute {
        switch self {
        case .local: .local
        case .near: .near
        case .venice: .venice
        case .tempo: .tempo
        case .zkapi: .zkapi
        }
    }

    var title: String {
        switch self {
        case .local: "Local Model (Free · $0)"
        case .near: "NEAR AI Gateway (TEE)"
        case .venice: "Venice AI (Base USDC / Key)"
        case .tempo: "Boundless (Tempo USDC.e)"
        case .zkapi: "zkAPI Anon Inference"
        }
    }

    var shortTitle: String {
        switch self {
        case .local: "Local ($0)"
        case .near: "NEAR TEE"
        case .venice: "Venice · Base"
        case .tempo: "Boundless · Tempo"
        case .zkapi: "zkAPI Anon"
        }
    }

    func isAllowed(in profile: SecurityProfile) -> Bool {
        switch self {
        case .local: true
        case .zkapi: profile.allowsZkAPI
        case .near: profile.allowsNear
        case .venice, .tempo: profile.allowsTokenInference
        }
    }
}

/// Providers available under Pay-Per-Prompt mode (Decision N5.1b).
enum PayProvider: String, CaseIterable, Identifiable {
    case venice
    case boundless

    var id: Self { self }

    var title: String {
        switch self {
        case .venice: "Venice (Base USDC)"
        case .boundless: "Boundless (Tempo USDC.e)"
        }
    }

    var shortTitle: String {
        switch self {
        case .venice: "Venice"
        case .boundless: "Boundless"
        }
    }
}

/// The selected Venice model saved in defaults.
struct VeniceChoice: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let tier: VeniceTier
}

/// How Chat rewrites prompts before sending them to remote AI services.
enum PromptRewriting: String, CaseIterable, Identifiable {
    case review
    case automatic
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .review: "Review before sending"
        case .automatic: "Automatic"
        case .off: "Off (reduces privacy)"
        }
    }
}

/// How long the model may go with nothing to reword before it leaves memory.
enum FreeMemory: String, CaseIterable, Identifiable {
    case fiveMinutes, fifteenMinutes, oneHour, never

    var id: Self { self }

    var title: String {
        switch self {
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        case .oneHour: "After 1 hour"
        case .never: "Never"
        }
    }

    /// Nil: the model stays in memory while Cloak runs.
    var after: Duration? {
        switch self {
        case .fiveMinutes: .seconds(5 * 60)
        case .fifteenMinutes: .seconds(15 * 60)
        case .oneHour: .seconds(60 * 60)
        case .never: nil
        }
    }
}

/// A key pressed with at least one of Command, Option and Control: the key's
/// code and Carbon's modifier bits, which the system registers, and the key
/// as shown. Shift alone is not enough, since it would take a capital letter
/// from every app.
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    /// The shortcut `flags` and the key make; nil without Command, Option or
    /// Control.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String) {
        let flags = flags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.keyCode = UInt32(keyCode)
        modifiers = [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)]
            .reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
        self.key = Self.names[Int(keyCode)] ?? key.uppercased()
    }

    /// The shortcut `event` presses.
    init?(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, flags: event.modifierFlags, key: event.characters(byApplyingModifiers: []) ?? "")
    }

    /// As the Mac's menus show one: Control, Option, Shift, Command, then the
    /// key.
    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    /// Keys whose character is blank or a control code.
    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Whether the app opens at login: the system's login item.
@MainActor
enum LoginItem {
    /// The login item as macOS has it, or as the last change left it.
    enum Stage: Equatable {
        case on
        case off
        /// Added, and waiting for its owner's approval in Login Items, as
        /// one they turned off there before does.
        case needsApproval
        /// macOS didn't add it (`adding`) or take it out, so it is as it was.
        case refused(adding: Bool)

        /// What the switch shows.
        var isOn: Bool { self == .on || self == .refused(adding: false) }

        /// What happened, for beside the switch, whose way on is Login
        /// Items (`openSettings`); nil while it is as asked.
        var words: String? {
            switch self {
            case .on, .off: nil
            case .needsApproval: "Needs your approval in Login Items."
            case .refused(adding: true): "macOS didn't add Cloak to Login Items."
            case .refused(adding: false): "macOS didn't take Cloak out of Login Items."
            }
        }
    }

    /// As macOS has it now.
    static var stage: Stage {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// Adds the app to the login items, or takes it out, and returns the
    /// stage after.
    static func set(_ on: Bool) -> Stage {
        let app = SMAppService.mainApp
        do {
            try on ? app.register() : app.unregister()
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot change the login item: \(String(describing: error), privacy: .public)")
        }
        return switch (stage, on) {
        case (.off, true): .refused(adding: true)
        case (.on, false): .refused(adding: false)
        case (let now, _): now
        }
    }

    /// System Settings' Login Items, where its owner approves the app, or
    /// adds or removes it themselves.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
