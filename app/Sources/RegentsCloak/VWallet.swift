import AppKit
import CloakChat
import SwiftUI

/// V's wallet, in the Wallet sheet of a V chat (docs/zkapi-mac-side.md,
/// section 3): the payer's Ethereum address to send ETH to, the deposit
/// each request is paid from with a new key, and the model V chats go to.
/// Every figure is the payer's, in ETH; the one figure in dollars is the
/// amount its owner asked to deposit. Deposit, Withdraw and Transfer each
/// ask the payer for a quote and show it where the press was made, in
/// place of the button pressed; the review's button is the one place an
/// approve is sent from. A money button is off only where the chain at the
/// latest block read shows its request certain to fail, with why beside it;
/// never for a press under way, and every press is sent. While Cloak is not
/// running, nothing is read and none of this shows: the sheet's `StartRow`
/// is the way on.
struct VWallet: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    let running: Bool

    var body: some View {
        if let stop = payer.stop {
            Section {
                PressStopRow(payer: payer, stop: stop)
            }
        } else if let stop = payer.readStop {
            Section {
                ReadStopRow(payer: payer, stop: stop)
            }
        }
        switch payer.state {
        case .unread:
            // Until a read stops; then its row says why, with Try Again.
            if running, payer.readStop == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .failed(let fault):
            Section {
                Failed(payer: payer, fault: fault)
            }
            // The ETH on the address can still be seen and sent out.
            if let funding = payer.funding {
                AddressSection(payer: payer, funding: funding)
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
/// code, with what alone may be sent to it; the ETH there now; and
/// Transfer…, which sends an amount of it to an address, both typed in, or
/// its quote under review.
private struct AddressSection: View {
    let payer: Payer
    let funding: FundingStatus
    /// The payer reads and sends ETH on Ethereum Mainnet and nothing else,
    /// and its key never leaves the guest.
    private static let only = "Send only ETH on Ethereum Mainnet. Cloak can't return anything else sent to this address."

    var body: some View {
        Section("Wallet") {
            LabeledContent("Address") {
                HStack(spacing: 4) {
                    Text(funding.address)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(text: funding.address)
                    CodeButton(address: funding.address, only: Self.only)
                }
            }
            LabeledContent("Network", value: "Ethereum Mainnet")
            LabeledContent("Asset", value: "ETH")
            Only(words: Self.only)
            LabeledContent("Balance", value: Ether.text(wei: funding.ethBalance) ?? "—")
            if let returning = payer.returning, returning.phase == "return_pending" {
                LabeledContent("Pending") {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        if let hash = returning.transactionHash {
                            Hash(hash)
                        }
                    }
                }
            }
            if let review = payer.review, case .transfer = review {
                ReviewRows(payer: payer, review: review)
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    if let block = payer.transferBlock {
                        Text(block.words)
                            .foregroundStyle(.secondary)
                    }
                    TransferButton(payer: payer, balance: funding.ethBalance)
                        .disabled(payer.transferBlock != nil)
                }
            }
        }
    }
}

/// Transfer…: an address and an amount in ETH typed in a popover, checked
/// when Review is pressed, and the payer's quote for sending that much
/// there. Max types the whole balance, and the whole balance, typed or
/// from Max, asks for all of it less the fee, which the review shows: no
/// transfer can send all of an address's ETH and pay a fee on top.
private struct TransferButton: View {
    let payer: Payer
    /// The address's ETH, in wei as a decimal string.
    let balance: String
    @State private var open = false
    @State private var destination = ""
    @State private var amount = ""
    @State private var wrong: Wrong?

    private enum Wrong: String {
        case address = "Enter an Ethereum address: 0x and 40 characters."
        case amount = "Enter an amount in ETH, such as 0.005."
        case tooMuch = "That's more than the balance."
    }

    var body: some View {
        Button("Transfer…") { open = true }
            .tip("Sends ETH from this wallet to an address you type.")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("To")
                            TextField("To", text: $destination, prompt: Text("0x…"))
                                .font(.body.monospaced())
                                .frame(width: 360)
                        }
                        GridRow {
                            Text("Amount")
                            HStack(spacing: 8) {
                                TextField("Amount", text: $amount, prompt: Text("0.0"))
                                    .monospacedDigit()
                                    .frame(width: 160)
                                Text("ETH")
                                    .foregroundStyle(.secondary)
                                Button("Max") { amount = Ether.exact(wei: balance) ?? "" }
                                    .tip("All of the balance, less the fee.")
                            }
                        }
                    }
                    .labelsHidden()
                    .onSubmit(review)
                    if let wrong {
                        Text(wrong.rawValue)
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
        let to = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.wholeMatch(of: /0x[0-9a-fA-F]{40}/) != nil else {
            wrong = .address
            return
        }
        guard let wei = Ether.wei(eth: amount.trimmingCharacters(in: .whitespaces)) else {
            wrong = .amount
            return
        }
        let plain = Locale(identifier: "en_US_POSIX")
        if let asked = Decimal(string: wei, locale: plain), let held = Decimal(string: balance, locale: plain), asked > held {
            wrong = .tooMuch
            return
        }
        wrong = nil
        open = false
        Task { await payer.quoteTransfer(to: to, wei: wei == balance ? "" : wei) }
    }
}

/// The deposit, as the payer and the chain show it: none, with the amount
/// to deposit, and, while the address holds no ETH, that ETH comes first;
/// on its way; held, with its balance, its expiry and Withdraw; being
/// withdrawn; closed on the chain. A deposit's quote under review takes the
/// amount's place.
private struct DepositSection: View {
    let payer: Payer

    var body: some View {
        Section("Deposit") {
            switch payer.state {
            case .none:
                if payer.transferBlock == .nothingToTransfer {
                    Text("Deposits are paid in ETH from this wallet. Add ETH first; Deposit shows how much.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                amount
            case .depositing(let stage):
                Moving(symbol: "arrow.down.circle", title: "Depositing", help: Self.stage(stage), hash: payer.funding?.transactionHash)
            case .ready, .settling:
                Held(payer: payer)
                amount
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

    @ViewBuilder private var amount: some View {
        if let review = payer.review, case .deposit = review {
            ReviewRows(payer: payer, review: review)
        } else {
            Amount(payer: payer)
        }
    }

    private static func stage(_ stage: String) -> String {
        switch stage {
        case "fee_wait": "Waiting for ETH for the fee."
        case "finalizing": "Waiting for final confirmation."
        case "activating": "Activating the deposit."
        default: "Submitted. Waiting for confirmation."
        }
    }

    private static func phase(_ phase: String) -> String {
        switch phase {
        case "waiting_settlement": "Waiting for the last request to settle."
        case "waiting_funds": "Waiting for ETH for the fee."
        case "confirming": "Confirming with the service."
        case "withdrawal_pending": "Submitted. Waiting for confirmation."
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
                .tip(help)
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
                .tip(words)
                .accessibilityValue(words)
        }
        if let expiry = payer.expiry {
            LabeledContent {
                Text(expiry.formatted(date: .abbreviated, time: .shortened))
            } label: {
                HStack(spacing: 2) {
                    Text("Expires")
                    InfoButton("About Expiry", note: "After this date the service's operator can claim the deposit, spent or not. Withdraw before then.")
                }
            }
            switch band {
            case .near?:
                Label("Expires \(expiry.formatted(.dateTime.day().month())). Withdraw before then.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .due?:
                Label("Expired. Withdraw now.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            case .far?, nil:
                EmptyView()
            }
        }
        WithdrawRow(payer: payer, prominent: band == .near || band == .due)
    }
}

/// Withdraw: the whole deposit, to the payer's own address. Prominent when
/// the expiry is near or past. Its quote under review takes its place.
private struct WithdrawRow: View {
    let payer: Payer
    let prominent: Bool

    var body: some View {
        if let review = payer.review, case .withdrawal = review {
            ReviewRows(payer: payer, review: review)
        } else {
            HStack(spacing: 8) {
                Spacer()
                if let block = payer.withdrawBlock {
                    Text(block.words)
                        .foregroundStyle(.secondary)
                }
                let withdraw = Button("Withdraw") { Task { await payer.quoteWithdrawal() } }
                    .tip("Returns the whole deposit to this wallet.")
                    .disabled(payer.withdrawBlock != nil)
                if prominent {
                    withdraw.buttonStyle(.borderedProminent)
                } else {
                    withdraw
                }
            }
        }
    }
}

/// The amount to deposit, in dollars, which the payer prices in ETH, and
/// Deposit, which asks it for the quote. The amount is checked as Deposit
/// is pressed, and Return in the box does what Deposit does. Why an amount
/// was turned away shows until the text changes.
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
                    .fixedSize()
                    .onSubmit {
                        // Nothing while Deposit is off.
                        if payer.depositBlock == nil { deposit() }
                    }
                    .onChange(of: text) { wrong = false }
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
                .tip("Shows what the deposit costs in ETH before anything is sent.")
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

/// A quote, as the payer made it, for its owner to confirm, as rows in the
/// section its press was made in: what it sends, where, the most it pays
/// in fees, and how long it holds (not counted down for a transfer). Its
/// button is the one place an approve
/// is sent from; once the quote has expired, the button asks for a new one,
/// shown before anything is approved.
private struct ReviewRows: View {
    let payer: Payer
    let review: Payer.Review

    var body: some View {
        let quote = review.quote
        Group {
            switch review {
            case .deposit(_, let microUSD):
                LabeledContent("Amount") {
                    Text((Decimal(quote.inputMicroUsd ?? microUSD) / 1_000_000).formatted(.currency(code: "USD")))
                }
                LabeledContent("Deposit", value: Ether.text(wei: quote.principalWei) ?? "—")
            case .withdrawal:
                LabeledContent("Amount", value: Ether.text(gwei: quote.amount))
            case .transfer:
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
            LabeledContent("Fee", value: cost(wei: quote.requiredFeeWei).map { "Up to \($0)" } ?? "—")
            LabeledContent("Total", value: cost(wei: quote.requiredTotalWei) ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = quote.expired(at: context.date)
                let block = payer.confirmBlock(review)
                HStack(spacing: 8) {
                    if !expired, timed {
                        Text(quote.expires, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .tip("The quote holds until this runs out.")
                    }
                    Spacer()
                    if let block {
                        Text(block.words)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", action: payer.cancelReview)
                    Button(expired ? again : title) { Task { await payer.confirm() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!expired && block != nil)
                }
            }
        }
    }

    /// "0.0126 ETH", and in a deposit's review "0.0126 ETH, about $19.86":
    /// the fee can be several times a small deposit, and dollars say so.
    private func cost(wei: String) -> String? {
        guard let eth = Ether.text(wei: wei) else { return nil }
        guard let dollars = review.quote.dollars(wei: wei) else { return eth }
        return "\(eth), about \(dollars.formatted(.currency(code: "USD")))"
    }

    private var title: String {
        switch review {
        case .deposit: "Deposit"
        case .withdrawal: "Withdraw"
        case .transfer: "Transfer"
        }
    }

    /// Whether the time the quote holds for is counted down beside the
    /// button. A deposit's and a withdrawal's are; a transfer's amount and
    /// address are its owner's own, and only its fee can change.
    private var timed: Bool {
        if case .transfer = review { false } else { true }
    }

    /// The button once the quote has expired: it asks for a new one, shown
    /// before anything is approved.
    private var again: String {
        timed ? "New Quote" : "Update Fee"
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
                .tip(fault)
                .accessibilityValue(fault)
            Spacer()
            Button("Try Again") { Task { await payer.retry() } }
        }
    }
}

/// The model V chats go to, from the service's list, each with its price a
/// million tokens where the provider lists one; which price is which, and
/// what is set aside for a request, is the row's help. The choice is kept in
/// Settings' defaults. A read of the list or of the prices that stops says
/// so in the row, with Try Again.
private struct ModelSection: View {
    let payer: Payer
    @Bindable var settings: AppSettings
    /// The last read of the list from here stopped; false while one is
    /// under way.
    @State private var stopped = false

    var body: some View {
        Section {
            if let models = payer.models, let prices = payer.prices, let model = payer.model,
                let chosen = models.first(where: { $0.id == model })
            {
                let help =
                    "Prices per million tokens: in | out. Up to \(Self.price(Decimal(chosen.cap) / 1_000_000)) is set aside while a request to this model is out; what it doesn't use stays in your deposit."
                Picker("Model", selection: Binding(get: { model }, set: { settings.vModel = $0 })) {
                    ForEach(models) { model in
                        if let price = prices[model.id]?.perMillion {
                            let input = Self.price(price.input), output = Self.price(price.output)
                            Text("\(model.id): \(input) | \(output)")
                                // Read aloud, a bar says nothing of which side is which.
                                .accessibilityLabel("\(model.id), \(input) in, \(output) out")
                                .tag(model.id)
                        } else {
                            Text(model.id)
                                .tag(model.id)
                        }
                    }
                }
                .tip(help)
                .accessibilityHint(help)
            } else {
                LabeledContent("Model") {
                    if payer.models != nil, payer.prices != nil {
                        Text("None listed")
                            .foregroundStyle(.secondary)
                    } else if stopped {
                        HStack(spacing: 8) {
                            Text("Couldn't load the list")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { await load() } }
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .task(id: payer.state == .unread) {
            guard payer.state != .unread else { return }
            await load()
        }
    }

    /// Reads the service's models and their prices through the payer.
    private func load() async {
        stopped = false
        do {
            try await payer.loadModels()
            try await payer.loadPrices()
        } catch {
            stopped = true
        }
    }

    /// "$0.27"
    private static func price(_ dollars: Decimal) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
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

/// Why a press in V's wallet stopped, in plain words, with Dismiss. One
/// that stopped for want of a read carries Try Again, which reads.
private struct PressStopRow: View {
    let payer: Payer
    let stop: Payer.Stop

    var body: some View {
        StopLine(title: stop.title, words: stop.words) {
            if stop == .unread {
                ReadAgain(payer: payer)
            }
            DismissButton(action: payer.dismiss)
        }
    }
}

/// Why the last read of V's wallet stopped, in plain words, with Try Again.
/// It stays until a read works.
private struct ReadStopRow: View {
    let payer: Payer
    let stop: PayStop

    var body: some View {
        StopLine(title: stop.title, words: stop.readWords) {
            ReadAgain(payer: payer)
        }
    }
}

/// Try Again on a read that stopped: reads now. A spinner in its place
/// while a read is under way.
private struct ReadAgain: View {
    let payer: Payer

    var body: some View {
        if payer.reading {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Try Again", action: payer.follow)
        }
    }
}

/// Why a chat request to V's payer stopped, in plain words. One with no
/// deposit says to deposit; that one, and one whose model the service can't
/// use, come with the way to the wallet.
struct PayStopRow: View {
    let stop: PayStop
    /// What the stopped request was to do: send or run.
    var verb = "send"
    var showWallet: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        let noDeposit = stop.code == .noDeposit
        StopLine(title: noDeposit ? "Deposit to \(verb)." : stop.title, words: noDeposit ? nil : stop.words) {
            if noDeposit || stop.code == .modelUnavailable, let showWallet {
                Button("Wallet…", action: showWallet)
            }
            DismissButton(action: dismiss)
        }
    }
}

/// A stop's row: its mark, what stopped and what to do, and the ways on at
/// the right.
private struct StopLine<Actions: View>: View {
    let title: String
    let words: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let words {
                    Text(words)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
    }
}

/// Dismiss, as a symbol.
private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button("Dismiss", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .hover(Circle(), outset: 4)
            .tip("Dismiss")
    }
}

extension Payer.Stop {
    var title: String {
        switch self {
        case .quote(let stop), .approve(let stop): stop.title
        case .unread: "Unavailable"
        }
    }

    /// What happened and what to do. A quote sends nothing, so one that got
    /// no answer says so; an approve may have been sent.
    var words: String {
        switch self {
        case .quote(let stop) where stop.unanswered:
            "No quote came. Nothing was sent. Try again."
        case .approve(let stop) where stop.unanswered:
            "No answer came. It may have been sent: the Wallet shows it once the chain does."
        case .quote(let stop), .approve(let stop):
            stop.words
        case .unread:
            "Cloak hasn't read the deposit, so nothing was sent. Try again."
        }
    }
}

extension PayStop {
    var title: String {
        switch code {
        case .unreachable: "Unreachable"
        case .noDeposit: "No deposit"
        case .withdrawing: "Withdrawing"
        case .busy: "Busy"
        case .modelUnavailable: "Model unavailable"
        case .torDown: "Tor down"
        case .refused: "Declined"
        case .providerFailed: "Failed"
        case .answerRefused: "No answer"
        case .heldTooLong: "Settling"
        case .timedOut: "No answer"
        case .ended: "Interrupted"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        }
    }

    /// For a read of V's wallet. A read sends nothing, so one that got no
    /// answer says so.
    var readWords: String {
        unanswered ? "Cloak couldn't read V's wallet. Nothing was sent. Try again." : words
    }

    /// No answer came: in time, before the connection ended, or from the
    /// provider.
    fileprivate var unanswered: Bool {
        switch code {
        case .timedOut, .ended, .providerFailed: true
        default: false
        }
    }

    /// What happened and what to do, for a chat request.
    var words: String {
        switch code {
        case .unreachable: "Cloak couldn't reach V's wallet. Pause and start Cloak, then try again."
        case .noDeposit: "Make a deposit in Wallet, then try again."
        case .withdrawing: "The deposit is being withdrawn, so it can't pay for requests now."
        case .busy: "V's wallet is busy with another request. Try again."
        case .modelUnavailable: "The service can't use this model now. Pick another in Wallet."
        case .torDown: "Cloak couldn't reach the service through Tor. Try again."
        case .refused: "The service declined the request."
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
        case .needs(let wei): "Insufficient balance: \(Ether.text(Decimal(sign: .plus, exponent: -18, significand: wei), up: true)) more needed"
        case .needsFee: "Insufficient ETH for the fee"
        case .nothingToTransfer: "Nothing to transfer"
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

    /// ETH in full from wei as a decimal string, "0.01", as an amount field
    /// takes it; nil when it does not read.
    static func exact(wei: String) -> String? {
        guard wei.wholeMatch(of: /[0-9]+/) != nil else { return nil }
        let digits = String(repeating: "0", count: max(0, 19 - wei.count)) + wei
        let whole = digits.dropLast(18).drop { $0 == "0" }
        let fraction = String(digits.suffix(18)).replacing(/0+$/, with: "")
        return (whole.isEmpty ? "0" : String(whole)) + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// Wei as a decimal string from ETH as typed, "0.01" or ".5"; nil when
    /// it is not an amount above zero of at most 18 decimals.
    static func wei(eth typed: String) -> String? {
        guard let match = typed.wholeMatch(of: /([0-9]*)(?:\.([0-9]{0,18}))?/) else { return nil }
        let fraction = String(match.2 ?? "")
        let digits = (match.1 + fraction + String(repeating: "0", count: 18 - fraction.count)).drop { $0 == "0" }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Up to six decimals, rounded up when `up`, for an amount still needed.
    static func text(_ eth: Decimal, up: Bool = false) -> String {
        let format = Decimal.FormatStyle.number.precision(.fractionLength(0...6))
        return "\(eth.formatted(up ? format.rounded(rule: .up) : format)) ETH"
    }
}
