import AppKit
import CloakChat
import CloakSupervisor
import CoreImage.CIFilterBuiltins
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
    @Bindable var wallet: Wallet
    let payer: Payer
    let settings: AppSettings
    let nearMode: NearMode
    /// The conversation in front's.
    let kind: Chat.Kind
    /// The tokens NEAR counted for the conversation in front's answers,
    /// added up; nil while none has counts, as in every other mode.
    let tokens: Tokens?
    let showDetails: () -> Void
    let showNearSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let running = wallet.supervisor.phase == .running
        VStack(spacing: 0) {
            switch kind {
            case .v: VBar()
            case .token: TokenBar()
            case .near, .llama: EmptyView()
            }
            Form {
                if kind == .v || kind == .token, !running {
                    Section {
                        StartRow(supervisor: wallet.supervisor) {
                            dismiss()
                            showDetails()
                        }
                    }
                }
                switch kind {
                case .v:
                    VWallet(payer: payer, settings: settings, running: running)
                case .token:
                    WalletSections(wallet: wallet, running: running)
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
                if kind == .token, wallet.working > 0 || wallet.presence == .creating {
                    ProgressView()
                        .controlSize(.small)
                }
                if kind == .v, payer.working > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                // Only while there is something to read again.
                switch kind {
                case .v where running:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { payer.follow() }
                case .token where running && wallet.presence.address != nil:
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { Task { await wallet.refresh() } }
                case .v, .token, .near, .llama:
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
        // As it opens, and again when Cloak starts or stops under it.
        .task(id: running) {
            switch kind {
            case .v: payer.follow()
            case .token: await wallet.refresh()
            case .near, .llama: break
            }
        }
    }
}

/// In a wallet while Cloak is not running: Cloak's state in words and the
/// way on beside it. Start while paused or ready; a failure's fix (`Fix`),
/// or, with none, its remedy in words; a spinner while Cloak starts or
/// stops. The download of the model that rewords comes from the sheet's
/// environment.
struct StartRow: View {
    let supervisor: Supervisor
    let showDetails: () -> Void
    @Environment(ModelDownload.self) private var download

    var body: some View {
        let phase = supervisor.phase
        let fix = phase.reason.flatMap { Fix(for: $0, download: download) }
        HStack(spacing: 8) {
            Text(words(phase, fix: fix))
                .foregroundStyle(.secondary)
            Spacer()
            switch phase {
            case .needsAttention:
                switch fix {
                case .start?: Button(Fix.start.title) { supervisor.send(.start) }
                case .download(let underWay)?: Button(Fix.download(underWay: underWay).title, action: showDetails)
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

    private func words(_ phase: Phase, fix: Fix?) -> String {
        switch phase {
        case .paused: "Cloak is paused."
        case .ready: "Cloak isn't running."
        case .preparing: "Cloak is starting."
        case .stopping: "Cloak is stopping."
        case .needsAttention(let reason):
            switch fix {
            case .start?, .download?: reason.title
            // No button does it all, so the words say what to do.
            case .showModel?, nil: "\(reason.title) \(reason.remedy)"
            }
        case .running: "Cloak is running."
        }
    }
}

/// The wallet that pays for Token Inference chats, Agent on or off.
private struct WalletSections: View {
    let wallet: Wallet
    let running: Bool

    var body: some View {
        if let stop = wallet.stop ?? wallet.readStop {
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
                        Button("Create") { Task { await wallet.create() } }
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

/// Where to add funds, and what is there.
private struct Account: View {
    let wallet: Wallet
    let address: String
    let running: Bool

    var body: some View {
        Section("Wallet") {
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
            if running {
                ending(deposit, none: none)
            }
        }
    }

    /// Close and Withdraw, and why either is off.
    private func ending(_ deposit: Look.Deposit?, none: Bool) -> some View {
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
                    .disabled(none)
                    .help("Refunds what's unspent.")
                    .accessibilityHint("Refunds what's unspent.")
                Button("Withdraw") { Task { await wallet.withdraw() } }
                    .disabled(none || waiting)
                    .help(withdraw)
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

/// Token Inference's mark, with what it means for the person as its help.
struct TokenBar: View {
    var body: some View {
        HStack {
            ModePill(title: "Token Inference", help: "The provider can link your chats, because one wallet pays for all of them.", tint: .orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.06))
    }
}

/// Why a request stopped, in plain words. In a chat, one the wallet fixes
/// (no funds, or a model that can't be used) comes with the way there.
struct StopRow: View {
    let stop: RemoteStop
    var showWallet: (() -> Void)?
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
                Button("Wallet…", action: showWallet)
            }
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

extension Double {
    /// "$0.27"
    fileprivate var price: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}
