import AppKit
import CloakChat
import CloakDoor
import CloakSupervisor
import SwiftUI

/// The owner's other apps that send through Cloak: the address to point
/// them at, the door's state with the one way on from it (`DoorLine`), each
/// app with a pass of its own, shown once when it is added, and the latest
/// chat requests, each with its texts once reworded, as the app wrote them
/// and as Cloak sent them. The door keeps those in memory only.
struct AgentsView: View {
    static func window(
        _ door: Door, supervisor: Supervisor, download: ModelDownload, settings: AppSettings,
        openDoor: @escaping () -> Void, showDetails: @escaping () -> Void, showDoorSettings: @escaping () -> Void
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agents"
        window.contentViewController = NSHostingController(
            rootView: AgentsView(
                door: door, supervisor: supervisor, download: download, settings: settings, openDoor: openDoor,
                showDetails: showDetails, showDoorSettings: showDoorSettings))
        return window
    }

    let door: Door
    let supervisor: Supervisor
    /// The download of the model that rewords, for the Start row's fix.
    let download: ModelDownload
    /// Read for the port the door takes when it next opens.
    let settings: AppSettings
    /// Opens the door again, in turn with the app's own opens and closes.
    let openDoor: () -> Void
    let showDetails: () -> Void
    /// Settings, on its Door pane, where the port is chosen.
    let showDoorSettings: () -> Void
    /// Read so the door's line is drawn again each time the window comes to
    /// the front: the app holding the port may have quit meanwhile.
    @Environment(\.appearsActive) private var appearsActive
    /// Nil while no app is being added.
    @State private var adding: Adding?
    @State private var removing: AgentApp?
    /// The request whose texts are open, by its id, so the sheet shows it
    /// as it is now.
    @State private var opened: AgentRequest.ID?

    var body: some View {
        let _ = appearsActive
        let line = DoorLine(door.state, running: supervisor.phase == .running, port: settings.doorPort)
        Form {
            Section {
                LabeledContent {
                    Copyable(text: door.address)
                } label: {
                    HStack(spacing: 2) {
                        Text("Address")
                        InfoButton(
                            "About Address",
                            note: "Cloak rewords what you write on this Mac before it leaves; your apps' instructions, tools, tool results and the model's earlier answers go as the apps send them. Each request is paid from V's deposit, with a new key.")
                    }
                }
                LabeledContent("Status") {
                    switch line {
                    case .open:
                        Label("Open", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                    case .stopped:
                        Text("Closed")
                            .foregroundStyle(.secondary)
                    case .opening:
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Opening")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    case .portTaken, .refused:
                        Label("Can't open", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                switch line {
                case .open, .opening:
                    EmptyView()
                case .stopped:
                    StartRow(supervisor: supervisor, download: download, showDetails: showDetails)
                case .portTaken(let port):
                    HStack(spacing: 8) {
                        Text("Another app is using port \(String(port)). Choose another, or quit that app.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change Port…", action: showDoorSettings)
                    }
                case .refused(let words):
                    HStack(spacing: 8) {
                        Text(words)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Try Again", action: openDoor)
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
                    SymbolButton("Add", symbol: "plus") { adding = .naming(stop: nil) }
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
                            request: request, sender: door.sender(of: request),
                            open: request.messages.isEmpty ? nil : { opened = request.id })
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
        .frame(width: 520, height: 560)
        .task { await door.load() }
        .sheet(item: $adding) { stage in
            AddApp(door: door, adding: stage) { adding = $0 }
        }
        // The request as it is now in the door's list, which keeps the
        // latest 200; it closes once the request is gone from there.
        .sheet(
            item: Binding(
                get: { opened.flatMap { id in door.requests.first { $0.id == id } } },
                set: { opened = $0?.id })
        ) { request in
            RequestTexts(request: request, sender: door.sender(of: request))
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
}

/// The door's state as the Agents window shows it, read in one place, each
/// with the one way on from it, by the rule the rest of the app uses for a
/// start that stopped (`Fix`): while Cloak isn't running, the Start row,
/// with Start or the start's own fix; while another app holds the port the
/// door takes next, so trying again is certain to fail, the way to the
/// port; for any other refusal, Try Again.
private enum DoorLine {
    case open
    /// Cloak isn't running, so the door is closed.
    case stopped
    /// Cloak is running and the door isn't open yet.
    case opening
    /// Another app holds the port the door takes next.
    case portTaken(UInt16)
    /// The door couldn't open, in its words.
    case refused(String)

    /// With the port the door takes when it next opens, which another app
    /// may hold.
    init(_ state: Door.State, running: Bool, port: UInt16) {
        switch state {
        case .open: self = .open
        case .closed: self = running ? .opening : .stopped
        case .refused(let words): self = AppSettings.isFree(port) ? .refused(words) : .portTaken(port)
        }
    }
}

private extension Door {
    /// Who sent `request`, by name.
    func sender(of request: AgentRequest) -> String {
        switch request.sender {
        case .app(let id): apps.first { $0.id == id }?.name ?? "Removed app"
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
        case .left(let paid):
            Label {
                Text("Left")
            } icon: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(paid ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .help(Self.left(paid: paid))
        }
    }

    private var stageWords: String {
        switch request.stage {
        case .rewording: "Rewording"
        case .sending: "Sending"
        case .answered: "Answered"
        case .stopped(let words): "Stopped: \(words)"
        case .left(let paid): "Left: \(Self.left(paid: paid))"
        }
    }

    private static func left(paid: Bool) -> String {
        paid
            ? "The app left after this was sent. It was paid for, and the answer went unread."
            : "The app left before this was sent. Nothing was paid."
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

    /// False for a request that stopped, or whose app left before it was
    /// sent: it may not have left this Mac, so its texts are called
    /// reworded, not sent.
    private var went: Bool {
        switch request.stage {
        case .stopped, .left(paid: false): false
        case .rewording, .sending, .answered, .left(paid: true): true
        }
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
                    // Newer requests have pushed this one's texts out since
                    // it was opened.
                    if request.messages.isEmpty {
                        Text("Cloak keeps the texts of the latest \(Door.latest) requests only.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(request.messages.enumerated().reversed()), id: \.offset) { _, message in
                        MessageTexts(message: message, went: went)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// Adding an app, from its name to its pass, as one value. The window
/// keeps it, not the sheet, and nothing closes the sheet while the app is
/// being kept, so a pass that was made is always shown, once.
private enum Adding: Identifiable {
    /// Asking the app's name; with the door's words when the last Add
    /// could not keep it.
    case naming(stop: String?)
    /// Keeping the app named.
    case keeping(name: String)
    /// Kept: its pass, shown this once.
    case kept(name: String, pass: String)

    /// Every stage is the one sheet, which stays as it was while it closes.
    var id: Int { 0 }
}

/// Asks the app's name, then shows its pass once, with the address. While
/// the app is kept there is no Cancel: the door keeps it either way.
private struct AddApp: View {
    let door: Door
    let adding: Adding
    /// The next stage; nil closes the sheet.
    let move: (Adding?) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch adding {
            case .kept(let name, let pass):
                Text(name)
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
                    Button("Done") { move(nil) }
                        .keyboardShortcut(.defaultAction)
                }
            case .naming(let stop):
                Text("New App")
                    .font(.headline)
                field
                if let stop {
                    Text(stop)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { move(nil) }
                        .keyboardShortcut(.cancelAction)
                    Button("Add", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .keeping:
                Text("New App")
                    .font(.headline)
                field
                    .disabled(true)
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding")
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        // Its own height, so the pass and the words under it wrap in full.
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isKeeping)
    }

    private var field: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("App name")
            .onSubmit(add)
    }

    private var isKeeping: Bool {
        if case .keeping = adding { true } else { false }
    }

    private func add() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .naming = adding, !name.isEmpty else { return }
        move(.keeping(name: name))
        Task {
            if let pass = await door.add(name) {
                move(.kept(name: name, pass: pass))
            } else {
                move(.naming(stop: door.problem))
            }
        }
    }
}

/// Text to paste elsewhere, in full, with Copy.
struct Copyable: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
            CopyButton(text: text)
        }
    }
}
