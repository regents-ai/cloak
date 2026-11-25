import CloakSupervisor
import SwiftUI

/// Hardware-aware 3-step Welcome Tour shown once on first launch and
/// replayable anytime from the menu bar ("Take a Tour…") or Chat's onboarding
/// card. Tailors its recommendations to this Mac's memory (16 GB+ Apple Silicon
/// vs. 8 GB / unsupported Macs) and surfaces Cloak's key privacy features
/// without nagging tooltips.
struct TourView: View {
    let chat: Chat
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void
    let showAdvancedSettings: () -> Void
    let showConnectedApps: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int

    init(
        chat: Chat,
        initialStep: Int = 0,
        showNearSettings: @escaping () -> Void,
        showLlamaSettings: @escaping () -> Void,
        showAdvancedSettings: @escaping () -> Void,
        showConnectedApps: @escaping () -> Void
    ) {
        self.chat = chat
        self.showNearSettings = showNearSettings
        self.showLlamaSettings = showLlamaSettings
        self.showAdvancedSettings = showAdvancedSettings
        self.showConnectedApps = showConnectedApps
        _step = State(initialValue: min(max(initialStep, 0), 2))
    }

    private let totalSteps = 3
    private static let agentDocsURL = URL(string: "https://regents.sh/cloak#agent")!

    private var localFits: Bool {
        chat.recommendedLocalDownload.fits
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: whyCloakStep
                case 1: choosePathStep
                default: superpowersStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()

            HStack {
                Button("Skip") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Button {
                            step = index
                        } label: {
                            Circle()
                                .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.32))
                                .frame(width: 7, height: 7)
                                .frame(width: 20, height: 20)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .hover(Circle())
                        .accessibilityLabel("Step \(index + 1) of \(totalSteps)")
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                if step < totalSteps - 1 {
                    Button("Next") { step += 1 }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Chatting") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 500)
    }

    // MARK: Step 1 — What Cloak Does Differently

    private var whyCloakStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Cloak")
                    .font(.title2.weight(.semibold))
                Text("Private AI for macOS. Zero accounts. Zero telemetry.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ComparisonRow(
                    symbol: "laptopcomputer",
                    tint: .green,
                    title: "Cloak Local (16 GB+ Macs)",
                    summary: "Runs completely offline on your Mac. Free, fast, no account, no crypto."
                )
                ComparisonRow(
                    symbol: "lock.shield",
                    tint: .accentColor,
                    title: "Private & Anonymous Cloud",
                    summary: "Strips writing style locally, routes over Tor, and pays via hardware enclaves or unlinkable crypto."
                )
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 26)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloak **does not** support normal cloud AI inference.")
                        .font(.system(size: 13.5, weight: .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Standard cloud AI ties your identity, IP address, and writing style to every prompt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
            .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    // MARK: Step 2 — Choose Your Starting Path (Hardware-Aware)

    private var choosePathStep: some View {
        let download = chat.recommendedLocalDownload
        let size = DownloadSection.text(download.total)
        let installed = download.state == .installed

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose how to start")
                    .font(.title2.weight(.semibold))
                Text(
                    localFits
                        ? "Switch modes anytime in Chat."
                        : "Local models need 16 GB+ Apple Silicon. NEAR AI Gateway works right away on this Mac."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if localFits {
                    PathCard(
                        symbol: "laptopcomputer",
                        title: "Local",
                        badge: installed ? "Ready" : download.isUnderWay ? "Downloading" : "Free · Offline",
                        badgeTint: .green,
                        detail: installed
                            ? "\(download.model.label) is ready for offline chat."
                            : download.isUnderWay
                                ? "Downloading \(download.model.label) (\(DownloadSection.text(download.done)) of \(size))…"
                                : "Download \(download.model.label) (\(size)) once. Works offline forever.",
                        actionTitle: installed ? "Open Local" : download.isUnderWay ? "View Progress" : "Download (\(size))"
                    ) {
                        chat.selectMode(.llama)
                        if !installed && !download.isUnderWay {
                            chat.downloadRecommendedLocalModel()
                        }
                        dismiss()
                    }
                }

                PathCard(
                    symbol: "cpu",
                    title: "NEAR AI Gateway",
                    badge: localFits ? "No Download" : "Recommended",
                    badgeTint: .accentColor,
                    detail: "Hardware-verified Intel TDX + NVIDIA enclaves using a standard NEAR API key.",
                    actionTitle: "Set Up…"
                ) {
                    chat.selectMode(.near)
                    dismiss()
                    showNearSettings()
                }

                if localFits {
                    PathCard(
                        symbol: "theatermasks",
                        title: "Token Inference & zkAPI Anon Inference",
                        badge: "Tor + Rewriter",
                        badgeTint: .orange,
                        detail: "Anonymous pay-per-prompt with USDC or unlinkable ETH (zkAPI).",
                        actionTitle: "Funds…"
                    ) {
                        chat.selectMode(.token)
                        dismiss()
                        DispatchQueue.main.async {
                            chat.showingWallet = true
                        }
                    }
                }
            }
        }
    }

    // MARK: Step 3 — Agent Mode & Power Tools

    private var superpowersStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent mode & power tools")
                    .font(.title2.weight(.semibold))
                Text("Run sandboxed coding agents, connect your Mac apps, and summon Cloak anywhere.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: Chat.Kind.agentSymbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Agent Box (Pi)")
                            .font(.headline)
                        Text("Toggle the hammer in Token Inference or zkAPI Anon Inference to run shell & coding tasks inside a sealed Linux microVM over Tor — never touching your Mac files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Link(destination: Self.agentDocsURL) {
                        HStack(spacing: 3) {
                            Text("Docs")
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
                .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                SuperpowerRow(
                    symbol: "command",
                    title: "Menu bar & Quick Prompt",
                    detail: "Draft from the menu bar, toggle live Cover Traffic, or set a global hotkey (zero Accessibility permission required).",
                    actionTitle: "Shortcut…"
                ) {
                    dismiss()
                    showAdvancedSettings()
                }

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Models & Connected Apps")
                            .font(.headline)
                        Text("Switch local MLX/GGUF models or route Cursor, Cline, and Aider through Cloak at 127.0.0.1:8742.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button("Models…") {
                            dismiss()
                            showLlamaSettings()
                        }
                        .controlSize(.small)
                        Button("Apps…") {
                            dismiss()
                            showConnectedApps()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
                .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
    }
}

private struct ComparisonRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
        .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct PathCard: View {
    let symbol: String
    let title: String
    let badge: String
    let badgeTint: Color
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badgeTint.opacity(0.14), in: Capsule())
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
        .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct SuperpowerRow: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
        .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
