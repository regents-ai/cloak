#if DARKBLOOM
import AppKit
import CloakDarkbloom
import SwiftUI

/// Serving mode master control, account linking, live payout balance,
/// settled earnings, and external setup warnings.
struct DarkbloomServingSection: View {
    let mode: DarkbloomMode
    let onSelectMode: (DarkbloomMode.ServingMode) -> Void

    private static let networkBullets = [
        "Your local requests stay on this Mac and always take priority.",
        "Network serving pauses while you use this Mac and resumes when idle.",
        "Requires a one-time browser sign-in — Cloak never sees your password or account key.",
        "Earnings accrue to your linked Darkbloom account and are managed on console.darkbloom.dev.",
    ]

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

    var body: some View {
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
                        onSelect: onSelectMode
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
                    } else if snapshot.operations.contains(where: {
                        $0.state == "running" && ($0.action == "link" || $0.action == "account-signin")
                    }) {
                        DarkbloomWorking(words: "Signing in")
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

            if let earnings = mode.cloudEarnings, earnings.linked {
                if let balance = earnings.balanceMicroUsd {
                    LabeledContent("Payout Balance") {
                        HStack(spacing: 8) {
                            Text(DarkbloomCloudEarnings.formatMicroUSD(balance))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.green)
                                .monospacedDigit()
                            SymbolButton("Refresh Earnings", symbol: "arrow.clockwise") {
                                mode.refreshEarnings(force: true)
                            }
                            .overhanging()
                        }
                    }
                }
                if let lifetime = earnings.lifetimeMicroUsd {
                    LabeledContent("Settled Earnings") {
                        VStack(alignment: .trailing, spacing: 1) {
                            let jobs = earnings.settledRecords.map { " · \($0.formatted()) jobs" } ?? ""
                            Text("\(DarkbloomCloudEarnings.formatMicroUSD(lifetime)) lifetime\(jobs)")
                                .font(.callout)
                                .monospacedDigit()
                            if let week = earnings.weekMicroUsd {
                                Text("\(DarkbloomCloudEarnings.formatMicroUSD(week)) last 7d")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } else if let err = mode.cloudEarningsError, mode.snapshot?.linked == true {
                LabeledContent("Account Earnings") {
                    HStack(spacing: 8) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        Button("Sign In") { mode.signInAccount() }
                            .controlSize(.small)
                    }
                }
            }

            LabeledContent {
                HStack(spacing: 8) {
                    if mode.snapshot?.linked == true, mode.snapshot?.account?.signedIn == false, mode.linking == nil {
                        Button("Sign In") { mode.signInAccount() }
                            .controlSize(.small)
                            .tip("Sign into your Darkbloom dashboard account to keep email and earnings synced.")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://console.darkbloom.dev/")!)
                    } label: {
                        Label("Dashboard & Payouts", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }
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
            DarkbloomWorking(words: "Loading")
        case .stopping:
            DarkbloomWorking(words: "Stopping")
        case .stopped:
            Label("Stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .noModel:
            Label("Download a model to start", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            DarkbloomWorking(
                words: progress.map { "Downloading (\($0.formatted(.percent.precision(.fractionLength(0)))))" }
                    ?? "Downloading")
        case .failed(let failure):
            DarkbloomFailureBadge(failure: failure)
        case .unsupported, .looking, .notSetUp, .needsUpdate, .installing, .notConnected, .connecting:
            DarkbloomWorking(words: "Connecting")
        }
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
            DarkbloomWorking(words: "Connecting")
        } else if let status = snapshot.providerStatus, !status.isEmpty, status != "online", status != "trusted" {
            Label(status.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .tip("Darkbloom reported provider status '\(status)'. Run darkbloom doctor in Details if serving is held.")
        } else if snapshot.models.contains(where: { $0.registration == "routable" }) {
            Label("Serving requests", systemImage: "circle.fill")
                .foregroundStyle(.green)
        } else {
            DarkbloomWorking(words: "Joining")
        }
    }
}

struct DarkbloomCurrentSetupSection: View {
    let changes: [DarkbloomMode.Change]

    var body: some View {
        Section {
            ForEach(changes, id: \.self) { change in
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
#endif
