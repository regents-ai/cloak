// Compiled only by `app/build.sh darkbloom`: Darkbloom's window is in no
// release until its makers allow it (decision 36 in docs/plan.md).
#if DARKBLOOM
import AppKit
import CloakSupervisor
import SwiftUI

/// Darkbloom on this Mac: setting it up, the one model that fits beside
/// Cloak, Start and Stop, the local address other apps use with its key,
/// serving Darkbloom's network too, and how it runs after Cloak quits.
/// Every fact shown is Darkbloom's own, read as it is now (`DarkbloomMode`).
struct DarkbloomView: View {
    static func window(_ mode: DarkbloomMode) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Darkbloom"
        window.contentViewController = NSHostingController(rootView: DarkbloomView(mode: mode))
        // Darkbloom is followed only while the window is open.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { mode.close() }
        }
        return window
    }

    let mode: DarkbloomMode
    @State private var confirmingStart = false
    /// What the network switch was turned to, while its restart waits on
    /// the confirmation; nil for Start's.
    @State private var switching: Bool?
    @State private var confirmingCancel = false
    @State private var confirmingRemove = false
    @State private var more = false

    var body: some View {
        Group {
            if mode.state == .unsupported {
                ContentUnavailableView(
                    "Needs macOS 27", systemImage: "exclamationmark.triangle",
                    description: Text("Darkbloom runs on macOS 27 or later."))
            } else {
                Form {
                    if mode.connected {
                        if !mode.changes.isEmpty { changes }
                        model
                        serving
                        if let endpoint = mode.snapshot?.endpoint { connection(endpoint) }
                        network
                        details
                    } else {
                        setup
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 560)
        .confirmationDialog("Change how Darkbloom serves?", isPresented: $confirmingStart) {
            Button(switching == nil ? "Start" : "Restart") {
                if let switching { mode.setAlsoServe(switching) } else { mode.start() }
            }
        } message: {
            Text(confirmed.map(\.start).joined(separator: " "))
        }
        .confirmationDialog("Cancel the download?", isPresented: $confirmingCancel) {
            Button("Cancel Download", role: .destructive) { mode.cancelDownload() }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Darkbloom stops downloading the model.")
        }
        .confirmationDialog("Remove \(mode.recommended?.displayName ?? "the model")?", isPresented: $confirmingRemove) {
            Button("Remove Model", role: .destructive) { mode.removeModel() }
        } message: {
            Text("Darkbloom deletes it from this Mac. Serving it again means downloading it again.")
        }
    }

    // MARK: Setup

    private var setup: some View {
        Section {
            LabeledContent {
                switch mode.state {
                case .notSetUp:
                    HStack {
                        Text("From darkbloom.dev")
                            .foregroundStyle(.secondary)
                        SymbolButton("Install", symbol: "arrow.down.circle") { mode.install() }
                            .overhanging()
                    }
                case .installing(let step):
                    ProgressView(value: Double(step), total: 5)
                        .frame(width: 140)
                        .accessibilityLabel("Installing")
                        .accessibilityValue("Step \(step) of 5")
                        .help("Installing, step \(step) of 5")
                case .notConnected:
                    HStack(spacing: 2) {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        InfoButton("About Connect", note: Self.connectNote)
                        SymbolButton("Connect", symbol: "link") { mode.connect() }
                            .overhanging()
                    }
                case .failed(let failure):
                    HStack(spacing: 2) {
                        Failure(failure: failure)
                        SymbolButton("Try Again", symbol: "arrow.clockwise") { mode.open() }
                            .overhanging()
                    }
                default:
                    Working(words: "Checking")
                }
            } label: {
                HStack(spacing: 2) {
                    Text("Runtime")
                    InfoButton("About Runtime", note: Self.runtimeNote)
                }
            }
        } header: {
            Text("Setup")
        }
    }

    private static let runtimeNote = """
        Install downloads Darkbloom's installer from api.darkbloom.dev and runs it, as Darkbloom's own app does: it \
        puts Darkbloom in ~/.darkbloom and adds it to your shell's path in ~/.zshrc. Before Cloak runs anything of \
        Darkbloom's, it checks that it is signed by Darkbloom's developer (team SLDQ2GJ6TL). Cloak then starts \
        Darkbloom's control service, which stays on this Mac and opens at login. Nothing is served until you press \
        Start. Closing this window before Install finishes stops it.
        """

    private static let connectNote = """
        Cloak talks to Darkbloom through Darkbloom's control service, on this Mac only. Connect starts it, as \
        Darkbloom's own app does; it stays on this Mac and opens at login. Nothing is served until you press Start.
        """

    // MARK: Existing setup

    private var changes: some View {
        Section {
            ForEach(mode.changes, id: \.self) { change in
                Label(change.words, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        } header: {
            HStack(spacing: 2) {
                Text("Current Setup")
                InfoButton(
                    "About Current Setup",
                    note: "How Darkbloom serves on this Mac now, set outside Cloak. Cloak changes nothing until you press Start, which serves the model below with your requests kept on this Mac and its address open to this Mac only.")
            }
        }
    }

    // MARK: Model

    private var model: some View {
        Section {
            if let model = mode.recommended {
                LabeledContent {
                    modelAction(model)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        if let size = model.sizeGb {
                            Text("\(size, format: .number.precision(.fractionLength(1))) GB")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(noModel)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 2) {
                Text("Model")
                InfoButton("About Model", note: modelNote)
            }
        }
    }

    @ViewBuilder
    private func modelAction(_ model: DarkbloomSnapshot.Model) -> some View {
        if case .downloading(let progress) = mode.state {
            HStack {
                Group {
                    if let progress {
                        ProgressView(value: progress)
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    } else {
                        ProgressView(value: nil as Double?)
                    }
                }
                .frame(width: 120)
                .accessibilityLabel("Download")
                SymbolButton("Cancel Download", symbol: "xmark.circle") { confirmingCancel = true }
                    .overhanging()
            }
        } else if model.downloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Downloaded")
                .accessibilityLabel("Downloaded")
        } else {
            SymbolButton("Download", symbol: "arrow.down.circle") { mode.downloadModel() }
                .overhanging()
        }
    }

    private var noModel: String {
        if mode.snapshot?.catalogError != nil { return "Darkbloom's model list is unavailable." }
        if mode.room == nil { return "Darkbloom doesn't say what fits." }
        return "No model fits beside Cloak."
    }

    private var modelNote: String {
        let room = mode.snapshot?.memory.pinBudgetGb.map {
            " Darkbloom lets models take \($0.formatted(.number.precision(.fractionLength(0)))) GB here."
        } ?? ""
        return "The largest model in Darkbloom's list that this Mac can serve beside Cloak, which keeps "
            + "\(Memory.text(mode.cloakMemory)) for itself.\(room) One already on this Mac comes first. Darkbloom "
            + "downloads it over the network."
    }

    // MARK: Serving

    private var serving: some View {
        Section {
            LabeledContent {
                HStack {
                    if mode.isOn {
                        SymbolButton("Stop", symbol: "stop.fill") { mode.stop() }
                            .overhanging()
                            .disabled(mode.state == .stopping)
                    } else {
                        if let block = mode.startBlock {
                            Text(block)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        SymbolButton("Start", symbol: "play.fill") {
                            switching = nil
                            if mode.changes.isEmpty { mode.start() } else { confirmingStart = true }
                        }
                        .overhanging()
                        .disabled(mode.startBlock != nil)
                    }
                }
            } label: {
                status
            }
        } header: {
            Text("Serving")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch mode.state {
        case .serving:
            Label("Serving", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .loading:
            Working(words: "Loading")
        case .stopping:
            Working(words: "Stopping")
        case .stopped:
            Label("Stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .noModel:
            Label("No model", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .failed(let failure):
            Failure(failure: failure)
        case .unsupported, .looking, .notSetUp, .installing, .notConnected, .connecting:
            Working(words: "Connecting")
        }
    }

    // MARK: Connection

    private func connection(_ endpoint: DarkbloomSnapshot.Endpoint) -> some View {
        Section {
            LabeledContent("Address") {
                Copyable(text: endpoint.baseUrl)
            }
            LabeledContent("Key") {
                if endpoint.authenticated {
                    key
                } else {
                    Text("None needed")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                reach
            } label: {
                HStack(spacing: 2) {
                    Text("Requests")
                    InfoButton("About Requests", note: reachNote)
                }
            }
        } header: {
            Text("Connection")
        }
    }

    private var key: some View {
        HStack(spacing: 4) {
            if let key = mode.shownKey {
                Text(key)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SymbolButton("Hide Key", symbol: "eye.slash") { mode.hideKey() }
                    .overhanging()
            } else {
                Text("••••••••••••")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden")
                SymbolButton("Show Key", symbol: "eye") { Task { await mode.showKey() } }
                    .overhanging()
            }
            SymbolButton("Copy Key", symbol: "doc.on.doc") {
                Task {
                    guard let key = await mode.key() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
            .overhanging()
        }
    }

    @ViewBuilder
    private var reach: some View {
        switch mode.reach {
        case .thisMac:
            Label("Stay on this Mac", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .beyond:
            Label("Open beyond this Mac", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        case .forwards:
            Label("Can leave this Mac", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        case .unknown:
            Label("Can't confirm", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    private var reachNote: String {
        let route = switch mode.setup.route {
        case "this-mac": "this Mac only"
        case "my-macs": "your other Macs when this one is busy"
        case "my-macs-first": "your other Macs, then Darkbloom's network, when this one is busy"
        case let other?: other
        case nil: "unknown"
        }
        let listens = mode.setup.listens ?? "unknown"
        return "Where requests to this address go, from Darkbloom's own files now: they are sent to \(route), and the "
            + "address listens on \(listens). Another Darkbloom app, or darkbloom route in Terminal, can change "
            + "where they are sent at any time; Cloak shows what it reads each time. Darkbloom itself still uses the "
            + "network to download models and updates."
    }

    // MARK: Network

    private var network: some View {
        Section {
            LabeledContent {
                HStack {
                    if !mode.canAlsoServe {
                        Text("Needs a newer Darkbloom")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Serve Network", isOn: Binding(get: { mode.alsoServe }, set: switchNetwork))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!mode.canAlsoServe)
                }
            } label: {
                HStack(spacing: 2) {
                    Text("Serve Network")
                    InfoButton("About Serve Network", note: Self.networkNote)
                }
            }
            if mode.alsoServe, let snapshot = mode.snapshot {
                if let link = mode.linking {
                    LabeledContent("Code") {
                        Text(link.code)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Continue in Browser") { mode.continueInBrowser() }
                    }
                }
                LabeledContent("Account") {
                    if snapshot.linked {
                        Label("Linked", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if snapshot.operations.contains(where: { $0.state == "running" && $0.action == "link" }) {
                        Working(words: "Linking")
                    } else {
                        Text("Not linked")
                            .foregroundStyle(.secondary)
                    }
                }
                if snapshot.linked {
                    LabeledContent("Network") {
                        networkStatus(snapshot)
                    }
                }
            }
        } header: {
            Text("Network")
        }
    }

    /// Turning the switch while Darkbloom serves restarts it, which asks
    /// first when that changes a setup made outside Cloak.
    private func switchNetwork(_ on: Bool) {
        switching = on
        if mode.isOn, !confirmed.isEmpty { confirmingStart = true } else { mode.setAlsoServe(on) }
    }

    /// What the confirmation names: everything Start changes, or for the
    /// switch, everything but serving the network, which is the switch's
    /// own choice.
    private var confirmed: [DarkbloomMode.Change] {
        switching == nil ? mode.changes : mode.changes.filter { $0 != .network }
    }

    @ViewBuilder
    private func networkStatus(_ snapshot: DarkbloomSnapshot) -> some View {
        if snapshot.state != "running" || mode.setup.job?.mode == .onlyMe {
            Text("Off")
                .foregroundStyle(.secondary)
        } else if snapshot.providerStatus == "untrusted" {
            Label("Verification needed", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .help("Darkbloom hasn't verified this Mac yet.")
        } else if snapshot.providerStatus == "offline" {
            Working(words: "Connecting")
        } else if snapshot.models.contains(where: { $0.registration == "routable" }) {
            Label("Serving requests", systemImage: "circle.fill")
                .foregroundStyle(.green)
        } else {
            Working(words: "Joining")
        }
    }

    private static let networkNote = """
        This Mac also answers requests from Darkbloom's network. Yours go first: Darkbloom's pause while you use this \
        Mac's address and come back once you stop. Your own requests stay on this Mac either way. Turning it on links \
        this Mac to your Darkbloom account: you sign in on Darkbloom's page in your browser and enter the code shown \
        here, so Cloak never sees your password or account key. Requests come once Darkbloom has verified this Mac.
        """

    // MARK: Details

    private var details: some View {
        Section {
            DisclosureGroup(isExpanded: $more) {
                if let model = mode.recommended, model.downloaded {
                    LabeledContent("Model") {
                        HStack {
                            if model.serving || model.loaded {
                                Text("Stop first")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            SymbolButton("Remove Model", symbol: "trash") { confirmingRemove = true }
                                .overhanging()
                                .disabled(model.serving || model.loaded)
                        }
                    }
                }
                LabeledContent {
                    Text(mode.setup.job?.loaded == true ? "Keeps serving" : "Nothing runs")
                } label: {
                    HStack(spacing: 2) {
                        Text("After Quit")
                        InfoButton(
                            "About After Quit",
                            note: "Darkbloom serves from its own service, which launchd runs, not Cloak, so quitting Cloak doesn't stop it. Stop does.")
                    }
                }
                LabeledContent {
                    Text(mode.setup.job.map { $0.loaded && $0.runsAtLoad } == true ? "Starts" : "Off")
                } label: {
                    HStack(spacing: 2) {
                        Text("At Login")
                        InfoButton(
                            "About At Login",
                            note: "While Darkbloom is set to serve, its service starts at login; Stop turns that off too. Cloak adds no login item of its own.")
                    }
                }
                LabeledContent("Version", value: mode.version ?? "Unknown")
            } label: {
                // In a form on macOS the disclosure gives VoiceOver nothing
                // to press, so its title has an action of its own.
                Text("More")
                    .accessibilityAction { more.toggle() }
            }
        }
    }
}

/// A small spinner and what is under way.
private struct Working: View {
    let words: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(words)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
    }
}

/// What stopped, in a few words, with Darkbloom's reason behind its note.
private struct Failure: View {
    let failure: DarkbloomFailure

    var body: some View {
        HStack(spacing: 2) {
            Label(failure.words, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            if let detail = failure.detail {
                InfoButton("About \(failure.words)", note: detail)
            }
        }
    }
}
#endif
