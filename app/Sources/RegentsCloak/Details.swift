import AppKit
import CloakControl
import CloakSupervisor
import SwiftUI

/// The one small window: the state, why it needs attention and what to do,
/// the release, the model, the last check, and technical detail on demand.
/// Closing it leaves the supervisor as it is.
@MainActor
final class DetailsWindow {
    private var window: NSWindow?

    func show(_ supervisor: Supervisor) {
        let window = self.window ?? make(supervisor)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make(_ supervisor: Supervisor) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Details"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DetailsView(supervisor: supervisor))
        window.center()
        return window
    }
}

/// A menu-bar app has no menus of its own, so the window closes itself on
/// Command-W and Escape.
private final class ClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct DetailsView: View {
    let supervisor: Supervisor
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
            }
            Section {
                LabeledContent("Release", value: "\(status.release) (\(status.build))")
                LabeledContent("Model") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(status.model.name)
                        Text(status.model.label.prefix(1).uppercased() + status.model.label.dropFirst())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Last check", value: lastCheck(status.check))
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $technical) {
                    Text(status.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lastCheck(_ check: StatusDocument.Check?) -> String {
        guard let check else { return "Not yet" }
        let time = check.at.formatted(date: .omitted, time: .shortened)
        return check.passed ? "Passed at \(time)" : "Failed at \(time)"
    }
}
