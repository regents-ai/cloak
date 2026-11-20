import AppKit
import CloakChat
import CloakDoor
import SwiftUI

/// The owner's other apps that send through Cloak: the address to point
/// them at, each app with a pass of its own, shown once when it is added,
/// and the latest chat requests, each with its texts once reworded, as the
/// app wrote them and as Cloak sent them. The door keeps those in memory
/// only.
struct AgentsView: View {
    static func window(_ door: Door) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agents"
        window.contentViewController = NSHostingController(rootView: AgentsView(door: door))
        return window
    }

    let door: Door
    @State private var adding = false
    @State private var removing: AgentApp?
    @State private var opened: AgentRequest?

    var body: some View {
        VStack(spacing: 0) {
            DevelopmentBar()
            Form {
                Section {
                    LabeledContent {
                        Copyable(text: door.address)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Address")
                            InfoButton("About Address", note: "Cloak rewords what you write on this Mac before it leaves; your apps' instructions, tools, tool results and the model's earlier answers go as the apps send them.")
                        }
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
                }
                if let problem = door.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Section {
                    if door.apps.isEmpty {
                        Text("No apps yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(door.apps) { app in
                        AppRow(app: app) { removing = app }
                    }
                } header: {
                    HStack {
                        Text("Apps")
                        Spacer()
                        SymbolButton("Add", symbol: "plus") { adding = true }
                    }
                }
                Section {
                    if door.requests.isEmpty {
                        Text("Nothing sent yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Drawn again each minute, so the last 24 hours stay true.
                        TimelineView(.everyMinute) { context in
                            let summary = summary(at: context.date)
                            LabeledContent("24 hours") {
                                Text(summary.joined(separator: " · "))
                                    .accessibilityLabel(summary.joined(separator: ", "))
                            }
                        }
                        ForEach(door.requests.prefix(Door.latest)) { request in
                            RequestRow(
                                request: request, sender: sender(of: request),
                                open: request.messages.isEmpty ? nil : { opened = request })
                        }
                    }
                } header: {
                    HStack(spacing: 2) {
                        Text("Activity")
                        InfoButton("About Activity", note: "Kept in memory only, and gone when Cloak quits.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 560)
        .task { await door.load() }
        .sheet(isPresented: $adding) {
            AddApp(door: door)
        }
        .sheet(item: $opened) { request in
            RequestTexts(request: request, sender: sender(of: request))
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

    /// The requests listed in the 24 hours to `now`, and the share of those
    /// finished that were answered, rounded down so a stop never shows as
    /// 100%.
    private func summary(at now: Date) -> [String] {
        let recent = door.requests.filter { now.timeIntervalSince($0.started) < 24 * 60 * 60 }
        guard !recent.isEmpty else { return ["None"] }
        let count = recent.count == 1 ? "1 request" : "\(recent.count.formatted()) requests"
        let finished = recent.filter { $0.stage != .rewording && $0.stage != .sending }
        guard !finished.isEmpty else { return [count] }
        let answered = Double(finished.count { $0.stage == .answered }) / Double(finished.count)
        return [count, "\(answered.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))) answered"]
    }

    private func sender(of request: AgentRequest) -> String {
        switch request.sender {
        case .app(let id): door.apps.first { $0.id == id }?.name ?? "Removed app"
        case .agent: "Cloak agent"
        }
    }
}

/// One chat request: who sent it, its model, how many messages went
/// reworded and how long it took, and where it is now. With its texts, the
/// whole row is a button, with a chevron, that opens them.
private struct RequestRow: View {
    let request: AgentRequest
    let sender: String
    /// Nil while the request has no texts to show.
    let open: (() -> Void)?

    var body: some View {
        // Drawn again each minute, so "2 minutes ago" stays true.
        TimelineView(.everyMinute) { _ in
            let when = request.started.formatted(.relative(presentation: .named))
            let words = ([stageWords] + details + [when]).joined(separator: ", ")
            if let open {
                Button(action: open) {
                    row(when: when)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                .accessibilityLabel(sender)
                .accessibilityValue(words)
                .accessibilityHint("Shows what the app wrote and what Cloak sent.")
            } else {
                row(when: when)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(sender)
                    .accessibilityValue(words)
            }
        }
    }

    private func row(when: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sender)
                    .fontWeight(.medium)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                stage
                Text(when)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch request.stage {
        case .rewording, .sending:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(stageWords)
            }
        case .answered:
            Text(stageWords)
        case .stopped(let words):
            Label {
                Text("Stopped")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            .help(words)
        }
    }

    private var stageWords: String {
        switch request.stage {
        case .rewording: "Rewording"
        case .sending: "Sending"
        case .answered: "Answered"
        case .stopped(let words): "Stopped: \(words)"
        }
    }

    /// The model once read, the messages reworded once all are, and the time
    /// taken once finished.
    private var details: [String] {
        var details = [String]()
        if let model = request.model { details.append(model) }
        switch request.reworded {
        case nil: break
        case 0: details.append("nothing reworded")
        case 1: details.append("1 message reworded")
        case let count?: details.append("\(count.formatted()) messages reworded")
        }
        if let took = request.took {
            details.append(took.formatted(.units(allowed: [.minutes, .seconds], width: .wide, fractionalPart: .show(length: 1))))
        }
        return details
    }
}

/// One request's user messages, the newest first: each as the app wrote it
/// and as Cloak sent it, in the boxes Chat's cards use, with the words
/// taken out and put in marked; one sent as written is shown once.
private struct RequestTexts: View {
    let request: AgentRequest
    let sender: String
    @Environment(\.dismiss) private var dismiss

    /// False for a request that stopped: it may not have left this Mac,
    /// so its texts are called reworded, not sent.
    private var went: Bool {
        if case .stopped = request.stage { false } else { true }
    }

    var body: some View {
        let when = request.started.formatted(date: .abbreviated, time: .shortened)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sender)
                    .font(.headline)
                Text(request.model.map { "\($0) · \(when)" } ?? when)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(request.messages.enumerated().reversed()), id: \.offset) { _, message in
                        MessageTexts(message: message, went: went)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // As tall as what it shows, up to the Agents window's height; past
        // that, the messages scroll.
        .frame(width: 500)
        .frame(maxHeight: 540)
        // Escape closes it too; Return is Done's.
        .onExitCommand { dismiss() }
    }
}

/// One user message: Written above Sent, as Chat marks them, or Written
/// alone when it went as written.
private struct MessageTexts: View {
    let message: AgentRequest.Message
    /// False for a request that stopped (`RequestTexts.went`).
    let went: Bool

    var body: some View {
        let sent = went ? "Sent" : "Reworded"
        Card {
            if message.written == message.sent {
                Pane(title: "Written", count: nil, mark: .removed) {
                    TextBox(text: .constant(message.written), label: "Written", editable: false)
                }
                Text(went ? "Sent as written" : "Not reworded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let diff = WordDiff(original: message.written, reworded: message.sent)
                Pane(title: "Written", count: diff.removed.count, mark: .removed) {
                    TextBox(text: .constant(message.written), label: "Written", editable: false, marks: diff.removed, mark: .removed)
                }
                Pane(title: sent, count: diff.added.count, mark: .added) {
                    TextBox(text: .constant(message.sent), label: sent, editable: false, marks: diff.added, mark: .added)
                }
            }
        }
        .accessibilityElement(children: .contain)
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
            .hover(Circle())
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
            .hover(Circle())
            .help("Copy")
        }
    }
}
