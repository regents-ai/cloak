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
    let showServingSettings: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int

    init(
        chat: Chat,
        initialStep: Int = 0,
        showNearSettings: @escaping () -> Void,
        showLlamaSettings: @escaping () -> Void,
        showAdvancedSettings: @escaping () -> Void,
        showConnectedApps: @escaping () -> Void,
        showServingSettings: (() -> Void)? = nil
    ) {
        self.chat = chat
        self.showNearSettings = showNearSettings
        self.showLlamaSettings = showLlamaSettings
        self.showAdvancedSettings = showAdvancedSettings
        self.showConnectedApps = showConnectedApps
        self.showServingSettings = showServingSettings
        _step = State(initialValue: min(max(initialStep, 0), 2))
    }

    private let totalSteps = 3
    private static let agentDocsURL = URL(string: "https://regents.sh/cloak#agent")!
    private static let nearCloudURL = URL(string: "https://cloud.near.ai")!
    private static let walletGuideURL = URL(string: "https://regents.sh/docs/cloak/wallets")!

    private var localFits: Bool {
        chat.recommendedLocalDownload.fits
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: choosePathStep
                case 1: superpowersStep
                default: quickstartStep
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
        .frame(width: 640, height: 610)
    }

    // MARK: Step 1 — Welcome & Choose Your Path (Hardware-Aware + Tor Tradeoffs)

    private var choosePathStep: some View {
        let download = chat.recommendedLocalDownload
        let size = DownloadSection.text(download.total)
        let installed = download.state == .installed

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Cloak")
                    .font(.title2.weight(.semibold))
                Text(
                    localFits
                        ? "Private, zero-account AI for macOS — offline local models, hardware enclaves, and anonymous pay-per-prompt cloud."
                        : "Private, zero-account AI for macOS. Local models need 16 GB+ Apple Silicon; NEAR and Direct Token Inference work right away on this Mac."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: torSymbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("**When Tor is used — and why it's slower**")
                        .font(.callout)
                    Text("Tor hides your IP address across 3 relays, which adds noticeable latency. **No Tor (fast):** Local (offline), NEAR (direct by default, hardware-encrypted), and Token Inference if you toggle Tor off. **Tor ON:** zkAPI (always) and Token Inference by default — toggle Tor below Chat anytime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.08), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
            .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color.orange.opacity(0.24), lineWidth: 1))

            VStack(spacing: 8) {
                if localFits {
                    PathCard(
                        symbol: "laptopcomputer",
                        title: "Local",
                        badge: installed ? "Ready · No Tor" : download.isUnderWay ? "Downloading" : "Free · Offline",
                        badgeTint: .green,
                        detail: installed
                            ? "\(download.model.label) is ready for instant offline chat."
                            : download.isUnderWay
                                ? "Downloading \(download.model.label) (\(DownloadSection.text(download.done)) of \(size))…"
                                : "Download \(download.model.label) (\(size)) once. Fast, offline, no account or crypto.",
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
                    badge: localFits ? "Fast Direct · Optional Tor" : "Recommended · Fast",
                    badgeTint: .accentColor,
                    detail: "Hardware-verified Intel TDX + NVIDIA enclaves using a NEAR API key. Direct by default; toggle Tor on to hide your IP.",
                    actionTitle: "Set Up…"
                ) {
                    chat.selectMode(.near)
                    dismiss()
                    showNearSettings()
                }

                PathCard(
                    symbol: "theatermasks",
                    title: "Token Inference & zkAPI Anon Inference",
                    badge: "Tor Optional / Always",
                    badgeTint: .orange,
                    detail: "Pay per prompt with Boundless (Tempo USDC.e) or Venice (Base USDC) — Tor optional for speed — or unlinkable zkAPI ETH (always Tor).",
                    actionTitle: "Funds…"
                ) {
                    chat.selectMode(.token)
                    dismiss()
                    DispatchQueue.main.async {
                        chat.showingWallet = true
                    }
                }

                if let showServingSettings {
                    PathCard(
                        symbol: "server.rack",
                        title: "Serve Inference to Earn",
                        badge: "Darkbloom",
                        badgeTint: .purple,
                        detail: "Idle Macs can join EigenLayer's Darkbloom network and serve inference.",
                        actionTitle: "Settings…"
                    ) {
                        dismiss()
                        showServingSettings()
                    }
                }
            }
        }
    }

    // MARK: Step 2 — Agent Mode & Power Tools

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

    // MARK: Step 3 — Quickstart

    private var quickstartStep: some View {
        let modelLabel = chat.recommendedLocalDownload.model.label

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quickstart")
                    .font(.title2.weight(.semibold))
                Text("What you need to start each mode.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                QuickstartRow(
                    symbol: "laptopcomputer",
                    tint: .green,
                    title: "Local",
                    badge: "16 GB+ Macs",
                    detail: localFits
                        ? "Download \(modelLabel) once — free, offline, no account or crypto."
                        : "Requires 16 GB+ Apple Silicon. Download \(modelLabel) once for free, offline chat."
                ) {
                    Button("Models…") {
                        dismiss()
                        showLlamaSettings()
                    }
                    .controlSize(.small)
                }

                QuickstartRow(
                    symbol: "cpu",
                    tint: .accentColor,
                    title: "NEAR AI Gateway",
                    badge: "API Key",
                    detail: "Create an API key at cloud.near.ai and save it in NEAR settings. Runs on 8 GB+ Macs with 0 GB download."
                ) {
                    HStack(spacing: 8) {
                        Link(destination: Self.nearCloudURL) {
                            HStack(spacing: 3) {
                                Text("Get Key")
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                            }
                        }
                        .controlSize(.small)
                        Button("NEAR Key…") {
                            chat.selectMode(.near)
                            dismiss()
                            showNearSettings()
                        }
                        .controlSize(.small)
                    }
                }

                QuickstartRow(
                    symbol: "dollarsign.circle",
                    tint: .orange,
                    title: "Token Inference",
                    badge: "Tempo · Base",
                    detail: "Open Funds to create a local wallet, then send a little USDC.e on Tempo (Boundless) or USDC on Base (Venice, or a Venice API key). Toggle Tor off below Chat for faster direct replies."
                ) {
                    Button("Funds…") {
                        chat.selectMode(.token)
                        dismiss()
                        DispatchQueue.main.async {
                            chat.showingWallet = true
                        }
                    }
                    .controlSize(.small)
                }

                QuickstartRow(
                    symbol: "theatermasks",
                    tint: .purple,
                    title: "zkAPI Anon Inference",
                    badge: "Ethereum L1",
                    detail: "Open Funds → zkAPI, send a small amount of mainnet ETH (+ L1 gas) to your local address, and deposit for unlinkable one-time keys."
                ) {
                    Button("Funds…") {
                        chat.selectMode(.v)
                        dismiss()
                        DispatchQueue.main.async {
                            chat.showingWallet = true
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Text("Start with a small balance ($5–$20) while Cloak is in beta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link(destination: Self.walletGuideURL) {
                    HStack(spacing: 3) {
                        Text("Wallet guide")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct QuickstartRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let badge: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.14), in: Capsule())
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
