import AppKit
import CloakChat
import SwiftUI

/// V's wallet, in the Wallet sheet of a V chat (docs/zkapi-mac-side.md,
/// section 3): the payer's Ethereum address to send ETH to, the deposit
/// each request is paid from with a new key, and the model V chats go to.
/// Every figure is the payer's, in ETH; the one figure in dollars is the
/// amount its owner asked to deposit. Deposit, Withdraw and Send Out each
/// ask the payer for a quote and show it; the review's button is the one
/// place an approve is sent from. A money button is off only where the
/// chain at the latest block read shows its request certain to fail, with
/// why beside it; never for a press under way, and every press is sent.
struct VWallet: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    let running: Bool

    var body: some View {
        if !running {
            Section {
                Text("Start Cloak to use the wallet.")
                    .foregroundStyle(.secondary)
            }
        }
        if let stop = payer.stop ?? payer.readStop {
            Section {
                PayStopRow(stop: stop, dismiss: payer.dismiss)
            }
        }
        if let review = payer.review {
            ReviewSection(payer: payer, review: review)
        }
        switch payer.state {
        case .unread:
            if running {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .failed(let fault):
            Section {
                Failed(payer: payer, fault: fault)
            }
        default:
            if let funding = payer.funding {
                AddressSection(payer: payer, funding: funding)
            }
            DepositSection(payer: payer)
            ModelSection(payer: payer, settings: settings)
        }
    }
}

/// The payer's own address on Ethereum, to send ETH to, as Copy and a QR
/// code; the ETH there now; and Send Out…, which sends all of it to an
/// address typed in.
private struct AddressSection: View {
    let payer: Payer
    let funding: FundingStatus

    var body: some View {
        Section("Address") {
            LabeledContent("Address") {
                HStack(spacing: 4) {
                    Text(funding.address)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(text: funding.address)
                    CodeButton(address: funding.address)
                }
            }
            LabeledContent("Network", value: "Ethereum")
            LabeledContent("Asset", value: "ETH")
            LabeledContent("On hand", value: Ether.text(wei: funding.ethBalance) ?? "—")
            if let returning = payer.returning, returning.phase == "return_pending" {
                LabeledContent("Sending") {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        if let hash = returning.transactionHash {
                            Hash(hash)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if let block = payer.sendOutBlock {
                    Text(block.words)
                        .foregroundStyle(.secondary)
                }
                SendOutButton(payer: payer)
                    .disabled(payer.sendOutBlock != nil)
            }
        }
    }
}

/// Send Out…: an address typed in a popover, checked as Ethereum's when
/// Review is pressed, and the payer's quote for sending all of the
/// address's ETH there.
private struct SendOutButton: View {
    let payer: Payer
    @State private var open = false
    @State private var destination = ""
    @State private var wrong = false

    var body: some View {
        Button("Send Out…") { open = true }
            .help("Sends all the ETH on hand to an address you type.")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("To", text: $destination, prompt: Text("0x…"))
                        .font(.body.monospaced())
                        .frame(width: 360)
                        .onSubmit(review)
                    if wrong {
                        Text("Enter an Ethereum address: 0x and 40 characters.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Review", action: review)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
    }

    private func review() {
        let typed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else {
            wrong = true
            return
        }
        wrong = false
        open = false
        Task { await payer.quoteSendOut(to: typed) }
    }
}

/// The deposit, as the payer and the chain show it: none, with the amount
/// to deposit; on its way; held, with its balance, its expiry and
/// Withdraw; being withdrawn; closed on the chain.
private struct DepositSection: View {
    let payer: Payer

    var body: some View {
        Section("Deposit") {
            switch payer.state {
            case .none:
                Amount(payer: payer)
            case .depositing(let stage):
                Moving(symbol: "arrow.down.circle", title: "Depositing", help: Self.stage(stage), hash: payer.funding?.transactionHash)
            case .ready, .settling:
                Held(payer: payer)
                Amount(payer: payer)
            case .withdrawing(let phase):
                Moving(
                    symbol: "arrow.up.circle", title: "Withdrawing", help: Self.phase(phase),
                    hash: payer.withdrawal?.transactionHash)
                if let destination = payer.withdrawal?.destination {
                    LabeledContent("To") {
                        Text(destination)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                // Signed again only from a new quote.
                if ["quoted", "waiting_settlement", "waiting_funds"].contains(phase) {
                    WithdrawRow(payer: payer, prominent: true)
                }
            case .taken:
                Text("This deposit was closed on the chain.")
                    .foregroundStyle(.secondary)
            case .unread, .failed:
                EmptyView()
            }
        }
    }

    private static func stage(_ stage: String) -> String {
        switch stage {
        case "fee_wait": "Waiting for ETH for the fee."
        case "finalizing": "Waiting for the chain to finalize it."
        case "activating": "Opening it with the service."
        default: "Sent. Waiting for the chain."
        }
    }

    private static func phase(_ phase: String) -> String {
        switch phase {
        case "waiting_settlement": "Waiting for the last request to settle."
        case "waiting_funds": "Waiting for ETH for the fee."
        case "confirming": "Confirming with the service."
        case "withdrawal_pending": "Sent. Waiting for the chain."
        default: "Quoted. Review it to withdraw."
        }
    }
}

/// A deposit or a withdrawal on its way: its symbol and title, its stage as
/// the help, and its transaction once there is one.
private struct Moving: View {
    let symbol: String
    let title: String
    let help: String
    let hash: String?

    var body: some View {
        LabeledContent {
            if let hash {
                Hash(hash)
            }
        } label: {
            Label(title, systemImage: symbol)
                .help(help)
                .accessibilityHint(help)
        }
    }
}

/// The deposit held: its balance, whether a request is out or settling,
/// its expiry with the warning when it is near or past, and Withdraw.
private struct Held: View {
    let payer: Payer

    var body: some View {
        let queue = payer.queue
        let band = payer.band(at: .now)
        LabeledContent {
            if let balance = payer.withdrawal?.privateBalance {
                Text(Ether.text(gwei: balance))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        } label: {
            let (symbol, words) =
                if queue.held || (payer.state == .settling && !queue.sending) {
                    ("clock", "Settling the last request.")
                } else if queue.sending {
                    ("arrow.up.circle", queue.waiting == 0 ? "1 sending" : "1 sending, \(queue.waiting) waiting")
                } else {
                    ("checkmark.circle", "Ready")
                }
            Label("Balance", systemImage: symbol)
                .help(words)
                .accessibilityValue(words)
        }
        if let expiry = payer.expiry {
            LabeledContent {
                Text(expiry.formatted(date: .abbreviated, time: .shortened))
            } label: {
                HStack(spacing: 2) {
                    Text("Expires")
                    InfoButton("About Expiry", note: "After this day anyone can send this deposit to the service's operator, spent or not.")
                }
            }
            switch band {
            case .near?:
                Label("Expires \(expiry.formatted(.dateTime.day().month())). Withdraw before then.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .due?:
                Label("Can be taken now.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            case .far?, nil:
                EmptyView()
            }
        }
        WithdrawRow(payer: payer, prominent: band == .near || band == .due)
    }
}

/// Withdraw: the whole deposit, to the payer's own address. Prominent when
/// the expiry is near or past.
private struct WithdrawRow: View {
    let payer: Payer
    let prominent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if let block = payer.withdrawBlock {
                Text(block.words)
                    .foregroundStyle(.secondary)
            }
            let withdraw = Button("Withdraw") { Task { await payer.quoteWithdrawal() } }
                .help("Brings the whole deposit back to the address above.")
                .disabled(payer.withdrawBlock != nil)
            if prominent {
                withdraw.buttonStyle(.borderedProminent)
            } else {
                withdraw
            }
        }
    }
}

/// The amount to deposit, in dollars, which the payer prices in ETH, and
/// Deposit, which asks it for the quote. The amount is checked as Deposit
/// is pressed.
private struct Amount: View {
    let payer: Payer
    @State private var text = ""
    @State private var wrong = false

    var body: some View {
        let dollars = Self.dollars(text)
        LabeledContent("Amount") {
            HStack(spacing: 4) {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Amount", text: $text, prompt: Text("20"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .onSubmit(deposit)
            }
        }
        if wrong {
            Text("Enter an amount in dollars, like 20.")
                .foregroundStyle(.red)
        } else if let dollars, dollars > 50 {
            Text("Over $50. Deposit only what you'll spend.")
                .foregroundStyle(.orange)
        }
        HStack(spacing: 8) {
            Spacer()
            if let block = payer.depositBlock {
                Text(block.words)
                    .foregroundStyle(.secondary)
            }
            Button("Deposit", action: deposit)
                .help("Shows what the deposit costs in ETH before anything is sent.")
                .disabled(payer.depositBlock != nil)
        }
    }

    private func deposit() {
        guard let dollars = Self.dollars(text), dollars > 0 else {
            wrong = true
            return
        }
        wrong = false
        var micro = dollars * 1_000_000
        var whole = Decimal()
        NSDecimalRound(&whole, &micro, 0, .plain)
        let microUSD = NSDecimalNumber(decimal: whole).uint64Value
        Task { await payer.quoteDeposit(microUSD: microUSD) }
    }

    /// The dollars typed, with or without a dollar sign; nil when they do not
    /// read.
    private static func dollars(_ text: String) -> Decimal? {
        let typed = text.trimmingCharacters(in: .whitespaces).replacing("$", with: "")
        guard typed.wholeMatch(of: /[0-9]+(\.[0-9]{0,6})?/) != nil else { return nil }
        return Decimal(string: typed, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// A quote, as the payer made it, for its owner to confirm: what it sends,
/// where, the most it pays in fees, and how long it holds. Its button is the
/// one place an approve is sent from; once the quote has expired, the
/// button asks for a new one, shown before anything is approved.
private struct ReviewSection: View {
    let payer: Payer
    let review: Payer.Review

    var body: some View {
        let quote = review.quote
        Section("Review") {
            switch review {
            case .deposit(_, let microUSD):
                LabeledContent("Amount") {
                    Text((Decimal(quote.inputMicroUsd ?? microUSD) / 1_000_000).formatted(.currency(code: "USD")))
                }
                LabeledContent("Deposit", value: Ether.text(wei: quote.principalWei) ?? "—")
            case .withdrawal:
                LabeledContent("Amount", value: Ether.text(gwei: quote.amount))
            case .sendOut:
                LabeledContent("Amount", value: Ether.text(wei: quote.principalWei) ?? "—")
            }
            if let destination = quote.destination {
                LabeledContent("To") {
                    Text(destination)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Fee", value: Ether.text(wei: quote.requiredFeeWei).map { "Up to \($0)" } ?? "—")
            LabeledContent("Total", value: Ether.text(wei: quote.requiredTotalWei) ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = quote.expired(at: context.date)
                let block = payer.confirmBlock(review)
                HStack(spacing: 8) {
                    if !expired {
                        Text(quote.expires, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("The quote holds until this runs out.")
                    }
                    Spacer()
                    if let block {
                        Text(block.words)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", action: payer.cancelReview)
                    Button(expired ? "New Quote" : title) { Task { await payer.confirm() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!expired && block != nil)
                }
            }
        }
    }

    private var title: String {
        switch review {
        case .deposit: "Deposit"
        case .withdrawal: "Withdraw"
        case .sendOut: "Send"
        }
    }
}

/// A phase or stage the Mac does not go on from: a triangle, a word, what
/// the payer named it on demand, and Try Again, which reads again and
/// makes the follow calls the payer allows.
private struct Failed: View {
    let payer: Payer
    let fault: String

    var body: some View {
        HStack(spacing: 8) {
            Label("Stopped", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .help(fault)
                .accessibilityValue(fault)
            Spacer()
            Button("Try Again") { Task { await payer.retry() } }
        }
    }
}

/// The model V chats go to, from the service's list, each with the most one
/// request to it may cost. The choice is kept in Settings' defaults.
private struct ModelSection: View {
    let payer: Payer
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            if let models = payer.models, let model = payer.model {
                Picker("Model", selection: Binding(get: { model }, set: { settings.vModel = $0 })) {
                    ForEach(models) { model in
                        Text("\(model.id), up to \(Self.dollars(model.cap)) a request")
                            .tag(model.id)
                    }
                }
            } else {
                LabeledContent("Model") {
                    if payer.models == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("None listed")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: payer.state == .unread) {
            guard payer.state != .unread else { return }
            try? await payer.loadModels()
        }
    }

    private static func dollars(_ micro: UInt64) -> String {
        (Decimal(micro) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}

/// A transaction's hash, shortened, with Copy.
private struct Hash: View {
    let hash: String

    init(_ hash: String) {
        self.hash = hash
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(hash)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
                .textSelection(.enabled)
            CopyButton(text: hash)
        }
    }
}

/// Copy, as a symbol: puts `text` on the pasteboard.
struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            // A larger target than the icon alone.
            Label("Copy", systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .help("Copy")
    }
}

/// Why a request to V's payer stopped, in plain words. A chat request with
/// no deposit says to deposit, with the way to the wallet.
struct PayStopRow: View {
    let stop: PayStop
    /// What the stopped request was to do: send or run.
    var verb = "send"
    var showWallet: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if stop.code == .noDeposit {
                    Text("Deposit to \(verb).")
                        .fontWeight(.medium)
                } else {
                    Text(stop.title)
                        .fontWeight(.medium)
                    Text(stop.words)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if stop.code == .noDeposit, let showWallet {
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

extension PayStop {
    var title: String {
        switch code {
        case .unreachable: "Not reached"
        case .noDeposit: "No deposit"
        case .withdrawing: "Withdrawing"
        case .busy: "Busy"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor down"
        case .refused: "Refused"
        case .providerFailed: "Failed"
        case .answerRefused: "No answer"
        case .heldTooLong: "Settling"
        case .timedOut: "No answer"
        case .ended: "Interrupted"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        }
    }

    var words: String {
        switch code {
        case .unreachable: "Cloak couldn't reach V's wallet. Pause and start Cloak, then try again."
        case .noDeposit: "Make a deposit in Wallet, then try again."
        case .withdrawing: "The deposit is being withdrawn, so it can't pay for requests now."
        case .busy: "V's wallet is busy with another request. Try again."
        case .modelUnavailable: "The service can't use this model now. Pick another in Wallet."
        case .torDown: "Cloak couldn't reach the service through Tor. Try again."
        case .refused: "The service turned the request away as it was."
        case .providerFailed: "The provider failed. The request may have been paid for."
        case .answerRefused: "The model declined to answer."
        case .heldTooLong: "The last request is still settling, so nothing was sent. Try again in a minute."
        case .timedOut: "No answer came in time. The request may have been paid for."
        case .ended: "The connection ended before the answer. The request may have been paid for."
        case .cancelled: "The request was stopped."
        case .failed: "V's wallet couldn't finish this. Try again."
        }
    }
}

extension Payer.Block {
    var words: String {
        switch self {
        case .paused: "Paused by operator"
        case .oneAtATime: "One deposit at a time"
        case .nothingToWithdraw: "Nothing to withdraw"
        case .needs(let wei): "Needs \(Ether.text(Decimal(sign: .plus, exponent: -18, significand: wei), up: true)) more"
        case .needsFee: "Needs ETH for the fee"
        case .nothingToSend: "Nothing to send"
        }
    }
}

/// Amounts of ETH as the payer gives them, in wei or gwei, written in ETH.
enum Ether {
    /// "0.0123 ETH", from wei as a decimal string; nil when it does not read.
    static func text(wei: String) -> String? {
        guard let wei = Decimal(string: wei, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return text(Decimal(sign: .plus, exponent: -18, significand: wei))
    }

    static func text(gwei: UInt64) -> String {
        text(Decimal(sign: .plus, exponent: -9, significand: Decimal(gwei)))
    }

    /// Up to six decimals, rounded up when `up`, for an amount still needed.
    static func text(_ eth: Decimal, up: Bool = false) -> String {
        let format = Decimal.FormatStyle.number.precision(.fractionLength(0...6))
        return "\(eth.formatted(up ? format.rounded(rule: .up) : format)) ETH"
    }
}
