import AppKit
import CloakChat
import CloakControl
import Foundation
import Observation

/// Observable controller for Cloak's local `Traces` folder
/// (`~/Library/Application Support/Regents Cloak/Traces`).
///
/// Tracks which NEAR AI Gateway conversations have been exported as Letta
/// Trajectory v1 files, detects whether the NEAR AI Gateway Mac app is
/// installed, and enforces the opt-in `AppSettings.nearShareTraces` gate.
@MainActor
@Observable
final class NearTraces {
    static let gatewayWebsiteURL = URL(string: "https://gateway.near.ai")!
    static let traceCommonsGitHubURL = URL(string: "https://github.com/TraceCommons/trace-commons")!

    let folder: URL
    let settings: AppSettings

    /// Exported trace files currently on disk, keyed by conversation ID.
    private(set) var exported: [UUID: NearTraceExporter.ExportedFile] = [:]
    /// Last user-visible write/delete error, cleared on the next successful action.
    var errorMessage: String?

    init(folder: URL = Places.support.appending(path: "Traces"), settings: AppSettings = .standard) {
        self.folder = folder
        self.settings = settings
        refresh()
    }

    /// Reloads the exported trace index from disk.
    func refresh() {
        exported = NearTraceExporter.scan(in: folder)
    }

    var exportedCount: Int {
        exported.count
    }

    var exportedBytes: Int {
        exported.values.reduce(0) { $0 + $1.bytes }
    }

    func file(for conversationID: UUID) -> NearTraceExporter.ExportedFile? {
        exported[conversationID]
    }

    func isExported(_ conversationID: UUID) -> Bool {
        exported[conversationID] != nil
    }

    /// True when the conversation has more answered turns than its exported file.
    func hasNewTurns(for conversation: Conversation) -> Bool {
        guard let file = exported[conversation.id] else { return false }
        let answered = conversation.turns.filter { $0.answer != nil }.count
        return answered > file.turnCount
    }

    /// Turns trace sharing on (creating the owner-only, Time-Machine-excluded
    /// folder) or off (optionally deleting exported files when confirmed).
    func setEnabled(_ enabled: Bool, deleteFiles: Bool = false) {
        errorMessage = nil
        if enabled {
            do {
                try NearTraceExporter.prepareFolder(folder)
                settings.nearShareTraces = true
                refresh()
            } catch {
                errorMessage = "Couldn't create the Traces folder. Check free space and try again."
            }
        } else {
            if deleteFiles {
                do {
                    try NearTraceExporter.removeAll(in: folder)
                } catch {
                    errorMessage = "Couldn't remove some exported traces."
                    refresh()
                    return
                }
            }
            settings.nearShareTraces = false
            refresh()
        }
    }

    /// Exports one NEAR AI Gateway conversation as a Letta Trajectory v1 file.
    @discardableResult
    func export(_ conversation: Conversation) -> Bool {
        errorMessage = nil
        if !settings.nearShareTraces {
            settings.nearShareTraces = true
        }
        do {
            let file = try NearTraceExporter.export(conversation, to: folder)
            exported[conversation.id] = file
            return true
        } catch {
            switch error {
            case .notNearChat:
                errorMessage = "Only NEAR AI Gateway chats can be exported as traces."
            case .noAnsweredTurns:
                errorMessage = "Wait for at least one reply before exporting this chat."
            case .io:
                errorMessage = "Couldn't save the trace. Check free space and try again."
            }
            return false
        }
    }

    /// Removes one exported trace copy from Cloak's `Traces` folder.
    func remove(_ conversationID: UUID) {
        errorMessage = nil
        do {
            try NearTraceExporter.remove(conversationID: conversationID, from: folder)
            exported.removeValue(forKey: conversationID)
        } catch {
            errorMessage = "Couldn't remove the exported trace."
        }
    }

    /// Reveals the `Traces` folder in Finder (creating it first if needed).
    func revealInFinder() {
        errorMessage = nil
        do {
            try NearTraceExporter.prepareFolder(folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            errorMessage = "Couldn't open the Traces folder."
        }
    }

    /// Copies the `Traces` folder path to the pasteboard (for ⇧⌘G in file pickers).
    func copyFolderPath() {
        _ = try? NearTraceExporter.prepareFolder(folder)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
    }

    /// Locates an installed NEAR AI Gateway Mac app, if present.
    var installedGatewayAppURL: URL? {
        let workspace = NSWorkspace.shared
        for bundleID in ["ai.tracecommons.shell", "ai.near.gateway"] {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        let candidates = [
            "/Applications/NEAR AI Gateway.app",
            "/Applications/Near AI Gateway.app",
            "\(NSHomeDirectory())/Applications/NEAR AI Gateway.app",
            "\(NSHomeDirectory())/Applications/Near AI Gateway.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Opens NEAR AI Gateway if installed, otherwise opens `gateway.near.ai`.
    func openGatewayAppOrWebsite() {
        if let appURL = installedGatewayAppURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else {
            NSWorkspace.shared.open(Self.gatewayWebsiteURL)
        }
    }
}
