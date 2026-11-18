import AppKit
import CloakControl
import CloakSupervisor
import os
import ServiceManagement
import SwiftUI

/// The small window: the state, why it needs attention and what to do, the
/// model's download while its files are not all in place, the release, the
/// model and whether it is out of memory, what Cloak holds in memory now,
/// the last check, how long the model may go unused before it leaves
/// memory, whether the app opens at login, and technical detail on demand,
/// the build and each part's memory among it. Closing it leaves the
/// supervisor, and the download, as they are.
struct DetailsView: View {
    let supervisor: Supervisor
    let download: ModelDownload
    let memory: MemoryWatch

    static func window(_ supervisor: Supervisor, _ download: ModelDownload) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Details"
        window.contentViewController = NSHostingController(
            rootView: DetailsView(supervisor: supervisor, download: download, memory: MemoryWatch(supervisor, window: window)))
        return window
    }

    @State private var technical = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @AppStorage(FreeMemory.key) private var freeMemory = FreeMemory.unchosen

    var body: some View {
        let status = supervisor.status
        Form {
            Section {
                LabeledContent("Status") {
                    Label(status.state.title, systemImage: supervisor.phase.symbol)
                        .foregroundStyle(status.state == .needsAttention ? Color.orange : Color.primary)
                }
                if let reason = status.reason {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason.title)
                        Text(reason.remedy)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if download.state != .installed {
                DownloadSection(download: download)
            }
            Section {
                LabeledContent("Release", value: status.release)
                LabeledContent("Model", value: supervisor.resting ? "\(status.model.label), unloaded" : status.model.label)
                LabeledContent("Memory", value: memory.reading.total.map(Memory.text) ?? "Can't be measured")
                LabeledContent("Last check", value: lastCheck(status.check))
            }
            Section {
                Picker("Free memory", selection: $freeMemory) {
                    ForEach(FreeMemory.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("The model leaves memory once Cloak has reworded nothing for that long, and the next message takes a few seconds longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch Cloak on startup", isOn: Binding(get: { login }, set: openAtLogin))
            } footer: {
                Text("Cloak opens paused, so nothing runs until you press Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup(isExpanded: $technical) {
                    Text(status.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    // In a form on macOS the disclosure gives VoiceOver
                    // nothing to press, so its title has an action of its
                    // own; the details under it stay text.
                    Text("Technical details")
                        .accessibilityAction { technical.toggle() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // The login item can change in System Settings while the window is
        // away, and the model's files and the free space on disk too, so
        // each is read again each time the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            login = SMAppService.mainApp.status == .enabled
            download.refresh()
        }
    }

    /// Adds the app to the login items, or takes it out. One the user turned
    /// off in System Settings needs their approval there, which opens.
    private func openAtLogin(_ on: Bool) {
        let app = SMAppService.mainApp
        do {
            try on ? app.register() : app.unregister()
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot change the login item: \(String(describing: error), privacy: .public)")
        }
        if app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        login = app.status == .enabled
    }

    private func lastCheck(_ check: StatusDocument.Check?) -> String {
        guard let check else { return "Not yet" }
        let time = check.at.formatted(date: .omitted, time: .shortened)
        return check.passed ? "Passed at \(time)" : "Failed at \(time)"
    }
}

/// What Cloak holds in memory (`Supervisor.memory`), read again every 3
/// seconds while the Details window is on screen and not at all otherwise.
/// The window and its views are kept when it closes, and their tasks run
/// on, so this follows the window's own visibility.
@MainActor
@Observable
final class MemoryWatch {
    private(set) var reading: Memory
    @ObservationIgnored private let supervisor: Supervisor
    @ObservationIgnored private var refresh: Task<Void, Never>?

    init(_ supervisor: Supervisor, window: NSWindow) {
        self.supervisor = supervisor
        reading = supervisor.memory()
        // The window, and so this, lasts as long as the app.
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.follow(onScreen: window?.occlusionState.contains(.visible) == true)
            }
        }
    }

    private func follow(onScreen: Bool) {
        refresh?.cancel()
        refresh = onScreen ? Task {
            repeat {
                reading = supervisor.memory()
            } while (try? await Task.sleep(for: .seconds(3))) != nil
        } : nil
    }
}

/// How long the model may go with nothing to reword before it leaves memory,
/// as chosen in the Details window and kept in the app's defaults. The
/// supervisor reads it each time that time starts again, so a change applies
/// from then, with no restart.
enum FreeMemory: String, CaseIterable, Identifiable {
    case fiveMinutes, fifteenMinutes, oneHour, never

    static let key = "freeMemory"
    /// Until the person chooses.
    static let unchosen = FreeMemory.fiveMinutes

    /// The choice kept, or `unchosen`.
    static var chosen: FreeMemory {
        UserDefaults.standard.string(forKey: key).flatMap(FreeMemory.init) ?? unchosen
    }

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
