import AppKit
import CloakChat
import CoreImage.CIFilterBuiltins
import SwiftUI

/// How the conversation in front is paid for. In a V chat, Agent on or off,
/// V's wallet (`VWallet`): the deposit each request is paid from with a new
/// key. In a Token Inference chat, Agent on or off, its one wallet: made
/// here on Create, its address to add funds to, its balance, the deposit
/// chats are paid from, and the model they go to. A button that reaches the
/// network is off only where its request is certain to stop: Cloak not
/// running, so nothing reaches the guest; no deposit, as the network last
/// showed the wallet; or, for Withdraw, the network's waiting time still
/// running. Never for a press under way. In a NEAR Private AI chat, the
/// owner's NEAR key, whether one is saved, the way to Settings' NEAR pane,
/// and the tokens NEAR counted for the chat; in a Local Llama chat, nothing
/// to pay. The wallet is read each time this opens on a chat it pays for.
/// A Token Inference chat's provider comes first: Boundless, or Venice,
/// whose sections then take the place of Boundless's (`VeniceSections`),
/// with the same wallet at the same address when Venice is paid from it.
struct WalletView: View {
    @Bindable var wallet: Wallet
    let payer: Payer
    let settings: AppSettings
    let nearMode: NearMode
    let veniceMode: VeniceMode
    /// The conversation in front's.
    let kind: Chat.Kind
    /// The conversation in front.
    let conversation: Conversation?
    /// The tokens NEAR counted for the conversation in front's answers,
    /// added up; nil while none has counts, as in every other mode.
    let tokens: Tokens?
    let showNearSettings: () -> Void
    let showVeniceSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// The provider shown: a started chat's own, fixed; or the one chosen
    /// for new chats.
    private var provider: Provider {
        guard let conversation, !conversation.turns.isEmpty else { return settings.provider }
        return conversation.isVenice ? .venice : .boundless
    }

    /// A started Venice chat's model, tier and way to pay.
    private var started: VeniceChat? {
        conversation?.turns.isEmpty == false ? conversation?.venice : nil
    }

    var body: some View {
        let running = wallet.supervisor.phase == .running
        let venice = kind == .token && provider == .venice
        VStack(spacing: 0) {
            switch kind {
            case .v: VBar()
            case .token: TokenBar(venice: venice, tier: venice ? started?.tier ?? veniceMode.choice?.tier : nil)
            case .near, .llama: EmptyView()
            }
            Form {
                switch kind {
                case .v:
                    VWallet(payer: payer, settings: settings, running: running)
                case .token:
                    ProviderPicker(settings: settings, fixed: conversation?.turns.isEmpty == false ? provider : nil)
                    if venice {
                        VeniceSections(mode: veniceMode, wallet: wallet, settings: settings, chat: started, running: running) {
                            dismiss()
                            showVeniceSettings()
                        }
                    } else {
                        WalletSections(wallet: wallet, running: running, venice: nil)
                    }
                case .near:
                    NearPayment(mode: nearMode, tokens: tokens) {
                        dismiss()
                        showNearSettings()
                    }
                case .llama:
                    LlamaPayment()
                }
            }
            .formStyle(.grouped)
            HStack(spacing: 10) {
                if kind == .token,
                    wallet.working > 0 || wallet.presence == .creating || (venice && (veniceMode.reading > 0 || veniceMode.adding > 0))
                {
                    ProgressView()
                        .controlSize(.small)
                }
                if kind == .v, payer.working > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                switch kind {
                case .v:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { payer.follow() }
                        .disabled(!running)
                case .token:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") {
                        Task {
                            if venice { await veniceMode.refresh(wallet: wallet.presence.address) } else { await wallet.refresh() }
                        }
                    }
                    .disabled((wallet.presence.address == nil && !venice) || !running)
                case .near, .llama:
                    EmptyView()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // Level with the form's boxes.
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // As tall as what it shows, up to 640 points; past that, or past
        // the room the Chat window leaves a sheet, the form scrolls.
        .frame(width: 540)
        .frame(maxHeight: 640)
        .task {
            switch kind {
            case .v: payer.follow()
            case .token, .near, .llama: break
            }
        }
        // Token Inference's wallet is read for the provider shown: for
        // Boundless as the sheet opens on it or turns to it; for Venice then,
        // and again as Cloak starts, the way new chats pay changes, or the
        // wallet is made.
        .task(id: venice) {
            if kind == .token, !venice { await wallet.refresh() }
        }
        .task(id: VeniceRead(shown: venice, running: running, pays: settings.venicePays, wallet: wallet.presence.address)) {
            if venice { await veniceMode.refresh(wallet: wallet.presence.address) }
        }
    }
}

/// What reading Venice for the sheet follows.
private struct VeniceRead: Equatable {
    let shown: Bool
    let running: Bool
    let pays: VeniceChat.Pays
    let wallet: String?
}

/// Who answers Token Inference chats: Boundless, or Venice. Chosen here for
/// new chats (`AppSettings.provider`); a started chat's shows, fixed.
private struct ProviderPicker: View {
    @Bindable var settings: AppSettings
    /// A started chat's provider.
    let fixed: Provider?

    var body: some View {
        Section {
            Picker("Provider", selection: fixed.map { Binding.constant($0) } ?? $settings.provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .disabled(fixed != nil)
            .help(fixed == nil ? "Who answers new Token Inference chats." : "Each chat keeps the provider it started with.")
        }
    }
}

/// Venice's part of the sheet, in place of Boundless's: how new Venice chats
/// pay, and what that has to spend, then the model they go to. A started
/// chat shows its own way to pay and model, fixed. Paid with the wallet,
/// Cloak's one wallet shows (`WalletSections`), with its USDC on Base and
/// the credit it bought at Venice.
private struct VeniceSections: View {
    let mode: VeniceMode
    let wallet: Wallet
    @Bindable var settings: AppSettings
    let chat: VeniceChat?
    let running: Bool
    let openSettings: () -> Void

    var body: some View {
        let pays = chat?.pays ?? settings.venicePays
        Section {
            Picker("Pay with", selection: chat.map { Binding.constant($0.pays) } ?? $settings.venicePays) {
                ForEach(VeniceChat.Pays.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(chat != nil)
            .help("How new Venice chats pay. Each chat keeps the way it started with.")
            if pays == .key {
                VeniceKeyRows(mode: mode, running: running, openSettings: openSettings)
                if let stop = mode.accountStop {
                    Text(stop.kind.words)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Venice")
        } footer: {
            if pays == .key {
                Text("Paid from your Venice account at [venice.ai/settings/api](https://venice.ai/settings/api).")
                    .foregroundStyle(.secondary)
            }
        }
        if pays == .wallet {
            WalletSections(wallet: wallet, running: running, venice: mode)
        }
        VeniceModels(mode: mode, settings: settings, chat: chat, running: running)
    }
}

/// The owner's Venice key: whether one is saved, the way to Settings'
/// Venice pane, and what it has to spend.
private struct VeniceKeyRows: View {
    let mode: VeniceMode
    let running: Bool
    let openSettings: () -> Void

    var body: some View {
        LabeledContent("Key") {
            HStack(spacing: 4) {
                Text(key)
                SymbolButton("Open Settings", symbol: "gearshape", action: openSettings)
                    .overhanging()
            }
        }
        LabeledContent("Balance") {
            if let usd = mode.keyAccount?.usd {
                Text(usd.dollars)
            } else {
                Unread(running: running, what: "balance")
            }
        }
        if let diem = mode.keyAccount?.diem, diem > 0 {
            LabeledContent {
                Text(diem.formatted(.number.precision(.fractionLength(0...4))))
            } label: {
                Text("DIEM")
                    .help("Venice's DIEM allowance on this key.")
            }
        }
    }

    private var key: String {
        switch mode.hasKey {
        case true?: "Saved"
        case false?: "None"
        case nil: mode.keyFailed ? "Couldn't check" : "Checking…"
        }
    }
}

/// The wallet's USDC on Base, read at the latest block, at its one address:
/// what to send it for Venice, and what is there.
private struct VeniceFunds: View {
    let mode: VeniceMode
    let running: Bool

    var body: some View {
        LabeledContent("Token", value: "USDC on Base")
        LabeledContent("Balance") {
            if let funds = mode.funds {
                Text(funds.usdc)
            } else if mode.fundsFailed {
                Text("Couldn't read")
                    .foregroundStyle(.secondary)
            } else {
                Unread(running: running, what: "wallet balance")
            }
        }
    }
}

/// What the wallet has bought at Venice, as Venice last showed it, and a
/// top-up from its USDC on Base. Add is off only while Cloak is not running,
/// since the wallet signs in the guest, and while the wallet's USDC on Base,
/// read at the latest block, is below the amount. Each press signs and pays.
private struct VeniceCredit: View {
    let mode: VeniceMode
    let address: String
    let running: Bool

    var body: some View {
        Section("Credit") {
            LabeledContent("Balance") {
                if let usd = mode.credit?.usd {
                    Text(usd.dollars)
                } else {
                    Unread(running: running, what: "credit")
                }
            }
            if let stop = mode.accountStop {
                Text(stop.kind.words)
                    .foregroundStyle(.secondary)
            }
            TopUp(mode: mode, address: address, running: running)
        }
    }
}

/// The amount to add, in dollars, starting at Venice's least, and Add. The
/// amount is checked as Add is pressed; each press is one payment of exactly
/// it, from the wallet at `address`.
private struct TopUp: View {
    let mode: VeniceMode
    let address: String
    let running: Bool
    /// As typed; nil until it is, so the field shows Venice's least.
    @State private var typed: String?
    @State private var wrong = false

    var body: some View {
        let least = mode.terms?.least.plain
        let text = typed ?? least ?? ""
        let lacking = Amount(dollars: text)?.lacking(in: mode.funds)
        LabeledContent("Amount") {
            HStack(spacing: 4) {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Amount", text: Binding(get: { text }, set: { typed = $0; wrong = false }), prompt: Text(least ?? "5"))
                    .labelsHidden()
                    .fixedSize()
                    .onSubmit { add(text) }
                Button("Add") { add(text) }
                    .disabled(!running || lacking != nil)
            }
        }
        if wrong {
            Text("Enter an amount in dollars, like 5.")
                .foregroundStyle(.red)
        } else if let lacking {
            Text("Needs \(lacking.dollars.dollars) more on Base.")
                .foregroundStyle(.secondary)
        } else if !running {
            Text("Start Cloak to use the wallet.")
                .foregroundStyle(.secondary)
        }
        Text((mode.terms.map { "Venice's least is \($0.least.dollars.dollars). " } ?? "") + "Venice keeps what you add; it can't be sent back.")
            .foregroundStyle(.secondary)
        if let stop = mode.topUpStop {
            Text(stop.kind.words)
                .foregroundStyle(.orange)
            if stop.sent, stop.kind == .unreachable || stop.kind == .failed {
                Text("The payment may have gone through. Check Credit before adding again.")
                    .foregroundStyle(.secondary)
            }
        } else if let added = mode.added {
            Text("Added \(added.credited.dollars).")
                .foregroundStyle(.secondary)
        }
    }

    /// One press: one payment of exactly the amount typed, unless it is not
    /// an amount.
    private func add(_ text: String) {
        guard let amount = Amount(dollars: text) else {
            wrong = true
            return
        }
        wrong = false
        Task { await mode.add(amount, from: address) }
    }
}

/// The model new Venice chats go to, grouped by Venice's tier, TEE first,
/// each with its prices; Anonymous only with All tiers on, and none Venice
/// may answer for from another. One offline is dimmed and can't be chosen.
/// The chosen one's tier is its own row, a capsule with what the tier means
/// as its help. A started chat shows its own model, fixed.
private struct VeniceModels: View {
    let mode: VeniceMode
    @Bindable var settings: AppSettings
    let chat: VeniceChat?
    let running: Bool

    var body: some View {
        Section {
            if let chat {
                LabeledContent("Model", value: mode.models?.first { $0.id == chat.model }?.name ?? chat.model)
                LabeledContent("Tier") { TierPill(tier: chat.tier) }
            } else if mode.models != nil {
                let offered = mode.offered
                Picker("Model", selection: Binding(get: { mode.choice }, set: { settings.veniceModel = $0 })) {
                    Text("None").tag(VeniceChoice?.none)
                    ForEach(VeniceTier.allCases.reversed(), id: \.self) { tier in
                        let listed = offered.filter { $0.tier == tier }
                        if !listed.isEmpty {
                            Section(tier.name) {
                                ForEach(listed) { model in
                                    Text(model.offline ? "\(model.name): Offline at Venice." : "\(model.name): \(model.input.price) | \(model.output.price)")
                                        .accessibilityLabel(
                                            model.offline ? "\(model.name), offline at Venice" : "\(model.name), \(model.input.price) in, \(model.output.price) out")
                                        .tag(VeniceChoice?.some(VeniceChoice(model: model.id, tier: model.tier)))
                                        .disabled(model.offline)
                                }
                            }
                        }
                    }
                }
                .help("Prices per million tokens: in | out.")
                .accessibilityHint("Prices per million tokens, in and out.")
                if let choice = mode.choice {
                    LabeledContent("Tier") { TierPill(tier: choice.tier) }
                }
            } else if mode.listStop != nil {
                Text("Cloak couldn't read Venice's models.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Try Again") { Task { await mode.readModels() } }
                        .disabled(!running)
                }
            } else if !running {
                Text("Start Cloak to see Venice's models.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A Venice tier in Venice's word, in a capsule, with what it means as its
/// help.
private struct TierPill: View {
    let tier: VeniceTier

    var body: some View {
        ModePill(title: tier.name, help: tier.about, tint: .gray)
    }
}

/// The wallet that pays for Token Inference chats, Agent on or off: for
/// Boundless, its USDC.e on Tempo, the deposit and the model chats go to;
/// for Venice (`venice`), at the same address, its USDC on Base and the
/// credit it bought at Venice.
private struct WalletSections: View {
    let wallet: Wallet
    let running: Bool
    /// Venice's, when the wallet is shown paying Venice.
    let venice: VeniceMode?

    var body: some View {
        if !running {
            Section {
                Text("Start Cloak to use the wallet.")
                    .foregroundStyle(.secondary)
            }
        }
        // A read on Tempo that stopped says nothing of Venice.
        if let stop = wallet.stop ?? (venice == nil ? wallet.readStop : nil) {
            Section {
                StopRow(stop: stop) { wallet.dismiss() }
            }
        }
        switch wallet.presence {
        case .looking:
            ProgressView()
                .frame(maxWidth: .infinity)
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
            Account(wallet: wallet, address: address, running: running, venice: venice)
            if let venice {
                VeniceCredit(mode: venice, address: address, running: running)
            } else {
                Holding(wallet: wallet, running: running)
                Models(wallet: wallet)
            }
        case .absent, .creating:
            Section {
                Text("Cloak makes one wallet on this Mac. You add funds to it, and it pays for each chat you send.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Create") { Task { await wallet.create() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(wallet.presence == .creating || !running)
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
            .help(why)
            .accessibilityLabel(why)
    }
}

/// How a NEAR Private AI chat is paid for: the owner's own key from NEAR AI
/// Cloud, whether one is saved, asked of the keychain as the NEAR pane asks
/// it (never the key itself), with the way to that pane beside it; and,
/// once NEAR has counted any of its answers, the chat's tokens in and out,
/// added up. Counts only, never a price.
private struct NearPayment: View {
    let mode: NearMode
    /// The chat's, added up; nil while no answer has counts.
    let tokens: Tokens?
    let openSettings: () -> Void

    var body: some View {
        Section {
            LabeledContent("Key") {
                HStack(spacing: 4) {
                    Text(key)
                    SymbolButton("Open Settings", symbol: "gearshape", action: openSettings)
                        .overhanging()
                }
            }
            if let tokens {
                LabeledContent("Tokens", value: String(localized: "\(tokens.input) in, \(tokens.output) out"))
            }
        } footer: {
            Text("Paid with your NEAR key from [cloud.near.ai](https://cloud.near.ai).")
                .foregroundStyle(.secondary)
        }
        .task { await mode.find() }
    }

    private var key: String {
        switch mode.hasKey {
        case true?: "Saved"
        case false?: "Not saved"
        case nil: mode.keyFailed ? "Couldn't check" : "Checking…"
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

/// Where to add funds, and what is there: USDC.e on Tempo for Boundless, or,
/// at the same address, USDC on Base for Venice (`venice`).
private struct Account: View {
    let wallet: Wallet
    let address: String
    let running: Bool
    let venice: VeniceMode?

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
                    CodeButton(address: address)
                }
            }
            if let venice {
                VeniceFunds(mode: venice, running: running)
            } else {
                LabeledContent("Token") {
                    HStack(spacing: 4) {
                        Text("USDC.e on Tempo")
                        BoundlessTempoButton()
                    }
                }
                if let look = wallet.look {
                    if !look.setup {
                        Label("The provider no longer names USDC.e on Tempo. Don't add funds.", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    LabeledContent("Balance", value: look.balance.text)
                    if wallet.lacksFunds {
                        Text("Add at least \(look.least.text) to send.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Balance") { Unread(running: running, what: "wallet balance") }
                }
            }
        } header: {
            Text("Wallet")
        } footer: {
            if venice != nil {
                Text(Chat.Kind.oneAddress)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The address as a QR code, for a phone's wallet to scan, in a popover
/// from the button beside Copy, with the address in full under it to check
/// against. Shown only.
struct CodeButton: View {
    let address: String
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
        .help("Show QR Code")
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
/// it holds, and the two ways to end it, side by side at the right. What
/// each does is its help; why one is off is beside them.
private struct Holding: View {
    let wallet: Wallet
    let running: Bool

    var body: some View {
        let look = wallet.look
        // A deposit the network shows closed is already forgotten.
        let deposit = look?.deposit.flatMap { $0.gone == true ? nil : $0 }
        let none = look != nil && deposit == nil
        Section("Deposit") {
            LabeledContent("Held") {
                if let deposit {
                    Text("\(deposit.deposit.text), \(deposit.spent.text) spent")
                } else if none {
                    Text("None")
                } else {
                    Unread(running: running, what: "deposit")
                }
            }
            TimelineView(.everyMinute) { context in
                let wait = deposit?.withdrawAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let waiting = wait.map { context.date < $0 } ?? false
                let withdraw = wait == nil
                    ? "Without the provider: asks the network to close it, then takes it back 15 minutes later."
                    : "Takes it back now."
                HStack {
                    if none {
                        Text("Nothing to refund.")
                            .foregroundStyle(.secondary)
                    } else if waiting, let wait {
                        Text("Ready at \(wait.formatted(date: .omitted, time: .shortened)).")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close") { Task { await wallet.close() } }
                        .disabled(!running || none)
                        .help("Refunds what's unspent.")
                        .accessibilityHint("Refunds what's unspent.")
                    Button("Withdraw") { Task { await wallet.withdraw() } }
                        .disabled(!running || none || waiting)
                        .help(withdraw)
                        .accessibilityHint(withdraw)
                }
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
            .help("Prices per million tokens: in | out.")
            .accessibilityHint("Prices per million tokens, in and out.")
        }
    }
}

/// A mode's name in a capsule of its colour, with what it means for the
/// person as its help and as what VoiceOver reads after the name.
struct ModePill: View {
    let title: String
    let help: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.2), in: Capsule())
            .help(help)
            .accessibilityHint(help)
    }
}

/// V's mark, with what it means for the person as its help.
struct VBar: View {
    var body: some View {
        HStack {
            ModePill(
                title: "V", help: "Reworded on this Mac and sent through Tor. Each request is paid with a new key.",
                tint: .accentColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }
}

/// Token Inference's mark, with what it means for the person as its help;
/// in a Venice chat, beside it, Venice and the chat's tier in Venice's word,
/// with what the tier means as its help.
struct TokenBar: View {
    let venice: Bool
    /// The Venice chat's, or the chosen model's for a new one.
    let tier: VeniceTier?

    var body: some View {
        HStack(spacing: 6) {
            ModePill(title: "Token Inference", help: venice ? Chat.Kind.veniceLink : Chat.Kind.tokenLink, tint: .orange)
            if venice {
                ModePill(title: tier.map { "Venice \($0.name)" } ?? "Venice", help: tier?.about ?? "Choose a model in the Wallet.", tint: .gray)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.06))
    }
}

/// Why a request stopped, in plain words.
struct StopRow: View {
    let stop: RemoteStop
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
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .help("Dismiss")
        }
    }
}

extension RemoteStop {
    var title: String {
        switch code {
        case .noFunds: "No funds"
        case .walletRefused: "Wallet refused"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor down"
        case .answerRefused: "No answer"
        case .failed: "Failed"
        case .unreachable: "Not running"
        }
    }

    var words: String {
        switch code {
        case .noFunds: "Add USDC.e on Tempo to the wallet, then try again."
        case .walletRefused: "The provider turned this wallet away."
        case .modelUnavailable: "This model can't be used now. Pick another in Wallet."
        case .torDown: "Cloak couldn't reach the network through Tor. Try again."
        case .answerRefused: "The model declined to answer."
        case .failed: "The request did not go through. Try again."
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

extension Amount {
    /// "1.00 USDC", for USDC on Base.
    fileprivate var usdc: String {
        "\(dollars.formatted(.number.precision(.fractionLength(2...6)))) USDC"
    }

    /// "5", "7.5": dollars as a field takes them.
    fileprivate var plain: String {
        dollars.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}

extension Double {
    /// "$0.27"
    fileprivate var price: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}

extension Decimal {
    /// "$0.27"
    fileprivate var price: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }

    /// "$7.50"
    fileprivate var dollars: String {
        formatted(.currency(code: "USD"))
    }
}

extension VeniceChat.Pays {
    var title: String {
        switch self {
        case .key: "Key"
        case .wallet: "Wallet"
        }
    }
}
