import AppKit
import CloakDoor
import SwiftUI

/// The owner's other apps that send through Cloak: the address to point
/// them at, and each app with a pass of its own, shown once when it is
/// added. Counts and times only; never what an app sent.
struct AgentsView: View {
    static func window(_ door: Door) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agents"
        window.contentViewController = NSHostingController(rootView: AgentsView(door: door))
        return window
    }

    let door: Door
    @State private var adding = false
    @State private var removing: AgentApp?

    var body: some View {
        VStack(spacing: 0) {
            DevelopmentBar()
            Form {
                Section {
                    LabeledContent("Address") {
                        Copyable(text: door.address)
                    }
                    LabeledContent("Status") {
                        switch door.state {
                        case .open:
                            Label("Open", systemImage: "circle.fill")
                                .foregroundStyle(.green)
                        case .closed:
                            Text("Closed while Cloak isn't running.")
                                .foregroundStyle(.secondary)
                        case .refused(let words):
                            Label(words, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                } footer: {
                    Text("Cloak rewords what you write on this Mac before it leaves; your apps' instructions, tools, tool results and the model's earlier answers go as the apps send them.")
                        .foregroundStyle(.secondary)
                }
                if let problem = door.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Section("Apps") {
                    if door.apps.isEmpty {
                        Text("No apps yet. Add one to give it a pass.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(door.apps) { app in
                        AppRow(app: app) { removing = app }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Add") { adding = true }
                    .buttonStyle(.borderedProminent)
            }
            // Level with the form's boxes.
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 560)
        .task { await door.load() }
        .sheet(isPresented: $adding) {
            AddApp(door: door)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { app in
            Button("Remove", role: .destructive) { door.remove(app.id) }
        } message: { _ in
            Text("Its pass stops working at once.")
        }
    }
}

/// One app: its name, when it was added, and its use.
private struct AppRow: View {
    let app: AgentApp
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .fontWeight(.medium)
                // Drawn again each minute, so "last used" stays true.
                TimelineView(.everyMinute) { _ in
                    Text(use)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(action: remove) {
                // A larger target than the icon alone.
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    private var use: String {
        let added = "Added \(app.added.formatted(date: .abbreviated, time: .omitted))"
        let requests = app.requests == 1 ? "1 request" : "\(app.requests.formatted()) requests"
        let last = app.lastUsed.map { "last used \($0.formatted(.relative(presentation: .named)))" } ?? "not used yet"
        return "\(added) · \(requests) · \(last)"
    }
}

/// Asks the app's name, then shows its pass once, with the address.
private struct AddApp: View {
    let door: Door
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pass: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pass {
                Text(name.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pass")
                        .font(.subheadline.weight(.semibold))
                    Copyable(text: pass)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Address")
                        .font(.subheadline.weight(.semibold))
                    Copyable(text: door.address)
                }
                Text("Copy the pass now: Cloak shows it only once. Paste it where the app asks for its key, and the address where it asks for one.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("New App")
                    .font(.headline)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("App name")
                    .onSubmit(add)
                if let problem = door.problem {
                    Text(problem)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Add", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        // Its own height, so the pass and the words under it wrap in full.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func add() {
        guard !working else { return }
        working = true
        Task {
            pass = await door.add(name)
            working = false
        }
    }
}

/// Text to paste elsewhere, in full, with Copy.
private struct Copyable: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                // A larger target than the icon alone.
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}
