import AppKit
import CloakControl
import CloakSupervisor
import os
import ServiceManagement
import SwiftUI

/// The small window: the state, why it needs attention and what to do, the
/// release, the model, the last check, whether the app opens at login, and
/// technical detail on demand, the build among it. Closing it leaves the
/// supervisor as it is.
struct DetailsView: View {
    let supervisor: Supervisor

    static func window(_ supervisor: Supervisor) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Details"
        window.contentViewController = NSHostingController(rootView: DetailsView(supervisor: supervisor))
        return window
    }

    @State private var technical = false
    @State private var login = SMAppService.mainApp.status == .enabled

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
            Section {
                LabeledContent("Release", value: status.release)
                LabeledContent("Model", value: status.model.label)
                LabeledContent("Last check", value: lastCheck(status.check))
            }
            Section {
                Toggle("Launch Cloak on startup", isOn: Binding(get: { login }, set: openAtLogin))
            } footer: {
                Text("Cloak opens paused, so nothing runs until you press Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $technical) {
                    Text(status.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // In a form on macOS the disclosure gives VoiceOver nothing
                // to press, so it has an action of its own.
                .accessibilityAction { technical.toggle() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // The login item can change in System Settings while the window is
        // away, so the switch reads it again each time the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            login = SMAppService.mainApp.status == .enabled
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
