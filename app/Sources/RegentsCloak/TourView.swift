import CloakChat
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
        let profile = chat.settings.securityProfile

        return VStack(alignment: .leading, spacing: 11) {
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

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: profile.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(profile == .localOnly ? .green : (profile == .anonCloud ? .purple : .accentColor))
                    Text("Security Profile")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    Picker(
                        "Security Profile",
                        selection: Binding(
                            get: { chat.settings.securityProfile },
                            set: { chat.settings.securityProfile = $0 }
                        )
                    ) {
                        ForEach(SecurityProfile.allCases) { option in
                            Text(option.shortTitle).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.07), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
            .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color.accentColor.opacity(0.22), lineWidth: 1))

            VStack(spacing: 8) {
                if localFits {
                    PathCard(
                        symbol: "laptopcomputer",
                        title: "Local",
                        badge: installed ? "Ready · No Tor" : download.isUnderWay ? "Downloading" : "Free · Offline",
                        badgeTint: .green,
                        detail: installed
                            ? "\(download.model.label) is ready for instant offline chat — or reuse Splash, LM Studio, mlx-serve & Ollama on 127.0.0.1."
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
                    badge: profile.allowsNear ? (localFits ? "Fast Direct · Optional Tor" : "Recommended · Fast") : "Private Cloud Only",
                    badgeTint: profile.allowsNear ? .accentColor : .secondary,
                    detail: "Hardware-verified Intel TDX + NVIDIA enclaves using a NEAR API key. Direct by default; toggle Tor on to hide your IP.",
                    actionTitle: "Set Up…",
                    disabled: !profile.allowsNear
                ) {
                    chat.selectMode(.near)
                    dismiss()
                    showNearSettings()
                }

                PathCard(
                    symbol: "theatermasks",
                    title: profile == .anonCloud ? "zkAPI Anon Inference" : "Token Inference & zkAPI Anon Inference",
                    badge: profile.allowsAnyCloud ? (profile == .anonCloud ? "Tor + Cover Locked ON" : "Tor Optional / Always") : "Cloud Disabled",
                    badgeTint: profile.allowsAnyCloud ? .orange : .secondary,
                    detail: profile == .anonCloud
                        ? "Unlinkable one-time zkAPI credentials over Tor with Cover Traffic and Local Prompt Rewriting locked ON."
                        : "Pay per prompt with Venice (Base USDC / Stripe Link) or Boundless (Tempo USDC.e) — or unlinkable zkAPI ETH (always Tor).",
                    actionTitle: "Funds…",
                    disabled: !profile.allowsAnyCloud
                ) {
                    chat.selectMode(profile == .anonCloud ? .v : .token)
                    dismiss()
                    DispatchQueue.main.async {
                        chat.showingWallet = true
                    }
                }

                if let showServingSettings {
                    PathCard(
                        symbol: "server.rack",
                        title: "Serve Inference to Earn",
                        badge: profile.allowsNetworkServing ? "Darkbloom · Guardrails" : "Local Only",
                        badgeTint: .purple,
                        detail: "Idle Macs can serve local apps or earn payouts on Darkbloom with battery, thermal, and Quiet Hours guardrails.",
                        actionTitle: "Settings…"
                    ) {
                        dismiss()
                        showServingSettings()
                    }
                }
            }
        }
    }

    // MARK: Step 2 — Connected Apps, Projects & Agent Box

    private var superpowersStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected Apps, Projects & Agent Box")
                    .font(.title2.weight(.semibold))
                Text("Route your coding agents through Privacy Shield, isolate client workspaces, and run sandboxed tasks.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "cable.connector")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected Apps + Privacy Shield")
                            .font(.headline)
                        Text("Connect Claude Code, OpenCode, Goose, Cursor, or Cline at 127.0.0.1:8742 across all 5 rails (including Local $0) with pre-send secret blocking, reversible aliases, and Spend Guardrails.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Apps…") {
                        dismiss()
                        showConnectedApps()
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
                .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                SuperpowerRow(
                    symbol: "folder.badge.gearshape",
                    title: "Saved Project Profiles & Local Voice",
                    detail: "Switch projects in Chat's sidebar to swap approved Local folders, Privacy Shield terms, and preferred routes. Dictate privately with on-device macOS 26 Local Voice.",
                    actionTitle: "Models…"
                ) {
                    dismiss()
                    showLlamaSettings()
                }

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: Chat.Kind.agentSymbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Agent Box (Pi) & Quick Prompt")
                            .font(.headline)
                        Text("Toggle the hammer in Token or zkAPI mode to run shell & coding tasks in a sealed Linux microVM over Tor, or summon Quick Prompt from any app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button("Shortcut…") {
                            dismiss()
                            showAdvancedSettings()
                        }
                        .controlSize(.small)
                        Link(destination: Self.agentDocsURL) {
                            HStack(spacing: 3) {
                                Text("Docs")
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                            }
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
                        ? "Download \(modelLabel) once, or connect to running Splash, TensorFold, mlx-serve, LM Studio, or Ollama servers on 127.0.0.1 — free and offline."
                        : "Requires 16 GB+ Apple Silicon for built-in weights, or connect to a running local server on 127.0.0.1."
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
                    badge: "Base · Tempo",
                    detail: "Open Funds to create a local wallet and fund Base USDC (Venice, including Stripe Link / Apple Pay) or Tempo USDC.e (Boundless), or save a Venice API key."
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
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
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
                .disabled(disabled)
        }
        .padding(12)
        .opacity(disabled ? 0.62 : 1)
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
