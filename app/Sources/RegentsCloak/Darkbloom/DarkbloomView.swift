// Compiled only when DARKBLOOM is defined (see app/build.sh).
#if DARKBLOOM
import AppKit
import CloakControl
import CloakDarkbloom
import CloakSupervisor
import SwiftUI

/// Thin container for Inference Serving: routes between Setup and the
/// isolated connected sections so 2s SSE heartbeats never invalidate
/// unrelated controls or model rows.
struct DarkbloomView: View {
    static func window(_ mode: DarkbloomMode) -> NSWindow {
        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Inference Serving"
        window.contentViewController = NSHostingController(rootView: DarkbloomView(mode: mode))
        window.setFrameAutosaveName("sh.regents.cloak.window.serving")
        return window
    }

    let mode: DarkbloomMode
    @Bindable var settings: AppSettings = .standard
    var embedded = false
    @State private var confirmingStart = false
    /// Target serving mode waiting on the existing-setup confirmation dialog;
    /// nil when confirming a model switch.
    @State private var pendingMode: DarkbloomMode.ServingMode?
    @State private var cancellingOp: String?
    @State private var removingModel: DarkbloomSnapshot.Model?
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
                    if Places.isDev {
                        Section {
                            Label(
                                "Cloak Dev shares your Mac's live Darkbloom service (~/.darkbloom). Starting, stopping, or switching models here affects the live daemon.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.callout)
                            .foregroundStyle(.orange)
                        }
                    }
                    DarkbloomBrandHeader()
                    if mode.connected {
                        DarkbloomServingSection(
                            mode: mode,
                            onSelectMode: selectServingMode
                        )
                        if !mode.changes.isEmpty {
                            DarkbloomCurrentSetupSection(changes: mode.changes)
                        }
                        DarkbloomModelsSection(
                            mode: mode,
                            flashDownload: flashDownload,
                            onRequestSwitch: requestModelSwitch,
                            onRequestCancelDownload: { cancellingOp = $0 }
                        )
                        DarkbloomMonitorSection(mode: mode)
                        DarkbloomQoSSection(settings: settings, mode: mode)
                        if let endpoint = mode.snapshot?.endpoint {
                            DarkbloomLocalAPISection(mode: mode, endpoint: endpoint)
                        }
                        DarkbloomDetailsSection(
                            mode: mode,
                            onRequestRemoveModel: { removingModel = $0 }
                        )
                    } else {
                        DarkbloomSetupSection(mode: mode)
                    }
                    DarkbloomNetworksSection()
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: embedded ? nil : 500, minHeight: embedded ? nil : 520)
        .textSelection(.enabled)
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

    private func requestModelSwitch() {
        pendingMode = nil
        if mode.changes.isEmpty { mode.start() } else { confirmingStart = true }
    }

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

    private var confirmed: [DarkbloomMode.Change] {
        pendingMode == nil ? mode.changes : mode.changes.filter { $0 != .network }
    }
}

private struct DarkbloomSetupSection: View {
    let mode: DarkbloomMode

    private static let runtimeBullets = [
        "Runs Darkbloom's installer script from api.darkbloom.dev into ~/.darkbloom, then verifies the installed binary is signed by developer team SLDQ2GJ6TL before Cloak talks to it.",
        "Starts Darkbloom's local control service, but serves nothing until you choose Local Only or Network + Local.",
        "Closing this window cancels an install or update in progress.",
    ]

    private static let connectBullets = [
        "Starts Darkbloom's local control service on this Mac.",
        "Nothing is served until you choose Local Only or Network + Local.",
    ]

    var body: some View {
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
                        DarkbloomFailureBadge(failure: failure)
                        SymbolButton("Try Again", symbol: "arrow.clockwise") { mode.open() }
                            .overhanging()
                    }
                default:
                    DarkbloomWorking(words: "Checking")
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
}

struct DarkbloomWorking: View {
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

struct DarkbloomFailureBadge: View {
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

/// Smart Mac QoS guardrails (battery, thermal pressure, quiet hours) for network serving.
private struct DarkbloomQoSSection: View {
    @Bindable var settings: AppSettings
    let mode: DarkbloomMode

    var body: some View {
        Section {
            Toggle("Pause on battery power", isOn: $settings.servingPauseOnBattery)
                .onChange(of: settings.servingPauseOnBattery) { _, _ in mode.evaluateQoS() }
            Toggle("Pause if Mac runs hot", isOn: $settings.servingPauseOnHighThermal)
                .onChange(of: settings.servingPauseOnHighThermal) { _, _ in mode.evaluateQoS() }
            Toggle("Quiet hours schedule", isOn: $settings.servingQuietHoursEnabled)
                .onChange(of: settings.servingQuietHoursEnabled) { _, _ in mode.evaluateQoS() }
            if settings.servingQuietHoursEnabled {
                LabeledContent("Pause window") {
                    HStack(spacing: 6) {
                        Picker("Start", selection: $settings.servingQuietStartHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(Self.formatHour(hour)).tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 88)
                        .onChange(of: settings.servingQuietStartHour) { _, _ in mode.evaluateQoS() }
                        Text("to")
                            .foregroundStyle(.secondary)
                        Picker("End", selection: $settings.servingQuietEndHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(Self.formatHour(hour)).tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 88)
                        .onChange(of: settings.servingQuietEndHour) { _, _ in mode.evaluateQoS() }
                    }
                }
            }
        } header: {
            Text("Mac Guardrails")
        } footer: {
            Text("Cloak automatically pauses network serving when a guardrail triggers and resumes once your Mac is plugged in, cool, and outside quiet hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func formatHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let suffix = normalized >= 12 ? "PM" : "AM"
        let display = normalized % 12 == 0 ? 12 : normalized % 12
        return "\(display):00 \(suffix)"
    }
}

/// Pluggable Serving Network catalog preparing Cloak for multi-network serving selection.
private struct DarkbloomNetworksSection: View {
    var body: some View {
        Section {
            ForEach(ServingNetworkDescriptor.catalog) { network in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(network.name)
                            .fontWeight(.medium)
                        Text(network.status.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(network.status == .active ? .green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    network.status == .active ? Color.green.opacity(0.14) : Color.primary.opacity(0.07))
                            )
                        Spacer(minLength: 0)
                        Text(network.settlement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(network.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Serving Networks")
        }
    }
}
#endif
