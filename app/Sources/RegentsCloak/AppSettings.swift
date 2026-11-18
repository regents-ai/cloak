import AppKit
import Carbon.HIToolbox
import Darwin
import Observation
import os
import ServiceManagement

/// Cloak's settings, kept in the app's defaults: every key and its default
/// is named here, once, and read and written only here. Only the Settings
/// window sets them. No setting can be set from a link, from the door, from
/// AppleScript or from the guest: none of those reaches this type. Whether
/// the app opens at login is the system's login item (`LoginItem`), and
/// whether it checks for updates by itself is Sparkle's own setting
/// (`Updates`); neither is a default kept here.
@MainActor
@Observable
final class AppSettings {
    static let standard = AppSettings(.standard)

    /// Every key, one per setting.
    enum Key: String, CaseIterable {
        case freeMemory
        case shortcut
        case doorPort
    }

    /// Each setting until it is chosen, and again after Restore Defaults.
    /// The quick prompt's shortcut has none.
    nonisolated static let defaultFreeMemory = FreeMemory.fiveMinutes
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

    /// Puts every setting kept here back to its default.
    func restore() {
        withMutation(keyPath: \.freeMemory) {
            withMutation(keyPath: \.shortcut) {
                withMutation(keyPath: \.doorPort) {
                    for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
                }
            }
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
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Adds the app to the login items, or takes it out, and returns whether
    /// it is in now. One the user turned off in System Settings needs their
    /// approval there, which opens.
    static func set(_ on: Bool) -> Bool {
        let app = SMAppService.mainApp
        do {
            try on ? app.register() : app.unregister()
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot change the login item: \(String(describing: error), privacy: .public)")
        }
        if app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isOn
    }
}
