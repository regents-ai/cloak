import AppKit
import Carbon.HIToolbox
import CloakChat
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
    }

    /// Each setting until it is chosen, and again after Restore Defaults.
    /// The quick prompt's shortcut has none; Never reword is off; Cover,
    /// Review and Saved chats are on; Tor for NEAR is off; Local Llama
    /// answers with the model that rewords.
    nonisolated static let defaultFreeMemory = FreeMemory.fifteenMinutes
    nonisolated static let defaultProofFreshness = ProofFreshness.tenMinutes
    nonisolated static let defaultDoorPort: UInt16 = 8742
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
            return defaults.bool(forKey: Key.neverReword.rawValue)
        }
        set {
            withMutation(keyPath: \.neverReword) { defaults.set(newValue, forKey: Key.neverReword.rawValue) }
            if newValue { review = false }
        }
    }

    /// Whether the guest's daemon sends cover traffic: its own background
    /// fetches of the public pages in the one list (reference/cover.json).
    /// The supervisor reads it as it writes a guest's boot files; a change
    /// while Running restarts Cloak with it (`Supervisor.followCover`).
    var cover: Bool {
        get {
            access(keyPath: \.cover)
            return defaults.object(forKey: Key.cover.rawValue) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.cover) { defaults.set(newValue, forKey: Key.cover.rawValue) }
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

    /// Which provider Pay-Per-Prompt uses for new chats: defaults to Venice
    /// (Base USDC) per Decision N5.1b, with Boundless (Tempo USDC.e) alongside it.
    var payProvider: PayProvider {
        get {
            access(keyPath: \.payProvider)
            return defaults.string(forKey: Key.payProvider.rawValue).flatMap(PayProvider.init) ?? .venice
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
    var localContextOptions: LocalContextOptions {
        LocalContextOptions(
            shareMacInfo: localShareMacInfo,
            useMemory: localUseMemory,
            syncHermesMemory: localSyncHermesMemory,
            approvedFolders: localApprovedFolders,
            useCalendar: localUseCalendar,
            useReminders: localUseReminders,
            useContacts: localUseContacts)
    }

    /// Human-readable names of currently enabled Local Access sources.
    var activeLocalContextSummary: [String] {
        var names: [String] = []
        if localShareMacInfo { names.append("Mac info") }
        if localUseMemory { names.append("Memory") }
        if !localApprovedFolders.isEmpty {
            let count = localApprovedFolders.count
            names.append(count == 1 ? "1 folder" : "\(count) folders")
        }
        if localUseCalendar { names.append("Calendar") }
        if localUseReminders { names.append("Reminders") }
        if localUseContacts { names.append("Contacts") }
        return names
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
            case .vModel, .depositExpires, .payProvider, .veniceModel, .venicePays: break
            }
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
