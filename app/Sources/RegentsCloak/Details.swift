import AppKit
import CloakControl
import CloakSupervisor
import SwiftUI

/// The small window: the state, what Running and Paused each mean, why it
/// needs attention and what to do, the
/// model's download while its files are not all in place, the release, the
/// model and whether it is out of memory, what Cloak holds in memory now,
/// the last check, and technical detail on demand, the build and each
/// part's memory among it, and the way to Chat's Modes page. Closing it
/// leaves the supervisor, and the download, as they are. The settings are
/// the Settings window's.
struct DetailsView: View {
    let supervisor: Supervisor
    let download: ModelDownload
    let memory: MemoryWatch
    let showModes: () -> Void

    static func window(_ supervisor: Supervisor, _ download: ModelDownload, showModes: @escaping () -> Void) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Details"
        window.contentViewController = NSHostingController(
            rootView: DetailsView(
                supervisor: supervisor, download: download, memory: MemoryWatch(supervisor, window: window), showModes: showModes))
        return window
    }

    @State private var technical = false

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
            } footer: {
                // What Start and Pause change, both said, so the two can be
                // told apart whichever Cloak is in.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running: Tor is connected. V and Token Inference chats can send.")
                    Text("Paused: Tor is off. V and Token Inference chats wait.")
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
                LabeledContent("Modes") {
                    SymbolButton("Show Modes", symbol: "square.grid.2x2", action: showModes)
                }
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
        // The model's files and the free space on disk can change while the
        // window is away, so they are read again each time it comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            download.refresh()
        }
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
