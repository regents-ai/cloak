import AppKit
import Carbon.HIToolbox
import CloakChat
import CloakControl
import CloakDoor
import CloakSupervisor
import Foundation
import os
@testable import RegentsCloak
import Testing

/// The Settings window's settings: each starts at its default, is kept, and
/// goes back with Restore Defaults; the door's port is refused out of range
/// or while something listens on it, and a refused one changes nothing; a
/// shortcut needs Command, Option or Control; and the quick prompt's text
/// becomes a new chat's draft, unsent.
@MainActor
@Suite(.serialized)
struct SettingsTests {
    /// Settings in defaults of the test's own: a domain named by a path,
    /// which keeps its file there, in a temporary folder removed after.
    private static func settings(_ use: (AppSettings, UserDefaults) throws -> Void) throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-settings-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try use(AppSettings(defaults), defaults)
    }

    @Test func eachSettingStartsAtItsDefaultIsKeptAndGoesBackOnRestore() throws {
        try Self.settings { settings, defaults in
            #expect(settings.freeMemory == .fiveMinutes)
            #expect(settings.shortcut == nil)
            #expect(settings.doorPort == 8742)

            let shortcut = try #require(Shortcut(keyCode: UInt16(kVK_Space), flags: [.option], key: " "))
            let port = try Stand.freePort()
            settings.freeMemory = .never
            settings.shortcut = shortcut
            try settings.choose(port: String(port), open: nil)
            // Kept: read again from the same defaults, as at the next launch,
            // and as the supervisor reads the free memory.
            let again = AppSettings(defaults)
            #expect(again.freeMemory == .never)
            #expect(AppSettings.freeMemory(in: defaults) == .never)
            #expect(again.shortcut == shortcut)
            #expect(again.doorPort == port)

            settings.restore()
            #expect(settings.freeMemory == .fiveMinutes)
            #expect(settings.shortcut == nil)
            #expect(settings.doorPort == 8742)
            #expect(AppSettings.Key.allCases.allSatisfy { defaults.object(forKey: $0.rawValue) == nil })
        }
    }

    @Test func aPortOutOfRangeIsRefusedAndChangesNothing() throws {
        try Self.settings { settings, _ in
            for text in ["0", "80", "1023", "65536", "99999", "-1", "", "port", "8742.5", "9 000"] {
                #expect(throws: AppSettings.PortRefusal.outOfRange) { try settings.choose(port: text, open: nil) }
                #expect(settings.doorPort == 8742)
            }
        }
    }

    @Test(arguments: [INADDR_LOOPBACK, INADDR_ANY])
    func aPortSomethingListensOnIsRefusedAndChangesNothing(_ address: in_addr_t) throws {
        try Self.settings { settings, _ in
            let (held, port) = try Self.listen(on: address)
            defer { close(held) }
            #expect(throws: AppSettings.PortRefusal.taken) { try settings.choose(port: String(port), open: nil) }
            #expect(throws: AppSettings.PortRefusal.taken) { try settings.choose(port: String(port), open: 8742) }
            #expect(settings.doorPort == 8742)
        }
    }

    @Test func aFreePortIsKeptAndSoIsThePortTheDoorHolds() throws {
        try Self.settings { settings, _ in
            let (held, port) = try Self.listen(on: INADDR_LOOPBACK)
            close(held)
            try settings.choose(port: " \(port) ", open: nil)
            #expect(settings.doorPort == port)
            #expect(AppSettings.doorPorts.contains(Int(port)))

            // The door listens on it: saved again, it stays.
            let (door, _) = try Self.listen(on: INADDR_LOOPBACK, port: port)
            defer { close(door) }
            try settings.choose(port: String(port), open: port)
            #expect(settings.doorPort == port)

            // Another port chosen while the door is open, then the door's
            // own again: Cloak holds it, so it is taken back.
            let (other, otherPort) = try Self.listen(on: INADDR_LOOPBACK)
            close(other)
            try settings.choose(port: String(otherPort), open: port)
            #expect(settings.doorPort == otherPort)
            try settings.choose(port: String(port), open: port)
            #expect(settings.doorPort == port)
        }
    }

    @Test(arguments: [[], [.shift], [.capsLock], [.function], [.shift, .capsLock]] as [NSEvent.ModifierFlags])
    func aShortcutWithoutCommandOptionOrControlIsRefused(_ flags: NSEvent.ModifierFlags) {
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_K), flags: flags, key: "k") == nil)
    }

    @Test func aShortcutTakesCommandOptionControlAndShiftAndNothingElse() throws {
        let shortcut = try #require(Shortcut(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift, .capsLock, .function], key: "k"))
        #expect(shortcut.keyCode == UInt32(kVK_ANSI_K))
        #expect(shortcut.modifiers == UInt32(cmdKey | shiftKey))
        #expect(shortcut.title == "⇧⌘K")
        for (flag, bit) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey)] {
            #expect(Shortcut(keyCode: UInt16(kVK_Space), flags: flag, key: " ")?.modifiers == UInt32(bit))
        }
    }

    @Test func theQuickPromptsTextBecomesANewChatsDraftUnsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let door = Door(
            file: fixture.root.appending(path: "agents"), wallet: fixture.root.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { _ throws(RewriteStop) in
                    Issue.record("reworded")
                    return []
                },
                exchange: { _, _ in
                    Issue.record("sent")
                    return Data()
                },
                wallet: { nil }, key: { Data(repeating: 0x11, count: 32) }, sealing: { nil }),
            port: { 0 })
        let chat = Chat(
            supervisor: try fixture.supervisor(), folder: fixture.root.appending(path: "conversations"),
            wallet: fixture.root.appending(path: "wallet"), door: door)
        chat.kind = .agent
        chat.compose("Find a quiet table for two tonight")
        #expect(chat.draft == "Find a quiet table for two tonight")
        #expect(chat.kind == .chat)
        #expect(chat.rewording == nil)
        #expect(chat.sending.isEmpty)
        #expect(chat.conversations.allSatisfy { $0.turns.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "conversations").path))
    }

    @Test func theLogHasThisSessionsLinesOfCloaksLogOnly() async throws {
        let mark = UUID().uuidString
        Logger(subsystem: "sh.regents.cloak.app", category: "test").info("settings test \(mark, privacy: .public)")
        Logger(subsystem: "sh.regents.cloak.other", category: "test").info("other \(mark, privacy: .public)")
        let lines = try await SessionLog.read()
        #expect(lines.contains { $0.hasSuffix("test settings test \(mark)") })
        #expect(!lines.contains { $0.contains("other \(mark)") })
    }

    /// A socket listening on `address` and `port`, or a port the system picks:
    /// it and its port.
    private static func listen(on address: in_addr_t, port: UInt16 = 0) throws -> (Int32, UInt16) {
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        var bound = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: address.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(holder, $0, length) == 0 && Darwin.listen(holder, 1) == 0 && getsockname(holder, $0, &length) == 0
            }
        }
        guard listening else {
            close(holder)
            throw POSIXError(.EADDRINUSE)
        }
        return (holder, UInt16(bigEndian: bound.sin_port))
    }
}
