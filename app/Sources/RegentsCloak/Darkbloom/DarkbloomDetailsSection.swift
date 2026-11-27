#if DARKBLOOM
import CloakDarkbloom
import SwiftUI

/// Local OpenAI-compatible API endpoint details and on-demand key reveal.
struct DarkbloomLocalAPISection: View {
    let mode: DarkbloomMode
    let endpoint: DarkbloomSnapshot.Endpoint

    private static let localAPIBullets = [
        "OpenAI-compatible API served locally on this Mac by Darkbloom.",
        "Use this address and key in external apps or coding agents (OpenCode, Hermes, Cursor, custom scripts).",
        "Cloak's own Local Mode uses its built-in engine directly and does not need these credentials.",
    ]

    var body: some View {
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
}

/// Collapsible CLI tools, inline doctor/status diagnostics, downloaded model
/// removal, and launchd persistence metadata.
struct DarkbloomDetailsSection: View {
    let mode: DarkbloomMode
    let onRequestRemoveModel: (DarkbloomSnapshot.Model) -> Void

    @State private var more = false

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

    var body: some View {
        let downloadedModels = mode.eligibleModels.filter(\.downloaded)
        Section {
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
                            SymbolButton("Remove Model", symbol: "trash") { onRequestRemoveModel(entry) }
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
#endif
