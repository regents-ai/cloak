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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Inference Serving"
        window.contentViewController = NSHostingController(rootView: DarkbloomView(mode: mode))
        window.setFrameAutosaveName("sh.regents.cloak.window.serving")
        // Darkbloom is followed only while the window is open.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { mode.close() }
        }
        return window
    }

    let mode: DarkbloomMode
    var embedded = false
    @State private var confirmingStart = false
    /// Target serving mode waiting on the existing-setup confirmation dialog;
    /// nil when confirming a model switch.
    @State private var pendingMode: DarkbloomMode.ServingMode?
    @State private var cancellingOp: String?
    @State private var removingModel: DarkbloomSnapshot.Model?
    @State private var showAllModels = false
    @State private var more = false
    @State private var hoveringDownloadPrompt = false
    @State private var flashDownload = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        Group {
            if mode.state == .unsupported {
                ContentUnavailableView(
                    "Needs macOS 27", systemImage: "exclamationmark.triangle",
                    description: Text("Darkbloom runs on macOS 27 or later."))
            } else {
                Form {
                    DarkbloomBrandHeader()
                    if mode.connected {
                        network
                        if !mode.changes.isEmpty { changes }
                        model
                        monitor
                        if let endpoint = mode.snapshot?.endpoint { connection(endpoint) }
                        details
                    } else {
                        setup
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: embedded ? nil : 500, minHeight: embedded ? nil : 520)
        .onAppear {
            if embedded { mode.open() }
        }
        .onDisappear {
            flashTask?.cancel()
            if embedded { mode.close() }
        }
        .confirmationDialog("Change how Darkbloom serves?", isPresented: $confirmingStart) {
            Button(pendingMode == nil ? "Switch Model" : "Apply") {
                if let target = pendingMode {
                    mode.setServingMode(target)
                } else {
                    mode.start()
                }
                pendingMode = nil
            }
        } message: {
            Text(confirmed.map(\.start).joined(separator: " "))
        }
        .confirmationDialog(
            "Cancel the download?",
            isPresented: Binding(get: { cancellingOp != nil }, set: { if !$0 { cancellingOp = nil } }),
            presenting: cancellingOp
        ) { opID in
            Button("Cancel Download", role: .destructive) { mode.cancelDownload(opID) }
            Button("Keep Downloading", role: .cancel) {}
        } message: { _ in
            Text("Darkbloom stops downloading the model.")
        }
        .confirmationDialog(
            "Remove \(removingModel?.displayName ?? "the model")?",
            isPresented: Binding(get: { removingModel != nil }, set: { if !$0 { removingModel = nil } }),
            presenting: removingModel
        ) { target in
            Button("Remove Model", role: .destructive) { mode.removeModel(target.id) }
        } message: { _ in
            Text("Darkbloom deletes it from this Mac. Serving it again means downloading it again.")
        }
    }

    private func pulseDownloadButton() {
        flashTask?.cancel()
        flashTask = Task {
            for _ in 0..<2 {
                flashDownload = true
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                flashDownload = false
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
            }
        }
    }

    // MARK: Setup

    private var setup: some View {
        Section {
            LabeledContent {
                switch mode.state {
                case .notSetUp:
                    HStack(spacing: 8) {
                        Text("From darkbloom.dev")
                            .foregroundStyle(.secondary)
                        Button("Install") { mode.install() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                case .needsUpdate(let version):
                    HStack(spacing: 8) {
                        Label("Update needed (\(version))", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .tip("Darkbloom \(version) is installed; Cloak requires 0.10.16 or later.")
                        Button("Update") { mode.install(updating: true) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                case .installing(let step):
                    HStack(spacing: 8) {
                        ProgressView(value: Double(step), total: 5)
                            .frame(width: 110)
                            .accessibilityLabel(mode.installingUpdate ? "Updating" : "Installing")
                            .accessibilityValue("Step \(step) of 5")
                        Text(step == 0 ? "Starting…" : "Step \(step)/5")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                case .notConnected:
                    HStack(spacing: 6) {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        InfoButton("About Connect", hint: Self.connectBullets.joined(separator: " ")) {
                            BulletNote(bullets: Self.connectBullets)
                        }
                        Button("Connect") { mode.connect() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
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
                    InfoButton("About Runtime", hint: Self.runtimeBullets.joined(separator: " ")) {
                        BulletNote("Darkbloom Runtime", bullets: Self.runtimeBullets)
                    }
                }
            }
        } header: {
            Text("Setup")
        }
    }

    private static let runtimeBullets = [
        "Runs Darkbloom's installer script from api.darkbloom.dev into ~/.darkbloom, then verifies the installed binary is signed by developer team SLDQ2GJ6TL before Cloak talks to it.",
        "Starts Darkbloom's local control service, but serves nothing until you choose Local Only or Network + Local.",
        "Closing this window cancels an install or update in progress.",
    ]

    private static let connectBullets = [
        "Starts Darkbloom's local control service on this Mac.",
        "Nothing is served until you choose Local Only or Network + Local.",
    ]

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
                    note: "How Darkbloom serves on this Mac now, set outside Cloak. Cloak changes nothing until you switch Serving Mode below, which serves the model with your requests kept on this Mac and its address open to this Mac only.")
            }
        }
    }

    // MARK: Model

    private var model: some View {
        let fitting = mode.eligibleModels
        let selectedID = mode.recommended?.id
        let topPreview: [DarkbloomSnapshot.Model] = {
            guard !showAllModels, fitting.count > 3 else { return fitting }
            var shown = Array(fitting.prefix(3))
            // Keep the selected model and any already-downloaded eligible model visible.
            for candidate in fitting where candidate.id == selectedID || candidate.downloaded || mode.isModelServing(candidate) {
                if !shown.contains(where: { $0.id == candidate.id }) {
                    shown.append(candidate)
                }
            }
            return shown
        }()
        let hiddenCount = max(0, fitting.count - topPreview.count)

        return Section {
            if fitting.isEmpty {
                Text(noModel)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topPreview) { entry in
                    let isSelected = entry.id == selectedID
                    let isTopEarner = mode.pricing != nil && fitting.count > 1 && entry.id == mode.topEarnerID
                    modelRow(entry, isSelected: isSelected, isTopEarner: isTopEarner)
                }
                if hiddenCount > 0 || showAllModels && fitting.count > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showAllModels.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showAllModels ? 90 : 0))
                                .frame(width: 12)
                                .accessibilityHidden(true)
                            Text(
                                showAllModels
                                    ? "Show fewer models"
                                    : "Show \(hiddenCount) more fitting \(hiddenCount == 1 ? "model" : "models")"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                    .accessibilityValue(showAllModels ? "Expanded" : "Collapsed")
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("Model")
                InfoButton("About Model", note: modelNote)
                Spacer(minLength: 0)
                if mode.pricing != nil, fitting.count > 1 {
                    Text("Ranked by payout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: DarkbloomSnapshot.Model, isSelected: Bool, isTopEarner: Bool) -> some View {
        let price = mode.price(for: entry)
        let tipText = modelTooltip(entry, price: price)
        LabeledContent {
            modelAction(entry, isSelected: isSelected)
        } label: {
            Button {
                mode.selectModel(entry.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.displayName)
                                .fontWeight(isSelected ? .medium : .regular)
                                .lineLimit(1)
                            if mode.isModelServing(entry) {
                                Text("Serving")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            } else if isTopEarner {
                                Text("Top Earner")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(modelSubtitle(entry, price: price))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .tip(tipText)
    }

    private func modelSubtitle(_ entry: DarkbloomSnapshot.Model, price: DarkbloomPricing.Price?) -> String {
        var parts: [String] = []
        if let size = entry.sizeGb {
            parts.append("\(size.formatted(.number.precision(.fractionLength(1)))) GB")
        }
        if let price {
            parts.append(price.compactRate)
        }
        return parts.joined(separator: " · ")
    }

    private func modelTooltip(_ entry: DarkbloomSnapshot.Model, price: DarkbloomPricing.Price?) -> String {
        var parts: [String] = []
        if let price {
            parts.append("Darkbloom payout rate: \(price.compactRate) tokens (in | out, 0% platform cut).")
        }
        if let desc = entry.description, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func modelAction(_ model: DarkbloomSnapshot.Model, isSelected: Bool) -> some View {
        if let op = mode.activeDownload(for: model.id) {
            HStack(spacing: 6) {
                Group {
                    if let progress = op.progress {
                        ProgressView(value: progress)
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    } else {
                        ProgressView(value: nil as Double?)
                    }
                }
                .frame(width: 90)
                .accessibilityLabel("Download")
                if let progress = op.progress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }
                if op.cancellable {
                    SymbolButton("Cancel Download", symbol: "xmark.circle") { cancellingOp = op.id }
                        .overhanging()
                }
            }
        } else if model.downloaded {
            if isSelected, mode.isOn, !mode.isModelServing(model) {
                Button("Switch") {
                    pendingMode = nil
                    if mode.changes.isEmpty { mode.start() } else { confirmingStart = true }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .tip("Downloaded")
                    .accessibilityLabel("Downloaded")
            }
        } else if isSelected {
            let emphasized = hoveringDownloadPrompt || flashDownload
            Button {
                mode.downloadModel(model.id)
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .scaleEffect(flashDownload ? 1.08 : (hoveringDownloadPrompt ? 1.03 : 1.0))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: emphasized ? 2.5 : 0)
                    .padding(-3)
                    .opacity(emphasized ? 1 : 0)
            )
            .shadow(
                color: Color.accentColor.opacity(flashDownload ? 0.85 : (hoveringDownloadPrompt ? 0.45 : 0)),
                radius: flashDownload ? 10 : 6
            )
            .animation(.easeInOut(duration: 0.18), value: flashDownload)
            .animation(.easeInOut(duration: 0.18), value: hoveringDownloadPrompt)
        } else {
            Button("Download") { mode.downloadModel(model.id) }
                .controlSize(.small)
        }
    }

    private var noModel: String {
        if mode.snapshot?.catalogError != nil { return "Darkbloom's model list is unavailable." }
        if mode.room == nil { return "Darkbloom doesn't say what fits." }
        return "No model fits beside Cloak."
    }

    private var modelNote: String {
        let room = mode.snapshot?.memory.pinBudgetGb.map {
            " (\($0.formatted(.number.precision(.fractionLength(0)))) GB Darkbloom budget)"
        } ?? ""
        return "Darkbloom models that fit beside Cloak, which reserves \(Memory.text(mode.cloakMemory))\(room). Ranked highest payout first using Darkbloom's live token pricing (0% platform cut)."
    }

    // MARK: Serving Status

    @ViewBuilder
    private var status: some View {
        switch mode.state {
        case .serving:
            let label = switch mode.setup.job?.mode {
            case .onlyMe: "Serving (Local Only)"
            case .both: "Serving Network + Local"
            case .network: "Serving Network"
            case nil: "Serving"
            }
            Label(label, systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .loading:
            Working(words: "Loading")
        case .stopping:
            Working(words: "Stopping")
        case .stopped:
            Label("Stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .noModel:
            Label("Download a model to start", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            Working(
                words: progress.map { "Downloading (\($0.formatted(.percent.precision(.fractionLength(0)))))" }
                    ?? "Downloading")
        case .failed(let failure):
            Failure(failure: failure)
        case .unsupported, .looking, .notSetUp, .needsUpdate, .installing, .notConnected, .connecting:
            Working(words: "Connecting")
        }
    }

    // MARK: Live Monitor (Decision N5.2)

    @ViewBuilder
    private var monitor: some View {
        if let snapshot = mode.snapshot {
            let loadedModels = snapshot.models.filter(\.loaded)
            let routableCount = snapshot.models.filter { $0.registration == "routable" }.count
            let memoryUsed = loadedModels.compactMap(\.memoryGb).reduce(0, +)
            let live = snapshot.liveMetrics
            Section("Live Monitor") {
                LabeledContent("Provider Health") {
                    if snapshot.state == "running" {
                        if mode.setup.job?.mode == .onlyMe {
                            Label("Local Only · Healthy", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if routableCount > 0 {
                            Label("Routable (\(routableCount) model\(routableCount == 1 ? "" : "s"))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if snapshot.providerStatus == "untrusted" {
                            Label("Awaiting Verification", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        } else {
                            Text(snapshot.providerStatus?.capitalized ?? "Joining Network")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(snapshot.state.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
                if let budget = snapshot.memory.pinBudgetGb {
                    LabeledContent("Model Memory") {
                        if snapshot.state == "running", memoryUsed == 0 {
                            Text("0.0 / \(budget, format: .number.precision(.fractionLength(1))) GB · loads on demand")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(memoryUsed, format: .number.precision(.fractionLength(1))) / \(budget, format: .number.precision(.fractionLength(1))) GB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let tps = live?.resolvedTPS {
                    LabeledContent("Throughput") {
                        Text("\(tps, format: .number.precision(.fractionLength(1))) tok/s")
                            .monospacedDigit()
                    }
                }
                if let served = live?.resolvedRequests ?? snapshot.activity?.resolvedRequests {
                    LabeledContent("Served Requests") {
                        if let active = live?.resolvedActive, active > 0 {
                            Text("\(served.formatted()) (\(active) active)")
                                .monospacedDigit()
                        } else {
                            Text(served.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let tokens = snapshot.activity?.resolvedTokens, tokens > 0 {
                    LabeledContent("Output Tokens") {
                        Text(tokens.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let uptime = live?.uptimeSeconds {
                    LabeledContent("Daemon Uptime") {
                        Text(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if let startedAt = snapshot.activity?.startedAt, startedAt > 0, snapshot.state == "running" {
                    let startDate = Date(timeIntervalSince1970: startedAt)
                    LabeledContent("Daemon Uptime") {
                        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if let since = mode.connectedSince {
                    LabeledContent("Stream Connected") {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let beat = mode.lastHeartbeat {
                    TimelineView(.periodic(from: beat, by: 5)) { context in
                        let age = max(0, Int(context.date.timeIntervalSince(beat)))
                        LabeledContent("Last Heartbeat") {
                            Text(age < 5 ? "Just now" : "\(age)s ago")
                                .monospacedDigit()
                                .foregroundStyle(age > 15 ? .orange : .secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Local API (For Other Apps)

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
                    InfoButton("About Requests", hint: reachBullets.joined(separator: " ")) {
                        BulletNote("Local Request Routing", bullets: reachBullets)
                    }
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("Local API (For Other Apps)")
                InfoButton("About Local API", hint: Self.localAPIBullets.joined(separator: " ")) {
                    BulletNote("Local OpenAI-Compatible API", bullets: Self.localAPIBullets)
                }
            }
        } footer: {
            Text("Point local apps, scripts, or coding agents (OpenCode, Hermes, Cursor) to this address and key to query the MLX model running on this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    private static let localAPIBullets = [
        "OpenAI-compatible API served locally on this Mac by Darkbloom.",
        "Use this address and key in external apps or coding agents (OpenCode, Hermes, Cursor, custom scripts).",
        "Cloak's own Local Mode uses its built-in engine directly and does not need these credentials.",
    ]

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
            CopyButton("Copy Key", side: 28) { await mode.key() }
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

    private var reachBullets: [String] {
        let route = switch mode.setup.route {
        case "this-mac": "this Mac only"
        case "my-macs": "your other Macs when this one is busy"
        case "my-macs-first": "your other Macs, then Darkbloom's network, when this one is busy"
        case let other?: other
        case nil: "unknown"
        }
        let listens = mode.setup.listens ?? "unknown"
        return [
            "Route: \(route).",
            "Listens on: \(listens).",
            "Changing routes in another Darkbloom app or via darkbloom route in Terminal updates this view automatically.",
            "Darkbloom still uses the network to download models and updates.",
        ]
    }

    // MARK: Serving Mode (Unified 3-Way Master Control)

    private var servingModeSubtitle: String {
        switch mode.servingMode {
        case .off:
            "Darkbloom is stopped. Pick Local Only for apps on this Mac, or Network + Local to earn payouts while idle."
        case .localOnly:
            "Serving local apps on this Mac only (not earning). Switch to Network + Local to earn payouts while idle."
        case .network:
            "Earning payouts on Darkbloom's network while your Mac is idle (pauses when you use it) and prioritizing your local apps."
        }
    }

    private var network: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Serving Mode")
                            .font(.headline)
                        InfoButton("About Serving Mode", hint: Self.networkBullets.joined(separator: " ")) {
                            BulletNote("Darkbloom Serving Modes", bullets: Self.networkBullets)
                        }
                    }
                    Spacer(minLength: 8)
                    ServingModeControl(
                        selection: mode.servingMode,
                        canServeNetwork: mode.canAlsoServe,
                        disabled: mode.state == .stopping,
                        onSelect: selectServingMode
                    )
                }
                Text(servingModeSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            LabeledContent("Status") {
                VStack(alignment: .trailing, spacing: 2) {
                    status
                    if mode.lastChangeFromCLI {
                        Text("Updated from `darkbloom` CLI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if mode.needsModelNotice {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Download a model below first to start serving.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let target = mode.recommended {
                        Button("Download \(target.displayName)") {
                            mode.downloadModel(target.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            if let snapshot = mode.snapshot {
                if let link = mode.linking {
                    LabeledContent("Sign-in Code") {
                        Text(link.code)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Continue in Browser") { mode.continueInBrowser() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                LabeledContent {
                    if let identity = snapshot.account?.identity {
                        VStack(alignment: .trailing, spacing: 1) {
                            Label(identity, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let provider = snapshot.providerName, provider != identity {
                                Text("Provider: \(provider)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if snapshot.linked {
                        VStack(alignment: .trailing, spacing: 1) {
                            Label(snapshot.providerName ?? "Linked", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("CLI token linked · view email in Console")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if snapshot.operations.contains(where: { $0.state == "running" && $0.action == "link" }) {
                        Working(words: "Linking")
                    } else {
                        Text("Not linked")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Earning As")
                }
                if mode.alsoServe, snapshot.linked {
                    LabeledContent("Network") {
                        networkStatus(snapshot)
                    }
                }
            }

            LabeledContent {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://console.darkbloom.dev/")!)
                } label: {
                    Label("Dashboard & Payouts", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earnings & Payouts")
                    Text("Accrue to your linked console.darkbloom.dev account — safe even if Cloak is uninstalled or reinstalled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Switches Darkbloom between Off, Local Only (`--local`), and Network + Local
    /// (`--me-first`), prompting to download a model first if none is installed.
    private func selectServingMode(_ target: DarkbloomMode.ServingMode) {
        guard target != mode.servingMode else { return }
        if target != .off, mode.recommended?.downloaded != true {
            mode.setServingMode(target)
            pulseDownloadButton()
            return
        }
        if target == .off {
            mode.setServingMode(.off)
            return
        }
        pendingMode = target
        if mode.isOn, !confirmed.isEmpty { confirmingStart = true } else {
            pendingMode = nil
            mode.setServingMode(target)
        }
    }

    /// What the confirmation names: everything Start changes, or for a mode
    /// switch, everything except the network-serving change the user chose.
    private var confirmed: [DarkbloomMode.Change] {
        pendingMode == nil ? mode.changes : mode.changes.filter { $0 != .network }
    }

    @ViewBuilder
    private func networkStatus(_ snapshot: DarkbloomSnapshot) -> some View {
        if snapshot.state != "running" || mode.setup.job?.mode == .onlyMe {
            Text("Off")
                .foregroundStyle(.secondary)
        } else if snapshot.providerStatus == "untrusted" {
            Label("Verification needed", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .tip("Darkbloom hasn't verified this Mac yet.")
        } else if snapshot.providerStatus == "offline" {
            Working(words: "Connecting")
        } else if snapshot.models.contains(where: { $0.registration == "routable" }) {
            Label("Serving requests", systemImage: "circle.fill")
                .foregroundStyle(.green)
        } else {
            Working(words: "Joining")
        }
    }

    private static let networkBullets = [
        "Your local requests stay on this Mac and always take priority.",
        "Network serving pauses while you use this Mac and resumes when idle.",
        "Requires a one-time browser sign-in — Cloak never sees your password or account key.",
        "Earnings accrue to your linked Darkbloom account and are managed on console.darkbloom.dev.",
    ]

    // MARK: Details & CLI Tools

    private static let cliCommands: [(cmd: String, note: String)] = [
        ("darkbloom doctor", "Run hardware, RAM, port & coordinator diagnostics"),
        ("darkbloom status", "Show daemon state, active model, and request counts"),
        ("darkbloom logs", "Stream provider logs from macOS unified logging"),
        ("darkbloom login", "Link or switch the Darkbloom account on this Mac"),
        ("darkbloom schedule", "Configure weekly serving hours & model preloading"),
        ("darkbloom idle", "Choose when idle models unload from memory"),
        ("darkbloom benchmark", "Run standardized local MLX speed benchmarks"),
        ("darkbloom --opencode", "Connect OpenCode directly to local Darkbloom"),
        ("darkbloom --hermes", "Connect Hermes Agent directly to local Darkbloom"),
        ("darkbloom cluster", "Link two Apple Silicon Macs to serve one model"),
    ]

    private var details: some View {
        let downloadedModels = mode.eligibleModels.filter(\.downloaded)
        return Section {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { more.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(more ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text("CLI & Troubleshooting")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
            .accessibilityValue(more ? "Expanded" : "Collapsed")

            if more {
                LabeledContent("Quick Diagnostics") {
                    HStack(spacing: 8) {
                        if mode.runningDiagnostic {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Run Doctor") { mode.runDiagnostic("doctor") }
                            .controlSize(.small)
                            .disabled(mode.runningDiagnostic)
                        Button("Run Status") { mode.runDiagnostic("status") }
                            .controlSize(.small)
                            .disabled(mode.runningDiagnostic)
                    }
                }

                if let output = mode.diagnosticOutput {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(mode.diagnosticTitle ?? "Output")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            CopyButton(text: output)
                            Button("Clear") { mode.clearDiagnostic() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            Text(output)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Useful CLI Commands (Terminal)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Self.cliCommands, id: \.cmd) { item in
                        HStack(spacing: 8) {
                            Text(item.cmd)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(item.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            CopyButton(text: item.cmd)
                        }
                    }
                }
                .padding(.vertical, 2)

                ForEach(downloadedModels) { entry in
                    let inUse = mode.isModelServing(entry) || entry.loaded
                    LabeledContent(entry.displayName) {
                        HStack {
                            if inUse {
                                Text("Turn Off first")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            SymbolButton("Remove Model", symbol: "trash") { removingModel = entry }
                                .overhanging()
                                .disabled(inUse)
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
                            note: "Darkbloom serves from its own service, which launchd runs, not Cloak, so quitting Cloak doesn't stop it. Switching Serving Mode to Off does.")
                    }
                }
                LabeledContent {
                    Text(mode.setup.job.map { $0.loaded && $0.runsAtLoad } == true ? "Starts" : "Off")
                } label: {
                    HStack(spacing: 2) {
                        Text("At Login")
                        InfoButton(
                            "About At Login",
                            note: "While Darkbloom is set to serve, its service starts at login; switching Serving Mode to Off turns that off too. Cloak adds no login item of its own.")
                    }
                }
                LabeledContent("Version", value: mode.version ?? "Unknown")
            }
        } footer: {
            Text("Cloak drives the same ~/.darkbloom service as the darkbloom CLI — schedules, idle timeouts, autopilot, fan control, and cluster setups configured in Terminal stay intact and sync here automatically.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Custom 3-way segmented control (`Off` | `Local Only` | `Network + Local`)
/// with distinct color weight and a subtle breathing green glow when earning
/// on Darkbloom's network.
private struct ServingModeControl: View {
    let selection: DarkbloomMode.ServingMode
    let canServeNetwork: Bool
    let disabled: Bool
    let onSelect: (DarkbloomMode.ServingMode) -> Void

    @Namespace private var thumbSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowHigh = false

    private var activeFill: Color {
        switch selection {
        case .off: Color.primary.opacity(0.16)
        case .localOnly: Color.green.opacity(0.18)
        case .network: Color.green.opacity(0.86)
        }
    }

    private var activeStroke: Color {
        switch selection {
        case .off: Color.primary.opacity(0.20)
        case .localOnly: Color.green.opacity(0.32)
        case .network: Color.green
        }
    }

    private var containerStroke: Color {
        switch selection {
        case .off: Color.primary.opacity(0.12)
        case .localOnly: Color.green.opacity(0.22)
        case .network: Color.green.opacity(glowHigh ? 0.55 : 0.32)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DarkbloomMode.ServingMode.allCases) { option in
                let isSelected = option == selection
                let optionDisabled = disabled || (option == .network && !canServeNetwork)
                Button {
                    guard !optionDisabled else { return }
                    onSelect(option)
                } label: {
                    HStack(spacing: 5) {
                        if option == .network, isSelected {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 6, height: 6)
                                .opacity(glowHigh ? 1.0 : 0.65)
                        }
                        Text(option.label)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(labelColor(for: option, selected: isSelected, disabled: optionDisabled))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(activeFill)
                                .overlay(Capsule().strokeBorder(activeStroke, lineWidth: 1))
                                .shadow(
                                    color: selection == .network ? Color.green.opacity(glowHigh ? 0.55 : 0.22) : .clear,
                                    radius: selection == .network ? (glowHigh ? 9 : 4) : 0
                                )
                                .matchedGeometryEffect(id: "servingModeThumb", in: thumbSpace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(optionDisabled)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(containerStroke, lineWidth: 1))
        .shadow(
            color: selection == .network ? Color.green.opacity(glowHigh ? 0.28 : 0.10) : .clear,
            radius: selection == .network ? (glowHigh ? 12 : 5) : 0
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
        .onAppear { syncGlow() }
        .onChange(of: selection) { _, _ in syncGlow() }
        .onChange(of: reduceMotion) { _, _ in syncGlow() }
    }

    private func labelColor(for option: DarkbloomMode.ServingMode, selected: Bool, disabled: Bool) -> Color {
        if disabled { return .secondary.opacity(0.45) }
        guard selected else { return .secondary }
        switch option {
        case .off: return .primary.opacity(0.82)
        case .localOnly: return .primary.opacity(0.90)
        case .network: return .white
        }
    }

    private func syncGlow() {
        guard selection == .network, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { glowHigh = false }
            return
        }
        glowHigh = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            glowHigh = true
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
