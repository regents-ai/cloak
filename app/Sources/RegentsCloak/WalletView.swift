import AppKit
import CloakChat
import CloakSupervisor
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import SwiftUI

/// How the conversation in front is paid for. In a V chat, Agent on or off,
/// V's wallet (`VWallet`): the deposit each request is paid from with a new
/// key. In a Token Inference chat, Agent on or off, its one wallet: made
/// here on Create, its address to add funds to, its balance, the deposit
/// chats are paid from, and the model they go to. While Cloak is not
/// running, nothing reaches the guest: Cloak's state and Start
/// (`StartRow`) lead the sheet, and the buttons that need the guest are not
/// shown. A button that reaches the network is off only where its request
/// is certain to stop: no deposit, as the network last showed the wallet;
/// or, for Withdraw, the network's waiting time still running, with why
/// beside it. Never for a press under way. In a NEAR Private AI chat, the
/// owner's NEAR key, whether one is saved, the way to Settings' NEAR pane,
/// and the tokens NEAR counted for the chat; in a Local Llama chat, nothing
/// to pay. The wallet is read each time this opens on a chat it pays for.
struct WalletView: View {
    enum FundsTab: String, CaseIterable, Identifiable {
        case payPerPrompt
        case paranoid
        case privateCloud

        var id: Self { self }

        var title: String {
            switch self {
            case .payPerPrompt: "Token Inference"
            case .paranoid: "zkAPI Anon Inference"
            case .privateCloud: "NEAR AI Gateway"
            }
        }

        init(kind: Chat.Kind) {
            switch kind {
            case .token, .llama: self = .payPerPrompt
            case .v: self = .paranoid
            case .near: self = .privateCloud
            }
        }
    }

    @Bindable var wallet: Wallet
    let veniceMode: VeniceMode
    let payer: Payer
    @Bindable var settings: AppSettings
    let nearMode: NearMode
    /// The download of the model that rewords, for the Start row's fix.
    let download: ModelDownload
    /// The conversation in front's mode, used to pick the initial tab.
    let kind: Chat.Kind
    /// The tokens NEAR counted for the conversation in front's answers,
    /// added up; nil while none has counts, as in every other mode.
    let tokens: Tokens?
    let showDetails: () -> Void
    let showNearSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: FundsTab

    init(
        wallet: Wallet, veniceMode: VeniceMode, payer: Payer, settings: AppSettings, nearMode: NearMode,
        download: ModelDownload, kind: Chat.Kind, tokens: Tokens?,
        showDetails: @escaping () -> Void, showNearSettings: @escaping () -> Void
    ) {
        self.wallet = wallet
        self.veniceMode = veniceMode
        self.payer = payer
        self.settings = settings
        self.nearMode = nearMode
        self.download = download
        self.kind = kind
        self.tokens = tokens
        self.showDetails = showDetails
        self.showNearSettings = showNearSettings
        _tab = State(initialValue: FundsTab(kind: kind))
    }

    var body: some View {
        let running = wallet.supervisor.phase == .running
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Funds")
                        .font(.headline)
                        .fixedSize()
                    BetaBadge()
                }
                Spacer()
                Picker("Mode", selection: $tab) {
                    ForEach(FundsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                WhyCryptoButton(tab: tab)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                Form {
                    if tab == .paranoid || tab == .payPerPrompt {
                        Section {
                            BetaWalletNotice(includeZkAPILimit: tab == .paranoid)
                        }
                    }
                    if tab == .paranoid || tab == .payPerPrompt, !running {
                        Section {
                            StartRow(supervisor: wallet.supervisor, download: download) {
                                dismiss()
                                showDetails()
                            }
                        }
                    }
                    switch tab {
                    case .paranoid:
                        VWallet(payer: payer, settings: settings, running: running)
                    case .payPerPrompt:
                        Section {
                            LabeledContent("Provider") {
                                Picker("Provider", selection: $settings.payProvider) {
                                    Text("Venice (Base)").tag(PayProvider.venice)
                                    Text("Boundless + Tempo").tag(PayProvider.boundless)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        switch settings.payProvider {
                        case .venice:
                            VeniceFundsSections(venice: veniceMode, settings: settings, running: running)
                        case .boundless:
                            WalletSections(wallet: wallet, running: running)
                        }
                    case .privateCloud:
                        NearPayment(mode: nearMode, tokens: tokens) {
                            dismiss()
                            showNearSettings()
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .onChange(of: payer.review) { _, review in
                    guard review != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("v-review-actions", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: payer.stop) { _, stop in
                    guard stop != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("v-stop-banner", anchor: .center)
                        }
                    }
                }
            }
            .refreshable {
                guard running else { return }
                switch tab {
                case .paranoid:
                    payer.follow()
                case .payPerPrompt:
                    if settings.payProvider == .venice {
                        await veniceMode.refresh()
                    } else {
                        await wallet.refresh()
                    }
                case .privateCloud:
                    break
                }
            }
            Divider()
            HStack(spacing: 10) {
                if tab == .payPerPrompt {
                    if (settings.payProvider == .venice && veniceMode.working > 0)
                        || (settings.payProvider == .boundless && (wallet.working > 0 || wallet.presence == .creating))
                    {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if tab == .paranoid, payer.working > 0, payer.activity == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                // Only while there is something to read again.
                switch tab {
                case .paranoid where running:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { payer.follow() }
                case .payPerPrompt where running && settings.payProvider == .venice:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { Task { await veniceMode.refresh() } }
                case .payPerPrompt where running && settings.payProvider == .boundless && wallet.presence.address != nil:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { Task { await wallet.refresh() } }
                case .paranoid, .payPerPrompt, .privateCloud:
                    EmptyView()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // Level with the form's boxes.
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // As tall as what it shows, up to 660 points; past that, the form scrolls.
        .frame(width: 600)
        .onChange(of: kind) { _, newKind in
            tab = FundsTab(kind: newKind)
        }
        .frame(maxHeight: 660)
        // As it opens, when tabs or provider switch, and when Cloak starts or stops under it.
        .task(id: "\(tab.rawValue)-\(settings.payProvider.rawValue)-\(running)") {
            switch tab {
            case .paranoid: payer.follow()
            case .payPerPrompt:
                if settings.payProvider == .venice {
                    await veniceMode.refresh()
                } else {
                    await wallet.refresh()
                }
            case .privateCloud: break
            }
        }
    }
}

/// Plain-English "Why crypto?" explanation for each funding mode (Decision N4).
private struct WhyCryptoButton: View {
    let tab: WalletView.FundsTab

    var body: some View {
        let note: String = switch tab {
        case .payPerPrompt:
            "Credit cards tie prompts to your name. A local USDC wallet pays per prompt over Tor with no account."
        case .paranoid:
            "zkAPI Anon Inference uses zero-knowledge proofs (zkAPI) so every prompt is paid with a fresh one-time key — unlinkable even to your own earlier prompts."
        case .privateCloud:
            "Runs in hardware-verified remote enclaves using a standard NEAR API key — no crypto required."
        }
        InfoButton("Why crypto?", note: note)
    }
}

/// Live checklist of `Supervisor.StartStep` shown across app windows while
/// Cloak is starting (`phase == .preparing`).
struct StartupProgressView: View {
    let supervisor: Supervisor

    var body: some View {
        let current = supervisor.startStep ?? .checking
        let cover = supervisor.cover ?? supervisor.coverPreferred
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Supervisor.StartStep.allCases) { step in
                let isDone = step.rawValue < current.rawValue
                let isActive = step.rawValue == current.rawValue
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        if isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                        } else if isActive {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                    Text(step.detail(cover: cover))
                        .font(.callout)
                        .fontWeight(isActive ? .medium : .regular)
                        .foregroundStyle(isActive ? .primary : (isDone ? .secondary : .tertiary))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// In a wallet while Cloak is not running: Cloak's state in words and the
/// way on beside it. Start while paused or ready; a failure's fix (`Fix`),
/// or, with none, its remedy in words; a live step-by-step startup checklist
/// while Cloak starts, or a spinner while it stops.
struct StartRow: View {
    let supervisor: Supervisor
    /// The download of the model that rewords.
    let download: ModelDownload
    let showDetails: () -> Void

    var body: some View {
        let phase = supervisor.phase
        let fix = phase.reason.flatMap { Fix(for: $0, download: download) }
        if phase.state == .preparing {
            let stepIndex = (supervisor.startStep?.rawValue ?? 0) + 1
            let stepTotal = Supervisor.StartStep.allCases.count
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Starting Cloak")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Step \(stepIndex) of \(stepTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StartupProgressView(supervisor: supervisor)
            }
            .padding(.vertical, 2)
        } else {
            let needsRewriter = (phase == .paused || phase == .ready) && download.state != .installed
            HStack(spacing: 8) {
                Text(needsRewriter ? (download.isUnderWay ? "Downloading the local rewriter…" : "Download the local rewriter to start.") : words(phase, fix: fix))
                    .foregroundStyle(.secondary)
                Spacer()
                if needsRewriter {
                    Button(download.isUnderWay ? "Downloading…" : "Download Model…", action: showDetails)
                        .buttonStyle(.borderedProminent)
                } else {
                    switch phase {
                    case .needsAttention:
                        switch fix {
                        case .start?: Button(Fix.start.title) { supervisor.send(.start) }
                        case .download(let underWay)?: Button(Fix.download(underWay: underWay).title, action: showDetails)
                        case .repair?: Button(Fix.repair.title) { download.repair() }
                        case .showModel?: Button(Fix.showModel.title, action: Fix.showModel)
                        case nil: EmptyView()
                        }
                    case .paused, .ready:
                        Button("Start") { supervisor.send(.start) }
                    case .preparing, .stopping, .running:
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func words(_ phase: Phase, fix: Fix?) -> String {
        switch phase {
        case .paused: "Cloak is paused."
        case .ready: "Cloak isn't running."
        case .preparing: "Cloak is starting."
        case .stopping(.restart): "Cloak is restarting."
        case .stopping: "Cloak is stopping."
        case .needsAttention(let reason):
            switch fix {
            case .start?, .download?, .repair?: reason.title(with: fix)
            // No button does it all, so the words say what to do.
            case .showModel?, nil: "\(reason.title) \(reason.remedy)"
            }
        case .running: "Cloak is running."
        }
    }
}

/// Pay-Per-Prompt's Venice provider sections (Decisions N5.1b, R5b, N1a):
/// dedicated Base USDC wallet (separate Keychain key from Tempo), Card / Apple
/// Pay funding straight to that local address, x402 credit top-up, optional
/// Venice API key, and Private/TEE model picker.
struct VeniceFundsSections: View {
    let venice: VeniceMode
    @Bindable var settings: AppSettings
    let running: Bool
    @State private var onRampTarget: CardOnRamp.Target?
    @State private var topUpText = "5"
    @State private var topUpError: String?
    @State private var pendingTopUp: Amount?
    @State private var apiKeyInput = ""
    @State private var keyBusy = false
    @State private var keyError: String?

    private static let onlyBaseUSDC =
        "Send USDC on Base only — other assets can't be recovered."

    var body: some View {
        Section {
            Picker("Pay with", selection: $settings.venicePays) {
                Text("Base USDC Wallet").tag(VeniceChat.Pays.wallet)
                Text("Venice API Key").tag(VeniceChat.Pays.key)
            }
            .pickerStyle(.segmented)
        }

        if settings.venicePays == .wallet {
            walletSections
        } else {
            keySection
        }

        modelsSection
            .sheet(item: $onRampTarget) { target in
                CardOnRampSheet(target: target) {
                    Task { await venice.refreshBalances() }
                }
            }
    }

    @ViewBuilder private var walletSections: some View {
        if let stop = venice.walletStop {
            Section {
                StopRow(
                    stop: stop,
                    retry: running && venice.presence == .absent ? { Task { await venice.createWallet() } } : nil,
                    dismiss: { venice.dismissWalletStop() }
                )
            }
        }
        switch venice.presence {
        case .looking:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading Venice Base wallet…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        case .unreadable:
            Section {
                Text("Cloak couldn't read the Venice wallet from Keychain.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Try Again") { Task { await venice.findWallet() } }
                }
            }
        case .absent, .creating:
            Section("Venice Base Wallet") {
                Text("Creates a local Base USDC wallet on this Mac — pay per prompt with no Venice account.")
                    .foregroundStyle(.secondary)
                if running {
                    HStack {
                        Spacer()
                        Button("Create Venice Wallet") { Task { await venice.createWallet() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(venice.presence == .creating)
                    }
                }
            }
        case .held(let address):
            Section {
                LabeledContent("Address") {
                    HStack(spacing: 4) {
                        Text(address)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        CopyButton(text: address)
                        CodeButton(address: address, only: Self.onlyBaseUSDC)
                    }
                }
                LabeledContent("Network", value: "Base (USDC)")
                Only(words: Self.onlyBaseUSDC)
                LabeledContent("Wallet USDC") {
                    if let funds = venice.funds {
                        Text("\(funds.dollars.formatted(.currency(code: "USD"))) USDC")
                            .monospacedDigit()
                    } else if venice.fundsFailed {
                        HStack(spacing: 6) {
                            Text("Couldn't read over Tor")
                                .foregroundStyle(.secondary)
                            if running {
                                Button("Try Again") { Task { await venice.refreshBalances() } }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        Unread(running: running, what: "Base USDC balance")
                    }
                }
                HStack(spacing: 8) {
                    ExportPrivateKeyButton(
                        title: "Venice Base Wallet",
                        address: address,
                        loadKey: { try VeniceWalletKeychain.key() })
                    Spacer(minLength: 0)
                    if CardOnRamp.isConfigured {
                        Button {
                            onRampTarget = .baseUSDC(address: address)
                        } label: {
                            Label("Add Funds with Card / Apple Pay", systemImage: "creditcard")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Venice Base Wallet")
            } footer: {
                Text("Beta: keep working balances small. Venice x402 top-ups are gasless; moving unspent Base USDC out via an external wallet requires a small amount of Base ETH for gas. Stored in this Mac's Keychain (not synced to iCloud). [Wallet security & recovery](https://regents.sh/docs/cloak/wallets).")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Credit Balance") {
                    if let usd = venice.credit?.usd {
                        Text(usd.formatted(.currency(code: "USD")))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    } else if let stop = venice.accountStop {
                        Text(stop.kind.title)
                            .foregroundStyle(.secondary)
                    } else {
                        Unread(running: running, what: "Venice credit")
                    }
                }
                if running {
                    LabeledContent("Move USDC to Credit") {
                        HStack(spacing: 6) {
                            ForEach(["5", "10", "20"], id: \.self) { preset in
                                Button("$\(preset)") {
                                    topUpText = preset
                                    topUpError = nil
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(topUpText == preset ? .accentColor : nil)
                            }
                            Text("$").foregroundStyle(.secondary)
                            TextField("Amount", text: $topUpText, prompt: Text("5"))
                                .labelsHidden()
                                .accessibilityLabel("Top-up amount in US dollars")
                                .frame(width: 52)
                                .onChange(of: topUpText) { topUpError = nil }
                            Button(venice.adding ? "Topping Up…" : "Top Up") { prepareTopUp() }
                                .disabled(venice.adding || venice.topUpUncertain)
                                .confirmationDialog(
                                    pendingTopUp.map { "Top Up \($0.dollars.formatted(.currency(code: "USD"))) to Venice Credit?" } ?? "Top Up Venice Credit?",
                                    isPresented: Binding(
                                        get: { pendingTopUp != nil },
                                        set: { if !$0 { pendingTopUp = nil } }
                                    ),
                                    titleVisibility: .visible
                                ) {
                                    if let amount = pendingTopUp {
                                        Button("Top Up \(amount.dollars.formatted(.currency(code: "USD")))") {
                                            pendingTopUp = nil
                                            Task { await venice.topUp(amount) }
                                        }
                                    }
                                    Button("Cancel", role: .cancel) { pendingTopUp = nil }
                                } message: {
                                    Text("Signs a gasless Base USDC transfer to Venice AI Credit. Top-ups are irreversible and non-refundable.")
                                }
                        }
                    }
                    if let least = venice.terms?.least {
                        Text("Minimum top-up: \(least.dollars.formatted(.currency(code: "USD"))) USDC on Base.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Beta: Base USDC x402 top-ups are irreversible on-chain transfers. Move only what you expect to spend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let topUpError {
                        Text(topUpError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let added = venice.added {
                        Label("Added \(added.credited.formatted(.currency(code: "USD"))) credit.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let settled = venice.topUpSettledNotice {
                        Label(settled, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let pending = venice.uncertainTopUp {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let expired = context.date >= pending.expiresAt
                            let message: String = {
                                if expired {
                                    return "The earlier top-up authorization expired without changing balances. Verify live balances to unlock Top Up."
                                }
                                if pending.checkedUnchanged {
                                    let remaining = max(1, Int(pending.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                                    let mins = remaining / 60
                                    let secs = remaining % 60
                                    let countdown = String(format: "%d:%02d", mins, secs)
                                    return "Balances haven't changed yet — your signed transfer may still settle on Base (authorization expires in \(countdown)). Verify again before retrying."
                                }
                                return "Top-up was submitted over Tor and may still settle on Base. Verify live balances before trying again."
                            }()
                            HStack(alignment: .top, spacing: 8) {
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                if running {
                                    Spacer(minLength: 4)
                                    Button("Verify Balances") { Task { await venice.refreshBalances() } }
                                        .controlSize(.small)
                                }
                            }
                        }
                    } else if let stop = venice.topUpStop {
                        Label("\(stop.kind.title): \(stop.kind.words)", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Venice AI Credit")
            }
        }
    }

    @ViewBuilder private var keySection: some View {
        Section {
            if venice.hasKey == true {
                LabeledContent("Key") {
                    HStack(spacing: 8) {
                        Text("Saved in Keychain")
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            keyBusy = true
                            keyError = nil
                            Task {
                                do { try await venice.removeKey() } catch { keyError = "Couldn't remove key." }
                                keyBusy = false
                            }
                        }
                        .disabled(keyBusy)
                    }
                }
                if let usd = venice.keyAccount?.usd {
                    LabeledContent("USD Balance", value: usd.formatted(.currency(code: "USD")))
                }
                if let diem = venice.keyAccount?.diem, diem > 0 {
                    LabeledContent("DIEM Balance", value: "\(diem.formatted(.number.precision(.fractionLength(2...4)))) DIEM")
                }
                if let stop = venice.keyAccountStop {
                    Label("\(stop.kind.title): \(stop.kind.words)", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if venice.hasKey == nil {
                HStack(spacing: 8) {
                    Text("Couldn't check Venice API key in Keychain.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { Task { await venice.findKey() } }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Venice API key", text: $apiKeyInput, prompt: Text("Paste Venice Inference key"))
                        .labelsHidden()
                        .accessibilityLabel("Venice API key")
                    Button("Save") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        keyBusy = true
                        keyError = nil
                        Task {
                            do {
                                try await venice.saveKey(trimmed)
                                apiKeyInput = ""
                            } catch {
                                keyError = "Couldn't save key to Keychain."
                            }
                            keyBusy = false
                        }
                    }
                    .disabled(keyBusy || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Venice API Key")
        } footer: {
            if venice.hasKey != true {
                Text("Create an Inference API key at [venice.ai/settings/api](https://venice.ai/settings/api).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var modelsSection: some View {
        Section {
            let offered = venice.offered
            if !offered.isEmpty {
                let selectedID = Binding<String>(
                    get: { venice.effectiveChoice?.id ?? offered[0].id },
                    set: { id in
                        if let model = offered.first(where: { $0.id == id }) {
                            settings.veniceModel = VeniceChoice(id: model.id, name: model.name, tier: model.tier)
                        }
                    })
                Picker("Model", selection: selectedID) {
                    ForEach(offered) { model in
                        let inPrice = model.input.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
                        let outPrice = model.output.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
                        Text("\(model.name) [\(model.tier.name)] · \(inPrice) | \(outPrice)")
                            .tag(model.id)
                    }
                }
                .tip("Prices per million tokens (in | out). Only Private and TEE models are listed by default.")
            } else if let stop = venice.listStop {
                HStack {
                    Text("Couldn't load Venice models (\(stop.kind.title)).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { Task { await venice.refreshModels() } }
                }
            } else if running {
                LabeledContent("Model") {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Text("Start Cloak to load Venice models.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Powered by [Venice AI](https://venice.ai) ([Docs](https://docs.venice.ai) · [GitHub](https://github.com/veniceai)).")
                .foregroundStyle(.secondary)
        }
    }

    private func prepareTopUp() {
        guard let amount = Amount(dollars: topUpText) else {
            topUpError = "Enter a valid dollar amount (e.g. 5)."
            return
        }
        if let least = venice.terms?.least, amount < least {
            topUpError = "Minimum top-up is \(least.dollars.formatted(.currency(code: "USD"))) USDC on Base."
            return
        }
        if let funds = venice.funds, amount > funds {
            topUpError = "Not enough Base USDC in this wallet (\(funds.dollars.formatted(.currency(code: "USD"))) available)."
            return
        }
        topUpError = nil
        pendingTopUp = amount
    }
}

/// The wallet that pays for Token Inference chats, Agent on or off.
struct WalletSections: View {
    let wallet: Wallet
    let running: Bool

    var body: some View {
        if let stop = wallet.stop ?? wallet.readStop {
            let canRetryRead = wallet.stop == nil && running && wallet.presence.address != nil
            Section {
                StopRow(
                    stop: stop,
                    retry: canRetryRead ? { Task { await wallet.refresh() } } : nil,
                    dismiss: { wallet.dismiss() }
                )
            }
        }
        switch wallet.presence {
        case .looking:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading Token Inference wallet…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        case .unreadable:
            Section {
                Text("Cloak couldn't read the wallet.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Try Again") { Task { await wallet.find() } }
                }
            }
        case .held(let address):
            Account(wallet: wallet, address: address, running: running)
            Holding(wallet: wallet, running: running)
            Models(wallet: wallet)
        case .absent, .creating:
            Section {
                Text("Cloak makes one wallet on this Mac. You add funds to it, and it pays for each chat you send.")
                    .foregroundStyle(.secondary)
                if running {
                    HStack {
                        Spacer()
                        Button("Create Wallet") { Task { await wallet.create() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(wallet.presence == .creating)
                    }
                }
            }
        }
    }
}

/// In place of an amount the network hasn't shown since Cloak opened: a
/// dash, with why as its help, anywhere on the row's value side. The wallet
/// is read only while Cloak runs, so nothing leaves this Mac for it while
/// Cloak is paused.
private struct Unread: View {
    let running: Bool
    /// What would be here: "wallet balance" or "deposit".
    let what: String

    var body: some View {
        let why = running ? "Not read yet." : "Start Cloak to load the \(what)."
        Text("—")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(.rect)
            .tip(why)
            .accessibilityLabel(why)
    }
}

/// How a NEAR Private AI chat is paid for: the owner's own key from NEAR AI
/// Cloud, whether one is saved, asked of the keychain as the NEAR pane asks
/// it (never the key itself), with the way to that pane beside it; and,
/// once NEAR has counted any of its answers, the chat's tokens in and out,
/// added up. Counts only, never a price.
struct NearPayment: View {
    let mode: NearMode
    /// The chat's, added up; nil while no answer has counts.
    let tokens: Tokens?
    let openSettings: () -> Void
    /// This row's own read of whether a key is kept stopped.
    @State private var unread = false

    var body: some View {
        Section {
            LabeledContent("Key") {
                HStack(spacing: 6) {
                    Text(key)
                        .foregroundStyle(mode.hasKey == true ? .primary : .secondary)
                    if unread {
                        SymbolButton("Try Again", symbol: "arrow.clockwise") { Task { await read() } }
                            .overhanging()
                    }
                    if mode.hasKey == false {
                        Button("Set Up Key…", action: openSettings)
                            .controlSize(.small)
                    } else {
                        SymbolButton("Open Settings", symbol: "gearshape", action: openSettings)
                            .overhanging()
                    }
                }
            }
            LabeledContent("Model", value: Near.displayModel)
            if let tokens {
                LabeledContent("Tokens", value: String(localized: "\(tokens.input) in, \(tokens.output) out"))
            }
        } footer: {
            Text("Paid with your key from [NEAR AI Cloud](https://cloud.near.ai) ([NEAR AI Gateway](https://gateway.near.ai) · [Trace Commons](https://github.com/TraceCommons/trace-commons) · [Dstack TEE](https://github.com/Dstack-TEE/dstack)).")
                .foregroundStyle(.secondary)
        }
        .task { await read() }
    }

    private func read() async {
        unread = false
        do {
            try await mode.find()
        } catch {
            unread = true
        }
    }

    private var key: String {
        if unread { return "Couldn't check" }
        return switch mode.hasKey {
        case true?: "Saved"
        case false?: "Not saved"
        case nil: "Checking…"
        }
    }
}

/// A Local Llama chat costs nothing: the model on this Mac answers it.
private struct LlamaPayment: View {
    var body: some View {
        Section {
            Text("Nothing to pay.")
        }
    }
}

/// Where to add funds, with what alone may be sent there, and what is
/// there.
private struct Account: View {
    let wallet: Wallet
    let address: String
    let running: Bool
    /// The wallet pays in USDC.e on Tempo and sends nothing else.
    private static let only = "Send USDC.e on Tempo only — other assets can't be recovered."

    var body: some View {
        Section {
            LabeledContent("Address") {
                HStack(spacing: 4) {
                    Text(address)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(text: address)
                    CodeButton(address: address, only: Self.only)
                }
            }
            LabeledContent("Asset") {
                HStack(spacing: 4) {
                    Text("USDC.e · Tempo")
                    BoundlessTempoButton()
                }
            }
            Only(words: Self.only)
            if let look = wallet.look {
                if look.providerUnreachable == true {
                    Label("Boundless API is unreachable over Tor. On-chain Tempo balance and emergency Withdraw are still available below.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.caption)
                } else if !look.setup {
                    Label("The provider no longer names USDC.e on Tempo. Don't add funds.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                LabeledContent("Balance", value: look.balance.text)
                if wallet.lacksFunds {
                    Text("Add at least \(look.least.text) plus a small buffer (e.g. 1.05 USDC.e) — Tempo uses USDC.e for gas fees.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                LabeledContent("Balance") { Unread(running: running, what: "wallet balance") }
            }
            HStack {
                ExportPrivateKeyButton(
                    title: "Boundless Tempo Wallet",
                    address: address,
                    loadKey: { try WalletKeychain.key() })
                Spacer(minLength: 0)
            }
        } header: {
            Text("Wallet")
        } footer: {
            Text("Beta: keep working balances small. Private-key backup recovers wallet USDC.e only — close or withdraw any active channel before wiping or switching Macs (keys never sync to iCloud). [Wallet security & recovery](https://regents.sh/docs/cloak/wallets).")
                .foregroundStyle(.secondary)
        }
    }
}

/// Shared compact orange `BETA` pill used on wallet and deposit surfaces.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Shared beta and self-custody notice displayed above wallet transfer and deposit flows.
struct BetaWalletNotice: View {
    var includeZkAPILimit: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Beta Wallet Notice")
                        .font(.callout.weight(.semibold))
                    BetaBadge()
                }
                Text(
                    includeZkAPILimit
                        ? "Cloak v0.2 is beta software and has not been independently audited. Keep balances small, back up or withdraw funds before wiping your Mac, and note the 30-day protocol limit on untouched zkAPI deposits. [Wallet security & recovery guide](https://regents.sh/docs/cloak/wallets)."
                        : "Cloak v0.2 is beta software and has not been independently audited. Keep balances small — wallet keys stay on this Mac only (never synced to iCloud), so wiping or losing this Mac without a backup permanently loses funds. [Wallet security & recovery guide](https://regents.sh/docs/cloak/wallets)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Touch ID / Mac-password-gated private key export for Cloak's local EVM
/// wallets (Venice Base & Boundless Tempo). Key bytes are read only after
/// `LAContext` authentication succeeds and cleared from memory on dismiss.
private struct ExportPrivateKeyButton: View {
    let title: String
    let address: String
    let loadKey: @Sendable () throws -> Data

    @State private var revealedHex: String?
    @State private var errorMessage: String?
    @State private var authenticating = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                authenticateAndReveal()
            } label: {
                Label("Export Private Key…", systemImage: "key")
            }
            .controlSize(.small)
            .disabled(authenticating)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .popover(
            isPresented: Binding(
                get: { revealedHex != nil },
                set: { shown in
                    if !shown {
                        revealedHex = nil
                        copied = false
                    }
                }),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("\(title) Private Key")
                        .font(.headline)
                }
                Text("Anyone with this key can spend funds at \(address). Store it in a password manager or offline backup — never share it or paste it into any chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hex = revealedHex {
                    Text(hex)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }

                HStack {
                    Button {
                        if let hex = revealedHex {
                            let pasteboard = NSPasteboard.general
                            pasteboard.prepareForNewContents(with: .currentHostOnly)
                            let item = NSPasteboardItem()
                            item.setString(hex, forType: .string)
                            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                            pasteboard.writeObjects([item])
                            let copiedChangeCount = pasteboard.changeCount
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(60))
                                if NSPasteboard.general.changeCount == copiedChangeCount {
                                    NSPasteboard.general.clearContents()
                                }
                            }
                        }
                    } label: {
                        Label(copied ? "Copied (clears in 60s)" : "Copy Private Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                    Button("Hide") {
                        revealedHex = nil
                        copied = false
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
            .frame(width: 390)
        }
        .onDisappear {
            revealedHex = nil
            copied = false
        }
    }

    private func authenticateAndReveal() {
        authenticating = true
        errorMessage = nil
        let reason = "Authenticate to export your \(title) private key."
        let readKey = loadKey
        Task {
            let context = LAContext()
            var authError: NSError?
            let canAuth = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
            guard canAuth else {
                authenticating = false
                errorMessage = "Device authentication unavailable."
                return
            }
            do {
                let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                guard passed else {
                    authenticating = false
                    return
                }
                let keyData = try await Task.detached(priority: .userInitiated) {
                    try readKey()
                }.value
                let hex = "0x" + keyData.map { String(format: "%02x", $0) }.joined()
                revealedHex = hex
            } catch let laError as LAError where laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                // Silent cancel.
            } catch {
                errorMessage = "Couldn't read wallet key."
            }
            authenticating = false
        }
    }
}

/// What alone may be sent to a wallet's address, said where the address is
/// copied from: a wrong coin or a wrong network sent there is beyond the
/// app's reach.
struct Only: View {
    let words: String

    var body: some View {
        Label(words, systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The address as a QR code, for a phone's wallet to scan, in a popover
/// from the button beside Copy, with the address in full under it to check
/// against, and under that what alone may be sent to it. Shown only.
struct CodeButton: View {
    let address: String
    let only: String
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Label("Show QR Code", systemImage: "qrcode")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .tip("Show QR Code")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let code = QRCode.image(for: address) {
                let side = CGFloat(code.width) * QRCode.point
                VStack(spacing: 10) {
                    // A whole number of pixels per module at any display
                    // scale, and no smoothing, so each module's edge is sharp.
                    Image(code, scale: 1, label: Text("QR code of the address"))
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 6))
                    // On one line, so it is never broken with a hyphen.
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize()
                    Only(words: only)
                        .font(.caption)
                }
                .padding(16)
            }
        }
    }
}

/// A QR code of exactly a text, one pixel per module, black on white inside
/// a white quiet zone at least four modules wide, white in light and dark
/// alike, since that is what a camera reads.
enum QRCode {
    /// The points each module takes on screen.
    static let point: CGFloat = 5

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        // CoreImage leaves a margin of one module; four more make the quiet
        // zone.
        let quiet = 4
        let side = code.width + 2 * quiet
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: quiet, y: quiet, width: code.width, height: code.height))
        return context.makeImage()
    }
}

/// The deposit chats are paid from, at the size the provider suggests: what
/// it holds, and, while Cloak runs, the two ways to end it, side by side at
/// the right. What each does is its help; why one is off is beside them.
private struct Holding: View {
    let wallet: Wallet
    let running: Bool

    var body: some View {
        let look = wallet.look
        // A deposit the network shows closed is already forgotten.
        let deposit = look?.deposit.flatMap { $0.gone == true ? nil : $0 }
        let none = look != nil && deposit == nil
        Section {
            LabeledContent("Amount") {
                if let deposit {
                    Text("\(deposit.deposit.text), \(deposit.spent.text) spent")
                } else if none {
                    Text("None")
                } else {
                    Unread(running: running, what: "deposit")
                }
            }
            if running {
                ending(deposit, unread: look == nil, none: none)
            }
        } header: {
            Text("Deposit")
        } footer: {
            Text("Beta: Boundless opens an on-chain Tempo USDC.e payment channel. Close or withdraw unspent funds before switching Macs. [Wallet security & recovery](https://regents.sh/docs/cloak/wallets).")
                .foregroundStyle(.secondary)
        }
    }

    /// Close and Withdraw, and why either is off.
    private func ending(_ deposit: Look.Deposit?, unread: Bool, none: Bool) -> some View {
        TimelineView(.everyMinute) { context in
            let wait = deposit?.withdrawAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let waiting = wait.map { context.date < $0 } ?? false
            let withdraw = wait == nil
                ? "Without the provider: asks the network to close it, then returns it to the wallet 15 minutes later."
                : "Returns it to the wallet now."
            HStack {
                if none {
                    Text("Nothing to refund.")
                        .foregroundStyle(.secondary)
                } else if waiting, let wait {
                    Text("Ready at \(wait.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let providerDown = wallet.look?.providerUnreachable == true
                Button(wallet.mutation == .closing ? "Closing…" : "Close") { Task { await wallet.close() } }
                    .disabled(unread || none || providerDown || wallet.mutating)
                    .tip(providerDown ? "Boundless API is unreachable over Tor. Use Withdraw instead." : "Refunds what's unspent.")
                    .accessibilityHint("Refunds what's unspent.")
                Button(wallet.mutation == .withdrawing ? "Submitting…" : "Withdraw") { Task { await wallet.withdraw() } }
                    .disabled(unread || none || waiting || wallet.mutating)
                    .tip(withdraw)
                    .accessibilityHint(withdraw)
            }
        }
    }
}

/// The model chats go to, with its price; which price is which is its help.
private struct Models: View {
    @Bindable var wallet: Wallet

    var body: some View {
        let models = (wallet.look?.models ?? []).sorted { $0.pricing.output < $1.pricing.output }
        Section {
            Picker("Model", selection: $wallet.model) {
                if !models.contains(where: { $0.id == wallet.model }) {
                    Text(wallet.model).tag(wallet.model)
                }
                ForEach(models) { model in
                    let input = model.pricing.input.price, output = model.pricing.output.price
                    Text("\(model.id): \(input) | \(output)")
                        // Read aloud, a bar says nothing of which side is which.
                        .accessibilityLabel("\(model.id), \(input) in, \(output) out")
                        .tag(model.id)
                }
            }
            .tip("Prices per million tokens: in | out.")
            .accessibilityHint("Prices per million tokens, in and out.")
        } footer: {
            Text("Powered by [Boundless](https://boundless.network) on [Tempo](https://tempo.xyz) via [MPP](https://mpp.dev) ([GitHub](https://github.com/tempoxyz/mpp-rs)).")
                .foregroundStyle(.secondary)
        }
    }
}

/// Why a request stopped, in plain words. In a chat, one the wallet fixes
/// (no funds, or a model that can't be used) comes with the way there.
struct StopRow: View {
    let stop: RemoteStop
    var showWallet: (() -> Void)?
    var retry: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title)
                    .fontWeight(.medium)
                Text(stop.words)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if stop.code == .noFunds || stop.code == .modelUnavailable, let showWallet {
                Button("Funds…", action: showWallet)
            }
            if let retry {
                Button("Try Again", action: retry)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .tip("Dismiss")
        }
    }
}

extension RemoteStop {
    var title: String {
        switch code {
        case .noFunds: "Insufficient funds"
        case .walletRefused: "Wallet declined"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor connection failed"
        case .torExitBlocked: "Tor exit blocked"
        case .answerRefused: "No answer"
        case .failed: "Failed over Tor"
        case .unreachable: "Not running"
        }
    }

    var words: String {
        switch code {
        case .noFunds: "Add USDC.e on Tempo to the wallet, then try again."
        case .walletRefused: "The provider declined this wallet."
        case .modelUnavailable: "This model can't be used now. Pick another in Funds."
        case .torDown: "Tor couldn't reach the network (slow or dropped Tor circuit). Try again for a fresh Tor exit."
        case .torExitBlocked: "The provider's firewall blocked this Tor exit node. Try again to switch to a fresh Tor circuit."
        case .answerRefused: "The model declined to answer."
        case .failed: "No complete response came back over Tor. Try again for a fresh Tor circuit."
        case .unreachable: "Start Cloak, then try again."
        }
    }
}

extension Amount {
    /// "1.00 USDC.e"
    var text: String {
        "\(dollars.formatted(.number.precision(.fractionLength(2...6)))) USDC.e"
    }
}

extension Double {
    /// "$0.27"
    fileprivate var price: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}
